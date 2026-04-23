---
quick_id: 260423-qpx
description: Address fallback for legacy MAPI apps + fix dev-build update compare
status: complete
date: 2026-04-23
commits:
  - 5954603 fix(interceptor): promote email-shaped lpszName to address when lpszAddress empty
  - 5876088 fix(updates): treat dev builds as semver-ordered, drop always-newer shortcut
---

# Quick Task 260423-qpx — Summary

## What shipped

**Task 1 — Address fallback (C++ side)**
- `src/interceptor/message_converter.cpp`: new
  `PromoteEmailShapedNameToAddress(Recipient&)` helper applied after the
  raw `lpszName` / `lpszAddress` reads in both ANSI and Wide conversion
  paths. Promotes `name` → `address` (and clears `name`) iff `address`
  is empty and `name` contains `@`.
- 4 new TEST_CASEs in `message_converter_tests.cpp`. TDD: 2 failing
  before impl, 27/27 green after.
- **Effect:** legacy Spanish SendEmail-style app (and any Simple MAPI
  caller that only populates `lpszName` with a bare email) now produces
  JSON accepted by the Go validator.

**Task 2 — Dev-build update comparison**
- `src/app/updates.go`: removed `isDevVersion(current) -> true` shortcut
  from `isNewerVersion`. The existing `compareSemver` / `splitPrerelease`
  path already handles dev/prerelease correctly.
- New `TestIsNewerVersion_DevBuildNotOfferedDowngrade` with 8 sub-cases.
  Bug case `3.0.0-dev vs 2.1.0` now correctly returns false.
- **Effect:** Marc on `3.0.0-dev` no longer sees a v2.1.0 downgrade offer.
  Behavior preserved: tagged releases still surface to dev builds of the
  same main version; `0.0.0-dev` (ldflags default) still sees every
  release.

## Verification

End-to-end rebuild after both commits:
- C++ message_converter_tests: **27/27 green**
- Go `./internal/mapi/... ./src/app/...`: **all green** (12.5 s for src/app)
- x64 DLL: `PE32+ x86-64` (1.46 MB)
- x86 DLL: `PE32 Intel i386` (1.45 MB)
- Wails app: `go-mapi.exe` (16.56 MB, OAuth ldflags baked in)
- Installer: `go-mapi-setup.exe` (7.10 MB, timestamp 19:18)

## Commits

| # | Hash    | Message                                                                           |
|---|---------|-----------------------------------------------------------------------------------|
| 1 | 5954603 | fix(interceptor): promote email-shaped lpszName to address when lpszAddress empty |
| 2 | 5876088 | fix(updates): treat dev builds as semver-ordered, drop always-newer shortcut      |

## Not done (scope-discipline)

- Uninstaller changes — NSI already correct per 260423-ntu. Verified
  live: x86 DLL deletion, 32-bit registry cleanup, WOW6432Node `(Default)`
  restore are all in place.
- Removal of the now-unused `isDevVersion` helper — explicitly deferred.
- Extended running-process guard that also checks for processes with
  `go-mapi.dll` loaded (not just `go-mapi.exe`) — good idea, separate task.
- Wails CLI `LDFlags` stdout redaction — small polish, separate task.

## Decision log

- The C++ promotion helper lives in `message_converter.cpp` rather than
  being duplicated into the Go side. Rationale: the shape mismatch
  originates in MAPI's API contract; fixing it at the boundary (where
  we have `lpsz*` context) is cheaper than round-tripping through JSON
  and fixing after the fact. Plus the C++ tests lock it in.
- Bar for "looks like an email" is intentionally loose (`contains '@'`
  only) — the Go side's `normalizeAddress` handles further cleanup and
  the validator's explicit checks catch anything pathological.
