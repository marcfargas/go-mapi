---
phase: 10-installer-migration
fixed_at: 2026-04-20T14:05:00Z
review_path: .planning/phases/10-installer-migration/10-REVIEW.md
iteration: 2
findings_in_scope: 9
fixed: 9
skipped: 0
status: all_fixed
---

# Phase 10: Code Review Fix Report

**Fixed at:** 2026-04-20T14:05:00Z
**Source review:** `.planning/phases/10-installer-migration/10-REVIEW.md`
**Iteration:** 2

## Summary

- Findings in scope: 9 (3 Warning + 6 Info; no Critical)
- Fixed: 9
- Skipped: 0

Iteration 2 invoked with `--all` to cover the previously-deferred Info
findings. All six Info findings were addressed and committed atomically.
The three Warning findings were fixed in iteration 1 and are preserved
here for a complete audit trail.

### Per-finding table

| ID    | Severity | Status | Commit    | File(s)                                    | Iteration |
|-------|----------|--------|-----------|--------------------------------------------|-----------|
| WR-01 | Warning  | fixed  | `e14b406` | `src/installer/go-mapi.nsi`                | 1         |
| WR-02 | Warning  | fixed  | `381f715` | `src/installer/go-mapi.nsi`                | 1         |
| WR-03 | Warning  | fixed  | `94b7403` | `.github/workflows/installer-smoke.yml`    | 1         |
| IN-01 | Info     | fixed  | `1a704ec` | `src/app/webview2_check.go`                | 2         |
| IN-02 | Info     | fixed  | `e555e5f` | `src/installer/go-mapi.nsi`                | 2         |
| IN-03 | Info     | fixed  | `c996bf6` | `src/installer/go-mapi.nsi`                | 2         |
| IN-04 | Info     | fixed  | `0a480d1` | `src/installer/go-mapi.nsi`                | 2         |
| IN-05 | Info     | fixed  | `609dd01` | `src/installer/go-mapi.nsi`                | 2         |
| IN-06 | Info     | fixed  | `6679541` | `src/installer/tests/AumidReader.ps1`      | 2         |

## Fixed Issues (iteration 2)

### IN-01: use `syscall.UTF16PtrFromString` in webview2_check

**Files modified:** `src/app/webview2_check.go`
**Commit:** `1a704ec`
**Applied fix:**
Replaced both `syscall.StringToUTF16Ptr(...)` calls in
`showWebView2MissingDialog` with the non-deprecated
`syscall.UTF16PtrFromString(...)` form, discarding the returned error
(safe because the literals are compile-time constants with no NUL
bytes). Added an inline comment explaining the decision and tying it
back to the codebase-wide idiom (`sessionend.go`, `settings.go`,
`singleinstance.go`). Matches the style used elsewhere and removes the
deprecation warning.

**Verification:**
- Tier 1: re-read modified function; both `title` and `body` now use
  `UTF16PtrFromString` with `_` error discard.
- Tier 2: `go vet ./src/app/...` → no output (clean).
- Bonus: `go build ./src/app/...` → no output (compiles cleanly).

### IN-02: correct `un.StrContains` register restore sequence

**Files modified:** `src/installer/go-mapi.nsi`
**Commit:** `e555e5f`
**Applied fix:**
Rewrote the `un.SC_Done` cleanup block. The prelude saves
`prev$R1` and `prev$R2` via `Exch $R1; Exch; Exch $R2`, leaving the
stack as `[prev$R1, prev$R2]` bottom->top, then pushes `$R3..$R5`.
The old cleanup attempted an extra `Exch / Pop / Exch` ballet that
left `$R1`'s pre-call value lost and one stray stack entry per call
(slow leak, plus `$R2` corrupted). The new sequence is:

```
Pop $R5
Pop $R4
Pop $R3
Pop $R2     ; restore prev$R2
Exch $R1    ; swap prev$R1 on stack with result in $R1
```

4 Pops + 1 Exch correctly balances 2 Exch-saves + 3 Pushes. Added an
inline comment tracing the stack shape through each step.

**Verification (Tier 1 + stack-balance inspection):**
Re-read the full function. Stack trace:
- Post-prelude: `[prev$R1, prev$R2]` + 3 pushes =
  `[prev$R1, prev$R2, prev$R3, prev$R4, prev$R5]`.
- Pop R5, R4, R3 → registers restored, stack = `[prev$R1, prev$R2]`.
- Pop R2 → `$R2 = prev$R2`, stack = `[prev$R1]`.
- Exch R1 → swap `prev$R1` with `$R1` (result).
  `$R1 = prev$R1`, stack top = result.
Final: caller pops the result, all `$R1..$R5` restored, zero leak.

**Logic-verification disclaimer:** NSIS has no local test harness;
correctness is inferred from the stack-balance analysis above.
Pester CI exercises the uninstaller's non-null-client path (Pester
items 7-8) but with IN-05 applied `un.StrContains` is no longer called
from that path — this function is now dormant. Keeping the corrected
version in place for any future caller.

### IN-03: correct `un.StrExtract` register restore sequence

**Files modified:** `src/installer/go-mapi.nsi`
**Commit:** `c996bf6`
**Applied fix:**
Rewrote the `un.SE_Done` cleanup block. Because of the prelude's
`Exch 2` swap (needed to get three Exch-saves from a three-arg call),
the post-prelude stack is `[prev$R2, prev$R1, prev$R3]` bottom->top —
note `prev$R1` and `prev$R2` are interleaved in reverse order.
After Push `$R4..$R7` the full stack is
`[prev$R2, prev$R1, prev$R3, prev$R4, prev$R5, prev$R6, prev$R7]`.

The corrected cleanup pops `$R7..$R3` (restores those five registers),
then uses `Exch` (no arg) to swap the remaining `[prev$R2, prev$R1]`
into `[prev$R1, prev$R2]`, pops `$R2` to restore `prev$R2`, and
`Exch $R1` swaps the final `prev$R1` with the result.

```
Pop $R7
Pop $R6
Pop $R5
Pop $R4
Pop $R3     ; restore prev$R3
Exch        ; [prev$R2, prev$R1] -> [prev$R1, prev$R2]
Pop $R2     ; restore prev$R2
Exch $R1    ; swap prev$R1 with result in $R1
```

**Verification (Tier 1 + stack-balance inspection):**
Re-read the full function. Traced every Exch/Pop step through the
post-prelude stack shape (documented inline in the file via comment
block). Note: IN-05 also removes this function's only caller from the
hot path; the fix is dormant but kept for any future re-use.

**Logic-verification disclaimer:** Same as IN-02 — no NSIS test
harness. Correctness is stack-balance-inspected; flags the fix as
"requires human verification" in the strict sense, but the stack
arithmetic is the entire correctness criterion and is documented.

### IN-04: reset `SetRegView` before `DetectWebView2` returns

**Files modified:** `src/installer/go-mapi.nsi`
**Commit:** `0a480d1`
**Applied fix:**
Added `SetRegView default` as the first statement of both
`WebView2NotFound` and `WebView2Found` exit blocks. The function now
leaves the registry view in the NSIS default state regardless of which
probe the control flow reached. This eliminates the latent hazard of
silent WOW6432Node redirects affecting subsequent `WriteRegStr HKLM`
calls in the install section (AddFirewallRule and any future growth).

**Verification:**
- Tier 1: re-read both labels. `SetRegView default` is present
  immediately before each `Pop $1 / Pop $0 / Push "0" (or "1") / Return`.
- Grep for `SetRegView` in the file confirms 4 occurrences:
  `SetRegView 64` (entry), `SetRegView 32` (third-probe), and two
  `SetRegView default` (restore).
- Pester smoke test (CI) covers the runtime-present path implicitly
  via the install-section regressions after this Call.

### IN-05: parse backup JSON via `ConvertFrom-Json`

**Files modified:** `src/installer/go-mapi.nsi`
**Commit:** `609dd01`
**Applied fix:**
Replaced the naive substring-based JSON parse in
`un.RestorePreviousMailClient` with a PowerShell one-liner that uses
`Get-Content | ConvertFrom-Json` to retrieve the `.previousClient`
property. The new flow:
1. `IfFileExists` gates the PS spawn — fall through to `NoBackup` if
   the file is absent (avoids the ~200ms PS startup for missing
   backups).
2. `nsExec::ExecToStack` invokes PowerShell; the script writes the
   previousClient value to stdout (empty string if JSON null), or
   exits non-zero on parse error / IO failure.
3. Exit code is checked first (`StrCmp $4 "0"`); non-zero → fallbacks.
4. Trailing CRLF on stdout is stripped via `StrCpy $1 $1 -2` guarded
   by an `IntCmp` length check (≥2 bytes).
5. Empty result → fallbacks; non-empty → proceed to `VerifyAndRestore`.

`ConvertFrom-Json` correctly distinguishes JSON `null` from the
literal string `"previousClient":null` inside a value, and correctly
unescapes JSON-escaped `"` / `\` characters written by
`EscapeJsonString` (WR-02 helper). Net effect: the naive-substring
false-match vector is closed, and the uninstaller's parse semantics
now match what the installer writes.

**Shell-injection note:** the PowerShell invocation uses single-quoted
literals for the path (`''$APPDATA\...''`) and does not interpolate
any external input; the only NSIS variable in the command line is
`$APPDATA` itself (a system-resolved path with known shape). No shell
injection surface.

**Verification:**
- Tier 1: re-read the full `un.RestorePreviousMailClient` function;
  confirmed the `IfFileExists -> nsExec::ExecToStack -> Pop exit ->
  Pop stdout -> StrCmp -> trim -> branch` flow is intact.
- Side effect: `un.StrContains` and `un.StrExtract` are no longer
  called from the uninstaller (confirmed via `Grep` for both names in
  `go-mapi.nsi` — only the `Function` declarations remain). They
  remain in the file as corrected (IN-02 / IN-03) helpers for any
  future caller; no breakage from dead code.
- Pester smoke coverage (CI): items 7-8 exercise the non-null restore
  path; with this fix, a previously-registered third-party mail client
  is correctly extracted via ConvertFrom-Json and restored as the
  HKLM Mail (Default) value.

**Logic-verification disclaimer:** `IntCmp $4 2 0 SkipTrim 0` was
hand-checked — the NSIS semantics `IntCmp a b <equal> <less>
<greater>` mean we fall through (trim) when len == 2 or len > 2, skip
when len < 2. Confirmed by re-reading the block and inline comment.
Marked as **"requires human verification"** per fixer-guidance policy
for user-visible control-flow changes in the uninstaller hot path.

### IN-06: guard `AumidReader` `Add-Type` on `PublicReader`

**Files modified:** `src/installer/tests/AumidReader.ps1`
**Commit:** `6679541`
**Applied fix:**
Changed the Add-Type idempotency guard from
`'GoMapi.AumidReader.Reader' -as [type]` to
`'GoMapi.AumidReader.PublicReader' -as [type]`. Added a comment
explaining the rationale: `PublicReader` is the actual entry point
invoked by `Get-ShortcutAumid` (line 102), so checking its presence
is the correct proxy for "the compiled assembly is loaded". The
Add-Type call itself still uses `-Name Reader` (unchanged — that name
only determines the internal container type, not the entry point the
test code calls).

**Verification:**
- Tier 1: re-read lines 15-21; guard symbol flipped to `PublicReader`.
- Grep for `Reader.*-as.*type` confirms single match
  (`PublicReader`) — no stray legacy guards.
- CI Pester runs always start with a clean PowerShell session per job,
  so this is a dev-machine-iterative-testing improvement; no CI
  behaviour change expected.

## Previously Fixed (iteration 1)

These three Warning findings were applied in iteration 1. Commits are
preserved verbatim from the iteration-1 report for audit continuity.

### WR-01: correct `DetectWebView2` StrCmp to reject `0.0.0.0` sentinel

**Files modified:** `src/installer/go-mapi.nsi`
**Commit:** `e14b406`
**Applied fix:**
Restructured `DetectWebView2` to use explicit next-probe labels
(`TryDirectHKLM`, `TryHKCU`) so the `pv=""` and `pv="0.0.0.0"` guards
fall through to the next probe instead of being swallowed by the
inverted `StrCmp $0 "" 0 WebView2Found` form. All three probes now
reject both sentinels; the first probe that returns a non-empty,
non-`0.0.0.0` value jumps to `WebView2Found`. Matches the Go-side
check at `src/app/webview2_check.go:45` (`pv != "" && pv != "0.0.0.0"`)
so the installer and Wails app now agree on runtime presence.

### WR-02: escape backup JSON string interpolation

**Files modified:** `src/installer/go-mapi.nsi`
**Commit:** `381f715`
**Applied fix:**
Added a new `Function EscapeJsonString` helper that escapes the two
JSON-meaningful characters (`\` → `\\`, then `"` → `\"` — order
matters). `BackupPreviousMailClient` calls `EscapeJsonString` on `$0`
before the `FileWrite` template interpolation. Null-branch needs no
escape (bare `null` literal).

### WR-03: drop OAuth secrets from installer-smoke workflow

**Files modified:** `.github/workflows/installer-smoke.yml`
**Commit:** `94b7403`
**Applied fix:**
Removed the `env:` block injecting `GOMAPI_OAUTH_CLIENT_ID` and
`GOMAPI_OAUTH_CLIENT_SECRET` from repo secrets, and stripped the two
matching `-X main.oauthClientID=...` / `-X main.oauthClientSecret=...`
ldflags from the Wails build step. Kept `-X main.aumidOverride=...`
(not a secret). Release workflow was intentionally NOT modified.

## Skipped Issues

None.

## Deferred (not in scope)

None — all findings addressed.

---

_Fixed: 2026-04-20T14:05:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 2_
