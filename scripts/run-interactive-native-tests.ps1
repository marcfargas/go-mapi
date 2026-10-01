# Runs the Windows Go test suite exactly as the `go-race` job in
# .github/workflows/ci.yml does. The `go test` line below is a verbatim copy of
# that job's command; change both in the same commit
# (scripts/tests/InteractiveScripts.Tests.ps1 checks that they are identical).
#
# Requires an interactive Windows desktop logon and an elevated shell
# (./src/service/... opens the Service Control Manager), Go 1.25+, a C
# toolchain for -race (`just prepare-windows -Native`) and a built
# src/app/frontend/dist (`just build-frontend`).
#
# ci.yml does not run this script: hosted runners have no interactive desktop.
# Any caller runs the script and reads its exit code, which is the exit code
# of `go test`.
#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

# ci.yml sets CGO_ENABLED at job level; -race needs it.
$env:CGO_ENABLED = '1'

# src/app/main.go embeds frontend/dist; without it ./src/app/... fails to compile
# with an obscure error, so stop early with a clear one.
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'src/app/frontend/dist'))) {
    [Console]::Error.WriteLine('src/app/frontend/dist is missing; run `just build-frontend` first.')
    exit 1
}

Push-Location $repoRoot
try {
    go test -race -v ./internal/mapi/... ./src/app/... ./src/service/...
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $code
