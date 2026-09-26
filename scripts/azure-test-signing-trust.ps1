#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Cleanup')][string]$Mode,
    [Parameter(Mandatory)][string]$StatePath,
    [string[]]$SignedFiles
)
$ErrorActionPreference = 'Stop'
$rootUrl = 'https://www.microsoft.com/pkiops/certs/Microsoft%20Identity%20Verification%20TEST%20ONLY%20Root%20Certificate%20Authority%202020.crt'
$rootHash = '41c1fd9b83c54731c84375c07ec2585b61d032961d9c578c1784fca0e3c59f6e'
$rootCommonName = 'CN=Microsoft Identity Verification TEST ONLY Root Certificate Authority 2020'
function SignatureStatus([string]$Path, [string]$Phase) {
    $name = [IO.Path]::GetFileName($Path)
    Write-Host "Azure TEST trust $Phase signature check starting: $name"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $timer.Stop()
    Write-Host "Azure TEST trust $Phase signature check finished: $name status=$($signature.Status) elapsedMs=$($timer.ElapsedMilliseconds)"
    return [ordered]@{ file=$name; status=$signature.Status.ToString();
        signerThumbprint=if ($signature.SignerCertificate) { $signature.SignerCertificate.Thumbprint } else { $null };
        timestampThumbprint=if ($signature.TimeStamperCertificate) { $signature.TimeStamperCertificate.Thumbprint } else { $null } }
}
if ($Mode -eq 'Cleanup') {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ($state.schema -ne 'go-mapi-azure-test-root-fixture-v1' -or $state.certificateSha256 -cne $rootHash -or
        $state.store -cne 'LocalMachine/Root') { throw 'Invalid test-root cleanup state' }
    if ($state.importAttempted -and -not $state.preexisting) {
        $path = "Cert:\LocalMachine\Root\$($state.thumbprint)"
        if (Test-Path -LiteralPath $path) {
            $certificate = Get-Item -LiteralPath $path -ErrorAction Stop
            $sha256 = [Security.Cryptography.SHA256]::Create()
            try { $hash = ([BitConverter]::ToString($sha256.ComputeHash($certificate.RawData))).Replace('-', '').ToLowerInvariant() }
            finally { $sha256.Dispose() }
            if ($hash -cne $rootHash) { throw 'Owned test root changed before cleanup' }
            Remove-Item -LiteralPath $path -Force
            if (Test-Path -LiteralPath $path) { throw 'Owned test root remains after cleanup' }
            Write-Host "Removed owned Azure TEST ONLY root $($state.thumbprint) from LocalMachine Root"
        }
    }
    return
}
if (-not $SignedFiles -or (Test-Path -LiteralPath $StatePath)) { throw 'Test-root preparation requires signed files and a vacant state path' }
$baseline = @($SignedFiles | ForEach-Object { SignatureStatus $_ 'baseline' })
$tempCert = Join-Path $env:RUNNER_TEMP ('go-mapi-test-root-' + [Guid]::NewGuid().ToString('N') + '.crt')
try {
    Write-Host 'Azure TEST trust pinned Microsoft root download starting (60-second timeout)'
    $downloadTimer = [Diagnostics.Stopwatch]::StartNew()
    Invoke-WebRequest -Uri $rootUrl -OutFile $tempCert -TimeoutSec 60
    $downloadTimer.Stop()
    Write-Host "Azure TEST trust pinned Microsoft root download finished: elapsedMs=$($downloadTimer.ElapsedMilliseconds)"
    if ((Get-FileHash -LiteralPath $tempCert -Algorithm SHA256).Hash.ToLowerInvariant() -cne $rootHash) { throw 'Official Azure TEST root hash mismatch' }
    Write-Host 'Azure TEST trust pinned Microsoft root SHA-256 matched'
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($tempCert)
    if ($certificate.Subject -cne $certificate.Issuer -or -not $certificate.Subject.Contains($rootCommonName)) { throw 'Unexpected Azure TEST root identity' }
    $storePath = "Cert:\LocalMachine\Root\$($certificate.Thumbprint)"
    $alreadyTrusted = Test-Path -LiteralPath $storePath
    $shouldImport = @($baseline | Where-Object status -ne 'Valid').Count -gt 0 -and -not $alreadyTrusted
    $state = [ordered]@{ schema='go-mapi-azure-test-root-fixture-v1'; source=$rootUrl; certificateSha256=$rootHash;
        thumbprint=$certificate.Thumbprint; store='LocalMachine/Root'; preexisting=$alreadyTrusted; importAttempted=$shouldImport;
        imported=$false; baseline=$baseline }
    # Save cleanup ownership before changing the certificate store. If import
    # fails after adding the cert, the job's always() cleanup can still remove it.
    [IO.File]::WriteAllText($StatePath, ($state | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    if ($shouldImport) {
        Write-Host 'Azure TEST trust owned LocalMachine Root import starting'
        Import-Certificate -FilePath $tempCert -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
        if (-not (Test-Path -LiteralPath $storePath)) { throw 'Azure TEST root import did not persist' }
        $state.imported = $true
        [IO.File]::WriteAllText($StatePath, ($state | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        Write-Host 'Azure TEST trust owned LocalMachine Root import finished'
    } else {
        Write-Host 'Azure TEST trust root import skipped; preserving existing store state'
    }
    foreach ($file in $SignedFiles) {
        $status = SignatureStatus $file 'final'
        if ($status.status -ne 'Valid' -or -not $status.signerThumbprint -or -not $status.timestampThumbprint) {
            throw "Azure TEST signature did not validate with explicit runner trust: $file ($($status.status))"
        }
    }
} finally { Remove-Item -LiteralPath $tempCert -Force -ErrorAction SilentlyContinue }
