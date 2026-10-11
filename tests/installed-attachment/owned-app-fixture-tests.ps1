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
        -GetProcesses { @($owned) } -StopProcess { param([int] $ProcessId) $stopped.Add($ProcessId) }
    if (($stopped -join ',') -ne '4100') { $failures.Add("owned app not stopped exactly once: $($stopped -join ',')") }
    if (Test-Path -LiteralPath $case.Log) { $failures.Add('prior app.log still present where the current case log is written') }
    $preserved = Join-Path $case.RunRoot 'preexisting-app.log'
    if (!(Test-Path -LiteralPath $preserved) -or (Get-FileHash -LiteralPath $preserved -Algorithm SHA256).Hash.ToLowerInvariant() -ne $priorHash) { $failures.Add('prior log not preserved byte-exactly') }
    if (Test-Path -LiteralPath (Join-Path $case.RunRoot 'app.log')) { $failures.Add('prior log was presented as the current-case app.log') }
    $json = Get-Content -LiteralPath (Join-Path $case.RunRoot 'preexisting-app-fixture.json') -Raw | ConvertFrom-Json
    if ($json.PreexistingAppLog.SHA256 -ne $priorHash -or $json.StoppedOwnedApps[0].PID -ne 4100 -or $receipt.Sid -ne $sid) { $failures.Add('fixture receipt incomplete') }
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
