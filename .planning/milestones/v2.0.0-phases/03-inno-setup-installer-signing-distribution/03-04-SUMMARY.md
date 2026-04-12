---
plan: 03-04
phase: 03
status: complete
completed: 2026-04-10
commits:
  - 2a85141 ci(03-04): add Pester 5 installer smoke test and CI workflow (INST-07)
---

# Plan 03-04 Summary: Pester 5 installer smoke test + CI workflow

## What shipped

- `src/installer/tests/installer.Tests.ps1` — ~130-line Pester 5 test
  exercising a full install → verify → uninstall → verify round-trip
  against `src/installer/dist/go-mapi-setup.exe`.
- `.github/workflows/installer-smoke.yml` — 110-line GitHub Actions
  workflow that installs build prerequisites, builds the binaries and
  installer inline, runs the Pester test, and uploads results +
  installer artifact.

## Requirements satisfied

- **INST-07**: The Pester 5 test runs on a fresh `windows-latest` runner
  and verifies:
  - Silent install via `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=...`
    exits 0 and writes the log file.
  - `go-mapi.dll` and `go-mapi-host.exe` are present under
    `%ProgramFiles%\go-mapi`.
  - `HKLM\SOFTWARE\Clients\Mail\go-mapi` exists with a `DLLPath` that
    resolves to a real file.
  - `HKLM\SOFTWARE\Clients\Mail (Default)` equals `go-mapi`.
  - `%ProgramData%\go-mapi\com.gomapi.host.json` exists and parses as a
    native-messaging manifest (`name`, `type`, `path`, `allowed_origins`).
  - All five browser registry trees (Chrome, Chromium, Edge, Brave,
    Vivaldi) exist under HKLM and point at the shared manifest path.
  - Previous-mail-client backup JSON is permissive: if present, must
    contain `previousClient` and `backedUpAt` fields; if absent, the
    `uninst` directory must still exist (covers fresh-runner "no prior
    client" state).
  - Silent uninstall via `unins000.exe /VERYSILENT /SUPPRESSMSGBOXES
    /NORESTART` exits 0.
  - All five browser registry trees removed.
  - MAPI handler key removed.
  - Shared manifest file removed.
  - Backup JSON removed.
  - Install directory is empty or gone.

## Notable decisions

- **Inline build in the smoke workflow**: the workflow does not depend
  on `build.yml` or `release.yml` artifacts. A single job: check out →
  install toolchain via Chocolatey → build interceptor DLL → build Go
  host → compile installer with `iscc.exe` → run Pester. This keeps
  test-failure triage in one log file and lets a PR touching only
  installer files exercise the full round-trip.
- **Path filters on triggers**: the workflow runs only when
  `src/installer/**`, `src/interceptor/**`, `src/native-host/**`, or the
  workflow file itself changes. Avoids burning runner minutes on
  extension-only or docs-only PRs.
- **Pester 5 configuration object**: uses `New-PesterConfiguration` →
  `$config.Run.Path`, `$config.Run.Exit`, `$config.Output.Verbosity`,
  `$config.TestResult.Enabled` + `OutputPath` + `OutputFormat` →
  `Invoke-Pester -Configuration $config`. This is the current Pester 5
  idiom; the older `Invoke-Pester script.ps1 -EnableExit` (Pester 4) is
  explicitly avoided per plan.
- **Permissive previous-client backup test**: `windows-latest` runners
  may not have a default Mail client set at all. The installer's
  `BackupPreviousMailClient()` deliberately skips the write when the
  current value is empty (per CONTEXT D-09), so the test accepts either
  outcome — backup exists and is valid, OR backup is absent and the
  `uninst` directory is still created (via `[Dirs]`).
- **Permissive install-dir-gone test**: Inno Setup may leave an empty
  directory if any untracked file (e.g. the install log) remains in it.
  The test accepts either "dir gone" or "dir present but contains no
  files".

## Verification

- **Grep checks**: all acceptance-criteria patterns match in both
  `installer.Tests.ps1` and `installer-smoke.yml`. All five browser
  registry paths present in the test fixture array (via `grep -c
  'NativeMessagingHosts'` → 5).
- **PowerShell parse check**: executed on the executor host via
  `pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile(...)"`
  — returned `parse OK` with no syntax errors.
- **`iscc.exe` not available on executor host**: the smoke workflow's
  `iscc.exe` step is not pre-verified; it will run on the first
  push/PR and surface any `.iss` syntax problems at that point.
- **Pester execution not pre-verified**: the test cannot run locally
  without Administrator rights and a built installer, both of which are
  out of scope for the executor sandbox. Will run in CI.

## Known gaps

- **First CI run is the real verification**. The smoke workflow runs
  inline without prior artifacts, so a failing `.iss` script or a
  Pester assertion mismatch surfaces on the first PR touching the
  installer files. This is expected given the plan's "no local Inno
  Setup" constraint.
- **No fuzz on the manifest ExtensionId**: the test checks the shape of
  the rendered manifest but does not assert the specific extension ID.
  This is deliberate — `GO_MAPI_EXTENSION_ID` is a placeholder until
  the Chrome Web Store listing is published, and a Pester test against
  the literal placeholder value would need updating at the same time
  as the extension ID swap. Instead the test verifies
  `allowed_origins.Count >= 1` which catches a malformed/empty
  `allowed_origins` array without coupling to the specific ID value.
