$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force

function Assert-Equal($Expected, $Actual, [string] $Message) {
    if ($Expected -cne $Actual) { throw "$Message (expected=$Expected actual=$Actual)" }
}

$frequency = [long]10000000
$start = [long]100000000
$deadlines = Get-HostedCapabilityDeadlines -JobStartCounter $start -CounterFrequency $frequency
Assert-Equal ($start + 9 * 60 * $frequency) $deadlines.launch 'worker launch deadline must be fixed at J+9'
Assert-Equal ($start + 21 * 60 * $frequency) $deadlines.work 'work deadline must be fixed at J+21'
Assert-Equal ($start + 24 * 60 * $frequency) $deadlines.cleanup 'cleanup deadline must be fixed at J+24'
Assert-Equal ($start + 25 * 60 * $frequency) $deadlines.watchdog 'independent watchdog must kill by J+25'
Assert-Equal ($start + 27 * 60 * $frequency) $deadlines.upload 'upload deadline must be fixed at J+27'
Assert-Equal ($start + 30 * 60 * $frequency) $deadlines.job 'outer job bound must remain J+30'

$clock = Test-HostedCapabilityClock -ExpectedBootMarker 'boot-1' -ObservedBootMarker 'boot-1' `
    -ExpectedFrequency $frequency -ObservedFrequency $frequency -JobStartCounter $start -CurrentCounter ($start + 1)
if (-not $clock.valid) { throw 'same-boot monotonic clock was rejected' }
foreach ($case in @(
    @{ boot='boot-2'; frequency=$frequency; counter=$start + 1; message='boot change' },
    @{ boot='boot-1'; frequency=$frequency + 1; counter=$start + 1; message='frequency change' },
    @{ boot='boot-1'; frequency=$frequency; counter=$start - 1; message='counter reversal' }
)) {
    $clock = Test-HostedCapabilityClock -ExpectedBootMarker 'boot-1' -ObservedBootMarker $case.boot `
        -ExpectedFrequency $frequency -ObservedFrequency $case.frequency -JobStartCounter $start -CurrentCounter $case.counter
    if ($clock.valid) { throw "clock contract accepted $($case.message)" }
}

$preparedAt = $start + 2 * 60 * $frequency
$build = Get-HostedCapabilityBuildAllowance -JobStartCounter $start -CounterFrequency $frequency `
    -NonBuildCompleteCounter $preparedAt -NowCounter ($start + 2 * 60 * $frequency)
if (-not $build.allowed -or $build.remainingSeconds -ne 420) { throw 'build allowance must retain the observed 6m14m build within a seven-minute maximum' }
$build = Get-HostedCapabilityBuildAllowance -JobStartCounter $start -CounterFrequency $frequency `
    -NonBuildCompleteCounter ($start + 2 * 60 * $frequency + 1) -NowCounter ($start + 2 * 60 * $frequency + 1)
if ($build.allowed) { throw 'build must not start after the J+2 non-build preparation gate' }
$build = Get-HostedCapabilityBuildAllowance -JobStartCounter $start -CounterFrequency $frequency `
    -NonBuildCompleteCounter $preparedAt -NowCounter ($start + 8 * 60 * $frequency)
if (-not $build.allowed -or $build.remainingSeconds -ne 60) { throw 'build allowance must shrink to the remaining J+9 window' }
$build = Get-HostedCapabilityBuildAllowance -JobStartCounter $start -CounterFrequency $frequency `
    -NonBuildCompleteCounter $preparedAt -NowCounter ($start + 9 * 60 * $frequency)
if ($build.allowed) { throw 'build must not begin at the J+9 worker-launch cutoff' }

$step = Get-HostedProbeStepBackstop -JobStartCounter $start -CounterFrequency $frequency `
    -ActualStepStartCounter ($start + 9 * 60 * $frequency)
Assert-Equal 16 $step.timeoutMinutes 'step timeout must end no later than J+25 when probe step starts at J+9'
$step = Get-HostedProbeStepBackstop -JobStartCounter $start -CounterFrequency $frequency `
    -ActualStepStartCounter ($start + 19 * 30 * $frequency)
Assert-Equal 15 $step.timeoutMinutes 'step timeout must shrink with a later actual step start'
if ($step.watchdogDeadlineCounter -ne $deadlines.watchdog -or $step.deadlineCounter -ne $deadlines.final) { throw 'step backstop must preserve J+24 cleanup before the independent J+25 watchdog' }
$watchdog=Get-HostedCapabilityWatchdogDecision -ClockValid $true -CurrentCounter ($deadlines.watchdog-1) -DeadlineCounter $deadlines.watchdog -CompletionVerified $false
if($watchdog.action -cne 'wait'){throw 'watchdog must retain the independently supervised process tree immediately before J+25'}
$watchdog=Get-HostedCapabilityWatchdogDecision -ClockValid $true -CurrentCounter ($deadlines.watchdog-1) -DeadlineCounter $deadlines.watchdog -CompletionVerified $true
if($watchdog.action -cne 'complete'){throw 'watchdog must accept only a verified exact-run supervisor completion before the hard deadline'}
$watchdog=Get-HostedCapabilityWatchdogDecision -ClockValid $true -CurrentCounter $deadlines.watchdog -DeadlineCounter $deadlines.watchdog -CompletionVerified $true
if($watchdog.action -cne 'terminate' -or $watchdog.reason -cne 'absolute-j-plus-25-watchdog'){throw 'J+25 remains an inclusive independent termination cutoff even if completion arrives late'}
$watchdog=Get-HostedCapabilityWatchdogDecision -ClockValid $false -CurrentCounter ($deadlines.watchdog-1) -DeadlineCounter $deadlines.watchdog -CompletionVerified $true
if($watchdog.action -cne 'terminate' -or $watchdog.reason -cne 'clock-continuity-lost'){throw 'clock discontinuity must fail closed to watchdog termination'}
$upload=Get-HostedCapabilityUploadDecision -ClockValid $true -IndexVerified $true -ActualStepStartCounter ($deadlines.watchdog-1) -JobStartCounter $start -CounterFrequency $frequency -MaximumDurationSeconds 120
if(!$upload.allowed -or $upload.worstCaseFinishCounter -gt $deadlines.upload){throw 'two-minute upload must fit the absolute J+25-start/J+27-finish bound'}
$upload=Get-HostedCapabilityUploadDecision -ClockValid $true -IndexVerified $true -ActualStepStartCounter $deadlines.watchdog -JobStartCounter $start -CounterFrequency $frequency -MaximumDurationSeconds 120
if(!$upload.allowed -or $upload.worstCaseFinishCounter -gt $deadlines.upload){throw 'A canary-clean bounded late upload must still fit J+27'}
$upload=Get-HostedCapabilityUploadDecision -ClockValid $true -IndexVerified $true -ActualStepStartCounter ($deadlines.upload-61*$frequency) -JobStartCounter $start -CounterFrequency $frequency
if(!$upload.allowed -or $upload.maximumDurationSeconds -ne 61){throw 'Late upload must use the shorter remaining seconds cap'}
$upload=Get-HostedCapabilityUploadDecision -ClockValid $true -IndexVerified $true -ActualStepStartCounter ($deadlines.upload-19*$frequency) -JobStartCounter $start -CounterFrequency $frequency
if(!$upload.allowed -or $upload.maximumDurationSeconds -ne 19 -or $upload.worstCaseFinishCounter -gt $deadlines.upload){throw 'A permissible subminute upload must retain its actual seconds budget'}
if((Get-HostedCapabilityWaitBudget 1000 100 5000 999) -ne 10 -or (Get-HostedCapabilityWaitBudget 1000 100 5000 1000) -ne 0){throw 'Nested waits must shrink without borrowing beyond their absolute deadline'}
$upload=Get-HostedCapabilityUploadDecision -ClockValid $true -IndexVerified $false -ActualStepStartCounter ($deadlines.watchdog-1) -JobStartCounter $start -CounterFrequency $frequency -MaximumDurationSeconds 120
if($upload.allowed -or $upload.reason -cne 'evidence-index-unverified'){throw 'upload must be refused when evidence indexing did not validate'}

$closeout=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-capability-closeout.ps1') -Raw
$workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../.github/workflows/hosted-capability.yml') -Raw
$supervisor = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-capability-supervisor.ps1') -Raw
$worker = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-capability.ps1') -Raw
$owner = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-session-owner.ps1') -Raw
$promptService = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted_cua_prompt.py') -Raw
$rootImporter = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-root-import.ps1') -Raw
$recoveryWorker = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-capability-recovery-worker.ps1') -Raw
$recoveryLauncher = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-capability-recovery.ps1') -Raw
$native = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Raw
$indexModule = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-capability-index.psm1') -Raw
$watchdogSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-capability-watchdog.ps1') -Raw
$rootImporterSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-root-import.ps1') -Raw
if ($workflow -notmatch 'timeout-minutes:\s*30' -or
    $workflow -notmatch 'timeout-minutes:\s*\$\{\{ fromJSON\(env\.HOSTED_CAPABILITY_PROBE_TIMEOUT_MINUTES\) \}\}' -or
    $workflow -notmatch 'if:\s*always\(\)' -or
    $workflow -notmatch 'timeout-minutes:\s*2' -or
    $workflow -notmatch "t3code/569-bounded-preflight-20261009") {
    throw 'workflow must use the bounded-preflight branch, actual-start probe backstop before the J+25 watchdog, and always-run two-minute upload'
}
if($workflow -notmatch 'name: Close watchdog window and index evidence[\s\S]*?timeout-minutes:\s*1' -or
   $closeout -notmatch 'HOSTED_CAPABILITY_UPLOAD_ALLOWED' -or
   $closeout -notmatch 'Get-HostedCapabilityUploadDecision' -or
   $workflow -notmatch 'hosted-capability-closeout.ps1' -or
   $closeout -notmatch 'HOSTED_CAPABILITY_EVIDENCE_INDEX_SHA256' -or
   $indexModule -notmatch '\[IO\.Path\]::GetRelativePath' -or
   $indexModule -notmatch 'attempted-unverified' -or
   $indexModule -notmatch 'ArtifactObservedByRoot' -or
   $watchdogSource -notmatch 'Get-HostedCapabilityWatchdogDecision' -or
   $watchdogSource -notmatch 'Stop-HostedCapabilityProcessIdentity' -or
   $watchdogSource -notmatch '\$job\.Terminate\(137\)'){
    throw 'Evidence indexing must be independently audited and the upload action must be gated by the absolute J+25 closeout cutoff; remote retention stays unverified without root API/download proof'
}
if($rootImporterSource -notmatch 'processIdentity=@\{pid=\$process\.Id;creationFileTimeUtc=' -or
   $rootImporterSource -notmatch 'identityCreationRetained=\$true' -or
   $supervisor -notmatch 'exact-certutil-import-process-exit-observed' -or
   $supervisor -notmatch 'validated-helper-process-exit-observed' -or
   $supervisor -match 'outside-worker-importer-certutil-task-helper-lifetime-proof-not-yet-integrated'){
    throw 'Importer/helper process identity and retained-handle exit observations must feed the final supervisor ledger instead of an unconditional cleanup uncertainty'
}
$workerCleanupDisconnect=$worker.IndexOf('Disconnect-OwnedRdp', $worker.IndexOf('} finally {'))
$workerCleanupLogoff=$worker.IndexOf('Wait-ProfileUnloaded -SID')
$workerCleanupRestore=$worker.IndexOf('Invoke-HostedProfileRestoreIfRequired -ProfileState')
$workerCleanupProfile=$worker.IndexOf("-Operation 'remove-exact-unloaded-user-profile'")
$workerCleanupUser=$worker.IndexOf("-Operation 'remove-owned-user-and-group-membership'")
if(@($workerCleanupDisconnect,$workerCleanupLogoff,$workerCleanupRestore,$workerCleanupProfile,$workerCleanupUser | Where-Object {$_ -lt 0}).Count -or
   !($workerCleanupDisconnect -lt $workerCleanupLogoff -and $workerCleanupLogoff -lt $workerCleanupRestore -and $workerCleanupRestore -lt $workerCleanupProfile -and $workerCleanupProfile -lt $workerCleanupUser)){
    throw 'Worker cleanup order must disconnect, unload exact session/hive, restore profile, remove profile registration, and only then remove user/group ownership'
}
$recoveryStart=$supervisor.IndexOf('function Invoke-OwnedPostSessionCleanup')
$ownerShutdown=$supervisor.IndexOf('Stop-HostedSessionOwnerPlanned',$recoveryStart)
$recoveryLogoff=$supervisor.IndexOf("'logoff-exact-recovered-user-session'",$recoveryStart)
if($ownerShutdown -lt $recoveryStart -or $recoveryLogoff -lt 0 -or $ownerShutdown -gt $recoveryLogoff -or
   $supervisor -notmatch 'beforeRecoveryLogoff=\$true' -or
   $supervisor -notmatch 'if\(\$ownerProcess -and !\$script:ownerCleanupComplete\)'){
    throw 'Same-session recovery must attempt retained session-owner shutdown and process/job exit proof before exact-session logoff, with retry/termination fallback'
}
if($supervisor -notmatch 'New-HostedCapabilityHelperServer' -or
   $supervisor -notmatch 'Pump-HostedCapabilityHelper' -or
   $supervisor -notmatch 'validated-helper-pipe-caller' -or
   $supervisor -notmatch 'session-host-health' -or
   $supervisor -notmatch 'currentuser-root-session-host-lost-during-recovery' -or
   $recoveryWorker -notmatch 'session-host-health' -or
   $recoveryWorker -notmatch 'rootStatus=\$rootStatus' -or
   $supervisor -match 'Authenticated Users|S-1-5-11|Everyone' -or
   $supervisor -notmatch 'rootPreabsenceFacts' -or
   $supervisor -notmatch 'rootImportAttempts' -or
   $rootImporter -notmatch 'currentuser-root-exact-thumbprint-preabsence' -or
   $rootImporter -notmatch 'import-exact-currentuser-root-certificate' -or
   $rootImporter -notmatch 'remove-exact-owned-currentuser-root-certificate' -or
   $rootImporter -notmatch 'recovery-remove-exact-owned-currentuser-root-certificate' -or
   $recoveryWorker -notmatch 'recovery-delete-exact-currentuser-synthetic-credential'){
    throw 'Nested CurrentUser import/recovery mutations must be supervisor-acknowledged through the independently serviced helper channel with exact ownership evidence'
}
if($rootImporter -notmatch "ValidateSet\('Import','RemoveOwned'\)" -or
   $rootImporter -notmatch 'Get-HostedRootRemoveOwnedDecision' -or
   $rootImporter -notmatch 'OwnershipPreabsenceSequence' -or
   $rootImporter -notmatch 'OwnershipImportSequence' -or
   $recoveryWorker -notmatch "'recovery-root-removal-ownership'" -or
   $recoveryWorker -notmatch "'-Mode','RemoveOwned'" -or
   $supervisor -notmatch 'helper-fact-recovery-root-removal-ownership'){
    throw 'RemoveOwned must require supervisor-ledger preabsence and import-attempt facts and read back the exact thumbprint absence'
}
$workerPipeConnect=$worker.IndexOf('$script:supervisorConnection=Connect-HostedCapabilitySupervisor')
$runtimeRootMutation=$worker.IndexOf("create-owned-hosted-capability-runtime-root")
$runtimeRootCreate=$worker.IndexOf('New-Item -ItemType Directory -Path $runRoot')
if($workerPipeConnect -lt 0 -or $runtimeRootMutation -le $workerPipeConnect -or $runtimeRootCreate -le $runtimeRootMutation){
    throw 'The shared hosted-capability runtime directory must be created only after the worker connects to the supervisor and through an acknowledged mutation'
}
if ($supervisor -notmatch 'Start-HostedCapabilityProcess -Job \$ownerJob' -or
    $supervisor -notmatch 'session-owner-started-outside-worker-job' -or
    $supervisor -notmatch 'authorize-worker' -or
    $worker -match 'hosted_session_owner\.py' -or
    $worker -notmatch 'passwordTransferPath=''worker-direct-named-pipe''' -or
    $worker -notmatch 'command=''health''' -or
    $worker -notmatch "command='prompt-run'" -or
    $worker -notmatch 'current-user-root-session-lost' -or
    $worker -match '\[Diagnostics\.Process\]::Start\(\$promptStart\)' -or
    $owner -notmatch 'function Start-PromptService' -or
    $owner -notmatch 'function Invoke-PromptService' -or
    $owner -notmatch 'function Stop-PromptService' -or
    $supervisor -notmatch 'promptServiceStopped=\$shutdown\.result\.promptService\.stopped' -or
    $promptService -notmatch 'async def run_service\(' -or
    $promptService -notmatch 'mcp_override=mcp, retain_mcp=True' -or
    $owner -notmatch '@\(''ping'',''--session'',\$SessionName,''--json''\)' -or
    $owner -notmatch 'automatic reconnect is prohibited' -or
    $owner -notmatch 'Get-HostedCapabilityPipeClientProcessId' -or
    $owner -notmatch 'Test-Caller \$ClientPID.*''worker''' -or
    $owner -notmatch 'Test-HostedCapabilityPasswordPeer' -or
    $supervisor -notmatch '''-OwnerJobName'',\$ownerJobName' -or
    $workflow -notmatch '-SessionOwnerJobName') {
    throw 'session host must be supervisor-created in its own job, authorize the worker by identity, and accept passwords only over the worker-direct pipe'
}
if($supervisor -notmatch 'recovery-launch-gate-created' -or
   $supervisor -notmatch 'validated-recovery-launcher-before-release' -or
   $supervisor -notmatch 'release-exact-recovery-launch-gate' -or
   $supervisor -notmatch 'global-failure-event-created' -or
   $supervisor -notmatch 'global-failure-event-dacl-extended-for-exact-recovery-sid' -or
   $supervisor -notmatch 'Resolve-HostedCapabilitySupervisorVerdict' -or
   $supervisor -notmatch 'failureLatched=\$failureLatched' -or
   $supervisor -notmatch 'CleanupStatus \$cleanupStatus' -or
   $supervisor -notmatch 'A;;0x00100000;;;\$targetSID' -or
   $supervisor -match '0x5;;;IU' -or
   $supervisor -notmatch 'ExpectedLauncherSHA256' -or
   $supervisor -notmatch 'ExpectedWorkerSHA256' -or
   $recoveryLauncher -notmatch 'ExpectedLauncherSHA256' -or
   $recoveryLauncher -notmatch 'ExpectedWorkerSHA256' -or
   $recoveryLauncher -notmatch '\-LeaveSuspended' -or
   $recoveryLauncher -notmatch '\$child\.Resume\(\)' -or
   $recoveryLauncher -notmatch 'recordedBeforeResumeQpc' -or
   $recoveryLauncher -notmatch 'suspendedChildValidated=\$true' -or
   $native -notmatch 'CreateEventW' -or
   $native -notmatch 'OpenEventW' -or
   $native -match 'ResetEvent\(') {
    throw 'recovery launch requires exact run-scoped one-way gate, pre-release launcher identity/hash evidence, and a suspended/assigned worker recorded before resume'
}

# Exercise the actual production EOF/close functions with an actual pipe peer
# that disconnects and remains alive. Caller authentication and the Windows
# native handle are stand-ins here; Windows main-path authorization is separate.
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-owner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-protocol.psm1') -Force
$parseErrors=$null;$tokens=$null
$supervisorAst=[Management.Automation.Language.Parser]::ParseInput($supervisor,[ref]$tokens,[ref]$parseErrors)
foreach($functionName in @('Get-HelperDeadline','Drain-HostedCapabilityFinishingHelpers','Pump-HostedCapabilityHelper','Close-HostedCapabilityHelperEndpoint')){
    $definition=$supervisorAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName},$true)
    if($definition.Count -ne 1){throw "Expected one production $functionName"}
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
function New-HostedCapabilityHelperServer($TargetSID){
    [IO.Pipes.NamedPipeServerStream]::new($script:testHelperName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous)
}
function Stop-HostedCapabilityProcessIdentity($ProcessId,$CreationFileTimeUtc,$WaitMilliseconds){
    $actual=Get-Process -Id $ProcessId -ErrorAction Stop
    try{
        if($actual.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $CreationFileTimeUtc){throw 'Fixture stop identity changed'}
        $actual.Kill();@{terminated=$actual.WaitForExit($WaitMilliseconds)}
    }finally{$actual.Dispose()}
}
$frequency=[Diagnostics.Stopwatch]::Frequency
$deadlines=Get-HostedCapabilityDeadlines -JobStartCounter ([Diagnostics.Stopwatch]::GetTimestamp()) -CounterFrequency $frequency
$script:finishingHelpers=[Collections.Generic.List[object]]::new()
$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('ticket569-helper-eof-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory|Out-Null
try{
    foreach($case in @(@{pending=$false;identityMatches=$true},@{pending=$true;identityMatches=$true},@{pending=$false;identityMatches=$false})){
        $withPending=$case.pending
        $runId=[guid]::NewGuid().ToString('N');$sourceSha='a'*40
        $ledger=$null;$peer=$null;$retainedPeer=$null
        $script:helperServer=$null;$script:helperReader=$null;$script:helperWriter=$null;$script:helperProcess=$null
        try{
        $ledger=New-HostedCapabilityLedger -Directory (Join-Path $testDirectory $runId) -RunId $runId -SourceSHA $sourceSha -BootMarker 'fixture-boot' -JobStartCounter 1 -CounterFrequency ([Diagnostics.Stopwatch]::Frequency)
        $script:testHelperName='Ticket569-'+$runId+'-helper'
        $script:helperServer=New-HostedCapabilityHelperServer
        $accept=$script:helperServer.WaitForConnectionAsync()
        $peerScript='$pipe=[IO.Pipes.NamedPipeClientStream]::new(".","'+$script:testHelperName+'",[IO.Pipes.PipeDirection]::InOut);$pipe.Connect(10000);$pipe.Dispose();Start-Sleep -Seconds 30'
        $startInfo=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach($argument in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($peerScript)))){$startInfo.ArgumentList.Add($argument)}
        $peer=[Diagnostics.Process]::Start($startInfo)
            if(!$accept.Wait(10000)){throw 'Actual helper peer did not connect'}
            $script:helperProcess=Get-Process -Id $peer.Id
            $null=$script:helperProcess.Handle
            $retainedPeer=Get-Process -Id $peer.Id;$null=$retainedPeer.Handle
            $script:helperProcessIdentity=@{pid=$peer.Id;creationFileTimeUtc=$peer.StartTime.ToUniversalTime().ToFileTimeUtc();role='recovery-worker';sid='fixture-sid';sessionId=$peer.SessionId}
            $script:expectedRecoveryWorker=$script:helperProcessIdentity.Clone()
            if(!$case.identityMatches){$script:expectedRecoveryWorker.creationFileTimeUtc++}
            $script:recoveryWorkerHandle=[pscustomobject]@{Process=$retainedPeer}
            $script:recoveryWorkerHandle|Add-Member ScriptMethod Wait {param($milliseconds)$this.Process.WaitForExit($milliseconds)}
            $script:helperReader=[IO.StreamReader]::new($script:helperServer,[Text.UTF8Encoding]::new($false),$false,4096,$true)
            $script:helperWriter=[IO.StreamWriter]::new($script:helperServer,[Text.UTF8Encoding]::new($false),4096,$true)
            $script:helperReadTask=$script:helperReader.ReadLineAsync()
            if(!$script:helperReadTask.Wait(10000) -or $null -ne $script:helperReadTask.Result){throw 'Expected actual peer EOF'}
            $script:helperReadDeadlineCounter=$null;$script:helperAcceptTask=$null;$script:helperPending=$null;$script:failure=$false
            $beforeEndpoint=$script:helperServer.SafePipeHandle
            if($withPending){
                $script:helperPending=@{requestId=[guid]::NewGuid().ToString('N');operation='fixture-pending-mutation';resourceIdentity=@{run=$runId}}
                Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event (@{phase='intent';precondition=@{fixture=$true}}+$script:helperPending)|Out-Null
            }
            Pump-HostedCapabilityHelper
            if(!$beforeEndpoint.IsClosed -or !$script:helperAcceptTask){throw 'EOF teardown did not close and reopen its listener'}
            $replay=Read-HostedCapabilityLedger -Directory $ledger.Directory -RunId $runId -SourceSHA $sourceSha
            if(!$replay.valid){throw 'EOF fixture ledger became invalid'}
            if($withPending){
                if(!$script:failure -or !$peer.WaitForExit(0) -or $replay.pending.Count -ne 1 -or !$replay.failureLatched){throw 'Pending EOF must fail, stop exact peer, and preserve durable intent'}
            }elseif(!$case.identityMatches){
                if(!$script:failure -or !$peer.WaitForExit(0) -or !$replay.failureLatched -or $replay.pending.Count){throw 'Unproved handoff identity must stop the peer and latch failure'}
            }else{
                if($peer.WaitForExit(0) -or $script:failure){throw 'Recovery helper connection handoff killed its live retained participant'}
                if(@($replay.events|Where-Object operation -eq 'validated-recovery-helper-connection-handoff').Count -ne 1 -or
                   @($replay.events|Where-Object operation -match 'process-exit|retained-exit').Count){throw 'Handoff must record connection change without claiming process exit'}
                if($script:recoveryWorkerHandle.Wait(0)){throw 'Separate retained recovery participant handle was lost'}
            }
            Write-Output "HELPER_EOF_ACTUAL_PIPE_PROCESS pending=$withPending identity_matches=$($case.identityMatches) auth=fixture native_handle=fixture"
        }finally{
            try{
                if($peer -and !$peer.HasExited){$peer.Kill();if(!$peer.WaitForExit(5000)){throw 'Fixture exact retained helper did not exit within its cleanup bound'}}
            }finally{
                try{
                    if($script:helperReader){$script:helperReader.Dispose()}
                    if($script:helperWriter){try{$script:helperWriter.Dispose()}catch [IO.IOException]{}}
                    if($script:helperServer){$script:helperServer.Dispose()}
                    if($script:helperProcess){$script:helperProcess.Dispose()}
                    if($retainedPeer){$retainedPeer.Dispose()}
                    if($peer){$peer.Dispose()}
                }finally{if($ledger){Close-HostedCapabilityLedger -Ledger $ledger}}
            }
        }
    }
}finally{Remove-Item -LiteralPath $testDirectory -Recurse -Force}
Write-Output 'HOSTED_CAPABILITY_SUPERVISOR_TESTS_PASSED'

# The changed owner-assignment boundary runs in an isolated process so its
# explicit kernel adapters cannot replace types in other source regressions.
& pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'hosted-recovery-owner-assignment-tests.ps1')
if($LASTEXITCODE -ne 0){throw 'Retained-owner recovery assignment regression failed'}
