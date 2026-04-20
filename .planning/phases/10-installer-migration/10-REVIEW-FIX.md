---
phase: 10-installer-migration
fixed_at: 2026-04-20T13:02:00Z
review_path: .planning/phases/10-installer-migration/10-REVIEW.md
iteration: 1
findings_in_scope: 3
fixed: 3
skipped: 0
status: all_fixed
---

# Phase 10: Code Review Fix Report

**Fixed at:** 2026-04-20T13:02:00Z
**Source review:** `.planning/phases/10-installer-migration/10-REVIEW.md`
**Iteration:** 1

## Summary

- Findings in scope: 3 (all Warning; no Critical findings — Info findings deferred)
- Fixed: 3
- Skipped: 0

All three warning-level findings from 10-REVIEW.md were fixed and committed
atomically. No skips. No rollbacks triggered. Six Info findings (IN-01 through
IN-06) remain deferred per the default scope (critical + warning only).

## Fixed Issues

### Per-finding table

| ID    | Severity | Status | Commit    | File(s)                                 | Verification                                         |
|-------|----------|--------|-----------|-----------------------------------------|------------------------------------------------------|
| WR-01 | Warning  | fixed  | `e14b406` | `src/installer/go-mapi.nsi`             | Re-read + grep anti-pattern (see below)              |
| WR-02 | Warning  | fixed  | `381f715` | `src/installer/go-mapi.nsi`             | Re-read + stack-balance inspection of EscapeJsonString |
| WR-03 | Warning  | fixed  | `94b7403` | `.github/workflows/installer-smoke.yml` | Re-read + no-tabs YAML sanity + Pester-grep confirmation |

### WR-01: correct `DetectWebView2` StrCmp to reject `0.0.0.0` sentinel

**Files modified:** `src/installer/go-mapi.nsi`
**Commit:** `e14b406`
**Applied fix:**
Restructured `DetectWebView2` to use explicit next-probe labels
(`TryDirectHKLM`, `TryHKCU`) so the `pv=""` and `pv="0.0.0.0"` guards
fall through to the next probe instead of being swallowed by the
previous inverted `StrCmp $0 "" 0 WebView2Found` form. All three probes
now reject both sentinels; the first probe that returns a non-empty,
non-`0.0.0.0` value jumps to `WebView2Found`. Matches the Go-side check
at `src/app/webview2_check.go:45` (`pv != "" && pv != "0.0.0.0"`) so
the installer and Wails app now agree on runtime presence.

**Verification (Tier 1 + regression grep):**
Re-read the function after edit; confirmed all three probes follow the
same shape:
  - `StrCmp $0 "" <next-probe-or-NotFound>`
  - `StrCmp $0 "0.0.0.0" <next-probe-or-NotFound>`
  - `Goto WebView2Found`
Ran `Grep` for the anti-pattern `StrCmp.*" 0 WebView2Found` (the
inverted form that was the source of the bug) — zero matches in the
file post-fix.

### WR-02: escape backup JSON string interpolation

**Files modified:** `src/installer/go-mapi.nsi`
**Commit:** `381f715`
**Applied fix:**
Added a new `Function EscapeJsonString` helper that escapes the two
JSON-meaningful characters in a string literal: `\` → `\\` (first), `"`
→ `\"` (second — order matters, else the new backslashes double-escape).
`BackupPreviousMailClient` now calls `EscapeJsonString` on `$0` before
the `FileWrite` template interpolation. The null-branch needs no escape
(bare `null` literal, no quoted value). Helper preserves caller state
via `Exch $R0` + Push/Pop of `$R1..$R4`.

**Verification (Tier 1 + stack-balance inspection):**
Re-read the helper function; confirmed the stack contract:
  - Entry: 1 `Exch $R0` (save caller's $R0, consume input) + 4 Push ($R1..$R4)
  - Exit: 4 Pop ($R4..$R1) + 1 `Exch $R0` (restore caller's $R0, push output)
Balance: 5 in / 5 out. All `$R*` registers restored; no stray stack
entries.
Loop termination: `IntCmp $R2 $R1 EscDone` fires when cursor reaches
length, so the loop is bounded by input length.

**Note (logic-verification disclaimer):** JSON escaping is a textual
transform; correctness depends on the escape order (backslash first,
quote second). The order is documented inline and matches the standard
JSON string encoding rules. No unit test was added (NSIS has no test
harness in this repo); the Pester smoke test exercises the
not-null-client install branch, which will fail parse if the helper is
broken.

### WR-03: drop OAuth secrets from installer-smoke workflow

**Files modified:** `.github/workflows/installer-smoke.yml`
**Commit:** `94b7403`
**Applied fix:**
Removed the `env:` block that injected `GOMAPI_OAUTH_CLIENT_ID` and
`GOMAPI_OAUTH_CLIENT_SECRET` from repo secrets, and stripped the two
matching `-X main.oauthClientID=...` / `-X main.oauthClientSecret=...`
ldflags from the Wails build step. Kept `-X main.aumidOverride=...`
(not a secret). Replaced the removed content with a comment explaining
the security rationale so future edits do not re-introduce the leak.

**Verification:**
Re-read the workflow; confirmed:
  - No `GOMAPI_OAUTH_CLIENT_*` env or ldflags references remain.
  - `-X main.aumidOverride=com.marcfargas.gomapi` is retained (needed
    for Pester item 5 — the AUMID assertion).
  - File parses as valid YAML structure (126 lines, no tabs, indentation
    preserved around the removed env block).
Grepped `src/installer/tests/installer.Tests.ps1` for
`Start-Process.*go-mapi\.exe` and `&.*go-mapi\.exe` — only two matches,
both inside `Test-Path` assertions (item 2). Confirmed Pester never
launches `go-mapi.exe`, so the dev binary built without OAuth
credentials is functionally equivalent for smoke coverage.

Release workflow `.github/workflows/installer-release.yml` was NOT
modified — the release artifact is published intentionally and its
OAuth injection is the product's distribution path.

## Skipped Issues

None.

## Deferred (not in scope)

The following Info-severity findings from `10-REVIEW.md` were NOT
addressed in this fix pass (default scope = Critical + Warning only).
They remain tracked in the original review and can be picked up via
`/gsd-code-review-fix --all` or a follow-up todo:

- **IN-01:** `syscall.StringToUTF16Ptr` deprecated → prefer
  `UTF16PtrFromString` in `src/app/webview2_check.go`.
- **IN-02:** `un.StrContains` corrupts `$R2` on return in
  `src/installer/go-mapi.nsi:494-522` (latent; silent because callers
  use only `$0–$5`).
- **IN-03:** Same register-restore bug in `un.StrExtract`
  (`src/installer/go-mapi.nsi:526-567`).
- **IN-04:** `DetectWebView2` leaves `SetRegView 32` active on exit
  (benign today; hazard for future registry writes after the call).
- **IN-05:** `previousClient:null` detection uses naive substring
  match; fails on a contrived previous-client name containing the
  literal JSON key:value pair.
- **IN-06:** `AumidReader.ps1` `Add-Type` guard keys off
  `GoMapi.AumidReader.Reader`, but `PublicReader` is the actual entry
  point — rename the guard symbol.

None of the deferred items are security-critical or block Phase 10 from
proceeding to verification.

---

_Fixed: 2026-04-20T13:02:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
