Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:protocolDeadline=0L;$script:protocolFrequency=0L
function Set-HostedCapabilityProtocolDeadline([long]$DeadlineCounter,[long]$CounterFrequency){
    if($DeadlineCounter -le 0 -or $CounterFrequency -le 0){throw 'Invalid protocol deadline'}
    $script:protocolDeadline=$DeadlineCounter;$script:protocolFrequency=$CounterFrequency
}
function Get-ProtocolWait([int]$MaximumMilliseconds){
    if(!$script:protocolDeadline){return $MaximumMilliseconds}
    $remaining=[int][Math]::Max(0,[Math]::Min($MaximumMilliseconds,[Math]::Floor(($script:protocolDeadline-[Diagnostics.Stopwatch]::GetTimestamp())*1000.0/$script:protocolFrequency)))
    if($remaining -le 0){throw 'Absolute participant protocol deadline reached'}
    $remaining
}
Export-ModuleMember -Function Set-HostedCapabilityProtocolDeadline


function Connect-HostedCapabilitySupervisor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^Ticket569-[a-f0-9]{32}(?:-helper)?$')][string] $PipeName,
          [ValidateRange(1,30000)][int] $TimeoutMilliseconds=10000)
    $pipe=[IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::None)
    try {
        $pipe.Connect((Get-ProtocolWait $TimeoutMilliseconds))
        $writer=[IO.StreamWriter]::new($pipe,[Text.UTF8Encoding]::new($false),4096,$true)
        $writer.AutoFlush=$true
        $reader=[IO.StreamReader]::new($pipe,[Text.UTF8Encoding]::new($false),$false,4096,$true)
        [pscustomobject]@{ Pipe=$pipe; Reader=$reader; Writer=$writer; Closed=$false }
    } catch { $pipe.Dispose(); throw }
}

function Send-HostedCapabilitySupervisorRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Connection,[Parameter(Mandatory)][object] $Request)
    if ($Connection.Closed -or !$Connection.Pipe.IsConnected) { throw 'Supervisor protocol pipe is not connected' }
    $line=ConvertTo-Json -InputObject $Request -Depth 48 -Compress
    if ($line.Length -gt 1048576) { throw 'Supervisor protocol request exceeds the one-megabyte frame limit' }
    $Connection.Writer.WriteLine($line)
    $responseTask=$Connection.Reader.ReadLineAsync()
    if(!$responseTask.Wait((Get-ProtocolWait 30000))){throw 'Supervisor protocol acknowledgement exceeded its thirty-second bound'}
    $response=$responseTask.Result
    if ($null -eq $response) { throw 'Supervisor closed the protocol pipe before acknowledging the request' }
    if ($response.Length -gt 1048576) { throw 'Supervisor protocol response exceeds the one-megabyte frame limit' }
    ConvertFrom-Json -InputObject $response -ErrorAction Stop
}

function Close-HostedCapabilitySupervisorConnection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Connection)
    if (!$Connection.Closed) {
        $Connection.Closed=$true
        try{if($Connection.Reader){$Connection.Reader.Dispose()}}finally{
            try{if($Connection.Writer){$Connection.Writer.Dispose()}}catch [IO.IOException]{}finally{$Connection.Pipe.Dispose()}
        }
    }
}

function Invoke-HostedProtocolMutation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Connection,
          [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string] $RunId,
          [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceSHA,
          [Parameter(Mandatory)][string] $Operation,
          [Parameter(Mandatory)][object] $ResourceIdentity,
          [Parameter(Mandatory)][object] $Precondition,
          [Parameter(Mandatory)][scriptblock] $Action,
          [scriptblock] $SendRequest)
    $requestId=[guid]::NewGuid().ToString('N')
    $intentRequest=[ordered]@{
        schema='ticket569-supervisor-request-v1'; runId=$RunId; sourceSHA=$SourceSHA; requestId=$requestId
        phase='intent'; operation=$Operation; resourceIdentity=$ResourceIdentity; precondition=$Precondition
    }
    $intent=if($SendRequest){& $SendRequest $intentRequest}else{Send-HostedCapabilitySupervisorRequest -Connection $Connection -Request $intentRequest}
    if (!$intent.acknowledged -or $intent.requestId -cne $requestId -or [long]$intent.sequence -le 0) {
        throw 'Supervisor did not durably acknowledge the exact mutation intent'
    }
    $actionResult=$null
    $actionError=$null
    try { $actionResult=& $Action } catch { $actionError=$_ }
    $observationRequest=[ordered]@{
        schema='ticket569-supervisor-request-v1'; runId=$RunId; sourceSHA=$SourceSHA; requestId=$requestId
        phase='observation'; operation=$Operation; resourceIdentity=$ResourceIdentity; observed=$actionResult
        result=if($actionError){'failed'}else{'completed'}; errorType=if($actionError){$actionError.Exception.GetType().FullName}else{$null}
    }
    $observation=if($SendRequest){& $SendRequest $observationRequest}else{Send-HostedCapabilitySupervisorRequest -Connection $Connection -Request $observationRequest}
    if (!$observation.acknowledged -or $observation.requestId -cne $requestId -or [long]$observation.sequence -le [long]$intent.sequence) {
        throw 'Supervisor did not durably acknowledge the exact mutation observation'
    }
    if ($actionError) { $actionError.Exception.Data['Ticket569MutationObservationAcknowledged']=$true;throw $actionError }
    [pscustomobject]@{ requestId=$requestId; intentSequence=[long]$intent.sequence; observationSequence=[long]$observation.sequence; result=$actionResult }
}

function Connect-HostedCapabilityHelper {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^Ticket569-[a-f0-9]{32}-helper$')][string] $PipeName,
          [ValidateRange(1,30000)][int] $TimeoutMilliseconds=10000)
    Connect-HostedCapabilitySupervisor -PipeName $PipeName -TimeoutMilliseconds $TimeoutMilliseconds
}

function Send-HostedCapabilityHelperFact {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Connection,
          [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string] $RunId,
          [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceSHA,
          [Parameter(Mandatory)][string] $Name,
          [Parameter(Mandatory)][object] $ResourceIdentity,
          [Parameter(Mandatory)][object] $Observed)
    $response=Get-HostedCapabilityHelperFact -Connection $Connection -RunId $RunId -SourceSHA $SourceSHA -Name $Name -ResourceIdentity $ResourceIdentity -Observed $Observed
    [long]$response.sequence
}

function Get-HostedCapabilityHelperFact {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Connection,
          [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string] $RunId,
          [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceSHA,
          [Parameter(Mandatory)][string] $Name,
          [Parameter(Mandatory)][object] $ResourceIdentity,
          [Parameter(Mandatory)][object] $Observed)
    $requestId=[guid]::NewGuid().ToString('N')
    $response=Send-HostedCapabilitySupervisorRequest -Connection $Connection -Request ([ordered]@{
        schema='ticket569-supervisor-request-v1';runId=$RunId;sourceSHA=$SourceSHA;requestId=$requestId
        phase='fact';name=$Name;resourceIdentity=$ResourceIdentity;observed=$Observed
    })
    if(!$response.acknowledged -or $response.requestId -cne $requestId -or [long]$response.sequence -le 0){throw 'Supervisor did not durably acknowledge the exact helper observation'}
    $response
}

function Invoke-HostedHelperMutation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Connection,
          [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string] $RunId,
          [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceSHA,
          [Parameter(Mandatory)][string] $Operation,
          [Parameter(Mandatory)][object] $ResourceIdentity,
          [Parameter(Mandatory)][object] $Precondition,
          [Parameter(Mandatory)][scriptblock] $Action,
          [scriptblock] $SendRequest)
    Invoke-HostedProtocolMutation -Connection $Connection -RunId $RunId -SourceSHA $SourceSHA `
        -Operation $Operation -ResourceIdentity $ResourceIdentity -Precondition $Precondition -Action $Action -SendRequest $SendRequest
}

Export-ModuleMember -Function Connect-HostedCapabilitySupervisor, Send-HostedCapabilitySupervisorRequest, Close-HostedCapabilitySupervisorConnection, Invoke-HostedProtocolMutation, Connect-HostedCapabilityHelper, Send-HostedCapabilityHelperFact, Get-HostedCapabilityHelperFact, Invoke-HostedHelperMutation
