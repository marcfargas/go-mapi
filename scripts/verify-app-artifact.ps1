#Requires -Version 5.1
[CmdletBinding()]
param([string]$ArtifactPath = '')

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'components.json') -Raw | ConvertFrom-Json
$app = $manifest.components.app
if ($null -eq $app -or $app.path -ne 'src/app' -or $app.artifact -ne 'go-mapi.exe' -or $app.versionFile -ne 'src/app/VERSION') {
    throw 'components.json app record is invalid'
}
if ($manifest.schemaVersion -ne 2 -or $app.requires.component -ne 'interceptor' -or [string]::IsNullOrWhiteSpace($app.requires.minInclusive)) { throw 'components.json app compatibility record is invalid' }
$expected = ([System.IO.File]::ReadAllText((Join-Path $repoRoot $app.versionFile))).Trim()
if ([string]::IsNullOrWhiteSpace($expected) -or $expected -eq '0.0.0-dev') { throw 'verification requires a release app version' }
if ([string]::IsNullOrWhiteSpace($ArtifactPath)) { $ArtifactPath = Join-Path $repoRoot 'src/app/build/bin/go-mapi.exe' }
if ((Split-Path -Leaf $ArtifactPath) -ne $app.artifact -or -not (Test-Path -LiteralPath $ArtifactPath)) { throw "missing manifest-named app artifact: $ArtifactPath" }

# Wails applications are GUI subsystem executables.  On Windows their stdout
# can be inherited by (and displayed through) the GUI host rather than being
# returned through PowerShell's native-command output pipeline.  Consequently
# Capturing the program's `--version` output is therefore not a dependable
# artifact assertion even though the program handles that flag. The PE
# resources are the Windows distribution contract and are written from the same component VERSION input
# as the runtime ldflag by build-wails.ps1, so verify those instead.
$version = (Get-Item -LiteralPath $ArtifactPath).VersionInfo
foreach ($actual in @($version.ProductVersion, $version.FileVersion)) {
    if ($actual -notmatch [regex]::Escape($expected)) { throw "PE version mismatch: got $actual, want $expected" }
}
$artifactManifestPath = Join-Path (Split-Path -Parent $ArtifactPath) 'app-artifacts.json'
if (-not (Test-Path -LiteralPath $artifactManifestPath)) { throw "missing app artifact manifest: $artifactManifestPath" }
$artifactManifest = Get-Content -LiteralPath $artifactManifestPath -Raw | ConvertFrom-Json
if ($artifactManifest.component -ne 'app' -or $artifactManifest.version -ne $expected -or
    $artifactManifest.queueProtocol -ne $app.queueProtocol -or
    $artifactManifest.requires.component -ne $app.requires.component -or
    $artifactManifest.requires.minInclusive -ne $app.requires.minInclusive -or
    [string]$artifactManifest.requires.maxExclusive -ne [string]$app.requires.maxExclusive -or
    $artifactManifest.artifact.filename -ne $app.artifact -or
    $artifactManifest.artifact.peProductVersion -ne $expected) {
    throw 'app-artifacts.json does not match the app component record'
}
$actualHash = (Get-FileHash -LiteralPath $ArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($artifactManifest.artifact.sha256 -ne $actualHash) { throw 'app artifact SHA-256 mismatch' }
Write-Host "verified $($app.artifact) version $expected"
