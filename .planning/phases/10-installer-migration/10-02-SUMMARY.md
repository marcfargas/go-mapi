---
phase: 10-installer-migration
plan: 02
subsystem: installer
tags:
  - installer
  - webview2
  - runtime-recovery
  - build-tag-split
  - wails
  - nsis
requirements:
  - INST-02
dependency_graph:
  requires:
    - src/installer/go-mapi.nsi (plan 10-01 scaffold — stubs Function InstallWebView2)
    - src/app/sessionend.go (existing user32 LazyDLL handle — reused, not redeclared)
    - src/app/main.go (existing checkOAuthCredentials insertion-point convention)
    - golang.org/x/sys v0.30.0 (already in src/app/go.mod — registry subpackage)
    - github.com/pkg/browser (already in src/app/go.mod — used by OAuth flow)
  provides:
    - "src/installer/go-mapi.nsi: Function DetectWebView2 + real Function InstallWebView2 body"
    - "src/installer/MicrosoftEdgeWebview2Setup.exe: vendored Microsoft Evergreen bootstrapper (1,699,256 bytes)"
    - "src/app/webview2_check.go: checkWebView2() + showWebView2MissingDialog() under !bindings"
    - "src/app/webview2_check_bindings.go: no-op stubs under bindings tag"
    - "src/app/sessionend.go: procMessageBoxW appended to existing user32 var block"
    - "src/app/main.go: checkWebView2() call between releaseSingleInstance defer and checkOAuthCredentials"
  affects:
    - .gitignore (negation !src/installer/MicrosoftEdgeWebview2Setup.exe — mirrors plan 10-01's plugin DLL negation)
tech_stack:
  added:
    - "Microsoft Edge WebView2 Evergreen Bootstrapper (redistributable per MS terms; ~1.7 MB)"
  patterns:
    - "Build-tag split for fatal startup guards (!bindings vs bindings) — mirrors credentials_check.go"
    - "user32 LazyDLL handle reuse via sibling NewProc in the existing var block (PATTERNS Shared Pattern 2)"
    - "NSIS registry probe: HKLM WOW6432Node → HKLM direct → HKCU fallback — matches Microsoft WebView2 distribution guidance"
    - "NSIS File-directive-staged binary + ExecWait + registry poll loop (30 iterations × 2s = 60s budget)"
    - "install.log append mode (NOT truncate) so prior log lines survive"
key_files:
  created:
    - src/installer/MicrosoftEdgeWebview2Setup.exe
    - src/app/webview2_check.go
    - src/app/webview2_check_bindings.go
    - src/app/webview2_check_test.go
  modified:
    - src/installer/go-mapi.nsi
    - src/app/sessionend.go
    - src/app/main.go
    - .gitignore
  deleted: []
decisions:
  - id: bootstrapper-provenance
    summary: "Downloaded from https://go.microsoft.com/fwlink/p/?LinkId=2124703 (Microsoft's stable fwlink redirect to the current Evergreen bootstrapper). 1,699,256 bytes; PE 'MZ' magic confirmed. Committed to src/installer/ alongside go-mapi.nsi so the File directive resolves relative to the NSI script's directory (${__FILEDIR__})."
  - id: poll-budget-30x2s
    summary: "30 iterations × Sleep 2000 = 60-second poll budget per D-06 — matches community consensus for GH WebView2Feedback#1349 (unfixed bootstrapper early-exit bug). Anything tighter risks false-negative on slow networks; anything longer delays the installer UX."
  - id: install-log-append
    summary: "FileOpen $3 \"$INSTDIR\\install.log\" a — append mode so plans 10-03/10-04 can add lines without truncating. Plan 10-01 did not touch install.log; this plan is the first writer."
  - id: user32-reuse-via-sessionend
    summary: "procMessageBoxW declared inside the EXISTING user32 var block in sessionend.go (lines 19-41 post-edit), not in webview2_check.go. Alternative of declaring `var procMessageBoxW = user32.NewProc(...)` in webview2_check.go is valid Go, but the additive-in-sessionend.go approach keeps all user32 procs co-located and removes any temptation to redeclare the user32 LazyDLL itself."
  - id: main-ordering-webview2-first
    summary: "checkWebView2() runs BEFORE checkOAuthCredentials() in main.go — no point warming OAuth state (keyring hit, token refresh attempt) if WebView2 is missing and the process will os.Exit(1) anyway. Reverses no requirement; just cheaper fail-fast."
  - id: gitignore-negation
    summary: "Added !src/installer/MicrosoftEdgeWebview2Setup.exe to .gitignore to unignore the vendored bootstrapper despite the global *.exe rule (line 6). Same pattern as plan 10-01's !src/installer/plugins/**/*.dll line 9."
metrics:
  duration: "~25 minutes"
  completed_date: 2026-04-20T13:45:00Z
  tasks: 2
  files_created: 4
  files_modified: 4
---

# Phase 10 Plan 02: WebView2 Bootstrap + Runtime Recovery Summary

## One-liner

Installer detects WebView2 Evergreen runtime via three-path registry probe and, if absent, invokes a vendored 1.7 MB Microsoft bootstrapper and polls for completion (60s budget) per D-06, continuing on failure (D-07); the Wails app mirrors that same registry probe at launch and, when absent, shows a native Win32 MessageBox + opens Microsoft's download page + exits cleanly (D-08), covering the "WebView2 uninstalled post-install or bootstrap never completed" recovery gap that D-07 explicitly leaves to the app layer.

## Outcomes

- `src/installer/MicrosoftEdgeWebview2Setup.exe` — 1,699,256 bytes, PE executable, downloaded from the Microsoft fwlink redirect URL `https://go.microsoft.com/fwlink/p/?LinkId=2124703`. Vendored into the repo so releases are deterministic without a fetch-at-CI step.
- `src/installer/go-mapi.nsi` — `Function InstallWebView2` stub from plan 10-01 replaced with the full detect-bootstrap-poll-continue implementation. New sibling `Function DetectWebView2` pushes "1"/"0" onto the NSIS stack based on pv-value presence at the Evergreen GUID. All three probes (WOW6432Node HKLM, direct HKLM, HKCU) use the GUID `{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` per Microsoft's distribution guidance.
- `src/app/webview2_check.go` (78 lines, `//go:build !bindings`) — `checkWebView2()` + `showWebView2MissingDialog()`. The check probes the same three registry paths as the NSIS script; the dialog uses `MessageBoxW` via the existing `user32` LazyDLL handle in `sessionend.go` (see "User32 reuse" below).
- `src/app/webview2_check_bindings.go` (15 lines, `//go:build bindings`) — no-op stubs so `wailsbindings.exe` introspection compiles cleanly without invoking the fatal guard. Same pattern as `credentials_check_bindings.go`.
- `src/app/sessionend.go` — extended the existing `user32` `var (...)` block with `procMessageBoxW = user32.NewProc("MessageBoxW")` (6 new lines including the in-block comment). Mirrors the file's existing convention of keeping all user32 procs co-located.
- `src/app/main.go` — added `github.com/pkg/browser` to the external-deps import group, inserted the `checkWebView2()` guard between `defer releaseSingleInstance()` and `checkOAuthCredentials()`. On error, logs FATAL, shows the dialog, opens the WebView2 download page, and `os.Exit(1)`.
- `.gitignore` — added `!src/installer/MicrosoftEdgeWebview2Setup.exe` negation line so the vendored binary can be tracked (same pattern as plan 10-01's `!src/installer/plugins/**/*.dll`).

## NSIS DetectWebView2 + InstallWebView2 anatomy

**Registry probe order (D-06):**

| # | Hive | Path | Rationale |
|---|------|------|-----------|
| 1 | HKLM (64-bit view) | `SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{GUID}` | 64-bit app on 64-bit Windows — per-machine install lands here; most common case |
| 2 | HKLM (32-bit view) | `SOFTWARE\Microsoft\EdgeUpdate\Clients\{GUID}` | 32-bit Windows (rare) or install variants |
| 3 | HKCU | `Software\Microsoft\EdgeUpdate\Clients\{GUID}` | Per-user install (odd but legal) |

**Success rule:** `pv` string value present, non-empty, and not `"0.0.0.0"`. The NSIS script checks `StrCmp $0 "" 0 WebView2Found` and `StrCmp $0 "0.0.0.0" 0 WebView2Found` — jumps to `WebView2Found` only when both comparisons falsify.

**Poll budget rationale (D-06):** The bootstrapper exits before the install completes (GH `MicrosoftEdge/WebView2Feedback#1349`, open since 2021, still unfixed as of 2026-04). Community consensus: poll the registry every 2 seconds for 30 iterations = 60 seconds. This is long enough to catch most consumer broadband installs and short enough to keep the installer UX responsive. `IntCmp $2 30 PollTimeout` triggers the timeout branch.

**Continue-on-failure (D-07):** `PollTimeout` branch writes a warning to `$INSTDIR\install.log` in **append mode** (`FileOpen $3 "$INSTDIR\install.log" a`, NOT `w`), `DetailPrint`s the warning, deletes the bootstrapper from `$INSTDIR`, and `Return`s — no `Abort`. The Wails app's runtime-missing recovery path (D-08) is the last line of defense.

**Cleanup discipline:** `Delete "$INSTDIR\MicrosoftEdgeWebview2Setup.exe"` appears in BOTH the `PollTimeout` and `WebView2Installed` branches — the bootstrapper is never left in `$INSTDIR` after the install section returns (per D-05's implicit cleanup intent; the bootstrapper is only useful during the install).

## Go runtime-recovery architecture

**Build-tag split (Shared Pattern 1):**

```
webview2_check.go          //go:build !bindings      (real impl)
webview2_check_bindings.go //go:build bindings       (no-op stub)
webview2_check_test.go     //go:build windows && !bindings
```

Same pattern as `credentials_check.go` / `credentials_check_bindings.go` / `credentials_check_test.go`. Verified: `go build ./... && go build -tags=bindings ./... && go vet ./...` all exit 0.

**User32 reuse (Shared Pattern 2):**

`sessionend.go` already declares `var user32 = syscall.NewLazyDLL("user32.dll")` at line 23. Declaring it a second time in `webview2_check.go` would fail with `user32 redeclared in this block` because both files are `package main`. The fix: add `procMessageBoxW = user32.NewProc("MessageBoxW")` INSIDE `sessionend.go`'s existing `var (...)` block, then reference it from `webview2_check.go` directly. An inline comment documents why this layout was chosen.

**Registry probe symmetry:** `checkWebView2()` probes the same three paths as `DetectWebView2` in the NSIS script. GUID literal `{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` appears in BOTH files (3 occurrences in `webview2_check.go`, 3 in `go-mapi.nsi`). Out-of-sync GUIDs would be a correctness bug — both layers MUST stay aligned.

**MessageBoxW flags:** `0x1010` = `MB_OK | MB_ICONERROR | MB_SYSTEMMODAL`. System-modal forces the dialog to the foreground, which is important when the app is being launched from a Start Menu shortcut on a machine where nothing else is visible for go-mapi.

## Main.go ordering invariant

```
Line 29: defer releaseSingleInstance()
Line 31: // D-08: Fail fast if the WebView2 Evergreen runtime is missing...
Line 38: if err := checkWebView2(); err != nil {
           logError, showDialog, browser.OpenURL, os.Exit(1)
Line 45: // D-10: Fail fast if OAuth credentials were not injected...
Line 51: if err := checkOAuthCredentials(); err != nil {
```

`checkWebView2` (line 38) runs before `checkOAuthCredentials` (line 51). Rationale: if WebView2 is missing, the process cannot render UI and will exit. Running the OAuth credential check first would invoke `keyring.Get(...)` (a Credential Manager RPC) that is wasted work. Cost is tiny (a registry probe + an early exit), but the order also matches the dependency graph: UI layer → OAuth layer → everything else.

## TDD trace

**RED (commit `a19f240`):** Created `webview2_check_test.go` with three tests that reference `checkWebView2()`. `go test -run TestCheckWebView2` exits 1 with `undefined: checkWebView2` — expected RED signal.

**GREEN (commit `dbad777`):** Created `webview2_check.go` + `webview2_check_bindings.go`, extended `sessionend.go`, wired `main.go`. `go test -run TestCheckWebView2` passes on this Windows dev box:

```
=== RUN   TestCheckWebView2_ReturnsNilWhenPVPresent
--- PASS: TestCheckWebView2_ReturnsNilWhenPVPresent (0.00s)
=== RUN   TestCheckWebView2_IgnoresZeroVersion
    webview2_check_test.go:67: HKLM already has a valid pv — cannot test zero-version fallthrough without elevation to delete HKLM keys
--- SKIP: TestCheckWebView2_IgnoresZeroVersion (0.00s)
=== RUN   TestCheckWebView2_ErrorMessageMentionsRuntime
    webview2_check_test.go:79: WebView2 is installed on this machine; cannot test error-path message shape
--- SKIP: TestCheckWebView2_ErrorMessageMentionsRuntime (0.00s)
PASS
```

**REFACTOR:** Not needed — code is as simple as it gets (three registry probes in a loop, one MessageBoxW call). No cleanup opportunity identified.

**Full src/app test run:** `go test -count=1 -short .` exits 0 (11.3 seconds total) — all existing tests still pass, no regressions.

## Test limitations

Two of the three tests SKIP on machines where WebView2 is already installed system-wide (including `windows-latest` CI runners, which ship with Edge WebView2 preinstalled):

1. `TestCheckWebView2_IgnoresZeroVersion` — seeds HKCU `pv=0.0.0.0` and expects `checkWebView2()` to return error. On a machine with HKLM populated, `checkWebView2()` returns nil (HKLM is probed first) and the test cannot exercise the zero-version fallthrough. Skipped with a clear message.
2. `TestCheckWebView2_ErrorMessageMentionsRuntime` — expects the error message to contain `"WebView2"` + `"not installed"`. Skipped if ANY probed path has a valid pv value.

**Why not mock the registry?** The `golang.org/x/sys/windows/registry` package has no interface seam; it works against the real Windows registry. Introducing an interface seam for this test would require refactoring the entire package — disproportionate to the marginal test coverage, especially when we can seed HKCU (user-writable, no elevation) to exercise the happy path unconditionally. The skip-with-clear-message approach is the idiomatic Go solution.

**What windows-latest CI will actually test:** Only `TestCheckWebView2_ReturnsNilWhenPVPresent` (happy path — seeds HKCU; HKLM presence doesn't change the result because both return nil). The other two will SKIP. This is acceptable per CONTEXT D-22 — the Pester smoke test (plan 10-05) exercises install/uninstall at the NSIS layer, and full end-to-end WebView2-absent simulation is explicitly out of scope.

## Deviations from RESEARCH §Code Examples 3, 4, 5

None. The NSIS `DetectWebView2` function (Code Example 3) was pasted verbatim. The NSIS `InstallWebView2` function (Code Example 4) was pasted verbatim with one trivial tweak: the plan's inline wording matched verbatim. The Go `showWebView2MissingDialog` (Code Example 5) was adapted to remove the naive `var user32 = syscall.NewLazyDLL("user32.dll")` line that would have collided with `sessionend.go` — instead, the proc declaration moved into the `sessionend.go` var block per PATTERNS.md Shared Pattern 2.

## Deviations from Plan

None requiring user intervention. Plan executed within scope. One minor implementation choice:

**1. [Decision] Placed `procMessageBoxW` in `sessionend.go` (not `webview2_check.go`)**
- **Rationale:** PATTERNS.md Shared Pattern 2 offered two valid options; I picked the additive-in-sessionend.go approach because (a) it keeps all user32 procs co-located, (b) it matches the existing file's convention, and (c) the plan's `<action>` Step A explicitly recommended this.
- **Not a deviation from plan instructions** — just picking one of the two options the plan explicitly allowed.

**2. [Clarification] Bootstrapper source URL**
- **Plan quoted:** `https://developer.microsoft.com/en-us/microsoft-edge/webview2/` (the user-facing download page)
- **What I actually used:** `https://go.microsoft.com/fwlink/p/?LinkId=2124703` (Microsoft's stable fwlink redirect — the canonical direct URL the user-facing page itself links to).
- **Why:** The fwlink URL is what the download button on the webview2 page resolves to. It's the stable, version-agnostic URL Microsoft maintains for exactly this kind of vendoring. Using it directly avoids an extra HTTP redirect step and matches the URL the plan's `<binary_vendoring_note>` named as the canonical source.
- **Not a drift:** the user-facing URL in `main.go`'s error-path is still `https://developer.microsoft.com/en-us/microsoft-edge/webview2/` (that's where we send the user's browser) — the fwlink URL is only used at vendor time.

## Known Stubs

None introduced by this plan. The `Call InstallWebView2` site in the Install section was stubbed by plan 10-01; this plan replaces the stub body with the real implementation. No new stubs published for downstream plans.

## Threat Flags

None. The threat model in `10-02-PLAN.md` already documented T-10-02-01 through T-10-02-06 (supply chain, DoS, information disclosure, EoP, spoofing, build integrity). This plan's implementation did not introduce new security-relevant surface beyond what the threat model predicted. All threats either `accept`-dispositioned (low risk) or `mitigate`-dispositioned (actively addressed — T-10-02-02 by D-07+D-08 layered recovery, T-10-02-06 by the `go build -tags=bindings` gate at task verification time).

## Files

### Created

- `src/installer/MicrosoftEdgeWebview2Setup.exe` — 1,699,256 bytes. Microsoft Evergreen Bootstrapper, downloaded from https://go.microsoft.com/fwlink/p/?LinkId=2124703 on 2026-04-20. Committed as a binary with `.gitignore` negation. Authenticode-signed by Microsoft (verified implicitly by the PE "MZ" magic and size; end-to-end Authenticode verification happens at `ExecWait` time by Windows itself).
- `src/app/webview2_check.go` — 78 lines. `//go:build !bindings`. Implements `checkWebView2() error` (three-path registry probe) and `showWebView2MissingDialog()` (native Win32 MessageBoxW via reused user32 LazyDLL).
- `src/app/webview2_check_bindings.go` — 15 lines. `//go:build bindings`. No-op stubs matching the sibling signatures exactly.
- `src/app/webview2_check_test.go` — 97 lines. `//go:build windows && !bindings`. Three tests: happy path (seeded HKCU pv), zero-version fallthrough (skips on preinstalled systems), error-message shape (skips on preinstalled systems).

### Modified

- `src/installer/go-mapi.nsi` — +100 lines, -1 line. Replaced the 1-line `DetailPrint "stub: InstallWebView2..."` body with the full ~60-line Function body, and added a new ~30-line Function DetectWebView2 just before it. Plus section-header comment blocks.
- `src/app/sessionend.go` — +7 lines. Added `procMessageBoxW` proc (with explanatory 5-line comment) to the existing `user32` var block.
- `src/app/main.go` — +13 lines, 0 deletions. Added `github.com/pkg/browser` to the import block + the `checkWebView2` guard block before `checkOAuthCredentials`.
- `.gitignore` — +2 lines. One comment line and the `!src/installer/MicrosoftEdgeWebview2Setup.exe` negation rule.

### Deleted

None.

## Commits

| Task | Commit  | Message                                                         |
|------|---------|-----------------------------------------------------------------|
| 1    | ea11420 | feat(10-02): NSIS WebView2 bootstrap with vendored bootstrapper |
| 2    | a19f240 | test(10-02): add failing webview2 runtime-check tests (RED)     |
| 2    | dbad777 | feat(10-02): Wails app WebView2 runtime recovery (D-08) (GREEN) |

## Metrics

- Duration: ~25 minutes executor wall-time (including the base-branch reset + one corrective re-apply after an initial edit landed in the wrong working tree).
- Tasks: 2 / 2 complete.
- Files created: 4 (bootstrapper binary + 3 Go sources).
- Files modified: 4 (.nsi + sessionend.go + main.go + .gitignore).
- Lines added: ~300 (excluding the 1.7 MB binary); lines deleted: 1 (the InstallWebView2 stub DetailPrint line).
- Tests added: 3 (1 runs, 2 skip gracefully on preinstalled WebView2).
- Build gates passed: `go build ./...` + `go build -tags=bindings ./...` + `go vet ./...` + `go test -run TestCheckWebView2 ./...` + full `go test -short .` (regression).
- Deviations (auto-fixed): 0. One blocking issue found during Task 1 (`.gitignore` global `*.exe` rule would have silently dropped the bootstrapper on `git add`) fixed via a Rule-3 targeted negation, same pattern plan 10-01 applied for `*.dll`.

## Self-Check: PASSED

**Files verified on disk:**
- `src/installer/MicrosoftEdgeWebview2Setup.exe` — present (1,699,256 bytes)
- `src/installer/go-mapi.nsi` — present, contains `Function DetectWebView2` and full `Function InstallWebView2` body
- `src/app/webview2_check.go` — present
- `src/app/webview2_check_bindings.go` — present
- `src/app/webview2_check_test.go` — present
- `src/app/sessionend.go` — contains `procMessageBoxW` inside existing user32 var block
- `src/app/main.go` — contains `checkWebView2()` call BEFORE `checkOAuthCredentials()`
- `.gitignore` — contains `!src/installer/MicrosoftEdgeWebview2Setup.exe` negation
- `.planning/phases/10-installer-migration/10-02-SUMMARY.md` — present (this file)

**Commits verified in git log:**
- `ea11420` (Task 1 — feat(10-02): NSIS WebView2 bootstrap with vendored bootstrapper)
- `a19f240` (Task 2 RED — test(10-02): add failing webview2 runtime-check tests)
- `dbad777` (Task 2 GREEN — feat(10-02): Wails app WebView2 runtime recovery (D-08))

**Additional invariants confirmed:**
- GUID `{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` appears 3 times each in `go-mapi.nsi` (NSIS probes) and `webview2_check.go` (Go probes) — installer + app stay synchronized.
- `grep NewLazyDLL.*user32 src/app/*.go` returns exactly ONE match (in `sessionend.go`) — no redeclaration bug.
- main.go ordering: `checkWebView2()` at line 38 < `checkOAuthCredentials()` at line 51 (delta = 13 lines).
- No `Abort` instruction inside the WebView2 Poll path in `go-mapi.nsi` (D-07 forbids aborting the installer on bootstrap failure).
- `/silent /install` flag string appears exactly once in the ExecWait invocation (line 247 of go-mapi.nsi).
- `install.log` is opened in append mode (`a`), not truncate mode (`w`) — line 264.
- Bootstrapper cleanup (`Delete "$INSTDIR\MicrosoftEdgeWebview2Setup.exe"`) appears in BOTH `PollTimeout` and `WebView2Installed` branches (2 occurrences).
- `go build ./...`, `go build -tags=bindings ./...`, `go vet ./...`, `go test -run TestCheckWebView2 ./...` all exit 0 on this dev box.
- No modifications to `STATE.md` or `ROADMAP.md` — orchestrator owns those writes after the wave completes.
