Set-StrictMode -Version Latest

$script:Alpha7 = [ordered]@{
    kind = 'exact-alpha7-historical-fixture'
    tag = 'suite-v3.2.0-alpha.7'
    sourceCommit = '3d33779ad21d28b5579fb638c0a31ee8f698da1c'
    validationRunId = '36458319650'
    validationAttempt = '1'
    msiName = 'go-mapi-suite-3.2.0-alpha.7-x64.msi'
    msiSize = 12021760
    msiSha256 = 'bcf00f8511b8f076582ff06f9ecb00a67aa9476dd3cbdebc5f6b975f4ec94a68'
    signerSha1 = '076F98CC1928F8F8604B4A384A6BA27FA884F920'
    timestampSha1 = '9D64791BDBA7AB705D8EEB6BC275951F512BC45C'
    signerNotBeforeUtc = '2026-09-27T10:11:51Z'
    signerNotAfterUtc = '2026-09-30T10:11:51Z'
    lifetimeSigningEku = '1.3.6.1.4.1.311.10.3.13'
    timestampUtc = '2026-09-28T17:32:29Z'
    rfc3161GenTimeUtc = '2026-09-28T17:32:29.4750000Z'
    rfc3161MessageImprintSha256 = '6642489753c751c14ceae5961828d0db45f38c22c23eed7ab264c258b811c885'
    signingRootSha256 = '41c1fd9b83c54731c84375c07ec2585b61d032961d9c578c1784fca0e3c59f6e'
    signingRootSha1 = 'DFA0E53504EF5328FAEC21AD7DF14C10B07C4FCB'
    timestampRootSha256 = '5367f20c7ade0e2bca790915056d086b720c33c1fa2a2661acf787e3292e1270'
    validationName = 'suite-3.2.0-alpha.7.validation.json'
    validationSha256 = '3400ef558184216eef8c462fbfc2a3fbea85bb2c23f61403b3b5a922778d73f7'
    manifestName = 'go-mapi-suite-3.2.0-alpha.7.manifest.json'
    manifestSha256 = 'e4ff6e5d6e4159691aeeb9276a669afd91437829ed131b0fbdba5995d950fbf7'
    targetsName = 'suite-targets.json'
    targetsSha256 = '8e879ea2542aa2ace7ddefc7c827e998091e517b1ecd2795abf95c85444961c3'
    appArtifactsName = 'app-artifacts.json'
    appArtifactsSha256 = 'a216c087967c25c6a74f2e8be6d6333af1182e8aabae5f04a4271fcb9e0a46e6'
    appSha256 = 'eb2b6b828af2f48bd9e3c866663ac01a92642fc9913b6bf927e076178afbc2c4'
    x64DllSha256 = '51eb64a2faf60e048b473e2de0f0c7bee49dfaa77f35294fc380e0d5cde03764'
    portableEvidenceSha256Sums = '05105cbe4d66db00be45231eadea0ffef256651c7579b7493dd1137cff1ea488'
    releaseApiSha256 = '47a77ccf6cc9930abaf3fc61e1d241175367e00432921cf893dcb2a41b802c39'
}

function Get-Alpha7Sha256([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-Alpha7BytesSha256([byte[]] $Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Convert-Alpha7UtcSecondPrecision([string] $Value) {
    $parsed = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    return $parsed.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-Alpha7PortableEvidence([string] $Directory) {
    $sumPath = Join-Path $Directory 'SHA256SUMS'
    if (!(Test-Path -LiteralPath $sumPath -PathType Leaf) -or (Get-Alpha7Sha256 $sumPath) -cne $script:Alpha7.portableEvidenceSha256Sums) {
        throw 'Pinned alpha.7 portable SHA256SUMS identity mismatch'
    }
    $rootFull = [IO.Path]::GetFullPath($Directory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $listed = @{}
    foreach ($line in Get-Content -LiteralPath $sumPath -Encoding ASCII) {
        if ($line -notmatch '^([0-9a-f]{64})  \./(.+)$') { throw 'Pinned alpha.7 portable SHA256SUMS contains a malformed entry' }
        $relative = $Matches[2]
        if ($relative -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($relative) -or $listed.ContainsKey($relative)) {
            throw 'Pinned alpha.7 portable SHA256SUMS contains an unsafe or duplicate path'
        }
        $path = [IO.Path]::GetFullPath((Join-Path $Directory $relative))
        if (!$path.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-Alpha7Sha256 $path) -cne $Matches[1]) { throw "Pinned alpha.7 portable evidence hash mismatch: $relative" }
        $listed[$relative] = $Matches[1]
    }
    $required = @('alpha7-historical-verify.log','alpha7-current-verify.log','alpha7-altered-verify.log','alpha7-altered.msi','inputs/root-test.pem','inputs/microsoft-identity-root-2020.pem','inputs/all-crls.pem','verifier/osslsigncode','provenance.txt')
    foreach ($requiredPath in $required) { if (!$listed.ContainsKey($requiredPath)) { throw "Portable alpha.7 bundle omits required evidence: $requiredPath" } }
    $historical = Get-Content -LiteralPath (Join-Path $Directory 'alpha7-historical-verify.log') -Raw
    $current = Get-Content -LiteralPath (Join-Path $Directory 'alpha7-current-verify.log') -Raw
    $altered = Get-Content -LiteralPath (Join-Path $Directory 'alpha7-altered-verify.log') -Raw
    $historicalMustContain = @(
        "Calculated message digest        : $($script:Alpha7.msiSha256.ToUpperInvariant())",
        'Signature verification: ok','Timestamp Server Signature verification: ok',
        'Timestamp Server Signature CRL verification: ok','Signature CRL verification: ok',
        "Timestamp time: Sep 28 17:32:29 2026 GMT",'notAfter : Sep 30 10:11:51 2026 GMT',
        "Warning: Ignoring 'certificate has expired' error for CRL validation"
    )
    foreach ($fact in $historicalMustContain) { if ($historical -notlike "*$fact*") { throw "Portable alpha.7 historical log omitted required fact: $fact" } }
    if ($current -notlike '*Timestamp Server Signature verification is disabled*' -or $current -notlike '*Error: certificate has expired*' -or $current -notlike '*Signature verification: failed*') { throw 'Portable alpha.7 current-time expired-leaf control is incomplete' }
    if ($altered -notlike '*MISMATCH!!!*' -or $altered -notlike '*Signature verification: failed*') { throw 'Portable alpha.7 altered-file digest control is incomplete' }
    foreach ($entry in @(
        @{ File='inputs/root-test.pem'; Expected=$script:Alpha7.signingRootSha256 },
        @{ File='inputs/microsoft-identity-root-2020.pem'; Expected=$script:Alpha7.timestampRootSha256 }
    )) {
        $pem = Get-Content -LiteralPath (Join-Path $Directory $entry.File) -Raw -Encoding ASCII
        $pem = [regex]::Replace($pem, '(?m)^(?:subject|issuer)=.*\r?\n', '')
        if ($pem -notmatch '(?s)-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----') { throw "Portable alpha.7 certificate is malformed: $($entry.File)" }
        $der = [Convert]::FromBase64String(($Matches[1] -replace '\s',''))
        if ((Get-Alpha7BytesSha256 $der) -cne $entry.Expected) { throw "Portable alpha.7 root certificate identity mismatch: $($entry.File)" }
    }
    $warning = ($historical -split "`r?`n" | Where-Object { $_ -like "*Warning: Ignoring 'certificate has expired' error for CRL validation*" } | Select-Object -First 1)
    $digestMatch = [regex]::Match($historical, '(?m)^Calculated message digest\s*:\s*([0-9A-Fa-f]{64})\s*$')
    $timestampMatch = [regex]::Match($historical, '(?m)^[ \t]+Timestamp time:[ \t]*(?<month>[A-Za-z]{3}) (?<day>\d{1,2}) (?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2}) (?<year>\d{4}) GMT[ \t]*$')
    if (!$digestMatch.Success -or !$timestampMatch.Success) { throw 'Portable alpha.7 historical digest/timestamp observations are malformed' }
    $month = [DateTime]::ParseExact($timestampMatch.Groups['month'].Value, 'MMM', [Globalization.CultureInfo]::InvariantCulture).Month
    $timestampDate = [DateTime]::new([int]$timestampMatch.Groups['year'].Value, $month, [int]$timestampMatch.Groups['day'].Value,
        [int]$timestampMatch.Groups['hour'].Value, [int]$timestampMatch.Groups['minute'].Value, [int]$timestampMatch.Groups['second'].Value,
        [DateTimeKind]::Utc)
    $timestampObserved = $timestampDate.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    return [ordered]@{
        sha256Sums=$script:Alpha7.portableEvidenceSha256Sums; verifiedFileCount=$listed.Count
        historical=@{ msiSha256=$digestMatch.Groups[1].Value.ToLowerInvariant(); timestampUtc=$timestampObserved; signingRootSHA256=$script:Alpha7.signingRootSha256; timestampRootSHA256=$script:Alpha7.timestampRootSha256; digestVerified=($digestMatch.Groups[1].Value -ieq $script:Alpha7.msiSha256); signatureVerified=($historical -match 'Signature verification: ok'); timestampVerified=($historical -match 'Timestamp Server Signature verification: ok' -and $historical -match 'Timestamp Server Signature CRL verification: ok'); signingCrlWarning=$warning; signingCrlWarningPresent=[bool]$warning }
        currentControl='signer-expired-with-timestamp-disabled'; alteredControl='msi-digest-mismatch'
        hashes=@{ historicalLog=$listed['alpha7-historical-verify.log']; currentLog=$listed['alpha7-current-verify.log']; alteredLog=$listed['alpha7-altered-verify.log']; allCrls=$listed['inputs/all-crls.pem']; verifier=$listed['verifier/osslsigncode'] }
        limitation='osslsigncode reports it ignored the expired-leaf CRL validation error; this is qualified portable evidence, not Windows revocation proof'
    }
}

function Assert-Alpha7Asset([string] $Path, [string] $Name, [string] $Hash) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf) -or (Split-Path -Leaf $Path) -cne $Name -or (Get-Alpha7Sha256 $Path) -cne $Hash) {
        throw "Pinned alpha.7 asset identity mismatch: $Name"
    }
}

function Assert-Alpha7NativeAdmissionObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RequestedPackageKind,
        [Parameter(Mandatory)][string] $ObservedMsiSha256,
        [Parameter(Mandatory)][long] $ObservedMsiSize,
        [Parameter(Mandatory)][object] $Diagnostic,
        [Parameter(Mandatory)][object] $Portable,
        [Parameter(Mandatory)][string[]] $SignerEkus
    )
    if ($RequestedPackageKind -cne $script:Alpha7.kind) { throw 'Only the exact alpha.7 historical fixture may request expired-leaf admission' }
    if ($ObservedMsiSha256 -cne $script:Alpha7.msiSha256 -or $ObservedMsiSize -ne $script:Alpha7.msiSize) { throw 'Observed alpha.7 MSI tuple differs from the immutable fixture' }
    if (!$Diagnostic.collectionComplete -or !$Diagnostic.signatureDetailsComplete -or !$Diagnostic.winVerifyTrust) { throw 'Native alpha.7 admission collection is incomplete' }
    $signature = $Diagnostic.signature
    $wvt = $Diagnostic.winVerifyTrust
    $timestampProof = $Diagnostic.rfc3161SigningTime
    if ($signature.status -cne 'UnknownError' -or $signature.statusMessage -notmatch 'expir|validity period' -or
        $signature.signatureType -cne 'Authenticode' -or $signature.signer.thumbprint -cne $script:Alpha7.signerSha1 -or
        (Convert-Alpha7UtcSecondPrecision $signature.signer.notBeforeUtc) -cne $script:Alpha7.signerNotBeforeUtc -or
        (Convert-Alpha7UtcSecondPrecision $signature.signer.notAfterUtc) -cne $script:Alpha7.signerNotAfterUtc -or
        $signature.timestamp.thumbprint -cne $script:Alpha7.timestampSha1 -or
        !$timestampProof -or $timestampProof.signingTimeSource -cne 'rfc3161-tstinfo-genTime' -or
        $timestampProof.signingTimeUtc -cne $script:Alpha7.rfc3161GenTimeUtc -or
        $timestampProof.tokenSignatureVerified -ne $true -or
        $timestampProof.messageImprint.algorithmOid -cne '2.16.840.1.101.3.4.2.1' -or
        $timestampProof.messageImprint.hashedMessage -cne $script:Alpha7.rfc3161MessageImprintSha256 -or
        $wvt.verifyHResultHex -cne '0x800B0101' -or $wvt.stateCloseHResultHex -cne '0x00000000' -or
        $wvt.policy -cne 'WINTRUST_ACTION_GENERIC_VERIFY_V2; WTD_UI_NONE; WTD_REVOKE_NONE; WTD_CHOICE_FILE; dwProvFlags=0') {
        throw 'Native alpha.7 result is not the pinned UnknownError/CERT_E_EXPIRED observation and verifier policy'
    }
    if ($SignerEkus -notcontains $script:Alpha7.lifetimeSigningEku) { throw 'Pinned alpha.7 leaf lacks Lifetime Signing EKU' }
    if ($Portable.sha256Sums -cne $script:Alpha7.portableEvidenceSha256Sums -or
        $Portable.historical.msiSha256 -cne $script:Alpha7.msiSha256 -or
        $Portable.historical.timestampUtc -cne $script:Alpha7.timestampUtc -or
        $Portable.historical.signingRootSHA256 -cne $script:Alpha7.signingRootSha256 -or
        $Portable.historical.timestampRootSHA256 -cne $script:Alpha7.timestampRootSha256 -or
        $Portable.historical.digestVerified -ne $true -or $Portable.historical.signatureVerified -ne $true -or
        $Portable.historical.timestampVerified -ne $true -or $Portable.historical.signingCrlWarningPresent -ne $true) {
        throw 'Pinned independent alpha.7 digest/signature/timestamp/root or disclosed CRL-warning evidence is incomplete'
    }
    return $true
}

function Write-Alpha7AdmissionEvidence([string] $Path, [object] $Value) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 64) + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-Alpha7HistoricalAdmission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $MsiPath,
        [Parameter(Mandatory)][string] $ReleaseApiPath,
        [Parameter(Mandatory)][string] $ValidationPath,
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $TargetsPath,
        [Parameter(Mandatory)][string] $AppArtifactsPath,
        [Parameter(Mandatory)][string] $PortableEvidencePath,
        [Parameter(Mandatory)][string] $EvidencePath,
        [Parameter(Mandatory)][string] $RequestedPackageKind
    )
    if ($RequestedPackageKind -cne $script:Alpha7.kind) { throw 'Candidate or arbitrary package attempted alpha.7 expiry admission' }
    Assert-Alpha7Asset $MsiPath $script:Alpha7.msiName $script:Alpha7.msiSha256
    if ((Get-Item -LiteralPath $MsiPath).Length -ne $script:Alpha7.msiSize) { throw 'Pinned alpha.7 MSI size mismatch' }
    Assert-Alpha7Asset $ReleaseApiPath 'alpha7-release-api.json' $script:Alpha7.releaseApiSha256
    Assert-Alpha7Asset $ValidationPath $script:Alpha7.validationName $script:Alpha7.validationSha256
    Assert-Alpha7Asset $ManifestPath $script:Alpha7.manifestName $script:Alpha7.manifestSha256
    Assert-Alpha7Asset $TargetsPath $script:Alpha7.targetsName $script:Alpha7.targetsSha256
    Assert-Alpha7Asset $AppArtifactsPath $script:Alpha7.appArtifactsName $script:Alpha7.appArtifactsSha256
    $portable = Get-Alpha7PortableEvidence $PortableEvidencePath

    $api = Get-Content -LiteralPath $ReleaseApiPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($api.tag_name -cne $script:Alpha7.tag -or $api.published_at -cne '2026-09-28T17:33:00Z') { throw 'Pinned alpha.7 GitHub release API identity mismatch' }
    $apiAssets = @($api.assets)
    foreach ($asset in @(
        @{ Name=$script:Alpha7.msiName; Hash=$script:Alpha7.msiSha256 },
        @{ Name=$script:Alpha7.validationName; Hash=$script:Alpha7.validationSha256 },
        @{ Name=$script:Alpha7.manifestName; Hash=$script:Alpha7.manifestSha256 },
        @{ Name=$script:Alpha7.targetsName; Hash=$script:Alpha7.targetsSha256 },
        @{ Name=$script:Alpha7.appArtifactsName; Hash=$script:Alpha7.appArtifactsSha256 }
    )) {
        $match = @($apiAssets | Where-Object name -CEQ $asset.Name)
        if ($match.Count -ne 1 -or $match[0].digest -cne "sha256:$($asset.Hash)") { throw "Pinned release API asset digest mismatch: $($asset.Name)" }
    }

    $proof = Get-Content -LiteralPath $ValidationPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($proof.commit -cne $script:Alpha7.sourceCommit -or $proof.workflowRevision -cne $script:Alpha7.sourceCommit -or
        [string]$proof.runId -cne $script:Alpha7.validationRunId -or [string]$proof.runAttempt -cne $script:Alpha7.validationAttempt -or
        $proof.tag -cne $script:Alpha7.tag -or $proof.assetName -cne $script:Alpha7.msiName -or
        $proof.msi.sha256 -cne $script:Alpha7.msiSha256 -or $proof.msi.size -ne $script:Alpha7.msiSize) {
        throw 'Pinned alpha.7 validation proof tuple mismatch'
    }
    if ($proof.signedInputManifest.sha256 -cne $script:Alpha7.manifestSha256 -or
        $proof.targets.sha256 -cne $script:Alpha7.targetsSha256 -or
        $proof.appBuildManifest.sha256 -cne $script:Alpha7.appArtifactsSha256) { throw 'Pinned alpha.7 proof asset hashes mismatch' }
    $appPart = @($proof.peHashes | Where-Object { $_.component -ceq 'app' -and $_.architecture -ceq 'x64' })
    $dllPart = @($proof.peHashes | Where-Object { $_.component -ceq 'interceptor' -and $_.architecture -ceq 'x64' })
    if ($appPart.Count -ne 1 -or $appPart[0].signedSha256 -cne $script:Alpha7.appSha256 -or
        $dllPart.Count -ne 1 -or $dllPart[0].signedSha256 -cne $script:Alpha7.x64DllSha256 -or
        $proof.componentSources.app.commit -cne $script:Alpha7.sourceCommit -or
        $proof.componentSources.interceptor.commit -cne $script:Alpha7.sourceCommit) { throw 'Pinned alpha.7 installed component/source proof mismatch' }
    $proofSigner = @($proof.signatures | Where-Object file -CEQ $script:Alpha7.msiName)
    if ($proofSigner.Count -ne 1 -or $proofSigner[0].status -cne 'Valid' -or
        $proofSigner[0].signerThumbprint -cne $script:Alpha7.signerSha1 -or
        $proofSigner[0].timestampThumbprint -cne $script:Alpha7.timestampSha1 -or
        $proof.testTrust.certificateSha256 -cne $script:Alpha7.signingRootSha256 -or
        $proof.testTrust.thumbprint -cne $script:Alpha7.signingRootSha1) { throw 'Pinned alpha.7 historical signing proof mismatch' }

    $root = Get-Item -LiteralPath "Cert:\LocalMachine\Root\$($script:Alpha7.signingRootSha1)" -ErrorAction Stop
    $rootSha = Get-Alpha7BytesSha256 $root.RawData
    if ($rootSha -cne $script:Alpha7.signingRootSha256) { throw 'Owned TEST signing root bytes differ from the pinned alpha.7 root' }
    $timestampRoots = @((Get-ChildItem Cert:\LocalMachine\Root -ErrorAction Stop) + (Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop) | Where-Object {
        (Get-Alpha7BytesSha256 $_.RawData) -ceq $script:Alpha7.timestampRootSha256
    })
    if ($timestampRoots.Count -lt 1) { throw 'Pinned Microsoft timestamp root is absent from the observed trust stores' }

    Import-Module (Join-Path $PSScriptRoot 'authenticode-diagnostic.psm1') -Force
    Initialize-WinVerifyTrustType
    $observedAt = [DateTime]::UtcNow
    $diagnostic = Get-AuthenticodeDiagnostic -MsiPath $MsiPath -ObservationTimeUtc $observedAt
    $sig = $diagnostic.signature
    $wvt = $diagnostic.winVerifyTrust
    $leaf = Get-AuthenticodeSignature -LiteralPath $MsiPath -ErrorAction Stop | Select-Object -ExpandProperty SignerCertificate
    $leafNotBefore = $leaf.NotBefore.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $leafNotAfter = $leaf.NotAfter.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    if ($leafNotBefore -cne (Convert-Alpha7UtcSecondPrecision $sig.signer.notBeforeUtc) -or
        $leafNotAfter -cne (Convert-Alpha7UtcSecondPrecision $sig.signer.notAfterUtc)) { throw 'Native alpha.7 leaf validity differs from the collected signature detail' }
    $signerChainRoot = @($diagnostic.signerChain.elements | Select-Object -Last 1)
    $timestampChainRoot = @($diagnostic.timestampChain.elements | Select-Object -Last 1)
    $ekuExtension = $leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' } | Select-Object -First 1
    if (!$ekuExtension) { throw 'Pinned alpha.7 leaf has no EKU extension' }
    $eku = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($ekuExtension, $ekuExtension.Critical)
    $ekuValues = @($eku.EnhancedKeyUsages | ForEach-Object Value)
    Assert-Alpha7NativeAdmissionObservation -RequestedPackageKind $RequestedPackageKind -ObservedMsiSha256 $diagnostic.msiSha256 `
        -ObservedMsiSize ([long](Get-Item -LiteralPath $MsiPath).Length) -Diagnostic $diagnostic -Portable $portable -SignerEkus $ekuValues | Out-Null

    $admission = [ordered]@{
        schema = 'go-mapi-alpha7-expired-lifetime-signing-fixture-v1'
        packageKind = $script:Alpha7.kind
        admission = 'legacy-fixture-admitted:expired-lifetime-signing'
        tuple = $script:Alpha7
        checkedAtUtc = $observedAt.ToString('o')
        native = $diagnostic
        signerEkus = @($eku.EnhancedKeyUsages | ForEach-Object Value)
        digestVerified = [bool]$portable.historical.digestVerified
        signatureVerified = [bool]$portable.historical.signatureVerified
        timestampVerified = [bool]$portable.historical.timestampVerified
        embeddedTimestampUtc = $portable.historical.timestampUtc
        portableEvidence = $portable
        signingTimeVerification = @{ method='pinned-osslsigncode-2.9'; timestampUtc=$portable.historical.timestampUtc; verifierSHA256=$portable.hashes.verifier; historicalLogSHA256=$portable.hashes.historicalLog }
        rootInventory = @{ signingStore='LocalMachine/Root'; signingSha256=$rootSha; signingSha1=$script:Alpha7.signingRootSha1; timestampRootSha256=$portable.historical.timestampRootSHA256; timestampStore='LocalMachine-or-CurrentUser/Root' }
        chainRootDiagnostics = @{
            signerReachedPinnedRoot = [bool]($signerChainRoot.Count -eq 1 -and $signerChainRoot[0].certificateSha256 -ceq $script:Alpha7.signingRootSha256)
            timestampReachedPinnedRoot = [bool]($timestampChainRoot.Count -eq 1 -and $timestampChainRoot[0].certificateSha256 -ceq $script:Alpha7.timestampRootSha256)
            interpretation = 'Ancillary observation-time X509Chain only; statuses do not override the native Authenticode admission result.'
        }
        revocationCoverage = 'not-checked-by-native-policy; portable-explicit-time-CRL-warning-retained'
        qualification = 'Historical test fixture only; not current Valid. WinVerifyTrust used WTD_REVOKE_NONE. Ancillary direct X509Chain records are diagnostic only and are retained without turning their status into the Authenticode admission result.'
    }
    Write-Alpha7AdmissionEvidence $EvidencePath $admission
    return [pscustomobject]$admission
}

Export-ModuleMember -Function Get-Alpha7HistoricalAdmission, Assert-Alpha7NativeAdmissionObservation
