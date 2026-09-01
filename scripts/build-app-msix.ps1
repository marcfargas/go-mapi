[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$IdentityName,
    [Parameter(Mandatory = $true)][string]$Publisher,
    [Parameter(Mandatory = $true)][string]$PublisherDisplayName,
    [string]$AppExe = "src/app/build/bin/go-mapi.exe",
    [string]$OutputDirectory = "release/app"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$versionInput = (Get-Content (Join-Path $repoRoot "src/app/VERSION") -Raw).Trim()
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Version -eq '0.0.0') { throw "Version must be a stable major.minor.patch value" }
if ($Version -ne $versionInput) { throw "Version $Version does not match src/app/VERSION $versionInput" }
$packageVersion = "$Version.0"

$appPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $AppExe))
if (-not (Test-Path $appPath -PathType Leaf)) { throw "App executable not found: $appPath" }
$makeAppx = (Get-Command makeappx.exe -ErrorAction Stop).Source
$outputPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
$stage = Join-Path ([IO.Path]::GetTempPath()) ("go-mapi-msix-" + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $stage "Assets") | Out-Null
    Copy-Item $appPath (Join-Path $stage "go-mapi.exe")

    Add-Type -AssemblyName System.Drawing
    $sourceLogo = Join-Path $repoRoot "src/app/frontend/src/assets/images/logo-universal.png"
    $sourceImage = [Drawing.Image]::FromFile($sourceLogo)
    try {
        $logos = @{
            "StoreLogo.png" = @(50, 50)
            "Square44x44Logo.png" = @(44, 44)
            "Square150x150Logo.png" = @(150, 150)
            "Wide310x150Logo.png" = @(310, 150)
        }
        foreach ($entry in $logos.GetEnumerator()) {
            $bitmap = New-Object Drawing.Bitmap($entry.Value[0], $entry.Value[1])
            try {
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                try { $graphics.DrawImage($sourceImage, 0, 0, $bitmap.Width, $bitmap.Height) } finally { $graphics.Dispose() }
                $bitmap.Save((Join-Path $stage "Assets\$($entry.Key)"), [Drawing.Imaging.ImageFormat]::Png)
            } finally { $bitmap.Dispose() }
        }
    } finally { $sourceImage.Dispose() }

    $template = Get-Content (Join-Path $repoRoot "src/app/packaging/msix/AppxManifest.xml.in") -Raw
    $manifest = $template.Replace('@@IDENTITY_NAME@@', $IdentityName).
        Replace('@@PUBLISHER@@', $Publisher).
        Replace('@@PUBLISHER_DISPLAY_NAME@@', $PublisherDisplayName).
        Replace('@@PACKAGE_VERSION@@', $packageVersion)
    [IO.File]::WriteAllText((Join-Path $stage "AppxManifest.xml"), $manifest, (New-Object Text.UTF8Encoding($false)))

    $msixPath = Join-Path $outputPath "go-mapi-$Version-x64.msix"
    & $makeAppx pack /d $stage /p $msixPath /o
    if ($LASTEXITCODE -ne 0) { throw "MakeAppx failed with exit code $LASTEXITCODE" }
    Write-Output $msixPath
} finally {
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
}
