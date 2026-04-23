---
phase: quick/260423-msq
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - src/interceptor/fs_utils.h
  - src/interceptor/fs_utils.cpp
  - src/interceptor/main.cpp
  - src/interceptor/CMakeLists.txt
  - src/app/paths.go
  - src/app/paths_test.go
  - src/app/frontend/src/App.svelte
  - scripts/diagnostics/collect-registration.ps1
  - scripts/diagnostics/collect-runtime.ps1
  - src/installer/go-mapi.nsi
  - CLAUDE.md
autonomous: true
requirements: []
must_haves:
  truths:
    - "DLL writes MAPI JSON to %LOCALAPPDATA%\\go-mapi\\queue\\ regardless of calling process's TEMP override"
    - "DLL creates both queue/ and queue/errors/ on DllMain attach"
    - "Wails watcher watches the same %LOCALAPPDATA%\\go-mapi\\queue\\ path — no divergence"
    - "Env vars TEMP and TMP have ZERO influence on go resolution of watcherDir() (proven by test)"
    - "Operator can run scripts/diagnostics/collect-registration.ps1 on a user machine and get registry + DLL bitness + export probe in a timestamped .txt"
    - "Operator can run scripts/diagnostics/collect-runtime.ps1 and get queue tree + log tails + loaded-DLL process list"
  artifacts:
    - path: "src/interceptor/fs_utils.h"
      provides: "GetQueueDirectory() renamed interface (replaces GetTempPath)"
    - path: "src/interceptor/fs_utils.cpp"
      provides: "SHGetFolderPathW(CSIDL_LOCAL_APPDATA)-based queue resolution + errors/ subdir creation"
    - path: "src/app/paths.go"
      provides: "watcherDir() resolving via %LOCALAPPDATA%\\go-mapi\\queue, ignoring TEMP/TMP"
    - path: "src/app/paths_test.go"
      provides: "Failing-first test that pins TEMP/TMP irrelevance + LOCALAPPDATA precedence"
    - path: "scripts/diagnostics/collect-registration.ps1"
      provides: "Registry + PE bitness + export probe collector"
    - path: "scripts/diagnostics/collect-runtime.ps1"
      provides: "Queue tree + log tails + loaded-DLL process collector"
  key_links:
    - from: "src/interceptor/main.cpp"
      to: "FsUtils::EnsureOutputDirectory"
      via: "DllMain DLL_PROCESS_ATTACH"
      pattern: "EnsureOutputDirectory"
    - from: "src/app/app.go"
      to: "watcherDir()"
      via: "Startup wiring to EmailWatcher"
      pattern: "watchDir := watcherDir\\(\\)"
    - from: "src/interceptor/CMakeLists.txt"
      to: "shell32 system library"
      via: "target_link_libraries — required by SHGetFolderPathW"
      pattern: "shell32"
---

<objective>
Relocate the MAPI interceptor's JSON queue from `%TEMP%\go-mapi\` to `%LOCALAPPDATA%\go-mapi\queue\` so that per-process TEMP overrides (legacy apps setting `TEMP=C:\TEMP\marc\…`) can no longer redirect the DLL's output away from the Wails watcher. Add two diagnostic PS1 scripts under `scripts/diagnostics/` for future "Report bug" support bundles.

Purpose: Fix a confirmed bug — a Spanish legacy app overrides TEMP process-locally, so the DLL writes its JSON into the app's private TEMP, and the Wails watcher (correctly watching the *user's* TEMP) never sees those files. `%LOCALAPPDATA%` via `SHGetFolderPathW(CSIDL_LOCAL_APPDATA)` is session-scoped and cannot be overridden by env vars, making the path invariant across every process that loads the DLL. Flag-day change, no migration, no backwards-compat.

Output:
- C++ DLL writing to `%LOCALAPPDATA%\go-mapi\queue\` (with `errors/` subdir pre-created).
- Wails Go app watching the same path, with TEMP/TMP completely removed from the resolution order.
- Two diagnostic PS1 scripts that can be invoked by a future in-app "Report bug" button (or run manually by a support contact) to produce timestamped text reports.
- User-visible string in `App.svelte` updated to reflect the new path.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@CLAUDE.md
@src/interceptor/fs_utils.h
@src/interceptor/fs_utils.cpp
@src/interceptor/main.cpp
@src/interceptor/CMakeLists.txt
@src/app/paths.go
@src/app/paths_test.go
@src/app/watcher_bridge.go

<interfaces>
<!-- Current contracts (pre-change) the executor must preserve compatibility for where noted. -->

From src/interceptor/fs_utils.h (current — to be RENAMED in Task 1):
```cpp
namespace go_mapi {
class FsUtils {
public:
    static std::wstring GetTempPath();         // RENAME -> GetQueueDirectory()
    static bool EnsureOutputDirectory();       // keep name; impl now creates queue/ AND queue/errors/
    static std::wstring GenerateUniqueFilename();
    static bool WriteFile(const std::wstring& filePath, const std::string& content);
private:
    static std::wstring GetBaseTempDir();      // RENAME -> GetBaseQueueDir()
    static std::string GetRandomSuffix();
};
}
```

From src/app/paths.go (current — to be REWRITTEN in Task 2):
```go
// Pre-change behaviour:
//   GOMAPI_WATCH_DIR > TEMP > TMP > os.TempDir()   all joined with "go-mapi"
// Post-change behaviour:
//   GOMAPI_WATCH_DIR > %LOCALAPPDATA%\go-mapi\queue > (fallback for POSIX test compile)
// TEMP and TMP env vars MUST NOT influence resolution — enforced by test.
func watcherDir() string { ... }
```

From src/app/app.go:144 (UNCHANGED — downstream consumer):
```go
watchDir := watcherDir()   // gets passed to EmailWatcher; no change to call site
```

Callers of the DLL-side API (searched via grep across src/interceptor/):
- `FsUtils::EnsureOutputDirectory()` — called from `main.cpp` DllMain
- `FsUtils::GetTempPath()` — if called from `mapi_impl.cpp` or `json_writer.cpp`, executor MUST grep and update ALL call sites to `GetQueueDirectory()`
- `FsUtils::GenerateUniqueFilename()` — unchanged
- `FsUtils::WriteFile()` — unchanged

Wails app call sites of the OLD path string — executor MUST grep for any literal `%TEMP%\go-mapi`, `TEMP\go-mapi`, or similar string in:
- src/app/*.go
- src/app/frontend/src/**/*.{svelte,ts}
- Known hit: src/app/frontend/src/App.svelte:270 — user-facing error banner mentions "%TEMP%\go-mapi\". Update to "%LOCALAPPDATA%\go-mapi\queue\".
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: DLL-side — relocate queue to %LOCALAPPDATA%\go-mapi\queue\ and create errors/ subdir</name>
  <files>
    src/interceptor/fs_utils.h,
    src/interceptor/fs_utils.cpp,
    src/interceptor/main.cpp,
    src/interceptor/CMakeLists.txt
  </files>
  <action>
Read-before-write: open `src/interceptor/fs_utils.h` and `fs_utils.cpp` fully (already in context), then grep the interceptor tree for callers:

```
grep -rn "GetTempPath\|GetBaseTempDir" src/interceptor/
```

Update every call site you find — do NOT leave any reference to the old names.

**fs_utils.h changes:**
- Rename public `GetTempPath()` → `GetQueueDirectory()`. Keep return type `std::wstring`. Update the doc comment to say: `// Get the queue directory path (e.g., %LOCALAPPDATA%\go-mapi\queue\) — invariant regardless of the calling process's TEMP/TMP environment.`
- Rename private `GetBaseTempDir()` → `GetBaseQueueDir()`. Doc: `// Get base queue directory (%LOCALAPPDATA%\go-mapi\queue) without trailing separator.`
- `EnsureOutputDirectory()` — name unchanged; doc must now say: `// Ensure the queue directory and the queue/errors subdirectory both exist (create if needed).`
- Keep `GenerateUniqueFilename()` and `WriteFile()` exactly as-is.

**fs_utils.cpp changes:**
- Add `#include <shlobj.h>` for `SHGetFolderPathW` and `CSIDL_LOCAL_APPDATA`.
- Replace the body of `GetBaseQueueDir()`:
  ```cpp
  std::wstring FsUtils::GetBaseQueueDir() {
      wchar_t path[MAX_PATH];
      HRESULT hr = SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, SHGFP_TYPE_CURRENT, path);
      if (FAILED(hr)) {
          return L"";
      }
      std::wstring result(path);
      if (!result.empty() && result.back() != L'\\') {
          result += L'\\';
      }
      result += L"go-mapi\\queue";
      return result;
  }
  ```
  Rationale (inline comment in the code): `CSIDL_LOCAL_APPDATA` is session-scoped and NOT influenced by per-process `TEMP`/`TMP` env overrides — fixes the legacy-app-overrides-TEMP bug where the DLL and the watcher disagreed on the queue location.
- Update `GetQueueDirectory()` to call `GetBaseQueueDir()` and append trailing `\\`.
- Rewrite `EnsureOutputDirectory()` to create BOTH the base queue dir AND its `errors` subdir. Use `SHCreateDirectoryExW` (handles nested creation; `ERROR_ALREADY_EXISTS` is success) for both paths:
  ```cpp
  bool FsUtils::EnsureOutputDirectory() {
      std::wstring queueDir = GetBaseQueueDir();
      if (queueDir.empty()) return false;
      int rc = SHCreateDirectoryExW(nullptr, queueDir.c_str(), nullptr);
      if (rc != ERROR_SUCCESS && rc != ERROR_ALREADY_EXISTS && rc != ERROR_FILE_EXISTS) {
          return false;
      }
      std::wstring errorsDir = queueDir + L"\\errors";
      rc = SHCreateDirectoryExW(nullptr, errorsDir.c_str(), nullptr);
      return rc == ERROR_SUCCESS || rc == ERROR_ALREADY_EXISTS || rc == ERROR_FILE_EXISTS;
  }
  ```
- Keep the existing `#pragma comment(lib, "shlwapi.lib")` (still used elsewhere if applicable; if unused, remove it — use `grep` on the file to confirm).

**main.cpp changes:**
- No logic change. If it imports / references `GetTempPath()` via any helper, update to `GetQueueDirectory()`. The `DllMain DLL_PROCESS_ATTACH` call to `EnsureOutputDirectory()` stays as-is.

**CMakeLists.txt changes:**
- Link `shell32` on both MSVC and MinGW branches (required by `SHGetFolderPathW` and `SHCreateDirectoryExW`). Current file links `kernel32 user32` — add `shell32`:
  - MSVC branch (~line 77): `target_link_libraries(go-mapi PRIVATE kernel32.lib user32.lib shell32.lib)`
  - MinGW branch (~line 84): `target_link_libraries(go-mapi PRIVATE kernel32 user32 shell32 -static-libgcc -static-libstdc++)`

**TDD posture for C++ side:** There is a `src/interceptor/test-harness/` and a `tests/` doctest setup. Check `src/interceptor/tests/` for any existing `fs_utils_tests.cpp` or similar (grep for `fs_utils` in the tests dirs). If a unit harness for `FsUtils` exists, add a test that:
- Asserts `GetQueueDirectory()` ends with `\\go-mapi\\queue\\`.
- Asserts `EnsureOutputDirectory()` returns true and that both `queue/` and `queue/errors/` exist afterward on a tempdir-redirected CSIDL (if the harness supports injection — otherwise just call it once and assert the paths exist on the real system, clean up after).
If NO such harness exists for `FsUtils`, proceed impl-first and add a TODO comment at the top of `fs_utils.cpp`: `// TODO: cover GetQueueDirectory + EnsureOutputDirectory in a future C++ unit harness.` Do NOT invent a new harness in this quick task (scope-discipline).

**Build verification:**
Run the DLL build via the npm workspace script (this is the canonical path — do not hand-invoke CMake):

```
npm run build:interceptor
```

A clean build must produce `src/interceptor/build/bin/go-mapi.dll` with no new warnings or link errors. If the doctest suite runs as part of the build (`ctest --output-on-failure` from the build dir), run it too and confirm green.
  </action>
  <verify>
    <automated>cd /c/dev/go-mapi && npm run build:interceptor 2>&1 | tail -30 && [ -f src/interceptor/build/bin/go-mapi.dll ] && echo "DLL_OK"</automated>
  </verify>
  <done>
    - `fs_utils.h` public API renamed to `GetQueueDirectory()`; private helper renamed to `GetBaseQueueDir()`.
    - `fs_utils.cpp` uses `SHGetFolderPathW(CSIDL_LOCAL_APPDATA)`, appends `\\go-mapi\\queue`, and `EnsureOutputDirectory()` creates both `queue\\` and `queue\\errors\\` via `SHCreateDirectoryExW`.
    - All interceptor-side callers of the old names compile (grep returns zero references to `GetTempPath` and `GetBaseTempDir` under `src/interceptor/`).
    - `CMakeLists.txt` links `shell32` on both MSVC and MinGW branches.
    - `npm run build:interceptor` succeeds, `go-mapi.dll` is produced, no new compiler warnings.
    - If a C++ test harness for `FsUtils` existed, a test was added; otherwise a TODO comment marks the follow-up.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: Go/Wails-side — RED-first test, then rewrite watcherDir() to use %LOCALAPPDATA%\go-mapi\queue\ and update user-visible path string</name>
  <files>
    src/app/paths_test.go,
    src/app/paths.go,
    src/app/frontend/src/App.svelte
  </files>
  <behavior>
    RED-phase test must assert ALL of the following before any implementation change is made:
    - `GOMAPI_WATCH_DIR` takes precedence and is returned as-is (no join, no suffix) — existing behaviour preserved.
    - With `GOMAPI_WATCH_DIR` empty, setting `TEMP` and `TMP` to arbitrary non-existent paths MUST NOT influence the result — the resolved dir must NOT contain either of those values as a substring. This is the core regression guard for the TEMP-override bug.
    - With `GOMAPI_WATCH_DIR` empty and `LOCALAPPDATA` set, `watcherDir()` returns `filepath.Join(LOCALAPPDATA, "go-mapi", "queue")` exactly.
    - With `GOMAPI_WATCH_DIR` and `LOCALAPPDATA` both empty, `watcherDir()` returns a non-empty string (platform fallback — does not matter which, only that callers never get "").
    - The existing `TestAppDataDir_EnvPrecedence` must continue to pass unchanged (that test covers `appDataDir()`, a separate path that intentionally stays at `%APPDATA%\go-mapi`).
  </behavior>
  <action>
**Read-before-write:** `src/app/paths.go` and `src/app/paths_test.go` are already in context. Also grep for other consumers of the watcher-path concept in the Go tree:

```
grep -rn "watcherDir\|GOMAPI_WATCH_DIR\|%TEMP%.*go-mapi" src/app/
```

Confirm `src/app/app.go:144` (`watchDir := watcherDir()`) is the only production call site — if you find more, they're already shielded by the function boundary and need no edit.

**Step A (RED) — rewrite `paths_test.go`'s `TestWatcherDir_EnvPrecedence` BEFORE touching `paths.go`:**

Replace the existing `TestWatcherDir_EnvPrecedence` with a new shape that matches the `<behavior>` block above. Suggested subtests (keep `t.Setenv` pattern — no `t.Parallel`):

```go
func TestWatcherDir_EnvPrecedence(t *testing.T) {
    overrideDir := filepath.Join(t.TempDir(), "override")
    localAppData := filepath.Join(t.TempDir(), "localappdata")

    t.Run("GOMAPI_WATCH_DIR wins — used as-is", func(t *testing.T) {
        t.Setenv("GOMAPI_WATCH_DIR", overrideDir)
        t.Setenv("LOCALAPPDATA", localAppData)
        t.Setenv("TEMP", "C:\\BOGUS\\TEMP")
        t.Setenv("TMP", "C:\\BOGUS\\TMP")
        if got := watcherDir(); got != overrideDir {
            t.Errorf("watcherDir() = %q, want %q (as-is)", got, overrideDir)
        }
    })

    t.Run("LOCALAPPDATA used when GOMAPI_WATCH_DIR empty — TEMP and TMP ignored", func(t *testing.T) {
        t.Setenv("GOMAPI_WATCH_DIR", "")
        t.Setenv("LOCALAPPDATA", localAppData)
        bogusTemp := filepath.Join(t.TempDir(), "process-local-temp")
        bogusTmp  := filepath.Join(t.TempDir(), "process-local-tmp")
        t.Setenv("TEMP", bogusTemp)
        t.Setenv("TMP", bogusTmp)
        want := filepath.Join(localAppData, "go-mapi", "queue")
        got := watcherDir()
        if got != want {
            t.Errorf("watcherDir() = %q, want %q", got, want)
        }
        // Regression guard for the bug this plan fixes: TEMP/TMP must have zero influence.
        if strings.Contains(got, bogusTemp) || strings.Contains(got, bogusTmp) {
            t.Errorf("watcherDir() = %q leaked TEMP=%q or TMP=%q into the path", got, bogusTemp, bogusTmp)
        }
    })

    t.Run("non-empty fallback when LOCALAPPDATA and GOMAPI_WATCH_DIR both empty", func(t *testing.T) {
        t.Setenv("GOMAPI_WATCH_DIR", "")
        t.Setenv("LOCALAPPDATA", "")
        if got := watcherDir(); got == "" {
            t.Error("watcherDir() returned empty string with no env vars set — callers assume non-empty")
        }
    })
}
```

Add `"strings"` to the imports in `paths_test.go` if not already present.

Run `go test ./src/app/... -run TestWatcherDir` and confirm RED (the `LOCALAPPDATA` subtest must fail because current `paths.go` still joins against `TEMP`). Commit if you commit per-cycle: `test(quick/260423-msq): assert watcherDir ignores TEMP/TMP and resolves via LOCALAPPDATA`.

**Step B (GREEN) — rewrite `watcherDir()` in `paths.go`:**

Replace the function body with:

```go
// watcherDir returns the directory that the MAPI interceptor DLL writes email JSON files to.
//
// As of quick/260423-msq: the DLL resolves this via SHGetFolderPathW(CSIDL_LOCAL_APPDATA)
// + "\\go-mapi\\queue", which is session-scoped and immune to per-process TEMP/TMP
// overrides (fixes the bug where legacy apps overriding TEMP redirected MAPI JSON away
// from the watcher). The Go side mirrors that resolution by reading LOCALAPPDATA directly.
//
// Precedence:
//  1. GOMAPI_WATCH_DIR — used as-is (test override / RDS per-session override).
//  2. %LOCALAPPDATA%\go-mapi\queue — production path; must match the DLL.
//  3. Platform fallback (os.UserCacheDir) — keeps Go test compile green on POSIX CI.
//
// TEMP and TMP are intentionally NOT consulted — doing so would reintroduce the bug.
func watcherDir() string {
    if dir := os.Getenv("GOMAPI_WATCH_DIR"); dir != "" {
        return dir
    }
    if localAppData := os.Getenv("LOCALAPPDATA"); localAppData != "" {
        return filepath.Join(localAppData, "go-mapi", "queue")
    }
    if cacheDir, err := os.UserCacheDir(); err == nil {
        return filepath.Join(cacheDir, "go-mapi", "queue")
    }
    return filepath.Join(".", "go-mapi", "queue")
}
```

Leave `appDataDir()` UNTOUCHED — it serves a different purpose (`%APPDATA%\go-mapi\` for settings.json and app.log) and is out of scope per the task context.

Run `go test ./src/app/... -run TestWatcherDir` and confirm GREEN. Then run the full `src/app` test suite with `-race` to match the per-PR CI gate:

```
go test -race ./internal/mapi/... ./src/app/...
```

Must be fully green.

**Step C — update the user-facing path string:**

In `src/app/frontend/src/App.svelte` around line 270, the current text is:

```
<p>go-mapi can't watch %TEMP%\go-mapi\. Restart the app, or check app.log for details.</p>
```

Replace with:

```
<p>go-mapi can't watch %LOCALAPPDATA%\go-mapi\queue\. Restart the app, or check app.log for details.</p>
```

No component logic changes. Run the frontend test + check gates:

```
npm run -w @marcfargas/go-mapi-app-frontend test:run
npm run -w @marcfargas/go-mapi-app-frontend check
```

Both must pass.

**Commit cadence:** atomic commits per logical unit — RED test, then impl+String update together (or two commits if svelte-check runs separately). Use `test(quick/260423-msq): …` and `feat(quick/260423-msq): relocate watcher to LOCALAPPDATA\go-mapi\queue` prefixes per project conventions.
  </action>
  <verify>
    <automated>cd /c/dev/go-mapi && go test -race ./internal/mapi/... ./src/app/... 2>&1 | tail -20 && npm run -w @marcfargas/go-mapi-app-frontend test:run 2>&1 | tail -10 && npm run -w @marcfargas/go-mapi-app-frontend check 2>&1 | tail -10</automated>
  </verify>
  <done>
    - `TestWatcherDir_EnvPrecedence` has been rewritten and now includes an explicit regression guard that fails if TEMP or TMP leaks into the resolved path.
    - `watcherDir()` in `paths.go` resolves via `GOMAPI_WATCH_DIR` → `LOCALAPPDATA` → `os.UserCacheDir` fallback — no TEMP/TMP lookup anywhere.
    - Full `go test -race ./internal/mapi/... ./src/app/...` is green.
    - Frontend Vitest and svelte-check are green after the App.svelte path-string update.
    - `appDataDir()` and its test are UNCHANGED (scope-discipline).
  </done>
</task>

<task type="auto">
  <name>Task 3: Diagnostics scripts (collect-registration.ps1, collect-runtime.ps1) + installer + CLAUDE.md doc bump</name>
  <files>
    scripts/diagnostics/collect-registration.ps1,
    scripts/diagnostics/collect-runtime.ps1,
    src/installer/go-mapi.nsi,
    CLAUDE.md
  </files>
  <action>
**Read-before-write:** Confirm `scripts/diagnostics/` does not yet exist (`ls scripts/diagnostics 2>&1` → no such directory). Create it. Also confirm, per the already-read `go-mapi.nsi`, that the installer does NOT pre-create anything under `%TEMP%\go-mapi` — it only installs to `$INSTDIR` ($PROGRAMFILES64\go-mapi) and writes registry keys + `%ProgramData%\go-mapi\uninst\`. This means **no installer logic changes are needed** for the path relocation itself; the DLL creates the queue dir at DllMain time. Surface this in the NSI file only as a comment.

**1. `scripts/diagnostics/collect-registration.ps1` (NEW)**

Top-level contract:
- Parameter: `[string]$OutputDir = "$env:USERPROFILE\Desktop"` with default landing on Desktop for easy bug-report attach; overridable.
- Produces a timestamped `.txt` file: `$OutputDir\go-mapi-registration-<yyyyMMdd-HHmmss>.txt`.
- All output goes into that file (use `Add-Content -LiteralPath $out -Value …` or `*>&1 | Tee-Object -FilePath $out -Append`). Do NOT dump to console beyond the final "Report written to: …" line.
- Must NOT require admin unless a section specifically needs it; wrap each section in `try/catch` and record `ACCESS_DENIED` inline rather than aborting.

Sections (in order, each with a banner like `=== Section: HKLM Mail clients ===`):
1. **Header** — script version `1.0`, timestamp, `$env:COMPUTERNAME`, `$env:USERNAME`, `[Environment]::OSVersion.VersionString`, `[Environment]::Is64BitOperatingSystem`, `[Environment]::Is64BitProcess`.
2. **HKLM mail clients (native view)** — `Get-ChildItem 'HKLM:\SOFTWARE\Clients\Mail' -ErrorAction SilentlyContinue | Format-List` and `Get-ItemProperty 'HKLM:\SOFTWARE\Clients\Mail' -ErrorAction SilentlyContinue`.
3. **HKLM mail clients (WOW6432 view)** — same thing under `HKLM:\SOFTWARE\WOW6432Node\Clients\Mail`.
4. **HKLM go-mapi registration** — dump every value under `HKLM:\SOFTWARE\Clients\Mail\go-mapi` and `HKLM:\SOFTWARE\WOW6432Node\Clients\Mail\go-mapi` if present.
5. **DLL presence and PE bitness** — read `$dllPath = 'C:\Program Files\go-mapi\go-mapi.dll'` (also try `${env:ProgramFiles(x86)}\go-mapi\go-mapi.dll` as a fallback). If present, parse the PE header manually to report 32-bit vs 64-bit: read bytes at offset 0x3C (`e_lfanew`), then at `e_lfanew + 4 + 20` (the optional header magic — `0x10B` = PE32/x86, `0x20B` = PE32+/x64). Use `[System.IO.File]::ReadAllBytes` + bit twiddling. Report file size + SHA256 (`Get-FileHash -Algorithm SHA256`).
6. **DLL export probe (in-process)** — use `Add-Type` with a small C# shim that calls `LoadLibraryExW` with `LOAD_LIBRARY_AS_DATAFILE` and `GetProcAddress` for each expected export: `MAPISendMail`, `MAPISendMailW`, `MAPILogon`, `MAPILogoff`, `MAPIFreeBuffer`, `MAPISendDocuments`. Record "found" / "NOT found" per export, and `GetLastError` on failure. Note in the banner: this section probes the CURRENT PowerShell architecture (64-bit unless explicitly launched 32-bit); to probe the 32-bit side, the support contact should re-run in `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`.
7. **Footer** — "Report written to: $out" echoed to console (this is the only console output).

Keep the script self-contained — no module imports, no external binaries. Target Windows PowerShell 5.1 (pre-installed everywhere) — do NOT require PowerShell 7. Use `Set-StrictMode -Version Latest`. `#Requires -Version 5.1` at the top.

**2. `scripts/diagnostics/collect-runtime.ps1` (NEW)**

Top-level contract — same parameter/output pattern as script 1, producing `$OutputDir\go-mapi-runtime-<yyyyMMdd-HHmmss>.txt`.

Sections:
1. **Header** — same as script 1.
2. **Queue directory tree** — `$queueRoot = Join-Path $env:LOCALAPPDATA 'go-mapi\queue'`. If present: `Get-ChildItem -LiteralPath $queueRoot -Recurse -Force | Format-Table FullName, Length, LastWriteTime -AutoSize | Out-String -Width 240`. Count top-level `*.json` files and print summary.
3. **Errors subdir** — `$errorsDir = Join-Path $queueRoot 'errors'`. List every file; for each `.error` file, print filename + its full contents (these are small reason files, safe to include).
4. **Interceptor log tail** — `$interceptorLog = Join-Path $env:LOCALAPPDATA 'go-mapi\queue\interceptor.log'` (if the DLL writes a log there; otherwise fall back to `$env:TEMP\go-mapi\interceptor.log` with a note that it's the pre-fix location — useful for diagnosing the case where an installer upgrade didn't take). `Get-Content -LiteralPath $interceptorLog -Tail 200`.
5. **App log tail** — `$appLog = Join-Path $env:APPDATA 'go-mapi\app.log'` (unchanged — per the task context, app.log stays at `%APPDATA%\go-mapi\app.log`). `Get-Content -LiteralPath $appLog -Tail 200`.
6. **Processes currently holding go-mapi.dll** — `Get-Process | Where-Object { $_.Modules | Where-Object { $_.ModuleName -ieq 'go-mapi.dll' } } | Select-Object Id, ProcessName, @{N='DllPath';E={($_.Modules | Where-Object ModuleName -ieq 'go-mapi.dll').FileName}} | Format-Table -AutoSize | Out-String -Width 240`. Wrap in try/catch — enumerating every process's Modules can hit access-denied on protected processes; swallow those silently.
7. **Env snapshot (sanitized)** — print `LOCALAPPDATA`, `APPDATA`, `USERPROFILE`, `TEMP`, `TMP` for diagnostic context. These are user-level env vars — not secrets — and are exactly what's needed to explain path surprises.
8. **Footer** — "Report written to: $out" console echo.

Same PowerShell version + strict-mode requirements as script 1.

**3. `src/installer/go-mapi.nsi`**

Add a one-line comment near the top (after the existing D-## block around line 20) recording the flag-day path change for future archaeology:

```
;   QUICK-260423-msq — DLL queue relocated from %TEMP%\go-mapi\ to
;   %LOCALAPPDATA%\go-mapi\queue\ (DLL creates it at DllMain; installer does not
;   pre-create it — no install-time action required for the path itself).
```

No functional NSI changes. Do NOT add the diagnostic scripts to the installer payload in this quick task (scope-discipline — the task brief says "ship with the installer for future Report bug support", but wiring the Report-bug button and installer payload is a follow-up; leave the scripts available on-disk in the repo and documented in CLAUDE.md).

**4. `CLAUDE.md`**

Two surgical edits — read the file first, then use Edit (not Write — do not rewrite the whole file):

- Anywhere `%TEMP%\go-mapi\` appears as the queue location description, replace with `%LOCALAPPDATA%\go-mapi\queue\`. Known hits (verify by grep): the Architecture section's "filesystem IPC" paragraph, "Data Flow" email-arrival step 1, Privacy section, the Logging section's DLL log pointer if any.
- Leave `%APPDATA%\go-mapi\app.log` UNCHANGED — app.log is not moving.
- Also leave the `%TEMP%\go-mapi\errors\` reference in the MAPI-DLL error-handling paragraph updated to `%LOCALAPPDATA%\go-mapi\queue\errors\`.

Grep before and after to confirm no stale `%TEMP%\go-mapi` references remain in CLAUDE.md:

```
grep -n "TEMP.*go-mapi" CLAUDE.md
```

Post-edit, this grep should return zero lines (or only lines that are deliberately historical context).

**Verification scripts:**

After writing both .ps1 files, syntax-parse them without executing (no registry / filesystem mutation happens on parse):

```
powershell -NoProfile -NonInteractive -Command "$null = [System.Management.Automation.Language.Parser]::ParseFile('scripts/diagnostics/collect-registration.ps1', [ref]$null, [ref]$null); $null = [System.Management.Automation.Language.Parser]::ParseFile('scripts/diagnostics/collect-runtime.ps1', [ref]$null, [ref]$null); 'OK'"
```

Both files must parse without errors.

Also smoke-run `collect-runtime.ps1` once (safe — read-only) with a tempdir output to confirm it produces a file:

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/diagnostics/collect-runtime.ps1 -OutputDir $env:TEMP
```

Expect a "Report written to: …" line and the file should exist and be non-empty. Delete afterwards.

Do NOT smoke-run `collect-registration.ps1` in automation — the PE-parsing + LoadLibrary section assumes the DLL is installed, which it may not be on the dev machine; manual verification is fine.
  </action>
  <verify>
    <automated>cd /c/dev/go-mapi && powershell -NoProfile -NonInteractive -Command "$e=$null; $null=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'scripts/diagnostics/collect-registration.ps1'), [ref]$null, [ref]$e); if($e){$e|Out-String;exit 1}; $null=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'scripts/diagnostics/collect-runtime.ps1'), [ref]$null, [ref]$e); if($e){$e|Out-String;exit 1}; 'PARSE_OK'" && ! grep -q "%TEMP%.go-mapi" CLAUDE.md && echo "CLAUDEMD_CLEAN"</automated>
  </verify>
  <done>
    - `scripts/diagnostics/collect-registration.ps1` exists, parses clean, covers all 7 sections.
    - `scripts/diagnostics/collect-runtime.ps1` exists, parses clean, smoke-runs and produces a report file.
    - `src/installer/go-mapi.nsi` has the QUICK-260423-msq archaeology comment; no functional changes.
    - `CLAUDE.md` has all `%TEMP%\go-mapi` queue references updated to `%LOCALAPPDATA%\go-mapi\queue`; `%APPDATA%\go-mapi\app.log` preserved.
    - No lockfile changes (no npm install run — rule surfaced in task context does not apply).
  </done>
</task>

</tasks>

<verification>
End-to-end checks for the quick task overall:

1. `npm run build:interceptor` builds the DLL cleanly with `shell32` linked (Task 1).
2. `go test -race ./internal/mapi/... ./src/app/...` is fully green, with the new TEMP/TMP-leak regression guard passing (Task 2).
3. Frontend `test:run` + `check` pass with the updated user-visible path string (Task 2).
4. Both PowerShell diagnostic scripts parse cleanly; runtime script smoke-runs and produces a report (Task 3).
5. `grep -rn "%TEMP%.go-mapi" src/app/ src/interceptor/ CLAUDE.md` returns zero live references (historical milestone docs under `.planning/milestones/v2.0.0-phases/` are deliberately left alone — they describe past releases).
6. The Wails watcher (`src/app/app.go:144` → `watcherDir()`) and the DLL (`src/interceptor/fs_utils.cpp::GetBaseQueueDir`) now target byte-for-byte the same path: `%LOCALAPPDATA%\go-mapi\queue`. Confirmed by inspecting both sources post-change.
</verification>

<success_criteria>
- DLL writes to `%LOCALAPPDATA%\go-mapi\queue\` unconditionally, regardless of the calling process's TEMP/TMP env vars.
- Go watcher reads the same path; `TestWatcherDir_EnvPrecedence` includes an explicit regression guard that fails if TEMP/TMP ever leak back in.
- `queue/errors/` subdir exists on DLL load.
- Two PowerShell diagnostic scripts committed under `scripts/diagnostics/`, parse cleanly, produce timestamped text reports.
- `CLAUDE.md` and `App.svelte` reflect the new path; `app.log` at `%APPDATA%\go-mapi\app.log` is deliberately unchanged.
- All existing tests (Go `-race`, frontend Vitest, svelte-check, C++ doctest if present) green.
- No installer payload or registry-key changes — flag-day change with DLL-owned dir creation.
</success_criteria>

<output>
After completion, create `.planning/quick/260423-msq-relocate-dll-queue-to-localappdata-and-a/260423-msq-SUMMARY.md` with:
- What changed per file (1-2 lines each).
- The RED→GREEN cycle note for `paths_test.go` + `paths.go`.
- Confirmation that TEMP/TMP are no longer consulted anywhere in the path-resolution chain.
- Where the diagnostic scripts live and how to invoke them (one-liner per script).
- Any follow-ups left as TODOs (e.g., C++ FsUtils unit test, in-app "Report bug" button wiring, installer-payload inclusion of the diagnostic scripts).
</output>
