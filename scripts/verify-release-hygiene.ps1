<#
.SYNOPSIS
  Fail if the release build pipeline would embed e2e test hooks.

.DESCRIPTION
  Phase 11 plan 06 CI guard. The e2e harness relies on two knobs:

    1. The `-tags e2e` build tag, which compiles src/app/auth_e2e.go —
       that file swaps the Windows Credential Manager keyring for an
       in-memory fake populated from GOMAPI_E2E_FAKE_TOKEN_JSON.
    2. The GOMAPI_DEBUG_BROWSER_ARGS env var, honored by our vendored
       go-webview2 fork (src/app/vendor/go-webview2-e2e) to forward
       --remote-debugging-port=... to WebView2.

  Neither may appear in the release artifact. This script greps the
  installer-release workflow for both markers and exits non-zero if
  anything is found. It is meant to run as a workflow step on every
  release-tag push before binaries are built.

.PARAMETER WorkflowPath
  Path to the release workflow YAML. Defaults to
  .github/workflows/installer-release.yml.

.PARAMETER BuildEnvDump
  Optional path to a file containing a dump of `env` (or PowerShell
  Get-ChildItem Env:) captured during the build job. When provided, the
  script also asserts GOMAPI_DEBUG_BROWSER_ARGS is absent from the dump.
#>
[CmdletBinding()]
param(
  [string]$WorkflowPath = ".github/workflows/installer-release.yml",
  [string]$BuildEnvDump = ""
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $repoRoot

$failed = $false

function Fail($msg) {
  Write-Host "[release-hygiene] FAIL: $msg" -ForegroundColor Red
  $script:failed = $true
}

function Pass($msg) {
  Write-Host "[release-hygiene] OK:   $msg" -ForegroundColor Green
}

if (-not (Test-Path $WorkflowPath)) {
  Fail "workflow not found: $WorkflowPath"
  exit 1
}

# Strip YAML comment-only lines before grepping so the guard does not
# flag its own explanatory comments. A line is a comment-only line when
# (after optional leading whitespace) the first non-whitespace character
# is '#'. This still catches inline comments appended to a command
# (e.g. `run: wails build ... # -tags e2e` would be flagged) while
# leaving descriptive narrative blocks untouched.
$rawLines = Get-Content $WorkflowPath
$codeLines = $rawLines | Where-Object { $_ -notmatch '^\s*#' }
$workflowCode = $codeLines -join "`n"

# 1. The release workflow must not pass -tags e2e to the Go build.
if ($workflowCode -match '-tags\s+[^\s]*e2e') {
  Fail "installer-release workflow contains '-tags e2e' — this would ship test hooks in production"
} else {
  Pass "no '-tags e2e' in installer-release workflow"
}

# 2. The release workflow must not export GOMAPI_DEBUG_BROWSER_ARGS.
if ($workflowCode -match 'GOMAPI_DEBUG_BROWSER_ARGS') {
  Fail "installer-release workflow references GOMAPI_DEBUG_BROWSER_ARGS — this would expose WebView2 CDP in release builds"
} else {
  Pass "no GOMAPI_DEBUG_BROWSER_ARGS in installer-release workflow"
}

# 3. Likewise for GOMAPI_E2E_* overrides.
if ($workflowCode -match 'GOMAPI_E2E_') {
  Fail "installer-release workflow references GOMAPI_E2E_* — e2e fakes must never reach release builds"
} else {
  Pass "no GOMAPI_E2E_* env vars in installer-release workflow"
}

# 4. Optional: scan an env dump captured at build time.
if ($BuildEnvDump -and (Test-Path $BuildEnvDump)) {
  $envContent = Get-Content $BuildEnvDump -Raw
  if ($envContent -match 'GOMAPI_DEBUG_BROWSER_ARGS') {
    Fail "build env dump ($BuildEnvDump) contains GOMAPI_DEBUG_BROWSER_ARGS"
  } else {
    Pass "build env dump has no GOMAPI_DEBUG_BROWSER_ARGS"
  }
  if ($envContent -match 'GOMAPI_E2E_') {
    Fail "build env dump ($BuildEnvDump) contains GOMAPI_E2E_*"
  } else {
    Pass "build env dump has no GOMAPI_E2E_* vars"
  }
} else {
  Write-Host "[release-hygiene] INFO: no BuildEnvDump provided — skipping env dump scan" -ForegroundColor Yellow
}

if ($failed) {
  Write-Host "[release-hygiene] one or more checks failed" -ForegroundColor Red
  exit 1
}

Write-Host "[release-hygiene] all release-hygiene checks passed" -ForegroundColor Green
exit 0
