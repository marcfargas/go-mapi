#!/usr/bin/env pwsh
#
# Local v3.0 RC installer build for the Phase 11 sandbox smoke.
#
# Why this script exists:
# - The CI workflow `installer-release.yml` builds the signed/unsigned
#   installer and uploads it as `go-mapi-setup-unsigned`. For Phase 11
#   pre-GA smoke we need a fresh v3.0 installer before the release is
#   published, so we either download that CI artifact or build locally.
# - `!addplugindir "${__FILEDIR__}\plugins"` in `src/installer/go-mapi.nsi`
#   does not always register under some pwsh/MSYS invocations, so this
#   wrapper passes the plugin dir via `/X`-style preamble with an
#   absolute path, which works reliably.
#
# Prerequisites (one-time):
# - NSIS installed and on PATH (`scoop install nsis` or `choco install nsis`).
# - Fresh `go-mapi.exe` at `src\app\build\bin\`:
#       set -a; source .env.local; set +a
#       cd src/app && wails build -platform windows/amd64 \
#           -ldflags "-X main.Version=3.0.0-rc.1 \
#                     -X main.oauthClientID=$GOMAPI_OAUTH_CLIENT_ID \
#                     -X main.oauthClientSecret=$GOMAPI_OAUTH_CLIENT_SECRET \
#                     -X github.com/marcfargas/go-mapi/app.aumidOverride=com.marcfargas.gomapi \
#                     -s -w"
# - Fresh `go-mapi.dll` at `src\interceptor\build\bin\` (`npm run build:interceptor`).
#
# Output:
# - Installer copied to `tests\sandbox\phase11\installer\go-mapi-setup.exe`
#   (gitignored path) so the sandbox's LogonCommand picks it up.

[CmdletBinding()]
param(
    [string]$Version = '3.0.0-rc.1'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$InstallerDir = Join-Path $RepoRoot 'src\installer'
$PluginDir    = Join-Path $InstallerDir 'plugins'
$StageDir     = Join-Path $RepoRoot 'tests\sandbox\phase11\installer'

if (-not (Get-Command makensis -ErrorAction SilentlyContinue)) {
    throw "makensis not on PATH. Install NSIS: 'scoop install nsis' or 'choco install nsis'."
}

foreach ($p in @(
    'src\app\build\bin\go-mapi.exe',
    'src\interceptor\build\bin\go-mapi.dll'
)) {
    $full = Join-Path $RepoRoot $p
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Missing prerequisite: $full — rebuild binaries first (see script header)."
    }
}

Push-Location $InstallerDir
try {
    $preamble = "!addplugindir `"$PluginDir`""
    Write-Host "Version:  $Version"
    Write-Host "Preamble: $preamble"
    & makensis "/X$preamble" "/DGOMAPI_VERSION=$Version" go-mapi.nsi
    if ($LASTEXITCODE -ne 0) { throw "makensis exit $LASTEXITCODE" }

    $out = Join-Path $InstallerDir 'go-mapi-setup.exe'
    if (-not (Test-Path -LiteralPath $out)) { throw 'installer not produced' }

    New-Item -ItemType Directory -Force $StageDir | Out-Null
    $dest = Join-Path $StageDir 'go-mapi-setup.exe'
    Copy-Item $out $dest -Force
    $sz = (Get-Item $dest).Length
    $hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
    Write-Host "Staged:   $dest"
    Write-Host "Size:     $sz bytes"
    Write-Host "SHA256:   $hash"
}
finally {
    Pop-Location
}
