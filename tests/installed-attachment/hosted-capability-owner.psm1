Set-StrictMode -Version Latest
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)

function Write-HostedCapabilityAtomicJson {
    param([Parameter(Mandatory)][string] $Path,[Parameter(Mandatory)][object] $Value)
    $parent = Split-Path -Parent $Path
    if (!(Test-Path -LiteralPath $parent -PathType Container)) { throw 'Evidence parent directory is missing' }
    $temporary = Join-Path $parent ('.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $bytes = $script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $Value -Depth 48 -Compress) + [Environment]::NewLine)
    $stream = [IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ([IO.File]::Exists($Path)) {
        [IO.File]::Move($temporary,$Path,$true)
    } else {
        [IO.File]::Move($temporary,$Path)
    }
}

function New-HostedCapabilityLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string] $RunId,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceSHA,
        [Parameter(Mandatory)][string] $BootMarker,
        [Parameter(Mandatory)][long] $JobStartCounter,
        [Parameter(Mandatory)][long] $CounterFrequency
    )
    if ($CounterFrequency -le 0 -or $JobStartCounter -lt 0 -or !$BootMarker) { throw 'Clock marker is invalid' }
    if (!(Test-Path -LiteralPath $Directory -PathType Container)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $eventsPath = Join-Path $Directory 'events.ndjson'
    $stream = [IO.FileStream]::new($eventsPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $state = [ordered]@{
        schema='ticket569-owner-state-v1'; runId=$RunId; sourceSHA=$SourceSHA; phase='preparing'
        createdAtUtc=[DateTime]::UtcNow.ToString('o'); bootMarker=$BootMarker
        jobStartCounter=$JobStartCounter; counterFrequency=$CounterFrequency; lastSequence=0
        failureLatched=$false; resources=@{}
    }
    try { Write-HostedCapabilityAtomicJson -Path (Join-Path $Directory 'owner-state.json') -Value $state }
    catch { $stream.Dispose(); Remove-Item -LiteralPath $eventsPath -Force -ErrorAction SilentlyContinue; throw }
    [pscustomobject]@{ Directory=$Directory; RunId=$RunId; SourceSHA=$SourceSHA; Sequence=0L; Stream=$stream; State=$state; FailureLatched=$false; FailureEvent=$null; Closed=$false }
}

function Get-HostedCapabilityEventField {
    param([Parameter(Mandatory)][object] $Event,[Parameter(Mandatory)][string] $Name)
    if ($Event -is [Collections.IDictionary]) { return $Event[$Name] }
    $property=$Event.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Write-HostedCapabilityLedgerEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Ledger,[Parameter(Mandatory)][object] $Event)
    if ($Ledger.Closed) { throw 'Owner ledger is closed' }
    $sequence = [long]$Ledger.Sequence + 1
    $record = [ordered]@{
        sequence=$sequence; atUtc=[DateTime]::UtcNow.ToString('o'); runId=$Ledger.RunId; sourceSHA=$Ledger.SourceSHA
        requestId=(Get-HostedCapabilityEventField $Event 'requestId')
        phase=[string](Get-HostedCapabilityEventField $Event 'phase'); operation=[string](Get-HostedCapabilityEventField $Event 'operation')
        resourceIdentity=(Get-HostedCapabilityEventField $Event 'resourceIdentity'); precondition=(Get-HostedCapabilityEventField $Event 'precondition')
        observed=(Get-HostedCapabilityEventField $Event 'observed'); result=(Get-HostedCapabilityEventField $Event 'result'); processIdentity=(Get-HostedCapabilityEventField $Event 'processIdentity')
    }
    if ($record.phase -notin @('resource','intent','observation','failure','process')) { throw 'Owner event phase is invalid' }
    if (!$record.operation) { throw 'Owner event operation is required' }
    $line = $script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $record -Depth 48 -Compress) + [Environment]::NewLine)
    $Ledger.Stream.Write($line,0,$line.Length)
    $Ledger.Stream.Flush($true)
    $Ledger.Sequence = $sequence
    $Ledger.State.lastSequence = $sequence
    $Ledger.State.phase = $record.phase
    if ($record.phase -eq 'failure') { $Ledger.FailureLatched = $true; $Ledger.State.failureLatched=$true }
    Write-HostedCapabilityAtomicJson -Path (Join-Path $Ledger.Directory 'owner-state.json') -Value $Ledger.State
    [pscustomobject]$record
}

function Read-HostedCapabilityLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string] $RunId,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceSHA
    )
    $eventsPath=Join-Path $Directory 'events.ndjson'
    $statePath=Join-Path $Directory 'owner-state.json'
    if(!(Test-Path -LiteralPath $eventsPath -PathType Leaf) -or !(Test-Path -LiteralPath $statePath -PathType Leaf)){
        return [pscustomobject]@{valid=$false;sequence=0L;failureLatched=$true;pending=@();sessionFact=$null;error='ledger-file-missing'}
    }
    $pending=@{}
    $allEvents=[Collections.Generic.List[object]]::new()
    $completedMutations=[Collections.Generic.List[object]]::new()
    $sessionFact=$null
    $sequence=0L
    $failureLatched=$false
    $errorMessage=$null
    try{
        # Reader allows the existing sole writer; the writer still denies a second writer.
        $readStream=[IO.FileStream]::new($eventsPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        $journalReader=[IO.StreamReader]::new($readStream,[Text.Encoding]::UTF8)
        try { $journalText=$journalReader.ReadToEnd() } finally { $journalReader.Dispose() }
        if(!$journalText){$journalLines=@()}else{$journalLines=$journalText.TrimEnd([char[]]@([char]10,[char]13)).Split([char]10)}
        foreach($line in $journalLines){
            $line=$line.TrimEnd([char]13)
            if([string]::IsNullOrWhiteSpace($line)){throw 'ledger contains an empty event record'}
            $event=$line|ConvertFrom-Json -ErrorAction Stop
            $allEvents.Add($event)
            $sequence++
            if([long]$event.sequence -ne $sequence -or $event.runId -cne $RunId -or $event.sourceSHA -cne $SourceSHA){throw 'ledger sequence/run/source identity is discontinuous'}
            if($event.phase -notin @('resource','intent','observation','failure','process') -or !$event.operation){throw 'ledger phase or operation is invalid'}
            if($event.phase -eq 'intent'){
                if(!$event.requestId -or $pending.ContainsKey([string]$event.requestId)){throw 'ledger intent request identity is missing or duplicated'}
                $pending[[string]$event.requestId]=$event
            } elseif($event.phase -eq 'observation' -and $event.requestId){
                $requestId=[string]$event.requestId
                if(!$pending.ContainsKey($requestId)){throw 'ledger observation has no matching durable intent'}
                $intent=$pending[$requestId]
                if($intent.operation -cne $event.operation -or (ConvertTo-Json -InputObject $intent.resourceIdentity -Compress -Depth 32) -cne (ConvertTo-Json -InputObject $event.resourceIdentity -Compress -Depth 32)){
                    throw 'ledger observation does not match its exact durable intent identity'
                }
                $completedMutations.Add([pscustomobject]@{intent=$intent;observation=$event})
                $pending.Remove($requestId)
            } elseif($event.phase -eq 'observation'){
                throw 'ledger mutation observation lacks a request identity'
            } elseif($event.phase -eq 'process' -and $event.operation -ceq 'exact-active-user-session-observed'){
                if(!$event.resourceIdentity.sid -or [int]$event.resourceIdentity.sessionId -le 0){throw 'ledger session observation identity is invalid'}
                $sessionFact=@{sid=[string]$event.resourceIdentity.sid;sessionId=[int]$event.resourceIdentity.sessionId;profilePath=[string]$event.resourceIdentity.profilePath;stepName=[string]$event.resourceIdentity.stepName;profileContext=if($event.resourceIdentity.PSObject.Properties['profileContext']){$event.resourceIdentity.profileContext}else{$null};ledgerSequence=$sequence;acknowledgedBySupervisor=$true;workerProcessIdentity=$event.processIdentity}
            }
            if($event.phase -eq 'failure'){$failureLatched=$true}
        }
        $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop
        if($state.runId -cne $RunId -or $state.sourceSHA -cne $SourceSHA -or [long]$state.lastSequence -gt $sequence){throw 'ledger snapshot identity or sequence disagrees with the journal'}
        $failureLatched=$failureLatched -or [bool]$state.failureLatched -or (Test-Path -LiteralPath (Join-Path $Directory 'failure-records'))
    }catch{$errorMessage=$_.Exception.Message}
    [pscustomobject]@{valid=(!$errorMessage);sequence=$sequence;failureLatched=$failureLatched;pending=@($pending.Values);mutations=@($completedMutations);events=@($allEvents);sessionFact=$sessionFact;error=$errorMessage}
}

function Invoke-HostedAcknowledgedMutation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Ledger,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string] $RunId,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceSHA,
        [Parameter(Mandatory)][string] $Operation,
        [Parameter(Mandatory)][object] $ResourceIdentity,
        [Parameter(Mandatory)][object] $Precondition,
        [Parameter(Mandatory)][scriptblock] $SendIntent,
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][scriptblock] $SendObservation
    )
    if ($RunId -cne $Ledger.RunId -or $SourceSHA -cne $Ledger.SourceSHA) { throw 'Owner request run/source identity mismatch' }
    $requestId=[guid]::NewGuid().ToString('N')
    $intent=[ordered]@{ requestId=$requestId; runId=$RunId; sourceSHA=$SourceSHA; phase='intent'; operation=$Operation; resourceIdentity=$ResourceIdentity; precondition=$Precondition }
    $intentAck=& $SendIntent $intent
    if (!$intentAck -or $intentAck.acknowledged -ne $true -or $intentAck.requestId -cne $requestId -or $intentAck.sequence -lt $Ledger.Sequence) {
        throw 'Supervisor intent acknowledgement missing, mismatched, or not durable'
    }
    $intentSequence=[long]$intentAck.sequence
    $actionResult=$null
    $actionError=$null
    try { $actionResult=& $Action }
    catch { $actionError=$_ }
    $observation=[ordered]@{ requestId=$requestId; runId=$RunId; sourceSHA=$SourceSHA; phase='observation'; operation=$Operation; resourceIdentity=$ResourceIdentity; observed=$actionResult; result=if($actionError){'failed'}else{'completed'}; errorType=if($actionError){$actionError.Exception.GetType().FullName}else{$null} }
    $observationAck=& $SendObservation $observation
    if (!$observationAck -or $observationAck.acknowledged -ne $true -or $observationAck.requestId -cne $requestId -or $observationAck.sequence -le $intentSequence) {
        throw 'Supervisor observation acknowledgement missing, mismatched, or not durable'
    }
    if ($actionError) { throw $actionError }
    [pscustomobject]@{ requestId=$requestId; intentSequence=$intentSequence; observationSequence=[long]$observationAck.sequence; result=$actionResult }
}

function Write-HostedCapabilityFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Ledger,[Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string] $Code,[Parameter(Mandatory)][object] $Evidence)
    $directory=Join-Path $Ledger.Directory 'failure-records'
    if (!(Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $path=Join-Path $directory ($Code + '-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-HostedCapabilityAtomicJson -Path $path -Value ([ordered]@{schema='ticket569-failure-v1';runId=$Ledger.RunId;sourceSHA=$Ledger.SourceSHA;code=$Code;atUtc=[DateTime]::UtcNow.ToString('o');evidence=$Evidence})
    $Ledger.FailureLatched=$true
    $Ledger.State.failureLatched=$true
    if($Ledger.FailureEvent){try{$Ledger.FailureEvent.Release()}catch{}}
    Write-HostedCapabilityAtomicJson -Path (Join-Path $Ledger.Directory 'owner-state.json') -Value $Ledger.State
    [pscustomobject]@{ latched=$true; path=$path; code=$Code }
}

function Test-HostedCapabilityFailure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Ledger)
    [bool]($Ledger.FailureLatched -or $Ledger.State.failureLatched -or (Test-Path -LiteralPath (Join-Path $Ledger.Directory 'failure-records')))
}

function Close-HostedCapabilityLedger {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Ledger)
    if (!$Ledger.Closed) { $Ledger.Stream.Flush($true); $Ledger.Stream.Dispose(); $Ledger.Closed=$true }
}

Export-ModuleMember -Function Write-HostedCapabilityAtomicJson, New-HostedCapabilityLedger, Read-HostedCapabilityLedger, Write-HostedCapabilityLedgerEvent, Invoke-HostedAcknowledgedMutation, Write-HostedCapabilityFailure, Test-HostedCapabilityFailure, Close-HostedCapabilityLedger
