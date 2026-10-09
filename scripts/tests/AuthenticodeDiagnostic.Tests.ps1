$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$workflowPath = Join-Path $repoRoot '.github/workflows/ci.yml'
$modulePath = Join-Path $repoRoot 'tests/installed-attachment/authenticode-diagnostic.psm1'
Import-Module -Name $modulePath -Force

function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock] $Action, [string] $Message) {
    try { & $Action } catch { return $_.Exception.Message }
    throw $Message
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ticket569-authenticode-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    # Exercise the actual MSI SIP/CryptQueryObject path against exact owner-pinned
    # public bytes. No trust-store preparation or installation occurs. The diagnostic
    # records ambient WinVerifyTrust output, but this test checks decoder/adapter shape
    # only and never claims native alpha.7 admission.
    $alpha7Msi = Join-Path $tempRoot 'go-mapi-suite-3.2.0-alpha.7-x64.msi'
    $alpha7Uri = 'https://github.com/marcfargas/go-mapi/releases/download/suite-v3.2.0-alpha.7/go-mapi-suite-3.2.0-alpha.7-x64.msi'
    Invoke-WebRequest -Uri $alpha7Uri -OutFile $alpha7Msi -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    $alpha7Hash = (Get-FileHash -LiteralPath $alpha7Msi -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert ($alpha7Hash -ceq 'bcf00f8511b8f076582ff06f9ecb00a67aa9476dd3cbdebc5f6b975f4ec94a68') 'Downloaded RFC3161 decoder fixture differs from the pinned alpha.7 MSI'
    $alpha7Signature = Get-AuthenticodeSignature -LiteralPath $alpha7Msi -ErrorAction Stop
    Assert ($alpha7Signature.SignerCertificate -and $alpha7Signature.TimeStamperCertificate) 'Pinned alpha.7 decoder fixture did not expose signer and timestamp certificates'
    Initialize-WinVerifyTrustType
    $alpha7Diagnostic = Get-AuthenticodeDiagnostic -MsiPath $alpha7Msi -ObservationTimeUtc ([DateTime]::UtcNow)
    Assert ($alpha7Diagnostic.collectionComplete -and $null -eq $alpha7Diagnostic.rfc3161Exception) 'Real alpha.7 diagnostic collection lost its RFC3161 proof'
    Assert ($alpha7Diagnostic.signature.signingTimeUtc -eq '2026-09-28T17:32:29.4750000Z') 'Real alpha.7 diagnostic did not retain RFC3161 genTime on the signature record'
    $classificationInput = Join-Path $tempRoot 'alpha7-real-diagnostic.json'
    $classificationPayload = @{
        native=$alpha7Diagnostic; msiSHA256=$alpha7Hash; msiSize=(Get-Item -LiteralPath $alpha7Msi).Length
        portable=@{ historical=@{
            timestampUtc='2026-09-28T17:32:29Z'
            signingRootSHA256='41c1fd9b83c54731c84375c07ec2585b61d032961d9c578c1784fca0e3c59f6e'
            timestampRootSHA256='5367f20c7ade0e2bca790915056d086b720c33c1fa2a2661acf787e3292e1270'
            digestVerified=$true; signatureVerified=$true; timestampVerified=$true
        } }
    }
    [IO.File]::WriteAllText($classificationInput, (ConvertTo-Json -InputObject $classificationPayload -Depth 32), [Text.UTF8Encoding]::new($false))
    $classificationOutput = & python (Join-Path $repoRoot 'tests/installed-attachment/alpha7-diagnostic-classification.py') $classificationInput 2>&1
    $classificationText = $classificationOutput -join ' '
    Assert ($LASTEXITCODE -eq 0 -and $classificationText -match 'ALPHA7_DECODER_ADAPTER_SHAPE_PASSED' -and
        $classificationText -match 'nativeWinVerifyTrustHResult' -and $classificationText -match 'nativeAdmissionClaimed": false') `
        "Actual Get-AuthenticodeDiagnostic output failed host-side alpha.7 decoder/adapter shape validation: $classificationText"
    Write-Output $classificationText
    Import-Module (Join-Path $repoRoot 'tests/installed-attachment/authenticode-rfc3161.psm1') -Force
    $alpha7Timestamp = Get-AuthenticodeRfc3161Observation -MsiPath $alpha7Msi `
        -SignerCertificate $alpha7Signature.SignerCertificate -TimestampCertificate $alpha7Signature.TimeStamperCertificate `
        -CheckedAtUtc ([DateTime]::UtcNow)
    Assert ($alpha7Timestamp.signingTimeSource -eq 'rfc3161-tstinfo-genTime' -and $alpha7Timestamp.signingTimeUtc -eq '2026-09-28T17:32:29.4750000Z') 'MSI SIP decoder returned the wrong RFC3161 genTime'
    Assert ($alpha7Timestamp.messageImprint.algorithmOid -eq '2.16.840.1.101.3.4.2.1' -and $alpha7Timestamp.messageImprint.hashedMessage -eq '6642489753c751c14ceae5961828d0db45f38c22c23eed7ab264c258b811c885') 'MSI RFC3161 imprint differs from the pinned outer signer digest'
    Assert ($alpha7Timestamp.timestampSignerThumbprint -eq '9D64791BDBA7AB705D8EEB6BC275951F512BC45C' -and $alpha7Timestamp.tokenSignatureVerified) 'RFC3161 CMS token signature or timestamp signer identity was not verified'
    $legacyProbePath = Join-Path $tempRoot 'rfc3161-windows-powershell51.ps1'
    @'
param([string] $MsiPath, [string] $ModulePath)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
$signature = Get-AuthenticodeSignature -LiteralPath $MsiPath -ErrorAction Stop
$proof = Get-AuthenticodeRfc3161Observation -MsiPath $MsiPath -SignerCertificate $signature.SignerCertificate `
    -TimestampCertificate $signature.TimeStamperCertificate -CheckedAtUtc ([DateTime]::UtcNow)
$proof | ConvertTo-Json -Compress -Depth 4
'@ | Set-Content -LiteralPath $legacyProbePath -Encoding ascii
    $legacyOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $legacyProbePath `
        -MsiPath $alpha7Msi -ModulePath (Join-Path $repoRoot 'tests/installed-attachment/authenticode-rfc3161.psm1') 2>&1
    $legacyExit = $LASTEXITCODE
    Assert ($legacyExit -eq 0) "Windows PowerShell 5.1 could not decode the pinned MSI RFC3161 token: $($legacyOutput -join ' ')"
    $legacyProof = (($legacyOutput | Select-Object -Last 1) | ConvertFrom-Json)
    Assert ($legacyProof.signingTimeUtc -eq '2026-09-28T17:32:29.4750000Z' -and $legacyProof.tokenSignatureVerified) 'Windows PowerShell 5.1 returned a different RFC3161 observation'
    $encodedCms = [Ticket569Rfc3161Cms]::ReadEmbeddedSignedMessage($alpha7Msi)
    $encryptedDigest = [Ticket569Rfc3161Cms]::ReadEmbeddedEncryptedDigest($alpha7Msi)
    $tamperedDigest = [byte[]]$encryptedDigest.Clone(); $tamperedDigest[0] = $tamperedDigest[0] -bxor 1
    $mismatch = Assert-Throws {
        Get-AuthenticodeRfc3161ObservationFromCms -EncodedMessage $encodedCms -OuterEncryptedDigest $tamperedDigest `
            -SignerCertificate $alpha7Signature.SignerCertificate -TimestampCertificate $alpha7Signature.TimeStamperCertificate `
            -CheckedAtUtc ([DateTime]::UtcNow)
    } 'Tampered outer signer digest unexpectedly passed RFC3161 imprint binding'
    Assert ($mismatch -like '*messageImprint*') 'Tampered signer digest did not fail at the RFC3161 messageImprint binding'

    # A same-named but altered MSI must be rejected before any trust helper can run.
    $fakeMsi = Join-Path $tempRoot 'go-mapi-suite-3.2.0-alpha.9-x64.msi'
    $fakeProof = Join-Path $tempRoot 'suite-3.2.0-alpha.9.validation.json'
    [IO.File]::WriteAllText($fakeMsi, 'not the pinned MSI')
    [IO.File]::WriteAllText($fakeProof, '{}')
    $message = Assert-Throws { Assert-Alpha9DiagnosticInputs -MsiPath $fakeMsi -ProofPath $fakeProof } 'Altered MSI unexpectedly passed the package pin check'
    Assert ($message -like '*MSI bytes differ*') 'Altered MSI was not rejected by its pinned byte digest'
    $preflightReport = Join-Path $tempRoot 'preflight-rejected.json'
    $priorRunnerTemp = $env:RUNNER_TEMP
    $env:RUNNER_TEMP = $tempRoot
    try {
        & pwsh -NoProfile -NonInteractive -File (Join-Path $repoRoot 'tests/installed-attachment/run-authenticode-diagnostic.ps1') `
            -MsiPath $fakeMsi -ProofPath $fakeProof -EvidencePath $preflightReport
        $preflightExit = $LASTEXITCODE
    } finally { $env:RUNNER_TEMP = $priorRunnerTemp }
    Assert ($preflightExit -ne 0 -and (Test-Path -LiteralPath $preflightReport -PathType Leaf)) 'Rejected input did not produce a failed run and durable preflight report'
    $rejected = Get-Content -LiteralPath $preflightReport -Raw | ConvertFrom-Json
    Assert ($rejected.verdict -eq 'diagnostic-input-rejected' -and -not $rejected.trustMutationAttempted) 'Rejected input report did not prove no trust preparation was attempted'

    # The strict trust helper may throw after it has recorded and imported the owned root.
    # That expected non-Valid outcome must still produce observations and owned cleanup.
    $script:writtenEvidence = $null
    $script:cleanupObservedState = $null
    $ownedState = [pscustomobject]@{ preexisting = $false; importAttempted = $true; imported = $true }
    $result = Invoke-OwnedTrustDiagnosticLifecycle `
        -Prepare { throw [InvalidOperationException]::new('expected UnknownError after owned import') } `
        -ReadOwnedState { $ownedState } `
        -Observe { param($state) [pscustomobject]@{ status = 'UnknownError'; statusMessage = 'captured diagnostic message'; winVerifyTrustHResult = '0x800B0109'; chainVerificationTimeUtc = '2026-10-09T00:00:00Z'; chainDiagnosticOnly = $true } } `
        -Cleanup { param($state) $script:cleanupObservedState = $state; [pscustomobject]@{ rootPresentAfterCleanup = $false; ownedRootRemoved = $true } } `
        -WriteEvidence { param($record) $script:writtenEvidence = $record }
    Assert $result.collectionComplete 'Owned-root UnknownError observation did not complete with successful cleanup'
    Assert ($result.preparationException.message -like '*expected UnknownError*') 'Expected trust-helper failure was not retained'
    Assert ($result.observation.status -eq 'UnknownError' -and $result.observation.statusMessage -eq 'captured diagnostic message') 'Full Authenticode diagnostics were not retained'
    Assert ($result.observation.winVerifyTrustHResult -eq '0x800B0109' -and $result.observation.chainDiagnosticOnly) 'WinVerifyTrust or diagnostic-only chain evidence was lost'
    Assert ($script:cleanupObservedState -eq $ownedState -and $result.cleanup.ownedRootRemoved) 'Owned-root cleanup did not receive the exact recorded ownership state'
    Assert ($script:writtenEvidence.collectionComplete) 'The written evidence did not capture the completed outcome'

    # A collected negative chain status is diagnostic evidence, but an exception while
    # collecting either required signer/timestamp chain must keep the observation incomplete.
    # Exercise mocked WinVerifyTrust and chain-provider cases in a separate CLR.
    # The real alpha.7 diagnostic above initialized the production static type in
    # this process; Add-Type cannot redefine it to return synthetic values.
    $isolatedDiagnosticPath = Join-Path $tempRoot 'isolated-diagnostic-fixtures.ps1'
    @'
param([string] $ModulePath)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
public static class Ticket569WinVerifyTrust {
 public static object Verify(string path) { return new { verifyHResultHex = "0x800B0109" }; }
}
"@
Import-Module -Name $ModulePath -Force
$diagnosticModule = Get-Module -Name authenticode-diagnostic
& $diagnosticModule { function script:Import-Module { param([string] $Name, [switch] $Force) } }
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
    'CN=synthetic-authenticode-test', $rsa,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$fixtureCertificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
try {
    & $diagnosticModule {
        param($certificate)
        $script:chainCollectionFails = $true
        $script:rfcCollectionFails = $false
        $script:fixtureCertificate = $certificate
        function script:Get-AuthenticodeSignature {
            param($LiteralPath, $ErrorAction)
            [pscustomobject]@{ Status = 'UnknownError'; StatusMessage = 'synthetic'; SignatureType = 'Authenticode'; IsOSBinary = $false; SignerCertificate = $script:fixtureCertificate; TimeStamperCertificate = $script:fixtureCertificate }
        }
        function script:Get-AuthenticodeRfc3161Observation {
            param($MsiPath, $SignerCertificate, $TimestampCertificate, $CheckedAtUtc)
            if ($script:rfcCollectionFails) { throw [InvalidOperationException]::new('synthetic RFC3161 collection failure') }
            [pscustomobject]@{ signingTimeUtc='2026-09-28T17:32:29.4750000Z'; signingTimeSource='rfc3161-tstinfo-genTime' }
        }
        function script:Get-ChainDiagnostic {
            param($Certificate, $VerificationTimeUtc, $CertificateRole)
            if ($script:chainCollectionFails) {
                return [pscustomobject]@{ role = $CertificateRole; exception = [pscustomobject]@{ type = 'SyntheticChainCollectionFailure'; message = 'chain provider could not collect evidence' } }
            }
            return [pscustomobject]@{ role = $CertificateRole; buildSucceeded = $false; chainStatus = @([pscustomobject]@{ status = 'UntrustedRoot'; information = 'synthetic negative chain status' }); elements = @(); exception = $null }
        }
    } $fixtureCertificate
    $chainFailure = Get-AuthenticodeDiagnostic -MsiPath $PSCommandPath -ObservationTimeUtc ([DateTime]::UtcNow)
    if ($chainFailure.collectionComplete -or -not $chainFailure.signerChain.exception.message -or -not $chainFailure.timestampChain.exception.message) { throw 'Signer/timestamp chain collection exceptions were reported complete or lost' }
    & $diagnosticModule { $script:chainCollectionFails = $false }
    $negativeChain = Get-AuthenticodeDiagnostic -MsiPath $PSCommandPath -ObservationTimeUtc ([DateTime]::UtcNow)
    if (-not $negativeChain.collectionComplete -or $negativeChain.signerChain.buildSucceeded -ne $false -or $negativeChain.signerChain.chainStatus[0].status -ne 'UntrustedRoot') { throw 'A collected negative chain status was treated as a collection failure' }
    & $diagnosticModule { $script:rfcCollectionFails = $true }
    $rfcFailure = Get-AuthenticodeDiagnostic -MsiPath $PSCommandPath -ObservationTimeUtc ([DateTime]::UtcNow)
    if ($rfcFailure.collectionComplete -or $rfcFailure.rfc3161Exception.message -notlike '*synthetic RFC3161 collection failure*') { throw 'RFC3161 collection exception was reported as complete' }
    Write-Output 'TICKET569_SYNTHETIC_AUTHENTICODE_FIXTURES_PASSED'
} finally {
    $fixtureCertificate.Dispose()
    $rsa.Dispose()
}
'@ | Set-Content -LiteralPath $isolatedDiagnosticPath -Encoding ascii
    $isolatedOutput = & pwsh -NoProfile -NonInteractive -File $isolatedDiagnosticPath -ModulePath $modulePath 2>&1
    $isolatedExit = $LASTEXITCODE
    $isolatedText = $isolatedOutput -join ' '
    Assert ($isolatedExit -eq 0 -and $isolatedText -match 'TICKET569_SYNTHETIC_AUTHENTICODE_FIXTURES_PASSED') `
        "Isolated synthetic Authenticode fixtures failed in a fresh CLR: $isolatedText"

    # Root-store inventory is a required observation: an exception is incomplete,
    # while an observed absence or mismatch remains collected diagnostic data.
    $inventoryFailure = [pscustomobject]@{ type = 'SyntheticInventoryFailure'; message = 'root inventory unavailable' }
    Assert (-not (Test-RequiredTrustObservationComplete -Diagnostic ([pscustomobject]@{collectionComplete=$true}) -RootInventoryException $inventoryFailure)) 'Root inventory collection exception was ignored'
    Assert (Test-RequiredTrustObservationComplete -Diagnostic ([pscustomobject]@{collectionComplete=$true}) -RootInventoryException $null) 'A collected root inventory observation was incorrectly rejected'
    $script:inventoryFailureEvidence = $null
    $inventoryLifecycle = Invoke-OwnedTrustDiagnosticLifecycle `
        -Prepare { } `
        -ReadOwnedState { $ownedState } `
        -Observe { param($state) [pscustomobject]@{ trust = [pscustomobject]@{ inventoryException = $inventoryFailure }; collectionComplete = (Test-RequiredTrustObservationComplete -Diagnostic ([pscustomobject]@{collectionComplete=$true}) -RootInventoryException $inventoryFailure) } } `
        -Cleanup { [pscustomobject]@{ ownedRootRemoved = $true } } `
        -WriteEvidence { param($record) $script:inventoryFailureEvidence = $record }
    Assert (-not $inventoryLifecycle.collectionComplete -and $inventoryLifecycle.observation.trust.inventoryException.message -eq 'root inventory unavailable') 'Root inventory exception did not fail closed with evidence retained'

    # If the atomic artifact writer fails after collection/cleanup, the lifecycle
    # must emit the complete failed record to captured stderr before the caller exits.
    $fallbackChildScript = @'
param([string] $ModulePath)
$ErrorActionPreference = 'Stop'
Import-Module -Name $ModulePath -Force
$state = [pscustomobject]@{ preexisting = $false; importAttempted = $true; imported = $true }
$result = Invoke-OwnedTrustDiagnosticLifecycle `
    -Prepare { throw 'synthetic primary preparation failure' } `
    -ReadOwnedState { $state } `
    -Observe { param($owned) [pscustomobject]@{ statusMessage = 'synthetic primary status message'; collectionComplete = $true } } `
    -Cleanup { throw 'synthetic cleanup failure' } `
    -WriteEvidence { param($record) throw 'synthetic evidence writer failure' }
if (-not $result.collectionComplete) { exit 1 }
exit 0
'@
    $fallbackStdoutPath = Join-Path $tempRoot 'evidence-write-failure.stdout'
    $fallbackStderrPath = Join-Path $tempRoot 'evidence-write-failure.stderr'
    $modulePathLiteral = "'" + $modulePath.Replace("'", "''") + "'"
    $fallbackCommand = $fallbackChildScript.Replace('param([string] $ModulePath)', "`$ModulePath = $modulePathLiteral")
    $encodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($fallbackCommand))
    $pwshPath = (Get-Command pwsh).Source
    $fallbackProcess = Start-Process -FilePath $pwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedChild) -RedirectStandardOutput $fallbackStdoutPath -RedirectStandardError $fallbackStderrPath -PassThru -Wait -NoNewWindow
    $fallbackText = [IO.File]::ReadAllText($fallbackStderrPath)
    $fallbackLine = @($fallbackText -split "`r?`n" | Where-Object { $_.StartsWith('TICKET569_AUTHENTICODE_EVIDENCE_FALLBACK=') }) | Select-Object -First 1
    Assert ($fallbackProcess.ExitCode -eq 1 -and $fallbackLine) 'Evidence writer failure did not fail the process and emit a captured-log fallback'
    $fallbackRecord = $fallbackLine.Substring('TICKET569_AUTHENTICODE_EVIDENCE_FALLBACK='.Length) | ConvertFrom-Json
    Assert (-not $fallbackRecord.collectionComplete -and $fallbackRecord.verdict -eq 'diagnostic-evidence-write-failed') 'Fallback record did not retain the aggregate failure'
    Assert ($fallbackRecord.preparationException.message -eq 'synthetic primary preparation failure' -and $fallbackRecord.observation.statusMessage -eq 'synthetic primary status message') 'Fallback record lost primary preparation or observation evidence'
    Assert ($fallbackRecord.cleanupException.message -eq 'synthetic cleanup failure' -and $fallbackRecord.evidenceWriteException.message -eq 'synthetic evidence writer failure') 'Fallback record lost cleanup or evidence-write failure details'

    # The trust helper persists ownership before import. If it stops between import and
    # the imported=true rewrite, that state still authorizes exact-root cleanup.
    $script:partialPrepareCleanupState = $null
    $script:partialPrepareObserved = $false
    $partialState = [pscustomobject]@{ preexisting = $false; importAttempted = $true; imported = $false }
    $partial = Invoke-OwnedTrustDiagnosticLifecycle `
        -Prepare { throw [InvalidOperationException]::new('import completion rewrite was interrupted') } `
        -ReadOwnedState { $partialState } `
        -Observe { param($state) $script:partialPrepareObserved = $true; [pscustomobject]@{ status = 'UnknownError' } } `
        -Cleanup { param($state) $script:partialPrepareCleanupState = $state; [pscustomobject]@{ rootPresentAfterCleanup = $false; ownedRootRemoved = $true } } `
        -WriteEvidence { param($record) $script:writtenEvidence = $record }
    Assert (-not $partial.preparationComplete -and -not $partial.collectionComplete) 'Interrupted import was reported as complete'
    Assert ($script:partialPrepareObserved -and $script:partialPrepareCleanupState -eq $partialState) 'Persisted pre-import ownership did not permit observation and exact-root cleanup'
    Assert ($partial.observation.status -eq 'UnknownError' -and $partial.cleanup.ownedRootRemoved) 'Partial-import evidence or cleanup result was lost'

    # A preexisting root is preserved; the lifecycle forwards its ownership state to cleanup.
    $script:cleanupPreservedPreexisting = $false
    $preexisting = [pscustomobject]@{ preexisting = $true; importAttempted = $false; imported = $false }
    $preserved = Invoke-OwnedTrustDiagnosticLifecycle `
        -Prepare { } `
        -ReadOwnedState { $preexisting } `
        -Observe { param($state) [pscustomobject]@{ status = 'Valid' } } `
        -Cleanup { param($state) $script:cleanupPreservedPreexisting = $state.preexisting; [pscustomobject]@{ rootPresentAfterCleanup = $true; preexistingRootPreserved = $true } } `
        -WriteEvidence { param($record) }
    Assert ($preserved.collectionComplete -and $script:cleanupPreservedPreexisting -and $preserved.cleanup.preexistingRootPreserved) 'Preexisting-root ownership was not preserved through cleanup'

    # Missing ownership state fails closed: no cleanup runs and a failure record is still written.
    $script:missingStateCleanupCalled = $false
    $script:missingStateEvidence = $null
    $missing = Invoke-OwnedTrustDiagnosticLifecycle `
        -Prepare { throw [InvalidOperationException]::new('prepare stopped before state write') } `
        -ReadOwnedState { $null } `
        -Observe { throw 'observer must not run without ownership state' } `
        -Cleanup { $script:missingStateCleanupCalled = $true } `
        -WriteEvidence { param($record) $script:missingStateEvidence = $record }
    Assert (-not $missing.collectionComplete -and -not $script:missingStateCleanupCalled) 'Missing ownership state did not fail closed'
    Assert ($missing.cleanupException.type -eq 'OwnedTrustStateMissing' -and $script:missingStateEvidence) 'Missing-state failure evidence was not retained'

    # A cleanup failure must override diagnostic completion while preserving the observed signature.
    $cleanupFailure = Invoke-OwnedTrustDiagnosticLifecycle `
        -Prepare { } `
        -ReadOwnedState { $ownedState } `
        -Observe { param($state) [pscustomobject]@{ status = 'UnknownError' } } `
        -Cleanup { throw [InvalidOperationException]::new('owned-root removal failed') } `
        -WriteEvidence { param($record) $script:writtenEvidence = $record }
    Assert (-not $cleanupFailure.collectionComplete -and $cleanupFailure.observation.status -eq 'UnknownError') 'Cleanup failure did not override success or erased primary evidence'
    Assert ($cleanupFailure.cleanupException.message -like '*owned-root removal failed*') 'Cleanup failure details were not retained'

    # Check the actual workflow routes only the opt-in diagnostic dispatch to its isolated job.
    $workflow = Get-Content -LiteralPath $workflowPath -Raw
    $entrypoint = Get-Content -LiteralPath (Join-Path $repoRoot 'tests/installed-attachment/run-authenticode-diagnostic.ps1') -Raw
    Assert ($entrypoint.Contains('Test-RequiredTrustObservationComplete -Diagnostic $diagnostic -RootInventoryException $rootInventoryException')) 'Production observation does not include root-store inventory collection in its completion result'
    Assert ($entrypoint.Contains('if (-not $lifecycle.collectionComplete) { exit 1 }')) 'Production entrypoint no longer fails on incomplete lifecycle evidence'
    Assert ($workflow -match '(?s)run_authenticode_diagnostic:.*?type: boolean\s+default: false') 'Diagnostic dispatch input is not an opt-in boolean defaulting false'
    $diagnosticOnlyGate = "github.event_name == 'workflow_dispatch' && inputs.run_authenticode_diagnostic == true"
    $existingJobs = @('user-component','user-windows-shell','build-interceptor','admin-msi-fixtures','admin-msi-scenario','admin-msi','go-race')
    foreach ($job in $existingJobs) {
        $jobBlock = [regex]::Match($workflow, "(?ms)^  ${job}:\r?\n(?<body>.*?)(?=^  [a-zA-Z0-9_-]+:|\z)")
        Assert $jobBlock.Success "Existing job block is missing: $job"
        Assert ($jobBlock.Groups['body'].Value.Contains($diagnosticOnlyGate)) "Existing job does not exclude diagnostic-only dispatch: $job"
    }
    $diagnosticBlock = [regex]::Match($workflow, "(?ms)^  alpha9-authenticode-diagnostic:\r?\n(?<body>.*?)(?=^  [a-zA-Z0-9_-]+:|\z)")
    Assert ($diagnosticBlock.Success -and $diagnosticBlock.Groups['body'].Value.Contains($diagnosticOnlyGate)) 'Diagnostic job is not restricted to its explicit workflow dispatch input'
    Assert ($diagnosticBlock.Groups['body'].Value -match 'runs-on: windows-2025\s+timeout-minutes: 15') 'Diagnostic job is not bounded to the selected runner and 15-minute timeout'

    function Is-DiagnosticOnly([string] $Event, [bool] $Enabled) { return $Event -eq 'workflow_dispatch' -and $Enabled }
    function Existing-JobRuns([string] $Job, [string] $Event, [bool] $Diagnostic, [bool] $RunRace) {
        if (Is-DiagnosticOnly $Event $Diagnostic) { return $false }
        if ($Job -eq 'go-race') { return $Event -eq 'schedule' -or $RunRace }
        return $Event -ne 'schedule'
    }
    $cases = @(
        @{ event = 'push'; diagnostic = $false; race = $false; expectedExisting = $true; expectedDiagnostic = $false },
        @{ event = 'pull_request'; diagnostic = $false; race = $false; expectedExisting = $true; expectedDiagnostic = $false },
        @{ event = 'workflow_call'; diagnostic = $false; race = $false; expectedExisting = $true; expectedDiagnostic = $false },
        @{ event = 'workflow_dispatch'; diagnostic = $false; race = $false; expectedExisting = $true; expectedDiagnostic = $false },
        @{ event = 'workflow_dispatch'; diagnostic = $false; race = $true; expectedExisting = $true; expectedDiagnostic = $false },
        @{ event = 'workflow_dispatch'; diagnostic = $true; race = $false; expectedExisting = $false; expectedDiagnostic = $true },
        @{ event = 'workflow_dispatch'; diagnostic = $true; race = $true; expectedExisting = $false; expectedDiagnostic = $true },
        @{ event = 'schedule'; diagnostic = $false; race = $false; expectedExisting = $false; expectedDiagnostic = $false }
    )
    foreach ($case in $cases) {
        $expectedDiag = Is-DiagnosticOnly $case.event $case.diagnostic
        Assert ($expectedDiag -eq $case.expectedDiagnostic) "Diagnostic route mismatch for $($case.event), diagnostic=$($case.diagnostic)"
        foreach ($job in $existingJobs) {
            $runs = Existing-JobRuns $job $case.event $case.diagnostic $case.race
            if ($job -eq 'go-race' -and $case.event -eq 'schedule') { Assert $runs 'Scheduled race behavior changed' }
            elseif ($case.expectedExisting) { Assert ($runs -eq ($job -ne 'go-race' -or $case.race)) "Ordinary existing route changed for $job/$($case.event)" }
            else { Assert (-not $runs) "Diagnostic-only dispatch also runs unrelated job $job" }
        }
    }

    Write-Output 'Authenticode diagnostic ownership, failure, pinning, and workflow-routing tests passed'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
