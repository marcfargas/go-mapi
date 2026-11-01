# Host implementation; sourcing this file does not start Windows Sandbox.
function Get-SandboxHostSessionId { (Get-Process -Id $PID).SessionId }

function Test-SandboxPathWithin([string]$Path, [string]$Root) {
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullPath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-WsbProcess {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutMilliseconds, [hashtable]$Capture = @{})
    # Capture native results independently of evidence storage, including partial timeout output.
    $Capture.ExitCode = $null
    $Capture.Stdout = $null
    $Capture.Stderr = $null
    $Capture.Timeout = $null
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FilePath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $stdout = $null
    $stderr = $null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw 'Could not start wsb client.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            # Kill only this CLI client, never a sandbox viewer or unrelated process.
            $process.Kill()
            [void]$process.WaitForExit(5000)
            $Capture.Timeout = 'Native client timed out.'
            $detail = if ($Arguments[0] -eq 'start') { ' Ownership is unknown; inspect wsb list manually.' } else { '' }
            throw "wsb $($Arguments[0]) timed out.$detail"
        }
        # A child that inherited a pipe must not leave stream draining unbounded.
        $drainTime = [int][Math]::Max(1, $TimeoutMilliseconds - $timer.ElapsedMilliseconds)
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), $drainTime)) {
            $Capture.Timeout = 'Native output streams did not close before the deadline.'
            throw "wsb $($Arguments[0]) timed out while reading output."
        }
        $Capture.ExitCode = $process.ExitCode
    } finally {
        try {
            # Never mix stderr into JSON. Stream capture must not skip process disposal.
            if ($null -ne $stdout -and $stdout.IsCompletedSuccessfully) { $Capture.Stdout = $stdout.Result }
            if ($null -ne $stderr -and $stderr.IsCompletedSuccessfully) { $Capture.Stderr = $stderr.Result }
        } finally {
            $process.Dispose()
        }
    }
    [pscustomobject]$Capture
}

function Invoke-GoMapiSandboxTest {
    [CmdletBinding()]
    param(
        [switch]$Smoke, [string]$InputDirectory, [string]$ScriptPath,
        [ValidateSet('System', 'ExistingLogin')][string]$RunAs = 'System',
        [switch]$RunAsExistingLogin, [switch]$Connect,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [string]$EvidenceRoot = (Join-Path $env:LOCALAPPDATA 'agent-work/retained/go-mapi/sandbox')
    )
    if ($RunAsExistingLogin) { $RunAs = 'ExistingLogin' }
    if ($Connect -and $RunAs -ne 'ExistingLogin') { throw '-Connect requires -RunAs ExistingLogin (or -RunAsExistingLogin).' }
    if ($Smoke -and ($InputDirectory -or $ScriptPath)) { throw '-Smoke cannot be combined with custom inputs.' }
    if (-not $InputDirectory -and -not $ScriptPath) {
        $InputDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../tests/sandbox/smoke'))
        $ScriptPath = 'Smoke.ps1'
    } elseif (-not $InputDirectory -or -not $ScriptPath) {
        throw 'Specify both -InputDirectory and -ScriptPath (relative to that directory).'
    }
    $inputPath = (Get-Item -LiteralPath $InputDirectory).FullName
    if (-not (Test-Path -LiteralPath $inputPath -PathType Container)) { throw 'InputDirectory must be a directory.' }
    $projectPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    foreach ($privateRoot in @($projectPath, $env:USERPROFILE)) {
        if ($privateRoot -and (Test-SandboxPathWithin $privateRoot $inputPath)) {
            throw 'Select an artifact directory, not the repository, user profile, or an ancestor.'
        }
    }
    # Refuse junctions/symlinks before traversal so selected inputs cannot escape their root.
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($inputPath)
    $files = [Collections.Generic.List[object]]::new()
    while ($pending.Count -gt 0) {
        $item = Get-Item -Force -LiteralPath $pending.Dequeue()
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Input contains a reparse point: $($item.FullName)" }
        if ($item.Name -eq '.git' -or $item.Name -like '.env*') { throw "Input contains private repository/environment material: $($item.FullName)" }
        if ($item.PSIsContainer) {
            foreach ($child in Get-ChildItem -Force -LiteralPath $item.FullName) { $pending.Enqueue($child.FullName) }
        } else { $files.Add($item) }
    }
    if ([IO.Path]::IsPathRooted($ScriptPath)) { throw 'ScriptPath must be relative to InputDirectory.' }
    $scriptFullPath = [IO.Path]::GetFullPath((Join-Path $inputPath $ScriptPath))
    if (-not (Test-SandboxPathWithin $scriptFullPath $inputPath) -or
        [IO.Path]::GetExtension($scriptFullPath) -ne '.ps1' -or
        -not (Test-Path -LiteralPath $scriptFullPath -PathType Leaf)) {
        throw 'ScriptPath must select an existing .ps1 inside InputDirectory.'
    }
    $evidenceBase = [IO.Path]::GetFullPath($EvidenceRoot)
    if (Test-SandboxPathWithin $evidenceBase $inputPath) { throw 'EvidenceRoot must be outside InputDirectory.' }
    $sessionId = Get-SandboxHostSessionId
    if ($sessionId -eq 0) {
        throw 'Windows Sandbox requires an interactive desktop session. This process is in session 0 (service context); start this runner from an interactive desktop PowerShell. No sandbox was started.'
    }
    $wsb = (Get-Command wsb -CommandType Application -ErrorAction Stop).Source
    $mutex = [Threading.Mutex]::new($false, 'Local\go-mapi-sandbox-runner')
    $locked = $false
    $commandState = @{ Sequence = 0; OwnedId = $null }
    $evidenceErrors = [Collections.Generic.List[string]]::new()
    $runPath = $null
    $failure = $null
    $cleanupFailure = $null
    $connectClient = $null
    $summary = [ordered]@{ Status = 'FAIL'; SandboxId = $null; Cleanup = 'not-started'; CleanupError = $null; RunAs = $RunAs; Connect = [bool]$Connect; SessionId = $sessionId; InputDirectory = $inputPath; ScriptPath = $ScriptPath; TimeoutSeconds = $TimeoutSeconds }
    function Write-SandboxEvidence([string]$Path, $Value, [switch]$Json) {
        try {
            if ($Json) { $Value = ConvertTo-Json -InputObject $Value -Depth 5 -ErrorAction Stop }
            $Value | Set-Content -LiteralPath $Path -ErrorAction Stop
        } catch {
            $evidenceErrors.Add("${Path}: $($_.Exception.Message)")
        }
    }
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another go-mapi sandbox runner owns this desktop session; refusing to start.' }
        $runPath = Join-Path $evidenceBase ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $runPath -Force | Out-Null
        Write-Host "Sandbox evidence: $runPath"
        $outputPath = Join-Path $runPath 'output'
        New-Item -ItemType Directory -Path $outputPath | Out-Null
        $manifest = @($files | ForEach-Object { [ordered]@{ Path = [IO.Path]::GetRelativePath($inputPath, $_.FullName); SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash; Bytes = $_.Length } })
        Write-SandboxEvidence -Path (Join-Path $runPath 'inputs.json') -Value $manifest -Json
        if ($evidenceErrors.Count -gt 0) { throw 'Sandbox evidence could not be written.' }
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        function Invoke-CheckedWsb([string[]]$Arguments, [switch]$Json, [switch]$Cleanup, [int]$AttemptMilliseconds = 0) {
            $remaining = if ($Cleanup) { 30000 } else { [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds) }
            if ($AttemptMilliseconds -gt 0) { $remaining = [Math]::Min($remaining, $AttemptMilliseconds) }
            if ($remaining -le 0) { throw 'Sandbox run timed out.' }
            $commandState.Sequence++
            $prefix = Join-Path $runPath ('{0:d2}-{1}' -f $commandState.Sequence, $Arguments[0])
            Write-SandboxEvidence -Path "$prefix.arguments.json" -Value $Arguments -Json
            $capture = @{}
            $parsed = $null
            try {
                $result = Invoke-WsbProcess -FilePath $wsb -Arguments $Arguments -TimeoutMilliseconds $remaining -Capture $capture
                if ($result.ExitCode -ne 0) { throw "wsb $($Arguments[0]) failed (host exit $($result.ExitCode)); see $prefix.stderr.txt" }
                if ($Json) {
                    if ([string]::IsNullOrWhiteSpace($result.Stdout)) { throw "wsb $($Arguments[0]) returned empty JSON." }
                    $parsed = $result.Stdout | ConvertFrom-Json -ErrorAction Stop
                }
                if ($Arguments[0] -eq 'start') {
                    if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['Id'] -or
                        $parsed.Id -isnot [string] -or [string]::IsNullOrWhiteSpace($parsed.Id)) {
                        throw 'wsb start did not return an owned ID. Inspect wsb list manually; no unowned environment will be stopped.'
                    }
                    # Establish ownership before any result/stream evidence writes can fail.
                    $commandState.OwnedId = $parsed.Id
                    $summary.SandboxId = $parsed.Id
                    $summary.Cleanup = 'pending'
                }
            } finally {
                foreach ($field in @('ExitCode', 'Stdout', 'Stderr', 'Timeout')) {
                    if ($capture.ContainsKey($field) -and $null -ne $capture[$field]) {
                        $suffix = if ($field -eq 'ExitCode') { 'exit-code' } else { $field.ToLowerInvariant() }
                        Write-SandboxEvidence -Path "$prefix.$suffix.txt" -Value $capture[$field]
                    }
                }
            }
            # Cleanup must execute even when its arguments or result cannot be persisted.
            if (-not $Cleanup -and $evidenceErrors.Count -gt 0) { throw 'Sandbox evidence could not be written.' }
            if ($Json) { return $parsed }
        }
        $existing = Invoke-CheckedWsb -Arguments @('list', '--raw') -Json
        if ($null -eq $existing -or $null -eq $existing.PSObject.Properties['WindowsSandboxEnvironments'] -or $existing.WindowsSandboxEnvironments -isnot [array]) {
            throw 'wsb list returned an unexpected schema; refusing to assume no existing sandbox.'
        }
        if ($existing.WindowsSandboxEnvironments.Count -gt 0) { throw 'Existing sandbox found; refusing to stop or reuse it. Close it yourself before retrying.' }
        $null = Invoke-CheckedWsb -Arguments @('start', '--raw') -Json
        $ownedId = $commandState.OwnedId
        Write-SandboxEvidence -Path (Join-Path $runPath 'sandbox-id.txt') -Value $ownedId
        if ($evidenceErrors.Count -gt 0) { throw 'Sandbox evidence could not be written.' }
        Invoke-CheckedWsb -Arguments @('share', '--id', $ownedId, '--host-path', $inputPath, '--sandbox-path', 'C:\input', '--raw')
        Invoke-CheckedWsb -Arguments @('share', '--id', $ownedId, '--host-path', $outputPath, '--sandbox-path', 'C:\output', '--allow-write', '--raw')
        if ($Connect) {
            # Start-Process joins its argument array: quote the exact owned ID for native parsing.
            $quotedId = '"' + [regex]::Replace([regex]::Replace($ownedId, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
            Write-SandboxEvidence -Path (Join-Path $runPath 'connect.arguments.json') -Value @('connect', '--id', $ownedId) -Json
            if ($evidenceErrors.Count -gt 0) { throw 'Sandbox evidence could not be written.' }
            $connectClient = Start-Process -FilePath $wsb -ArgumentList @('connect', '--id', $quotedId) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runPath 'connect.stdout.txt') -RedirectStandardError (Join-Path $runPath 'connect.stderr.txt') -ErrorAction Stop
            $null = $connectClient.Handle
        }
        if ($RunAs -eq 'ExistingLogin') {
            $readyDeadline = [DateTime]::UtcNow.AddSeconds(90)
            if ($deadline -lt $readyDeadline) { $readyDeadline = $deadline }
            $attempt = 0
            while ($true) {
                if ($connectClient -and $connectClient.HasExited -and $connectClient.ExitCode -ne 0) { throw "wsb connect failed (host exit $($connectClient.ExitCode))." }
                $remaining = [int][Math]::Floor(($readyDeadline - [DateTime]::UtcNow).TotalMilliseconds)
                if ($remaining -le 0) { throw 'ExistingLogin readiness timed out; selected script was not executed.' }
                $attempt++
                $probeName = "readiness-$attempt.json"
                # A harmless probe observes the existing token and shell; it never creates a login.
                $probeCommand = @'
$ErrorActionPreference = 'Stop'
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $session = (Get-Process -Id $PID).SessionId
    if ($session -le 0) { throw 'Probe has no interactive session.' }
    $shell = Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" | Where-Object {
        $_.SessionId -eq $session -and (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction Stop).Sid -eq $identity.User.Value
    } | Select-Object -First 1
    if (-not $shell) { throw 'No Explorer for the probe session and owner SID.' }
    $owner = Invoke-CimMethod -InputObject $shell -MethodName GetOwnerSid -ErrorAction Stop
    if ($owner.ReturnValue -ne 0) { throw 'Explorer owner lookup failed.' }
    [ordered]@{ ProbeSessionId = $session; ProbeOwnerSid = $identity.User.Value; ExplorerSessionId = $shell.SessionId; ExplorerOwnerSid = $owner.Sid } |
        ConvertTo-Json | Set-Content -LiteralPath 'C:\output\PROBE_NAME' -ErrorAction Stop
    exit 0
} catch { Write-Error -ErrorRecord $_ -ErrorAction Continue; exit 1 }
'@
                $probeCommand = $probeCommand.Replace('PROBE_NAME', $probeName)
                $probeEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeCommand))
                try {
                    $probe = Invoke-CheckedWsb -Arguments @('exec', '--id', $ownedId, '--command', "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $probeEncoded", '--working-directory', 'C:\input', '--run-as', 'ExistingLogin', '--raw') -Json -AttemptMilliseconds ([Math]::Min(5000, $remaining))
                    if ($null -eq $probe -or $null -eq $probe.PSObject.Properties['ExitCode'] -or
                        ($probe.ExitCode -isnot [int] -and $probe.ExitCode -isnot [long]) -or $probe.ExitCode -ne 0) { throw 'Readiness probe did not return integer guest ExitCode zero.' }
                    $ready = Get-Content -LiteralPath (Join-Path $outputPath $probeName) -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($null -eq $ready -or ($ready.ProbeSessionId -isnot [long] -and $ready.ProbeSessionId -isnot [int]) -or
                        ($ready.ExplorerSessionId -isnot [long] -and $ready.ExplorerSessionId -isnot [int]) -or
                        $ready.ProbeSessionId -le 0 -or $ready.ExplorerSessionId -ne $ready.ProbeSessionId -or
                        $ready.ProbeOwnerSid -isnot [string] -or $ready.ProbeOwnerSid -notmatch '^S-1-\d+(-\d+)+$' -or
                        $ready.ExplorerOwnerSid -cne $ready.ProbeOwnerSid) { throw 'Readiness evidence has no matching Explorer session and owner SID.' }
                    if ([DateTime]::UtcNow -ge $readyDeadline) { throw 'Readiness probe completed after its deadline.' }
                    break
                } catch {
                    Write-SandboxEvidence -Path (Join-Path $runPath "readiness-$attempt.error.txt") -Value $_.Exception.Message
                    if ($evidenceErrors.Count -gt 0) { throw 'Sandbox evidence could not be written.' }
                    $pause = [int][Math]::Min(250, [Math]::Max(0, ($readyDeadline - [DateTime]::UtcNow).TotalMilliseconds))
                    if ($pause -gt 0) { Start-Sleep -Milliseconds $pause }
                }
            }
            if ($connectClient -and $connectClient.HasExited -and $connectClient.ExitCode -ne 0) { throw "wsb connect failed (host exit $($connectClient.ExitCode))." }
        }
        $guestScript = 'C:\input\' + [IO.Path]::GetRelativePath($inputPath, $scriptFullPath)
        $escapedGuestScript = $guestScript.Replace("'", "''")
        $command = @"
`$ErrorActionPreference = 'Stop'
`$global:LASTEXITCODE = 0
Start-Transcript -Path C:\output\guest.log -Force | Out-Null
try {
    & '$escapedGuestScript' -InputDirectory 'C:\input' -OutputDirectory 'C:\output'
    if (`$LASTEXITCODE -ne 0) {
        `$guestNativeExit = `$LASTEXITCODE
        Write-Error "Guest native command exited `$guestNativeExit" -ErrorAction Continue
        exit `$guestNativeExit
    }
} catch {
    Write-Error -ErrorRecord `$_ -ErrorAction Continue
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $executed = Invoke-CheckedWsb -Arguments @('exec', '--id', $ownedId, '--command', "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded", '--working-directory', 'C:\input', '--run-as', $RunAs, '--raw') -Json
        if ($null -eq $executed -or $null -eq $executed.PSObject.Properties['ExitCode'] -or
            ($executed.ExitCode -isnot [long] -and $executed.ExitCode -isnot [int])) { throw 'wsb exec returned no integer guest ExitCode.' }
        $summary.GuestExitCode = $executed.ExitCode
        if ($executed.ExitCode -ne 0) { throw "Guest script failed (exit $($executed.ExitCode)); see output/guest.log and exec stdout." }
        $summary.Status = 'PASS'
    } catch {
        $failure = $_
        $summary.Error = $_.Exception.Message
    } finally {
        if ($commandState.OwnedId) {
            try {
                Invoke-CheckedWsb -Arguments @('stop', '--id', $commandState.OwnedId, '--raw') -Cleanup
                $summary.Cleanup = 'stopped'
            } catch {
                $cleanupFailure = $_
                $summary.Cleanup = 'failed'
                $summary.CleanupError = $_.Exception.Message
                $summary.Status = 'FAIL'
            }
        }
        if ($connectClient) {
            try {
                if ($connectClient.HasExited) {
                    Write-SandboxEvidence -Path (Join-Path $runPath 'connect.exit-code.txt') -Value $connectClient.ExitCode
                    if ($connectClient.ExitCode -ne 0) { throw "wsb connect failed (host exit $($connectClient.ExitCode))." }
                } else {
                    $connectClient.Kill()
                    if (-not $connectClient.WaitForExit(5000)) { throw 'Owned connect client did not exit after termination.' }
                    Write-SandboxEvidence -Path (Join-Path $runPath 'connect.exit-code.txt') -Value $connectClient.ExitCode
                    Write-SandboxEvidence -Path (Join-Path $runPath 'connect.cleanup.txt') -Value 'Terminated retained connect client.'
                }
            } catch {
                $summary.Status = 'FAIL'
                $summary.ConnectError = $_.Exception.Message
                if (-not $cleanupFailure) { $cleanupFailure = $_ }
            } finally {
                try { $connectClient.Dispose() } catch {
                    $summary.Status = 'FAIL'
                    $summary.ConnectError = $_.Exception.Message
                    if (-not $cleanupFailure) { $cleanupFailure = $_ }
                }
            }
        }
        try {
            if ($evidenceErrors.Count -gt 0) { $summary.Status = 'FAIL' }
            $summary.EvidenceErrors = @($evidenceErrors.ToArray())
            if ($runPath) { Write-SandboxEvidence -Path (Join-Path $runPath 'result.json') -Value $summary -Json }
        } finally {
            try {
                if ($locked) { $mutex.ReleaseMutex() }
            } finally {
                $mutex.Dispose()
            }
        }
    }
    $evidenceDetail = if ($evidenceErrors.Count -gt 0) { ' Evidence write failures: ' + ($evidenceErrors -join '; ') } else { '' }
    if ($failure) { throw "Sandbox run failed: $($failure.Exception.Message) Evidence: $runPath. Cleanup: $($summary.Cleanup). $($summary.CleanupError)$evidenceDetail" }
    if ($cleanupFailure) { throw "Sandbox cleanup failed for owned ID $($commandState.OwnedId): $($cleanupFailure.Exception.Message) Evidence: $runPath.$evidenceDetail" }
    if ($evidenceErrors.Count -gt 0) { throw "Sandbox evidence could not be written. Evidence: $runPath. Cleanup: $($summary.Cleanup).$evidenceDetail" }
    [pscustomobject]@{ Status = 'PASS'; EvidenceDirectory = $runPath; SandboxId = $ownedId; Cleanup = $summary.Cleanup; GuestExitCode = $summary.GuestExitCode }
}
