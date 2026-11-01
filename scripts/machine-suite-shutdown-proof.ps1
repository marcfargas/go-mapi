# Dot-sourced only by the opt-in suite Hosted journey. Launcher is supplied by
# the guest orchestrator: param(ExecutablePath, EvidenceDirectory), returning
# exactly one newly created Diagnostics.Process with an already retained Handle.
# It must use an existing interactive login, clean up its own launch resources
# on failure, and never create a logon or launch an installed per-user app.
$script:suiteOwned = @()
$script:suiteDecoyProcess = $null
$script:suiteDecoyHash = $null
$script:suiteExercise = $null
$script:suiteExpectAbsent = $false
$script:suiteLogin = $null
$script:suiteProbeDescriptor = $null
$script:suiteProbeStarted = $false
$script:suiteProofStarted = [DateTime]::UtcNow
$script:suiteInstalledPath = Join-Path $env:ProgramFiles 'go-mapi\user\go-mapi.exe'

function StartSuiteProofProcess([string]$Path) {
    $started = [DateTime]::UtcNow
    $launched = @(& $SuiteShutdownLauncher -ExecutablePath $Path -EvidenceDirectory $evidence)
    if ($launched.Count -ne 1 -or $launched[0] -isnot [Diagnostics.Process]) {
        throw 'Launcher must return exactly one live Diagnostics.Process with a retained handle; launcher owns cleanup on failure'
    }
    $p = $launched[0]
    # Do not adopt an older process or kill by PID, even on failure.
    $null = $p.Handle
    if ($p.HasExited -or $p.StartTime.ToUniversalTime() -lt $started) { throw 'Launcher did not return a newly owned live process' }
    $script:suiteOwned += $p
    if ($p.Path -ine $Path -or $p.SessionId -le 0) { throw 'Launcher returned the wrong image or session 0' }
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)"
    $owner = Invoke-CimMethod -InputObject $cim -MethodName GetOwnerSid
    $shells = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$($p.SessionId)" | Where-Object {
        $shellOwner = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid
        $shellOwner.ReturnValue -eq 0 -and $shellOwner.Sid -eq $owner.Sid
    })
    if ($owner.ReturnValue -ne 0 -or $shells.Count -eq 0) { throw 'Launcher requires an existing Explorer login matching the app owner and session' }
    if ($Path -ieq $script:suiteInstalledPath) {
        if ($SuiteInterceptionHarness -and $script:suiteLogin -and ($script:suiteLogin.sid -cne $owner.Sid -or $script:suiteLogin.session -ne $p.SessionId)) {
            throw 'Installed shutdown apps must retain the same Explorer owner/session'
        }
        $script:suiteLogin = @{ sid=$owner.Sid; session=$p.SessionId }
    }
    Record 'suite-shutdown-process' ([ordered]@{
        pid=$p.Id; createdAtUtc=$p.StartTime.ToUniversalTime().ToString('o'); createdAtTicks=$p.StartTime.ToUniversalTime().Ticks
        sessionId=$p.SessionId; ownerSid=$owner.Sid; path=$p.Path; sha256=Hash $Path
        launcherSha256=Hash $SuiteShutdownLauncher; existingShellPids=@($shells.ProcessId)
    })
    return $p
}

function AssertSuiteProofAbsent {
    $unexpected = @(Get-Process -Name go-mapi -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $script:suiteInstalledPath })
    if ($unexpected.Count) {
        Record 'suite-shutdown-unexpected-app' @($unexpected | ForEach-Object { @{ pid=$_.Id; createdAtUtc=$_.StartTime.ToUniversalTime().ToString('o'); sessionId=$_.SessionId; path=$_.Path } })
        throw 'Installed suite app present without the next intercept; unexpected processes are not owned for cleanup'
    }
}

function StartSuiteShutdown([string]$InstalledKey, [string]$TargetKey, [switch]$Suspend) {
    if ((ReadAdmissionGate) -cne 'O') { throw 'Suite shutdown exercise requires open admission before launch' }
    AssertSuiteProofAbsent
    if ((Hash $script:suiteInstalledPath) -cne $manifest.packages.$InstalledKey.appSha256) { throw 'Shutdown app differs from installed fixture hash' }
    if (-not $script:suiteDecoyProcess) {
        $script:suiteDecoyHash = Hash $SuiteShutdownDecoy
        $script:suiteDecoyProcess = StartSuiteProofProcess $SuiteShutdownDecoy
    }
    $script:suiteExpectAbsent = $false
    $p = StartSuiteProofProcess $script:suiteInstalledPath
    if ($p.SessionId -ne $script:suiteDecoyProcess.SessionId) { throw 'App and decoy must use the same existing interactive session' }
    $script:suiteExercise = [ordered]@{ process=$p; target=$TargetKey; suspended=[bool]$Suspend; pending=$null; gateClosedAt=$null; exitAt=$null; lastAliveAt=$null }
    # A successfully launched process must stay alive before publication, rather
    # than being a singleton redirect or a startup failure mistaken for shutdown.
    $end = [DateTime]::UtcNow.AddSeconds(2)
    while ([DateTime]::UtcNow -lt $end) {
        if ($p.HasExited -or $script:suiteDecoyProcess.HasExited -or (ReadAdmissionGate) -cne 'O') { throw 'App/decoy failed the live open-admission launch prerequisite' }
        Start-Sleep -Milliseconds 100
    }
    if ($Suspend) {
        if (-not ('GoMapiShutdownProof' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GoMapiShutdownProof {
    [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr process);
}
'@
        }
        $status = [GoMapiShutdownProof]::NtSuspendProcess($p.Handle)
        if ($status -ne 0) { throw "Exact installed app suspension failed: NTSTATUS $status" }
        Record 'suite-shutdown-suspended' @{ pid=$p.Id; createdAtTicks=$p.StartTime.ToUniversalTime().Ticks; atUtc=[DateTime]::UtcNow.ToString('o') }
    }
    Record 'suite-shutdown-armed' @{ installed=$InstalledKey; target=$TargetKey; suspended=[bool]$Suspend; appPid=$p.Id; decoyPid=$script:suiteDecoyProcess.Id; graceSeconds=30; forceSeconds=5 }
}

function ObserveSuiteShutdown {
    if ($script:suiteDecoyProcess -and $script:suiteDecoyProcess.HasExited) { throw 'Same-name separately located decoy exited during suite update' }
    if ($script:suiteExpectAbsent) { AssertSuiteProofAbsent }
    $x = $script:suiteExercise
    if (-not $x -or $x.exitAt) { return }
    $gate = ReadAdmissionGate
    $pending = ReadJson (Join-Path $stateDir 'pending-v2.json')
    if ($pending -and $pending.candidate.packageVersion -eq $manifest.packages.($x.target).release -and
        $pending.PSObject.Properties['appDrainDeadline']) {
        if (-not $x.pending) {
            $x.pending = $pending
            Record 'suite-shutdown-drain' @{ gate=$gate; observedAtUtc=[DateTime]::UtcNow.ToString('o'); pending=$pending }
            WriteJson (Join-Path $evidence "$($x.target)-shutdown-pending.json") $pending
        } elseif ($x.pending.transactionId -cne $pending.transactionId -or $x.pending.attempt -ne $pending.attempt -or
            $x.pending.appDrainDeadline -cne $pending.appDrainDeadline) {
            throw 'Shutdown transaction, attempt or absolute drain deadline changed'
        }
    }
    if ($gate -ceq 'C' -and -not $x.gateClosedAt) {
        $x.gateClosedAt = [DateTime]::UtcNow
        Record 'suite-shutdown-gate-closed' @{ target=$x.target; observedAtUtc=$x.gateClosedAt.ToString('o') }
    }
    if (-not $x.process.HasExited) {
        $x.lastAliveAt = [DateTime]::UtcNow
        if ($pending -and $pending.PSObject.Properties['installer']) { throw 'Installer was created while the exact installed app was alive' }
        if ($x.pending -and [DateTime]::UtcNow -gt ([DateTime]$x.pending.appDrainDeadline).ToUniversalTime().AddSeconds(5)) { throw 'Exact installed app survived the production force bound' }
        return
    }
    $x.exitAt = $x.process.ExitTime.ToUniversalTime()
    Record 'suite-shutdown-exit' @{ target=$x.target; pid=$x.process.Id; exitAtUtc=$x.exitAt.ToString('o'); exitCode=$x.process.ExitCode; observedAtUtc=[DateTime]::UtcNow.ToString('o') }
    if (-not $x.pending -or -not $x.gateClosedAt) { throw 'Missed durable drain deadline or closed admission; shutdown is unproved' }
    $graceEnd = ([DateTime]$x.pending.appDrainDeadline).ToUniversalTime()
    if ($x.exitAt -lt $graceEnd.AddSeconds(-30) -or $x.exitAt -gt $graceEnd.AddSeconds(5)) { throw 'App exit outside the production drain bounds' }
    if ($x.suspended) {
        if ($x.exitAt -lt $graceEnd) { throw 'Suspended app did not remain alive through the full grace interval' }
    } elseif ($x.exitAt -ge $graceEnd -or $x.process.ExitCode -ne 0) {
        throw 'Graceful branch requires successful app exit before force eligibility'
    }
    $script:suiteExpectAbsent = $true
    AssertSuiteProofAbsent
}

function CompleteSuiteShutdown([string]$Key) {
    ObserveSuiteShutdown
    $x = $script:suiteExercise
    if (-not $x -or $x.target -cne $Key -or -not $x.exitAt) { throw 'No exact shutdown exit for committed target' }
    $readyPath = Join-Path $stateDir "ready-$($x.pending.transactionId)-attempt-$($x.pending.attempt)-v1.json"
    $ready = ReadJson $readyPath
    if (-not $ready -or $ready.transactionId -cne $x.pending.transactionId -or $ready.attempt -ne $x.pending.attempt -or
        $ready.runner.pid -ne $x.pending.runner.pid -or $ready.runner.createdAtUnixNano -ne $x.pending.runner.createdAtUnixNano) {
        throw 'Missing matching durable installer-ready evidence'
    }
    if ((Hash $SuiteShutdownDecoy) -cne $script:suiteDecoyHash) { throw 'Separately staged decoy image changed during suite update' }
    $exitNanos = ([decimal]$x.exitAt.Ticks - 621355968000000000d) * 100d
    if ([decimal]$ready.installer.createdAtUnixNano -lt $exitNanos) { throw 'Installer creation preceded exact app exit; no-resume-while-alive is unproved' }
    Copy-Item -LiteralPath $readyPath -Destination (Join-Path $evidence "$Key-shutdown-ready.json") -Force
    Record 'suite-shutdown-proved' @{ target=$Key; suspended=$x.suspended; gateClosedObservedAtUtc=$x.gateClosedAt.ToString('o'); graceEnd=$x.pending.appDrainDeadline; lastAliveObservedAtUtc=$x.lastAliveAt; exitAtUtc=$x.exitAt.ToString('o'); ready=$ready; decoyAlive=$true; decoySha256=$script:suiteDecoyHash; noRelaunch='sampled installed-image absence; no intercept issued' }
}

function InvokeSuiteInterceptionProof([string]$Key) {
    $snapshot = AssertHealthy $Key
    if ($snapshot.pending -or $snapshot.replay.sequence -ne $manifest.packages.$Key.identity.sequence -or
        (ReadAdmissionGate) -cne 'O' -or -not $script:suiteExpectAbsent -or
        -not $script:suiteLogin -or $script:suiteDecoyProcess.HasExited) { throw 'Next interception requires healthy committed C, no pending, open admission, absence and live decoy' }
    AssertSuiteProofAbsent
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $sid = $identity.User.Value } finally { $identity.Dispose() }
    if ($sid -cne $script:suiteLogin.sid -or [Diagnostics.Process]::GetCurrentProcess().SessionId -ne $script:suiteLogin.session) {
        throw 'Run interception proof in the earlier installed app Explorer owner/session'
    }
    $shells = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$($script:suiteLogin.session)" | Where-Object {
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid
        $owner.ReturnValue -eq 0 -and $owner.Sid -ceq $sid
    })
    if (-not $shells.Count) { throw 'Earlier app Explorer login no longer exists' }
    $dll = Join-Path $env:ProgramFiles 'go-mapi\interceptor\AMD64\go-mapi.dll'
    $harnessHash = Hash $SuiteInterceptionHarness
    if ($harnessHash -cne '2b089f9b9aeb7c71f25881874f6ed5a9c0f29503726e1f6e39ae0a49a5ec29cc' -or
        (Hash $dll) -cne $manifest.packages.$Key.x64DllSha256 -or
        (Hash $script:suiteInstalledPath) -cne $manifest.packages.$Key.appSha256) { throw 'Interception harness or installed C bytes differ from retained inputs' }
    $queue = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'go-mapi\queue'))
    foreach ($dir in @((Split-Path $queue -Parent), $queue)) {
        if ((Test-Path -LiteralPath $dir) -and ((Get-Item -LiteralPath $dir).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Queue must not traverse a reparse point' }
    }
    $entries = @(if (Test-Path -LiteralPath $queue) { Get-ChildItem -LiteralPath $queue -Force })
    $before = @($entries | Where-Object { -not $_.PSIsContainer -and $_.Extension -ieq '.json' } | ForEach-Object Name)
    $beforeEntries = @($entries | ForEach-Object Name)
    $p = [Diagnostics.Process]::new()
    $p.StartInfo.FileName = $SuiteInterceptionHarness
    $p.StartInfo.Arguments = '"' + $dll + '" --activation-probe "Simple Send"'
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    $p.StartInfo.CreateNoWindow = $true
    $launchedAt = [DateTime]::UtcNow
    $probe = [ordered]@{ command=('"' + $SuiteInterceptionHarness + '" ' + $p.StartInfo.Arguments); harnessSha256=$harnessHash; dllSha256=Hash $dll; appSha256=Hash $script:suiteInstalledPath; launchAtUtc=$launchedAt.ToString('o'); queue=$queue; ownerSid=$sid; sessionId=$script:suiteLogin.session }
    Record 'suite-interception-command' $probe
    AssertSuiteProofAbsent
    # This is the intentional next interception; absence polling ends here.
    $script:suiteExpectAbsent = $false
    $script:suiteProbeStarted = $true
    $stdout = $null; $stderr = $null
    try {
        if (-not $p.Start()) { throw 'Interception harness did not start' }
        $null = $p.Handle
        $script:suiteOwned += $p
        $harnessCreated = $p.StartTime.ToUniversalTime()
        $probe.pid = $p.Id; $probe.createdAtTicks = $harnessCreated.Ticks
        $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        $end = $launchedAt.AddSeconds(10)
        $app = $null
        do {
            if ($script:suiteDecoyProcess.HasExited) { throw 'Decoy exited during next interception' }
            $apps = @(Get-Process -Name go-mapi -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $script:suiteInstalledPath })
            if ($apps.Count -gt 1) { throw 'Multiple installed apps after next interception; unexplained processes are not owned' }
            if ($apps.Count -eq 1 -and -not $app) {
                $candidate = $apps[0]
                $null = $candidate.Handle
                $created = $candidate.StartTime.ToUniversalTime()
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($candidate.Id)"
                $owner = Invoke-CimMethod -InputObject $cim -MethodName GetOwnerSid
                if ($candidate.HasExited -or $candidate.Path -ine $script:suiteInstalledPath -or
                    $created -lt $launchedAt -or $created -lt $harnessCreated -or
                    ($p.HasExited -and $created -gt $p.ExitTime.ToUniversalTime()) -or
                    $candidate.SessionId -ne $script:suiteLogin.session -or $owner.ReturnValue -ne 0 -or $owner.Sid -cne $sid -or
                    $cim.ParentProcessId -ne $p.Id -or [Math]::Abs(($cim.CreationDate.ToUniversalTime() - $created).Ticks) -ge 10000 -or
                    $p.StartTime.ToUniversalTime().Ticks -ne $harnessCreated.Ticks -or
                    (Hash $candidate.Path) -cne $manifest.packages.$Key.appSha256) {
                    $candidate.Dispose()
                    throw 'New app identity/parent differs from exact owned harness; not adopted for cleanup'
                }
                $app = $candidate
                $script:suiteOwned += $app
                $aliveUntil = [DateTime]::UtcNow.AddSeconds(1)
                $probe.app = @{ pid=$app.Id; parentPid=$cim.ParentProcessId; createdAtTicks=$created.Ticks; createdAtUtc=$created.ToString('o'); sessionId=$app.SessionId; ownerSid=$owner.Sid; path=$app.Path; sha256=Hash $app.Path }
                Record 'suite-interception-owned-app' $probe.app
            }
            if ($app -and $app.HasExited) { throw 'Intercepted app exited before proof completed' }
            if ($p.HasExited -and $app -and [DateTime]::UtcNow -ge $aliveUntil) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $end)
        if (-not $p.HasExited -or -not $app -or [DateTime]::UtcNow -lt $aliveUntil) { throw 'Next interception exceeded ten-second bound or lacked a live app for one second' }
        $p.WaitForExit()
        if (-not $stdout.Wait(1000) -or -not $stderr.Wait(1000)) { throw 'Harness output streams did not close within bound' }
        $output = $stdout.GetAwaiter().GetResult()
        if ($p.ExitCode -ne 0) { throw 'Interception harness failed' }
        $reported = [regex]::Matches($output, '(?m)^Found new JSON file: ([^\r\n]+)\r?$')
        $new = @(Get-ChildItem -LiteralPath $queue -Filter '*.json' -File -Force | Where-Object { $_.Name -cnotin $before })
        if ($reported.Count -ne 1 -or $new.Count -ne 1 -or $new[0].Name -cne $reported[0].Groups[1].Value.TrimEnd("`r") -or
            ($new[0].Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Expected exactly one new queue JSON matching harness filename' }
        $descriptor = $new[0]
        if ($descriptor.BaseName -cin $beforeEntries) { throw 'Descriptor stem existed before interception; not owned for cleanup' }
        $saved = Join-Path $evidence 'suite-interception-descriptor.json'
        Copy-Item -LiteralPath $descriptor.FullName -Destination $saved
        $descriptorHash = Hash $saved
        if ((Hash $descriptor.FullName) -cne $descriptorHash) { throw 'Queue descriptor changed during evidence retention' }
        $json = ReadJson $saved
        Record 'suite-interception-descriptor' @{ filename=$descriptor.Name; sha256=$descriptorHash; rawEvidence=$saved }
        if ($json.version -ne 1 -or $json.interceptorVersion -cne $manifest.packages.$Key.interceptorVersion -or
            $json.subject -cne 'Test Email - Simple Send' -or $json.body -cne 'This is a test email from the go-mapi test harness.' -or
            @($json.recipients.to).Count -ne 1 -or $json.recipients.to[0].address -cne 'test@example.com' -or
            $json.recipients.to[0].name -cne 'Test User' -or @($json.recipients.cc).Count -ne 0 -or
            @($json.recipients.bcc).Count -ne 0 -or @($json.attachments).Count -ne 0) { throw 'Retained Simple Send descriptor content differs' }
        $script:suiteProbeDescriptor = @{ path=$descriptor.FullName; hash=$descriptorHash; queue=$queue; stem=(Join-Path $queue $descriptor.BaseName) }
        Record 'suite-interception-proved' $probe
    } finally {
        # Kill only our exact retained harness on timeout; never a discovered app.
        if ($stdout) {
            if (-not $p.HasExited) { $p.Kill(); if (-not $p.WaitForExit(5000)) { throw 'Owned harness survived timeout cleanup' } }
            $probe.exitCode = $p.ExitCode; $probe.exitAtUtc = $p.ExitTime.ToUniversalTime().ToString('o')
            foreach ($stream in @(@{ task=$stdout; name='stdout' }, @{ task=$stderr; name='stderr' })) {
                if ($stream.task.Wait(1000)) {
                    [IO.File]::WriteAllText((Join-Path $evidence "suite-interception-$($stream.name).txt"), $stream.task.GetAwaiter().GetResult())
                } else { $probe["$($stream.name)RetentionFailure"] = 'Output stream did not close within one second' }
            }
        }
        $probe.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
        Record 'suite-interception-result' $probe
    }
}

function StopSuiteShutdownProof {
    $errors = @()
    # Preserve transaction logs before the harness removes the installed unit.
    try {
        foreach ($file in @('pending-v2.json','last-result-v1.json')) {
            $path = Join-Path $stateDir $file
            if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $evidence "shutdown-final-$file") -Force }
        }
        $logs = Join-Path $env:ProgramData 'go-mapi\updates\logs'
        if (Test-Path -LiteralPath $logs) { Copy-Item -LiteralPath $logs -Destination (Join-Path $evidence 'shutdown-update-logs') -Recurse -Force }
        foreach ($provider in @('MsiInstaller','Service Control Manager')) {
            $rows = @(Get-WinEvent -FilterHashtable @{ LogName=if ($provider -eq 'MsiInstaller') { 'Application' } else { 'System' }; ProviderName=$provider; StartTime=$script:suiteProofStarted } -ErrorAction SilentlyContinue |
                Select-Object TimeCreated, Id, ProviderName, Message)
            WriteJson (Join-Path $evidence "shutdown-$($provider.Replace(' ','-'))-events.json") $rows
        }
    } catch { $errors += "Retaining shutdown evidence: $($_.Exception.Message)" }
    foreach ($p in $script:suiteOwned) {
        try {
            if (-not $p.HasExited) { $p.Kill(); if (-not $p.WaitForExit(5000)) { throw 'Owned exact process survived cleanup' } }
            Record 'suite-shutdown-owned-cleanup' @{ pid=$p.Id; exited=$p.HasExited }
        } catch { $errors += $_.Exception.Message }
        finally { $p.Dispose() }
    }
    if ($script:suiteProbeDescriptor) {
        try {
            $d = $script:suiteProbeDescriptor
            foreach ($dir in @((Split-Path $d.queue -Parent), $d.queue)) {
                if ((Get-Item -LiteralPath $dir).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Queue changed to a reparse point before cleanup' }
            }
            if ((Split-Path $d.path -Parent) -cne $d.queue -or (Split-Path $d.stem -Parent) -cne $d.queue -or
                (Hash $d.path) -cne $d.hash -or ((Get-Item -LiteralPath $d.path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Verified descriptor changed before cleanup' }
            # Simple Send has no attachments: never recursively delete a stem.
            if (Test-Path -LiteralPath $d.stem) {
                $stem = Get-Item -LiteralPath $d.stem
                if (-not $stem.PSIsContainer -or ($stem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                    @(Get-ChildItem -LiteralPath $d.stem -Force).Count) { throw 'Verified descriptor stem is not an empty ordinary directory' }
                Remove-Item -LiteralPath $d.stem
            }
            Remove-Item -LiteralPath $d.path
            Record 'suite-interception-descriptor-cleanup' @{ path=$d.path; sha256=$d.hash }
        } catch { $errors += $_.Exception.Message }
    }
    if ($script:suiteProbeStarted) {
        try { AssertSuiteProofAbsent; $script:suiteExpectAbsent = $true } catch { $errors += $_.Exception.Message }
    }
    if ($errors.Count) { throw ($errors -join '; ') }
}
