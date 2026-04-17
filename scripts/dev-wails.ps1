#!/usr/bin/env pwsh
# Phase 8 dev wrapper: loads .env.local from the repo root, then invokes `wails dev`.
# Mirrors the release-build -ldflags injection pattern so `wails dev` runs
# with the same oauthClientID / oauthClientSecret source-of-truth.

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$envFile = Join-Path $repoRoot '.env.local'
if (-not (Test-Path $envFile)) {
    Write-Error "Missing $envFile. Copy .env.local.example (repo root), fill in GCP OAuth client credentials, then retry."
}

Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*#') { return }
    if ($_ -match '^\s*$') { return }
    if ($_ -match '^\s*([^=]+?)\s*=\s*(.*)\s*$') {
        $name = $Matches[1]
        $value = $Matches[2]
        Set-Item -Path "Env:$name" -Value $value
    }
}

if (-not $env:GOMAPI_OAUTH_CLIENT_ID -or -not $env:GOMAPI_OAUTH_CLIENT_SECRET) {
    Write-Error "GOMAPI_OAUTH_CLIENT_ID and GOMAPI_OAUTH_CLIENT_SECRET must both be set in $envFile"
}

Push-Location (Join-Path $repoRoot 'src' 'app')
try {
    wails dev
} finally {
    Pop-Location
}
