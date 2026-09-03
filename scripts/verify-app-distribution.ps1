[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$MsixPath,
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [string]$OutputManifest = "release/app/app-distribution.json",
    [switch]$RequireSignature
)

$ErrorActionPreference = "Stop"

function Resolve-MakeAppx {
    $command = Get-Command makeappx.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $sdkBinRoot = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Windows Kits\10\bin'
    if (Test-Path -LiteralPath $sdkBinRoot) {
        $candidate = Get-ChildItem -LiteralPath $sdkBinRoot -Directory |
            Sort-Object Name -Descending |
            ForEach-Object {
                $path = Join-Path $_.FullName 'x64\makeappx.exe'
                if (Test-Path -LiteralPath $path) { $path }
            } |
            Select-Object -First 1
        if ($candidate) { return $candidate }
    }
    throw 'makeappx.exe was not found on PATH or in the installed Windows SDK'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$versionInput = (Get-Content (Join-Path $repoRoot "src/app/VERSION") -Raw).Trim()
if ($Version -ne $versionInput) { throw "Distribution version does not match src/app/VERSION" }
$makeAppx = Resolve-MakeAppx
$msix = [IO.Path]::GetFullPath((Join-Path $repoRoot $MsixPath))
$installer = [IO.Path]::GetFullPath((Join-Path $repoRoot $InstallerPath))
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
    $manifest = Get-Content (Join-Path $stage "AppxManifest.xml") -Raw
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
    $manifestPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputManifest))
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifestPath) | Out-Null
    [IO.File]::WriteAllText($manifestPath, ($record | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Write-Output $manifestPath
} finally {
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
}
