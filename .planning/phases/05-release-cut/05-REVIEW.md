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
  warning: 0
  info: 6
  total: 6
status: issues_found
---

# Phase 05: Code Review Report (re-review)

**Reviewed:** 2026-04-11
**Depth:** standard
**Files Reviewed:** 6
**Status:** issues_found (info only — no bugs, no security issues)

## Summary

Re-review of Phase 5 after commits `17003a6` (WR-02) and `a523bda` (WR-01)
on `tests/sandbox/run-sandbox-test.ps1`. Both warnings from the previous
REVIEW.md are **resolved** and no new bugs were introduced. The six info
items from the previous review remain — they are pre-existing polish
items unrelated to the two fixes — so the status drops from `issues_found
(2W/6I)` to `issues_found (0W/6I)`.

### Fix verification

**WR-01 (a523bda) — decouple `setup.ps1` from `-FullTest`: RESOLVED.**
- Line 144 now reads `if ($SetupOnly)` — the previous `$SetupOnly -or
  $FullTest` guard was replaced, so the WinAppDriver setup step runs only
  when explicitly requested. Lines 139-143 document the rationale with an
  explicit WR-01 back-reference.
- The `-FullTest` code path now skips the setup step entirely and goes
  directly from `[3/4]` (DLL registration) to `[5/5]` (install-and-verify),
  matching the 8-step flow documented in `tests/sandbox/README.md:61-74`.
- The dead-branch bug (setup failure not aborting the run) is also gone:
  the `if (-not $setupSuccess)` check at line 160 is now inside the
  `$SetupOnly` block and correctly exits with code 1 on failure.
- No new issues: the two consecutive `if ($SetupOnly)` blocks
  (lines 144-165 setup, 167-176 "SETUP COMPLETE" + exit) are stylistically
  awkward but semantically correct — both execute only under `-SetupOnly`,
  in order, and the second one short-circuits the fall-through into the
  `-FullTest` block below.

**WR-02 (17003a6) — defensive `wsb --raw` JSON parse: RESOLVED.**
- Lines 28-39: `wsb list --raw` now uses `2>$null` (separating stderr),
  guards on `$LASTEXITCODE` and `IsNullOrWhiteSpace`, wraps the
  `ConvertFrom-Json` in a `try`/`catch`, and continues with a warning on
  parse failure. Correct semantics for the pre-flight "is there an
  existing sandbox?" check — a parse failure should not abort the run.
- Lines 52-63: the same pattern is applied to `wsb start --raw`, with the
  correct difference that a parse failure here is fatal (`exit 1`) because
  the sandbox ID is required for everything downstream. The error path
  dumps the raw output for debugging.
- `-ErrorAction Stop` on `ConvertFrom-Json` is redundant under
  `$ErrorActionPreference = "Stop"` but harmless — it makes the intent
  explicit and is defensive against future preference-scope changes.
- No new issues: `$startRaw` is referenced inside the `catch` at line 61,
  but it's assigned on line 53 before any parse can fail, so it is always
  defined by the time the `catch` runs.
- Out of scope by design: `Invoke-SandboxCommand` at line 95 still uses
  the old `2>&1 | ConvertFrom-Json` pattern. This was previously flagged
  as IN-05 (info) and is preserved below — the WR-02 fix scope was
  explicitly the two host-side `--raw` calls, not the in-sandbox exec
  wrapper.

### Remaining findings

Six info items carry over unchanged from the previous review. None of the
files they reference were modified by the two fix commits, so every
citation still resolves to the same line. No bugs, no security issues, no
hardcoded secrets, no injection vectors.

## Info

### IN-01: Step counter drift in `run-sandbox-test.ps1`

**File:** `tests/sandbox/run-sandbox-test.ps1:50, 73, 105, 145, 180`
**Issue:** The script prints step banners `[1/4]` (start), `[2/4]`
(share), `[3/4]` (DLL test), `[4/4]` (setup, only under `-SetupOnly`),
then `[5/5]` (install-and-verify, only under `-FullTest`). The "N of 4"
denominator is wrong for any path that reaches step `[5/5]`, and under
`-FullTest` the `[4/4]` step is skipped entirely — so the user sees
`[1/4] → [2/4] → [3/4] → [5/5]`, which is jarring.

The WR-01 fix actually made this slightly more visible: under
`-FullTest`, `[4/4]` no longer prints at all, so the counter jumps
from 3 to 5.

**Fix:** Pick a single denominator (or compute it from the switches).
Simplest: drop the "of N" and just number sequentially:

```powershell
Write-Host "`n[1] Starting Windows Sandbox..."
Write-Host "`n[2] Sharing project folder..."
Write-Host "`n[3] Testing DLL registration..."
Write-Host "`n[4] Running setup (WinAppDriver)..."   # only under -SetupOnly
Write-Host "`n[5] Running REL-02 install -> verify -> uninstall flow..."
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

The post-install check (lines 69-74) verifies four files, including
`$env:ProgramData\go-mapi\uninst\previous-mail-client.json`. The backup
file is intentionally preserved during a normal uninstall so the
uninstaller can restore the previous default mail client from it. That's
legitimate, but the current code silently drops the file from the check
list with no comment, so a reviewer has to dig into `go-mapi.iss` to
figure out the asymmetry.

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

If the release contract is "delete after restore", add the file back to
the assertion list.

---

### IN-03: `sandbox.wsb` missing XML declaration and trailing newline

**File:** `tests/sandbox/sandbox.wsb:1`
**Issue:** The file opens with `<Configuration>` and ends with
`</Configuration>` on line 17. Windows Sandbox accepts this, but:

1. Some editors (and `git diff`) flag the missing final newline
   (`\ No newline at end of file`) on every future edit.
2. A leading `<?xml version="1.0" encoding="UTF-8"?>` declaration is the
   Windows Sandbox convention shown in Microsoft's own docs and helps
   XML-aware tooling (linters, IDEs) validate the file.

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
`cmd.exe` / pwsh-7+ operator — Windows PowerShell 5.1 (which ships with
Windows 10/11 by default and is what non-technical users will have open)
does not support it and will error with
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

### IN-05: `Invoke-SandboxCommand` JSON parse is brittle (same failure mode as the fixed WR-02)

**File:** `tests/sandbox/run-sandbox-test.ps1:95`
**Issue:**

```powershell
$result = wsb exec --id $sandboxId --command $Command --run-as System --raw 2>&1 | ConvertFrom-Json
```

This is the one remaining `2>&1 | ConvertFrom-Json` pattern in the
orchestrator after the WR-02 fix. It has the same failure mode: any
non-JSON line on stderr (a deprecation notice, an update nag, a
first-run diagnostic from `wsb exec`) will merge into stdout via `2>&1`
and feed `ConvertFrom-Json` garbage, which throws under
`$ErrorActionPreference = "Stop"` and aborts the run mid-test.

This was deliberately left out of the WR-02 fix scope — the two host-side
pre-flight calls (`wsb list`, `wsb start`) are the ones that break
first-run contributors, and they're now robust. But the `exec` wrapper
runs dozens of times per test and will eventually trip on a `wsb`
diagnostic.

**Fix:** Apply the same defensive pattern from the WR-02 fix:

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

Bonus: the `$Command` parameter is passed to `wsb exec --command` as a
single string. All current callers use paths without spaces
(`C:\go-mapi\tests\sandbox\*.ps1`), so this works, but it sets a quoting
trap for the day someone adds a test script under a path with spaces.

---

### IN-06: `tests/sandbox/README.md` prerequisite claims pwsh 7+ but in-sandbox runners use `powershell.exe`

**File:** `tests/sandbox/README.md:18-20`
**Issue:** The README lists

> **PowerShell 7+** (`pwsh`) — used by `run-sandbox-test.ps1`. Windows
> PowerShell 5.1 will parse but the harness uses `-raw` JSON output from
> `wsb` which is easier to handle in pwsh.

This is partly accurate (host-side `run-sandbox-test.ps1` is cleaner in
pwsh 7) but the *in-sandbox* runners are invoked via
`powershell -ExecutionPolicy Bypass -File ...` (lines 107, 147, 194 of
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
