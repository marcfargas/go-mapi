# scripts/build-wails.ps1 -- Wails production build with OAuth ldflags injection.
#
# QUICK-260423-olq.
#
# Reads GOMAPI_OAUTH_CLIENT_ID and GOMAPI_OAUTH_CLIENT_SECRET from the repo-root
# `.env.local` file (gitignored) and passes them to `wails build` via
# -ldflags "-X main.oauthClientID=... -X main.oauthClientSecret=...". Without
# this injection, the Wails binary's startup guard in src/app/credentials_check.go
# fatals with "OAuth client_id missing -- build was not wired correctly".
#
# Secret hygiene:
#   - The secret value is read into a local variable and passed to the child
#     process. It is NEVER printed, logged, or written to a file we commit.
#   - On failure, error messages reference the VARIABLE NAME (not the value).
#   - If you pipe this script's stdout/stderr to a log, no secret will leak.
#
# CC / CXX override (ARM64 host compatibility):
#   On Marc's ARM64 Windows dev machine, the plain `gcc` shim points at a
#   bare-metal aarch64-none-elf toolchain that cannot produce x86_64 Windows
#   binaries. Go's cgo must therefore be told to use the triple-prefixed
#   mstorsjo clang explicitly. We set CC / CXX in this script's environment
#   (child inherits); on x86_64 hosts this is a no-op because `gcc` there
#   would already produce x86_64.

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Platform = 'windows/amd64',
    [string]$EnvFile  = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Resolve script directory manually. $PSScriptRoot is unreliable inside param
# default expressions in PS 5.1; compute it here instead.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrEmpty($EnvFile)) {
    $EnvFile = Join-Path $ScriptDir '..\.env.local'
}

# 1) Locate and parse .env.local (repo root by default)
$EnvFile = [System.IO.Path]::GetFullPath($EnvFile)
if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-Error "Missing env file: $EnvFile. Create it with GOMAPI_OAUTH_CLIENT_ID=... and GOMAPI_OAUTH_CLIENT_SECRET=... (gitignored)."
    exit 1
}

$required = @('GOMAPI_OAUTH_CLIENT_ID', 'GOMAPI_OAUTH_CLIENT_SECRET')
$values   = @{}

foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
    $trimmed = $line.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
    $eq = $trimmed.IndexOf('=')
    if ($eq -lt 1) { continue }
    $k = $trimmed.Substring(0, $eq).Trim()
    $v = $trimmed.Substring($eq + 1)
    # Strip surrounding quotes if present -- tolerate both shapes
    if (($v.StartsWith('"') -and $v.EndsWith('"')) -or
        ($v.StartsWith("'") -and $v.EndsWith("'"))) {
        $v = $v.Substring(1, $v.Length - 2)
    }
    $values[$k] = $v
}

$missing = $required | Where-Object { -not $values.ContainsKey($_) -or [string]::IsNullOrEmpty($values[$_]) }
if ($missing) {
    Write-Error "Missing required variable(s) in $EnvFile : $($missing -join ', ')"
    exit 1
}

# 2) Build ldflags string. Values are passed to wails via the arg array so
# cmd.exe never re-parses them. We never echo the values.
$ldflags = @(
    "-X `"main.oauthClientID=$($values['GOMAPI_OAUTH_CLIENT_ID'])`"",
    "-X `"main.oauthClientSecret=$($values['GOMAPI_OAUTH_CLIENT_SECRET'])`""
) -join ' '

# 3) CC / CXX override for ARM64 hosts. If the triple-prefixed binaries are on
# PATH we prefer them explicitly; otherwise leave the env alone (x86_64 hosts
# with a matching `gcc` in PATH will Just Work).
$ccCandidate  = Get-Command 'x86_64-w64-mingw32-clang'   -ErrorAction SilentlyContinue
$cxxCandidate = Get-Command 'x86_64-w64-mingw32-clang++' -ErrorAction SilentlyContinue
if ($ccCandidate)  { $env:CC  = $ccCandidate.Source }
if ($cxxCandidate) { $env:CXX = $cxxCandidate.Source }

# 4) Invoke wails build. cd into src/app for wails.json resolution.
$appDir = Join-Path $ScriptDir '..\src\app'
$appDir = [System.IO.Path]::GetFullPath($appDir)
Push-Location $appDir
try {
    Write-Host "[build-wails] Platform: $Platform"
    Write-Host "[build-wails] CC:       $(if ($env:CC)  { $env:CC }  else { '(default)' })"
    Write-Host "[build-wails] CXX:      $(if ($env:CXX) { $env:CXX } else { '(default)' })"
    Write-Host "[build-wails] ldflags:  (oauth vars set -- values redacted)"
    & wails build -platform $Platform -ldflags $ldflags
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Write-Error "wails build exited with code $rc"
        exit $rc
    }
} finally {
    Pop-Location
}
