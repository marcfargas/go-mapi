[CmdletBinding()]
param(
    [Parameter(Mandatory)][long] $JobStartCounter,
    [Parameter(Mandatory)][long] $CounterFrequency,
    [Parameter(Mandatory)][string] $BootMarker,
    [Parameter(Mandatory)][string] $SupervisorIdentityPath,
    [Parameter(Mandatory)][string] $BuildJobName,
    [Parameter(Mandatory)][string] $WorkerJobName,
    [Parameter(Mandatory)][string] $SessionOwnerJobName,
    [Parameter(Mandatory)][string] $RecoveryJobName,
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][string] $SourceSHA,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [int] $TestDeadlineSeconds = 1500,
    [switch] $RequireCloseHandshake
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force
$Utf8NoBom=[Text.UTF8Encoding]::new($false)
if (!(Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) { New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null }
function Write-Atomic([string] $Path,[object] $Value) {
    $temporary=$Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $bytes=$Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $Value -Depth 24 -Compress)+[Environment]::NewLine)
    $stream=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)} finally {$stream.Dispose()}
    [IO.File]::Move($temporary,$Path,$true)
}
$closeGate=$null
if($RequireCloseHandshake){$closeSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$closeGate=New-HostedCapabilityGate -Name "Global\Ticket569-$RunId-watchdog-close" -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$closeSID)"}
function Wait-CloseHandshake {
    if(!$closeGate){return}
    while(!$closeGate.Wait(100)){if([Diagnostics.Stopwatch]::GetTimestamp() -ge $deadline){throw 'Watchdog close handshake reached absolute J+25'}}
    $closeGate.Dispose();$script:closeGate=$null
}
$retainedProcesses=@{};$retainedJobs=@{};$retentionErrors=@{}
$lastIdentity=$null
function Retain-ParticipantHandles {
    if(!(Test-Path -LiteralPath $SupervisorIdentityPath -PathType Leaf)){return}
    $value=Get-Content -LiteralPath $SupervisorIdentityPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if($value.schema -cne 'ticket569-supervisor-identity-v1' -or $value.runId -cne $RunId -or $value.sourceSHA -cne $SourceSHA){throw 'Watchdog participant identity run/source/schema mismatch'}
    $script:lastIdentity=$value
    foreach($role in @('supervisor','worker','sessionOwner','recoveryLauncher','recoveryWorker','rootImporter','rootImporterParent')){
        $identity=$value.$role
        if(!$identity){continue}
        if($retainedProcesses.ContainsKey($role)){
            $old=$retainedProcesses[$role].identity
            if($old.pid -ne $identity.pid -or $old.creationFileTimeUtc -ne $identity.creationFileTimeUtc){throw 'Watchdog refuses replaced participant identity'}
            continue
        }
        try{
            $handle=Open-HostedCapabilityProcessIdentity -ProcessId ([uint32]$identity.pid) -CreationFileTimeUtc ([long]$identity.creationFileTimeUtc)
            $info=Get-CimInstance Win32_Process -Filter "ProcessId=$($identity.pid)" -ErrorAction Stop
            $actualSID=(Invoke-CimMethod -InputObject $info -MethodName GetOwnerSid -ErrorAction Stop).Sid
            if($actualSID -cne $identity.sid -or [int]$info.SessionId -ne [int]$identity.sessionId){$handle.Dispose();throw 'Watchdog participant SID/session differed from retained creation identity'}
            $retainedProcesses[$role]=@{handle=$handle;identity=$identity}
            $retentionErrors.Remove($role)
        }catch{$retentionErrors[$role]=$_.Exception.GetType().FullName}
    }
    foreach($name in @($WorkerJobName,$SessionOwnerJobName,$RecoveryJobName,$BuildJobName)){
        if(!$retainedJobs.ContainsKey($name)){
            try{$retainedJobs[$name]=Open-HostedCapabilityJob -Name $name -Access 0x0010000C}catch{}
        }
    }
}
function Get-RetainedExitProof([int]$WaitMilliseconds=0){
    $proof=[Collections.Generic.List[object]]::new()
    foreach($role in @('supervisor','worker','sessionOwner','recoveryLauncher','recoveryWorker','rootImporter','rootImporterParent')){
        if(!$lastIdentity -or !$lastIdentity.$role){continue}
        if(!$retainedProcesses.ContainsKey($role)){$proof.Add(@{role=$role;retained=$false;exited=$false;error=$retentionErrors[$role]});continue}
        $participant=$retainedProcesses[$role]
        $exited=$participant.handle.Wait($WaitMilliseconds)
        $proof.Add(@{role=$role;identity=$participant.identity;retained=$true;exited=$exited;exitCode=if($exited){$participant.handle.ExitCode}else{$null}})
    }
    @($proof)
}
$sample=Get-HostedCapabilityClockSample
$clock=Test-HostedCapabilityClock -ExpectedBootMarker $BootMarker -ObservedBootMarker $sample.bootMarker -ExpectedFrequency $CounterFrequency -ObservedFrequency $sample.frequency -JobStartCounter $JobStartCounter -CurrentCounter $sample.counter
$deadline=$JobStartCounter + [long]$TestDeadlineSeconds * $CounterFrequency
if (!$clock.valid) { $deadline=$sample.counter }
$completionPath=Join-Path $EvidenceDirectory 'supervisor-complete.json'
$resultPath=Join-Path $EvidenceDirectory 'watchdog-result.json'
while ($true) {
    try {
    Retain-ParticipantHandles
    if($retainedProcesses.Count -ge 3 -and $retainedJobs.Count -ge 3 -and !(Test-Path -LiteralPath (Join-Path $EvidenceDirectory 'watchdog-retained-participants.json'))){Write-Atomic (Join-Path $EvidenceDirectory 'watchdog-retained-participants.json') @{runId=$RunId;sourceSHA=$SourceSHA;roles=@($retainedProcesses.Keys);jobs=@($retainedJobs.Keys)}}
    $sample=Get-HostedCapabilityClockSample
    $clock=Test-HostedCapabilityClock -ExpectedBootMarker $BootMarker -ObservedBootMarker $sample.bootMarker -ExpectedFrequency $CounterFrequency -ObservedFrequency $sample.frequency -JobStartCounter $JobStartCounter -CurrentCounter $sample.counter
    $completionVerified=$false
    if ($clock.valid -and $sample.counter -lt $deadline -and (Test-Path -LiteralPath $completionPath -PathType Leaf)) {
        $completion=Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($completion.runId -ceq $RunId -and $completion.sourceSHA -ceq $SourceSHA -and $completion.supervisorFinalized -eq $true) {
            $completionVerified=$true
        }
    }
    $decision=Get-HostedCapabilityWatchdogDecision -ClockValid $clock.valid -CurrentCounter $sample.counter -DeadlineCounter $deadline -CompletionVerified $completionVerified
    if($decision.action -eq 'complete'){
        $requiredCompletionFields=@('failure','activeProcesses','workerTerminationProven','ownerCleanupComplete','ownerActiveProcessesFinal','recoveryActiveProcessesFinal','ledgerReplayValid','ledgerPendingMutationCount','cleanupStatus','recoveryRequired','recoveryCompleted','localFinalWriteProven','localFinalCounter')
        $completionShape=$requiredCompletionFields.Count -eq @($completion.PSObject.Properties.Name | Where-Object {$_ -in $requiredCompletionFields}).Count
        $exitProof=@(Get-RetainedExitProof 1000)
        $jobsEmpty=($retainedJobs.Count -ge 3 -and @($retainedJobs.Values | Where-Object {$_.ActiveProcesses -ne 0}).Count -eq 0)
        $processProof=($jobsEmpty -and $exitProof.Count -ge 3 -and @($exitProof | Where-Object {!$_.retained -or !$_.exited}).Count -eq 0 -and $completionShape -and $completion.localFinalWriteProven -eq $true -and [long]$completion.localFinalCounter -lt $deadline -and $completion.workerTerminationProven -eq $true -and $completion.ownerCleanupComplete -eq $true -and
            [uint32]$completion.activeProcesses -eq 0 -and [uint32]$completion.ownerActiveProcessesFinal -eq 0 -and
            [uint32]$completion.recoveryActiveProcessesFinal -eq 0 -and $completion.ledgerReplayValid -eq $true -and
            [int]$completion.ledgerPendingMutationCount -eq 0 -and $completion.cleanupStatus -ceq 'complete' -and
            (!$completion.recoveryRequired -or $completion.recoveryCompleted -eq $true))
        $finalizedStatus=if($completion.failure -or !$processProof){'cleanup-failed'}else{'supervisor-completed'}
        Write-Atomic $resultPath @{schema='ticket569-watchdog-v1';runId=$RunId;sourceSHA=$SourceSHA;status=$finalizedStatus;atUtc=$sample.utc;deadlineCounter=$deadline;supervisorFailure=$completion.failure;processProof=$processProof;retainedProcessExits=$exitProof;retainedJobsEmpty=$jobsEmpty;localFinalWriteProven=$completion.localFinalWriteProven;activeProcesses=$completion.activeProcesses;ownerActiveProcesses=$completion.ownerActiveProcessesFinal;recoveryActiveProcesses=$completion.recoveryActiveProcessesFinal;workerTerminationProven=$completion.workerTerminationProven;ledgerReplayValid=$completion.ledgerReplayValid;ledgerPendingMutationCount=$completion.ledgerPendingMutationCount;recoverySkipped=$false}
        Wait-CloseHandshake
        if($finalizedStatus -eq 'cleanup-failed'){exit 2}
        exit 0
    }
    if($decision.action -eq 'terminate'){$watchdogReason=$decision.reason;break}
    Start-Sleep -Milliseconds 100
    }catch{$watchdogReason='participant-or-completion-evidence-invalid';break}
}
$identity=$null
if (Test-Path -LiteralPath $SupervisorIdentityPath -PathType Leaf) {
    try {
        $identity=Get-Content -LiteralPath $SupervisorIdentityPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($identity.schema -cne 'ticket569-supervisor-identity-v1' -or $identity.runId -cne $RunId -or $identity.sourceSHA -cne $SourceSHA) { throw 'watchdog supervisor identity mismatch' }
    } catch {
        $watchdogReason='supervisor-identity-untrusted';$identity=$lastIdentity
    }
} else {
    $watchdogReason='no-supervisor-identity-was-written-before-worker-start'
}
$jobResults=[Collections.Generic.List[object]]::new()
foreach ($name in @($BuildJobName,$WorkerJobName,$SessionOwnerJobName,$RecoveryJobName)) {
    try {
        $job=if($retainedJobs.ContainsKey($name)){$retainedJobs[$name]}else{Open-HostedCapabilityJob -Name $name -Access 0x0010000C}
        try {
            $before=[uint32]$job.ActiveProcesses
            if ($before -gt 0) { $job.Terminate(137) }
            $completionSignaled=[bool]$job.Wait(5000)
            $after=[uint32]$job.ActiveProcesses
            $jobResults.Add(@{name=$name;opened=$true;before=$before;activeAfter=$after;zeroCountObserved=($after -eq 0);jobCompletionSignaled=$completionSignaled;terminated=($after -eq 0)})
        } finally { $job.Dispose() }
    } catch {
        $nativeError=if($_.Exception -is [ComponentModel.Win32Exception]){$_.Exception.NativeErrorCode}else{$null}
        if ($nativeError -eq 2) {
            $jobResults.Add(@{name=$name;opened=$false;absent=$true;activeAfter=0;zeroCountObserved=$true;terminated=$true})
        } else {
            $jobResults.Add(@{name=$name;opened=$false;absent=$false;activeAfter=$null;zeroCountObserved=$false;terminated=$false;errorType=$_.Exception.GetType().FullName;nativeErrorCode=$nativeError})
        }
    }
}
$supervisor=@{terminated=$false;reason='no-trusted-supervisor-identity'}
if($identity.supervisor){$supervisor=Stop-HostedCapabilityProcessIdentity -ProcessId ([uint32]$identity.supervisor.pid) -CreationFileTimeUtc ([long]$identity.supervisor.creationFileTimeUtc) -WaitMilliseconds 5000}
$recoveryLauncher=$null
if($identity.recoveryLauncher){$recoveryLauncher=Stop-HostedCapabilityProcessIdentity -ProcessId ([uint32]$identity.recoveryLauncher.pid) -CreationFileTimeUtc ([long]$identity.recoveryLauncher.creationFileTimeUtc) -WaitMilliseconds 5000}
foreach($role in @('rootImporter','rootImporterParent','recoveryWorker')){if($retainedProcesses.ContainsKey($role)){$handle=$retainedProcesses[$role].handle;if(!$handle.Wait(0)){$handle.Terminate(137);$null=$handle.Wait(5000)}}}
$exitProof=@(Get-RetainedExitProof 1000)
$cleanupProven=($exitProof.Count -ge 3 -and @($exitProof | Where-Object {!$_.retained -or !$_.exited}).Count -eq 0 -and $clock.valid -and $supervisor.terminated -and (!$identity.recoveryLauncher -or $recoveryLauncher.terminated) -and @($jobResults | Where-Object { !$_.terminated }).Count -eq 0)
$record=@{
    schema='ticket569-watchdog-v1';runId=$RunId;sourceSHA=$SourceSHA
    status='cleanup-failed'
    reason=$watchdogReason
    atUtc=$sample.utc;deadlineCounter=$deadline;supervisor=$supervisor;recoveryLauncher=$recoveryLauncher;retainedProcessExits=$exitProof;jobs=@($jobResults)
    recoverySkipped=$true;cleanup=if($cleanupProven){'watchdog-terminated-jobs-and-supervisor; recovery skipped'}else{'termination unproven; recovery skipped'}
}
Write-Atomic $resultPath $record
[Console]::Error.WriteLine((ConvertTo-Json -InputObject @{event='ticket569-watchdog';runId=$RunId;status='cleanup-failed';reason=$record.reason} -Compress))
exit 2
