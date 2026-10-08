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
$signature = Get-AuthenticodeSignature -LiteralPath $MsiPath
Write-Atomic (Join-Path $EvidenceDirectory 'package-input.json') @{ Kind = $PackageKind; Path = $MsiPath; SHA256 = $msiHash; SignatureStatus = [string]$signature.Status; Signer = $(if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }) }
if ($signature.Status -ne 'Valid') { throw "MSI Authenticode signature is not valid: $($signature.Status)" }

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

if (!(Test-Path -LiteralPath $InstalledAppPath -PathType Leaf) -or !(Test-Path -LiteralPath $InstalledDllPath -PathType Leaf)) { throw 'Installed app or x64 MAPI DLL is missing after MSI completion' }
$appHash = (Get-FileHash -LiteralPath $InstalledAppPath -Algorithm SHA256).Hash.ToLowerInvariant()
$dllHash = (Get-FileHash -LiteralPath $InstalledDllPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($appHash -ne $ExpectedAppSHA256.ToLowerInvariant() -or $dllHash -ne $ExpectedDllSHA256.ToLowerInvariant()) { throw 'Installed app/DLL bytes differ from the selected package manifest' }
$service = Get-Service -Name go-mapi -ErrorAction Stop
Write-Atomic (Join-Path $EvidenceDirectory 'installed-package.json') @{ Kind = $PackageKind; MSI_SHA256 = $msiHash; AppPath = $InstalledAppPath; AppSHA256 = $appHash; X64DllPath = $InstalledDllPath; X64DllSHA256 = $dllHash; Service = $service.Name; ServiceStatus = [string]$service.Status; ServiceStartType = [string]$service.StartType }
Write-Output "INSTALLED_PACKAGE_$($PackageKind.ToUpperInvariant())_VERIFIED"
exit 0
