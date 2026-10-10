[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string] $SourceSHA,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string] $RunId,
    [ValidateRange(1,30)][int] $DeadlineMinutes=30,
    # Faults only stop work; they cannot bypass source, caller or ownership guards.
    [ValidateSet('none','before-runtime-intent','after-user-create','present-root-recovery')][string] $TestFault='none'
)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -eq 'true' -and $TestFault -ceq 'present-root-recovery'){throw 'TestFault exercises are SSH-only and refused in GitHub Actions'}
$ProgressPreference='SilentlyContinue'
foreach($tokenName in @('GH_TOKEN','GITHUB_TOKEN')){[Environment]::SetEnvironmentVariable($tokenName,$null,'Process')}
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-intent.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-owner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-protocol.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-verdict.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-bundle.psm1') -Force

foreach ($marker in @('HOSTED_CAPABILITY_JOB_STARTED_AT_UTC','HOSTED_CAPABILITY_JOB_STARTED_QPC','HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY','HOSTED_CAPABILITY_JOB_STARTED_BOOT')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($marker))) { throw "Supervisor refused missing clock marker $marker" }
}
$start=[long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC
$frequency=[long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY
$boot=[string]$env:HOSTED_CAPABILITY_JOB_STARTED_BOOT
$sample=Get-HostedCapabilityClockSample
$clock=Test-HostedCapabilityClock -ExpectedBootMarker $boot -ObservedBootMarker $sample.bootMarker -ExpectedFrequency $frequency -ObservedFrequency $sample.frequency -JobStartCounter $start -CurrentCounter $sample.counter
if (!$clock.valid) { throw ('Supervisor refused invalid job clock: ' + ($clock.reasons -join ',')) }
$expectedSha=$SourceSHA.ToLowerInvariant()
$head=(& git -C $root rev-parse HEAD).Trim().ToLowerInvariant();$headExit=$LASTEXITCODE
$status=(& git -C $root status --porcelain --untracked-files=all | Out-String).Trim();$statusExit=$LASTEXITCODE
if ($headExit -ne 0 -or $statusExit -ne 0 -or $head -cne $expectedSha -or $head -cne $env:GITHUB_SHA.ToLowerInvariant() -or $status) { throw 'Supervisor requires a clean checkout whose HEAD equals SourceSHA and GITHUB_SHA' }
$deadlines=Get-HostedCapabilityDeadlines -JobStartCounter $start -CounterFrequency $frequency
$runRoot=Join-Path $EvidenceDirectory 'supervisor'
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$session=[Diagnostics.Process]::GetCurrentProcess().SessionId
$self=[Diagnostics.Process]::GetCurrentProcess()
$selfCreation=$self.StartTime.ToUniversalTime().ToFileTimeUtc()
$selfIdentity=@{pid=$self.Id;creationFileTimeUtc=$selfCreation;sid=$sid;sessionId=$session}
$pipeName="Ticket569-$RunId"
$failureEventName="Global\Ticket569-$RunId-failure"
$jobName="Global\Ticket569-$RunId-worker"
$ownerJobName="Global\Ticket569-$RunId-session-owner"
$recoveryJobName="Global\Ticket569-$RunId-recovery"
$ownerPipeName="Ticket569-$RunId-session-owner"
$sddl="D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
$supervisorIdentityPath=Join-Path $EvidenceDirectory 'supervisor-identity.json'
Write-HostedCapabilityAtomicJson -Path $supervisorIdentityPath -Value @{schema='ticket569-supervisor-identity-v1';testFault=$TestFault;runId=$RunId;sourceSHA=$expectedSha;supervisor=$selfIdentity;worker=$null;jobNames=@($jobName,"Global\Ticket569-$RunId-build",$ownerJobName,$recoveryJobName);atUtc=[DateTime]::UtcNow.ToString('o');stage='supervisor-started'}
$ledger=New-HostedCapabilityLedger -Directory $runRoot -RunId $RunId -SourceSHA $expectedSha -BootMarker $boot -JobStartCounter $start -CounterFrequency $frequency
$cuaBundleContract=Get-HostedCapabilityCuaBundleContract
$cuaBundlePath=Join-Path $env:RDPILOT_BIN_DIR 'guest-bundle'
$cuaBundleReceiptPath=Join-Path $cuaBundlePath 'guest-bundle.json'
if(!(Test-Path -LiteralPath $cuaBundleReceiptPath -PathType Leaf)){throw 'Supervisor refused a missing pinned guest bundle receipt'}
try{$cuaBundleReceipt=Get-Content -LiteralPath $cuaBundleReceiptPath -Raw|ConvertFrom-Json -ErrorAction Stop}catch{throw 'Supervisor refused a malformed pinned guest bundle receipt'}
$cuaArchivePath=Join-Path $cuaBundlePath $cuaBundleContract.ArchiveName
$cuaBridgePath=Join-Path $cuaBundlePath 'rdpilot-bridge.exe'
if($cuaBundleReceipt.schema -cne 'ticket569-rdpilot-guest-bundle-v1' -or
   $cuaBundleReceipt.rdpilotSourceCommit -cne '8f799dd1e37422a8966833a08e4ec279f645ec58' -or
   $cuaBundleReceipt.sourceSHA -cne $expectedSha -or
   $cuaBundleReceipt.cuaReleaseTag -cne $cuaBundleContract.ReleaseTag -or
   $cuaBundleReceipt.cuaArchive -cne $cuaBundleContract.ArchiveName -or
   !(Test-HostedCapabilityArchiveFile -Path $cuaArchivePath -ExpectedBytes $cuaBundleContract.ArchiveBytes -ExpectedSHA256 $cuaBundleContract.ArchiveSHA256) -or
   !(Test-Path -LiteralPath $cuaBridgePath -PathType Leaf) -or
   (Get-FileHash -LiteralPath $cuaBridgePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$cuaBundleReceipt.bridgeSHA256){
    throw 'Supervisor refused guest bundle files that did not match the pinned source and release receipt'
}
$evidenceBundleReceipt=Join-Path $EvidenceDirectory 'rdpilot-guest-bundle.json'
Copy-Item -LiteralPath $cuaBundleReceiptPath -Destination $evidenceBundleReceipt -ErrorAction Stop
Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='pinned-rdpilot-guest-bundle-verified';processIdentity=$selfIdentity;resourceIdentity=@{rdpilotSourceCommit=$cuaBundleReceipt.rdpilotSourceCommit;sourceSHA=$expectedSha;cuaReleaseTag=$cuaBundleReceipt.cuaReleaseTag;archiveSHA256=$cuaBundleReceipt.cuaArchiveSHA256;bridgeSHA256=$cuaBundleReceipt.bridgeSHA256};observed=@{evidenceReceipt=(Split-Path -Leaf $evidenceBundleReceipt)}}|Out-Null
$failureEventDacl="D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
$script:failureEvent=New-HostedCapabilityGate -Name $failureEventName -DaclSddl $failureEventDacl
$ledger.FailureEvent=$script:failureEvent
$failureEventDaclSHA256=$null;$sha=[Security.Cryptography.SHA256]::Create();try{$failureEventDaclSHA256=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($failureEventDacl))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='resource';operation='global-failure-event-created';resourceIdentity=@{name=$failureEventName;daclSHA256=$failureEventDaclSHA256;resetOperationExposed=$false};observed=@{initiallySignaled=$false;manualReset=$true;signalOnly=$true;crossProcess=$true}} | Out-Null
$job=$null;$ownerJob=$null;$recoveryJob=$null;$recoveryGate=$null;$ownerProcess=$null;$ownerBootstrap=$null;$worker=$null;$server=$null;$reader=$null;$writer=$null;$helperServer=$null;$helperReader=$null;$helperWriter=$null;$helperProcess=$null
$pending=$null;$helperPending=$null;$failure=$false;$failureEventObserved=$false;$workerExit=$null;$acceptedCaller=$false;$helperAccepted=$false;$protocolError=$null;$cleanupStarted=$false;$workerFinalized=$false;$recoveryRequired=$false;$recoveryCompleted=$false;$script:ownerCleanupComplete=$false
$script:rootPreabsenceFacts=@{};$script:rootImportAttempts=@{};$script:helperProcessIdentity=$null;$script:helperReadTask=$null
$script:ownedCredentialTargets=@{}
$script:expectedUserChildIdentity=$null
$script:rootImportGate=$null;$script:expectedRootImporter=$null;$script:rootImporterHandle=$null;$script:rootImporterParentHandle=$null
$script:userProbeGates=@{};$script:finishingHelpers=[Collections.Generic.List[object]]::new();$script:expectedRecoveryLauncher=$null;$script:expectedRecoveryWorker=$null;$script:recoveryWorkerHandle=$null
$script:authoritativeSessionFact=$null
$script:rootImportObservations=@{};$script:presentRootIntercept=$null;$script:presentRootBarrier=$null;$script:presentRootPromptIdentity=$null;$script:exerciseRecoveryCutoff=$null;$script:presentRootRecoveryEvidence=$null;$script:presentRootCleanupCounter=$null
$runtimeRootWasAbsent=!(Test-Path -LiteralPath 'C:\crabbox\work\ticket569')
Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='resource';operation='hosted-runtime-root-preabsence';resourceIdentity=@{path='C:\crabbox\work\ticket569'};observed=@{absent=$runtimeRootWasAbsent}} | Out-Null
$script:helperReadDeadlineCounter=$null
$script:recoveryGate=$null
$workerName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { $workerName=(Get-Command pwsh.exe).Source }
$workerScript=Join-Path $PSScriptRoot 'hosted-capability.ps1'
$workerArgs=@('-NoLogo','-NoProfile','-NonInteractive','-STA','-File',$workerScript,'-SourceSHA',$expectedSha,'-EvidenceDirectory',$EvidenceDirectory,'-DeadlineMinutes',[string]$DeadlineMinutes,'-JobStartedAtUtc',$env:HOSTED_CAPABILITY_JOB_STARTED_AT_UTC,'-FailureEventName',$failureEventName,'-RunId',$RunId)
if($TestFault -cne 'none'){$workerArgs+=@('-TestFault',$TestFault)}
$ownerScript=Join-Path $PSScriptRoot 'hosted-session-owner.ps1'
$ownerArgs=@('-NoLogo','-NoProfile','-NonInteractive','-File',$ownerScript,'-RunId',$RunId,'-SourceSHA',$expectedSha,'-PipeName',$ownerPipeName,'-BinaryDirectory',$env:RDPILOT_BIN_DIR,'-OwnerJobName',$ownerJobName,'-EvidenceDirectory',$EvidenceDirectory,'-SupervisorSID',$sid,'-SupervisorPID',[string]$self.Id,'-SupervisorCreationFileTimeUtc',[string]$selfCreation,'-JobStartCounter',[string]$start,'-CounterFrequency',[string]$frequency,'-SessionName','ticket569')
function Invoke-SessionOwnerControl([object] $Request,[int] $TimeoutMilliseconds=5000) {
    $until=[Math]::Min($deadlines.cleanup,[Diagnostics.Stopwatch]::GetTimestamp()+[long]$TimeoutMilliseconds*$frequency/1000)
    $lastError=$null
    while([Diagnostics.Stopwatch]::GetTimestamp() -lt $until){
        $pipe=$null;$reader=$null;$writer=$null
        try {
            $pipe=[IO.Pipes.NamedPipeClientStream]::new('.', $ownerPipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::None)
            $remaining=Get-HostedCapabilityWaitBudget $until $frequency $TimeoutMilliseconds
            if($remaining -le 0){throw 'Session-owner control absolute deadline reached'}
            $pipe.Connect($remaining)
            $writer=[IO.StreamWriter]::new($pipe,[Text.UTF8Encoding]::new($false),4096,$true);$writer.AutoFlush=$true
            $reader=[IO.StreamReader]::new($pipe,[Text.UTF8Encoding]::new($false),$false,4096,$true)
            $writer.WriteLine((ConvertTo-Json -InputObject $Request -Depth 24 -Compress))
            $read=$reader.ReadLineAsync();$remaining=Get-HostedCapabilityWaitBudget $until $frequency $TimeoutMilliseconds
            if($remaining -le 0){throw 'Session-owner control absolute deadline reached'}
            if(!$read.Wait($remaining)){throw 'session-owner control response exceeded its bound'}
            if(!$read.Result){throw 'session-owner closed its control pipe without a response'}
            return (ConvertFrom-Json -InputObject $read.Result -ErrorAction Stop)
        } catch {$lastError=$_;Start-Sleep -Milliseconds (Get-HostedCapabilityWaitBudget $until $frequency 100)}
        finally {if($reader){$reader.Dispose()};if($writer){$writer.Dispose()};if($pipe){$pipe.Dispose()}}
    }
    throw "session-owner control request timed out: $($lastError.Exception.GetType().FullName)"
}
function New-SessionOwnerRequest([string] $Command,[object] $Extra=$null) {
    $request=[ordered]@{schema='ticket569-session-owner-v1';runId=$RunId;sourceSHA=$expectedSha;command=$Command}
    if($Extra){foreach($key in $Extra.Keys){$request[$key]=$Extra[$key]}}
    $request
}
function Invoke-SupervisorRecoveryMutation([string] $Operation,[object] $ResourceIdentity,[object] $Precondition,[scriptblock] $Action) {
    $requestId=[guid]::NewGuid().ToString('N')
    $intent=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{requestId=$requestId;phase='intent';operation=$Operation;resourceIdentity=$ResourceIdentity;precondition=$Precondition;processIdentity=$selfIdentity}
    try{$observed=& $Action;$result='completed';$errorType=$null}catch{$observed=@{errorType=$_.Exception.GetType().FullName};$result='failed';$errorType=$_.Exception.GetType().FullName;$caught=$_}
    $observation=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{requestId=$requestId;phase='observation';operation=$Operation;resourceIdentity=$ResourceIdentity;observed=$observed;result=$result;processIdentity=$selfIdentity}
    if($result -ne 'completed'){throw $caught}
    [pscustomobject]@{intentSequence=$intent.sequence;observationSequence=$observation.sequence;result=$observed}
}
function Get-SupervisorProcessSID([CimInstance] $Process) {
    try{$owner=Invoke-CimMethod -InputObject $Process -MethodName GetOwnerSid -ErrorAction Stop;[string]$owner.Sid}catch{$null}
}
function Assert-BeforeRecoveryDeadline {
    if([Diagnostics.Stopwatch]::GetTimestamp() -ge $deadlines.cleanup){throw 'Recovery reached the hard J+24 cleanup deadline'}
}
function New-HostedCapabilityHelperServer([string] $TargetSID=$null) {
    $security=[IO.Pipes.PipeSecurity]::new()
    $sddl="D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
    if($TargetSID){
        if($TargetSID -notmatch '^S-1-5-21-[0-9-]+$'){throw 'Helper pipe target SID is malformed'}
        $sddl+="(A;;GRGW;;;$TargetSID)"
    }
    $security.SetSecurityDescriptorSddlForm($sddl)
    # The security constructor belongs to .NET Framework. The actual pwsh
    # supervisor uses the supported Core ACL factory with the same exact DACL.
    if('System.IO.Pipes.NamedPipeServerStreamAcl' -as [type]){
        return [IO.Pipes.NamedPipeServerStreamAcl]::Create("Ticket569-$RunId-helper",[IO.Pipes.PipeDirection]::InOut,4,
            [IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,65536,65536,$security,
            [IO.HandleInheritability]::None,[IO.Pipes.PipeAccessRights]0)
    }
    [IO.Pipes.NamedPipeServerStream]::new("Ticket569-$RunId-helper",[IO.Pipes.PipeDirection]::InOut,4,
        [IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,65536,65536,$security)

}
function Get-HelperExpectedSession {
    $replay=Read-HostedCapabilityLedger -Directory $runRoot -RunId $RunId -SourceSHA $expectedSha
    $fact=$replay.sessionFact
    $memoryFact=$script:authoritativeSessionFact
    if(!$replay.valid -or !$fact -or !$memoryFact -or $fact.ledgerSequence -ne $memoryFact.ledgerSequence -or
       $fact.sid -cne $memoryFact.sid -or [int]$fact.sessionId -ne [int]$memoryFact.sessionId -or !$fact.sid -or [int]$fact.sessionId -le 0){
        throw 'Helper process has no exact active user-session fact that replays from the supervisor-owned durable ledger'
    }
    @{sid=[string]$fact.sid;sessionId=[int]$fact.sessionId;ledgerSequence=[long]$fact.ledgerSequence}
}
function Get-HelperDeadline {if($script:helperProcessIdentity.role -cin @('root-remove','recovery-worker')){$deadlines.cleanup}else{$deadlines.work}}
function Accept-HostedCapabilityHelper {
    if(!$helperServer -or !$helperServer.IsConnected){return $false}
    $clientProcessId=Get-HostedCapabilityPipeClientProcessId -PipeHandle $helperServer.SafePipeHandle.DangerousGetHandle()
    $clientSid=Get-HostedCapabilityPipeClientSid -Pipe $helperServer
    $expected=Get-HelperExpectedSession
    $helperProcess=Get-Process -Id $clientProcessId -ErrorAction Stop
    $null=$helperProcess.Handle
    $procInfo=Get-CimInstance Win32_Process -Filter "ProcessId=$clientProcessId" -ErrorAction Stop
    $command=[string]$procInfo.CommandLine
    $expectedCreation=$helperProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
    $isImporter=$command.Contains('hosted-root-import.ps1',[StringComparison]::OrdinalIgnoreCase)
    $isRecovery=$command.Contains('hosted-capability-recovery-worker.ps1',[StringComparison]::OrdinalIgnoreCase)
    $isUserProbe=$command.Contains('hosted-user-capability.ps1',[StringComparison]::OrdinalIgnoreCase)
    $expectedScript=if($isImporter){Join-Path $PSScriptRoot 'hosted-root-import.ps1'}elseif($isRecovery){Join-Path $PSScriptRoot 'hosted-capability-recovery-worker.ps1'}elseif($isUserProbe){Join-Path $PSScriptRoot 'hosted-user-capability.ps1'}else{$null}
    $scriptArgumentsProven=if($expectedScript){Test-HostedCapabilityCommandArguments $command @{'-File'=$expectedScript;'-RunId'=$RunId;'-SourceSHA'=$expectedSha}}else{$false}
    $expectedScriptHash=if($expectedScript){(Get-FileHash -LiteralPath $expectedScript -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}else{$null}
    if($isUserProbe){
        $expectedChild=$script:expectedUserChildIdentity
        if(!$expectedChild -or $clientProcessId -ne [uint32]$expectedChild.pid -or $expectedCreation -ne [long]$expectedChild.creationFileTimeUtc -or
           $clientSid -cne $expectedChild.sid -or [int]$helperProcess.SessionId -ne [int]$expectedChild.sessionId -or $expectedScriptHash -cne $expectedChild.scriptSHA256){
            throw 'User credential helper pipe caller did not match the exact supervisor-observed task child PID/creation/SID/session/script hash'
        }
    }
    $role=if($isUserProbe){'user-probe'}elseif($isRecovery){'recovery-worker'}elseif((Test-HostedCapabilityCommandArguments $command @{'-Mode'='RemoveOwned'})){'root-remove'}elseif((Test-HostedCapabilityCommandArguments $command @{'-Mode'='Import'})){'root-import'}else{throw 'Importer must have an explicit reviewed mode'}
    if($role -eq 'root-import'){
        $expectedImporter=$script:expectedRootImporter
        if(!$expectedImporter -or !$script:rootImporterHandle -or $script:rootImporterHandle.Wait(0) -or !$script:rootImporterParentHandle -or $script:rootImporterParentHandle.Wait(0) -or
           $clientProcessId -ne [uint32]$expectedImporter.pid -or $expectedCreation -ne [long]$expectedImporter.creationFileTimeUtc -or
           [uint32]$procInfo.ParentProcessId -ne [uint32]$expectedImporter.parent.pid -or $expectedScriptHash -cne $expectedImporter.scriptSHA256){throw 'Normal importer caller differs from the retained owner/native launch receipt and parent identity'}
    }
    if($role -eq 'recovery-worker'){
        $launcher=$script:expectedRecoveryLauncher
        if(!$launcher -or [uint32]$procInfo.ParentProcessId -ne [uint32]$launcher.pid -or
           !(Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$launcher.pid) -CreationFileTimeUtc ([long]$launcher.creationFileTimeUtc)).matches -or
           !(Test-HostedCapabilityProcessInJob -ProcessId $clientProcessId -JobName $recoveryJobName)){
            throw 'Recovery helper is not the exact live launcher child contained in its Recovery Job'
        }
        if($script:expectedRecoveryWorker -and ($script:expectedRecoveryWorker.pid -ne $clientProcessId -or $script:expectedRecoveryWorker.creationFileTimeUtc -ne $expectedCreation)){throw 'Recovery worker identity was replaced'}
        if(!$script:recoveryWorkerHandle){$script:recoveryWorkerHandle=Open-HostedCapabilityProcessIdentity -ProcessId $clientProcessId -CreationFileTimeUtc $expectedCreation}
        $script:expectedRecoveryWorker=@{pid=$clientProcessId;creationFileTimeUtc=$expectedCreation;sid=$clientSid;sessionId=[int]$helperProcess.SessionId}
        $published=Get-Content -LiteralPath $supervisorIdentityPath -Raw|ConvertFrom-Json
        $published|Add-Member -NotePropertyName recoveryWorker -NotePropertyValue $script:expectedRecoveryWorker -Force
        Write-HostedCapabilityAtomicJson -Path $supervisorIdentityPath -Value $published
    }
    if($role -eq 'root-remove'){
        $parent=$script:expectedRecoveryWorker
        if(!$parent -or !$script:recoveryWorkerHandle -or $script:recoveryWorkerHandle.Wait(0) -or [uint32]$procInfo.ParentProcessId -ne [uint32]$parent.pid -or
           !(Test-HostedCapabilityProcessInJob -ProcessId $clientProcessId -JobName $recoveryJobName)){
            throw 'RemoveOwned importer is not the exact live retained recovery worker child in its Recovery Job'
        }
    }
    if($clientSid -cne $expected.sid -or [int]$helperProcess.SessionId -ne $expected.sessionId -or
       (!$isImporter -and !$isRecovery -and !$isUserProbe) -or !$command.Contains($RunId,[StringComparison]::OrdinalIgnoreCase) -or
       !$command.Contains($expectedSha,[StringComparison]::OrdinalIgnoreCase) -or !$scriptArgumentsProven){
        throw 'Helper named-pipe caller identity did not match an exact allowlisted script, source SHA, run, SID and session'
    }
    $script:helperReader=[IO.StreamReader]::new($helperServer,[Text.UTF8Encoding]::new($false),$false,4096,$true)
    $script:helperWriter=[IO.StreamWriter]::new($helperServer,[Text.UTF8Encoding]::new($false),4096,$true);$script:helperWriter.AutoFlush=$true
    $script:helperProcessIdentity=@{pid=$clientProcessId;creationFileTimeUtc=$expectedCreation;sid=$clientSid;sessionId=[int]$helperProcess.SessionId;commandLine=$command;scriptPath=$expectedScript;scriptSHA256=$expectedScriptHash;role=$role}
    $script:helperProcess=$helperProcess
    $script:helperAccepted=$true
    $script:helperReadDeadlineCounter=[Math]::Min((Get-HelperDeadline),[Diagnostics.Stopwatch]::GetTimestamp()+30L*$frequency)
    Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='validated-helper-pipe-caller';processIdentity=$script:helperProcessIdentity;resourceIdentity=@{pipeName="Ticket569-$RunId-helper"}} | Out-Null
    $script:helperReadTask=$helperReader.ReadLineAsync()
    $true
}
function Assert-HostedPresentRootInterceptEligibility($Request,$Identity) {
    if($TestFault -cne 'present-root-recovery' -or $script:presentRootIntercept -or $script:helperPending -or
       $Identity.role -cne 'root-import' -or $Request.phase -cne 'intent' -or
       $Request.operation -cne 'remove-exact-owned-currentuser-root-certificate'){throw 'Present Root intercept not eligible'}
    $importer=$script:expectedRootImporter;$sessionFact=$script:authoritativeSessionFact
    $thumb=[string]$Request.resourceIdentity.thumbprint;$fact=$script:rootPreabsenceFacts[$thumb]
    $prior=$script:rootImportObservations[$thumb]
    if(!$importer -or !$sessionFact -or !$fact -or !$prior -or !$script:rootImporterHandle -or $script:rootImporterHandle.Wait(0) -or
       !$script:rootImporterParentHandle -or $script:rootImporterParentHandle.Wait(0) -or
       $Identity.pid -ne $importer.pid -or $Identity.creationFileTimeUtc -ne $importer.creationFileTimeUtc -or
       $Identity.scriptSHA256 -cne $importer.scriptSHA256 -or $Identity.scriptPath -cne $importer.scriptPath -or
       $Identity.sid -cne $importer.sid -or $Identity.sid -cne $sessionFact.sid -or [int]$Identity.sessionId -ne [int]$sessionFact.sessionId -or
       $fact.sid -cne $Identity.sid -or [int]$fact.sessionId -ne [int]$Identity.sessionId -or
       $Request.resourceIdentity.sid -cne $Identity.sid -or [int]$Request.resourceIdentity.sessionId -ne [int]$Identity.sessionId -or
       $Request.resourceIdentity.store -cne 'CurrentUser/Root' -or $thumb -notmatch '^[A-F0-9]{40}$' -or
       $Request.resourceIdentity.subject -cne "CN=Ticket569-Root-Prompt-$RunId" -or $Request.resourceIdentity.subject -cne $fact.subject -or
       !(Test-HostedBoolean $Request.precondition.exactMatch $true) -or !(Test-HostedBoolean $Request.precondition.importAttempted $true) -or
       [long]$Request.precondition.preabsenceSequence -ne [long]$fact.sequence -or [long]$fact.sequence -le 0 -or
       !$script:rootImportAttempts.ContainsKey($thumb) -or [long]$script:rootImportAttempts[$thumb] -le [long]$fact.sequence){throw 'Present Root intercept context or ownership mismatch'}
    foreach($number in @($Request.precondition.preabsenceSequence,$Request.resourceIdentity.sessionId,$prior.observed.exitCode,$prior.observed.process.pid,$prior.observed.process.creationFileTimeUtc,$prior.observed.process.sessionId)){
        if(!(Test-HostedInteger $number)){throw 'Present Root intercept external process/ownership receipt number malformed'}
    }
    $observed=$prior.observed
    if($prior.result -cne 'completed' -or !(Test-HostedBoolean $observed.waited $true) -or !(Test-HostedBoolean $observed.processExited $true) -or
       !(Test-HostedBoolean $observed.identityCreationRetained $true) -or $observed.exitCode -ne 0 -or !(Test-HostedBoolean $observed.imageMatchesExpected $true) -or
       !(Test-HostedBoolean $observed.timedOut $false) -or !(Test-HostedBoolean $observed.terminationRequested $false) -or
       $prior.processIdentity.pid -ne $Identity.pid -or $prior.processIdentity.creationFileTimeUtc -ne $Identity.creationFileTimeUtc -or
       !$observed.process -or $observed.process.sid -cne $Identity.sid -or $observed.process.sessionId -ne $Identity.sessionId -or
       $observed.process.thumbprint -cne $thumb -or [int]$observed.process.pid -le 0 -or [long]$observed.process.creationFileTimeUtc -le 0 -or
       [IO.Path]::GetFullPath($observed.process.executable) -cne [IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\certutil.exe'))){throw 'Present Root intercept has no successful exact retained certutil observation'}
    $replay=Read-HostedCapabilityLedger -Directory $runRoot -RunId $RunId -SourceSHA $expectedSha
    $owned=@($replay.mutations|Where-Object {$_.intent.operation -ceq 'import-exact-currentuser-root-certificate' -and $_.intent.sequence -eq $script:rootImportAttempts[$thumb] -and $_.observation.sequence -eq $prior.sequence})
    $pre=@($replay.events|Where-Object {$_.sequence -eq $fact.sequence -and $_.phase -ceq 'process' -and $_.operation -ceq 'helper-fact-currentuser-root-exact-thumbprint-preabsence' -and $_.observed.matchCount -eq 0 -and $_.observed.preexisting -eq $false -and $_.resourceIdentity.thumbprint -ceq $thumb})
    if(!$replay.valid -or !$replay.sessionFact -or $replay.sessionFact.ledgerSequence -ne $sessionFact.ledgerSequence -or
       $replay.sessionFact.profilePath -cne $sessionFact.profilePath -or $owned.Count -ne 1 -or $pre.Count -ne 1 -or
       $owned[0].observation.result -cne 'completed' -or $owned[0].intent.resourceIdentity.subject -cne $fact.subject){throw 'Present Root intercept facts do not replay from authoritative ledger'}
    $actualContext=Get-HostedObservedProfileContext $sessionFact.profilePath $sessionFact.stepName
    if(!$sessionFact.profileContext -or $actualContext.kind -cne $sessionFact.profileContext.kind -or $actualContext.volumeId -cne $sessionFact.profileContext.volumeId){throw 'Present Root intercept actual profile changed'}
}
function Try-HostedPresentRootIntercept($Request,$Identity) {
    if($TestFault -cne 'present-root-recovery' -or $Request.operation -cne 'remove-exact-owned-currentuser-root-certificate'){return $false}
    try {Assert-HostedPresentRootInterceptEligibility $Request $Identity}
    catch {
        $script:failure=$true
        Write-HostedCapabilityFailure -Ledger $ledger -Code 'present-root-exercise-intercept-refused' -Evidence @{errorType=$_.Exception.GetType().FullName;normalAcknowledgementUnchanged=$true}|Out-Null
        return $false
    }
    # A process event is not a deletion intent: the importer is still waiting
    # for authorization and the ledger gains no pending deletion mutation.
    $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='present-root-exercise-unapproved-cleanup-intercept';processIdentity=$Identity;resourceIdentity=$Request.resourceIdentity;observed=@{request=$Request;approved=$false;deliberateFailure=$true}}
    $script:presentRootIntercept=@{sequence=$event.sequence;importer=$script:expectedRootImporter;resource=$Request.resourceIdentity;preabsenceSequence=$script:rootPreabsenceFacts[[string]$Request.resourceIdentity.thumbprint].sequence;importSequence=$script:rootImportAttempts[[string]$Request.resourceIdentity.thumbprint];terminationRequested=$true;waited=$false;exitCode=$null;eligible=$false}
    $script:failure=$true
    Write-HostedCapabilityFailure -Ledger $ledger -Code 'present-root-exercise-deliberate-importer-stop' -Evidence @{interceptSequence=$event.sequence;approvedDeletion=$false}|Out-Null
    try {
        $script:rootImporterHandle.Terminate(137)
        $waited=$script:rootImporterHandle.Wait((Get-HostedCapabilityWaitBudget $deadlines.work $frequency 5000))
        $script:presentRootIntercept.waited=[bool]$waited
        if(!$waited){throw 'Present Root importer retained handle did not exit'}
        $script:presentRootIntercept.exitCode=$script:rootImporterHandle.ExitCode
        $script:presentRootIntercept.eligible=($script:rootImporterHandle.ExitCode -eq 137)
        Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='present-root-exercise-importer-stop-observed';processIdentity=$Identity;resourceIdentity=$Request.resourceIdentity;observed=$script:presentRootIntercept}|Out-Null
        Close-HostedCapabilityHelperEndpoint -Reopen
        return $true # deliberately no acknowledgement
    } catch {
        $script:presentRootIntercept.eligible=$false
        Write-HostedCapabilityFailure -Ledger $ledger -Code 'present-root-exercise-importer-stop-unproved' -Evidence @{errorType=$_.Exception.GetType().FullName;intercept=$script:presentRootIntercept}|Out-Null
        return $false # remaining live importer gets ordinary cleanup authorization
    }
}
function Get-HostedPresentRootAdmission([long]$Now) {
    $components=@{ownerShutdown=100;logoff=15;unload=40;restore=180;deletions=30;finalWaits=20}
    $recoveryComponents=@{startup=30;jobAssignment=5;health=60;removeStart=30;helper=30;resultExit=10}
    $reserve=385;$estimate=165;$margin=60
    $remaining=if($frequency -gt 0){($deadlines.cleanup-$Now)/[double]$frequency}else{-1}
    @{allowed=($frequency -gt 0 -and $Now -lt $deadlines.work -and $remaining -ge ($reserve+$estimate+$margin));counter=$Now;workDeadline=$deadlines.work;cleanupDeadline=$deadlines.cleanup;remainingSeconds=$remaining;cleanupReserveEstimateSeconds=$reserve;cleanupEstimateComponents=$components;recoveryEstimateSeconds=$estimate;recoveryEstimateComponents=$recoveryComponents;marginSeconds=$margin;estimatesNotGuarantees=$true;recoveryCutoff=($deadlines.cleanup-$reserve*$frequency)}
}
function Assert-HostedPresentRootBarrier($Request) {
    $intercept=$script:presentRootIntercept;$fact=$script:authoritativeSessionFact
    if($TestFault -cne 'present-root-recovery' -or $script:presentRootBarrier -or !$intercept -or !$intercept.eligible -or
       !$intercept.waited -or $intercept.exitCode -ne 137 -or $pending -or $script:helperPending -or !$fact -or
       !(Test-HostedBoolean $Request.observed.observationAcknowledged $true) -or !(Test-HostedBoolean $Request.observed.deliberateFailedPrompt $true)){throw 'Present Root barrier eligibility or pending mutation refused'}
    $replay=Read-HostedCapabilityLedger -Directory $runRoot -RunId $RunId -SourceSHA $expectedSha
    $failed=@($replay.mutations|Where-Object {$_.intent.operation -ceq 'run-pinned-cua-currentuser-root-prompt' -and $_.observation.result -ceq 'failed' -and $_.intent.resourceIdentity.thumbprint -ceq $intercept.resource.thumbprint -and $_.intent.resourceIdentity.sid -ceq $fact.sid -and $_.intent.resourceIdentity.sessionId -eq $fact.sessionId})
    if(!$replay.valid -or $replay.pending.Count -ne 0 -or $failed.Count -ne 1 -or !$replay.sessionFact -or
       $replay.sessionFact.ledgerSequence -ne $fact.ledgerSequence -or $replay.sessionFact.profilePath -cne $fact.profilePath){throw 'Present Root barrier acknowledged failed mutation/ledger not settled'}
    $detail=Get-Content -LiteralPath (Join-Path $EvidenceDirectory 'current-user-root-prompt.json') -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $reply=$Request.observed.ownerReply;$sessionHost=$Request.observed.prompt.sessionHost
    if(!(Test-HostedPresentRootFailedPrompt $detail) -or $detail.schema -cne 'ticket569-hosted-cua-prompt-v1' -or
       [int]$detail.importLaunchReceipt.pid -ne [int]$intercept.importer.pid -or $reply.exitCode -ne 1 -or !(Test-HostedBoolean $reply.retained $true) -or
       !$script:presentRootPromptIdentity -or $reply.process.pid -ne $script:presentRootPromptIdentity.pid -or $reply.process.creationFileTimeUtc -ne $script:presentRootPromptIdentity.creationFileTimeUtc -or
       !(Test-HostedBoolean $sessionHost.retained $true) -or $sessionHost.process.pid -ne $script:presentRootPromptIdentity.pid -or $sessionHost.process.creationFileTimeUtc -ne $script:presentRootPromptIdentity.creationFileTimeUtc -or
       (ConvertTo-Json $reply.result -Depth 32 -Compress) -cne (ConvertTo-Json $detail -Depth 32 -Compress)){throw 'Present Root barrier exact failed owner/CUA reply missing'}
    $attached=Get-Content -LiteralPath (Join-Path $fact.profilePath "root-import-attached-$RunId.json") -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $exited=Get-Content -LiteralPath (Join-Path $fact.profilePath "root-import-exit-$RunId.json") -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    foreach($number in @($attached.PID,$attached.CreationFileTimeUtc,$exited.PID,$exited.CreationFileTimeUtc,$exited.ExitCode,$reply.exitCode,$reply.process.pid,$reply.process.creationFileTimeUtc)){
        if(!(Test-HostedInteger $number)){throw 'Present Root barrier external process receipt has a missing/malformed number'}
    }
    if(!(Test-HostedBoolean $attached.HandleRetained $true) -or !(Test-HostedBoolean $exited.HandleRetained $true) -or
       $attached.PID -ne $intercept.importer.pid -or $exited.PID -ne $intercept.importer.pid -or
       $attached.CreationFileTimeUtc -ne $intercept.importer.creationFileTimeUtc -or $exited.CreationFileTimeUtc -ne $intercept.importer.creationFileTimeUtc -or
       $exited.ExitCode -ne 137 -or !$script:rootImporterHandle.Wait(0) -or $script:rootImporterHandle.ExitCode -ne 137 -or
       !$script:rootImporterParentHandle -or $script:rootImporterParentHandle.Wait(0) -or
       !(Test-HostedCapabilityCommandArguments $attached.CommandLine @{'-File'=$intercept.importer.scriptPath;'-RunId'=$RunId;'-SourceSHA'=$expectedSha;'-Mode'='Import'})){throw 'Present Root barrier retained observer/importer identity mismatch'}
    $actual=Get-HostedObservedProfileContext $fact.profilePath $fact.stepName
    if(!$fact.profileContext -or $actual.kind -cne $fact.profileContext.kind -or $actual.volumeId -cne $fact.profileContext.volumeId){throw 'Present Root barrier session profile context changed'}
    if(!$ownerProcess -or $ownerProcess.Wait(0) -or !(Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$ownerIdentity.pid) -CreationFileTimeUtc ([long]$ownerIdentity.creationFileTimeUtc)).matches){throw 'Present Root barrier retained owner lost'}
    # The owner serializes requests. Its own successful health reply proves the
    # previous failed prompt-run reply is complete; no watcher replacement allowed.
    $health=Invoke-SessionOwnerControl (New-SessionOwnerRequest 'health' @{requirePromptService=$true}) 30000
    if(!$health.ok -or !(Test-HostedBoolean $health.result.healthy $true) -or !(Test-HostedBoolean $health.result.connected $true) -or $health.result.state -cne 'connected' -or
       $health.result.session -cne 'ticket569' -or $health.result.ownerPID -ne $ownerIdentity.pid -or !(Test-HostedBoolean $health.result.promptServiceAlive $true) -or
       $health.result.promptServiceIdentity.pid -ne $script:presentRootPromptIdentity.pid -or $health.result.promptServiceIdentity.creationFileTimeUtc -ne $script:presentRootPromptIdentity.creationFileTimeUtc -or
       !(Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$health.result.promptServiceIdentity.pid) -CreationFileTimeUtc ([long]$health.result.promptServiceIdentity.creationFileTimeUtc)).matches){throw 'Present Root barrier original healthy owner/native MCP unavailable'}
    $admission=Get-HostedPresentRootAdmission ([Diagnostics.Stopwatch]::GetTimestamp())
    if(!$admission.allowed){throw 'Present Root barrier insufficient absolute budget or J+21 reached'}
    @{admission=$admission;observerAttached=$attached;observerExit=$exited;failedPrompt=$detail;ownerHealth=$health;sourceSHA=$expectedSha;runId=$RunId;context=$fact}
}
function Process-HostedPresentRootBarrier($Request) {
    try {$proof=Assert-HostedPresentRootBarrier $Request}
    catch {
        $script:failure=$true
        Write-HostedCapabilityFailure -Ledger $ledger -Code 'present-root-exercise-barrier-refused' -Evidence @{errorType=$_.Exception.GetType().FullName}|Out-Null
        $writer.WriteLine((ConvertTo-Json -Compress @{acknowledged=$true;requestId=$Request.requestId;sequence=$ledger.Sequence;status='refused'}))
        return
    }
    $script:presentRootBarrier=@{accepted=$true;proof=$proof;workerStopRequested=$true;workerWaited=$false;workerExit=$null;workerJobEmpty=$false}
    $script:exerciseRecoveryCutoff=[long]$proof.admission.recoveryCutoff
    Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='present-root-exercise-barrier-accepted';processIdentity=$workerIdentity;observed=$script:presentRootBarrier}|Out-Null
    # Never acknowledge acceptance: the live worker must not run outer cleanup.
    $job.Terminate(137)
    $script:presentRootBarrier.workerWaited=$worker.Wait((Get-HostedCapabilityWaitBudget $deadlines.work $frequency 5000))
    if(!$script:presentRootBarrier.workerWaited){throw 'Present Root barrier worker retained exit unproved'}
    $script:presentRootBarrier.workerExit=$worker.ExitCode
    $script:presentRootBarrier.workerJobEmpty=($job.ActiveProcesses -eq 0)
    if($worker.ExitCode -ne 137 -or !$script:presentRootBarrier.workerJobEmpty){throw 'Present Root barrier worker Job termination incomplete'}
    Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='present-root-exercise-worker-stop-observed';processIdentity=$workerIdentity;observed=$script:presentRootBarrier}|Out-Null
}
function Assert-HostedExerciseRecoveryCutoff {
    if($TestFault -ceq 'present-root-recovery' -and $script:exerciseRecoveryCutoff -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $script:exerciseRecoveryCutoff){throw 'Present Root exercise recovery cutoff reached; owned cleanup reserve preserved'}
}

function Process-HostedCapabilityHelperRequest([string] $line) {
    if($line.Length -gt 1048576){throw 'Helper protocol frame exceeded one-megabyte limit'}
    $request=ConvertFrom-Json -InputObject $line -ErrorAction Stop
    if($request.schema -cne 'ticket569-supervisor-request-v1' -or $request.runId -cne $RunId -or $request.sourceSHA -cne $expectedSha -or !$request.requestId){throw 'Helper protocol identity/schema mismatch'}
    $identity=$script:helperProcessIdentity
    $processCheck=Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$identity.pid) -CreationFileTimeUtc ([long]$identity.creationFileTimeUtc)
    if(!$processCheck.matches -or $request.resourceIdentity.sid -cne $identity.sid -or [int]$request.resourceIdentity.sessionId -ne $identity.sessionId){throw 'Helper request was not bound to its validated process and exact user context'}
    if($request.phase -eq 'fact'){
        $factsByRole=@{'user-probe'=@();'root-import'=@('currentuser-root-exact-thumbprint-preabsence');'root-remove'=@();'recovery-worker'=@('recovery-root-removal-ownership','recovery-run-credential-state','session-host-health')}
        if($request.name -cnotin $factsByRole[$identity.role]){throw 'Helper fact is not allowed for its authenticated caller role'}
        $responseExtra=@{}
        if($request.name -ceq 'currentuser-root-exact-thumbprint-preabsence' -and $request.resourceIdentity.store -ceq 'CurrentUser/Root' -and
           $request.resourceIdentity.thumbprint -match '^[A-Fa-f0-9]{40}$' -and $request.observed.matchCount -eq 0 -and !$request.observed.preexisting){
            $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation=('helper-fact-'+$request.name);resourceIdentity=$request.resourceIdentity;observed=$request.observed;processIdentity=$identity}
            $script:rootPreabsenceFacts[[string]$request.resourceIdentity.thumbprint]=@{sequence=[long]$event.sequence;subject=[string]$request.resourceIdentity.subject;sid=$identity.sid;sessionId=$identity.sessionId}
        } elseif($request.name -ceq 'recovery-root-removal-ownership' -and
            $request.resourceIdentity.store -ceq 'CurrentUser/Root' -and $request.resourceIdentity.thumbprint -match '^[A-Fa-f0-9]{40}$'){
            if($identity.scriptPath -cne (Join-Path $PSScriptRoot 'hosted-capability-recovery-worker.ps1')){throw 'Only the exact recovery worker may request ledger-owned RemoveOwned facts'}
            $thumb=[string]$request.resourceIdentity.thumbprint
            $fact=$script:rootPreabsenceFacts[$thumb]
            if(!$fact -or !$script:rootImportAttempts.ContainsKey($thumb) -or
               $request.resourceIdentity.subject -cne $fact.subject -or $fact.sid -cne $identity.sid -or [int]$fact.sessionId -ne $identity.sessionId){
                throw 'RemoveOwned facts lack this exact session ledger preabsence and import-attempt pair'
            }
            $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='helper-fact-recovery-root-removal-ownership';resourceIdentity=$request.resourceIdentity;observed=@{preexisting=$false;importAttempted=$true;preabsenceSequence=$fact.sequence;importAttemptSequence=[long]$script:rootImportAttempts[$thumb]};processIdentity=$identity}
            $responseExtra.rootOwnership=@{preexisting=$false;importAttempted=$true;preabsenceSequence=[long]$fact.sequence;importAttemptSequence=[long]$script:rootImportAttempts[$thumb]}
        } elseif($request.name -ceq 'recovery-run-credential-state' -and
            $request.resourceIdentity.target -ceq "ticket569-hosted-capability-$RunId" -and
            $request.observed.credReadErrorCode -in @(0,1168)){
            $owned=$script:ownedCredentialTargets.ContainsKey([string]$request.resourceIdentity.target)
            if([int]$request.observed.credReadErrorCode -eq 0 -and !$owned){throw 'Present recovery credential has no acknowledged run-owned write intent'}
            $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation=('helper-fact-'+$request.name);resourceIdentity=$request.resourceIdentity;observed=$request.observed;processIdentity=$identity}
            $responseExtra.credentialWriteOwned=[bool]$owned
        } elseif($request.name -ceq 'session-host-health' -and
            $request.resourceIdentity.sid -ceq $identity.sid -and [int]$request.resourceIdentity.sessionId -eq $identity.sessionId -and
            $request.observed.phase -in @('recovery-before-root-cleanup','recovery-after-root-cleanup')){
            $healthReceipt=$null;$healthError=$null
            try {
                $fact=$script:authoritativeSessionFact
                if(!$fact -or $fact.sid -cne $identity.sid -or [int]$fact.sessionId -ne [int]$identity.sessionId){throw 'Recovery health lacks the exact acknowledged helper session'}
                $actualContext=Get-HostedObservedProfileContext $fact.profilePath $fact.stepName
                if(!$fact.profileContext -or $actualContext.kind -cne $fact.profileContext.kind -or $actualContext.volumeId -cne $fact.profileContext.volumeId){throw 'Recovery health profile volume/kind changed'}
                $healthOperation=Invoke-SupervisorRecoveryMutation 'ensure-exact-session-removal-only-cua' @{owner=$ownerIdentity;sid=$fact.sid;sessionId=$fact.sessionId;profileContext=$actualContext} @{existingConnectionOnly=$true;noLoginOrImportReplay=$true} {
                    Invoke-SessionOwnerControl (New-SessionOwnerRequest 'health' @{requirePromptService=$true;allowRecoveryWatcher=$true;expectedSID=$fact.sid;expectedSessionId=$fact.sessionId;expectedProfilePath=$fact.profilePath;expectedVolumeId=$actualContext.volumeId;expectedProfileKind=$actualContext.kind}) 30000
                }
                $healthReceipt=$healthOperation.result
                if(!$healthReceipt.ok -or !$healthReceipt.result.healthy -or !$healthReceipt.result.promptServiceAlive -or
                   $healthReceipt.result.session -cne 'ticket569') {throw 'session-host health receipt was incomplete'}
            } catch {$healthError=$_.Exception.GetType().FullName;$script:failure=$true}
            $health=@{healthy=(!$healthError);phase=[string]$request.observed.phase;ownerProcess=$ownerIdentity;promptService=if($healthReceipt){$healthReceipt.result.promptServiceIdentity}else{$null};errorType=$healthError}
            $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='helper-fact-session-host-health';resourceIdentity=$request.resourceIdentity;observed=$health;processIdentity=$identity}
            $responseExtra.sessionHostHealth=$health
            if($healthError){
                Write-HostedCapabilityFailure -Ledger $ledger -Code 'currentuser-root-session-host-lost-during-recovery' -Evidence $health | Out-Null
                $promptEvidencePath=Join-Path $EvidenceDirectory 'current-user-root-prompt.json'
                if(Test-Path -LiteralPath $promptEvidencePath){
                    try{$promptEvidence=Get-Content -LiteralPath $promptEvidencePath -Raw | ConvertFrom-Json -ErrorAction Stop;$promptEvidence.status='unverified';$promptEvidence.reason='The retained session-host UIA or original RDP bridge was not healthy during same-session recovery.';Write-HostedCapabilityAtomicJson -Path $promptEvidencePath -Value $promptEvidence}catch{$script:failure=$true}
                }
                $workerFinalPath=Join-Path $EvidenceDirectory 'hosted-capability-final.json'
                if(Test-Path -LiteralPath $workerFinalPath){
                    try{$workerFinal=Get-Content -LiteralPath $workerFinalPath -Raw | ConvertFrom-Json -ErrorAction Stop;if($workerFinal.rootPrompt){$workerFinal.rootPrompt.status='unverified';$workerFinal.rootPrompt.reason='The retained session-host UIA or original RDP bridge was not healthy during same-session recovery.';Write-HostedCapabilityAtomicJson -Path $workerFinalPath -Value $workerFinal}}catch{$script:failure=$true}
                }
            }
        } else {throw 'Helper fact did not prove an allowed exact CurrentUser Root or run-scoped credential observation'}
        $script:helperWriter.WriteLine((ConvertTo-Json -InputObject (@{acknowledged=$true;requestId=$request.requestId;sequence=$event.sequence}+ $responseExtra) -Compress))
        $script:helperReadDeadlineCounter=[Math]::Min((Get-HelperDeadline),[Diagnostics.Stopwatch]::GetTimestamp()+30L*$frequency)
        return
    }
    if($request.phase -eq 'intent'){
        if(Try-HostedPresentRootIntercept $request $identity){return}
        if($helperPending){throw 'Helper sent a mutation intent before observing the prior mutation'}
        $null=Assert-HostedCapabilityHelperOperation -Request $request -Role $identity.role
        $allowed=@('seed-exact-currentuser-synthetic-credential','delete-exact-currentuser-synthetic-credential','recover-delete-exact-currentuser-synthetic-credential','write-owned-run-credential','read-owned-run-credential','delete-owned-run-credential','verify-owned-run-credential-absence','import-exact-currentuser-root-certificate','remove-exact-owned-currentuser-root-certificate','recovery-delete-exact-currentuser-synthetic-credential','recovery-remove-exact-owned-currentuser-root-certificate')
        if($request.operation -notin $allowed){throw 'Helper requested a mutation operation outside the explicit CurrentUser credential/root allowlist'}
        if($request.operation -in @('seed-exact-currentuser-synthetic-credential','write-owned-run-credential','read-owned-run-credential','delete-exact-currentuser-synthetic-credential','delete-owned-run-credential','verify-owned-run-credential-absence','recover-delete-exact-currentuser-synthetic-credential','recovery-delete-exact-currentuser-synthetic-credential')){
            if($request.resourceIdentity.target -cne "ticket569-hosted-capability-$RunId"){throw 'Credential helper request lacks the exact run-scoped target'}
            if($request.operation -in @('seed-exact-currentuser-synthetic-credential','write-owned-run-credential') -and ($request.precondition.credentialAbsent -ne $true -or [int]$request.precondition.credReadError -ne 1168)){throw 'Credential write intent lacks exact pre-mutation CredRead 1168 evidence'}
            if($request.operation -in @('delete-exact-currentuser-synthetic-credential','delete-owned-run-credential','verify-owned-run-credential-absence','recover-delete-exact-currentuser-synthetic-credential','recovery-delete-exact-currentuser-synthetic-credential') -and !$script:ownedCredentialTargets.ContainsKey([string]$request.resourceIdentity.target)){throw 'Credential deletion/absence intent lacks a supervisor-owned run-scoped write intent'}
        }
        if($request.operation -match 'root-certificate' -and ($request.resourceIdentity.store -cne 'CurrentUser/Root' -or $request.resourceIdentity.thumbprint -notmatch '^[A-Fa-f0-9]{40}$')){throw 'Root mutation identity lacks exact store/thumbprint'}
        if($request.operation -eq 'import-exact-currentuser-root-certificate'){
            $fact=$script:rootPreabsenceFacts[[string]$request.resourceIdentity.thumbprint]
            if(!$fact -or [long]$request.precondition.preabsenceSequence -ne [long]$fact.sequence -or $request.resourceIdentity.subject -cne $fact.subject){throw 'Root import lacks the supervisor-acknowledged exact-thumbprint/subject preabsence fact'}
        }
        if($request.operation -eq 'remove-exact-owned-currentuser-root-certificate'){
            $fact=$script:rootPreabsenceFacts[[string]$request.resourceIdentity.thumbprint]
            if(!$script:rootImportAttempts.ContainsKey([string]$request.resourceIdentity.thumbprint) -or !$request.precondition.importAttempted -or !$fact -or $request.resourceIdentity.subject -cne $fact.subject){throw 'Root cleanup lacks a supervisor-acknowledged exact import attempt/subject'}
        }
        if($request.operation -eq 'recovery-remove-exact-owned-currentuser-root-certificate'){
            $thumb=[string]$request.resourceIdentity.thumbprint
            $fact=$script:rootPreabsenceFacts[$thumb]
            if(!$script:rootImportAttempts.ContainsKey($thumb) -or !$fact -or $request.resourceIdentity.subject -cne $fact.subject -or !$request.precondition.exactSubjectMatch){throw 'Recovery Root cleanup lacks supervisor-acknowledged preabsence, import attempt, exact thumbprint and subject match'}
        }
        if($request.operation -in @('seed-exact-currentuser-synthetic-credential','write-owned-run-credential')){
            $script:ownedCredentialTargets[[string]$request.resourceIdentity.target]=$true
        }
        if($request.operation -eq 'recovery-delete-exact-currentuser-synthetic-credential' -and !$script:ownedCredentialTargets.ContainsKey([string]$request.resourceIdentity.target)){throw 'Recovery credential cleanup lacks a supervisor-acknowledged run-scoped credential write'}
        $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{requestId=$request.requestId;phase='intent';operation=$request.operation;resourceIdentity=$request.resourceIdentity;precondition=$request.precondition;processIdentity=$identity}
        if($request.operation -eq 'import-exact-currentuser-root-certificate'){$script:rootImportAttempts[[string]$request.resourceIdentity.thumbprint]=[long]$event.sequence}
        $script:helperPending=@{requestId=$request.requestId;operation=$request.operation;resourceIdentity=(ConvertTo-Json -InputObject $request.resourceIdentity -Compress -Depth 32);phase='intent'}
        $helperAllowance=if($request.operation -eq 'import-exact-currentuser-root-certificate'){5L*60L}else{30L}
        $script:helperReadDeadlineCounter=[Math]::Min((Get-HelperDeadline),[Diagnostics.Stopwatch]::GetTimestamp()+$helperAllowance*$frequency)
        $script:helperWriter.WriteLine((ConvertTo-Json -InputObject @{acknowledged=$true;requestId=$request.requestId;sequence=$event.sequence} -Compress))
        return
    }
    if($request.phase -eq 'observation'){
        if(!$helperPending -or $helperPending.requestId -cne $request.requestId -or $helperPending.operation -cne $request.operation){throw 'Helper mutation observation did not match its durable intent'}
        if($helperPending.resourceIdentity -cne (ConvertTo-Json -InputObject $request.resourceIdentity -Compress -Depth 32)){throw 'Helper mutation observation resource identity differed from its durable intent'}
        if($request.operation -eq 'import-exact-currentuser-root-certificate' -and $request.result -ceq 'completed'){
            $certutil=$request.observed.process
            $expectedCertutil=[IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\certutil.exe'))
            if(!$certutil -or [int]$certutil.pid -le 0 -or [long]$certutil.creationFileTimeUtc -le 0 -or
               [IO.Path]::GetFullPath([string]$certutil.executable) -cne $expectedCertutil -or
               [string]$certutil.thumbprint -cne [string]$request.resourceIdentity.thumbprint -or
               [string]$certutil.sid -cne [string]$identity.sid -or [int]$certutil.sessionId -ne [int]$identity.sessionId -or
               $request.observed.waited -ne $true -or $request.observed.identityCreationRetained -ne $true -or
               $request.observed.processExited -ne $true -or !$request.observed.PSObject.Properties['exitCode']){
                throw 'Certutil mutation observation lacks the exact exited image, creation, thumbprint, SID, session, and retained-handle evidence'
            }
            Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='exact-certutil-import-process-exit-observed';processIdentity=$certutil;resourceIdentity=@{thumbprint=$request.resourceIdentity.thumbprint;store='CurrentUser/Root'};observed=@{waited=$true;exitCode=[int]$request.observed.exitCode;retainedHandle=$true;imageMatchesExpected=[bool]$request.observed.imageMatchesExpected;timedOut=[bool]$request.observed.timedOut;terminationRequested=[bool]$request.observed.terminationRequested;validatedAgainstPinnedImporter=$identity}} | Out-Null
        }
        $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{requestId=$request.requestId;phase='observation';operation=$request.operation;resourceIdentity=$request.resourceIdentity;observed=$request.observed;result=$request.result;processIdentity=$identity}
        if($request.operation -ceq 'import-exact-currentuser-root-certificate'){$script:rootImportObservations[[string]$request.resourceIdentity.thumbprint]=$event}
        $script:helperPending=$null
        if($request.result -ne 'completed'){$script:failure=$true}
        $script:helperWriter.WriteLine((ConvertTo-Json -InputObject @{acknowledged=$true;requestId=$request.requestId;sequence=$event.sequence} -Compress))
        $script:helperReadDeadlineCounter=[Math]::Min((Get-HelperDeadline),[Diagnostics.Stopwatch]::GetTimestamp()+30L*$frequency)
        return
    }
    throw 'Helper protocol phase is not permitted'
}
function Drain-HostedCapabilityFinishingHelpers([switch]$StopRemaining) {
    foreach($participant in @($script:finishingHelpers)){
        $exited=$participant.Process.WaitForExit(0)
        if(!$exited -and ($StopRemaining -or [Diagnostics.Stopwatch]::GetTimestamp() -ge $participant.DeadlineCounter)){
            $script:failure=$true
            Write-HostedCapabilityFailure -Ledger $ledger -Code 'finishing-helper-exit-deadline' -Evidence $participant.Identity|Out-Null
            $null=Stop-HostedCapabilityProcessIdentity -ProcessId ([uint32]$participant.Identity.pid) -CreationFileTimeUtc ([long]$participant.Identity.creationFileTimeUtc) -WaitMilliseconds (Get-HostedCapabilityWaitBudget $participant.DeadlineCounter $frequency 1000)
            $exited=$participant.Process.WaitForExit(0)
        }
        if($exited){
            Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='validated-helper-process-exit-observed';processIdentity=$participant.Identity;observed=@{waitedHandle=$true;exitCode=$participant.Process.ExitCode;identityMatched=$true;afterConnectionClose=$true}}|Out-Null
            if($participant.Process.ExitCode -ne 0){$script:failure=$true;Write-HostedCapabilityFailure -Ledger $ledger -Code 'finishing-helper-nonzero-exit' -Evidence $participant.Identity|Out-Null}
            $participant.Process.Dispose();$null=$script:finishingHelpers.Remove($participant)
        }elseif($StopRemaining){throw 'Retained finishing helper lifetime remains unproved'}
    }
}
function Pump-HostedCapabilityHelper {
    Drain-HostedCapabilityFinishingHelpers
    if(!$helperServer.IsConnected -and $script:helperAcceptTask -and $script:helperAcceptTask.IsCompleted){
        if($script:helperAcceptTask.IsFaulted){throw 'Helper pipe accept failed'}
        $null=Accept-HostedCapabilityHelper
    }
    if($helperServer.IsConnected -and $script:helperReadDeadlineCounter -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $script:helperReadDeadlineCounter){
        $identity=$script:helperProcessIdentity
        if($identity){$null=Stop-HostedCapabilityProcessIdentity -ProcessId ([uint32]$identity.pid) -CreationFileTimeUtc ([long]$identity.creationFileTimeUtc) -WaitMilliseconds (Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 3000)}
        throw 'Helper protocol caller exceeded its bounded request/observation deadline'
    }
    if($helperServer.IsConnected -and $script:helperReadTask -and $script:helperReadTask.IsCompleted){
        $helperLine=$script:helperReadTask.Result
        if($null -eq $helperLine){
            Close-HostedCapabilityHelperEndpoint -Reopen -AllowRecoveryHandoff
        } else {
            Process-HostedCapabilityHelperRequest $helperLine
            $script:helperReadTask=if($script:helperReader){$script:helperReader.ReadLineAsync()}else{$null}
        }
    }
}
function Close-HostedCapabilityHelperEndpoint([switch]$Reopen,[switch]$AllowRecoveryHandoff) {
    if($script:helperPending){
        $script:failure=$true
        Write-HostedCapabilityFailure -Ledger $ledger -Code 'helper-observation-missing-at-endpoint-close' -Evidence $script:helperPending|Out-Null
        # Clear connection-local state only. Its durable pending intent remains
        # replayable and prevents a complete cleanup verdict without proof.
    }
    if($script:helperProcess -and $script:helperProcessIdentity){
        $identity=$script:helperProcessIdentity
        $transferred=$false
        try{
            # The authenticated recovery worker disconnects while its RemoveOwned
            # child uses this single-client pipe, then reconnects. Its independent
            # native handle remains retained until final recovery/job exit proof.
            $expected=$script:expectedRecoveryWorker
            $handoff=$AllowRecoveryHandoff -and !$script:helperPending -and $identity.role -ceq 'recovery-worker' -and
                $expected -and [int]$identity.pid -eq [int]$expected.pid -and
                [long]$identity.creationFileTimeUtc -eq [long]$expected.creationFileTimeUtc -and
                $identity.sid -ceq $expected.sid -and [int]$identity.sessionId -eq [int]$expected.sessionId -and
                $script:recoveryWorkerHandle -and !$script:recoveryWorkerHandle.Wait(0)
            if($handoff){
                Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='validated-recovery-helper-connection-handoff';processIdentity=$identity;observed=@{connectionClosed=$true;retainedParticipantLive=$true;processExitProven=$false;pendingMutation=$false}}|Out-Null
            }elseif($AllowRecoveryHandoff -and !$script:helperPending -and $identity.role -cin @('user-probe','root-import','root-remove')){
                $absolute=if($identity.role -ceq 'root-remove'){$deadlines.cleanup}else{$deadlines.work}
                $finishBy=[Math]::Min($absolute,[Diagnostics.Stopwatch]::GetTimestamp()+10L*$frequency)
                $script:finishingHelpers.Add(@{Identity=$identity;Process=$script:helperProcess;DeadlineCounter=$finishBy})
                $transferred=$true
                Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='validated-helper-connection-closed-finishing-retained';processIdentity=$identity;observed=@{processExitProven=$false;deadlineCounter=$finishBy}}|Out-Null
            }else{
                if($AllowRecoveryHandoff -and !$script:helperPending -and $identity.role -ceq 'recovery-worker' -and !$script:helperProcess.WaitForExit(0)){
                    $script:failure=$true
                    Write-HostedCapabilityFailure -Ledger $ledger -Code 'recovery-helper-handoff-identity-unproved' -Evidence @{process=$identity;expected=$expected}|Out-Null
                }
                if(!$script:helperProcess.WaitForExit((Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 3000))){
                    $stopped=Stop-HostedCapabilityProcessIdentity -ProcessId ([uint32]$identity.pid) -CreationFileTimeUtc ([long]$identity.creationFileTimeUtc) -WaitMilliseconds (Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 3000)
                    if(!$stopped.terminated){throw 'Closing helper endpoint lacks exact retained process exit'}
                }
                if(!$script:helperProcess.WaitForExit(0)){throw 'Closing helper process remains live'}
                Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='validated-helper-process-exit-observed';processIdentity=$identity;observed=@{waitedHandle=$true;exitCode=$script:helperProcess.ExitCode;identityMatched=$true}}|Out-Null
            }
        }catch{$script:failure=$true;Write-HostedCapabilityFailure -Ledger $ledger -Code 'helper-endpoint-process-exit-unproved' -Evidence @{errorType=$_.Exception.GetType().FullName;process=$identity}|Out-Null}
        finally{if(!$transferred){$script:helperProcess.Dispose()}}
    }
    try{
        if($script:helperServer){Close-HostedCapabilitySupervisorConnection -Connection ([pscustomobject]@{Reader=$script:helperReader;Writer=$script:helperWriter;Pipe=$script:helperServer;Closed=$false})}
    }finally{
        $script:helperServer=$null;$script:helperReader=$null;$script:helperWriter=$null;$script:helperProcess=$null;$script:helperProcessIdentity=$null;$script:helperReadTask=$null;$script:helperPending=$null;$script:helperReadDeadlineCounter=$null;$script:helperAcceptTask=$null
        if($Reopen){
            $target=if($script:authoritativeSessionFact){[string]$script:authoritativeSessionFact.sid}else{$null}
            $script:helperServer=New-HostedCapabilityHelperServer $target
            $script:helperAcceptTask=$script:helperServer.WaitForConnectionAsync()
        }
    }
}
function Stop-HostedSessionOwnerPlanned {
    if($script:ownerCleanupComplete){return $true}
    if(!$ownerProcess){return $false}
    try {
        $shutdown=Invoke-SessionOwnerControl (New-SessionOwnerRequest 'shutdown') 90000
        if(!$shutdown.ok -or !$shutdown.result.disconnected -or !$shutdown.result.planned -or !$shutdown.result.daemonStopped -or !$shutdown.result.privateRuntimeRemoved -or
           !$shutdown.result.promptService.stopped -or
           ($shutdown.result.promptService.present -and (!$shutdown.result.promptService.waitedHandle -or !$shutdown.result.promptService.process.creationFileTimeUtc -or $null -eq $shutdown.result.promptService.exitCode))){
            throw 'session owner shutdown receipt did not prove planned disconnect, daemon/runtime cleanup, and retained session-host MCP process exit'
        }
        if(!$ownerProcess.Wait((Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 10000)) -or $ownerProcess.ExitCode -ne 0){throw 'session owner did not exit successfully after shutdown'}
        if($ownerJob.ActiveProcesses -ne 0){throw 'session-owner Job Object still contains active processes after normal shutdown'}
        if($shutdown.result.promptService.present){Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='retained-session-host-mcp-exit-observed';processIdentity=$shutdown.result.promptService.process;observed=@{waitedHandle=$shutdown.result.promptService.waitedHandle;exitCode=$shutdown.result.promptService.exitCode;retainedJob=$ownerJobName}} | Out-Null}
        Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='session-owner-cleanup-verified';processIdentity=$ownerIdentity;observed=@{exitCode=$ownerProcess.ExitCode;activeProcesses=$ownerJob.ActiveProcesses;runtimeRemoved=$shutdown.result.privateRuntimeRemoved;daemonStopped=$shutdown.result.daemonStopped;promptServiceStopped=$shutdown.result.promptService.stopped;beforeRecoveryLogoff=$true}} | Out-Null
        $script:ownerCleanupComplete=$true;$script:ownerTerminationProven=$true
        return $true
    } catch {
        $script:failure=$true
        try {Write-HostedCapabilityFailure -Ledger $ledger -Code 'session-owner-cleanup-failed' -Evidence @{message=$_.Exception.Message;processIdentity=$ownerIdentity;activeProcesses=if($ownerJob){$ownerJob.ActiveProcesses}else{$null}} | Out-Null} catch {}
        if($ownerJob -and $ownerJob.ActiveProcesses -gt 0){try{$ownerJob.Terminate(137)}catch{}}
        $script:ownerTerminationProven=[bool]($ownerProcess -and $ownerProcess.Wait((Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 1000)) -and $ownerJob -and $ownerJob.ActiveProcesses -eq 0)
        if($script:ownerTerminationProven){Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='owner-retained-termination-after-failed-planned-shutdown';processIdentity=$ownerIdentity;observed=@{waitedHandle=$true;activeProcesses=0;primaryFailureRemainsLatched=$true}}|Out-Null}
        return $false
    }
}
function Invoke-OwnedPreSessionCleanup($Replay) {
    $create=@($Replay.events | Where-Object {$_.phase -ceq 'intent' -and $_.operation -ceq 'create-disposable-local-user' -and $_.precondition.absent -eq $true})
    if(!$create.Count){return @{preSession=$true;userNeverOwned=$true}}
    $name='t569'+$RunId.Substring(0,10)
    $local=Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if(!$local){return @{preSession=$true;userAbsent=$true}}
    $observed=@($Replay.mutations | Where-Object {$_.intent.operation -ceq 'create-disposable-local-user' -and $_.observation.result -ceq 'completed'})
    if($observed.Count -and $observed[-1].observation.observed.sid -cne $local.SID.Value){throw 'Pre-session cleanup user SID differs from supervisor journal ownership'}
    $profile=Get-CimInstance Win32_UserProfile -Filter "SID='$($local.SID.Value)'" -ErrorAction Stop
    if($profile -or (Test-Path "Registry::HKEY_USERS\$($local.SID.Value)")){throw 'Pre-session cleanup refuses a user whose profile/session appeared without authoritative session proof'}
    $grant=@($Replay.events | Where-Object {$_.phase -ceq 'intent' -and $_.operation -ceq 'grant-remote-desktop-users-membership' -and $_.resourceIdentity.memberSid -ceq $local.SID.Value -and $_.precondition.memberAbsent -eq $true})
    if($grant.Count){$null=Invoke-SupervisorRecoveryMutation 'remove-owned-presession-rdp-membership' @{groupSid='S-1-5-32-555';sid=$local.SID.Value} @{memberAbsentBeforeOwnedGrant=$true} {
        $members=@(Get-LocalGroupMember -SID 'S-1-5-32-555' | Where-Object {$_.SID.Value -ceq $local.SID.Value})
        if($members.Count){Remove-LocalGroupMember -SID 'S-1-5-32-555' -Member $members[0] -ErrorAction Stop}
        @{absent=(@(Get-LocalGroupMember -SID 'S-1-5-32-555' | Where-Object {$_.SID.Value -ceq $local.SID.Value}).Count -eq 0)}
    }}
    $null=Invoke-SupervisorRecoveryMutation 'remove-owned-presession-local-user' @{name=$name;sid=$local.SID.Value} @{userAbsentBeforeOwnedCreate=$true;profileAbsent=$true} {
        Remove-LocalUser -Name $name -ErrorAction Stop
        if(Get-LocalUser -Name $name -ErrorAction SilentlyContinue){throw 'Pre-session run-owned user remains'}
        @{absent=$true}
    }
    @{preSession=$true;userAbsent=$true;sid=$local.SID.Value;currentUserRoot='unverified-no-session';credential='unverified-no-session'}
}
function Remove-EmptyOwnedRuntimeRoot {
    $path='C:\crabbox\work\ticket569'
    if(!$runtimeRootWasAbsent){return @{preexistingPreserved=$true;ownedDirectoryCreated=$false}}
    if(!(Test-Path -LiteralPath $path)){return @{ownedDirectoryAbsent=$true}}
    if(@(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop).Count){throw 'Owned runtime directory contains remaining files; refusing recursive deletion'}
    $null=Invoke-SupervisorRecoveryMutation 'remove-empty-owned-hosted-runtime-root' @{path=$path} @{preexisting=$false;empty=$true} {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        @{absent=(!(Test-Path -LiteralPath $path))}
    }
    @{ownedDirectoryAbsent=(!(Test-Path -LiteralPath $path))}
}
function Stop-OwnedHostedProbeTasks([string]$targetSID,[int]$targetSession) {
    foreach($profileKind in @('normal','mount-point')){
        Assert-BeforeRecoveryDeadline
        $ownedTaskName="Ticket569-$RunId-$profileKind"
        $ownedTask=Get-ScheduledTask -TaskName $ownedTaskName -ErrorAction SilentlyContinue
        if($ownedTask){
            $ownedUser='t569'+$RunId.Substring(0,10)
            $principal=[string]$ownedTask.Principal.UserId
            if($principal -cne $targetSID -and $principal -ine "$env:COMPUTERNAME\$ownedUser"){throw 'Owned task cleanup refused a principal mismatch'}
            $actions=@($ownedTask.Actions)
            $expectedProbe=Join-Path $PSScriptRoot 'hosted-user-capability.ps1'
            if($actions.Count -ne 1 -or !(Test-HostedCapabilityCommandArguments ('powershell.exe '+$actions[0].Arguments) @{'-File'=$expectedProbe;'-RunId'=$RunId;'-SourceSHA'=$expectedSha})){throw 'Owned task cleanup refused changed source/run/script arguments'}
            if($ownedTask.State -eq 'Running'){$null=Invoke-SupervisorRecoveryMutation 'stop-failed-workers-exact-interactive-task' @{taskName=$ownedTaskName;sid=$targetSID;sessionId=$targetSession} @{taskNameRunScoped=$true;workerJobAlreadyTerminated=$true} {Stop-ScheduledTask -TaskName $ownedTaskName -ErrorAction Stop;@{stopped=$true}}}
            $userChildren=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop | Where-Object {$_.CommandLine -and $_.CommandLine.Contains('hosted-user-capability.ps1',[StringComparison]::OrdinalIgnoreCase) -and $_.CommandLine.Contains($RunId,[StringComparison]::OrdinalIgnoreCase) -and (Get-SupervisorProcessSID $_) -ceq $targetSID -and [int]$_.SessionId -eq $targetSession})
            foreach($childInfo in $userChildren){
                $childProcess=Get-Process -Id ([int]$childInfo.ProcessId) -ErrorAction Stop
                $childIdentity=@{pid=$childProcess.Id;creationFileTimeUtc=$childProcess.StartTime.ToUniversalTime().ToFileTimeUtc();sid=$targetSID;sessionId=$targetSession;taskName=$ownedTaskName}
                $null=Invoke-SupervisorRecoveryMutation 'terminate-failed-workers-exact-user-child' $childIdentity @{processOwnerAndSessionValidated=$true;runIdCommandLineMatched=$true;workerJobAlreadyTerminated=$true} {
                    $stopped=Stop-HostedCapabilityProcessIdentity -ProcessId ([uint32]$childIdentity.pid) -CreationFileTimeUtc ([long]$childIdentity.creationFileTimeUtc) -WaitMilliseconds (Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 5000)
                    if(!$stopped.terminated){throw 'Exact failed worker task child could not be identity-bound terminated'}
                    @{terminated=$true;exitCode=$stopped.exitCode;creationFileTimeUtc=$stopped.observedCreationFileTimeUtc}
                }
            }
            $leftover=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop | Where-Object {$_.CommandLine -and $_.CommandLine.Contains('hosted-user-capability.ps1',[StringComparison]::OrdinalIgnoreCase) -and $_.CommandLine.Contains($RunId,[StringComparison]::OrdinalIgnoreCase) -and (Get-SupervisorProcessSID $_) -ceq $targetSID -and [int]$_.SessionId -eq $targetSession})
            if($leftover.Count){throw 'Run-scoped user probe child remains after identity-bound worker-child termination'}
            $null=Invoke-SupervisorRecoveryMutation 'unregister-failed-workers-exact-interactive-task' @{taskName=$ownedTaskName;sid=$targetSID;sessionId=$targetSession} @{taskStopped=$true;runIdExact=$true} {Unregister-ScheduledTask -TaskName $ownedTaskName -Confirm:$false -ErrorAction Stop;@{absent=($null -eq (Get-ScheduledTask -TaskName $ownedTaskName -ErrorAction SilentlyContinue))}}
        }
    }
}
function Save-HostedPresentRootRecoveryEvidence($Result,$Launcher,$LauncherProcess,$ProfilePath) {
    if($TestFault -cne 'present-root-recovery'){return}
    if(!$script:presentRootBarrier.accepted -or !$script:presentRootIntercept.eligible){throw 'Present recovery evidence lacks accepted exercise'}
    Assert-HostedExerciseRecoveryCutoff
    Drain-HostedCapabilityFinishingHelpers
    $thumb=[string]$script:presentRootIntercept.resource.thumbprint
    if(@($Result.removedRootThumbprints).Count -ne 1 -or $Result.removedRootThumbprints[0] -cne $thumb){throw 'Present recovery did not remove exactly the owned thumbprint'}
    $removePath=Join-Path $ProfilePath ".ticket569-$RunId-root-remove-$($thumb.ToLowerInvariant()).json"
    $launcherPath=Join-Path $ProfilePath ".ticket569-$RunId-recovery-launcher.json"
    $remove=Get-Content -LiteralPath $removePath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $ancestry=Get-Content -LiteralPath $launcherPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $consentPath=Join-Path $EvidenceDirectory 'current-user-root-removal-consent.json'
    $consentDeadline=[Math]::Min([Diagnostics.Stopwatch]::GetTimestamp()+15L*$frequency,[long]$script:exerciseRecoveryCutoff)
    # The unchanged watcher writes only after its post-click close check.
    while(!(Test-Path -LiteralPath $consentPath -PathType Leaf)){
        Assert-HostedExerciseRecoveryCutoff
        $wait=Get-HostedCapabilityWaitBudget $consentDeadline $frequency 100
        if($wait -le 0){throw 'Present Root removal consent receipt did not arrive within its bounded wait'}
        Start-Sleep -Milliseconds $wait
    }
    Assert-HostedExerciseRecoveryCutoff
    if([Diagnostics.Stopwatch]::GetTimestamp() -ge $consentDeadline){throw 'Present Root removal consent receipt arrived after its bounded wait'}
    $consent=Get-Content -LiteralPath $consentPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $replay=Read-HostedCapabilityLedger -Directory $runRoot -RunId $RunId -SourceSHA $expectedSha
    $mutations=@($replay.mutations|Where-Object {$_.intent.operation -ceq 'recovery-remove-exact-owned-currentuser-root-certificate' -and $_.intent.resourceIdentity.thumbprint -ceq $thumb})
    $exits=@($replay.events|Where-Object {$_.operation -ceq 'validated-helper-process-exit-observed' -and $_.processIdentity.role -ceq 'root-remove' -and $_.processIdentity.pid -eq $remove.processId -and $_.processIdentity.creationFileTimeUtc -eq $remove.processCreationFileTimeUtc})
    if(!$replay.valid -or $mutations.Count -ne 1 -or $exits.Count -ne 1 -or
       $mutations[0].observation.result -cne 'completed' -or !(Test-HostedBoolean $mutations[0].observation.observed.absent $true) -or
       $mutations[0].intent.precondition.preabsenceSequence -ne $script:presentRootIntercept.preabsenceSequence -or
       $mutations[0].intent.precondition.importAttemptSequence -ne $script:presentRootIntercept.importSequence -or
       !(Test-HostedBoolean $mutations[0].intent.precondition.exactSubjectMatch $true) -or !(Test-HostedBoolean $mutations[0].intent.precondition.uniqueThumbprintMatch $true) -or
       !(Test-HostedBoolean $exits[0].observed.waitedHandle $true) -or !(Test-HostedBoolean $exits[0].observed.identityMatched $true) -or $exits[0].observed.exitCode -ne 0 -or
       $remove.schema -cne 'ticket569-currentuser-root-import-v1' -or $remove.runId -cne $RunId -or $remove.sid -cne $Result.sid -or $remove.sessionId -ne $Result.sessionId -or
       $remove.thumbprint -cne $thumb -or $remove.subject -cne $script:presentRootIntercept.resource.subject -or
       !(Test-HostedBoolean $remove.passed $true) -or !(Test-HostedBoolean $remove.removedOwned $true) -or !(Test-HostedBoolean $remove.removedObserved $true) -or
       $ancestry.schema -cne 'ticket569-recovery-launcher-v1' -or $ancestry.runId -cne $RunId -or $ancestry.sourceSHA -cne $expectedSha -or
       $ancestry.launcher.pid -ne $Launcher.pid -or $ancestry.child.pid -ne $script:expectedRecoveryWorker.pid -or
       $ancestry.child.creationFileTimeUtc -ne $script:expectedRecoveryWorker.creationFileTimeUtc -or
       $ancestry.child.sid -cne $Result.sid -or $ancestry.child.sessionId -ne $Result.sessionId -or $ancestry.child.job -cne $recoveryJobName -or
       $ancestry.workerScriptSHA256 -cne $Launcher.workerScriptSHA256 -or $ancestry.launcher.scriptSHA256 -cne $Launcher.scriptSHA256 -or
       !(Test-HostedBoolean $ancestry.suspendedChildValidated $true) -or !(Test-HostedBoolean $ancestry.gateReleased $true) -or
       $consent.status -cne 'observed-and-answered' -or !(Test-HostedBoolean $consent.promptClosed $true) -or
       !$consent.observation.pid -or !$consent.observation.windowId -or !$consent.observation.affirmativeElementToken -or
       $LauncherProcess.ExitCode -ne 0 -or $recoveryJob.ActiveProcesses -ne 0){throw 'Present RemoveOwned recovery ancestry, waited removal, consent or result incomplete'}
    $script:presentRootRecoveryEvidence=@{schema='ticket569-present-root-recovery-evidence-v1';runId=$RunId;sourceSHA=$expectedSha;testFault=$TestFault;intercept=$script:presentRootIntercept;barrier=$script:presentRootBarrier;recovery=$Result;launcher=$Launcher;launcherAncestry=$ancestry;launcherExitCode=$LauncherProcess.ExitCode;recoveryJobEmpty=$true;removeResult=$remove;removalMutation=$mutations[0];removalExit=$exits[0];removalConsent=$consent;recoveryCompletedCounter=[Diagnostics.Stopwatch]::GetTimestamp();recoveryCutoff=$script:exerciseRecoveryCutoff;cleanupDeadline=$deadlines.cleanup;counterFrequency=$frequency;independentAbsenceRequired=$true}
    $path=Join-Path $EvidenceDirectory 'present-root-recovery-evidence.json'
    if(Test-Path -LiteralPath $path){throw 'Present recovery evidence path occupied'}
    Write-HostedCapabilityAtomicJson -Path $path -Value $script:presentRootRecoveryEvidence
    # Preserve actual profile receipts before the existing profile removal.
    foreach($pair in @(@($removePath,'present-root-remove-receipt.json'),@($launcherPath,'present-root-launcher-receipt.json'),@((Join-Path $ProfilePath ".ticket569-$RunId-recovery.json"),'present-root-recovery-receipt.json'),@((Join-Path $ProfilePath "root-import-attached-$RunId.json"),'present-root-import-attached-receipt.json'),@((Join-Path $ProfilePath "root-import-exit-$RunId.json"),'present-root-import-exit-receipt.json'))){
        $destination=Join-Path $EvidenceDirectory $pair[1]
        if(Test-Path -LiteralPath $destination){throw 'Present native receipt destination occupied'}
        Copy-Item -LiteralPath $pair[0] -Destination $destination -ErrorAction Stop
        if((Get-FileHash -LiteralPath $pair[0]).Hash -cne (Get-FileHash -LiteralPath $destination).Hash){throw 'Present native receipt copy differs'}
    }
}

function Invoke-HostedSensitiveSessionRecovery {
    Assert-BeforeRecoveryDeadline
    $replay=Read-HostedCapabilityLedger -Directory $runRoot -RunId $RunId -SourceSHA $expectedSha
    $sessionFact=$replay.sessionFact
    if($replay.valid -and !$sessionFact){return Invoke-OwnedPreSessionCleanup $replay}
    if(!$replay.valid -or !$sessionFact -or !$script:authoritativeSessionFact -or
       $sessionFact.ledgerSequence -ne $script:authoritativeSessionFact.ledgerSequence -or
       $sessionFact.sid -cne $script:authoritativeSessionFact.sid -or [int]$sessionFact.sessionId -ne [int]$script:authoritativeSessionFact.sessionId -or
       !$sessionFact.sid -or [int]$sessionFact.sessionId -le 0){throw 'Recovery lacks a valid replayed supervisor-ledger exact active SID/session fact'}
    $script:ownedCredentialTargets=@{}
    $script:rootPreabsenceFacts=@{}
    $script:rootImportAttempts=@{}
    foreach($event in $replay.events){
        if($event.phase -eq 'intent' -and $event.operation -in @('seed-exact-currentuser-synthetic-credential','write-owned-run-credential')){
            $script:ownedCredentialTargets[[string]$event.resourceIdentity.target]=$true
        }
        if($event.phase -eq 'process' -and $event.operation -ceq 'helper-fact-currentuser-root-exact-thumbprint-preabsence' -and
           $event.observed.matchCount -eq 0 -and !$event.observed.preexisting){
            $thumb=[string]$event.resourceIdentity.thumbprint
            $script:rootPreabsenceFacts[$thumb]=@{sequence=[long]$event.sequence;subject=[string]$event.resourceIdentity.subject;sid=[string]$event.processIdentity.sid;sessionId=[int]$event.processIdentity.sessionId}
        }
        if($event.phase -eq 'intent' -and $event.operation -ceq 'import-exact-currentuser-root-certificate'){
            $script:rootImportAttempts[[string]$event.resourceIdentity.thumbprint]=[long]$event.sequence
        }
    }
    if(!$sessionFact){return Invoke-OwnedPreSessionCleanup $replay}
    if(!$sessionFact.sid -or [int]$sessionFact.sessionId -le 0){throw 'Replayed recovery session identity is invalid'}
    $targetSID=[string]$sessionFact.sid;$targetSession=[int]$sessionFact.sessionId
    $expectedName='t569'+$RunId.Substring(0,10);$local=Get-LocalUser -Name $expectedName -ErrorAction SilentlyContinue
    if(!$local -or $local.SID.Value -cne $targetSID){throw 'Recovery target user SID does not match the run-scoped account and session observation'}
    $profilePath=Join-Path 'C:\Users' $expectedName
    Stop-OwnedHostedProbeTasks $targetSID $targetSession
    $resultPath=Join-Path $profilePath ".ticket569-$RunId-recovery.json"
    if(Test-Path -LiteralPath $resultPath){throw 'Recovery evidence path is occupied; refusing to overwrite'}
    $recoveryScript=Join-Path $PSScriptRoot 'hosted-capability-recovery.ps1'
    $recoveryWorkerScript=Join-Path $PSScriptRoot 'hosted-capability-recovery-worker.ps1'
    $recoveryScriptHash=(Get-FileHash -LiteralPath $recoveryScript -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $recoveryWorkerScriptHash=(Get-FileHash -LiteralPath $recoveryWorkerScript -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $recoveryGateName="Global\Ticket569-$RunId-recovery-gate"
    $recoveryGateDacl="D:P(A;;GA;;;SY)(A;;GA;;;$sid)(A;;0x00100000;;;$targetSID)"
    $script:recoveryGate=New-HostedCapabilityGate -Name $recoveryGateName -DaclSddl $recoveryGateDacl
    $sha=[Security.Cryptography.SHA256]::Create();try{$recoveryGateDaclSHA256=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($recoveryGateDacl))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='resource';operation='recovery-launch-gate-created';resourceIdentity=@{name=$recoveryGateName;daclSHA256=$recoveryGateDaclSHA256;supervisorSID=$sid;recoverySID=$targetSID;resetOperationExposed=$false};observed=@{initiallySignaled=$false;manualReset=$true;access='supervisor-set exact-recovery-SID-synchronize'}} | Out-Null
    $taskName="Ticket569-$RunId-recovery"
    $pwsh=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',"`"$recoveryScript`"",'-RunId',$RunId,'-SourceSHA',$expectedSha,'-ExpectedSID',$targetSID,'-ExpectedSessionId',[string]$targetSession,'-ExpectedProfilePath',"`"$profilePath`"",'-RecoveryJobName',$recoveryJobName,'-RecoveryGateName',$recoveryGateName,'-ExpectedLauncherSHA256',$recoveryScriptHash,'-ExpectedWorkerSHA256',$recoveryWorkerScriptHash,'-HelperPipeName',"Ticket569-$RunId-helper",'-FailureEventName',$failureEventName,'-SourceRoot',"`"$root`"",'-JobStartCounter',[string]$start,'-CounterFrequency',[string]$frequency)
    $action=New-ScheduledTaskAction -Execute $pwsh -Argument ($arguments -join ' ')
    $principal=New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$expectedName" -LogonType Interactive -RunLevel Limited
    $null=Invoke-SupervisorRecoveryMutation 'register-interactive-recovery-task' @{taskName=$taskName;sid=$targetSID;sessionId=$targetSession;sourceSHA=$expectedSha;jobName=$recoveryJobName;script=$recoveryScript} @{taskAbsent=($null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue));interactiveToken=$true;noPassword=$true} {Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null;@{registered=$true}}
    try {
        $null=Invoke-SupervisorRecoveryMutation 'start-interactive-recovery-task' @{taskName=$taskName;sid=$targetSID;sessionId=$targetSession} @{registered=$true;exactLoadedSessionWasObserved=$true} {Start-ScheduledTask -TaskName $taskName;@{started=$true}}
        $taskProcess=$null;$taskProcessIdentity=$null;$deadline=if($TestFault -ceq 'present-root-recovery' -and $script:exerciseRecoveryCutoff){[long]$script:exerciseRecoveryCutoff}else{[long]$deadlines.cleanup}
        while([Diagnostics.Stopwatch]::GetTimestamp() -lt $deadline){
            Assert-HostedExerciseRecoveryCutoff
            Assert-BeforeRecoveryDeadline
            $processes=Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop | Where-Object {$_.CommandLine -and $_.CommandLine.Contains($recoveryScript,[StringComparison]::OrdinalIgnoreCase) -and $_.CommandLine.Contains($RunId,[StringComparison]::OrdinalIgnoreCase)}
            $script:discoveredRecoveryLaunchers=@($processes)
            $matches=@($processes | Where-Object { (Get-SupervisorProcessSID $_) -ceq $targetSID -and [int]$_.SessionId -eq $targetSession })
            if(@($processes).Count -gt 0){
                $selected=Get-HostedCapabilityRecoveryLauncher -ProcessIds @($processes|ForEach-Object {[uint32]$_.ProcessId}) -ExpectedSID $targetSID -ExpectedSessionId $targetSession -Executable $pwsh -ScriptPath $recoveryScript -RunId $RunId -SourceSHA $expectedSha -LauncherSHA256 $recoveryScriptHash -WorkerSHA256 $recoveryWorkerScriptHash -GateName $recoveryGateName
                $candidate=$selected.Process
                $candidateCreation=$selected.CreationFileTimeUtc
                if(!(Test-HostedCapabilityCommandArguments $matches[0].CommandLine @{'-File'=$recoveryScript;'-RunId'=$RunId;'-SourceSHA'=$expectedSha;'-RecoveryGateName'=$recoveryGateName;'-ExpectedLauncherSHA256'=$recoveryScriptHash;'-ExpectedWorkerSHA256'=$recoveryWorkerScriptHash})){throw 'Recovery launcher exact parsed arguments differ'}
                $taskProcess=$candidate
                $taskProcessIdentity=@{pid=$candidate.Id;creationFileTimeUtc=$candidateCreation;sid=$targetSID;sessionId=$targetSession;executable=[IO.Path]::GetFullPath($candidate.Path);scriptPath=$recoveryScript;scriptSHA256=$recoveryScriptHash;workerScriptSHA256=$recoveryWorkerScriptHash;gateName=$recoveryGateName;gateDaclSHA256=$recoveryGateDaclSHA256;taskName=$taskName;sourceSHA=$expectedSha}
                $identityRecord=Get-Content -LiteralPath $supervisorIdentityPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $identityRecord | Add-Member -NotePropertyName recoveryLauncher -NotePropertyValue $taskProcessIdentity -Force
                Write-HostedCapabilityAtomicJson -Path $supervisorIdentityPath -Value $identityRecord
                Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='validated-recovery-launcher-before-release';processIdentity=$taskProcessIdentity;resourceIdentity=@{taskName=$taskName;gateName=$recoveryGateName;gateDaclSHA256=$recoveryGateDaclSHA256};observed=@{taskPrincipalSID=$targetSID;taskSessionId=$targetSession;launcherWaitsForGate=$true;exactScriptHash=$recoveryScriptHash;workerHash=$recoveryWorkerScriptHash}} | Out-Null
                $script:expectedRecoveryLauncher=$taskProcessIdentity
                try{
                    $null=Invoke-SupervisorRecoveryMutation 'assign-exact-recovery-launcher-job' @{jobName=$recoveryJobName;launcher=$taskProcessIdentity;taskName=$taskName;runId=$RunId;sourceSHA=$expectedSha} @{launcherIdentityDurablyRecorded=$true;jobInitiallyEmpty=$true;killOnClose=$true;breakawayAllowed=$false;gateUnsignaled=$true} {
                        Add-HostedCapabilityRetainedProcessToJob -Job $recoveryJob -ProcessHandle $taskProcess.Handle -CreationFileTimeUtc $taskProcessIdentity.creationFileTimeUtc
                        @{assignedByRetainedOwner=$true;activeProcesses=$recoveryJob.ActiveProcesses;jobLimitFlags=$recoveryJob.LimitFlags;validatedBeforeGateRelease=$true}
                    }
                $null=Invoke-SupervisorRecoveryMutation 'release-exact-recovery-launch-gate' @{gateName=$recoveryGateName;launcher=$taskProcessIdentity;taskName=$taskName} @{launcherIdentityDurablyRecorded=$true;principalSID=$targetSID;sessionId=$targetSession;scriptSHA256=$recoveryScriptHash;workerScriptSHA256=$recoveryWorkerScriptHash;manualResetGateUnsignaled=$true} {$script:recoveryGate.Release();@{released=$true;atQpc=[Diagnostics.Stopwatch]::GetTimestamp()}}
                }catch{
                    $assignmentFailure=$_;$script:failure=$true
                    try{$script:failureEvent.Release()}catch{}
                    try{
                        if(!(Stop-HostedCapabilityRetainedProcess -ProcessHandle $taskProcess.Handle -CreationFileTimeUtc $taskProcessIdentity.creationFileTimeUtc -WaitMilliseconds (Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 5000))){throw 'Owner assignment failure did not retain exact launcher exit'}
                    }catch{Write-HostedCapabilityFailure -Ledger $ledger -Code 'owner-assignment-launcher-exit-unproven' -Evidence @{errorType=$_.Exception.GetType().FullName} | Out-Null}
                    throw $assignmentFailure
                }
                break
            }
            Start-Sleep -Milliseconds 100
        }
        if(!$taskProcess){throw 'Exact interactive recovery child was not observed before the J+24 cutoff'}
        while(!$taskProcess.WaitForExit((Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 100))){
            Assert-HostedExerciseRecoveryCutoff
            Pump-HostedCapabilityHelper
            Assert-BeforeRecoveryDeadline
            $identityCheck=Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$taskProcess.Id) -CreationFileTimeUtc ([long]$taskProcessIdentity.creationFileTimeUtc)
            if(!$identityCheck.matches){throw 'Recovery task PID creation identity changed while being supervised'}
        }
        Assert-HostedExerciseRecoveryCutoff
        $taskProcess.Refresh()
        if($taskProcess.ExitCode -ne 0 -or !(Test-Path -LiteralPath $resultPath)){throw 'Interactive recovery child failed or omitted its run-scoped result'}
        $result=Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if($result.runId -cne $RunId -or $result.sourceSHA -cne $expectedSha -or $result.sid -cne $targetSID -or [int]$result.sessionId -ne $targetSession -or $result.failed -or $result.credentialFinalCredReadError -ne 1168 -or $result.rootSubjectRemaining -or $result.rootStatus -cne 'verified' -or !$result.sessionHostHealthBefore.healthy -or !$result.sessionHostHealthAfter.healthy -or !$result.sessionLeftActiveForSupervisorLogoff){throw 'Recovery result did not prove exact credential absence, owned Root cleanup, retained session, and a healthy session-host UIA channel'}
        if($recoveryJob.ActiveProcesses -ne 0){throw 'Recovery child returned with active processes in its Recovery Job Object'}
        Save-HostedPresentRootRecoveryEvidence $result $taskProcessIdentity $taskProcess $profilePath
        $null=Invoke-SupervisorRecoveryMutation 'observe-interactive-recovery-complete' @{taskName=$taskName;child=$taskProcessIdentity;resultPath=$resultPath;sid=$targetSID;sessionId=$targetSession} @{taskExit=0;credentialFinalCredReadError=1168;rootSubjectRemaining=$false;recoveryJobEmpty=$true} {@{result=$result;taskExitCode=$taskProcess.ExitCode}}
        $null=Invoke-SupervisorRecoveryMutation 'unregister-interactive-recovery-task' @{taskName=$taskName;sid=$targetSID;sessionId=$targetSession} @{taskCompleted=$true} {Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop;@{absent=($null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue))}}
    } finally {
        if($script:discoveredRecoveryLaunchers){
            foreach($candidateInfo in $script:discoveredRecoveryLaunchers){
                try{
                    $candidateHandle=Get-Process -Id ([int]$candidateInfo.ProcessId) -ErrorAction Stop
                    $null=$candidateHandle.Handle
                    $created=$candidateHandle.StartTime.ToUniversalTime().ToFileTimeUtc()
                    $info=Get-CimInstance Win32_Process -Filter "ProcessId=$($candidateInfo.ProcessId)" -ErrorAction Stop
                    if($info.CommandLine -cne $candidateInfo.CommandLine -or !$info.CommandLine.Contains($RunId,[StringComparison]::OrdinalIgnoreCase) -or !$info.CommandLine.Contains($recoveryScript,[StringComparison]::OrdinalIgnoreCase)){throw 'Rejected launcher identity changed; termination refused'}
                    if(!$candidateHandle.HasExited){
                        $stop=Stop-HostedCapabilityProcessIdentity -ProcessId ([uint32]$candidateHandle.Id) -CreationFileTimeUtc $created -WaitMilliseconds (Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 5000)
                        if(!$stop.terminated){throw 'Rejected/duplicate launcher retained process exit was not proven'}
                    }
                    Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='recovery-launcher-retained-exit-before-gate-close';processIdentity=@{pid=$candidateHandle.Id;creationFileTimeUtc=$created;sid=(Get-SupervisorProcessSID $info);sessionId=$info.SessionId};observed=@{waitedHandle=$true;exited=$candidateHandle.WaitForExit((Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 1000))}} | Out-Null
                    $candidateHandle.Dispose()
                }catch{Write-HostedCapabilityFailure -Ledger $ledger -Code 'rejected-recovery-launcher-termination-unproven' -Evidence @{errorType=$_.Exception.GetType().FullName} | Out-Null;$script:failure=$true}
            }
        }
        try {
            $remainingTask=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if($remainingTask -and $remainingTask.State -eq 'Running'){Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop}
            if($taskProcess -and !$taskProcess.WaitForExit(0) -and $taskProcessIdentity){$null=Stop-HostedCapabilityProcessIdentity -ProcessId ([uint32]$taskProcessIdentity.pid) -CreationFileTimeUtc ([long]$taskProcessIdentity.creationFileTimeUtc) -WaitMilliseconds (Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 5000)}
            if($remainingTask){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop}
        } catch {try{Write-HostedCapabilityFailure -Ledger $ledger -Code 'recovery-task-stop-failed' -Evidence @{errorType=$_.Exception.GetType().FullName;taskName=$taskName} | Out-Null}catch{}}
        if($taskProcess){$taskProcess.Dispose()}
        if($script:recoveryGate){$script:recoveryGate.Dispose();$script:recoveryGate=$null}
    }
    @{sensitiveContextProven=$true;resultPath=$resultPath}
}
function Remove-OwnedTerminatedOwnerRuntime {
    if(!$script:ownerTerminationProven -or !$ownerJob -or $ownerJob.ActiveProcesses -ne 0){throw 'Private runtime cleanup lacks retained owner/job termination proof'}
    $expected=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ticket569-rdpilot-owner-'+$RunId)))
    if(!$ownerBootstrap -or [IO.Path]::GetFullPath([string]$ownerBootstrap.runtimeRoot) -cne $expected){throw 'Private runtime cleanup path differs from the authenticated owner bootstrap'}
    if(!(Test-Path -LiteralPath $expected)){return @{runtimeAbsent=$true}}
    if(((Get-Item -LiteralPath $expected).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
       @((Get-ChildItem -LiteralPath $expected -Recurse -Force)|Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count){throw 'Private runtime cleanup refuses linked files/directories'}
    $identityPath=Join-Path $EvidenceDirectory 'secret-canary-identity.json'
    if(!(Test-Path -LiteralPath $identityPath)){throw 'Private runtime cleanup lacks durable secret canary identities'}
    $identity=Get-Content -LiteralPath $identityPath -Raw|ConvertFrom-Json
    if($identity.schema -cne 'ticket569-secret-canary-v1' -or $identity.runId -cne $RunId -or $identity.sourceSHA -cne $expectedSha -or !$identity.hashes.Count){throw 'Private runtime secret identity differs from the run'}
    foreach($canary in $identity.hashes){
        $scanBudget=Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 4000
        if($scanBudget -lt 100){throw 'Private runtime scan cannot finish before the absolute cleanup deadline'}
        $scan=Test-HostedSecretCanary -Directories @($expected) -Sha256 $canary.sha256 -Length $canary.length -RollingFingerprint $canary.rollingFingerprint -MaxElapsedMilliseconds $scanBudget
        if($scan.leaked){throw 'Private runtime cleanup secret canary leaked; failure stays latched'}
    }
    Assert-BeforeRecoveryDeadline
    Invoke-SupervisorRecoveryMutation 'remove-exact-terminated-owner-private-runtime' @{path=$expected;owner=$ownerIdentity} @{ownerTerminationProven=$true;ownerJobEmpty=$true;secretCanariesAbsent=$true;noReparsePoints=$true} {
        Remove-Item -LiteralPath $expected -Recurse -Force -ErrorAction Stop
        if(Test-Path -LiteralPath $expected){throw 'Owned private runtime remains after guarded removal'}
        @{runtimeAbsent=$true;plannedOwnerShutdownStillFailed=$true}
    }
}
function Invoke-OwnedPostSessionCleanup($SessionFact,[bool]$SessionLive,[bool]$SensitiveProven) {
    $targetSID=[string]$SessionFact.sid;$targetSession=[int]$SessionFact.sessionId
    $expectedName='t569'+$RunId.Substring(0,10)
    $local=Get-LocalUser -Name $expectedName -ErrorAction Stop
    if($recoveryJob -and $recoveryJob.ActiveProcesses -gt 0){throw 'Recovery participants remain live; profile cleanup refused'}
    $profilePath=Join-Path 'C:\Users' $expectedName
    if($local.SID.Value -cne $targetSID -or $SessionFact.profilePath -cne $profilePath){throw 'Owned cleanup SID/profile identity differs from the durable run fact'}
    Stop-OwnedHostedProbeTasks $targetSID $targetSession
    $resultPath=Join-Path $profilePath ".ticket569-$RunId-recovery.json"
    if($ownerProcess -and !(Stop-HostedSessionOwnerPlanned) -and !$script:ownerTerminationProven){throw 'Retained owner/job termination remains unproved; safe profile cleanup refused'}
    if(!$script:ownerCleanupComplete){
        try{$null=Remove-OwnedTerminatedOwnerRuntime}catch{$script:failure=$true;Write-HostedCapabilityFailure -Ledger $ledger -Code 'owned-private-runtime-cleanup-unverified' -Evidence @{errorType=$_.Exception.GetType().FullName}|Out-Null}
    }
    Assert-BeforeRecoveryDeadline
    if($SessionLive){
    $logoff=Invoke-SupervisorRecoveryMutation 'logoff-exact-recovered-user-session' @{sid=$targetSID;sessionId=$targetSession} @{sameSidSessionLive=$true;ownerParticipantsTerminated=$true;sensitiveContextProven=$SensitiveProven} {
        $logoffPath=[IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\logoff.exe'))
        $process=Start-Process -FilePath $logoffPath -ArgumentList @([string]$targetSession) -PassThru
        $processIdentity=@{pid=$process.Id;creationFileTimeUtc=$process.StartTime.ToUniversalTime().ToFileTimeUtc();executable=[IO.Path]::GetFullPath($process.MainModule.FileName);sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;sessionId=$process.SessionId;targetSessionId=$targetSession}
        if($processIdentity.executable -cne $logoffPath){try{$process.Kill();$null=$process.WaitForExit((Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 5000))}catch{};throw 'Recovery logoff launched an unexpected executable image'}
        $deadlineCounter=[Math]::Min([Diagnostics.Stopwatch]::GetTimestamp()+10L*$frequency,$deadlines.cleanup)
        while(!$process.WaitForExit((Get-HostedCapabilityWaitBudget $deadlineCounter $frequency 100)) -and [Diagnostics.Stopwatch]::GetTimestamp() -lt $deadlineCounter){}
        if(!$process.HasExited){try{$process.Kill();$null=$process.WaitForExit((Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 5000))}catch{};throw 'Exact recovery-session logoff command exceeded its absolute bounded wait'}
        if($process.ExitCode -ne 0){throw "Exact recovery-session logoff exited $($process.ExitCode)"}
        $process.Refresh();if(!$process.HasExited){throw 'Recovery logoff process handle did not signal exit'}
        $observation=@{exitCode=$process.ExitCode;process=$processIdentity;waitedHandle=$true;observedCreationFileTimeUtc=$processIdentity.creationFileTimeUtc}
        $process.Dispose()
        $observation
    }
    }
    $unloadBy=[long]$deadlines.cleanup
    while([Diagnostics.Stopwatch]::GetTimestamp() -lt $unloadBy){
        Assert-BeforeRecoveryDeadline
        $sessions=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.SessionId -eq $targetSession -and (Get-SupervisorProcessSID $_) -ceq $targetSID } | Select-Object -First 1)
        $profile=Get-CimInstance Win32_UserProfile -Filter "SID='$targetSID'" -ErrorAction Stop
        if(!$sessions -and (!$profile -or !$profile.Loaded) -and !(Test-Path "Registry::HKEY_USERS\$targetSID")){break}
        Start-Sleep -Milliseconds 100
    }
    if($sessions -or ($profile -and $profile.Loaded) -or (Test-Path "Registry::HKEY_USERS\$targetSID")){throw 'Recovery did not observe exact session/profile/hive unload before J+24'}
    $restorePath=Join-Path $EvidenceDirectory 'recovery-profile-restore'
    & (Join-Path $PSScriptRoot 'profile.ps1') -Action restore-normal -SID $targetSID -ProfilePath $profilePath -VhdPath (Join-Path 'C:\crabbox\work\ticket569' "profile-$RunId.vhdx") -BackupPath "$profilePath.normal-backup" -EvidenceDirectory $restorePath -MutationMode Hosted -DeadlineCounter $deadlines.cleanup -CounterFrequency $frequency -MutationHook {
        param($operation,$resourceIdentity,$precondition,$action)
        $requestId=[guid]::NewGuid().ToString('N')
        $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{requestId=$requestId;phase='intent';operation=$operation;resourceIdentity=$resourceIdentity;precondition=$precondition;processIdentity=$selfIdentity}
        try{$observed=& $action;$result='completed'}catch{$observed=@{errorType=$_.Exception.GetType().FullName};$result='failed';$caught=$_}
        Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{requestId=$requestId;phase='observation';operation=$operation;resourceIdentity=$resourceIdentity;observed=$observed;result=$result;processIdentity=$selfIdentity} | Out-Null
        if($result -ne 'completed'){throw $caught}
    }
    $profile=Get-CimInstance Win32_UserProfile -Filter "SID='$targetSID'" -ErrorAction Stop
    if($profile){
        if($profile.Loaded -or $profile.LocalPath -cne $profilePath -or (Test-Path "Registry::HKEY_USERS\$targetSID")){throw 'Recovery refused profile deletion without exact unloaded SID/path identity'}
        $null=Invoke-SupervisorRecoveryMutation 'remove-recovered-exact-user-profile' @{sid=$targetSID;profilePath=$profilePath} @{sessionUnloaded=$true;profileState='normal';ownedRunUser=$expectedName} {Remove-CimInstance -InputObject $profile -ErrorAction Stop;@{profileAbsent=($null -eq (Get-CimInstance Win32_UserProfile -Filter "SID='$targetSID'" -ErrorAction SilentlyContinue))}}
    }
    $rootCerts=@(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object Subject -CEQ "CN=Ticket569-Root-Prompt-$RunId")
    foreach($cert in $rootCerts){$null=Invoke-SupervisorRecoveryMutation 'remove-exact-run-localmachine-prompt-certificate' @{store='LocalMachine/My';thumbprint=$cert.Thumbprint;subject=$cert.Subject} @{subjectExact=$true;runId=$RunId} {Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($cert.Thumbprint)" -Force -ErrorAction Stop;@{absent=($null -eq (Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -CEQ $cert.Thumbprint))}}}
    if(@(Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -CEQ "CN=Ticket569-Root-Prompt-$RunId").Count){throw 'Run-scoped LocalMachine prompt certificate remains after recovery'}
    $group=Get-LocalGroup -SID 'S-1-5-32-555' -ErrorAction Stop
    $members=@(Get-LocalGroupMember -Group $group -ErrorAction Stop | Where-Object SID -eq $targetSID)
    if($members.Count){$null=Invoke-SupervisorRecoveryMutation 'remove-recovered-run-user-rdp-group-membership' @{groupSid='S-1-5-32-555';sid=$targetSID;user=$expectedName} @{membershipPresent=$true;sidExact=$true} {Remove-LocalGroupMember -Group $group -Member $members[0] -ErrorAction Stop;@{absent=(@(Get-LocalGroupMember -Group $group | Where-Object SID -eq $targetSID).Count -eq 0)}}}
    $null=Invoke-SupervisorRecoveryMutation 'remove-recovered-run-local-user' @{sid=$targetSID;name=$expectedName} @{profileAbsent=($null -eq (Get-CimInstance Win32_UserProfile -Filter "SID='$targetSID'" -ErrorAction SilentlyContinue));sidExact=($local.SID.Value -ceq $targetSID)} {Remove-LocalUser -Name $expectedName -ErrorAction Stop;if(Get-LocalUser -Name $expectedName -ErrorAction SilentlyContinue){throw 'Run-scoped local user remains after recovery'};@{absent=$true}}
    @{sid=$targetSID;sessionId=$targetSession;user=$expectedName;recoveryResult=$resultPath;profileRestored=$true;profileRemoved=$true;userRemoved=$true;atUtc=[DateTime]::UtcNow.ToString('o')}
}function Get-HostedObservedProfileContext([string]$ProfilePath,[string]$StepName){
    $item=Get-Item -LiteralPath $ProfilePath -ErrorAction Stop
    $reparse=[bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    $volume=Get-Volume -FilePath (Join-Path $ProfilePath 'NTUSER.DAT') -ErrorAction Stop
    if(!$volume.UniqueId){throw 'Actual profile volume identity is unavailable'}
    if($StepName -ceq 'exact-active-user-wts-session'){
        if($reparse){throw 'Normal sensitive context became a mounted/reparse profile'}
        return @{kind='normal';volumeId=[string]$volume.UniqueId;profilePath=$ProfilePath}
    }
    if($StepName -cne 'vhd-active-user-wts-session' -or !$reparse){throw 'Actual profile kind differs from the acknowledged sensitive context'}
    $vhd=Join-Path 'C:\crabbox\work\ticket569' ("profile-$RunId.vhdx")
    $image=Get-DiskImage -ImagePath $vhd -ErrorAction Stop
    $volumes=@(Get-Partition -DiskNumber $image.Number -ErrorAction Stop|Get-Volume -ErrorAction Stop)
    if(!$image.Attached -or !@($volumes|Where-Object UniqueId -CEQ $volume.UniqueId).Count){throw 'Actual sensitive context volume does not belong to the run-owned VHD'}
    @{kind='mount-point';volumeId=[string]$volume.UniqueId;profilePath=$ProfilePath;vhdPath=$vhd}
}
function Invoke-HostedSessionRecovery {
    Assert-BeforeRecoveryDeadline
    $replay=Read-HostedCapabilityLedger -Directory $runRoot -RunId $RunId -SourceSHA $expectedSha
    if(!$replay.valid){throw 'Recovery journal is invalid'}
    $fact=$replay.sessionFact
    if(!$fact){return Invoke-OwnedPreSessionCleanup $replay}
    if(!$script:authoritativeSessionFact -or $fact.ledgerSequence -ne $script:authoritativeSessionFact.ledgerSequence -or
       $fact.sid -cne $script:authoritativeSessionFact.sid -or $fact.profilePath -cne $script:authoritativeSessionFact.profilePath){throw 'Recovery context differs from the acknowledged session fact'}
    $profile=Get-CimInstance Win32_UserProfile -Filter "SID='$($fact.sid)'" -ErrorAction Stop
    $sessionProcesses=@(Get-CimInstance Win32_Process -Filter "SessionId=$([int]$fact.sessionId)" -ErrorAction Stop|Where-Object {(Get-SupervisorProcessSID $_) -ceq $fact.sid})
    $live=[bool]($profile -and $profile.Loaded -and $profile.LocalPath -ceq $fact.profilePath -and $sessionProcesses.Count -gt 0 -and (Test-Path "Registry::HKEY_USERS\$($fact.sid)"))
    $sensitiveProven=$false
    try{
        if($live){
            $currentContext=Get-HostedObservedProfileContext $fact.profilePath $fact.stepName
            if(!$fact.profileContext -or $currentContext.kind -cne $fact.profileContext.kind -or $currentContext.volumeId -cne $fact.profileContext.volumeId){throw 'Actual sensitive profile/store context changed after its acknowledged fact'}
        }
        if(!$live){throw 'Original same-context sensitive session is unavailable; no interactive task or reconnect will be attempted'}
        $sensitive=Invoke-HostedSensitiveSessionRecovery
        $sensitiveProven=[bool]$sensitive.sensitiveContextProven
    }catch{
        $script:failure=$true
        Write-HostedCapabilityFailure -Ledger $ledger -Code 'same-context-sensitive-recovery-unverified' -Evidence @{errorType=$_.Exception.GetType().FullName;session=$fact;noReconnect=$true}|Out-Null
        if($recoveryJob -and $recoveryJob.ActiveProcesses -gt 0){$recoveryJob.Terminate(137)}
    }
    # Account/profile/VHD cleanup does not assert CredRead/Root absence when the
    # original sensitive session cannot be recovered. Pending intents stay pending.
    $owned=Invoke-OwnedPostSessionCleanup $fact ([bool]($sessionProcesses.Count -gt 0)) $sensitiveProven
    if($TestFault -ceq 'present-root-recovery'){$script:presentRootCleanupCounter=[Diagnostics.Stopwatch]::GetTimestamp()}
    @{sensitiveContextProven=$sensitiveProven;ownedCleanup=$owned;pendingMutationCount=$replay.pending.Count}
}

try {
    Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='supervisor-started';processIdentity=$selfIdentity;resourceIdentity=@{pid=$self.Id;creationFileTimeUtc=$selfCreation;testFault=$TestFault}} | Out-Null
    $launchDeadline=$start + 9L*60L*$frequency
    $preLaunchCounter=[Diagnostics.Stopwatch]::GetTimestamp()
    if ($preLaunchCounter -ge $launchDeadline) { throw 'Supervisor refused worker launch at or after the absolute J+9 cutoff' }
    $job=New-HostedCapabilityJob -Name $jobName -DaclSddl $sddl
    $recoveryDacl="D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
    $recoveryJob=New-HostedCapabilityJob -Name $recoveryJobName -DaclSddl $recoveryDacl
    $ownerJob=New-HostedCapabilityJob -Name $ownerJobName -DaclSddl $sddl
    $ownerProcess=Start-HostedCapabilityProcess -Job $ownerJob -Executable $workerName -ArgumentList $ownerArgs -WorkingDirectory $root
    $ownerIdentity=@{pid=$ownerProcess.ProcessId;creationFileTimeUtc=$ownerProcess.CreationFileTimeUtc;sid=$sid;sessionId=$session;jobName=$ownerJobName;pipeName=$ownerPipeName}
    Write-HostedCapabilityAtomicJson -Path $supervisorIdentityPath -Value @{schema='ticket569-supervisor-identity-v1';testFault=$TestFault;runId=$RunId;sourceSHA=$expectedSha;supervisor=$selfIdentity;sessionOwner=$ownerIdentity;worker=$null;stage='owner-started'}
    $bootstrap=Invoke-SessionOwnerControl (New-SessionOwnerRequest 'bootstrap') 10000
    if(!$bootstrap.ok -or !$bootstrap.result.ready -or $bootstrap.result.ownerPID -ne $ownerProcess.ProcessId -or $bootstrap.result.ownerSID -cne $sid -or $bootstrap.result.ownerSession -ne $session){throw 'Session owner bootstrap identity did not match its dedicated supervisor-owned process'}
    $ownerBootstrap=$bootstrap.result
    Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='session-owner-started-outside-worker-job';processIdentity=$ownerIdentity;resourceIdentity=@{jobName=$ownerJobName;pipeName=$ownerPipeName;runtimeRoot=$ownerBootstrap.runtimeRoot}} | Out-Null
    $workerArgs += @('-SessionOwnerPID',[string]$ownerProcess.ProcessId,'-SessionOwnerCreationFileTimeUtc',[string]$ownerProcess.CreationFileTimeUtc,'-SessionOwnerRuntimeRoot',[string]$ownerBootstrap.runtimeRoot)
    $server=[IO.Pipes.NamedPipeServerStream]::new($pipeName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,([IO.Pipes.PipeOptions]::CurrentUserOnly -bor [IO.Pipes.PipeOptions]::Asynchronous),65536,65536)
    $helperServer=New-HostedCapabilityHelperServer
    $launchHead=(& git -C $root rev-parse HEAD).Trim()
    $launchDirty=& git -C $root status --porcelain --untracked-files=normal
    if($LASTEXITCODE -ne 0 -or $launchHead -cne $expectedSha -or $launchDirty -or ($env:GITHUB_SHA -and $env:GITHUB_SHA -cne $expectedSha)){throw 'Adjacent worker-launch clean HEAD/GITHUB_SHA validation failed'}
    if([Diagnostics.Stopwatch]::GetTimestamp() -ge $launchDeadline){throw 'Supervisor refused worker launch because session-owner bootstrap reached the absolute J+9 cutoff'}
    $worker=Start-HostedCapabilityProcess -Job $job -Executable $workerName -ArgumentList $workerArgs -WorkingDirectory $root
    $workerIdentity=@{pid=$worker.ProcessId;creationFileTimeUtc=$worker.CreationFileTimeUtc;sid=$sid;sessionId=$session}
    $authorized=Invoke-SessionOwnerControl (New-SessionOwnerRequest 'authorize-worker' @{worker=$workerIdentity})
    if(!$authorized.ok -or !$authorized.result.authorized -or $authorized.result.worker.pid -ne $worker.ProcessId){throw 'Session owner refused the supervisor-authorized worker identity'}
    Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='worker-started-in-kill-on-close-job';processIdentity=$workerIdentity;resourceIdentity=@{jobName=$jobName;pipeName=$pipeName;pid=$worker.ProcessId;creationFileTimeUtc=$worker.CreationFileTimeUtc}} | Out-Null
    Write-HostedCapabilityAtomicJson -Path $supervisorIdentityPath -Value @{schema='ticket569-supervisor-identity-v1';testFault=$TestFault;runId=$RunId;sourceSHA=$expectedSha;supervisor=$selfIdentity;worker=$workerIdentity;sessionOwner=$ownerIdentity;jobNames=@($jobName,"Global\Ticket569-$RunId-build",$ownerJobName,$recoveryJobName);atUtc=[DateTime]::UtcNow.ToString('o');stage='worker-started'}
    $connected=$false
    $connectionWait=$server.WaitForConnectionAsync()
    while ([Diagnostics.Stopwatch]::GetTimestamp() -lt $launchDeadline) {
        if ($connectionWait.Wait((Get-HostedCapabilityWaitBudget $launchDeadline $frequency 200))) { $connected=$true;break }
        if ($worker.Wait(0)) { $workerExit=$worker.ExitCode;break }
    }
    if (!$connected) { throw 'Worker did not connect to the supervisor protocol before its bounded launch deadline' }
    $clientPid=Get-HostedCapabilityPipeClientProcessId -PipeHandle $server.SafePipeHandle.DangerousGetHandle()
    $clientSid=Get-HostedCapabilityPipeClientSid -Pipe $server
    $clientProcess=Get-Process -Id $clientPid -ErrorAction Stop
    $clientSession=[int]$clientProcess.SessionId
    $clientCreated=Test-HostedCapabilityProcessIdentity -ProcessId $clientPid -CreationFileTimeUtc $worker.CreationFileTimeUtc
    if ($clientPid -ne $worker.ProcessId -or !$clientCreated.matches -or $clientSid -cne $sid -or $clientSession -ne $session) {
        throw 'Named-pipe caller PID/creation/SID/session did not match the recorded worker identity'
    }
    $acceptedCaller=$true
    $reader=[IO.StreamReader]::new($server,[Text.UTF8Encoding]::new($false),$false,4096,$true)
    $writer=[IO.StreamWriter]::new($server,[Text.UTF8Encoding]::new($false),4096,$true);$writer.AutoFlush=$true
    Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='worker-pipe-caller-validated';processIdentity=$workerIdentity;resourceIdentity=@{pipeName=$pipeName;pid=$clientPid;sid=$clientSid;sessionId=$clientSession}} | Out-Null
    $pending=$null
    $readTask=$reader.ReadLineAsync()
    $helperReadTask=$null
    $script:helperReadTask=$null
    while ($true) {
        $requestDeadline=$deadlines.work
        if ([Diagnostics.Stopwatch]::GetTimestamp() -ge $requestDeadline) { throw 'Supervisor reached the current absolute work/cleanup deadline while awaiting worker protocol activity' }
        Pump-HostedCapabilityHelper
        if($script:failureEvent.Wait(0) -and !$failureEventObserved){$failureEventObserved=$true;$failure=$true;Write-HostedCapabilityFailure -Ledger $ledger -Code 'global-failure-event-latched' -Evidence @{eventName=$failureEventName;source='cross-process-manual-reset-event'} | Out-Null}
        if (!$readTask.Wait((Get-HostedCapabilityWaitBudget $deadlines.work $frequency 100))) {
            if ($worker.Wait(0)) { $workerExit=$worker.ExitCode;break }
            continue
        }
        $line=$readTask.Result
        if ($null -eq $line) { break }
        $readTask=$reader.ReadLineAsync()
        if ($line.Length -gt 1048576) { throw 'Worker protocol frame exceeded one-megabyte limit' }
        $request=ConvertFrom-Json -InputObject $line -ErrorAction Stop
        if ($request.schema -cne 'ticket569-supervisor-request-v1' -or $request.runId -cne $RunId -or $request.sourceSHA -cne $expectedSha -or !$request.requestId) { throw 'Worker protocol identity/schema mismatch' }
        if($request.phase -ceq 'lifecycle' -and $request.event -ceq 'present-root-recovery-barrier'){Process-HostedPresentRootBarrier $request;continue}
        if ($request.phase -eq 'intent') {
            if ($pending) { throw 'Worker sent a new mutation intent before observing the prior mutation' }
            $replay=Read-HostedCapabilityLedger -Directory $runRoot -RunId $RunId -SourceSHA $expectedSha
            $ownedUser=Get-LocalUser -Name ('t569'+$RunId.Substring(0,10)) -ErrorAction SilentlyContinue
            $context=@{runId=$RunId;sourceSHA=$expectedSha;worker=$workerIdentity;owner=$ownerIdentity;ownerRuntime=$ownerBootstrap.runtimeRoot;userSID=if($ownedUser){$ownedUser.SID.Value}else{$null};session=$script:authoritativeSessionFact;child=$script:expectedUserChildIdentity;scriptRoot=$PSScriptRoot;replay=$replay}
            $null=Assert-HostedCapabilityWorkerIntent -Request $request -Context $context
            $resource=$request.resourceIdentity;$pre=$request.precondition
            if($request.operation -ceq 'create-disposable-local-user' -and $ownedUser){throw 'User create precondition contradicted supervisor OS absence observation'}
            if($resource.profilePath){
                $profile=Get-CimInstance Win32_UserProfile -Filter "SID='$($context.userSID)'" -ErrorAction Stop
                if(!$profile -or $profile.LocalPath -cne $resource.profilePath){throw 'Worker profile resource differs from supervisor OS SID/path observation'}
                if(($pre.profileUnloaded -or $pre.sourceProfileUnloaded -or $pre.sessionUnloaded) -and ($profile.Loaded -or (Test-Path "Registry::HKEY_USERS\$($context.userSID)"))){throw 'Worker unloaded-profile precondition contradicted supervisor OS observation'}
            }
            if($pre.vhdAbsent -and (Test-Path -LiteralPath $resource.vhdPath)){throw 'Worker VHD absence contradicted supervisor OS observation'}
            if($resource.volumeId){
                $image=Get-DiskImage -ImagePath $resource.vhdPath -ErrorAction Stop
                $volumes=@(Get-Partition -DiskNumber $image.Number | Get-Volume)
                if(!$image.Attached -or @($volumes | Where-Object UniqueId -CEQ $resource.volumeId).Count -ne 1){throw 'Worker volume was not uniquely observed on the exact owned VHD'}
            }
            if($resource.diskNumber -ne $null -and [int](Get-DiskImage -ImagePath $resource.vhdPath -ErrorAction Stop).Number -ne [int]$resource.diskNumber){throw 'Worker disk number differs from supervisor-owned VHD observation'}
            if($pre.backupAbsent -and (Test-Path -LiteralPath $resource.backupPath)){throw 'Worker backup absence contradicted supervisor OS observation'}
            if($pre.profilePathAbsent -and (Test-Path -LiteralPath $resource.profilePath)){throw 'Worker profile path absence contradicted supervisor OS observation'}
            if($pre.taskAbsent -and (Get-ScheduledTask -TaskName $resource.taskName -ErrorAction SilentlyContinue)){throw 'Worker task absence contradicted supervisor OS observation'}
            if($resource.taskName -and !$pre.taskAbsent){
                $task=Get-ScheduledTask -TaskName $resource.taskName -ErrorAction Stop
                if($task.Principal.LogonType -cne 'Interactive' -or $task.Principal.RunLevel -cne 'Limited' -or $task.Principal.UserId -notmatch [regex]::Escape($ownedUser.Name)){throw 'Worker task principal/logon/privilege differs from owned user'}
            }
            if($request.operation -ceq 'run-pinned-cua-currentuser-root-prompt'){
                if($script:rootImportGate){throw 'Root importer launch gate already exists'}
                $gateName="Global\Ticket569-$RunId-root-import"
                $null=Invoke-SupervisorRecoveryMutation 'create-owned-root-importer-identity-gate' @{name=$gateName;sid=$context.session.sid} @{initiallyUnsignaled=$true;userSynchronizeOnly=$true} {
                    $script:rootImportGate=New-HostedCapabilityGate -Name $gateName -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)(A;;0x00100000;;;$($context.session.sid))"
                    @{created=$true}
                }
            }
            if($request.operation -ceq 'register-exact-run-scoped-interactive-user-task'){
                $kind=[string]$request.precondition.profileKind
                if($kind -cnotin @('normal','mount-point') -or $script:userProbeGates.ContainsKey($kind)){throw 'User probe gate identity is invalid or duplicated'}
                $targetSID=[string]$request.resourceIdentity.sid
                $script:userProbeGates[$kind]=New-HostedCapabilityGate -Name "Global\Ticket569-$RunId-user-$kind" -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)(A;;0x00100000;;;$targetSID)"
            }
            $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{requestId=$request.requestId;phase='intent';operation=$request.operation;resourceIdentity=$request.resourceIdentity;precondition=$request.precondition;processIdentity=$workerIdentity}
            $pending=@{requestId=$request.requestId;operation=$request.operation;resourceIdentity=(ConvertTo-Json -InputObject $request.resourceIdentity -Compress -Depth 32);phase='intent'}
            $writer.WriteLine((ConvertTo-Json -InputObject @{acknowledged=$true;requestId=$request.requestId;sequence=$event.sequence} -Compress))
        } elseif ($request.phase -eq 'observation') {
            if (!$pending -or $pending.requestId -cne $request.requestId -or $pending.operation -cne $request.operation) { throw 'Worker mutation observation did not match its durable intent' }
            if ($pending.resourceIdentity -cne (ConvertTo-Json -InputObject $request.resourceIdentity -Compress -Depth 32)) { throw 'Worker mutation observation resource identity differed from its durable intent' }
            if($request.operation -eq 'create-disposable-local-user' -and $request.result -eq 'completed'){
                $targetSID=[string]$request.observed.sid
                if($targetSID -notmatch '^S-1-5-21-[0-9-]+$' -or $helperServer.IsConnected){throw 'Helper endpoint SID update lacks an exact created user or arrived after a helper connect'}
                $expectedUser='t569'+$RunId.Substring(0,10)
                $createdUser=Get-LocalUser -Name $expectedUser -ErrorAction Stop
                if($createdUser.SID.Value -cne $targetSID){throw 'Recovery Job DACL update refused a created-user SID/name mismatch'}
                $failureEventDacl="D:P(A;;GA;;;SY)(A;;GA;;;$sid)(A;;0x0002;;;$targetSID)"
                Set-HostedCapabilityGateDacl -Gate $script:failureEvent -DaclSddl $failureEventDacl
                $sha=[Security.Cryptography.SHA256]::Create();try{$failureEventDaclSHA256=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($failureEventDacl))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
                Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='resource';operation='global-failure-event-dacl-extended-for-exact-recovery-sid';resourceIdentity=@{name=$failureEventName;daclSHA256=$failureEventDaclSHA256;recoverySID=$targetSID;modifyStateOnly=$true};observed=@{updatedAfterExactRunUserSid=$true;resetOperationExposed=$false}} | Out-Null
                $dacl="D:P(A;;GA;;;SY)(A;;GA;;;$sid)(A;;0x4;;;$targetSID)"
                $recoveryAclHandle=Open-HostedCapabilityJob -Name $recoveryJobName -Access 0x00040000
                try { Set-HostedCapabilityJobDacl -Job $recoveryAclHandle -DaclSddl $dacl }
                finally { $recoveryAclHandle.Dispose() }
                $helperServer.Dispose()
                $helperServer=New-HostedCapabilityHelperServer $targetSID
                $script:helperAcceptTask=$helperServer.WaitForConnectionAsync()
            }
            $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{requestId=$request.requestId;phase='observation';operation=$request.operation;resourceIdentity=$request.resourceIdentity;observed=$request.observed;result=$request.result;processIdentity=$workerIdentity}
            $pending=$null
            if ($request.result -ne 'completed') { $failure=$true }
            $writer.WriteLine((ConvertTo-Json -InputObject @{acknowledged=$true;requestId=$request.requestId;sequence=$event.sequence} -Compress))
        } elseif ($request.phase -eq 'failure') {
            $failure=$true
            $script:failureEvent.Release()
            $code=([string]$request.code -replace '[^a-z0-9-]','-').Trim('-')
            if (!$code) {$code='worker-failure'}
            $marker=Write-HostedCapabilityFailure -Ledger $ledger -Code $code -Evidence @{source=$request.evidence;processIdentity=$workerIdentity}
            $writer.WriteLine((ConvertTo-Json -InputObject @{acknowledged=$true;requestId=$request.requestId;sequence=$ledger.Sequence;failurePath=$marker.path} -Compress))
        } elseif ($request.phase -eq 'lifecycle' -and $request.event -eq 'root-importer-launch-observed') {
            if(!$pending -or $pending.operation -cne 'run-pinned-cua-currentuser-root-prompt' -or !$script:rootImportGate -or $script:expectedRootImporter){throw 'Importer authorization is outside its one acknowledged prompt mutation'}
            $ownerReceipt=Invoke-SessionOwnerControl (New-SessionOwnerRequest 'importer-identity') 10000
            if(!$ownerReceipt.ok -or !$ownerReceipt.result.retained){throw 'Importer identity did not come from the retained session owner'}
            $importer=$ownerReceipt.result.importer;$reported=$request.observed
            if($importer.pid -ne $reported.pid -or $importer.creationFileTimeUtc -ne $reported.creationFileTimeUtc){throw 'Worker importer launch report differs from authoritative owner receipt'}
            $expectedContext=Get-HelperExpectedSession
            if($importer.sid -cne $expectedContext.sid -or [int]$importer.sessionId -ne $expectedContext.sessionId -or
               $importer.scriptPath -cne (Join-Path $PSScriptRoot 'hosted-root-import.ps1') -or $importer.scriptSHA256 -cne (Get-FileHash -LiteralPath $importer.scriptPath).Hash.ToLowerInvariant()){throw 'Owner importer identity differs from pinned script and exact user session'}
            $childInfo=Get-CimInstance Win32_Process -Filter "ProcessId=$($importer.pid)" -ErrorAction Stop
            $actualSID=(Invoke-CimMethod -InputObject $childInfo -MethodName GetOwnerSid -ErrorAction Stop).Sid
            if($actualSID -cne $importer.sid -or [int]$childInfo.SessionId -ne [int]$importer.sessionId -or
               [uint32]$childInfo.ParentProcessId -ne [uint32]$importer.parent.pid -or [IO.Path]::GetFullPath($childInfo.ExecutablePath) -cne [IO.Path]::GetFullPath($importer.executable)){throw 'Actual importer token/image/parent differs from retained owner launch receipt'}
            $script:rootImporterHandle=Open-HostedCapabilityProcessIdentity -ProcessId ([uint32]$importer.pid) -CreationFileTimeUtc ([long]$importer.creationFileTimeUtc)
            $script:rootImporterParentHandle=Open-HostedCapabilityProcessIdentity -ProcessId ([uint32]$importer.parent.pid) -CreationFileTimeUtc ([long]$importer.parent.creationFileTimeUtc)
            $script:expectedRootImporter=$importer
            if($TestFault -ceq 'present-root-recovery'){
                $initialHealth=Invoke-SessionOwnerControl (New-SessionOwnerRequest 'health' @{requirePromptService=$true}) 30000
                if(!(Test-HostedBoolean $initialHealth.ok $true) -or !(Test-HostedBoolean $initialHealth.result.healthy $true) -or !(Test-HostedBoolean $initialHealth.result.promptServiceAlive $true) -or $initialHealth.result.ownerPID -ne $ownerIdentity.pid -or !$initialHealth.result.promptServiceIdentity.pid -or !$initialHealth.result.promptServiceIdentity.creationFileTimeUtc){throw 'Present Root exercise lacks original prompt-service identity'}
                $script:presentRootPromptIdentity=$initialHealth.result.promptServiceIdentity
                Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='present-root-exercise-original-prompt-service-observed';processIdentity=$script:presentRootPromptIdentity;observed=$initialHealth.result}|Out-Null
            }
            $identityRecord=Get-Content $supervisorIdentityPath -Raw|ConvertFrom-Json
            $identityRecord|Add-Member -NotePropertyName rootImporter -NotePropertyValue $importer -Force
            $identityRecord|Add-Member -NotePropertyName rootImporterParent -NotePropertyValue $importer.parent -Force
            Write-HostedCapabilityAtomicJson -Path $supervisorIdentityPath -Value $identityRecord
            $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='owner-native-launch-receipt-importer-identity-retained';processIdentity=$importer;observed=@{owner=$ownerIdentity;parentHandleRetained=$true;beforeAnyImporterMutation=$true}}
            $null=Invoke-SupervisorRecoveryMutation 'release-exact-root-importer-identity-gate' @{gateName="Global\Ticket569-$RunId-root-import";importer=$importer} @{identityDurablyRecorded=$true;sourceSHA=$expectedSha;sid=$expectedContext.sid;sessionId=$expectedContext.sessionId} {$script:rootImportGate.Release();@{released=$true}}
            $writer.WriteLine((ConvertTo-Json -Compress @{acknowledged=$true;requestId=$request.requestId;sequence=$event.sequence}))
        } elseif ($request.phase -eq 'lifecycle' -and $request.event -eq 'session-owner-shutdown-before-outer-cleanup') {
            if(!$cleanupStarted -or $pending){throw 'Owner shutdown request is outside acknowledged cleanup'}
            $null=Invoke-SupervisorRecoveryMutation 'shutdown-owner-before-worker-outer-logoff' $ownerIdentity @{cleanupStarted=$true;workerCallerValidated=$true} {
                if(!(Stop-HostedSessionOwnerPlanned)){throw 'Session owner did not prove process exit/empty job before outer logoff'}
                @{ownerCleanupComplete=$true;activeProcesses=$ownerJob.ActiveProcesses}
            }
            $writer.WriteLine((ConvertTo-Json -Compress @{acknowledged=$true;requestId=$request.requestId;sequence=$ledger.Sequence;ownerCleanupComplete=$true}))
        } elseif ($request.phase -eq 'lifecycle' -and $request.event -eq 'user-probe-child-identity-observed') {
            $child=$request.observed
            $expectedContext=Get-HelperExpectedSession
            if([int]$child.pid -le 0 -or [long]$child.creationFileTimeUtc -le 0 -or
               $child.sid -cne $expectedContext.sid -or [int]$child.sessionId -ne $expectedContext.sessionId -or
               $child.taskName -cnotin @("Ticket569-$RunId-normal","Ticket569-$RunId-mount-point") -or
               [IO.Path]::GetFullPath([string]$child.scriptPath) -cne [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'hosted-user-capability.ps1')) -or
               $child.scriptSHA256 -notmatch '^[a-f0-9]{64}$') { throw 'Worker task-child identity report was malformed or outside the expected run/user/script context' }
            $task=Get-ScheduledTask -TaskName $child.taskName -ErrorAction Stop
            $expectedUser=Get-LocalUser -Name ('t569'+$RunId.Substring(0,10)) -ErrorAction Stop
            $actual=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$child.pid)" -ErrorAction Stop
            $actualProcess=Get-Process -Id ([int]$child.pid) -ErrorAction Stop
            $actualSID=(Invoke-CimMethod -InputObject $actual -MethodName GetOwnerSid -ErrorAction Stop).Sid
            $actualCreation=$actualProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
            $actualHash=(Get-FileHash -LiteralPath $child.scriptPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if($actualCreation -ne [long]$child.creationFileTimeUtc -or $actualSID -cne $expectedContext.sid -or
               [int]$actualProcess.SessionId -ne $expectedContext.sessionId -or $actualHash -cne $child.scriptSHA256 -or
               !$actual.CommandLine.Contains($child.scriptPath,[StringComparison]::OrdinalIgnoreCase) -or
               $expectedUser.SID.Value -cne $expectedContext.sid -or
               $task.Principal.UserId -notmatch [regex]::Escape($expectedUser.Name)) { throw 'Supervisor OS observation did not validate the worker-reported task-child PID/creation/SID/session/script/task identity' }
            $script:expectedUserChildIdentity=@{pid=[int]$child.pid;creationFileTimeUtc=[long]$child.creationFileTimeUtc;sid=$expectedContext.sid;sessionId=$expectedContext.sessionId;taskName=[string]$child.taskName;scriptPath=[string]$child.scriptPath;scriptSHA256=$actualHash}
            $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='supervisor-validated-user-probe-task-child';processIdentity=$workerIdentity;resourceIdentity=$script:expectedUserChildIdentity;observed=@{taskState=[string]$task.State;ownerSID=$actualSID;sessionId=[int]$actualProcess.SessionId;creationFileTimeUtc=$actualCreation;scriptSHA256=$actualHash}}
            $kind=if($child.taskName -ceq "Ticket569-$RunId-normal"){'normal'}else{'mount-point'}
            if(!$script:userProbeGates[$kind]){throw 'Exact user probe identity gate is absent'}
            $script:userProbeGates[$kind].Release()
            $writer.WriteLine((ConvertTo-Json -InputObject @{acknowledged=$true;requestId=$request.requestId;sequence=$event.sequence} -Compress))
        } elseif ($request.phase -eq 'lifecycle' -and $request.event -eq 'active-user-session-observed') {
            $observedSession=$request.observed.session
            $stepName=[string]$request.observed.stepName
            $expectedUser='t569'+$RunId.Substring(0,10)
            $local=Get-LocalUser -Name $expectedUser -ErrorAction Stop
            $profile=Get-CimInstance Win32_UserProfile -Filter "SID='$($local.SID.Value)'" -ErrorAction Stop
            if($stepName -notin @('exact-active-user-wts-session','vhd-active-user-wts-session') -or
               [string]$observedSession.SID -cne $local.SID.Value -or [int]$observedSession.SessionId -le 0 -or [int]$observedSession.SessionId -eq 0 -or
               [int]$observedSession.State -ne 0 -or [string]$observedSession.User -cne $expectedUser -or !$profile -or !$profile.Loaded -or
               $profile.LocalPath -cne (Join-Path 'C:\Users' $expectedUser)){
                throw 'Worker WTS session fact did not match supervisor-observed active run-user SID/session/loaded-profile identity'
            }
            $profileContext=Get-HostedObservedProfileContext $profile.LocalPath $stepName
            $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='exact-active-user-session-observed';processIdentity=$workerIdentity;resourceIdentity=@{sid=$local.SID.Value;sessionId=[int]$observedSession.SessionId;profilePath=$profile.LocalPath;stepName=$stepName;profileContext=$profileContext};observed=@{state=[int]$observedSession.State;station=[string]$observedSession.Station;user=[string]$observedSession.User;domain=[string]$observedSession.Domain;profileLoaded=[bool]$profile.Loaded}}
            $script:authoritativeSessionFact=@{sid=$local.SID.Value;sessionId=[int]$observedSession.SessionId;profilePath=$profile.LocalPath;stepName=$stepName;profileContext=$profileContext;ledgerSequence=[long]$event.sequence;acknowledgedBySupervisor=$true;workerProcessIdentity=$workerIdentity}
            $writer.WriteLine((ConvertTo-Json -InputObject @{acknowledged=$true;requestId=$request.requestId;sequence=$event.sequence} -Compress))
        } elseif ($request.phase -eq 'lifecycle' -and $request.event -in @('cleanup-started','worker-finalized')) {
            if ($request.event -eq 'worker-finalized' -and !$cleanupStarted) { throw 'Worker finalized before recording cleanup start' }
            $event=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation=$request.event;processIdentity=$workerIdentity;observed=$request.observed}
            if ($request.event -eq 'cleanup-started') { $cleanupStarted=$true }
            if ($request.event -eq 'worker-finalized') { $workerFinalized=$true;$recoveryRequired=(!$request.observed.outerCleanupComplete);$failure=$failure -or ($request.observed.verdict -ne 'feasible-observed') -or !$request.observed.outerCleanupComplete -or $request.observed.writeFailed }
            $writer.WriteLine((ConvertTo-Json -InputObject @{acknowledged=$true;requestId=$request.requestId;sequence=$event.sequence} -Compress))
        } else { throw 'Worker protocol phase is not permitted' }
    }
    if ($pending) { $failure=$true; Write-HostedCapabilityFailure -Ledger $ledger -Code 'mutation-observation-missing' -Evidence $pending | Out-Null }
    if ($helperPending) { $failure=$true; Write-HostedCapabilityFailure -Ledger $ledger -Code 'helper-mutation-observation-missing' -Evidence $helperPending | Out-Null }
    if ($null -eq $workerExit -and $worker.Wait((Get-HostedCapabilityWaitBudget $deadlines.work $frequency 1000))) { $workerExit=$worker.ExitCode }
    $zeroBy=[DateTime]::UtcNow.AddSeconds(5)
    while ($job.ActiveProcesses -ne 0 -and [DateTime]::UtcNow -lt $zeroBy -and [Diagnostics.Stopwatch]::GetTimestamp() -lt $deadlines.work) { Start-Sleep -Milliseconds 25 }
    if ($job.ActiveProcesses -ne 0) { $job.Terminate(137);$failure=$true;Write-HostedCapabilityFailure -Ledger $ledger -Code 'worker-job-not-empty' -Evidence @{activeProcesses=$job.ActiveProcesses} | Out-Null }
    if ($null -eq $workerExit) { $failure=$true;Write-HostedCapabilityFailure -Ledger $ledger -Code 'worker-exit-unobserved' -Evidence @{pid=$worker.ProcessId} | Out-Null }
    elseif ($workerExit -ne 0) { $failure=$true;Write-HostedCapabilityFailure -Ledger $ledger -Code 'worker-nonzero-exit' -Evidence @{exitCode=$workerExit;pid=$worker.ProcessId} | Out-Null }
    if(!$workerFinalized){$recoveryRequired=$true}
} catch {
    $failure=$true;$protocolError=$_.Exception.Message
    if($script:failureEvent){try{$script:failureEvent.Release()}catch{}}
    try { Write-HostedCapabilityFailure -Ledger $ledger -Code 'supervisor-protocol-failure' -Evidence @{message=$protocolError;acceptedCaller=$acceptedCaller;workerExit=$workerExit} | Out-Null } catch {}
    if ($job -and $job.ActiveProcesses -gt 0) { try {$job.Terminate(137)} catch {} }
    if ($worker -and !$worker.Wait((Get-HostedCapabilityWaitBudget $deadlines.work $frequency 5000))) { try {$worker.Terminate(137)} catch {} }
    if($worker -and !$workerFinalized){$recoveryRequired=$true}
} finally {
    if($script:rootImporterHandle -and !$script:rootImporterHandle.Wait(0)){
        $script:rootImporterHandle.Terminate(137)
        if(!$script:rootImporterHandle.Wait((Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 5000))){$failure=$true}
    }
    if($recoveryRequired -and $ownerProcess -and $recoveryJob){
        try {
            Close-HostedCapabilityHelperEndpoint -Reopen
            Drain-HostedCapabilityFinishingHelpers -StopRemaining
            $recovery=Invoke-HostedSessionRecovery
            $recoveryCompleted=[bool]$recovery.sensitiveContextProven
            Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='same-session-recovery-completed-before-j-plus-24';processIdentity=$selfIdentity;resourceIdentity=$recovery} | Out-Null
        } catch {
            $failure=$true
            try{Write-HostedCapabilityFailure -Ledger $ledger -Code 'same-session-recovery-failed' -Evidence @{errorType=$_.Exception.GetType().FullName;message=$_.Exception.Message} | Out-Null}catch{}
            if($recoveryJob.ActiveProcesses -gt 0){try{$recoveryJob.Terminate(137)}catch{}}
        }
    }
    if($ownerProcess -and !$script:ownerCleanupComplete){$null=Stop-HostedSessionOwnerPlanned}
    if($script:failureEvent -and $script:failureEvent.Wait(0) -and !$failureEventObserved){$failureEventObserved=$true;$failure=$true;try{Write-HostedCapabilityFailure -Ledger $ledger -Code 'global-failure-event-latched-during-cleanup' -Evidence @{eventName=$failureEventName} | Out-Null}catch{}}
    try{$runtimeCleanup=Remove-EmptyOwnedRuntimeRoot}catch{$failure=$true;Write-HostedCapabilityFailure -Ledger $ledger -Code 'owned-runtime-directory-remaining' -Evidence @{errorType=$_.Exception.GetType().FullName} | Out-Null}
    $activeProcessesFinal=if($job){try {[uint32]$job.ActiveProcesses}catch{[uint32]::MaxValue}}else{[uint32]0}
    $ownerActiveProcessesFinal=if($ownerJob){try{[uint32]$ownerJob.ActiveProcesses}catch{[uint32]::MaxValue}}else{[uint32]0}
    $recoveryActiveProcessesFinal=if($recoveryJob){try{[uint32]$recoveryJob.ActiveProcesses}catch{[uint32]::MaxValue}}else{[uint32]0}
    $workerTerminationProven=[bool]($worker -and $workerExit -ne $null -and $worker.Wait(0) -and $activeProcessesFinal -eq 0)
    Close-HostedCapabilityHelperEndpoint
    try{Drain-HostedCapabilityFinishingHelpers -StopRemaining}catch{$failure=$true}
    $finalLedgerReplay=Read-HostedCapabilityLedger -Directory $runRoot -RunId $RunId -SourceSHA $expectedSha
    $ledgerReplayProven=[bool]($finalLedgerReplay.valid -and $finalLedgerReplay.pending.Count -eq 0)
    if(!$ledgerReplayProven){$failure=$true;try{Write-HostedCapabilityFailure -Ledger $ledger -Code 'final-ledger-replay-invalid-or-pending' -Evidence @{valid=$finalLedgerReplay.valid;pending=@($finalLedgerReplay.pending);error=$finalLedgerReplay.error} | Out-Null}catch{}}
    else{Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='final-ledger-replay-valid-no-pending-mutations';processIdentity=$selfIdentity;observed=@{sequence=$finalLedgerReplay.sequence;pendingCount=0;failureLatched=[bool]$finalLedgerReplay.failureLatched}} | Out-Null}
    foreach($handle in @($script:rootImporterHandle,$script:rootImporterParentHandle)){if($handle){if(!$handle.Wait((Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 5000))){$failure=$true};$handle.Dispose()}}
    foreach($probeGate in $script:userProbeGates.Values){$probeGate.Dispose()}
    if($script:rootImportGate){$script:rootImportGate.Dispose();$script:rootImportGate=$null}
    if($script:recoveryWorkerHandle){if(!$script:recoveryWorkerHandle.Wait((Get-HostedCapabilityWaitBudget $deadlines.cleanup $frequency 5000))){$failure=$true};$script:recoveryWorkerHandle.Dispose();$script:recoveryWorkerHandle=$null}
    if($server){Close-HostedCapabilitySupervisorConnection -Connection ([pscustomobject]@{Reader=$reader;Writer=$writer;Pipe=$server;Closed=$false})}
    if ($worker) {$worker.Dispose()};if ($job) {$job.Dispose()};if($ownerProcess){$ownerProcess.Dispose()};if($ownerJob){$ownerJob.Dispose()};if($recoveryJob){$recoveryJob.Dispose()};if($script:recoveryGate){$script:recoveryGate.Dispose();$script:recoveryGate=$null}
    if ($ledger) { Close-HostedCapabilityLedger -Ledger $ledger }
    if($script:failureEvent){$script:failureEvent.Dispose();$script:failureEvent=$null}
}
$failureEventSignaled=$false
if($failureEventName){try{$failureEventSignaled=[bool]$failureEventObserved}catch{}}
$workerVerdict='unknown';$workerOuterCleanupComplete=$false
$workerFinalPath=Join-Path $EvidenceDirectory 'hosted-capability-final.json'
if(Test-Path -LiteralPath $workerFinalPath){
    try{$workerFinalRecord=Get-Content -LiteralPath $workerFinalPath -Raw | ConvertFrom-Json -ErrorAction Stop;$candidateVerdict=[string]$workerFinalRecord.verdict;if($candidateVerdict -in @('feasible-observed','unavailable-supported-capability','harness-defect','transient-setup','unknown','cleanup-failed')){$workerVerdict=$candidateVerdict};$workerOuterCleanupComplete=[bool]$workerFinalRecord.outerCleanupComplete}catch{$workerVerdict='unknown'}
}
$failureLatched=[bool]((Test-HostedCapabilityFailure -Ledger $ledger) -or $failureEventSignaled -or $failure -or !$ledgerReplayProven -or $finalLedgerReplay.failureLatched)
$terminationProven=[bool]($workerTerminationProven -and $script:ownerCleanupComplete -and $ownerActiveProcessesFinal -eq 0 -and (!$recoveryRequired -or ($recoveryCompleted -and $recoveryActiveProcessesFinal -eq 0)))
$cleanupStatus=if($terminationProven -and $workerFinalized -and $workerOuterCleanupComplete -and $ledgerReplayProven -and (!$recoveryRequired -or $recoveryCompleted)){'complete'}else{'unverified'}
$cleanupReasons=@()
if(!$terminationProven){$cleanupReasons+='required-process-or-job-termination-proof-missing'}
if(!$workerOuterCleanupComplete){$cleanupReasons+='worker-outer-cleanup-not-proven'}
if($recoveryRequired -and !$recoveryCompleted){$cleanupReasons+='exact-session-recovery-not-proven'}
$cleanupReasons=@($cleanupReasons)+@($finalLedgerReplay.pending | ForEach-Object {"pending-mutation:$($_.operation)"})
$supervisorVerdict=Resolve-HostedCapabilitySupervisorVerdict -TestFault $TestFault -WorkerVerdict $workerVerdict -CleanupStatus $cleanupStatus -TerminationProven $terminationProven -WorkerIdentityProven ([bool]($acceptedCaller -and $workerIdentity -and $workerIdentity.sid -ceq $sid -and $workerIdentity.sessionId -eq $session)) -FailureLatched $failureLatched -LocalFinalWriteProven $false -RecoveryContextProven ([bool](!$recoveryRequired -or $recoveryCompleted))
$failure=$failure -or $failureLatched -or ($workerVerdict -ne 'feasible-observed') -or ($cleanupStatus -ne 'complete')
$record=@{
    schema='ticket569-supervisor-completion-v1';testFault=$TestFault;runId=$RunId;sourceSHA=$expectedSha
    supervisor=$selfIdentity;workerExit=$workerExit;workerCallerValidated=$acceptedCaller
    activeProcesses=$activeProcessesFinal;failure=$failure;failureEventName=$failureEventName;failureEventSignaled=$failureEventSignaled;failureLatched=$failureLatched
    workerVerdict=$workerVerdict;supervisorVerdict=$supervisorVerdict.verdict;primaryVerdict=$supervisorVerdict.primaryVerdict;cleanupStatus=$cleanupStatus;cleanupReasons=$cleanupReasons
    workerTerminationProven=$workerTerminationProven;ownerActiveProcessesFinal=$ownerActiveProcessesFinal;recoveryActiveProcessesFinal=$recoveryActiveProcessesFinal;ledgerReplayValid=[bool]$finalLedgerReplay.valid;ledgerPendingMutationCount=@($finalLedgerReplay.pending).Count
    presentRootExercise=@{intercept=$script:presentRootIntercept;barrier=$script:presentRootBarrier;recoveryEvidence=$script:presentRootRecoveryEvidence;ownedCleanup=if($recovery){$recovery.ownedCleanup}else{$null};cleanupCompletedCounter=$script:presentRootCleanupCounter;independentAbsenceRequired=$true;qualification='Supporting exercise only; overall killed-worker cleanupStatus remains unverified and native proof requires independent validation'}
    ownerCleanupComplete=$script:ownerCleanupComplete;recoveryRequired=$recoveryRequired;recoveryCompleted=$recoveryCompleted;protocolError=$protocolError
    localFinalWriteProven=$false;localFinalCounter=$null;recoveryContextProven=[bool](!$recoveryRequired -or $recoveryCompleted)
    supervisorFinalized=$false;atUtc=[DateTime]::UtcNow.ToString('o')
}
try{
    if([Diagnostics.Stopwatch]::GetTimestamp() -ge $deadlines.final){throw 'Supervisor local final write missed J+25'}
    $completionPath=Join-Path $EvidenceDirectory 'supervisor-complete.json'
    Write-HostedCapabilityAtomicJson -Path $completionPath -Value $record
    $record.localFinalWriteProven=$true
    $record.localFinalCounter=[Diagnostics.Stopwatch]::GetTimestamp()
    if($record.localFinalCounter -ge $deadlines.final){throw 'Supervisor local final flush reached J+25'}
    if($workerFinalRecord.secretCanary.hashes){foreach($canary in $workerFinalRecord.secretCanary.hashes){$check=Test-HostedSecretCanary -Directories @($EvidenceDirectory) -Sha256 $canary.sha256 -Length $canary.length -RollingFingerprint $canary.rollingFingerprint;if($check.leaked){throw 'Supervisor final evidence contains a password canary'}}}
    $supervisorVerdict=Resolve-HostedCapabilitySupervisorVerdict -TestFault $TestFault -WorkerVerdict $workerVerdict -CleanupStatus $cleanupStatus -TerminationProven $terminationProven -WorkerIdentityProven ([bool]($acceptedCaller -and $workerIdentity -and $workerIdentity.sid -ceq $sid -and $workerIdentity.sessionId -eq $session)) -FailureLatched $failureLatched -LocalFinalWriteProven ([bool]$record.localFinalWriteProven) -RecoveryContextProven ([bool]$record.recoveryContextProven)
    $failure=$failure -or ($supervisorVerdict.verdict -ne 'feasible-observed')
    $record.supervisorVerdict=$supervisorVerdict.verdict;$record.primaryVerdict=$supervisorVerdict.primaryVerdict;$record.failure=$failure
    $record.supervisorFinalized=$true
    Write-HostedCapabilityAtomicJson -Path $completionPath -Value $record
    if([Diagnostics.Stopwatch]::GetTimestamp() -ge $deadlines.final){throw 'Supervisor completed its final atomic write at or after J+25'}
}catch{
    $failure=$true
    [Console]::Error.WriteLine((ConvertTo-Json -Compress @{event='ticket569-local-final-write-failed';runId=$RunId;sourceSHA=$expectedSha;verdict='harness-defect';localFinalWriteProven=$false;errorType=$_.Exception.GetType().FullName}))
}
if ($failure) { exit 2 }
exit 0
