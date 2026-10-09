#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Cleanup')][string] $Mode,
    [Parameter(Mandatory)][string] $StatePath
)
$ErrorActionPreference = 'Stop'
$source = 'https://www.microsoft.com/pkiops/certs/Microsoft%20Identity%20Verification%20TEST%20ONLY%20Root%20Certificate%20Authority%202020.crt'
$sha256Pinned = '41c1fd9b83c54731c84375c07ec2585b61d032961d9c578c1784fca0e3c59f6e'
$sha1Pinned = 'DFA0E53504EF5328FAEC21AD7DF14C10B07C4FCB'
$subjectPinned = 'CN=Microsoft Identity Verification TEST ONLY Root Certificate Authority 2020'

function Get-CertificateSha256($Certificate) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Certificate.RawData))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

if ($Mode -eq 'Cleanup') {
    if (!(Test-Path -LiteralPath $StatePath -PathType Leaf)) { return }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($state.schema -cne 'go-mapi-alpha7-test-root-fixture-v1' -or $state.sha256 -cne $sha256Pinned -or
        $state.sha1 -cne $sha1Pinned -or $state.store -cne 'LocalMachine/Root') { throw 'Invalid alpha.7 pinned test-root cleanup state' }
    if ($state.importAttempted -and !$state.preexisting) {
        $matches = @(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $sha1Pinned)
        if ($matches.Count -gt 1) { throw 'Alpha.7 pinned-root cleanup found ambiguous certificate identity' }
        if ($matches.Count -eq 1) {
            if ((Get-CertificateSha256 $matches[0]) -cne $sha256Pinned) { throw 'Alpha.7 owned test root bytes changed before cleanup' }
            Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$sha1Pinned" -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath "Cert:\LocalMachine\Root\$sha1Pinned") { throw 'Owned alpha.7 TEST root remains after cleanup' }
    }
    return
}

if (Test-Path -LiteralPath $StatePath) { throw 'Alpha.7 trust state path is occupied' }
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP = [IO.Path]::GetTempPath() }
$temp = Join-Path $env:RUNNER_TEMP ('ticket569-alpha7-root-' + [guid]::NewGuid().ToString('N') + '.crt')
try {
    Invoke-WebRequest -Uri $source -OutFile $temp -TimeoutSec 60
    if ((Get-FileHash -LiteralPath $temp -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -cne $sha256Pinned) { throw 'Downloaded pinned alpha.7 TEST root hash mismatch' }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($temp)
    try {
        if ((Get-CertificateSha256 $certificate) -cne $sha256Pinned -or $certificate.Thumbprint -cne $sha1Pinned -or
            $certificate.Subject -cne $subjectPinned -or $certificate.Subject -cne $certificate.Issuer) { throw 'Downloaded alpha.7 TEST root identity mismatch' }
        $path = "Cert:\LocalMachine\Root\$sha1Pinned"
        $existing = @(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $sha1Pinned)
        if ($existing.Count -gt 1) { throw 'Pinned alpha.7 TEST root identity is ambiguous in LocalMachine Root' }
        if ($existing.Count -eq 1 -and (Get-CertificateSha256 $existing[0]) -cne $sha256Pinned) { throw 'Preexisting alpha.7 root thumbprint has different bytes' }
        $preexisting = $existing.Count -eq 1
        $state = [ordered]@{ schema='go-mapi-alpha7-test-root-fixture-v1'; source=$source; sha256=$sha256Pinned; sha1=$sha1Pinned; store='LocalMachine/Root'; preexisting=$preexisting; importAttempted=(!$preexisting); imported=$false }
        [IO.File]::WriteAllText($StatePath, (ConvertTo-Json -InputObject $state -Depth 8), [Text.UTF8Encoding]::new($false))
        if (!$preexisting) {
            Import-Certificate -FilePath $temp -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction Stop | Out-Null
            $added = Get-Item -LiteralPath $path -ErrorAction Stop
            if ((Get-CertificateSha256 $added) -cne $sha256Pinned) { throw 'Alpha.7 pinned TEST root import did not preserve exact bytes' }
            $state.imported = $true
            [IO.File]::WriteAllText($StatePath, (ConvertTo-Json -InputObject $state -Depth 8), [Text.UTF8Encoding]::new($false))
        }
        Write-Output ($state | ConvertTo-Json -Compress)
    } finally { $certificate.Dispose() }
} finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
