# Select only public packages and existing CI receipts for the disposable guest.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PriorBundleDirectory,
    [Parameter(Mandatory)][string]$BundleDirectory,
    [Parameter(Mandatory)][string]$PriorMachineReceiptsDirectory,
    [Parameter(Mandatory)][string]$MachineReceiptsDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
function ReadJson([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Select a new output directory' }
$prior = ReadJson (Join-Path $PriorBundleDirectory 'release.json')
$current = ReadJson (Join-Path $BundleDirectory 'release.json')
if ($prior.schema -cne 'go-mapi-release-v1' -or $current.schema -cne $prior.schema -or
    $prior.system.reused -or $current.system.reused -isnot [bool] -or !$current.system.reused -or
    $current.system.manifestSha256 -cne (Hash (Join-Path $PriorBundleDirectory 'release.json')) -or
    $current.system.version -cne $prior.system.version -or $current.system.commit -cne $prior.system.commit -or
    $current.suite.sequence -le $prior.suite.sequence -or $current.suite.upgradeCode -cne $prior.suite.upgradeCode) {
    throw 'Select a newer Suite reusing this original System release'
}
# Validate every selected receipt before creating output. No fixture manifest is introduced.
$selections = @(
    @{name='prior'; bundle=$PriorBundleDirectory; receipts=$PriorMachineReceiptsDirectory; release=$prior},
    @{name='current'; bundle=$BundleDirectory; receipts=$MachineReceiptsDirectory; release=$current}
)
foreach ($selection in $selections) {
    $release = $selection.release
    $asset = $release.suite.artifact
    if ([IO.Path]::GetFileName($asset.file) -cne $asset.file -or $asset.file -cne "go-mapi-suite-$($release.version)-x64.msi") { throw 'Unexpected Suite filename' }
    $package = Join-Path $selection.bundle $asset.file
    if ((Hash $package) -cne $asset.sha256 -or (Get-Item -LiteralPath $package).Length -ne $asset.size) { throw 'Suite package differs from release.json' }
    $proof = ReadJson (Join-Path $selection.receipts "suite-$($release.version).validation.json")
    $manifest = "go-mapi-suite-$($release.version).manifest.json"
    if ($proof.commit -cne $release.commit -or [string]$proof.runId -cne [string]$release.runId -or
        [string]$proof.runAttempt -cne [string]$release.runAttempt -or $proof.msi.sha256 -cne $asset.sha256 -or
        $proof.signedInputManifest.file -cne $manifest -or
        $proof.signedInputManifest.sha256 -cne (Hash (Join-Path $selection.receipts $manifest))) { throw 'Suite CI receipt identity differs' }
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
foreach ($selection in $selections) {
    $destination = Join-Path $OutputDirectory $selection.name
    New-Item -ItemType Directory -Path $destination | Out-Null
    $release = $selection.release
    Copy-Item -LiteralPath (Join-Path $selection.bundle 'release.json'),(Join-Path $selection.bundle $release.suite.artifact.file) -Destination $destination
    foreach ($name in @("suite-$($release.version).validation.json", "go-mapi-suite-$($release.version).manifest.json")) {
        Copy-Item -LiteralPath (Join-Path $selection.receipts $name) -Destination $destination
    }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Test-ReusedSuite.ps1') -Destination $OutputDirectory
[pscustomobject]@{InputDirectory=$OutputDirectory; ScriptPath='Test-ReusedSuite.ps1'}
