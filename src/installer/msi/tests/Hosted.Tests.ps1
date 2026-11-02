$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch { Assert ($_.Exception.Message -match $Pattern) "Unexpected failure: $_"; return }
    throw "Expected failure: $Pattern"
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('go-mapi-hosted-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory $temp | Out-Null
    $runner = Join-Path $temp 'hosted.ps1'
    Copy-Item (Join-Path $PSScriptRoot 'hosted.ps1') $runner
    @'
param($SystemMsi,$SuiteMsi,$NewerSuiteMsi,$NewerAppSuiteMsi,$LogDirectory)
if ($env:FAKE_CROSS_MODE -eq 'exit') { exit 23 }
if ($env:FAKE_CROSS_MODE -ne 'missing') {
    New-Item -ItemType Directory -Force $LogDirectory | Out-Null
    Set-Content (Join-Path $LogDirectory 'lifecycle.log') 'ok'
}
exit 0
'@ | Set-Content (Join-Path $temp 'CrossSkuLifecycle.Tests.ps1')
    @'
param($PackageManifest,$EvidenceDirectory,$SKU,$Phase,$FixturePort,$DeadlineMinutes,$DeferredInterruptionEvidence)
$name = Split-Path $EvidenceDirectory -Leaf
Add-Content $env:FAKE_PHASE_LOG "$name/$Phase/$SKU=$DeadlineMinutes"
if ($Phase -eq 'Cleanup' -and $DeferredInterruptionEvidence -ne $EvidenceDirectory) { throw 'Wrong deferred observation path' }
$result = @{ schema='go-mapi-machine-update-integration-v1'; phase=$Phase; passed=$true; cleanupError=$null; packageManifest=[IO.Path]::GetFullPath($PackageManifest) }
$mode = if ($env:FAKE_PHASE_TARGET -eq "$name/$Phase") { $env:FAKE_PHASE_MODE } else { '' }
switch ($mode) {
    'exit' { exit 23 }
    'missing' { exit 0 }
    'schema' { $result.schema='wrong' }
    'phase' { $result.phase='wrong' }
    'manifest' { $result.packageManifest='wrong' }
    'failed' { $result.passed=$false }
    'cleanup' { $result.cleanupError='cleanup failed' }
}
New-Item -ItemType Directory -Force $EvidenceDirectory | Out-Null
$path = Join-Path $EvidenceDirectory "machine-update-$($Phase.ToLowerInvariant()).json"
if ($mode -eq 'truncated') { Set-Content $path '{' } else { $result | ConvertTo-Json | Set-Content $path }
exit 0
'@ | Set-Content (Join-Path $temp 'update.ps1')
    $packages = @{}
    foreach ($name in @('systemA','systemB','systemC','suiteA','suiteB','suiteC')) {
        $path = Join-Path $temp "$name.msi"; Set-Content $path $name
        $packages[$name] = @{ msi=$path; sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $fixture = @{ schema='go-mapi-machine-test-packages-v1'; fixture=@{ metadataOrigin='https://localhost:18453'; artifactOrigin='https://localhost:18453/releases/download/' }; packages=$packages }
    $fixturePath = Join-Path $temp 'fixture.json'
    $evidence = Join-Path $temp 'evidence'
    $env:FAKE_PHASE_LOG = Join-Path $temp 'phases.log'
    function RunScenario([string]$Name) {
        [IO.File]::WriteAllText($env:FAKE_PHASE_LOG,'')
        & $runner -PackageManifest $fixturePath -EvidenceDirectory $evidence -Scenario $Name
    }
    $cases = @(
        @{ name='cross-sku'; phases=@(); production=@(); validation=@() },
        @{ name='update'; phases=@('update/Hosted/system'); production=@(35); validation=@(15) },
        @{ name='suite-update'; phases=@('suite-update/Hosted/suite'); production=@(45); validation=@(20) },
        @{ name='readiness-recovery'; phases=@('readiness-recovery/ReadinessRecovery/system'); production=@(35); validation=@(20) },
        @{ name='suite-readiness-recovery'; phases=@('suite-readiness-recovery/ReadinessRecovery/suite'); production=@(35); validation=@(25) },
        @{ name='update-interruption'; phases=@('update-interruption/InterruptSameBoot/system','update-interruption/Cleanup/system'); production=@(22,35); validation=@(22,35) }
    )
    foreach ($timers in @('production','validation')) {
        if ($timers -eq 'validation') { $fixture.fixture.timers=@{startupDelaySeconds=5} }
        $fixture | ConvertTo-Json -Depth 5 | Set-Content $fixturePath
        foreach ($case in $cases) {
            RunScenario $case.name
            $expected = @(for ($i=0; $i -lt $case.phases.Count; $i++) { "$($case.phases[$i])=$($case[$timers][$i])" })
            Assert ((@(Get-Content $env:FAKE_PHASE_LOG) -join ',') -ceq ($expected -join ',')) "$($case.name) $timers routing/deadline changed"
        }
        Assert (Test-Path (Join-Path $evidence 'cross-sku/lifecycle.log')) 'Cross-SKU MSI evidence missing'
    }
    foreach ($mode in @('exit','missing')) {
        $env:FAKE_CROSS_MODE=$mode
        Reject { RunScenario 'cross-sku' } $(if ($mode -eq 'exit') { 'Cross-SKU lifecycle failed with exit code 23' } else { 'no MSI log evidence' })
        Assert (-not (Test-Path (Join-Path $evidence 'cross-sku/lifecycle.log'))) 'Stale cross-SKU log survived'
    }
    $env:FAKE_CROSS_MODE=''
    $env:FAKE_PHASE_TARGET='update-interruption/InterruptSameBoot'
    foreach ($mode in @('exit','missing','schema','phase','manifest','failed','cleanup','truncated')) {
        # A prior successful receipt must never rescue a missing fresh result.
        $env:FAKE_PHASE_MODE=''; RunScenario 'update-interruption'
        $env:FAKE_PHASE_MODE=$mode
        $pattern = switch ($mode) { 'exit' {'failed with exit code 23'} 'missing' {'Missing phase result'} 'truncated' {'JSON|Invalid object'} default {'Invalid or failed phase evidence'} }
        Reject { RunScenario 'update-interruption' } $pattern
        Assert ((@(Get-Content $env:FAKE_PHASE_LOG) -join ',') -ceq 'update-interruption/InterruptSameBoot/system=22') 'A failed phase ran the second observation'
    }
    $env:FAKE_PHASE_TARGET='update-interruption/Cleanup'; $env:FAKE_PHASE_MODE='cleanup'
    Reject { RunScenario 'update-interruption' } 'Invalid or failed phase evidence'
    $env:FAKE_PHASE_MODE=''
    foreach ($name in @('all','unknown')) { Reject { RunScenario $name } 'ValidateSet|does not belong|not match' }
    Reject { & $runner -PackageManifest $fixturePath -EvidenceDirectory $evidence -Scenario 'update' -CleanupOnly } 'CleanupOnly'
    Set-Content $packages.systemA.msi 'changed'
    Reject { RunScenario 'update' } 'Missing or changed machine fixture package: systemA'
    Assert (@(Get-Content $env:FAKE_PHASE_LOG).Count -eq 0) 'Changed MSI reached a phase'
    Write-Host 'Hosted scenario and phase evidence contracts passed'
} finally {
    foreach ($name in @('FAKE_PHASE_LOG','FAKE_PHASE_TARGET','FAKE_PHASE_MODE','FAKE_CROSS_MODE')) { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
    if ([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
