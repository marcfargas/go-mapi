[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$AppExe = "src/app/build/bin/go-mapi.exe",
    [string]$OutputDirectory = "release/app",
    [string]$MakeNsis = "makensis.exe"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$versionInput = (Get-Content (Join-Path $repoRoot "src/app/VERSION") -Raw).Trim()
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Version -eq '0.0.0') { throw "Version must be a stable major.minor.patch value" }
if ($Version -ne $versionInput) { throw "Version $Version does not match src/app/VERSION $versionInput" }
$appPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $AppExe))
if (-not (Test-Path $appPath -PathType Leaf)) { throw "App executable not found: $appPath" }
$nsisPath = (Get-Command $MakeNsis -ErrorAction Stop).Source
$outputPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
$installerPath = Join-Path $outputPath "go-mapi-user-$Version-x64.exe"
$scriptPath = Join-Path $repoRoot "src/app/packaging/standalone/go-mapi-user.nsi"
Push-Location $outputPath
try {
    & $nsisPath "/DGOMAPI_VERSION=$Version" "/DGOMAPI_EXE=$appPath" "/DGOMAPI_OUTPUT=$installerPath" $scriptPath
    if ($LASTEXITCODE -ne 0) { throw "makensis failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}
if (-not (Test-Path $installerPath -PathType Leaf)) { throw "Expected installer missing: $installerPath" }
Write-Output $installerPath
