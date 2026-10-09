Set-StrictMode -Version Latest

$script:Alpha9Pins = [ordered]@{
    assetName = 'go-mapi-suite-3.2.0-alpha.9-x64.msi'
    proofName = 'suite-3.2.0-alpha.9.validation.json'
    tag = 'suite-v3.2.0-alpha.9'
    sourceCommit = '497798ddb1c243c6ab5c97f6ac1cdf6645b89267'
    runId = '36874061556'
    msiSha256 = '2f8f664d58a33435100db53ab049eef8a438fae8c8465784c0019433fed03f6d'
    msiSize = 12025856
    proofSha256 = '7614a92a7a2c0f47a146af15b144f5b1c7e33883fc99e98d0a1af33b0025a194'
    signerThumbprint = 'EC64449FCB1593C61AEE5DD474D89103A61EBC81'
    timestampThumbprint = '9D64791BDBA7AB705D8EEB6BC275951F512BC45C'
    rootSha256 = '41c1fd9b83c54731c84375c07ec2585b61d032961d9c578c1784fca0e3c59f6e'
    rootThumbprint = 'DFA0E53504EF5328FAEC21AD7DF14C10B07C4FCB'
}

function Get-FileSha256([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-BytesSha256([byte[]] $Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-Alpha9DiagnosticInputs([string] $MsiPath, [string] $ProofPath) {
    foreach ($file in @($MsiPath, $ProofPath)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Pinned alpha.9 input is missing: $file" }
    }
    if ((Split-Path -Leaf $MsiPath) -cne $script:Alpha9Pins.assetName -or
        (Split-Path -Leaf $ProofPath) -cne $script:Alpha9Pins.proofName) {
        throw 'Pinned alpha.9 input names differ from the reviewed package identity'
    }
    if ((Get-Item -LiteralPath $MsiPath).Length -ne $script:Alpha9Pins.msiSize -or
        (Get-FileSha256 $MsiPath) -cne $script:Alpha9Pins.msiSha256) {
        throw 'Pinned alpha.9 MSI bytes differ from the reviewed package identity'
    }
    if ((Get-FileSha256 $ProofPath) -cne $script:Alpha9Pins.proofSha256) {
        throw 'Pinned alpha.9 validation proof bytes differ from the reviewed package identity'
    }
    $proof = Get-Content -LiteralPath $ProofPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($proof.schema -cne 'go-mapi-machine-validation-provenance-v1' -or
        $proof.publishable -ne $true -or $proof.repository -cne 'marcfargas/go-mapi' -or
        $proof.commit -cne $script:Alpha9Pins.sourceCommit -or
        $proof.workflowRevision -cne $script:Alpha9Pins.sourceCommit -or
        $proof.workflow -cne 'Validate machine package' -or
        $proof.sourceRef -cne "refs/tags/$($script:Alpha9Pins.tag)" -or
        $proof.tag -cne $script:Alpha9Pins.tag -or [string]$proof.runId -cne $script:Alpha9Pins.runId -or
        $proof.assetName -cne $script:Alpha9Pins.assetName -or
        $proof.msi.sha256 -cne $script:Alpha9Pins.msiSha256 -or
        $proof.msi.size -ne $script:Alpha9Pins.msiSize -or $proof.msi.signed -ne $true -or
        $proof.testTrust.schema -cne 'go-mapi-azure-test-root-fixture-v1' -or
        $proof.testTrust.certificateSha256 -cne $script:Alpha9Pins.rootSha256 -or
        $proof.testTrust.thumbprint -cne $script:Alpha9Pins.rootThumbprint -or
        $proof.testTrust.store -cne 'LocalMachine/Root' -or
        $proof.testTrust.preexisting -ne $false -or $proof.testTrust.importAttempted -ne $true -or
        $proof.testTrust.imported -ne $true) {
        throw 'Pinned alpha.9 validation proof fields differ from the reviewed package/signing identity'
    }
    $signatures = @($proof.signatures | Where-Object file -ceq $script:Alpha9Pins.assetName)
    if ($signatures.Count -ne 1 -or $signatures[0].status -cne 'Valid' -or
        $signatures[0].signerThumbprint -cne $script:Alpha9Pins.signerThumbprint -or
        $signatures[0].timestampThumbprint -cne $script:Alpha9Pins.timestampThumbprint) {
        throw 'Pinned alpha.9 validation proof does not match the reviewed MSI signer and timestamp'
    }
    return [pscustomobject]@{
        packageTag = $script:Alpha9Pins.tag
        packageSourceCommit = $script:Alpha9Pins.sourceCommit
        validationRunId = $script:Alpha9Pins.runId
        msiSha256 = $script:Alpha9Pins.msiSha256
        proofSha256 = $script:Alpha9Pins.proofSha256
        signerThumbprint = $script:Alpha9Pins.signerThumbprint
        timestampThumbprint = $script:Alpha9Pins.timestampThumbprint
        pinnedTestRootSha256 = $script:Alpha9Pins.rootSha256
        pinnedTestRootThumbprint = $script:Alpha9Pins.rootThumbprint
        publisherImmutableFlag = $false
        pinningNote = 'Exact owner-pinned bytes; the GitHub release API does not mark this release immutable.'
    }
}

function Get-ExceptionEvidence([System.Exception] $Exception) {
    if (-not $Exception) { return $null }
    return [pscustomobject]@{
        type = $Exception.GetType().FullName
        message = $Exception.Message
        hresult = ('0x{0:X8}' -f [int32]$Exception.HResult)
    }
}

function Test-RequiredTrustObservationComplete([object] $Diagnostic, [object] $RootInventoryException) {
    return [bool]($null -ne $Diagnostic -and $Diagnostic.collectionComplete -and $null -eq $RootInventoryException)
}

function Write-AuthenticodeEvidenceFallback([object] $Record) {
    $json = ConvertTo-Json -InputObject $Record -Depth 64 -Compress
    [Console]::Error.WriteLine("TICKET569_AUTHENTICODE_EVIDENCE_FALLBACK=$json")
}

function Invoke-OwnedTrustDiagnosticLifecycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock] $Prepare,
        [Parameter(Mandatory)][scriptblock] $ReadOwnedState,
        [Parameter(Mandatory)][scriptblock] $Observe,
        [Parameter(Mandatory)][scriptblock] $Cleanup,
        [Parameter(Mandatory)][scriptblock] $WriteEvidence
    )
    $result = [ordered]@{
        schema = 'go-mapi-authenticode-diagnostic-v1'
        verdict = 'diagnostic-only-no-capability-conclusion'
        preparationException = $null
        ownedTrustState = $null
        preparationComplete = $false
        observation = $null
        observationException = $null
        cleanup = $null
        cleanupException = $null
        evidenceWriteException = $null
        collectionComplete = $false
    }
    $state = $null
    try {
        try { & $Prepare }
        catch { $result.preparationException = Get-ExceptionEvidence $_.Exception }

        $state = & $ReadOwnedState
        if ($null -eq $state) { throw 'Owned trust state is missing; no cleanup ownership can be proved' }
        $result.ownedTrustState = $state
        $result.preparationComplete = (-not [bool]$state.importAttempted -or [bool]$state.imported)
        $result.observation = & $Observe $state
        if ($result.observation -and $result.observation.PSObject.Properties['collectionComplete'] -and
            -not $result.observation.collectionComplete) {
            $result.observationException = [pscustomobject]@{
                type = 'DiagnosticObservationIncomplete'
                message = 'One or more required signature observations could not be collected.'
                hresult = $null
            }
        }
    } catch {
        $result.observationException = Get-ExceptionEvidence $_.Exception
    } finally {
        if ($null -eq $state) {
            $result.cleanupException = [pscustomobject]@{
                type = 'OwnedTrustStateMissing'
                message = 'Owned trust state is missing; cleanup is unproven and no certificate was removed.'
                hresult = $null
            }
        } else {
            try { $result.cleanup = & $Cleanup $state }
            catch { $result.cleanupException = Get-ExceptionEvidence $_.Exception }
        }
        $result.collectionComplete = ($null -eq $result.observationException -and
            $null -eq $result.cleanupException -and $null -eq $result.evidenceWriteException -and
            $result.preparationComplete -and $null -ne $result.observation -and $null -ne $result.cleanup)
        try { & $WriteEvidence ([pscustomobject]$result) }
        catch {
            $result.evidenceWriteException = Get-ExceptionEvidence $_.Exception
            $result.collectionComplete = $false
            $result.verdict = 'diagnostic-evidence-write-failed'
            try { Write-AuthenticodeEvidenceFallback -Record ([pscustomobject]$result) } catch { }
        }
    }
    return [pscustomobject]$result
}

function Get-ChainDiagnostic([System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
    [DateTime] $VerificationTimeUtc, [string] $CertificateRole) {
    $evidence = [ordered]@{
        role = $CertificateRole
        diagnosticOnly = $true
        verificationTimeUtc = $VerificationTimeUtc.ToUniversalTime().ToString('o')
        verificationPolicy = 'X509Chain, RevocationMode=NoCheck, RevocationFlag=ExcludeRoot, VerificationFlags=NoFlag'
        certificate = $null
        buildSucceeded = $null
        chainStatus = @()
        elements = @()
        exception = $null
    }
    if (-not $Certificate) { return [pscustomobject]$evidence }
    $evidence.certificate = [pscustomobject]@{
        subject = $Certificate.Subject
        issuer = $Certificate.Issuer
        thumbprint = $Certificate.Thumbprint
        notBeforeUtc = $Certificate.NotBefore.ToUniversalTime().ToString('o')
        notAfterUtc = $Certificate.NotAfter.ToUniversalTime().ToString('o')
    }
    $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $policy = $chain.ChainPolicy
        $policy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $policy.RevocationFlag = [System.Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
        $policy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
        $policy.VerificationTime = $VerificationTimeUtc.ToUniversalTime()
        $evidence.buildSucceeded = $chain.Build($Certificate)
        $evidence.chainStatus = @($chain.ChainStatus | ForEach-Object {
            [pscustomobject]@{ status = $_.Status.ToString(); information = $_.StatusInformation.Trim() }
        })
        $evidence.elements = @($chain.ChainElements | ForEach-Object {
            [pscustomobject]@{
                subject = $_.Certificate.Subject
                issuer = $_.Certificate.Issuer
                thumbprint = $_.Certificate.Thumbprint
                certificateSha256 = Get-BytesSha256 $_.Certificate.RawData
                notBeforeUtc = $_.Certificate.NotBefore.ToUniversalTime().ToString('o')
                notAfterUtc = $_.Certificate.NotAfter.ToUniversalTime().ToString('o')
                status = @($_.ChainElementStatus | ForEach-Object {
                    [pscustomobject]@{ name = $_.Status.ToString(); information = $_.StatusInformation.Trim() }
                })
            }
        })
    } catch {
        $evidence.exception = Get-ExceptionEvidence $_.Exception
    } finally { $chain.Dispose() }
    return [pscustomobject]$evidence
}

function Test-ChainDiagnosticCollected([object] $Chain) {
    if ($null -eq $Chain) { return $false }
    foreach ($property in @('exception', 'buildSucceeded', 'chainStatus', 'elements')) {
        if (-not $Chain.PSObject.Properties[$property]) { return $false }
    }
    return ($null -eq $Chain.exception -and $null -ne $Chain.buildSucceeded)
}

function Get-AuthenticodeDiagnostic([string] $MsiPath, [DateTime] $ObservationTimeUtc) {
    Import-Module (Join-Path $PSScriptRoot 'authenticode-rfc3161.psm1') -Force
    $result = [ordered]@{
        observationTimeUtc = $ObservationTimeUtc.ToUniversalTime().ToString('o')
        msiPath = $MsiPath
        msiSha256 = Get-FileSha256 $MsiPath
        signature = $null
        signatureDetailsComplete = $false
        signatureException = $null
        rfc3161SigningTime = $null
        rfc3161Exception = $null
        winVerifyTrust = $null
        winVerifyTrustException = $null
        collectionComplete = $false
        chainInterpretation = 'Direct signer and timestamp X509Chain results both use the recorded observation time, not the Authenticode signing time, and are diagnostics only. Expired current-time leaf-chain output does not establish Authenticode invalidity when a trusted timestamp may apply.'
    }
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $MsiPath -ErrorAction Stop
        $result.signature = [pscustomobject]@{
            status = $signature.Status.ToString()
            statusMessage = [string]$signature.StatusMessage
            signatureType = [string]$signature.SignatureType
            isOSBinary = [bool]$signature.IsOSBinary
            signingTimeUtc = $null
            signingTimeSource = $null
            signer = if ($signature.SignerCertificate) {
                [pscustomobject]@{ subject = $signature.SignerCertificate.Subject; issuer = $signature.SignerCertificate.Issuer; thumbprint = $signature.SignerCertificate.Thumbprint; notBeforeUtc = $signature.SignerCertificate.NotBefore.ToUniversalTime().ToString('o'); notAfterUtc = $signature.SignerCertificate.NotAfter.ToUniversalTime().ToString('o') }
            } else { $null }
            timestamp = if ($signature.TimeStamperCertificate) {
                [pscustomobject]@{ subject = $signature.TimeStamperCertificate.Subject; issuer = $signature.TimeStamperCertificate.Issuer; thumbprint = $signature.TimeStamperCertificate.Thumbprint; notBeforeUtc = $signature.TimeStamperCertificate.NotBefore.ToUniversalTime().ToString('o'); notAfterUtc = $signature.TimeStamperCertificate.NotAfter.ToUniversalTime().ToString('o') }
            } else { $null }
        }
        $result.signatureDetailsComplete = ($null -ne $signature.SignerCertificate -and $null -ne $signature.TimeStamperCertificate)
        $result.signerChain = Get-ChainDiagnostic $signature.SignerCertificate $ObservationTimeUtc 'signer'
        $result.timestampChain = Get-ChainDiagnostic $signature.TimeStamperCertificate $ObservationTimeUtc 'timestamp'
        if ($result.signatureDetailsComplete) {
            try {
                $result.rfc3161SigningTime = Get-AuthenticodeRfc3161Observation -MsiPath $MsiPath `
                    -SignerCertificate $signature.SignerCertificate -TimestampCertificate $signature.TimeStamperCertificate `
                    -CheckedAtUtc $ObservationTimeUtc
                $result.signature.signingTimeUtc = $result.rfc3161SigningTime.signingTimeUtc
                $result.signature.signingTimeSource = $result.rfc3161SigningTime.signingTimeSource
            } catch { $result.rfc3161Exception = Get-ExceptionEvidence $_.Exception }
        }
    } catch { $result.signatureException = Get-ExceptionEvidence $_.Exception }

    try { $result.winVerifyTrust = [Ticket569WinVerifyTrust]::Verify($MsiPath) }
    catch { $result.winVerifyTrustException = Get-ExceptionEvidence $_.Exception }
    $result.collectionComplete = ($null -ne $result.signature -and $result.signatureDetailsComplete -and $null -ne $result.winVerifyTrust -and
        $null -eq $result.signatureException -and $null -eq $result.winVerifyTrustException -and
        $null -eq $result.rfc3161Exception -and
        (Test-ChainDiagnosticCollected $result.signerChain) -and
        (Test-ChainDiagnosticCollected $result.timestampChain))
    return [pscustomobject]$result
}

function Initialize-WinVerifyTrustType {
    if ('Ticket569WinVerifyTrust' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct Ticket569WinTrustFileInfo {
    public UInt32 cbStruct;
    public IntPtr pcwszFilePath;
    public IntPtr hFile;
    public IntPtr pgKnownSubject;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct Ticket569WinTrustData {
    public UInt32 cbStruct;
    public IntPtr pPolicyCallbackData;
    public IntPtr pSIPClientData;
    public UInt32 dwUIChoice;
    public UInt32 fdwRevocationChecks;
    public UInt32 dwUnionChoice;
    public IntPtr pFile;
    public UInt32 dwStateAction;
    public IntPtr hWVTStateData;
    public IntPtr pwszURLReference;
    public UInt32 dwProvFlags;
    public UInt32 dwUIContext;
}

public static class Ticket569WinVerifyTrust {
    const UInt32 WTD_UI_NONE = 2;
    const UInt32 WTD_REVOKE_NONE = 0;
    const UInt32 WTD_CHOICE_FILE = 1;
    const UInt32 WTD_STATEACTION_VERIFY = 1;
    const UInt32 WTD_STATEACTION_CLOSE = 2;
    static readonly Guid WINTRUST_ACTION_GENERIC_VERIFY_V2 = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");

    [DllImport("wintrust.dll", ExactSpelling = true, PreserveSig = true, CharSet = CharSet.Unicode)]
    static extern Int32 WinVerifyTrust(IntPtr hwnd, ref Guid actionId, ref Ticket569WinTrustData data);

    public static object Verify(string path) {
        IntPtr filePath = IntPtr.Zero;
        IntPtr fileInfoPtr = IntPtr.Zero;
        Ticket569WinTrustData data = new Ticket569WinTrustData();
        Int32 verifyHr = unchecked((Int32)0x80004005);
        Int32 closeHr = unchecked((Int32)0x80004005);
        bool verifyCalled = false;
        try {
            filePath = Marshal.StringToCoTaskMemUni(path);
            Ticket569WinTrustFileInfo fileInfo = new Ticket569WinTrustFileInfo();
            fileInfo.cbStruct = (UInt32)Marshal.SizeOf(typeof(Ticket569WinTrustFileInfo));
            fileInfo.pcwszFilePath = filePath;
            fileInfoPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Ticket569WinTrustFileInfo)));
            Marshal.StructureToPtr(fileInfo, fileInfoPtr, false);
            data.cbStruct = (UInt32)Marshal.SizeOf(typeof(Ticket569WinTrustData));
            data.dwUIChoice = WTD_UI_NONE;
            data.fdwRevocationChecks = WTD_REVOKE_NONE;
            data.dwUnionChoice = WTD_CHOICE_FILE;
            data.pFile = fileInfoPtr;
            data.dwStateAction = WTD_STATEACTION_VERIFY;
            Guid action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
            verifyHr = WinVerifyTrust(IntPtr.Zero, ref action, ref data);
            verifyCalled = true;
        } finally {
            if (verifyCalled) {
                data.dwStateAction = WTD_STATEACTION_CLOSE;
                Guid action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
                closeHr = WinVerifyTrust(IntPtr.Zero, ref action, ref data);
            }
            if (fileInfoPtr != IntPtr.Zero) Marshal.FreeHGlobal(fileInfoPtr);
            if (filePath != IntPtr.Zero) Marshal.FreeCoTaskMem(filePath);
        }
        return new {
            policy = "WINTRUST_ACTION_GENERIC_VERIFY_V2; WTD_UI_NONE; WTD_REVOKE_NONE; WTD_CHOICE_FILE; dwProvFlags=0",
            verifyHResult = verifyHr,
            verifyHResultHex = "0x" + unchecked((UInt32)verifyHr).ToString("X8"),
            stateCloseHResult = closeHr,
            stateCloseHResultHex = "0x" + unchecked((UInt32)closeHr).ToString("X8")
        };
    }
}
'@ -ErrorAction Stop | Out-Null
}

function Write-AtomicJson([string] $Path, [object] $Value) {
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

Export-ModuleMember -Function Assert-Alpha9DiagnosticInputs, Invoke-OwnedTrustDiagnosticLifecycle, Get-AuthenticodeDiagnostic, Initialize-WinVerifyTrustType, Test-RequiredTrustObservationComplete, Write-AuthenticodeEvidenceFallback, Write-AtomicJson
