$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-verdict.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-root-import-policy.psm1') -Force
$normal = @{ status='feasible-observed' }
$vhd = @{ status='feasible-observed' }
$prompt = @{ status='observed-and-answered' }

function Assert-Verdict([string] $Expected, [object[]] $Conditions = @(), [string[]] $Cleanup = @(), [string] $Profile = 'normal', [bool] $UserCreated = $false, [object] $Normal = $normal, [object] $Vhd = $vhd) {
    $actual = Resolve-HostedCapabilityVerdict -Conditions $Conditions -Normal $Normal -Vhd $Vhd -RootPrompt $prompt `
        -PositiveRoute $true -CleanupErrors $Cleanup -ProfileState $Profile -UserCreated $UserCreated
    if ($actual -cne $Expected) { throw "Expected hosted verdict $Expected, observed $actual" }
}

Assert-Verdict 'feasible-observed'
Assert-Verdict 'harness-defect' @(@{ class='harness-defect'; evidence=@{ message='fixture' } })
Assert-Verdict 'transient-setup' @(@{ class='transient-setup'; evidence=@{ message='network' } })
Assert-Verdict 'unknown' @(@{ class='unavailable-supported-capability'; evidence=@{ actualError='unsupported' } })
Assert-Verdict 'unknown' @(@{ class='unavailable-supported-capability'; evidence=@{ documentedSupportedLimitation=$true; actualError='unsupported'; positiveControlObserved=$true } })
Assert-Verdict 'unavailable-supported-capability' @(@{ class='unavailable-supported-capability'; evidence=@{ route='vhd'; documentedSupportedLimitation=$true; actualError='unsupported'; positiveControlObserved=$true } }) `
    -Normal @{ status='feasible-observed' } -Vhd @{ status='unavailable-supported-capability' }
Assert-Verdict 'cleanup-failed' @(@{ class='harness-defect'; evidence=@{} }) @('profile restoration failed')
Assert-Verdict 'cleanup-failed' @() @() 'mounted' $true

$exhaustedBudget = Test-HostedPhaseBudget -NowUtc ([DateTime]::Parse('2026-10-09T10:00:00Z')) `
    -WorkDeadlineUtc ([DateTime]::Parse('2026-10-09T10:00:30Z')) -RequiredSeconds 125
if ($exhaustedBudget.allowed -or $exhaustedBudget.remainingSeconds -ne 30 -or $exhaustedBudget.requiredSeconds -ne 125) {
    throw 'An exhausted hosted phase budget was allowed to start instead of preserving time for cleanup/evidence'
}

$finalization = Invoke-HostedCapabilityFinalization -Final @{ verdict='feasible-observed' } -WriteEvidence { throw 'injected snapshot disk failure' }
if (!$finalization.writeFailed -or $finalization.verdict -cne 'harness-defect' -or $finalization.failureClass -cne 'harness-defect') {
    throw 'Final evidence write failure was not classified as a harness defect'
}
$combinedFailure = Invoke-HostedCapabilityFinalization -Final @{ verdict='cleanup-failed' } -WriteEvidence { throw 'injected snapshot disk failure after cleanup failure' }
if (!$combinedFailure.writeFailed -or $combinedFailure.verdict -cne 'cleanup-failed' -or $combinedFailure.failureClass -cne 'harness-defect') {
    throw 'Final evidence write failure overrode cleanup-failed verdict precedence'
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    $secret = 'Ticket569-test-canary-9aA!'
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $canaryHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($secret)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    [IO.File]::WriteAllText((Join-Path $temporary 'injected.json'), "{`"value`":`"$secret`"}")
    $detected = Test-HostedSecretCanary -Directory $temporary -Sha256 $canaryHash -Length $secret.Length
    if (!$detected.leaked -or $detected.file -cne 'injected.json') { throw 'Secret canary failed to detect the injected secret' }
    [IO.File]::WriteAllText((Join-Path $temporary 'injected.json'), '{"value":"clean"}')
    if ((Test-HostedSecretCanary -Directory $temporary -Sha256 $canaryHash -Length $secret.Length).leaked) { throw 'Secret canary reported a leak in clean evidence' }
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }

$generated = [Security.SecureString]::new()
foreach ($character in Get-HostedPasswordRequiredCharacters) { $generated.AppendChar($character) }
if ($generated.Length -ne 4) { throw 'Required password characters were not appended as individual chars' }
$generated.Dispose()

$workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../.github/workflows/hosted-capability.yml') -Raw
$probeSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-capability.ps1') -Raw
if ($workflow -notmatch '(?m)^\s+timeout-minutes:\s*30\s*$' -or
    $workflow -notmatch '-JobStartedAtUtc \$env:HOSTED_CAPABILITY_JOB_STARTED_AT_UTC' -or
    $workflow -notmatch 'Start job-wide probe deadline before source preparation' -or
    $probeSource -notmatch '\$deadline = \$jobStartedAt\.AddMinutes\(\$DeadlineMinutes\)' -or
    $probeSource -notmatch '\$workDeadline = \$deadline\.AddMinutes\(-\$cleanupReserveMinutes\)' -or
    $probeSource -notmatch 'Job-wide preflight work deadline elapsed during source preparation') {
    throw 'Hosted preflight deadline is not bounded by the full workflow job clock with reserved cleanup time'
}

$cleanupCases = @(
    @{ preexisting=$true; attempted=$true; count=1; subject=$true; expected='preserve' },
    @{ preexisting=$false; attempted=$false; count=1; subject=$true; expected='preserve' },
    @{ preexisting=$false; attempted=$true; count=1; subject=$true; expected='remove-owned' },
    @{ preexisting=$false; attempted=$true; count=0; subject=$false; expected='already-absent' },
    @{ preexisting=$false; attempted=$true; count=2; subject=$true; expected='refuse-ambiguous' },
    @{ preexisting=$false; attempted=$true; count=1; subject=$false; expected='refuse-mismatch' }
)
foreach ($case in $cleanupCases) {
    $actual = Get-HostedRootImportCleanupDecision -Preexisting $case.preexisting -ImportAttempted $case.attempted `
        -MatchCount $case.count -SubjectMatches $case.subject
    if ($actual -cne $case.expected) { throw "Expected root cleanup policy $($case.expected), observed $actual" }
}

Write-Output 'HOSTED_CAPABILITY_VERDICT_TESTS_PASSED'
