[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('baseline', 'candidate')] [string] $PackageKind,
    [Parameter(Mandatory)] [string] $MsiPath,
    [Parameter(Mandatory)] [string] $ExpectedMsiSHA256,
    [Parameter(Mandatory)] [string] $InstalledAppPath,
    [Parameter(Mandatory)] [string] $InstalledDllPath,
    [Parameter(Mandatory)] [string] $ExpectedAppSHA256,
    [Parameter(Mandatory)] [string] $ExpectedDllSHA256,
    [Parameter(Mandatory)] [string] $EvidenceDirectory,
    [string] $BaselineReleaseApiPath,
    [string] $BaselineValidationPath,
    [string] $BaselineManifestPath,
    [string] $BaselineTargetsPath,
    [string] $BaselineAppArtifactsPath,
    [string] $BaselinePortableEvidenceArchivePath,
    [string] $BaselinePortableEvidencePath,
    [string] $ExpectedPriorAppSHA256,
    [string] $ExpectedPriorDllSHA256,
    [string] $WebViewBootstrapper,
    [string] $ExpectedWebViewSHA256
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

function Write-Atomic([string] $Path, $Value) {
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 12) + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

foreach ($hash in @($ExpectedMsiSHA256, $ExpectedAppSHA256, $ExpectedDllSHA256)) {
    if ($hash -notmatch '^[0-9a-fA-F]{64}$') { throw 'Package hashes must be 64-character SHA-256 values' }
}
$msiHash = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($msiHash -ne $ExpectedMsiSHA256.ToLowerInvariant()) { throw 'Staged MSI bytes differ from the selected immutable package hash' }
if ($PackageKind -eq 'baseline') {
    if ($ExpectedMsiSHA256.ToLowerInvariant() -cne 'bcf00f8511b8f076582ff06f9ecb00a67aa9476dd3cbdebc5f6b975f4ec94a68' -or
        (Split-Path -Leaf $MsiPath) -cne 'go-mapi-suite-3.2.0-alpha.7-x64.msi') { throw 'Only the prevalidated immutable alpha.7 fixture may enter baseline setup' }
    foreach ($assetPath in @($BaselineReleaseApiPath, $BaselineValidationPath, $BaselineManifestPath, $BaselineTargetsPath, $BaselineAppArtifactsPath, $BaselinePortableEvidenceArchivePath, $BaselinePortableEvidencePath)) {
        if (!$assetPath) { throw 'Baseline setup requires all pinned alpha.7 release assets and API provenance' }
    }
    if (Test-Path -LiteralPath $BaselinePortableEvidencePath) { throw 'Pinned alpha.7 portable evidence extraction path is occupied' }
    Expand-Archive -LiteralPath $BaselinePortableEvidenceArchivePath -DestinationPath $BaselinePortableEvidencePath -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'alpha7-baseline.psm1') -Force
    $baselineAdmission = Get-Alpha7HistoricalAdmission `
        -MsiPath $MsiPath -ReleaseApiPath $BaselineReleaseApiPath -ValidationPath $BaselineValidationPath `
        -ManifestPath $BaselineManifestPath -TargetsPath $BaselineTargetsPath -AppArtifactsPath $BaselineAppArtifactsPath `
        -PortableEvidencePath $BaselinePortableEvidencePath `
        -EvidencePath (Join-Path $EvidenceDirectory 'alpha7-native-admission.json') `
        -RequestedPackageKind 'exact-alpha7-historical-fixture'
    Write-Atomic (Join-Path $EvidenceDirectory 'package-input.json') @{ Kind = $PackageKind; Path = $MsiPath; SHA256 = $msiHash; Admission = $baselineAdmission.admission; PackageTuple = $baselineAdmission.tuple; Native = $baselineAdmission.native; Qualification = $baselineAdmission.qualification }
} else {
    if ($BaselineReleaseApiPath -or $BaselineValidationPath -or $BaselineManifestPath -or $BaselineTargetsPath -or $BaselineAppArtifactsPath) { throw 'Candidate cannot carry or request the alpha.7 expired-fixture inputs' }
    $validity = Join-Path $EvidenceDirectory 'candidate-validity-install.json'
    & (Join-Path $PSScriptRoot 'verify-candidate-current.ps1') -MsiPath $MsiPath -ExpectedMsiSHA256 $ExpectedMsiSHA256 -Phase install -EvidencePath $validity
    if ($LASTEXITCODE -ne 0) { throw 'Candidate failed the strict current-valid install-time signature check' }
    Write-Atomic (Join-Path $EvidenceDirectory 'package-input.json') @{ Kind = $PackageKind; Path = $MsiPath; SHA256 = $msiHash; CandidateValidityEvidence = $validity }
}

if ($PackageKind -eq 'baseline') {
    if (Test-Path -LiteralPath $InstalledAppPath -PathType Leaf) { throw 'A suite app is already installed; refusing to overwrite a fresh alpha.7 baseline' }
    if (Get-Service -Name go-mapi -ErrorAction SilentlyContinue) { throw 'The go-mapi service already exists before baseline setup' }
} else {
    foreach ($hash in @($ExpectedPriorAppSHA256, $ExpectedPriorDllSHA256)) {
        if (!$hash -or $hash -notmatch '^[0-9a-fA-F]{64}$') { throw 'Candidate install requires prior baseline app and DLL hashes' }
    }
    if (!(Test-Path -LiteralPath $InstalledAppPath -PathType Leaf) -or !(Test-Path -LiteralPath $InstalledDllPath -PathType Leaf)) { throw 'Historical baseline app/DLL is missing before candidate upgrade' }
    $priorAppHash = (Get-FileHash -LiteralPath $InstalledAppPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $priorDllHash = (Get-FileHash -LiteralPath $InstalledDllPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($priorAppHash -ne $ExpectedPriorAppSHA256.ToLowerInvariant() -or $priorDllHash -ne $ExpectedPriorDllSHA256.ToLowerInvariant()) { throw 'Installed baseline bytes differ from the selected alpha.7 manifest before candidate upgrade' }
}

if ($WebViewBootstrapper) {
    if (!$ExpectedWebViewSHA256 -or $ExpectedWebViewSHA256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'WebView bootstrapper requires a package hash' }
    $webHash = (Get-FileHash -LiteralPath $WebViewBootstrapper -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($webHash -ne $ExpectedWebViewSHA256.ToLowerInvariant()) { throw 'WebView bootstrapper hash differs from its selected vendor manifest' }
    $webSignature = Get-AuthenticodeSignature -LiteralPath $WebViewBootstrapper
    if ($webSignature.Status -ne 'Valid' -or $webSignature.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'WebView bootstrapper lacks a valid Microsoft signature' }
    $web = Start-Process -FilePath $WebViewBootstrapper -ArgumentList @('/silent', '/install') -PassThru -Wait
    Write-Atomic (Join-Path $EvidenceDirectory 'webview-install.json') @{ Path = $WebViewBootstrapper; SHA256 = $webHash; Signature = $webSignature.Status; Signer = $webSignature.SignerCertificate.Subject; PID = $web.Id; ExitCode = [int]$web.ExitCode }
    if ($web.ExitCode -ne 0) { throw "Vendor WebView bootstrapper exited $($web.ExitCode)" }
}

$install = Start-Process -FilePath msiexec.exe -ArgumentList @('/i', $MsiPath, '/qn', 'GOMAPI_AUTO_UPDATE=0', '/norestart') -PassThru -Wait
Write-Atomic (Join-Path $EvidenceDirectory 'msi-install.json') @{ Kind = $PackageKind; PID = $install.Id; ExitCode = [int]$install.ExitCode; MSI_SHA256 = $msiHash; StartedAt = $install.StartTime.ToUniversalTime().ToString('o'); FinishedAt = [DateTime]::UtcNow.ToString('o') }
if ($install.ExitCode -ne 0) { throw "MSI installer exited $($install.ExitCode); reboot-required 3010 needs an explicit observed reboot/reconnect" }

if ($PackageKind -eq 'candidate') {
    $validity = Join-Path $EvidenceDirectory 'candidate-validity-install-complete.json'
    & (Join-Path $PSScriptRoot 'verify-candidate-current.ps1') -MsiPath $MsiPath -ExpectedMsiSHA256 $ExpectedMsiSHA256 -Phase install-complete -EvidencePath $validity
    if ($LASTEXITCODE -ne 0) { throw 'Candidate stopped being current-valid during installation' }
}

if (!(Test-Path -LiteralPath $InstalledAppPath -PathType Leaf) -or !(Test-Path -LiteralPath $InstalledDllPath -PathType Leaf)) { throw 'Installed app or x64 MAPI DLL is missing after MSI completion' }
$appHash = (Get-FileHash -LiteralPath $InstalledAppPath -Algorithm SHA256).Hash.ToLowerInvariant()
$dllHash = (Get-FileHash -LiteralPath $InstalledDllPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($appHash -ne $ExpectedAppSHA256.ToLowerInvariant() -or $dllHash -ne $ExpectedDllSHA256.ToLowerInvariant()) { throw 'Installed app/DLL bytes differ from the selected package manifest' }
$service = Get-Service -Name go-mapi -ErrorAction Stop
Write-Atomic (Join-Path $EvidenceDirectory 'installed-package.json') @{ Kind = $PackageKind; MSI_SHA256 = $msiHash; AppPath = $InstalledAppPath; AppSHA256 = $appHash; X64DllPath = $InstalledDllPath; X64DllSHA256 = $dllHash; Service = $service.Name; ServiceStatus = [string]$service.Status; ServiceStartType = [string]$service.StartType }
Write-Output "INSTALLED_PACKAGE_$($PackageKind.ToUpperInvariant())_VERIFIED"
exit 0
