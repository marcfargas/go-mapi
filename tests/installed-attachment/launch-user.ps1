[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RunRoot,
    [Parameter(Mandatory)] [string] $ExpectedJson,
    [Parameter(Mandatory)] [string] $AppPath,
    [Parameter(Mandatory)] [string] $X64DllPath,
    [Parameter(Mandatory)] [string] $FakeBinary,
    [ValidateSet('normal', 'mount-point')] [string] $ProfileKind,
    [string] $ExpectedProfilePath = $env:USERPROFILE,
    [string] $ExpectedVhdPath
)

$ErrorActionPreference = 'Stop'
$runScript = Join-Path $PSScriptRoot 'run-user.ps1'
$quote = { param([string] $Value) "'" + $Value.Replace("'", "''") + "'" }
$command = '& ' + (& $quote $runScript) +
    ' -RunRoot ' + (& $quote $RunRoot) +
    ' -ExpectedJson ' + (& $quote $ExpectedJson) +
    ' -AppPath ' + (& $quote $AppPath) +
    ' -X64DllPath ' + (& $quote $X64DllPath) +
    ' -FakeBinary ' + (& $quote $FakeBinary) +
    ' -ProfileKind ' + (& $quote $ProfileKind) +
    ' -ExpectedProfilePath ' + (& $quote $ExpectedProfilePath) +
    $(if ($ExpectedVhdPath) { ' -ExpectedVhdPath ' + (& $quote $ExpectedVhdPath) } else { '' }) + '; exit $LASTEXITCODE'
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$runParent = Split-Path -Parent $RunRoot
$runName = Split-Path -Leaf $RunRoot
$launcherLogs = Join-Path $runParent ('.' + $runName + '.launcher-' + $PID)
if (Test-Path -LiteralPath $launcherLogs) { throw 'Unique launcher log directory already exists' }
New-Item -ItemType Directory -Path $launcherLogs | Out-Null
$stdout = Join-Path $launcherLogs 'transaction.stdout.txt'
$stderr = Join-Path $launcherLogs 'transaction.stderr.txt'
$started = [DateTime]::UtcNow
$child = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -PassThru -Wait -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$child.Refresh()
$actualExit = [int]$child.ExitCode
Move-Item -LiteralPath $stdout -Destination (Join-Path $RunRoot 'transaction.stdout.txt') -Force
Move-Item -LiteralPath $stderr -Destination (Join-Path $RunRoot 'transaction.stderr.txt') -Force
Remove-Item -LiteralPath $launcherLogs -Force
$record = @{ SchemaVersion = 1; RunId = [IO.Path]::GetFileName($RunRoot); ChildPID = $child.Id; ChildExitCode = $actualExit; LauncherPID = $PID; LauncherSession = (Get-Process -Id $PID).SessionId; StartedAt = $started.ToString('o'); FinishedAt = [DateTime]::UtcNow.ToString('o') }
$temp = Join-Path $RunRoot 'launcher-result.tmp'
[IO.File]::WriteAllText($temp, (ConvertTo-Json $record -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temp -Destination (Join-Path $RunRoot 'launcher-result.json') -Force
exit $actualExit
