[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageManifest,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [int]$FixturePort = 18453,
    [switch]$CleanupOnly,
    # 'all' (default) runs every scenario in order on this machine. The hosted CI
    # runs one scenario per runner: the scenarios share the machine-global
    # service, MSI product, certificate stores and fixture port, so they cannot
    # share a machine. -CleanupOnly is scoped to the same scenario.
    [ValidateSet('all','cross-sku','update','suite-update','update-interruption')][string]$Scenario = 'all'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath($EvidenceDirectory)
$packagePath = [IO.Path]::GetFullPath($PackageManifest)
if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { throw "Missing machine fixture manifest: $packagePath" }
$fixture = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
if ($fixture.schema -cne 'go-mapi-machine-test-packages-v1' -or
    $fixture.fixture.metadataOrigin -cne "https://localhost:$FixturePort" -or
    $fixture.fixture.artifactOrigin -cne "https://localhost:$FixturePort/releases/download/") {
    throw 'Machine fixture manifest and HTTPS port disagree'
}
if (-not $CleanupOnly) {
    foreach ($name in @('systemA','systemB','systemC','suiteA','suiteB','suiteC')) {
        $package = $fixture.packages.$name
        if (-not $package -or -not (Test-Path -LiteralPath $package.msi -PathType Leaf) -or
            (Get-FileHash -LiteralPath $package.msi -Algorithm SHA256).Hash.ToLowerInvariant() -cne $package.sha256) {
            throw "Missing or changed machine fixture package: $name"
        }
    }
}
$phaseScript = Join-Path $PSScriptRoot 'run-machine-update-integration.ps1'
$powerShell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$deferred = Join-Path $root 'update-interruption'
# Phase deadlines in minutes under the fixture's validation timers (production
# timers keep the long deadlines). Each automatic commit has its own per-wait
# limit in the phase script; these only bound the phase as a whole, so a
# regression to a multi-minute stall cannot hide inside a long deadline.
# update-interruption keeps its own literal: it waits for Windows Installer's
# idle shutdown (about 6 minutes), which no validation timer shortens.
function InScenario([string]$Name) { $Scenario -eq 'all' -or $Scenario -eq $Name }
$validationTimers = [bool]$fixture.fixture.PSObject.Properties['timers']
$validationDeadlines = @{ 'update' = 15; 'suite-update' = 20 }
function Invoke-Phase([string]$Name, [string]$SKU, [string]$Phase, [int]$Deadline = 35) {
    if ($validationTimers -and $Phase -ne 'Cleanup' -and $validationDeadlines.ContainsKey($Name)) { $Deadline = $validationDeadlines[$Name] }
    $path = Join-Path $root $Name
    $resultPath = Join-Path $path "machine-update-$($Phase.ToLowerInvariant()).json"
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    $phaseArgs = @('-NoProfile','-File',$phaseScript,'-PackageManifest',$packagePath,
        '-EvidenceDirectory',$path,'-SKU',$SKU,'-Phase',$Phase,
        '-FixturePort',[string]$FixturePort,'-DeadlineMinutes',[string]$Deadline)
    if ($Phase -eq 'Cleanup' -and $SKU -eq 'system') { $phaseArgs += @('-DeferredInterruptionEvidence',$deferred) }
    & $powerShell @phaseArgs
    if ($LASTEXITCODE -ne 0) { throw "$Name $Phase failed with exit code $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw "Missing phase result: $resultPath" }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if ($result.schema -cne 'go-mapi-machine-update-integration-v1' -or $result.phase -cne $Phase -or
        $result.passed -ne $true -or $result.cleanupError -or $result.packageManifest -ine $packagePath) {
        throw "Invalid or failed phase evidence: $resultPath"
    }
}
$primary = $null
$cleanupFailures = @()
try {
    if (-not $CleanupOnly) {
        if (InScenario 'cross-sku') {
            $cross = Join-Path $root 'cross-sku'
            Get-ChildItem -LiteralPath $cross -Filter '*.log' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force
            & $powerShell -NoProfile -File (Join-Path $PSScriptRoot '../src/installer/msi/tests/CrossSkuLifecycle.Tests.ps1') `
                -SystemMsi $fixture.packages.systemA.msi -SuiteMsi $fixture.packages.suiteA.msi `
                -NewerSuiteMsi $fixture.packages.suiteB.msi -NewerAppSuiteMsi $fixture.packages.suiteC.msi -LogDirectory $cross
            if ($LASTEXITCODE -ne 0) { throw "Cross-SKU lifecycle failed with exit code $LASTEXITCODE" }
            if (@(Get-ChildItem -LiteralPath $cross -Filter '*.log' -File -ErrorAction SilentlyContinue).Count -eq 0) {
                throw 'Cross-SKU lifecycle produced no MSI log evidence'
            }
        }
        if (InScenario 'update') { Invoke-Phase 'update' 'system' 'Hosted' }
        if (InScenario 'suite-update') {
            Invoke-Phase 'suite-update' 'suite' 'Hosted' 45
            Invoke-Phase 'suite-update' 'suite' 'Cleanup'
        }
        if (InScenario 'update-interruption') { Invoke-Phase 'update-interruption' 'system' 'InterruptSameBoot' 22 }
    }
} catch { $primary = $_.Exception.Message }
finally {
    $names = if (Test-Path -LiteralPath (Join-Path $deferred 'cleanup-deferred.json') -PathType Leaf) {
        Write-Warning "Machine cleanup is deferred to ephemeral runner disposal; evidence: $deferred"
        @('update','update-interruption')
    } else { @('suite-update','update','update-interruption') }
    foreach ($name in @($names | Where-Object { InScenario $_ })) {
        try { Invoke-Phase $name $(if ($name -eq 'suite-update') { 'suite' } else { 'system' }) 'Cleanup' }
        catch { $cleanupFailures += "$name`: $($_.Exception.Message)" }
    }
}
if ($primary -or $cleanupFailures.Count -gt 0) {
    throw ((@($primary) + $cleanupFailures | Where-Object { $_ }) -join '; ')
}
