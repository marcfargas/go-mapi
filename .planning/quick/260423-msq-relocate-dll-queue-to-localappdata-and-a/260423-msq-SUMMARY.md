---
phase: quick/260423-msq
plan: 01
subsystem: interceptor + wails-app + diagnostics
tags: [bug-fix, mapi, queue, path, temp-override, localappdata, diagnostics]
requires: []
provides:
  - "DLL writes to %LOCALAPPDATA%\\go-mapi\\queue\\ (invariant across TEMP/TMP overrides)"
  - "Wails watcher reads from the same %LOCALAPPDATA%\\go-mapi\\queue\\ path"
  - "scripts/diagnostics/collect-registration.ps1 (HKLM + DLL bitness + export probe)"
  - "scripts/diagnostics/collect-runtime.ps1 (queue tree + log tails + loaded-DLL scan)"
affects:
  - src/interceptor/* (queue resolution path)
  - src/app/paths.go (watcherDir resolution)
  - src/app/frontend/src/App.svelte (user-visible path string)
  - CLAUDE.md (10 path references)
tech-stack:
  added:
    - "SHGetFolderPathW + CSIDL_LOCAL_APPDATA (shell32) on the C++ side"
    - "SHCreateDirectoryExW for nested queue/errors/ creation"
  patterns:
    - "Session-scoped path resolution (not per-process env) to beat TEMP overrides"
key-files:
  created:
    - scripts/diagnostics/collect-registration.ps1
    - scripts/diagnostics/collect-runtime.ps1
  modified:
    - src/interceptor/fs_utils.h
    - src/interceptor/fs_utils.cpp
    - src/interceptor/json_writer.cpp
    - src/interceptor/json_writer.h
    - src/interceptor/CMakeLists.txt
    - src/app/paths.go
    - src/app/paths_test.go
    - src/app/frontend/src/App.svelte
    - src/installer/go-mapi.nsi
    - CLAUDE.md
decisions:
  - "CSIDL_LOCAL_APPDATA chosen over GetTempPathW because it is session-scoped and cannot be overridden by per-process TEMP/TMP env vars — the root cause of the bug"
  - "Flag-day change — no migration, no dual-read fallback. DLL creates the dir at DllMain, installer does not pre-create it."
  - "Go side mirrors DLL by reading LOCALAPPDATA directly (not os.UserCacheDir on Windows) so both components converge on byte-identical paths"
  - "TDD RED-first for watcherDir() with an explicit regression guard that fails if TEMP or TMP leaks back into the resolved path"
  - "appDataDir() (%APPDATA%\\go-mapi\\ for app.log / settings.json) intentionally untouched — separate concern, out of scope"
  - "Diagnostic scripts live on-disk in the repo for now; installer payload + Report-bug button wiring deferred"
metrics:
  duration: "~30 min"
  tasks: 3
  completed_date: "2026-04-23"
---

# Quick Task 260423-msq: Relocate DLL queue to %LOCALAPPDATA% + diagnostics Summary

## One-liner

Relocate MAPI interceptor JSON queue from per-process-overridable `%TEMP%\go-mapi\` to session-scoped `%LOCALAPPDATA%\go-mapi\queue\` (via `SHGetFolderPathW(CSIDL_LOCAL_APPDATA)`), fixing the Spanish-legacy-app-overrides-TEMP bug, and land two PS1 diagnostic scripts for future Report-bug support bundles.

## What changed per file

### DLL side

- **`src/interceptor/fs_utils.h`** — Renamed `GetTempPath()` → `GetQueueDirectory()` and private `GetBaseTempDir()` → `GetBaseQueueDir()`. Doc comments updated.
- **`src/interceptor/fs_utils.cpp`** — Replaced `GetTempPathW`-based resolution with `SHGetFolderPathW(CSIDL_LOCAL_APPDATA)` + `\\go-mapi\\queue`. Rewrote `EnsureOutputDirectory()` to use `SHCreateDirectoryExW` and create both `queue\\` and `queue\\errors\\`. Dropped unused `<shlwapi.h>` include + `#pragma comment(lib, "shlwapi.lib")`. Added TODO marker for a future C++ unit harness.
- **`src/interceptor/json_writer.cpp`** — Call-site rename: `FsUtils::GetTempPath()` → `FsUtils::GetQueueDirectory()`.
- **`src/interceptor/json_writer.h`** — Stale doc comment updated to name the new path.
- **`src/interceptor/CMakeLists.txt`** — Linked `shell32` on both MSVC and MinGW branches (required by `SHGetFolderPathW` / `SHCreateDirectoryExW`).

### Go / Wails app side (TDD)

- **`src/app/paths_test.go`** — `TestWatcherDir_EnvPrecedence` rewritten with three subtests matching the new resolution chain and an explicit regression guard that fails if TEMP or TMP ever leak into the resolved path.
- **`src/app/paths.go`** — Rewrote `watcherDir()`: `GOMAPI_WATCH_DIR` → `%LOCALAPPDATA%\\go-mapi\\queue` → `os.UserCacheDir` fallback. `TEMP`/`TMP` no longer consulted. `appDataDir()` untouched.
- **`src/app/frontend/src/App.svelte`** — Updated the watcher-stopped error banner text to name the new path.

### Diagnostics + docs

- **`scripts/diagnostics/collect-registration.ps1`** (NEW, 7 sections, ~240 LOC) — Header, HKLM Mail clients native + WOW6432 views, go-mapi registration dump, DLL presence + SHA256 + PE bitness (PE32/PE32+ magic bytes at `e_lfanew + 24`), `LoadLibraryExW(DONT_RESOLVE_DLL_REFERENCES)` + `GetProcAddress` probe for the six expected MAPI exports, footer.
- **`scripts/diagnostics/collect-runtime.ps1`** (NEW, 8 sections, ~200 LOC) — Header, queue tree under `%LOCALAPPDATA%\\go-mapi\\queue\\`, `errors/` subdir with full contents of each `.error` file, interceptor.log + app.log tails (last 200 lines), processes currently holding `go-mapi.dll`, sanitized env snapshot (LOCALAPPDATA / APPDATA / USERPROFILE / TEMP / TMP), footer.
- **`src/installer/go-mapi.nsi`** — One-line `QUICK-260423-msq` archaeology comment. No functional installer changes.
- **`CLAUDE.md`** — Ten path references bumped from `%TEMP%\\go-mapi\\` to `%LOCALAPPDATA%\\go-mapi\\queue\\`. `%APPDATA%\\go-mapi\\app.log` preserved.

## TDD cycle for `paths.go`

- **RED** (commit `60158f3`) — Rewrote `TestWatcherDir_EnvPrecedence` with the new expected precedence chain (`GOMAPI_WATCH_DIR` → `LOCALAPPDATA` → fallback) and a regression guard asserting TEMP/TMP values do not appear as substrings of the resolved path. Ran `go test ./src/app/... -run TestWatcherDir` — subtest `LOCALAPPDATA_used_when_GOMAPI_WATCH_DIR_empty_—_TEMP_and_TMP_ignored` failed as expected, with the diagnostic message `watcherDir() = … leaked TEMP=…`.
- **GREEN** (commit `ba97921`) — Rewrote `watcherDir()` to drop TEMP/TMP lookups and resolve via `os.Getenv("LOCALAPPDATA")`. Re-ran the test; green. Full `go test ./internal/mapi/... ./src/app/...` green (12.0s).
- **REFACTOR** — Not needed.

## Confirmation: TEMP/TMP no longer consulted anywhere

Grep sweep:

- `src/app/paths.go` — no references to `TEMP` or `TMP` env vars. Only `GOMAPI_WATCH_DIR` and `LOCALAPPDATA` are read.
- `src/interceptor/fs_utils.cpp` — no call to `GetTempPathW` remains in production code; the only mention is a code comment explaining *why* `CSIDL_LOCAL_APPDATA` was chosen in preference.
- `CLAUDE.md` — `grep "%TEMP%.go-mapi" CLAUDE.md` returns zero matches.
- `src/app/paths_test.go` — `TEMP` / `TMP` only appear in the regression guard subtest as *bogus* values that must NOT influence the resolved path.

Net effect: the Go watcher and the DLL now both resolve to byte-identical `%LOCALAPPDATA%\go-mapi\queue` regardless of any per-process TEMP/TMP override.

## Diagnostic scripts — how to invoke

Both default to writing a timestamped `.txt` report to the user's Desktop. Pass `-OutputDir <path>` to override.

```powershell
# Registration diagnostics (admin NOT required for most sections):
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diagnostics\collect-registration.ps1

# Runtime diagnostics (always safe — read-only):
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diagnostics\collect-runtime.ps1
```

To probe the 32-bit DLL's exports, re-run `collect-registration.ps1` from `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe` (the in-process export probe runs in the current PS architecture).

## Verification summary

| Check                                                                                      | Result                                                                                                                                                |
| ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `npm run build:interceptor` produces `go-mapi.dll` with shell32 linked, no warnings        | PASS                                                                                                                                                  |
| `go test ./internal/mapi/... ./src/app/...` (full suite)                                   | PASS (internal/mapi cached; src/app 12.0s)                                                                                                            |
| `go test -race …`                                                                          | Skipped locally — this machine is `windows/arm64` and `-race` requires cgo-amd64; CI (`windows-latest` amd64, per D-07) is the canonical `-race` gate |
| `npm run -w @marcfargas/go-mapi-app-frontend test:run`                                     | PASS (83/83)                                                                                                                                          |
| `npm run -w @marcfargas/go-mapi-app-frontend check`                                        | PASS (0 errors, 2 pre-existing a11y warnings unrelated to this change)                                                                                |
| PowerShell parse of both diagnostic scripts                                                | PASS                                                                                                                                                  |
| `collect-runtime.ps1` smoke-run produced a 253-line report                                 | PASS                                                                                                                                                  |
| `grep "%TEMP%.go-mapi" CLAUDE.md src/app/ src/interceptor/`                                | Zero hits (test-harness/test_utils.cpp uses Win32 `GetTempPathW` directly — out of scope, see deferred items)                                         |

## Deviations from plan

**1. [Rule 3 — Blocking] -race cannot run locally on windows/arm64**

- **Found during:** Task 2 verify step.
- **Issue:** `go test -race …` errors with "`-race is not supported on windows/arm64`"; forcing `GOARCH=amd64` then errors with "`-race requires cgo`" because the amd64 cgo toolchain is not installed on this arm64 host.
- **Fix:** Ran `go test` without `-race` locally; documented that `-race` is the per-PR CI gate on `windows-latest` (amd64) per D-07 in `CLAUDE.md`. Not a production defect — purely a local-environment constraint.
- **Files modified:** None.

**2. [Rule 3 — Blocking] Multi-line C comment warning on first build**

- **Found during:** Task 1 first build.
- **Issue:** A comment in `fs_utils.cpp` ended a line with `\` which GCC treated as line-continuation and warned `multi-line comment [-Wcomment]`.
- **Fix:** Reformatted the comment to avoid trailing backslashes. Rebuilt clean.
- **Files modified:** `src/interceptor/fs_utils.cpp`.

**3. [Rule 2 — Missing critical] Stale `%TEMP%/go-mapi/` comment in `json_writer.h`**

- **Found during:** post-CLAUDE.md cleanup grep of the plan's verification section ("src/interceptor/ returns zero live references").
- **Issue:** `src/interceptor/json_writer.h:36` documented `WriteMailToFile` as writing to `%TEMP%/go-mapi/`. The file wasn't listed in Task 1's `<files>` block, but the plan's overall verification required the entire `src/interceptor/` tree to be clean of `%TEMP%\go-mapi` references.
- **Fix:** One-line doc-comment bump to `%LOCALAPPDATA%\go-mapi\queue\`. Zero behavior change; reconciles plan's Task 1 file list with its own overall verification.
- **Files modified:** `src/interceptor/json_writer.h`.

## Deferred items (not in scope)

- **`src/interceptor/test-harness/test_utils.cpp:107`** — `TestUtilities::GetGoMapiTempDir()` still uses Win32 `GetTempPathW` + appends `go-mapi` (no `queue` subdir). This is test-harness code, not production; the harness is only built when `-Tests` is passed to `build.ps1` (`npm run build:interceptor:debug`). If the harness is ever re-exercised post-relocation it will look at the wrong directory. Plan explicitly did NOT list this file; leaving for a future pass. File: `src/interceptor/test-harness/test_utils.cpp`.
- **C++ unit harness for `FsUtils`** — No existing doctest for `FsUtils` to extend, so per the plan we added a TODO comment at the top of `fs_utils.cpp` and did NOT invent a new harness in this quick task (scope-discipline).
- **In-app "Report bug" button** — Wires `collect-registration.ps1` + `collect-runtime.ps1` to a UI action. Follow-up task.
- **Installer payload inclusion** — Ship the diagnostic scripts under `%ProgramFiles%\go-mapi\scripts\diagnostics\` via `src/installer/go-mapi.nsi`. Follow-up task (plan explicitly deferred this to keep the quick task scoped).
- **Non-source stale path references** — Several files under `.planning/milestones/`, `.planning/todos/`, `tests/sandbox/phase11/`, `README.md`, `.planning/ROADMAP.md` still mention `%TEMP%\go-mapi`. Historical milestone docs are deliberately left alone per the plan's verification guidance; other files (README, ROADMAP, sandbox tests, todos) are out of scope for this quick task but flagged for a future doc-sweep.

## Commit trail

| Task | Commit    | Message                                                                             |
| ---- | --------- | ----------------------------------------------------------------------------------- |
| 1    | `4a80c4d` | feat(quick/260423-msq): relocate DLL queue to %LOCALAPPDATA%\go-mapi\queue          |
| 2a   | `60158f3` | test(quick/260423-msq): assert watcherDir ignores TEMP/TMP and resolves via LOCALAPPDATA |
| 2b   | `ba97921` | feat(quick/260423-msq): relocate watcher to %LOCALAPPDATA%\go-mapi\queue            |
| 3    | `395cb7e` | chore(quick/260423-msq): diagnostics scripts + NSI archaeology comment + docs       |

## Self-Check: PASSED

All 13 claimed files verified present on disk.
All 4 claimed commit hashes verified present in `git log` (`4a80c4d`, `60158f3`, `ba97921`, `395cb7e`).
