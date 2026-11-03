[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$MsixPath,
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [string]$AppExePath,
    [string]$OutputManifest = "release/app/app-distribution.json",
    [switch]$RequireSignature,
    [string]$MakeAppx = 'makeappx.exe',
    [string]$IdentityName,
    [string]$Publisher,
    [string]$PublisherDisplayName
)

$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Resolve-PackagePath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}
# The shared release sequence preserves prerelease counters in Windows versions.
$identity = & go -C $repoRoot run ./internal/mapi/cmd/machine-package -- system $Version | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Distribution version cannot be encoded as a Windows package version' }
$packageVersion = $identity.productVersion + '.0'
$msix = Resolve-PackagePath $MsixPath
$installer = Resolve-PackagePath $InstallerPath
foreach ($artifact in @($msix, $installer)) {
    if (-not (Test-Path $artifact -PathType Leaf)) { throw "Missing artifact: $artifact" }
    if ($RequireSignature -and (Get-AuthenticodeSignature $artifact).Status -ne 'Valid') { throw "Production artifact is not validly signed: $artifact" }
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ("go-mapi-verify-" + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    & $makeAppx unpack /p $msix /d $stage /o
    if ($LASTEXITCODE -ne 0) { throw "MakeAppx unpack failed" }
    $files = @(Get-ChildItem $stage -Recurse -File)
    $payload = @($files | Where-Object { $_.Extension -eq '.exe' })
    if ($payload.Count -ne 1 -or $payload[0].Name -ne 'go-mapi.exe') { throw "MSIX must contain exactly one executable payload: go-mapi.exe" }
    if ($AppExePath) {
        $appExe = Resolve-PackagePath $AppExePath
        if (-not (Test-Path -LiteralPath $appExe -PathType Leaf) -or
            (Get-FileHash -LiteralPath $appExe -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $payload[0].FullName -Algorithm SHA256).Hash) {
            throw 'MSIX payload differs from the exact signed app executable'
        }
    }
    $manifest = Get-Content (Join-Path $stage "AppxManifest.xml") -Raw
    $identity = ([xml]$manifest).Package.Identity
    if (($IdentityName -and $identity.Name -cne $IdentityName) -or
        ($Publisher -and $identity.Publisher -cne $Publisher) -or
        ($PublisherDisplayName -and ([xml]$manifest).Package.Properties.PublisherDisplayName -cne $PublisherDisplayName)) {
        throw 'MSIX identity differs from the requested package identity'
    }
    if (-not $manifest.Contains("Version=`"$packageVersion`"")) { throw "MSIX identity version does not match $packageVersion" }
    foreach ($required in @('ProcessorArchitecture="x64"', 'Windows.FullTrustApplication', 'windows.startupTask', 'TaskId="go-mapi-user-startup-v4"', 'Enabled="true"', 'FileSystemWriteVirtualization>disabled', 'Name="runFullTrust"', 'Name="unvirtualizedResources"', 'MinVersion="10.0.18362.0"')) {
        if (-not $manifest.Contains($required)) { throw "MSIX manifest is missing: $required" }
    }
    foreach ($forbidden in @('allowElevation', 'HKEY_LOCAL_MACHINE', 'UserChoice', 'go-mapi.dll', '.msi')) {
        if ($manifest.Contains($forbidden)) { throw "Forbidden MSIX content: $forbidden" }
    }

    $record = [ordered]@{
        schemaVersion = 1
        component = 'app'
        version = $Version
        architecture = 'x64'
        msix = [ordered]@{ file = [IO.Path]::GetFileName($msix); sha256 = (Get-FileHash $msix -Algorithm SHA256).Hash.ToLowerInvariant(); signature = (Get-AuthenticodeSignature $msix).Status.ToString() }
        standalone = [ordered]@{ file = [IO.Path]::GetFileName($installer); sha256 = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant(); signature = (Get-AuthenticodeSignature $installer).Status.ToString() }
        provenance = [ordered]@{ repository = $env:GITHUB_REPOSITORY; runId = $env:GITHUB_RUN_ID; commit = $env:GITHUB_SHA }
    }
    $manifestPath = Resolve-PackagePath $OutputManifest
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifestPath) | Out-Null
    [IO.File]::WriteAllText($manifestPath, ($record | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Write-Output $manifestPath
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not [IO.Path]::GetFullPath($stage).StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid owned verification directory' }
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
