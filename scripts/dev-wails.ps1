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
    # Go 1.26 Windows/ARM64 + `wails dev` / `wails build -debug` triggers a
    # `syscall.Syscall15: nosplit stack over 792 byte limit` compile error under
    # `-gcflags "all=-N -l"`. Build production with devtools instead — same
    # env-var credential fallback (auth_credentials.go init()) drives both paths.
    # Trade-off: no hot reload; rerun this script after editing Go/Svelte code.
    Write-Host 'Building go-mapi (production + devtools)...'
    wails build -devtools
    if ($LASTEXITCODE -ne 0) { throw 'wails build failed' }

    $binary = Join-Path (Get-Location) 'build' 'bin' 'go-mapi.exe'
    if (-not (Test-Path $binary)) { throw "Binary not produced at $binary" }

    Write-Host "Launching $binary..."
    & $binary
    if ($LASTEXITCODE -ne 0) { throw "go-mapi exited with code $LASTEXITCODE" }
} finally {
    Pop-Location
}
