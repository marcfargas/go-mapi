[CmdletBinding()]
param()

# Debug 776 behavior checks for Invoke-Ticket569AppFixturePreparation with injected process providers.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'owned-app-fixture.psm1') -Force

$app = 'C:\Program Files\go-mapi\user\go-mapi.exe'
$sid = 'S-1-5-21-1-2-3-1001'
$failures = [Collections.Generic.List[string]]::new()

function New-Case {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ticket569-fixture-' + [guid]::NewGuid().ToString('N'))
    $runRoot = Join-Path $root 'run'
    $appData = Join-Path $root 'appdata\go-mapi'
    New-Item -ItemType Directory -Path $runRoot, $appData | Out-Null
    [pscustomobject]@{ Root = $root; RunRoot = $runRoot; Log = (Join-Path $appData 'app.log') }
}

function Assert-Throws([string] $Name, [string] $Pattern, [scriptblock] $Body) {
    try { & $Body; $failures.Add("$Name did not throw") }
    catch { if ($_.ToString() -notmatch $Pattern) { $failures.Add("$Name threw unexpected: $_") } }
}

$owned = [pscustomobject]@{ Id = 4100; Name = 'go-mapi.exe'; ExecutablePath = $app; SessionId = 3; OwnerSid = $sid; CreationDate = '2026-10-11T17:34:00Z' }

# Owned fixture: stops only the exact owned app, preserves the prior log separately, leaves no current-case log.
$case = New-Case
try {
    Set-Content -LiteralPath $case.Log -Value 'prior run line' -NoNewline
    $priorHash = (Get-FileHash -LiteralPath $case.Log -Algorithm SHA256).Hash.ToLowerInvariant()
    $stopped = [Collections.Generic.List[int]]::new()
    $receipt = Invoke-Ticket569AppFixturePreparation -AppLogPath $case.Log -AppPath $app -RunRoot $case.RunRoot -Sid $sid -SessionId 3 -OwnedFixture `
        -GetProcesses { @($owned) } -StopProcess { param([int] $ProcessId) $stopped.Add($ProcessId); [ordered]@{ HasExited = $true; ExitCode = 1; ExitedUtc = '2026-10-11T18:00:00.0000000Z' } }
    if (($stopped -join ',') -ne '4100') { $failures.Add("owned app not stopped exactly once: $($stopped -join ',')") }
    if (Test-Path -LiteralPath $case.Log) { $failures.Add('prior app.log still present where the current case log is written') }
    $preserved = Join-Path $case.RunRoot 'preexisting-app.log'
    if (!(Test-Path -LiteralPath $preserved) -or (Get-FileHash -LiteralPath $preserved -Algorithm SHA256).Hash.ToLowerInvariant() -ne $priorHash) { $failures.Add('prior log not preserved byte-exactly') }
    if (Test-Path -LiteralPath (Join-Path $case.RunRoot 'app.log')) { $failures.Add('prior log was presented as the current-case app.log') }
    $json = Get-Content -LiteralPath (Join-Path $case.RunRoot 'preexisting-app-fixture.json') -Raw | ConvertFrom-Json
    if ($json.PreexistingAppLog.SHA256 -ne $priorHash -or $json.StoppedOwnedApps[0].PID -ne 4100 -or $receipt.Sid -ne $sid) { $failures.Add('fixture receipt incomplete') }
    if ($json.StoppedOwnedApps[0].HasExited -ne $true -or $json.StoppedOwnedApps[0].ExitCode -ne 1 -or (Get-Content -LiteralPath (Join-Path $case.RunRoot 'preexisting-app-fixture.json') -Raw) -notmatch '"ExitedUtc":\s*"2026-10-11T18:00:00\.0000000Z"') { $failures.Add('receipt lacks terminal exit fields') }
} finally { Remove-Item -LiteralPath $case.Root -Recurse -Force -ErrorAction SilentlyContinue }

# Owned fixture refuses an app in another session, another owner, or another image; nothing is stopped or moved.
foreach ($variant in @(
    @{ Name = 'other-session'; Process = ($owned | Select-Object *); Field = 'SessionId'; Value = 4 },
    @{ Name = 'other-owner'; Process = ($owned | Select-Object *); Field = 'OwnerSid'; Value = 'S-1-5-21-9-9-9-1001' },
    @{ Name = 'other-image'; Process = ($owned | Select-Object *); Field = 'ExecutablePath'; Value = 'C:\Temp\go-mapi.exe' },
    @{ Name = 'unknown-path'; Process = ($owned | Select-Object *); Field = 'ExecutablePath'; Value = $null })) {
    $case = New-Case
    try {
        Set-Content -LiteralPath $case.Log -Value 'prior'
        $process = $variant.Process; $process.($variant.Field) = $variant.Value
        $stopped = [Collections.Generic.List[int]]::new()
        Assert-Throws $variant.Name 'Unrecognized go-mapi process' {
            Invoke-Ticket569AppFixturePreparation -AppLogPath $case.Log -AppPath $app -RunRoot $case.RunRoot -Sid $sid -SessionId 3 -OwnedFixture `
                -GetProcesses { @($process) } -StopProcess { param([int] $ProcessId) $stopped.Add($ProcessId) }
        }
        if ($stopped.Count -or !(Test-Path -LiteralPath $case.Log) -or (Test-Path -LiteralPath (Join-Path $case.RunRoot 'preexisting-app.log'))) { $failures.Add("$($variant.Name) mutated state") }
    } finally { Remove-Item -LiteralPath $case.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

# A stopper without positive exit proof fails closed before the prior log is moved.
$case = New-Case
try {
    Set-Content -LiteralPath $case.Log -Value 'prior'
    Assert-Throws 'no-exit-proof' 'no positive exit proof' {
        Invoke-Ticket569AppFixturePreparation -AppLogPath $case.Log -AppPath $app -RunRoot $case.RunRoot -Sid $sid -SessionId 3 -OwnedFixture `
            -GetProcesses { @($owned) } -StopProcess { param([int] $ProcessId) [ordered]@{ HasExited = $false } }
    }
    if (!(Test-Path -LiteralPath $case.Log) -or (Test-Path -LiteralPath (Join-Path $case.RunRoot 'preexisting-app.log'))) { $failures.Add('no-exit-proof moved the prior log') }
} finally { Remove-Item -LiteralPath $case.Root -Recurse -Force -ErrorAction SilentlyContinue }

# Stop-Ticket569OwnedApp with handle stubs: exited handle passes with terminal fields; non-exit times out.
function New-Handle([bool] $Exits) {
    $h = [pscustomobject]@{ Exits = $Exits; Killed = $false; HasExited = $false; ExitCode = 137; ExitTime = [DateTime]::new(2026, 10, 11, 18, 1, 2, [DateTimeKind]::Utc) }
    $h | Add-Member ScriptMethod Kill { $this.Killed = $true }
    $h | Add-Member ScriptMethod WaitForExit { param($ms) if ($this.Exits) { $this.HasExited = $true }; return [bool]$this.Exits }
    $h | Add-Member ScriptMethod Refresh { }
    $h
}
$exiting = New-Handle $true
$result = Stop-Ticket569OwnedApp -ProcessId 4100 -GetHandle { param($Id) $exiting }
if (!$exiting.Killed -or $result.HasExited -ne $true -or $result.ExitCode -ne 137 -or $result.ExitedUtc -notmatch '^2026-10-11T18:01:02') { $failures.Add('exited handle did not produce terminal proof') }
$stuck = New-Handle $false
Assert-Throws 'handle-timeout' 'did not exit within 5 ms' { Stop-Ticket569OwnedApp -ProcessId 4100 -TimeoutMilliseconds 5 -GetHandle { param($Id) $stuck } }

# Real child process through the default Stop-Ticket569OwnedApp path (native Kill/WaitForExit/ExitCode).
$child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120') -PassThru
try {
    $real = Stop-Ticket569OwnedApp -ProcessId $child.Id
    if ($real.HasExited -ne $true -or !$real.ObservedExitedUtc) { $failures.Add('real child stop lacked terminal proof') }
    if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6) { if ($null -eq $real.ExitCode -or !$real.ExitedUtc) { $failures.Add('Windows real child stop lacked ExitCode/ExitTime') } }
    $child.Refresh()
    if (!$child.HasExited) { $failures.Add('real child still running after stop') }
} finally { if (!$child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } }

# Default (no -OwnedFixture) stays non-destructive and fails closed for a prior log or a resident app.
$case = New-Case
try {
    Set-Content -LiteralPath $case.Log -Value 'prior'
    Assert-Throws 'default-log' 'already has an app log' {
        Invoke-Ticket569AppFixturePreparation -AppLogPath $case.Log -AppPath $app -RunRoot $case.RunRoot -Sid $sid -SessionId 3 -GetProcesses { @() } -StopProcess { throw 'must not stop' }
    }
    Remove-Item -LiteralPath $case.Log
    Assert-Throws 'default-app' 'already running' {
        Invoke-Ticket569AppFixturePreparation -AppLogPath $case.Log -AppPath $app -RunRoot $case.RunRoot -Sid $sid -SessionId 3 -GetProcesses { @($owned) } -StopProcess { throw 'must not stop' }
    }
    $clean = Invoke-Ticket569AppFixturePreparation -AppLogPath $case.Log -AppPath $app -RunRoot $case.RunRoot -Sid $sid -SessionId 3 -GetProcesses { @() } -StopProcess { throw 'must not stop' }
    if ($null -ne $clean -or (Get-ChildItem -LiteralPath $case.RunRoot -Force).Count) { $failures.Add('clean default case wrote fixture state') }
} finally { Remove-Item -LiteralPath $case.Root -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures.Count) { $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }; exit 1 }
Write-Output 'OWNED_APP_FIXTURE_TESTS_PASSED'
exit 0
