[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$observer = Join-Path $PSScriptRoot 'process-observer.ps1'
$root = Join-Path $env:TEMP ('ticket569-process-observer-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null

try {
    $childCommand = 'Start-Sleep -Seconds 10; exit 7'
    $childEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
    $child = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $childEncoded) -PassThru
    $expectedCommand = $childEncoded
    & $observer -TargetProcessId $child.Id -ExpectedCommand $expectedCommand -ExpectedRunId $expectedCommand `
        -AttachedPath (Join-Path $root 'attached.json') -ExitPath (Join-Path $root 'exit.json') `
        -FailurePath (Join-Path $root 'failure.json') -TimeoutSeconds 10
    $exit = Get-Content -LiteralPath (Join-Path $root 'exit.json') -Raw | ConvertFrom-Json
    $attached = Get-Content -LiteralPath (Join-Path $root 'attached.json') -Raw | ConvertFrom-Json
    if ($exit.PID -ne $child.Id -or $exit.ExitCode -ne 7 -or !$exit.HandleRetained -or
        [Math]::Abs([double]$attached.CreationFileTimeUtc - [double]$attached.CimCreationFileTimeUtc) -gt 10000 -or
        $exit.CreationFileTimeUtc -ne $attached.CreationFileTimeUtc -or
        !$attached.CreationDateFromHandle) {
        throw 'Retained-handle observer did not report the real nonzero child exit'
    }

    $missingFailure = Join-Path $root 'missing-failure.json'
    & $observer -TargetProcessId 2147483647 -ExpectedCommand 'never-present-command' -ExpectedRunId 'never-present-run' `
        -AttachedPath (Join-Path $root 'missing-attached.json') -ExitPath (Join-Path $root 'missing-exit.json') `
        -FailurePath $missingFailure -TimeoutSeconds 2
    if (!(Test-Path -LiteralPath $missingFailure) -or (Test-Path -LiteralPath (Join-Path $root 'missing-exit.json'))) {
        throw 'Observer did not fail closed when it could not attach to the requested process'
    }

    $longCommand = 'Start-Sleep -Seconds 30; exit 0'
    $longEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($longCommand))
    $longChild = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $longEncoded) -PassThru
    try {
        & $observer -TargetProcessId $longChild.Id -ExpectedCommand $longEncoded -ExpectedRunId $longEncoded `
            -AttachedPath (Join-Path $root 'timeout-attached.json') -ExitPath (Join-Path $root 'timeout-exit.json') `
            -FailurePath (Join-Path $root 'timeout-failure.json') -TimeoutSeconds 1
        if (!(Test-Path -LiteralPath (Join-Path $root 'timeout-attached.json')) -or
            !(Test-Path -LiteralPath (Join-Path $root 'timeout-failure.json')) -or
            (Test-Path -LiteralPath (Join-Path $root 'timeout-exit.json'))) {
            throw 'Observer did not fail closed on a bounded wait timeout'
        }
    } finally {
        if (!$longChild.HasExited) { Stop-Process -Id $longChild.Id -Force }
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
