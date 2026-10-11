$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'alpha7-baseline.psm1') -Force

function New-AdmissionFixture {
    $pins = @{
        sha256Sums='05105cbe4d66db00be45231eadea0ffef256651c7579b7493dd1137cff1ea488'
        historical=@{
            msiSha256='bcf00f8511b8f076582ff06f9ecb00a67aa9476dd3cbdebc5f6b975f4ec94a68'
            timestampUtc='2026-09-28T17:32:29Z'
            signingRootSHA256='41c1fd9b83c54731c84375c07ec2585b61d032961d9c578c1784fca0e3c59f6e'
            timestampRootSHA256='5367f20c7ade0e2bca790915056d086b720c33c1fa2a2661acf787e3292e1270'
            digestVerified=$true; signatureVerified=$true; timestampVerified=$true; signingCrlWarningPresent=$true
        }
    }
    $diagnostic = @{
        collectionComplete=$true; signatureDetailsComplete=$true
        rfc3161SigningTime=@{ signingTimeUtc='2026-09-28T17:32:29.4750000Z'; signingTimeSource='rfc3161-tstinfo-genTime'; messageImprint=@{ algorithmOid='2.16.840.1.101.3.4.2.1'; hashedMessage='6642489753c751c14ceae5961828d0db45f38c22c23eed7ab264c258b811c885' }; tokenSignatureVerified=$true }
        signature=@{
            status='UnknownError'; statusMessage='A certificate chain processed, but terminated in a root certificate which is not trusted by the trust provider. A required certificate is not within its validity period.'
            signatureType='Authenticode'
            signer=@{ thumbprint='076F98CC1928F8F8604B4A384A6BA27FA884F920'; notBeforeUtc='2026-09-27T10:11:51.0000000Z'; notAfterUtc='2026-09-30T10:11:51.0000000Z' }
            timestamp=@{ thumbprint='9D64791BDBA7AB705D8EEB6BC275951F512BC45C' }
        }
        winVerifyTrust=@{ verifyHResultHex='0x800B0101'; stateCloseHResultHex='0x00000000'; policy='WINTRUST_ACTION_GENERIC_VERIFY_V2; WTD_UI_NONE; WTD_REVOKE_NONE; WTD_CHOICE_FILE; dwProvFlags=0' }
        signerChain=@{ diagnosticOnly=$true; chainStatus=@('NotSignatureValid') }
    }
    return @{ portable=$pins; diagnostic=$diagnostic; hash='bcf00f8511b8f076582ff06f9ecb00a67aa9476dd3cbdebc5f6b975f4ec94a68'; size=12021760 }
}

function Assert-Admitted($Fixture) {
    Assert-Alpha7NativeAdmissionObservation -RequestedPackageKind 'exact-alpha7-historical-fixture' `
        -ObservedMsiSha256 $Fixture.hash -ObservedMsiSize $Fixture.size -Diagnostic $Fixture.diagnostic `
        -Portable $Fixture.portable -SignerEkus @('1.3.6.1.4.1.311.10.3.13') | Out-Null
}

Assert-Admitted (New-AdmissionFixture)

$rejections = @(
    { param($f) $f.diagnostic.collectionComplete=$false },
    { param($f) $f.diagnostic.signature.status='Valid' },
    { param($f) $f.diagnostic.signature.signer.thumbprint='FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF' },
    { param($f) $f.diagnostic.signature.timestamp.thumbprint='FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF' },
    { param($f) $f.diagnostic.winVerifyTrust.verifyHResultHex='0x800B0001' },
    { param($f) $f.diagnostic.winVerifyTrust.policy='different policy' },
    { param($f) $f.diagnostic.rfc3161SigningTime.messageImprint.hashedMessage='wrong' },
    { param($f) $f.diagnostic.rfc3161SigningTime.signingTimeUtc='2026-09-29T17:32:29.4750000Z' },
    { param($f) $f.diagnostic.rfc3161SigningTime.tokenSignatureVerified=$false },
    { param($f) $f.portable.historical.digestVerified=$false },
    { param($f) $f.portable.historical.signatureVerified=$false },
    { param($f) $f.portable.historical.timestampVerified=$false },
    { param($f) $f.portable.historical.signingCrlWarningPresent=$false },
    { param($f) $f.portable.historical.timestampRootSHA256='wrong' }
)
foreach ($mutate in $rejections) {
    $fixture = New-AdmissionFixture
    & $mutate $fixture
    try { Assert-Admitted $fixture; throw 'Expected alpha.7 admission fault to reject' }
    catch { if ($_.Exception.Message -eq 'Expected alpha.7 admission fault to reject') { throw } }
}

foreach ($kind in @('candidate','other-fixture')) {
    $fixture = New-AdmissionFixture
    try {
        Assert-Alpha7NativeAdmissionObservation -RequestedPackageKind $kind -ObservedMsiSha256 $fixture.hash `
            -ObservedMsiSize $fixture.size -Diagnostic $fixture.diagnostic -Portable $fixture.portable `
            -SignerEkus @('1.3.6.1.4.1.311.10.3.13') | Out-Null
        throw "Expected package kind $kind to reject"
    } catch { if ($_.Exception.Message -eq "Expected package kind $kind to reject") { throw } }
}

$fixture = New-AdmissionFixture
foreach ($args in @(
    @{ Hash='0000000000000000000000000000000000000000000000000000000000000000'; Size=$fixture.size },
    @{ Hash=$fixture.hash; Size=12021759 }
)) {
    try {
        Assert-Alpha7NativeAdmissionObservation -RequestedPackageKind 'exact-alpha7-historical-fixture' `
            -ObservedMsiSha256 $args.Hash -ObservedMsiSize $args.Size -Diagnostic $fixture.diagnostic `
            -Portable $fixture.portable -SignerEkus @('1.3.6.1.4.1.311.10.3.13') | Out-Null
        throw 'Expected alpha.7 MSI tuple fault to reject'
    } catch { if ($_.Exception.Message -eq 'Expected alpha.7 MSI tuple fault to reject') { throw } }
}

try {
    Assert-Alpha7NativeAdmissionObservation -RequestedPackageKind 'exact-alpha7-historical-fixture' `
        -ObservedMsiSha256 $fixture.hash -ObservedMsiSize $fixture.size -Diagnostic $fixture.diagnostic `
        -Portable $fixture.portable -SignerEkus @('1.2.3') | Out-Null
    throw 'Expected missing Lifetime Signing EKU to reject'
} catch { if ($_.Exception.Message -eq 'Expected missing Lifetime Signing EKU to reject') { throw } }

Write-Output 'ALPHA7_ADMISSION_TESTS_PASSED'
