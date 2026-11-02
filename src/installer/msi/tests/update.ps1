# Native installed-service proof. Hosted runs on an elevated disposable Windows
# runner; the resumable phases require an external logout/reboot orchestrator.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageManifest,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [ValidateSet('system','suite')][string]$SKU = 'system',
    [ValidateSet('Hosted','PrepareNoUser','VerifyNoUser','InterruptSameBoot','PrepareReboot','VerifyReboot','ReadinessRecovery','Cleanup')][string]$Phase = 'Hosted',
    [int]$FixturePort = 18453,
    [int]$DeadlineMinutes = 35,
    [string]$DeferredInterruptionEvidence,
    [switch]$ExerciseSuiteShutdown,
    [string]$SuiteShutdownLauncher,
    [string]$SuiteShutdownDecoy,
    [string]$SuiteInterceptionHarness,
    [string]$MachineTargetsExecutable
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'UpdateSupport.ps1')
if ($SuiteInterceptionHarness) {
    if (-not $ExerciseSuiteShutdown) { throw '-SuiteInterceptionHarness requires -ExerciseSuiteShutdown' }
    if (-not (Test-Path -LiteralPath $SuiteInterceptionHarness -PathType Leaf)) { throw 'Missing suite interception harness' }
    $SuiteInterceptionHarness = (Resolve-Path -LiteralPath $SuiteInterceptionHarness).Path
}
if ($MachineTargetsExecutable) {
    if (-not (Test-Path -LiteralPath $MachineTargetsExecutable -PathType Leaf)) { throw 'Missing prebuilt machine-targets executable' }
    $MachineTargetsExecutable = (Resolve-Path -LiteralPath $MachineTargetsExecutable).Path
}
if ($ExerciseSuiteShutdown -and ($SKU -ne 'suite' -or $Phase -ne 'Hosted')) {
    throw '-ExerciseSuiteShutdown requires -SKU suite -Phase Hosted'
}
if ($ExerciseSuiteShutdown) {
    foreach ($inputPath in @($SuiteShutdownLauncher, $SuiteShutdownDecoy)) {
        if (-not $inputPath -or -not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
            throw 'Suite shutdown requires an existing-login launcher script and a separately staged same-name decoy executable'
        }
    }
    $SuiteShutdownLauncher = (Resolve-Path -LiteralPath $SuiteShutdownLauncher).Path
    $SuiteShutdownDecoy = (Resolve-Path -LiteralPath $SuiteShutdownDecoy).Path
    if ([IO.Path]::GetExtension($SuiteShutdownLauncher) -ine '.ps1' -or
        [IO.Path]::GetFileName($SuiteShutdownDecoy) -ine 'go-mapi.exe' -or
        $SuiteShutdownDecoy -ieq (Join-Path $env:ProgramFiles 'go-mapi\user\go-mapi.exe')) {
        throw 'Expected a .ps1 launcher and a separately located go-mapi.exe decoy'
    }
    . (Join-Path $PSScriptRoot 'suite-shutdown.ps1')
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
$PackageManifest = [IO.Path]::GetFullPath($PackageManifest)
$manifest = Get-Content -LiteralPath $PackageManifest -Raw | ConvertFrom-Json
$caseA = "${SKU}A"; $caseB = "${SKU}B"; $caseC = "${SKU}C"
if (-not $manifest.packages.$caseA -or -not $manifest.packages.$caseB -or -not $manifest.packages.$caseC) {
    throw "Fixture manifest lacks complete $SKU A/B/C cases"
}
if ($manifest.schema -ne 'go-mapi-machine-test-packages-v1' -or $manifest.fixture.metadataOrigin -ne "https://localhost:$FixturePort" -or
    $manifest.fixture.artifactOrigin -ne "https://localhost:$FixturePort/releases/download/") { throw 'Fixture origin or package manifest mismatch' }
$wrongSkuSystem = if ($manifest.PSObject.Properties['references'] -and $manifest.references.PSObject.Properties['wrongSkuSystem']) {
    $manifest.references.wrongSkuSystem
} else { $null }
if ($wrongSkuSystem -and ($wrongSkuSystem.package.sku -cne 'system' -or
    (Get-FileHash -LiteralPath $wrongSkuSystem.sourceManifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne $wrongSkuSystem.sourceManifestSha256 -or
    (Get-FileHash -LiteralPath $wrongSkuSystem.package.msi -Algorithm SHA256).Hash.ToLowerInvariant() -cne $wrongSkuSystem.package.sha256)) {
    throw 'Wrong-SKU system fixture reference changed'
}
$signing = if ($manifest.fixture.PSObject.Properties['signing']) { [string]$manifest.fixture.signing } elseif (
    $manifest.fixture.signerThumbprint -and $manifest.fixture.signerPublicCertificate) { 'self-signed-disposable' } else {
    throw 'Fixture signing provenance is missing and legacy self-signed fields are incomplete'
}
if ($signing -notin @('self-signed-disposable','pre-signed-Azure')) { throw 'Unknown fixture signing provenance' }
$azureSigned = $signing -eq 'pre-signed-Azure'
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$fixture = Join-Path $evidence 'fixture'
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$ownerPath = Join-Path $evidence 'owner.json'
$events = Join-Path $evidence 'events.ndjson'
$stateDir = Join-Path $env:ProgramData 'go-mapi\service'
$recoveryPath = Join-Path $stateDir "recovery-$SKU-v1.json"
$obstructionPath = Join-Path $stateDir 'readiness-obstruction-v1.json'
$processSubscriptions = @()
$statusPath = Join-Path $env:ProgramData 'go-mapi\status\status-v2.json'
$markerPath = 'HKLM:\SOFTWARE\go-mapi\MachineProduct'
$signer = [string]$manifest.fixture.signerThumbprint
$runId = [guid]::NewGuid().ToString('N')
$overallDeadline = [DateTime]::UtcNow.AddMinutes($DeadlineMinutes)
# Effective service timers, read from the package manifest and never hard-coded
# per environment. A fixture without fixture.timers (every pre-signed fixture and
# any build without -ValidationTimers) runs the production timers, and every wait
# below keeps its production length.
$timers = if ($manifest.fixture.PSObject.Properties['timers']) { $manifest.fixture.timers } else { $null }
$startupDelaySeconds = if ($timers) { [int]$timers.startupDelaySeconds } else { 120 }
$heartbeatSeconds = if ($timers) { [int]$timers.heartbeatSeconds } else { 60 }
$checkIntervalSeconds = if ($timers) { [int]$timers.checkIntervalSeconds } elseif ($manifest.fixture.PSObject.Properties['checkIntervalSeconds']) { [int]$manifest.fixture.checkIntervalSeconds } else { 60 }
$failureBaseSeconds = if ($timers) { [int]$timers.failureDelayBaseSeconds } else { 900 }
# One automatic commit spends 56-62 s in the Windows Installer service replace
# (measured, CI run 36843076430); no timer shortens it.
$installWorkSeconds = 70
# Slow-runner margin of every per-wait limit. The timer terms of a limit describe a
# healthy host; hosted Windows runners add scheduling, antivirus and installer
# start-up delays on top. Worst waits measured under the 5/2/5/30 s timers (CI runs
# 36931761969, 36938262552 and 36940474780): wrong-SKU refusal 5.6 s, untrusted-C
# refusal 7.3 s, automatic B commit 41.3 s, automatic C commit 99.7 s (from the trust
# restore), runner/installer liveness 4.9 s. The margin keeps every limit at three
# times the worst measured wait or more, and no limit reaches six minutes, so a real
# stall still fails within minutes instead of passing inside the phase deadline.
$waitMarginSeconds = 180
$commitPollMilliseconds = if ($timers) { 1000 } else { 5000 }

Record 'runner-context' ([ordered]@{ source=$env:GITHUB_SHA; runId=$env:GITHUB_RUN_ID; runAttempt=$env:GITHUB_RUN_ATTEMPT; imageOS=$env:ImageOS; imageVersion=$env:ImageVersion })
if ($MachineTargetsExecutable) { Record 'machine-targets-tool' @{ path=$MachineTargetsExecutable; sha256=Hash $MachineTargetsExecutable } }
Record 'service-timers' ([ordered]@{ validationTimers=[bool]$timers; startupDelaySeconds=$startupDelaySeconds; heartbeatSeconds=$heartbeatSeconds; checkIntervalSeconds=$checkIntervalSeconds; failureDelayBaseSeconds=$failureBaseSeconds; phase=$Phase; sku=$SKU })
$passed = $false
$cleanupOnExit = $Phase -eq 'ReadinessRecovery' -or $Phase -eq 'Hosted' -or $Phase -eq 'InterruptSameBoot' -or $Phase -eq 'Cleanup'
$cleanupError = $null
$cleanupDeferred = $null
$cleanMachineConfirmed = $false
$primaryError = $null
try {
    if ($Phase -eq 'Cleanup') {
        Record 'cleanup-requested' ([ordered]@{ packageManifest=$PackageManifest; owner=ReadJson $ownerPath })
    } elseif ($Phase -in @('Hosted','ReadinessRecovery','PrepareNoUser','InterruptSameBoot','PrepareReboot')) {
        if ((Get-Service go-mapi -ErrorAction SilentlyContinue) -or @(InstalledTestProducts).Count -ne 0 -or
            (Get-ScheduledTask -TaskName 'go-mapi Auto Update' -ErrorAction SilentlyContinue)) {
            throw 'Clean machine required: go-mapi service, machine product or legacy task already exists'
        }
        $cleanMachineConfirmed = $true
        # A preceding Hosted phase removes fixture trust in finally. Reimport
        # only the exact public certificate bound in the package manifest;
        # the signed MSI bytes and private key are never regenerated.
        RestoreSignerTrust
        InstallFixture
        Target $caseA $manifest.packages.$caseA.serviceVersion
        Target $caseB $manifest.packages.$caseA.serviceVersion
        Target $caseC $manifest.packages.$caseB.serviceVersion
        if ($SKU -eq 'suite' -and $Phase -eq 'Hosted') { Target 'systemB' $manifest.packages.$caseA.serviceVersion 'system' }
        if ($Phase -in @('PrepareNoUser','ReadinessRecovery')) { SelectTarget $caseA }
        Msi '/i' $manifest.packages.$caseA.msi 'bootstrap-A' @('GOMAPI_AUTO_UPDATE=1')
        $a = Until 'healthy A' { $s=Snapshot; if ($s.status.health -eq 'healthy' -and $s.marker.packageRelease -eq $manifest.packages.$caseA.release) { $s } } 3
        Record 'bootstrap' $a
        $owner = ReadJson $ownerPath
        $owner | Add-Member -NotePropertyName baselineServicePid -NotePropertyValue $a.service.processId
        WriteJson $ownerPath $owner
        if ($Phase -notin @('PrepareNoUser','ReadinessRecovery')) {
            if ($SKU -eq 'suite' -and $Phase -eq 'Hosted') {
                $priorDiscovery = ReadJson (Join-Path $stateDir "discovery-$SKU-v1.json")
                $beforeFailures = if ($priorDiscovery) { [int]$priorDiscovery.failures } else { 0 }
                $beforeRequests = RequestCount '/machine/suite/targets.json'
                SelectWrongSkuTarget 'systemB'
                Until 'wrong-SKU rejection' {
                    $s=Snapshot; $d=ReadJson (Join-Path $stateDir "discovery-$SKU-v1.json")
                    if ($d -and (RequestCount '/machine/suite/targets.json') -gt $beforeRequests -and $d.failures -gt $beforeFailures -and
                        $s.marker.packageRelease -eq $manifest.packages.$caseA.release -and -not $s.pending) { $s }
                } -PollMilliseconds $commitPollMilliseconds -Seconds (WaitLimit) | ForEach-Object { Record 'wrong-sku-refused' $_ }
            }
            if ($ExerciseSuiteShutdown) { StartSuiteShutdown $caseA $caseB }
            SelectTarget $caseB
        }
    }
    if ($Phase -eq 'ReadinessRecovery') {
        RunReadinessRecovery $a
    } elseif ($Phase -eq 'Hosted') {
        # A first failure delay can still be owed: suite B follows the wrong-SKU rejection,
        # and under short start-up timers a check may reach the fixture before B is selected.
        $b = Until 'automatic B commit' { $s=Snapshot; if ($s.marker.packageRelease -eq $manifest.packages.$caseB.release -and $s.status.health -eq 'healthy' -and -not $s.pending -and $s.replay.sequence -eq $manifest.packages.$caseB.identity.sequence) { $s } } `
            -PollMilliseconds $(if ($ExerciseSuiteShutdown) { 100 } else { $commitPollMilliseconds }) -Seconds (WaitLimit $failureBaseSeconds -Install)
        $b = AssertCommitted $caseB $a.service.processId
        if ($ExerciseSuiteShutdown) { CompleteSuiteShutdown $caseB }
        $beforeFailures = (ReadJson (Join-Path $stateDir "discovery-$SKU-v1.json")).failures
        $beforeReplay = $b.replay.sequence
        if (-not $azureSigned) {
        RemoveSignerTrust
        $owner = ReadJson $ownerPath
        if ((Test-Path "Cert:\LocalMachine\Root\$signer") -or (Test-Path "Cert:\LocalMachine\TrustedPublisher\$signer") -or
            -not (Test-Path "Cert:\LocalMachine\Root\$($owner.tlsThumbprint)") -or
            (Hash $manifest.packages.$caseC.msi) -ne $manifest.packages.$caseC.sha256) {
            throw 'Owned code-signing trust removal or independent TLS trust is inconsistent'
        }
        Record 'C-owned-trust-removed' ([ordered]@{ signer=$signer; tlsThumbprint=$owner.tlsThumbprint; msiSha256=$manifest.packages.$caseC.sha256 })
        # A restart makes the changed machine certificate trust visible to the
        # service's WinHTTP/WinVerifyTrust process without changing its engine.
        Restart-Service go-mapi -Force
        $cPath = "/releases/download/$($manifest.packages.$caseC.identity.tag)/$($manifest.packages.$caseC.identity.assetName)"
        SelectTarget $caseC
        Until 'untrusted C rejection after artifact GET' {
            $s=Snapshot; $d=ReadJson (Join-Path $stateDir "discovery-$SKU-v1.json")
            if ((RequestCount $cPath) -gt 0 -and $d.failures -gt $beforeFailures -and $s.marker.packageRelease -eq $manifest.packages.$caseB.release -and
                $s.status.health -eq 'healthy' -and -not $s.pending -and $s.replay.sequence -eq $beforeReplay) { $s }
        } -PollMilliseconds $commitPollMilliseconds -Seconds (WaitLimit) | ForEach-Object { Record 'untrusted-C-refused' $_ }
        # The failure count persists across the restart below and sets the delay
        # before C is retried (1 x base, 2 x base, ...). Recorded so a base that
        # lets the count grow during the untrusted window shows in the evidence.
        $atRestore = ReadJson (Join-Path $stateDir "discovery-$SKU-v1.json")
        Record 'failures-at-trust-restore' ([ordered]@{ failures=$atRestore.failures; lastAttemptAt=$atRestore.lastAttemptAt; nextAttemptAt=$atRestore.nextAttemptAt; failureBaseSeconds=$failureBaseSeconds })
        # Keep the target on installed B while launching/suspending B, so an
        # unrelated untrusted retry cannot drain it during setup.
        if ($ExerciseSuiteShutdown) {
            Stop-Service go-mapi
            SelectTarget $caseB
            if (ReadJson (Join-Path $stateDir 'pending-v2.json')) { throw 'C retry already in flight before shutdown setup; refusing unrelated drain' }
        }
        RestoreSignerTrust
        if ((Hash $manifest.packages.$caseC.msi) -ne $manifest.packages.$caseC.sha256) { throw 'C MSI bytes changed across trust restoration' }
        if ($ExerciseSuiteShutdown) {
            StartSuiteShutdown $caseB $caseC -Suspend
            SelectTarget $caseC
        }
        Restart-Service go-mapi -Force
        } else {
            if ((Hash $manifest.packages.$caseC.msi) -ne $manifest.packages.$caseC.sha256) { throw 'Azure-signed C MSI bytes changed' }
            if ($ExerciseSuiteShutdown) { StartSuiteShutdown $caseB $caseC -Suspend }
            SelectTarget $caseC
        }
        $c = Until 'automatic C commit after trust restoration' { $s=Snapshot; if ($s.marker.packageRelease -eq $manifest.packages.$caseC.release -and $s.status.health -eq 'healthy' -and -not $s.pending -and $s.replay.sequence -eq $manifest.packages.$caseC.identity.sequence) { $s } } 28 `
            -PollMilliseconds $(if ($ExerciseSuiteShutdown) { 100 } else { $commitPollMilliseconds }) -Seconds (WaitLimit (2 * $failureBaseSeconds) -Install)
        $c = AssertCommitted $caseC $b.service.processId
        if ($ExerciseSuiteShutdown) { CompleteSuiteShutdown $caseC }
        Msi '/i' $manifest.packages.$caseC.msi 'administrator-disable' @('REINSTALL=ALL','REINSTALLMODE=amus','GOMAPI_AUTO_UPDATE=0')
        $disabled = AssertHealthy $caseC
        if ($disabled.marker.autoUpdateEnabled -ne 0) { throw 'Administrator disable did not persist' }
        AssertAdmissionReopened 'administrator-disable' 15
        $requestsBefore = if (Test-Path (Join-Path $fixture 'requests.ndjson')) { (Get-Content (Join-Path $fixture 'requests.ndjson') -Raw) } else { '' }
        Restart-Service go-mapi -Force
        # The window exceeds one full start-up delay plus one heartbeat cadence, so a
        # disabled service that wrongly checked would have issued a request inside it.
        # Production timers: 120 s + 60 s + 5 s. Validation timers: the manifest's
        # start-up delay, heartbeat and check interval plus 10 s.
        $disabledWindowSeconds = if ($timers) { $startupDelaySeconds + $heartbeatSeconds + $checkIntervalSeconds + 10 } else { 185 }
        if ([DateTime]::UtcNow.AddSeconds($disabledWindowSeconds) -gt $overallDeadline) { throw 'Insufficient test deadline for disabled full startup/cadence window' }
        Start-Sleep -Seconds $disabledWindowSeconds
        $requestsAfter = if (Test-Path (Join-Path $fixture 'requests.ndjson')) { (Get-Content (Join-Path $fixture 'requests.ndjson') -Raw) } else { '' }
        $disabled = AssertHealthy $caseC
        if ($requestsBefore -cne $requestsAfter -or $disabled.pending -or $disabled.marker.autoUpdateEnabled -ne 0 -or $disabled.status.updates -ne 'disabled') { throw 'Disabled resident service issued a request or changed installed state' }
        Record 'disabled-window' ([ordered]@{ seconds=$disabledWindowSeconds; startupDelaySeconds=$startupDelaySeconds; heartbeatSeconds=$heartbeatSeconds; snapshot=$disabled })
        if ($ExerciseSuiteShutdown) { ObserveSuiteShutdown }
        if ($SuiteInterceptionHarness) { InvokeSuiteInterceptionProof $caseC }
    } elseif ($Phase -eq 'PrepareNoUser') {
        Record 'await-external-logoff' (Snapshot)
    } elseif ($Phase -eq 'VerifyNoUser') {
        AssertNoInteractiveUser
        if (-not (Test-Path -LiteralPath $ownerPath)) { throw 'No owned preparation fixture exists' }
        $baseline = AssertHealthy $caseA
        if ($baseline.pending -or ($baseline.replay -and $baseline.replay.sequence -ge $manifest.packages.$caseB.identity.sequence)) {
            throw 'No-user baseline already has a pending or committed B update before publication'
        }
        Record 'no-user-before-publication' $baseline
        SelectTarget $caseB
        Until 'no-user automatic B commit' { $x=Snapshot; if ($x.marker.packageRelease -eq $manifest.packages.$caseB.release -and $x.status.health -eq 'healthy' -and $x.replay.sequence -eq $manifest.packages.$caseB.identity.sequence -and -not $x.pending) { $x } } | Out-Null
        $b = AssertCommitted $caseB $baseline.service.processId
        AssertNoInteractiveUser
        SelectTarget $caseC
        Until 'no-user automatic C commit' { $x=Snapshot; if ($x.marker.packageRelease -eq $manifest.packages.$caseC.release -and $x.status.health -eq 'healthy' -and $x.replay.sequence -eq $manifest.packages.$caseC.identity.sequence -and -not $x.pending) { $x } } | Out-Null
        $c = AssertCommitted $caseC $b.service.processId
        AssertNoInteractiveUser
        Record 'no-user-A-B-C-committed' $c
    } elseif ($Phase -eq 'InterruptSameBoot') {
        # The runner/installer pair is live only while msiexec runs (a few
        # seconds). A 5-second poll phase-locks to the service's fixed startup
        # delay and can miss that window on every attempt; poll sub-second.
        $livenessWaitStartedUtc = [DateTime]::UtcNow
        try {
            $pending = Until 'matching runner and installer liveness' {
                $p=ReadJson (Join-Path $stateDir 'pending-v2.json')
                if ($p -and $p.candidate.packageVersion -eq $manifest.packages.$caseB.release -and (MatchingLiveTransaction $p)) { $p }
            } 12 200 -Seconds (WaitLimit 0 -Install)
        } catch { CollectUpdateEvidence 'handoff-stall' $livenessWaitStartedUtc | Out-Null; throw }
        Record 'interruption-observed' $pending
        if (-not (MatchingLiveTransaction $pending)) { throw 'Exact runner/installer identity changed before interruption' }
        $killedAtUtc = [DateTime]::UtcNow
        Stop-Process -Id $pending.runner.pid -Force
        Record 'interruption-runner-killed' ([ordered]@{ killedAtUtc=$killedAtUtc.ToString('o'); windowsInstaller=(WindowsInstallerState) })
        $script:lastWindowsInstallerKey = $null
        # Evidence only: the wait below is about 5 minutes that no validation timer
        # explains. Keep the interrupted install's msiexec log and the Windows
        # Installer service state in the evidence, collected even when the wait fails.
        try {
            $sameboot = Until 'conservative same-boot reconciliation' {
                try {
                    $state = WindowsInstallerState
                    $key = $state | ConvertTo-Json -Compress -Depth 4
                    if ($key -cne $script:lastWindowsInstallerKey) { $script:lastWindowsInstallerKey = $key; Record 'windows-installer-state' $state }
                } catch { Record 'windows-installer-state-error' $_.Exception.Message }
                $s=Snapshot
                $installer=Get-Process -Id $pending.installer.pid -ErrorAction SilentlyContinue
                if (-not $installer -and (-not $s.replay -or $s.replay.sequence -ne $manifest.packages.$caseB.identity.sequence) -and
                    $s.pending -and $s.pending.phase -in @('outcome-unconfirmed','repair-required','reboot-pending','rolled-back')) { $s }
            } 8
        } finally { CollectUpdateEvidence 'interruption' $killedAtUtc $pending | Out-Null }
        Record 'sameboot-conservative' $sameboot
    } elseif ($Phase -eq 'PrepareReboot') {
        $pending = Until 'matching pending before external reboot' {
            $p=ReadJson (Join-Path $stateDir 'pending-v2.json')
            if ($p -and $p.candidate.packageVersion -eq $manifest.packages.$caseB.release -and (MatchingLiveTransaction $p)) { $p }
        } 12 200
        $owner = ReadJson $ownerPath
        $task = "go-mapi-ci-fixture-$($owner.runId)"
        $action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument ("-NoProfile -File `"$PSScriptRoot\https-fixture.ps1`" -PackageManifest `"$PackageManifest`" -FixtureDirectory `"$fixture`" -Port $FixturePort")
        $trigger = New-ScheduledTaskTrigger -AtStartup
        Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest | Out-Null
        if (-not (MatchingLiveTransaction $pending)) { throw 'Exact runner/installer identity changed before reboot interruption' }
        Stop-Process -Id $pending.runner.pid -Force
        WriteJson (Join-Path $evidence 'reboot-intent.json') ([ordered]@{ bootTimeUtc=$owner.bootTimeUtc; requestedAtUtc=[DateTime]::UtcNow.ToString('o'); transactionId=$pending.transactionId; attempt=$pending.attempt; runner=$pending.runner; installer=$pending.installer })
        Record 'interrupted-runner-and-immediate-reboot-request' ([ordered]@{ bootTimeUtc=$owner.bootTimeUtc; task=$task; pending=$pending; snapshot=Snapshot })
        & shutdown.exe /r /t 0
        if ($LASTEXITCODE -ne 0) { throw 'Windows rejected immediate test reboot request' }
    } elseif ($Phase -eq 'VerifyReboot') {
        $owner = ReadJson $ownerPath
        $intent = ReadJson (Join-Path $evidence 'reboot-intent.json')
        $startup = ReadJson (Join-Path $fixture 'startup-pending.json')
        if (-not $intent -or -not $startup -or $startup.pending.transactionId -ne $intent.transactionId -or
            $startup.pending.attempt -ne $intent.attempt -or $startup.pending.runner.pid -ne $intent.runner.pid -or
            $startup.pending.installer.pid -ne $intent.installer.pid -or
            [DateTime]::Parse($startup.bootTimeUtc) -le [DateTime]::Parse($intent.bootTimeUtc)) {
            throw 'No matching pending transaction was captured at startup after the test reboot'
        }
        if ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime() -le [DateTime]::Parse($owner.bootTimeUtc)) { throw 'Boot identity did not change' }
        Until 'postboot healthy B reconciliation' { $x=Snapshot; if ($x.marker.packageRelease -eq $manifest.packages.$caseB.release -and $x.status.health -eq 'healthy' -and -not $x.pending -and $x.replay.sequence -eq $manifest.packages.$caseB.identity.sequence) { $x } } | Out-Null
        $b = AssertCommitted $caseB $owner.baselineServicePid
        SelectTarget $caseC
        Until 'postboot automatic C commit' { $x=Snapshot; if ($x.marker.packageRelease -eq $manifest.packages.$caseC.release -and $x.status.health -eq 'healthy' -and -not $x.pending -and $x.replay.sequence -eq $manifest.packages.$caseC.identity.sequence) { $x } } | Out-Null
        $c = AssertCommitted $caseC $b.service.processId
        Record 'postboot-C-committed' $c
        $cleanupOnExit = $true
    }
    $passed = $true
} catch {
    $primaryError = $_
    if ($Phase -in @('PrepareNoUser','PrepareReboot')) { $cleanupOnExit = $true }
    try { Record 'failure' ([ordered]@{ phase=$Phase; error=($primaryError | Out-String).Trim(); snapshot=Snapshot }) } catch { }
    throw
} finally {
    CompleteUpdateScenario
    $finalSnapshot = $null
    CleanupStep 'snapshot' { $script:finalSnapshot = Snapshot }
    $result = [ordered]@{ schema='go-mapi-machine-update-integration-v1'; phase=$Phase; passed=$passed; cleanupError=$cleanupError; cleanupDeferred=$cleanupDeferred; sourceCommit=$manifest.sourceCommit; packageManifest=[IO.Path]::GetFullPath($PackageManifest); packageManifestSha256=Hash $PackageManifest; finishedAtUtc=[DateTime]::UtcNow.ToString('o'); finalSnapshot=$finalSnapshot }
    WriteJson (Join-Path $evidence "machine-update-$($Phase.ToLowerInvariant()).json") $result
    if ($Phase -eq 'Hosted') { WriteJson (Join-Path $evidence 'machine-update-integration.json') $result }
    if ($cleanupError -and -not $primaryError) { throw "Native test cleanup failed: $cleanupError" }
}
