Set-StrictMode -Version Latest

function Initialize-AuthenticodeRfc3161Type {
    if ('Ticket569Rfc3161Cms' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class Ticket569Rfc3161Cms {
 [DllImport("crypt32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 static extern bool CryptQueryObject(uint objectType, string objectPath, uint contentFlags, uint formatFlags, uint flags,
   out uint encoding, out uint contentType, out uint formatType, out IntPtr certStore, out IntPtr message, out IntPtr context);
 [DllImport("crypt32.dll", SetLastError=true)]
 static extern bool CryptMsgGetParam(IntPtr message, uint parameter, uint index, byte[] data, ref uint size);
 [DllImport("crypt32.dll", SetLastError=true)] static extern bool CryptMsgClose(IntPtr message);
 [DllImport("crypt32.dll", SetLastError=true)] static extern bool CertCloseStore(IntPtr store, uint flags);
 public static byte[] ReadEmbeddedSignedMessage(string path) {
   uint encoding, content, format; IntPtr store, message, context;
   // CERT_QUERY_OBJECT_FILE=1; PKCS7_SIGNED_EMBED content flag=1<<10; binary format flag=1<<1.
   if (!CryptQueryObject(1, path, 0x00000400, 0x00000002, 0, out encoding, out content, out format, out store, out message, out context))
     throw new Win32Exception(Marshal.GetLastWin32Error(), "CryptQueryObject did not find an embedded PKCS#7 signature through the MSI SIP");
   try {
     uint size=0;
     if (!CryptMsgGetParam(message, 29, 0, null, ref size) || size == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "CryptMsgGetParam could not size the encoded MSI signature");
     byte[] encoded = new byte[checked((int)size)];
     if (!CryptMsgGetParam(message, 29, 0, encoded, ref size)) throw new Win32Exception(Marshal.GetLastWin32Error(), "CryptMsgGetParam could not read the encoded MSI signature");
     if (size != encoded.Length) Array.Resize(ref encoded, checked((int)size));
     return encoded;
   } finally {
     if (message != IntPtr.Zero) CryptMsgClose(message);
     if (store != IntPtr.Zero) CertCloseStore(store, 0);
   }
 }
 public static byte[] ReadEmbeddedEncryptedDigest(string path) {
   uint encoding, content, format; IntPtr store, message, context;
   if (!CryptQueryObject(1, path, 0x00000400, 0x00000002, 0, out encoding, out content, out format, out store, out message, out context))
     throw new Win32Exception(Marshal.GetLastWin32Error(), "CryptQueryObject did not find an embedded PKCS#7 signature through the MSI SIP");
   try {
     uint size=0;
     // CMSG_ENCRYPTED_DIGEST=27; signer index zero is the sole required outer signer.
     if (!CryptMsgGetParam(message, 27, 0, null, ref size) || size == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "CryptMsgGetParam could not size the outer signer encrypted digest");
     byte[] digest = new byte[checked((int)size)];
     if (!CryptMsgGetParam(message, 27, 0, digest, ref size)) throw new Win32Exception(Marshal.GetLastWin32Error(), "CryptMsgGetParam could not read the outer signer encrypted digest");
     if (size != digest.Length) Array.Resize(ref digest, checked((int)size));
     return digest;
   } finally {
     if (message != IntPtr.Zero) CryptMsgClose(message);
     if (store != IntPtr.Zero) CertCloseStore(store, 0);
   }
 }
}
'@ -ErrorAction Stop
}

function Read-Rfc3161DerElement([byte[]] $Bytes, [ref] $Offset, [int] $Limit) {
    $start = [int]$Offset.Value
    if ($start -ge $Limit) { throw 'RFC3161 DER element is truncated' }
    $tag = [int]$Bytes[$start]; $Offset.Value = $start + 1
    if (($tag -band 0x1f) -eq 0x1f) { throw 'RFC3161 DER high-tag-number form is unsupported' }
    if ($Offset.Value -ge $Limit) { throw 'RFC3161 DER length is truncated' }
    $first = [int]$Bytes[$Offset.Value]; $Offset.Value++
    if ($first -lt 0x80) { $length = $first }
    else {
        $octets = $first -band 0x7f
        if ($octets -lt 1 -or $octets -gt 4 -or ($Offset.Value + $octets) -gt $Limit) { throw 'RFC3161 DER length encoding is invalid' }
        if ($Bytes[$Offset.Value] -eq 0) { throw 'RFC3161 DER length is not minimally encoded' }
        $length = 0
        for ($index = 0; $index -lt $octets; $index++) { $length = ($length * 256) + [int]$Bytes[$Offset.Value]; $Offset.Value++ }
        if ($length -lt 0x80) { throw 'RFC3161 DER length is not minimally encoded' }
    }
    $valueStart = [int]$Offset.Value; $end = $valueStart + $length
    if ($end -gt $Limit) { throw 'RFC3161 DER value exceeds its container' }
    $value = if ($length) { [byte[]]$Bytes[$valueStart..($end - 1)] } else { [byte[]]@() }
    $Offset.Value = $end
    return [pscustomobject]@{ tag=$tag; value=$value; end=$end; start=$start }
}

function ConvertFrom-Rfc3161Oid([byte[]] $Bytes) {
    if (!$Bytes -or $Bytes.Length -eq 0) { throw 'RFC3161 OID is empty' }
    $values = [Collections.Generic.List[long]]::new()
    $current = [long]0; $firstValue = $null
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        $byte = [int]$Bytes[$index]
        if ($current -eq 0 -and $byte -eq 0x80) { throw 'RFC3161 OID component is not minimally encoded' }
        $current = ($current * 128) + ($byte -band 0x7f)
        if ($current -gt [long]::MaxValue / 128) { throw 'RFC3161 OID component overflows' }
        if (($byte -band 0x80) -eq 0) {
            if ($null -eq $firstValue) {
                if ($current -lt 40) { $values.Add(0); $values.Add($current) }
                elseif ($current -lt 80) { $values.Add(1); $values.Add($current - 40) }
                else { $values.Add(2); $values.Add($current - 80) }
                $firstValue = $true
            } else { $values.Add($current) }
            $current = 0
        }
    }
    if (($Bytes[-1] -band 0x80) -ne 0) { throw 'RFC3161 OID has an unterminated component' }
    return ($values -join '.')
}

function Get-Rfc3161TstInfo([byte[]] $Content) {
    $offset = 0
    $root = Read-Rfc3161DerElement $Content ([ref]$offset) $Content.Length
    if ($root.tag -ne 0x30 -or $offset -ne $Content.Length) { throw 'RFC3161 TSTInfo must be one complete DER SEQUENCE' }
    $cursor = 0; $limit = $root.value.Length
    $version = Read-Rfc3161DerElement $root.value ([ref]$cursor) $limit
    if ($version.tag -ne 0x02 -or @($version.value).Count -ne 1 -or $version.value[0] -ne 1) { throw 'RFC3161 TSTInfo version is not 1' }
    $policy = Read-Rfc3161DerElement $root.value ([ref]$cursor) $limit
    if ($policy.tag -ne 0x06) { throw 'RFC3161 TSTInfo policy OID is missing' }
    $policyOid = ConvertFrom-Rfc3161Oid $policy.value
    $imprint = Read-Rfc3161DerElement $root.value ([ref]$cursor) $limit
    if ($imprint.tag -ne 0x30) { throw 'RFC3161 TSTInfo messageImprint is missing' }
    $imprintOffset = 0; $imprintLimit = $imprint.value.Length
    $algorithm = Read-Rfc3161DerElement $imprint.value ([ref]$imprintOffset) $imprintLimit
    if ($algorithm.tag -ne 0x30) { throw 'RFC3161 messageImprint AlgorithmIdentifier is malformed' }
    $algorithmOffset = 0; $algorithmLimit = $algorithm.value.Length
    $algorithmOidElement = Read-Rfc3161DerElement $algorithm.value ([ref]$algorithmOffset) $algorithmLimit
    if ($algorithmOidElement.tag -ne 0x06) { throw 'RFC3161 messageImprint hash algorithm OID is missing' }
    $algorithmOid = ConvertFrom-Rfc3161Oid $algorithmOidElement.value
    if ($algorithmOffset -lt $algorithmLimit) {
        $parameters = Read-Rfc3161DerElement $algorithm.value ([ref]$algorithmOffset) $algorithmLimit
        if ($parameters.tag -ne 0x05 -or @($parameters.value).Count -ne 0) { throw 'RFC3161 hash AlgorithmIdentifier parameters are unsupported' }
    }
    if ($algorithmOffset -ne $algorithmLimit) { throw 'RFC3161 hash AlgorithmIdentifier has trailing data' }
    $hashed = Read-Rfc3161DerElement $imprint.value ([ref]$imprintOffset) $imprintLimit
    if ($hashed.tag -ne 0x04 -or $imprintOffset -ne $imprintLimit) { throw 'RFC3161 messageImprint digest is malformed' }
    $serial = Read-Rfc3161DerElement $root.value ([ref]$cursor) $limit
    if ($serial.tag -ne 0x02 -or !$serial.value.Length -or ($serial.value[0] -band 0x80)) { throw 'RFC3161 serial number is malformed' }
    $genTime = Read-Rfc3161DerElement $root.value ([ref]$cursor) $limit
    if ($genTime.tag -ne 0x18) { throw 'RFC3161 TSTInfo genTime is missing or not GeneralizedTime' }
    $genText = [Text.Encoding]::ASCII.GetString($genTime.value)
    $timeMatch = [regex]::Match($genText, '^(\d{14})(?:\.(\d{1,7}))?Z$')
    if (!$timeMatch.Success) { throw 'RFC3161 genTime must be UTC GeneralizedTime with at most 7 fractional digits' }
    $fraction = if ($timeMatch.Groups[2].Success) { $timeMatch.Groups[2].Value.PadRight(7, '0') } else { '0000000' }
    $normalizedTime = $timeMatch.Groups[1].Value + '.' + $fraction + 'Z'
    $parsedTime = [DateTimeOffset]::ParseExact($normalizedTime, "yyyyMMddHHmmss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)

    # Consume the supported ordered optional fields. Unknown/trailing fields fail closed.
    $lastOptional = 0
    while ($cursor -lt $limit) {
        $optional = Read-Rfc3161DerElement $root.value ([ref]$cursor) $limit
        $rank = switch ($optional.tag) { 0x30 { 1 } 0x01 { 2 } 0x02 { 3 } 0xa0 { 4 } 0xa1 { 5 } default { throw 'RFC3161 TSTInfo has an unsupported optional or trailing field' } }
        if ($rank -le $lastOptional) { throw 'RFC3161 TSTInfo optional fields are duplicated or out of order' }
        $lastOptional = $rank
        if ($optional.tag -eq 0x30) {
            $p = 0; $seen = 0
            while ($p -lt $optional.value.Length) {
                $part = Read-Rfc3161DerElement $optional.value ([ref]$p) $optional.value.Length
                if ($part.tag -notin @(0x02,0x80,0x81) -or @($part.value).Count -eq 0 -or ($part.value[0] -band 0x80)) { throw 'RFC3161 Accuracy field is malformed' }
                $partRank = @{ 2=1; 128=2; 129=3 }[[int]$part.tag]
                if ($partRank -le $seen) { throw 'RFC3161 Accuracy fields are duplicated or out of order' }
                $seen = $partRank
            }
        } elseif ($optional.tag -eq 0x01) {
            if (@($optional.value).Count -ne 1 -or $optional.value[0] -notin @(0,255)) { throw 'RFC3161 ordering BOOLEAN is malformed' }
        } elseif ($optional.tag -eq 0x02) {
            if (@($optional.value).Count -eq 0 -or ($optional.value[0] -band 0x80)) { throw 'RFC3161 nonce INTEGER is malformed' }
        } elseif ($optional.tag -eq 0xa0) {
            $p = 0; $generalName = Read-Rfc3161DerElement $optional.value ([ref]$p) $optional.value.Length
            if ($p -ne $optional.value.Length) { throw 'RFC3161 TSA GeneralName has trailing data' }
        } elseif ($optional.tag -eq 0xa1) {
            $p = 0
            while ($p -lt $optional.value.Length) {
                $extension = Read-Rfc3161DerElement $optional.value ([ref]$p) $optional.value.Length
                if ($extension.tag -ne 0x30) { throw 'RFC3161 extension is malformed' }
            }
        }
    }
    return [pscustomobject]@{ policyOid=$policyOid; hashAlgorithmOid=$algorithmOid; hashedMessage=$hashed.value; genTimeUtc=$parsedTime.UtcDateTime; originalGenTime=$genText }
}

function Compare-Rfc3161Bytes([byte[]] $Left, [byte[]] $Right) {
    if ($Left.Length -ne $Right.Length) { return $false }
    $different = 0
    for ($index = 0; $index -lt $Left.Length; $index++) { $different = $different -bor ($Left[$index] -bxor $Right[$index]) }
    return ($different -eq 0)
}

function Get-AuthenticodeRfc3161ObservationFromCms {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]] $EncodedMessage,
          [Parameter(Mandatory)][byte[]] $OuterEncryptedDigest,
          [Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2] $SignerCertificate,
          [Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2] $TimestampCertificate,
          [Parameter(Mandatory)][DateTime] $CheckedAtUtc)
    Add-Type -AssemblyName System.Security
    $outer = [Security.Cryptography.Pkcs.SignedCms]::new()
    $outer.Decode($EncodedMessage)
    if ($outer.SignerInfos.Count -ne 1) { throw 'RFC3161 extraction requires exactly one outer MSI signer' }
    $outerSigner = $outer.SignerInfos[0]
    $rfcAttributes = @($outerSigner.UnsignedAttributes | Where-Object { $_.Oid.Value -eq '1.3.6.1.4.1.311.3.3.1' })
    $legacyAttributes = @($outerSigner.UnsignedAttributes | Where-Object { $_.Oid.Value -eq '1.2.840.113549.1.9.6' })
    if ($rfcAttributes.Count -ne 1 -or $rfcAttributes[0].Values.Count -ne 1 -or $legacyAttributes.Count -ne 0) {
        throw 'MSI signature must contain exactly one unambiguous RFC3161 counter-signature and no legacy countersignature'
    }
    $token = [Security.Cryptography.Pkcs.SignedCms]::new()
    $token.Decode($rfcAttributes[0].Values[0].RawData)
    if ($token.ContentInfo.ContentType.Value -cne '1.2.840.113549.1.9.16.1.4' -or $token.SignerInfos.Count -ne 1) {
        throw 'RFC3161 token content type or signer count is invalid'
    }
    $token.CheckSignature($true)
    $tokenSigner = $token.SignerInfos[0].Certificate
    if (!$tokenSigner -or $tokenSigner.Thumbprint -cne $TimestampCertificate.Thumbprint) { throw 'RFC3161 token signer differs from the native timestamp certificate' }
    $tstInfo = Get-Rfc3161TstInfo $token.ContentInfo.Content
    $hashName = switch ($tstInfo.hashAlgorithmOid) {
        '1.3.14.3.2.26' { 'SHA1' }
        '2.16.840.1.101.3.4.2.1' { 'SHA256' }
        '2.16.840.1.101.3.4.2.2' { 'SHA384' }
        '2.16.840.1.101.3.4.2.3' { 'SHA512' }
        default { throw "RFC3161 messageImprint uses unsupported hash OID $($tstInfo.hashAlgorithmOid)" }
    }
    $algorithm = [Security.Cryptography.HashAlgorithm]::Create($hashName)
    try { $observedImprint = $algorithm.ComputeHash($OuterEncryptedDigest) }
    finally { $algorithm.Dispose() }
    if (-not (Compare-Rfc3161Bytes -Left $observedImprint -Right $tstInfo.hashedMessage)) { throw 'RFC3161 messageImprint does not bind the outer MSI signer encrypted digest' }
    $checkedAt = $CheckedAtUtc.ToUniversalTime()
    if ($tstInfo.genTimeUtc -lt $SignerCertificate.NotBefore.ToUniversalTime() -or
        $tstInfo.genTimeUtc -gt $SignerCertificate.NotAfter.ToUniversalTime() -or $tstInfo.genTimeUtc -gt $checkedAt) {
        throw 'RFC3161 genTime is outside the MSI signer certificate validity window or is in the future'
    }
    return [pscustomobject]@{
        signingTimeUtc=$tstInfo.genTimeUtc.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        signingTimeSource='rfc3161-tstinfo-genTime'
        messageImprint=@{ algorithmOid=$tstInfo.hashAlgorithmOid; hashedMessage=([BitConverter]::ToString($tstInfo.hashedMessage)).Replace('-','').ToLowerInvariant() }
        timestampSignerThumbprint=$tokenSigner.Thumbprint.ToUpperInvariant()
        tokenSignatureVerified=$true
    }
}

function Get-AuthenticodeRfc3161Observation([string] $MsiPath,
    [Security.Cryptography.X509Certificates.X509Certificate2] $SignerCertificate,
    [Security.Cryptography.X509Certificates.X509Certificate2] $TimestampCertificate,
    [DateTime] $CheckedAtUtc) {
    Initialize-AuthenticodeRfc3161Type
    $encoded = [Ticket569Rfc3161Cms]::ReadEmbeddedSignedMessage($MsiPath)
    $encryptedDigest = [Ticket569Rfc3161Cms]::ReadEmbeddedEncryptedDigest($MsiPath)
    return Get-AuthenticodeRfc3161ObservationFromCms -EncodedMessage $encoded -OuterEncryptedDigest $encryptedDigest -SignerCertificate $SignerCertificate `
        -TimestampCertificate $TimestampCertificate -CheckedAtUtc $CheckedAtUtc
}

Export-ModuleMember -Function Get-Rfc3161TstInfo, Get-AuthenticodeRfc3161ObservationFromCms, Get-AuthenticodeRfc3161Observation
