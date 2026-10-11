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

$restoreCalls = [Collections.Generic.List[bool]]::new()
foreach ($state in @('preparing', 'mounted')) {
    $restored = Invoke-HostedProfileRestoreIfRequired -ProfileState $state -Restore { $restoreCalls.Add($true) }
    if (-not $restored) { throw "Profile state $state must invoke guarded restoration" }
}
if ($restoreCalls.Count -ne 2) { throw 'Preparing and mounted states must invoke restoration once each' }
foreach ($state in @('not-created', 'normal')) {
    $restored = Invoke-HostedProfileRestoreIfRequired -ProfileState $state -Restore { $restoreCalls.Add($true) }
    if ($restored -or $restoreCalls.Count -ne 2) { throw "Profile state $state must skip VHD restoration" }
}
$notCreatedHarnessFailure = Resolve-HostedCapabilityVerdict -Conditions @(@{ class='harness-defect'; evidence=@{ message='AxHost compile failure' } }) `
    -Normal @{ status='not-run' } -Vhd @{ status='not-run' } -RootPrompt @{ status='unknown' } `
    -PositiveRoute $false -CleanupErrors @() -ProfileState 'not-created' -UserCreated $false
if ($notCreatedHarnessFailure -cne 'harness-defect') {
    throw 'Not-created profile cleanup must preserve the primary harness-defect instead of inventing cleanup failure'
}

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
$secondary=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $secondary | Out-Null
try {
    $secret = 'Ticket569-test-canary-9aA!'
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $canaryHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($secret)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    [IO.File]::WriteAllText((Join-Path $temporary 'injected.json'), "{`"value`":`"$secret`"}")
    $detected = Test-HostedSecretCanary -Directory $temporary -Sha256 $canaryHash -Length $secret.Length
    if (!$detected.leaked -or (Split-Path -Leaf $detected.file) -cne 'injected.json') { throw 'Secret canary failed to detect the injected secret' }
    [IO.File]::WriteAllText((Join-Path $temporary 'injected.json'), '{"value":"clean"}')
    foreach($case in @(
        @{name='utf16-le-no-bom';encoding=[Text.UnicodeEncoding]::new($false,$false,$false)},
        @{name='utf16-le-bom';encoding=[Text.UnicodeEncoding]::new($false,$true,$false)},
        @{name='utf16-be-no-bom';encoding=[Text.UnicodeEncoding]::new($true,$false,$false)},
        @{name='utf16-be-bom';encoding=[Text.UnicodeEncoding]::new($true,$true,$false)}
    )){
        $path=Join-Path $temporary ($case.name+'.json')
        [IO.File]::WriteAllText($path,"{`"value`":`"$secret`"}",$case.encoding)
        $detected=Test-HostedSecretCanary -Directory $temporary -Sha256 $canaryHash -Length $secret.Length
        if(!$detected.leaked -or (Split-Path -Leaf $detected.file) -cne (Split-Path -Leaf $path)){throw "Secret canary failed to detect the $($case.name) secret"}
        Remove-Item -LiteralPath $path -Force
    }
    [IO.File]::WriteAllText((Join-Path $temporary 'injected.json'), '{"value":"clean"}')
    if ((Test-HostedSecretCanary -Directory $temporary -Sha256 $canaryHash -Length $secret.Length).leaked) { throw 'Secret canary reported a leak in clean evidence' }
    $oversized=Join-Path $temporary 'oversized.bin'
    [IO.File]::WriteAllBytes($oversized,(New-Object byte[] (1MB+1)))
    $boundedFailure=$false
    try { $null=Test-HostedSecretCanary -Directory $temporary -Sha256 $canaryHash -Length $secret.Length -MaxBytes 1048576 }
    catch { $boundedFailure=$_.Exception.Message -match 'byte bound' }
    if(!$boundedFailure){throw 'Canary scan must fail closed before reading beyond its explicit run byte budget'}
    Remove-Item -LiteralPath $oversized -Force
    [IO.File]::WriteAllText((Join-Path $secondary 'runner-temp-owned.json'),"{`"value`":`"$secret`"}")
    $multiRoot=Test-HostedSecretCanary -Directories @($temporary,$secondary,$temporary) -Sha256 $canaryHash -Length $secret.Length
    if(!$multiRoot.leaked -or $multiRoot.root -cne [IO.Path]::GetFullPath($secondary)){throw 'Secret canary did not scan deduplicated, separate owned temporary roots'}
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force;Remove-Item -LiteralPath $secondary -Recurse -Force }

$generated = [Security.SecureString]::new()
foreach ($character in Get-HostedPasswordRequiredCharacters) { $generated.AppendChar($character) }
if ($generated.Length -ne 4) { throw 'Required password characters were not appended as individual chars' }
$generated.Dispose()

$workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../.github/workflows/hosted-capability.yml') -Raw
$probeSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-capability.ps1') -Raw
$verdictSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-capability-verdict.psm1') -Raw
$ownerSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-session-owner.ps1') -Raw
$profileSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'profile.ps1') -Raw
if ($workflow -notmatch '(?m)^\s+timeout-minutes:\s*30\s*$' -or
    $workflow -notmatch 'HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY' -or
    $workflow -notmatch 'HOSTED_CAPABILITY_JOB_STARTED_BOOT' -or
    $workflow -notmatch 'hosted-capability-supervisor\.ps1' -or
    $workflow -notmatch 'timeout-minutes:\s*\$\{\{ fromJSON\(env\.HOSTED_CAPABILITY_PROBE_TIMEOUT_MINUTES\) \}\}' -or
    $probeSource -notmatch '\$workDeadlineCounter = \$deadlines\.work' -or
    $probeSource -notmatch '\$cleanupDeadlineCounter = \$deadlines\.cleanup' -or
    $probeSource -notmatch 'Job-wide preflight work deadline elapsed during source preparation') {
    throw 'Hosted preflight deadlines must use the cross-step monotonic clock and independent supervisor'
}
if($probeSource -notmatch '\$script:secretCanaryRoots=@\(\$EvidenceDirectory,\$script:rdpOwnerRuntime\)' -or
   $probeSource -match '\$env:RUNNER_TEMP' -or
   $verdictSource -notmatch 'MaxElapsedMilliseconds=4000' -or
   $verdictSource -notmatch 'MaxBytes=16777216' -or
   $verdictSource -notmatch 'elapsed-time bound' -or
   $probeSource -notmatch 'Test-HostedSecretCanary -Directories \$script:secretCanaryRoots' -or
   $probeSource -notmatch 'passwordTransferPath=''worker-direct-named-pipe''' -or
   $ownerSource -notmatch 'Test-RuntimeSecret \$password' -or
   $ownerSource -notmatch 'automatic reconnect after unexpected or unplanned session state is prohibited'){
    throw 'Per-login credentials must stay on the one-shot worker pipe, be canaried across all owned temporary roots, and fail closed after an unexpected session drop'
}

if ($probeSource -notmatch '\$profileState = ''not-created''' -or
    $probeSource -notmatch 'Invoke-HostedProfileRestoreIfRequired -ProfileState \$profileState' -or
    $probeSource -notmatch 'preflightApartmentState=\$preflightApartmentState') {
    throw 'Hosted preflight must gate restoration on actual profile mutation and retain its apartment state'
}
foreach($operation in @("Invoke-Diskpart 'create-profile-vhd'","Invoke-Diskpart 'attach-profile-vhd'",'create-owned-profile-vhd-parent-directory','copy-normal-profile-into-owned-vhd','rename-normal-profile-to-owned-backup','create-original-profile-mount-directory','mount-vhd-at-original-profile-path','remove-temporary-vhd-drive-letter','detach-vhd-profile-mount-point','remove-profile-mount-placeholder','remove-empty-profile-restore-placeholder','recreate-missing-profile-restore-placeholder','restore-normal-profile-from-owned-backup','dismount-owned-profile-vhd','remove-owned-profile-vhd-file')){
    if($profileSource -notmatch [regex]::Escape($operation)){throw "Profile crash-boundary mutation is not individually acknowledged: $operation"}
}
if($profileSource -notmatch 'Hosted.*-and !\$MutationHook' -or $probeSource -notmatch '\-MutationMode Hosted -DeadlineCounter \$script:deadlineCounter -CounterFrequency \$script:counterFrequency -MutationHook' -or
   $probeSource -match "Invoke-RunMutation -Operation 'prepare-owned-vhd-profile'" -or
   $probeSource -match "Invoke-RunMutation -Operation 'restore-owned-normal-profile'"){
    throw 'VHD profile mutations must each use the supervisor-acknowledged hook inside profile.ps1'
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
$removeOwnedCases=@(
    @{preexisting=$false;attempted=$true;pre=4;attempt=5;count=1;subject=$true;expected='remove-owned'},
    @{preexisting=$false;attempted=$true;pre=4;attempt=5;count=0;subject=$false;expected='already-absent'},
    @{preexisting=$false;attempted=$true;pre=4;attempt=4;count=1;subject=$true;expected='refuse-unowned'},
    @{preexisting=$false;attempted=$false;pre=4;attempt=5;count=1;subject=$true;expected='refuse-unowned'},
    @{preexisting=$true;attempted=$true;pre=4;attempt=5;count=1;subject=$true;expected='preserve'}
)
foreach($case in $removeOwnedCases){
    $actual=Get-HostedRootRemoveOwnedDecision -Preexisting $case.preexisting -ImportAttempted $case.attempted `
        -PreabsenceSequence $case.pre -ImportAttemptSequence $case.attempt -MatchCount $case.count -SubjectMatches $case.subject
    if($actual -cne $case.expected){throw "RemoveOwned expected $($case.expected), observed $actual"}
}

Write-Output 'HOSTED_CAPABILITY_VERDICT_TESTS_PASSED'

$supervisorArgs=@{TestFault='none';WorkerVerdict='feasible-observed';CleanupStatus='complete';TerminationProven=$true;WorkerIdentityProven=$true;FailureLatched=$false;LocalFinalWriteProven=$true;RecoveryContextProven=$true}
if((Resolve-HostedCapabilitySupervisorVerdict @supervisorArgs).verdict -cne 'feasible-observed'){throw 'Complete parent proof was refused'}
foreach($field in @('LocalFinalWriteProven','RecoveryContextProven','TerminationProven','WorkerIdentityProven')){
    $fault=$supervisorArgs.Clone();$fault[$field]=$false
    if((Resolve-HostedCapabilitySupervisorVerdict @fault).verdict -ceq 'feasible-observed'){throw "Parent verdict passed without $field"}
}
$fault=$supervisorArgs.Clone();$fault.FailureLatched=$true
if((Resolve-HostedCapabilitySupervisorVerdict @fault).verdict -ceq 'feasible-observed'){throw 'Parent verdict lost an irreversible failure'}
