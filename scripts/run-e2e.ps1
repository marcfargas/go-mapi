<#
.SYNOPSIS
  Build the e2e-tagged Wails binary and run the Playwright suite.

.DESCRIPTION
  Phase 11 plan 06. Builds src/app/build/bin/go-mapi.exe with -tags e2e and
  ldflags-injected fake OAuth credentials so checkOAuthCredentials() does
  not fatal-exit. Then invokes `npm run e2e` from the repo root.

.PARAMETER NoBuild
  Skip the wails build step. Use when iterating on test code without Go
  changes — the harness still requires the binary at the expected path.

.PARAMETER SmokeOnly
  Run only smoke.spec.ts. Used by Task 2's acceptance check to prove the
  harness boots before the full regression suite is added in Task 3.

.PARAMETER InstallDeps
  Run `npm install` before testing. The first invocation on a fresh clone
  needs this to fetch @playwright/test + browser binaries.
#>
[CmdletBinding()]
param(
  [switch]$NoBuild,
  [switch]$SmokeOnly,
  [switch]$InstallDeps
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $repoRoot

if ($InstallDeps) {
  Write-Host '[run-e2e] npm install (root workspaces)…' -ForegroundColor Cyan
  npm install
  if ($LASTEXITCODE -ne 0) { throw "npm install failed ($LASTEXITCODE)" }

  Write-Host '[run-e2e] playwright install chromium…' -ForegroundColor Cyan
  npm exec --workspace=@marcfargas/go-mapi-e2e -- playwright install chromium
  if ($LASTEXITCODE -ne 0) { throw "playwright install failed ($LASTEXITCODE)" }
}

if (-not $NoBuild) {
  Write-Host '[run-e2e] building e2e-tagged Wails binary…' -ForegroundColor Cyan
  Push-Location (Join-Path $repoRoot 'src/app')
  try {
    # ldflags injects fake OAuth creds so checkOAuthCredentials() passes.
    # The values are clearly-fake markers (T-11-06-02 mitigation).
    $ldflags = @(
      '-X', 'main.Version=e2e',
      '-X', 'main.oauthClientID=e2e-fake-client-do-not-use',
      '-X', 'main.oauthClientSecret=e2e-fake-secret-do-not-use',
      '-s', '-w'
    ) -join ' '

    & wails build -platform windows/amd64 -tags e2e -ldflags $ldflags -clean
    if ($LASTEXITCODE -ne 0) { throw "wails build failed ($LASTEXITCODE)" }
  } finally {
    Pop-Location
  }
}

$binary = Join-Path $repoRoot 'src/app/build/bin/go-mapi.exe'
if (-not (Test-Path $binary)) {
  throw "expected $binary after build but it does not exist"
}
Write-Host "[run-e2e] binary at $binary" -ForegroundColor Green

# Belt-and-braces: kill any orphan go-mapi.exe from a previous failed run
# (the single-instance mutex would block our spawn otherwise — T-11-06-03).
Get-Process -Name 'go-mapi' -ErrorAction SilentlyContinue | ForEach-Object {
  Write-Host "[run-e2e] killing orphan go-mapi.exe pid=$($_.Id)" -ForegroundColor Yellow
  Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

Write-Host '[run-e2e] running Playwright…' -ForegroundColor Cyan
if ($SmokeOnly) {
  npm exec --workspace=@marcfargas/go-mapi-e2e -- playwright test smoke.spec.ts
} else {
  npm run e2e
}
$exitCode = $LASTEXITCODE

# Final cleanup pass — any test that crashed mid-run leaves orphans.
Get-Process -Name 'go-mapi' -ErrorAction SilentlyContinue | ForEach-Object {
  Write-Host "[run-e2e] post-run cleanup pid=$($_.Id)" -ForegroundColor Yellow
  Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

exit $exitCode
