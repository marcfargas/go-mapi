[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$observer = Join-Path $PSScriptRoot 'process-observer.ps1'
$root = Join-Path $env:TEMP ('ticket569-process-observer-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null

$child = $null
try {
    # Attach before allowing the child to exit; observer startup is outside its retained-handle wait.
    $attachedPath = Join-Path $root 'attached.json'
    $escapedAttachedPath = $attachedPath.Replace("'", "''")
    $childCommand = "`$deadline = [DateTime]::UtcNow.AddSeconds(30); while (!(Test-Path -LiteralPath '$escapedAttachedPath')) { if ([DateTime]::UtcNow -ge `$deadline) { exit 91 }; Start-Sleep -Milliseconds 100 }; exit 7"

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
    $missingRecord = Get-Content -LiteralPath $missingFailure -Raw | ConvertFrom-Json
    if ($missingRecord.Error -notmatch 'did not identify the expected live command' -or $missingRecord.Diagnostic.Reason -ne 'absent' -or
        $missingRecord.Diagnostic.ExpectedCommand -ne 'never-present-command' -or $missingRecord.Diagnostic.ExpectedRunId -ne 'never-present-run' -or
        $null -ne $missingRecord.Diagnostic.CommandLine) {
        throw 'Observer failure did not record the absent-process diagnostic'
    }

    $longCommand = 'Start-Sleep -Seconds 30; exit 0'
    $longEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($longCommand))
    $longChild = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $longEncoded) -PassThru
    try {
        foreach ($mismatch in @(
            @{ Name = 'command'; Command = 'never-present-command'; RunId = $longEncoded; Reason = 'command-mismatch' },
            @{ Name = 'runid'; Command = $longEncoded; RunId = 'never-present-run'; Reason = 'runid-mismatch' })) {
            $mismatchFailure = Join-Path $root ($mismatch.Name + '-mismatch-failure.json')
            & $observer -TargetProcessId $longChild.Id -ExpectedCommand $mismatch.Command -ExpectedRunId $mismatch.RunId `
                -AttachedPath (Join-Path $root ($mismatch.Name + '-mismatch-attached.json')) -ExitPath (Join-Path $root ($mismatch.Name + '-mismatch-exit.json')) `
                -FailurePath $mismatchFailure -TimeoutSeconds 2
            $record = Get-Content -LiteralPath $mismatchFailure -Raw | ConvertFrom-Json
            if ((Test-Path -LiteralPath (Join-Path $root ($mismatch.Name + '-mismatch-attached.json'))) -or
                $record.Error -notmatch 'did not identify the expected live command' -or $record.Diagnostic.Reason -ne $mismatch.Reason -or
                $record.Diagnostic.ProcessName -ne 'powershell.exe' -or $record.Diagnostic.CommandLine -notmatch [regex]::Escape($longEncoded) -or
                !$record.Diagnostic.CreationDate) {
                throw "Observer did not fail closed with the $($mismatch.Reason) diagnostic"
            }
        }
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
} catch {
    # Preserve the observer's reason in the CI log before removing the owned scratch directory.
    foreach ($receipt in Get-ChildItem -LiteralPath $root -Filter '*.json' -File) {
        Write-Output ("Observer fixture receipt {0}: {1}" -f $receipt.Name, (Get-Content -LiteralPath $receipt.FullName -Raw))
    }
    throw
} finally {
    if ($child -and !$child.HasExited) { $child.Kill(); [void]$child.WaitForExit(5000) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
