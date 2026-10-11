[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $MsiPath,
    [Parameter(Mandatory)][string] $ExpectedMsiSHA256,
    [Parameter(Mandatory)][ValidateSet('install', 'install-complete', 'fixed-vhd-run', 'fixed-normal-run', 'completion')][string] $Phase,
    [Parameter(Mandatory)][string] $EvidencePath
)

$ErrorActionPreference = 'Stop'
$checkedAt = [DateTime]::UtcNow
$record = [ordered]@{
    schema = 'go-mapi-candidate-current-signature-v1'
    phase = $Phase
    checkedAtUtc = $checkedAt.ToString('o')
    msiPath = $MsiPath
    expectedMsiSha256 = $ExpectedMsiSHA256.ToLowerInvariant()
    msiSha256 = $null
    authenticodeStatus = $null
    authenticodeMessage = $null
    signatureType = $null
    signerSHA1 = $null
    signerSubject = $null
    signerNotBeforeUtc = $null
    signerNotAfterUtc = $null
    signerEkus = @()
    timestampSHA1 = $null
    timestampSubject = $null
    winVerifyTrustHResult = $null
    winVerifyTrustCloseHResult = $null
    winVerifyTrustPolicy = $null
    pinnedTestRoot = $null
    signerChainRoot = $null
    timestampChainRoot = $null
    verifier = @{ powerShell=$PSVersionTable.PSVersion.ToString(); clr=[Environment]::Version.ToString(); osVersion=[Environment]::OSVersion.VersionString }
    signingTimeUtc = $null
    signingTimeSource = $null
    diagnostic = $null
    revocationCoverage = 'WTD_REVOKE_NONE; candidate also requires the existing publication and signing-proof checks'
    verdict = 'unknown'
    error = $null
}

function Write-Atomic([string] $Path, $Value) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

try {
    if ($ExpectedMsiSHA256 -notmatch '^[0-9a-fA-F]{64}$' -or !(Test-Path -LiteralPath $MsiPath -PathType Leaf)) { throw 'Candidate MSI path/hash identity is invalid' }
    $record.msiSha256 = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($record.msiSha256 -cne $ExpectedMsiSHA256.ToLowerInvariant()) { throw 'Candidate MSI bytes differ from the fixed candidate hash' }

    Import-Module (Join-Path $PSScriptRoot 'authenticode-diagnostic.psm1') -Force
    Initialize-WinVerifyTrustType
    $signature = Get-AuthenticodeSignature -LiteralPath $MsiPath -ErrorAction Stop
    $wvt = [Ticket569WinVerifyTrust]::Verify($MsiPath)
    $pinnedRootHash = '41c1fd9b83c54731c84375c07ec2585b61d032961d9c578c1784fca0e3c59f6e'
    $pinnedRoots = @(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction Stop | Where-Object {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { ([BitConverter]::ToString($sha.ComputeHash($_.RawData))).Replace('-','').ToLowerInvariant() -ceq $pinnedRootHash }
        finally { $sha.Dispose() }
    })
    if ($pinnedRoots.Count -ne 1) { throw 'Candidate current-valid check requires the one pinned Azure TEST root in LocalMachine Root' }
    $record.pinnedTestRoot = @{ subject=$pinnedRoots[0].Subject; thumbprint=$pinnedRoots[0].Thumbprint; sha256=$pinnedRootHash; store='LocalMachine/Root' }
    $record.diagnostic = Get-AuthenticodeDiagnostic -MsiPath $MsiPath -ObservationTimeUtc $checkedAt
    $record.signerChainRoot = @($record.diagnostic.signerChain.elements | Select-Object -Last 1)
    $record.timestampChainRoot = @($record.diagnostic.timestampChain.elements | Select-Object -Last 1)
    if ($record.signerChainRoot.Count -ne 1 -or $record.signerChainRoot[0].certificateSha256 -cne $pinnedRootHash) {
        throw 'Candidate signer chain does not terminate at the pinned Azure TEST root'
    }
    $record.authenticodeStatus = $signature.Status.ToString()
    $record.authenticodeMessage = [string]$signature.StatusMessage
    $record.signatureType = $signature.SignatureType.ToString()
    $record.signerSHA1 = if ($signature.SignerCertificate) { $signature.SignerCertificate.Thumbprint.ToUpperInvariant() } else { $null }
    $record.signerSubject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
    $record.signerNotBeforeUtc = if ($signature.SignerCertificate) { $signature.SignerCertificate.NotBefore.ToUniversalTime().ToString('o') } else { $null }
    $record.signerNotAfterUtc = if ($signature.SignerCertificate) { $signature.SignerCertificate.NotAfter.ToUniversalTime().ToString('o') } else { $null }
    $record.timestampSHA1 = if ($signature.TimeStamperCertificate) { $signature.TimeStamperCertificate.Thumbprint.ToUpperInvariant() } else { $null }
    $record.timestampSubject = if ($signature.TimeStamperCertificate) { $signature.TimeStamperCertificate.Subject } else { $null }
    $record.winVerifyTrustHResult = $wvt.verifyHResultHex
    $record.winVerifyTrustCloseHResult = $wvt.stateCloseHResultHex
    $record.winVerifyTrustPolicy = $wvt.policy
    if ($signature.SignerCertificate) {
        $extension = $signature.SignerCertificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' } | Select-Object -First 1
        if ($extension) {
            $enhanced = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($extension, $extension.Critical)
            $record.signerEkus = @($enhanced.EnhancedKeyUsages | ForEach-Object Value)
        }
    }
    if (-not $record.diagnostic.rfc3161SigningTime -or $record.diagnostic.rfc3161SigningTime.signingTimeSource -cne 'rfc3161-tstinfo-genTime') {
        throw 'Candidate validity requires a parsed, token-verified RFC3161 TSTInfo genTime bound to the outer signer digest'
    }
    $record.signingTimeUtc = $record.diagnostic.rfc3161SigningTime.signingTimeUtc
    $record.signingTimeSource = $record.diagnostic.rfc3161SigningTime.signingTimeSource
    $record.signingTimeMessageImprint = $record.diagnostic.rfc3161SigningTime.messageImprint
    if ($record.authenticodeStatus -ne 'Valid' -or $record.signatureType -ne 'Authenticode' -or
        !$signature.SignerCertificate -or !$signature.TimeStamperCertificate -or
        $record.winVerifyTrustHResult -cne '0x00000000' -or $record.winVerifyTrustCloseHResult -cne '0x00000000' -or
        $checkedAt -ge $signature.SignerCertificate.NotAfter.ToUniversalTime()) {
        throw 'Candidate is not currently Valid under native Authenticode and WinVerifyTrust or its signer window expired'
    }
    $record.verdict = 'candidate-current-valid'
} catch {
    $record.error = @{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message; hresult=('0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$_.Exception.HResult),0)) }
}

try { Write-Atomic $EvidencePath $record }
catch { Write-Error "Could not write candidate validity evidence: $($_.Exception.Message)"; exit 2 }
if ($record.verdict -ne 'candidate-current-valid') { exit 1 }
exit 0
