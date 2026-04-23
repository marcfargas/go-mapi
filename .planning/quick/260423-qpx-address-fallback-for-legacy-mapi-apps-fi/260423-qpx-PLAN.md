---
quick_id: 260423-qpx
description: Address fallback for legacy MAPI apps + fix dev-build update compare
date: 2026-04-23
mode: quick-inline
---

# Quick Task 260423-qpx — Plan

## Context

Two distinct bugs surfaced after 260423-olq shipped (the installer with
real OAuth creds baked in). Live-testing on RDS22-2:

1. **Watcher rejects legacy messages.** Spanish SendEmail-style legacy
   app produces `recipient to[0] missing address` errors:
   ```
   TO=marc@blegal.eu
   ```
   Arrives in JSON as `{"name":"marc@blegal.eu","address":""}`. The Go
   validator in `internal/mapi/protocol.go:validateMailMessage` rejects.
   Root cause: `src/interceptor/message_converter.cpp:58-63` (and
   `:126-131` for wide) copies `lpszName` and `lpszAddress` verbatim.
   Legacy Simple MAPI callers routinely populate only `lpszName` with a
   bare email and leave `lpszAddress` NULL.

2. **Dev build offered downgrade.** On `3.0.0-dev`, the update panel
   offered "upgrade" to v2.1.0 (the newest stable tag on GitHub).
   Root cause: `src/app/updates.go:263-265` — `isDevVersion(current)`
   shortcut unconditionally returns `true` from `isNewerVersion`,
   suppressing the real semver compare.

Uninstaller concern raised in the same turn was verified as already
correct: NSI lines 657-659, 691, 701-702, 807-810 already clean the
x86 DLL, 32-bit registry view, and restore WOW6432Node `(Default)`.
No change needed.

## Task breakdown

### Task 1 — address fallback (C++, TDD)

**Files:**
- `src/interceptor/message_converter.cpp`: new
  `PromoteEmailShapedNameToAddress(r)` helper; call after the raw
  `lpszName`/`lpszAddress` reads in both `ConvertAnsiMessage` and
  `ConvertWideMessage`.
- `src/interceptor/tests/message_converter_tests.cpp`: four new
  `TEST_CASE`s covering (a) email-shaped name promoted, (b) plain
  display name NOT promoted, (c) both fields set: passthrough,
  (d) wide-path variant of (a).

**TDD cycle:**
- RED: add tests, build test harness, confirm failures on the two
  promotion cases.
- GREEN: implement helper, re-run, confirm 27/27 pass.

**Done:** legacy-app JSON no longer fails Go validator.

### Task 2 — drop dev-build update shortcut (Go, TDD)

**Files:**
- `src/app/updates.go`: remove `if isDevVersion(current) { return true }`
  from `isNewerVersion`. Keep `isDevVersion` helper; it's unused now
  but referenced in the docstring — removing it is out of scope.
- `src/app/updates_test.go`: new
  `TestIsNewerVersion_DevBuildNotOfferedDowngrade` with 8 sub-cases
  covering the downgrade case, tagged-wins-over-dev-same-main case,
  patch/minor after dev-cut cases, `0.0.0-dev` always-offer case
  (existing behavior preserved), and regular stable comparisons.

**TDD cycle:**
- RED: first sub-case `3.0.0-dev vs 2.1.0: no downgrade` fails.
- GREEN: drop shortcut, 8/8 pass.

**Done:** local dev builds no longer offered downgrades.

### Task 3 — docs (1 commit)

- `.planning/quick/260423-qpx-.../260423-qpx-PLAN.md` (this file)
- `.planning/quick/260423-qpx-.../260423-qpx-SUMMARY.md`
- `.planning/STATE.md` — "Last activity" + Quick Tasks Completed row

## Scope discipline

- NO uninstaller changes — NSI is already correct per 260423-ntu.
- NO toolchain changes.
- NO removal of the now-unused `isDevVersion` helper.
- NO broader refactoring of `compareSemver` / `splitPrerelease`.
