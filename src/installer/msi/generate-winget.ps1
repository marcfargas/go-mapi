[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$MsiPath,
    [Parameter(Mandatory)][string]$InstallerUrl,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'winget\generated' }
if ($InstallerUrl -notmatch '^https://') { throw 'Winget installer URL must be immutable HTTPS' }
if (-not (Test-Path $MsiPath)) { throw "MSI not found: $MsiPath" }
$signature = Get-AuthenticodeSignature -LiteralPath $MsiPath
if ($signature.Status -ne 'Valid') { throw "Refusing winget publication for unsigned MSI ($($signature.Status))" }

$sha256 = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash.ToUpperInvariant()
function Get-MsiProperty([string]$Name) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @((Resolve-Path $MsiPath).Path, 0))
    $sql = "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'"
    $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @($sql))
    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
    $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
    if (-not $record) { throw "MSI property is absent: $Name" }
    return $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
}
$productCode = Get-MsiProperty 'ProductCode'
$upgradeCode = Get-MsiProperty 'UpgradeCode'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$manifestPath = Join-Path $OutputDirectory "go-mapi.interceptor.installer.yaml"
$yaml = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.1.12.0.schema.json
PackageIdentifier: MarcFargas.go-mapi.Interceptor
PackageVersion: $Version
InstallerType: msi
Scope: machine
InstallModes:
  - interactive
  - silent
  - silentWithProgress
ElevationRequirement: elevationRequired
Installers:
  - Architecture: x64
    InstallerUrl: $InstallerUrl
    InstallerSha256: $sha256
    ProductCode: '$productCode'
    UpgradeBehavior: install
    RepairBehavior: installer
    AppsAndFeaturesEntries:
      - DisplayName: go-mapi interceptor
        DisplayVersion: $Version
        ProductCode: '$productCode'
        UpgradeCode: '$upgradeCode'
        InstallerType: msi
ManifestType: installer
ManifestVersion: 1.12.0
"@
[IO.File]::WriteAllText($manifestPath, $yaml, [Text.UTF8Encoding]::new($false))
$versionManifest = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.1.12.0.schema.json
PackageIdentifier: MarcFargas.go-mapi.Interceptor
PackageVersion: $Version
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
"@
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'go-mapi.interceptor.yaml'), $versionManifest, [Text.UTF8Encoding]::new($false))
$localeManifest = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.1.12.0.schema.json
PackageIdentifier: MarcFargas.go-mapi.Interceptor
PackageVersion: $Version
PackageLocale: en-US
Publisher: Marc Fargas
PackageName: go-mapi interceptor
License: LGPL-3.0-or-later
ShortDescription: Machine-wide x86/x64 Simple MAPI interceptor for go-mapi
PackageUrl: https://github.com/marcfargas/go-mapi
ManifestType: defaultLocale
ManifestVersion: 1.12.0
"@
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'go-mapi.interceptor.locale.en-US.yaml'), $localeManifest, [Text.UTF8Encoding]::new($false))
Write-Host "Generated winget manifest: $manifestPath"
