#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $MsiPath,
    [Parameter(Mandatory)][string] $ProofPath,
    [Parameter(Mandatory)][string] $EvidencePath
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'authenticode-diagnostic.psm1'
Import-Module -Name $modulePath -Force
$trustHelper = Join-Path $PSScriptRoot '..\..\scripts\azure-test-signing-trust.ps1'
$trustStatePath = Join-Path $env:RUNNER_TEMP 'ticket569-authenticode-test-root.json'
$observationTime = [DateTime]::UtcNow
function Get-BytesSha256([byte[]] $Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

try {
    $pins = Assert-Alpha9DiagnosticInputs -MsiPath $MsiPath -ProofPath $ProofPath
    $sourceSha = (& git -C $PSScriptRoot rev-parse HEAD).Trim().ToLowerInvariant()
    $sourceExit = $LASTEXITCODE
    $sourceStatus = (& git -C $PSScriptRoot status --porcelain --untracked-files=all | Out-String).Trim()
    if ($sourceExit -ne 0 -or $sourceSha -cne $env:GITHUB_SHA.ToLowerInvariant() -or $sourceStatus) {
        throw 'Diagnostic requires the exact clean workflow source SHA'
    }
} catch {
    $preflight = [ordered]@{
        schema = 'go-mapi-authenticode-diagnostic-v1'
        verdict = 'diagnostic-input-rejected'
        preflightException = [pscustomobject]@{ type = $_.Exception.GetType().FullName; message = $_.Exception.Message; hresult = ('0x{0:X8}' -f [int32]$_.Exception.HResult) }
        trustMutationAttempted = $false
        cleanup = 'not-needed-no-trust-mutation-attempted'
    }
    try { Write-AtomicJson -Path $EvidencePath -Value $preflight } catch { Write-Error "Could not write preflight evidence: $($_.Exception.Message)" }
    exit 1
}

if (Test-Path -LiteralPath $trustStatePath) {
    Write-AtomicJson -Path $EvidencePath -Value ([ordered]@{
        schema = 'go-mapi-authenticode-diagnostic-v1'
        verdict = 'diagnostic-aborted-state-path-not-vacant'
        inputs = $pins
        trustMutationAttempted = $false
        cleanup = 'not-needed-no-trust-mutation-attempted'
    })
    exit 1
}

try { Initialize-WinVerifyTrustType }
catch {
    Write-AtomicJson -Path $EvidencePath -Value ([ordered]@{
        schema = 'go-mapi-authenticode-diagnostic-v1'
        verdict = 'diagnostic-prerequisite-failed'
        inputs = $pins
        preparationException = [pscustomobject]@{ type = $_.Exception.GetType().FullName; message = $_.Exception.Message; hresult = ('0x{0:X8}' -f [int32]$_.Exception.HResult) }
        trustMutationAttempted = $false
        cleanup = 'not-needed-no-trust-mutation-attempted'
    })
    exit 1
}
$lifecycle = Invoke-OwnedTrustDiagnosticLifecycle `
    -Prepare {
        & $trustHelper -Mode Prepare -StatePath $trustStatePath -SignedFiles @($MsiPath)
    } `
    -ReadOwnedState {
        if (-not (Test-Path -LiteralPath $trustStatePath -PathType Leaf)) { return $null }
        $state = Get-Content -LiteralPath $trustStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($state.schema -cne 'go-mapi-azure-test-root-fixture-v1' -or
            $state.certificateSha256 -cne $pins.pinnedTestRootSha256 -or
            $state.thumbprint -cne $pins.pinnedTestRootThumbprint -or
            $state.store -cne 'LocalMachine/Root' -or
            $null -eq $state.preexisting -or $null -eq $state.importAttempted -or $null -eq $state.imported) {
            throw 'Owned trust state does not match the pinned TEST ONLY root contract'
        }
        if ($state.preexisting -and ($state.importAttempted -or $state.imported)) { throw 'Trust helper claimed ownership of a preexisting root' }
        if ($state.imported -and -not $state.importAttempted) { throw 'Trust state reports an unowned root import' }
        return $state
    } `
    -Observe {
        param($state)
        $storePath = "Cert:\LocalMachine\Root\$($pins.pinnedTestRootThumbprint)"
        $rootPresent = $false
        $rootMatches = $false
        $rootInventoryException = $null
        try {
            $rootPresent = Test-Path -LiteralPath $storePath
            if ($rootPresent) {
                $certificate = Get-Item -LiteralPath $storePath -ErrorAction Stop
                $rawHash = Get-BytesSha256 $certificate.RawData
                $rootMatches = $rawHash -ceq $pins.pinnedTestRootSha256
            }
        } catch { $rootInventoryException = [pscustomobject]@{ type = $_.Exception.GetType().FullName; message = $_.Exception.Message; hresult = ('0x{0:X8}' -f [int32]$_.Exception.HResult) } }
        $diagnostic = Get-AuthenticodeDiagnostic -MsiPath $MsiPath -ObservationTimeUtc $observationTime
        $observationComplete = Test-RequiredTrustObservationComplete -Diagnostic $diagnostic -RootInventoryException $rootInventoryException
        return [pscustomobject]@{
            inputs = $pins
            trust = [pscustomobject]@{
                preexisting = [bool]$state.preexisting
                importAttempted = [bool]$state.importAttempted
                imported = [bool]$state.imported
                rootPresentBeforeObservation = $rootPresent
                rootBytesMatchPinnedSha256 = $rootMatches
                inventoryException = $rootInventoryException
                rootThumbprint = $pins.pinnedTestRootThumbprint
                store = 'LocalMachine/Root'
            }
            authenticode = $diagnostic
            collectionComplete = $observationComplete
        }
    } `
    -Cleanup {
        param($state)
        & $trustHelper -Mode Cleanup -StatePath $trustStatePath
        $storePath = "Cert:\LocalMachine\Root\$($pins.pinnedTestRootThumbprint)"
        $present = Test-Path -LiteralPath $storePath
        $expectedPresent = [bool]$state.preexisting
        if ($present -ne $expectedPresent) {
            throw "Pinned TEST root cleanup mismatch: expected present=$expectedPresent, observed present=$present"
        }
        if ($present) {
            $certificate = Get-Item -LiteralPath $storePath -ErrorAction Stop
            $rawHash = Get-BytesSha256 $certificate.RawData
            if ($rawHash -cne $pins.pinnedTestRootSha256) { throw 'Preserved preexisting TEST root bytes changed during cleanup' }
        }
        return [pscustomobject]@{ rootPresentAfterCleanup = $present; preexistingRootPreserved = ($present -and $expectedPresent); ownedRootRemoved = (-not $present -and -not $expectedPresent); errors = @() }
    } `
    -WriteEvidence {
        param($record)
        $runner = $null
        $runnerException = $null
        try {
            $runner = [ordered]@{
                name = $env:RUNNER_NAME
                label = 'windows-2025'
                imageOS = $env:ImageOS
                imageVersion = $env:ImageVersion
                computerName = $env:COMPUTERNAME
                os = (Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption)
            }
        } catch { $runnerException = [pscustomobject]@{ type = $_.Exception.GetType().FullName; message = $_.Exception.Message; hresult = ('0x{0:X8}' -f [int32]$_.Exception.HResult) } }
        $document = [ordered]@{
            schema = $record.schema
            verdict = $record.verdict
        sourceSHA = $env:GITHUB_SHA
        checkedOutSourceSHA = $sourceSha
            runner = $runner
            runnerException = $runnerException
            inputs = $pins
            observationTimeUtc = $observationTime.ToString('o')
            preparationException = $record.preparationException
            preparationComplete = $record.preparationComplete
            ownedTrustState = $record.ownedTrustState
            observation = $record.observation
            observationException = $record.observationException
            cleanup = $record.cleanup
            cleanupException = $record.cleanupException
            collectionComplete = $record.collectionComplete
            interpretation = 'This job observes signature behavior only. It does not install the MSI, create a user, inspect or mutate a user profile, or conclude hosted capability.'
        }
        Write-AtomicJson -Path $EvidencePath -Value $document
    }

if (-not $lifecycle.collectionComplete) { exit 1 }
exit 0
