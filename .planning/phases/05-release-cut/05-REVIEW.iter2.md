---
phase: 05-release-cut
reviewed: 2026-04-11T00:00:00Z
depth: standard
files_reviewed: 6
files_reviewed_list:
  - README.md
  - src/interceptor/json_writer.h
  - tests/sandbox/README.md
  - tests/sandbox/install-and-verify.ps1
  - tests/sandbox/run-sandbox-test.ps1
  - tests/sandbox/sandbox.wsb
findings:
  critical: 0
  warning: 2
  info: 6
  total: 8
status: issues_found
---

# Phase 05: Code Review Report

**Reviewed:** 2026-04-11
**Depth:** standard
**Files Reviewed:** 6
**Status:** issues_found

## Summary

Phase 5 is a release-cut phase: a one-character C++ comment fix, a README
rewrite for the v2.0.0 end-user install flow, and a Windows Sandbox harness
(REL-02) for local install -> verify -> uninstall reproduction. The core
changes are sound — the `-Wcomment` fix is correct, the installer-smoke
registry assertions mirror `src/installer/go-mapi.iss`, the five native-
messaging host registry keys listed in README match the `.iss` `[Registry]`
section, and the documented direct-download URL pattern is valid.

Two **warnings** concern the `run-sandbox-test.ps1` orchestrator: (1) a
documentation/code mismatch where `-FullTest` unconditionally runs
`setup.ps1` (WinAppDriver install) even though `tests/sandbox/README.md`'s
"Full path" narrative describes the flow without that step, and (2) a
fragile `ConvertFrom-Json` on the `wsb list --raw` output with merged
stderr that can throw under `$ErrorActionPreference = "Stop"` when the CLI
emits a non-JSON diagnostic on first run. Neither blocks the release but
both will bite a contributor reproducing a CI failure locally — the core
use case of this harness.

The remaining six findings are informational: minor documentation drift,
one missing post-uninstall verification (the `previous-mail-client.json`
backup isn't checked for deletion), step-counter drift in
`run-sandbox-test.ps1` (`[1/4]..[4/4]` then `[5/5]`), and a couple of
cross-reference polish items.

No security issues, no hardcoded secrets, no injection vectors. The
sandbox harness is read-only by design (host-side) and writes only to a
dedicated per-run output folder under `$env:TEMP`.

## Warnings

### WR-01: `-FullTest` runs `setup.ps1` but `tests/sandbox/README.md` does not document this

**File:** `tests/sandbox/run-sandbox-test.ps1:113`
**Issue:** The orchestrator unconditionally runs WinAppDriver setup when
`$FullTest` is set:

```powershell
if ($SetupOnly -or $FullTest) {
    Write-Host "`n[4/4] Running setup (WinAppDriver)..."
    $setupSuccess = Invoke-SandboxCommand `
        -Command "powershell -ExecutionPolicy Bypass -File C:\go-mapi\tests\sandbox\setup.ps1" `
        ...
}
```

However, `tests/sandbox/README.md:62-74` describes the `-FullTest` flow as
a clean 8-step list that starts with "Stops any existing sandbox", runs
`test-dll-registration.ps1`, then `install-and-verify.ps1`, and stops the
sandbox. WinAppDriver setup is never mentioned. This creates three issues:

1. Contributors expecting a ~5 min flow hit an unexplained WinAppDriver
   install step that can fail on sandbox network hiccups and abort the
   whole run.
2. The REL-02 scope (install -> verify -> uninstall) does not need
   WinAppDriver — the `install-and-verify.ps1` runner has no UI
   automation dependency.
3. If `setup.ps1` fails, `$setupSuccess` is captured but never checked
   (the `if ($SetupOnly)` branch exits early, but the `-FullTest` path
   falls through to `[5/5]` regardless of setup success).

**Fix:** Decouple setup from `-FullTest`. Only run `setup.ps1` when
`$SetupOnly` is explicitly set, OR introduce a new `-WithUIAutomation`
switch for the legacy path. Recommended minimal fix:

```powershell
# Run setup (WinAppDriver install) — only when explicitly requested
if ($SetupOnly) {
    Write-Host "`n[4/5] Running setup (WinAppDriver)..."
    $setupSuccess = Invoke-SandboxCommand `
        -Command "powershell -ExecutionPolicy Bypass -File C:\go-mapi\tests\sandbox\setup.ps1" `
        -Description "WinAppDriver setup"

    if (-not $setupSuccess) {
        Write-Host "=== SETUP FAILED ===" -ForegroundColor Red
        if (-not $KeepRunning) { wsb stop --id $sandboxId 2>&1 | Out-Null }
        exit 1
    }
    # ... existing early-exit block
}
```

Drop the `-or $FullTest` from the guard. The REL-02 full flow has no
UI-automation dependency and runs strictly faster without it.

---

### WR-02: `wsb list --raw` output piped to `ConvertFrom-Json` with merged stderr can throw under `Stop` preference

**File:** `tests/sandbox/run-sandbox-test.ps1:25`
**Issue:**

```powershell
$existing = wsb list --raw 2>&1 | ConvertFrom-Json
```

With `$ErrorActionPreference = "Stop"` (line 11), any non-JSON line on
stderr — a warning, a deprecation notice, a first-run "Telemetry is
enabled" banner, a `wsb` update nag — gets merged into stdout via `2>&1`
and fed to `ConvertFrom-Json`, which throws `Conversion from JSON failed`.
The orchestrator then dies at the pre-flight check, before even trying
to start the sandbox, with a cryptic error that looks unrelated to `wsb`.

This is the exact kind of failure a contributor running the harness for
the first time on a fresh marcwin clone will hit, and it defeats the
"fast local feedback loop" goal the README advertises.

**Fix:** Separate stdout and stderr, and guard the JSON parse:

```powershell
# Check for existing sandbox
try {
    $listOutput = wsb list --raw 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($listOutput)) {
        $existing = $null
    } else {
        $existing = $listOutput | ConvertFrom-Json -ErrorAction Stop
    }
} catch {
    Write-Host "WARNING: Could not parse 'wsb list --raw' output: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Continuing — assuming no existing sandbox." -ForegroundColor Yellow
    $existing = $null
}

if ($existing -and $existing.WindowsSandboxEnvironments.Count -gt 0) {
    Write-Host "WARNING: Existing sandbox found. Stopping it..." -ForegroundColor Yellow
    foreach ($sb in $existing.WindowsSandboxEnvironments) {
        wsb stop --id $sb.Id 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 2
}
```

Apply the same pattern to the `wsb start --raw` parse on line 36 — it
has the identical failure shape.

---

## Info

### IN-01: Step counter drift in `run-sandbox-test.ps1`

**File:** `tests/sandbox/run-sandbox-test.ps1:35, 46, 78, 114, 143`
**Issue:** The script prints step banners `[1/4]` (start), `[2/4]`
(share), `[3/4]` (DLL test), `[4/4]` (setup), then jumps to `[5/5]`
(install-and-verify). The "N of 4" denominator is wrong for any path
that reaches step `[5/5]`. A contributor reading the output sees the
counter reset and assumes something is re-running.

**Fix:** Pick a single denominator (or compute it from the switches).
Simplest: change all banners to use a consistent `[N/5]` pattern, or
drop the "of N" and just number sequentially:

```powershell
Write-Host "`n[1] Starting Windows Sandbox..."
Write-Host "`n[2] Sharing project folder..."
# ...
```

---

### IN-02: `install-and-verify.ps1` skips `previous-mail-client.json` in post-uninstall cleanup check

**File:** `tests/sandbox/install-and-verify.ps1:109-111`
**Issue:** The post-uninstall verification loop only checks three files:

```powershell
foreach ($f in @("$env:ProgramFiles\go-mapi\go-mapi.dll",
                 "$env:ProgramFiles\go-mapi\go-mapi-host.exe",
                 "$env:ProgramData\go-mapi\com.gomapi.host.json")) {
```

The post-install check (line 69-74) verifies four files, including
`$env:ProgramData\go-mapi\uninst\previous-mail-client.json`. The
backup file is intentionally preserved during a normal uninstall so
users can roll back — the `.iss` script restores the previous default
mail client from it. That's legitimate, but the current code silently
drops the file from the check list with no comment, so a reviewer has
to dig into `go-mapi.iss` to figure out the asymmetry.

**Fix:** Add an explicit comment (and ideally an assertion that the
backup file either (a) is gone because the uninstaller restored and
cleaned it, or (b) still exists — whichever the release contract
actually is):

```powershell
# Note: previous-mail-client.json is intentionally excluded here.
# The Inno Setup uninstaller uses it to restore the previous default
# Mail client; whether it survives or is deleted after restore is
# documented in src/installer/go-mapi.iss [UninstallDelete].
foreach ($f in @("$env:ProgramFiles\go-mapi\go-mapi.dll",
                 "$env:ProgramFiles\go-mapi\go-mapi-host.exe",
                 "$env:ProgramData\go-mapi\com.gomapi.host.json")) {
```

If the release contract is "delete after restore", add the file back
to the assertion list.

---

### IN-03: `sandbox.wsb` missing XML declaration and trailing newline

**File:** `tests/sandbox/sandbox.wsb:1`
**Issue:** The file opens with `<Configuration>` and ends with
`</Configuration>` on line 17 with no trailing newline. Windows Sandbox
accepts this, but:

1. Some editors (and `git diff`) mark the missing final newline
   (`\ No newline at end of file`) on every future edit.
2. A leading `<?xml version="1.0" encoding="UTF-8"?>` declaration is the
   Windows Sandbox convention shown in Microsoft's own docs and will
   help XML-aware tooling (linters, IDEs) validate the file.

**Fix:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
    <VGpu>Disable</VGpu>
    ...
</Configuration>
```

Also ensure the file ends with a single LF after `</Configuration>`.

---

### IN-04: README `taskkill && start explorer.exe` command is shell-specific

**File:** `README.md:237`
**Issue:** The troubleshooting bullet shows
`taskkill /im explorer.exe /f && start explorer.exe`. `&&` is a
`cmd.exe`/pwsh-7+ operator — Windows PowerShell 5.1 (which ships with
Windows 10/11 by default and is what non-technical users will have
open) does not support it and will error with
`The token '&&' is not a valid statement separator in this version`.
Since the README's audience for this section is end users troubleshooting
a failed install, they're most likely in the default `powershell.exe`.

**Fix:** Either label the command explicitly as cmd-only, or split it:

```
- **"Send to → Mail recipient" doesn't appear** — restart Windows
  Explorer from an elevated `cmd.exe`:
  `taskkill /im explorer.exe /f && start explorer.exe`
  (or from PowerShell:
  `Stop-Process -Name explorer -Force; Start-Process explorer`).
```

---

### IN-05: `Invoke-SandboxCommand` parameter splatting is brittle for commands with spaces

**File:** `tests/sandbox/run-sandbox-test.ps1:68`
**Issue:**

```powershell
$result = wsb exec --id $sandboxId --command $Command --run-as System --raw 2>&1 | ConvertFrom-Json
```

`$Command` is a single string passed to `--command`. All current
callers use paths without spaces (`C:\go-mapi\tests\sandbox\*.ps1`),
so this works, but it sets a trap: the day someone adds a test script
under a path with spaces or needs to pass arguments with spaces,
quoting will silently break. Same `ConvertFrom-Json`-on-merged-stderr
failure mode as WR-02 applies here.

**Fix:** Wrap the command value in explicit quotes inside the string,
or switch to `--command-file` (if the `wsb` CLI supports it), and
apply the defensive JSON parse from WR-02:

```powershell
function Invoke-SandboxCommand {
    param(
        [string]$Command,
        [string]$Description,
        [switch]$AllowFailure
    )
    Write-Host "`n> $Description"
    $raw = wsb exec --id $sandboxId --command $Command --run-as System --raw 2>$null
    try {
        $result = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host "FAILED: could not parse wsb exec output: $raw" -ForegroundColor Red
        return $false
    }
    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        Write-Host "FAILED: Exit code $($result.ExitCode)" -ForegroundColor Red
        return $false
    }
    Write-Host "OK: Exit code $($result.ExitCode)" -ForegroundColor Green
    return $true
}
```

---

### IN-06: `tests/sandbox/README.md` prerequisite claims pwsh 7+ but invoked scripts run under `powershell.exe`

**File:** `tests/sandbox/README.md:19-21`
**Issue:** The README lists

> **PowerShell 7+** (`pwsh`) — used by `run-sandbox-test.ps1`. Windows
> PowerShell 5.1 will parse but the harness uses `-raw` JSON output from
> `wsb` which is easier to handle in pwsh.

This is partly accurate (host-side `run-sandbox-test.ps1` is cleaner in
pwsh 7) but the *in-sandbox* runners are invoked via
`powershell -ExecutionPolicy Bypass -File ...` (lines 80, 116, 157 of
`run-sandbox-test.ps1`), i.e. Windows PowerShell 5.1. A reader of the
README might install pwsh 7 inside the sandbox thinking it's required,
which is unnecessary work (and pwsh isn't in a vanilla sandbox image).

**Fix:** Clarify the scope:

```markdown
- **PowerShell 7+ (`pwsh`) on the HOST** — used to run
  `run-sandbox-test.ps1`. Windows PowerShell 5.1 will parse it but the
  `wsb list --raw` / `wsb exec --raw` JSON handling is cleaner in pwsh 7.
  Scripts running INSIDE the sandbox (`install-and-verify.ps1`,
  `test-dll-registration.ps1`) use the stock Windows PowerShell 5.1 that
  ships in every sandbox image — no pwsh needed inside.
```

---

_Reviewed: 2026-04-11_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
