---
phase: quick/260423-ntu
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - scripts/diagnostics/collect-registration.ps1
  - scripts/diagnostics/collect-runtime.ps1
  - src/interceptor/build.ps1
  - src/interceptor/CMakeLists.txt
  - package.json
  - src/installer/go-mapi.nsi
  - src/installer/tests/installer.Tests.ps1
autonomous: true
requirements:
  - QUICK-260423-ntu-T1  # Diagnostic script null-ref fixes
  - QUICK-260423-ntu-T2  # Installer + uninstaller running-process check
  - QUICK-260423-ntu-T3  # 32-bit DLL build + dual-bitness installer
user_setup: []

must_haves:
  truths:
    - "Both `collect-registration.ps1` and `collect-runtime.ps1` run to completion on a fresh machine with NO null-reference errors — even when the MAPI (Default) value is missing and when the queue dir does not yet exist."
    - "Running `npm run build:interceptor` produces BOTH `src/interceptor/build-x64/bin/go-mapi.dll` (PE32+ / x86_64) AND `src/interceptor/build-x86/bin/go-mapi.dll` (PE32 / i686) using the triple-prefixed clang toolchain."
    - "Running `npm run build` (Wails) still succeeds on an ARM64 host where unprefixed `gcc` is shimmed to `gcc-aarch64-none-elf`, by explicitly setting `CC`/`CXX` to `x86_64-w64-mingw32-clang[++]`."
    - "Running `makensis src/installer/go-mapi.nsi` compiles the installer; install deposits the x64 DLL at `$PROGRAMFILES64\\go-mapi\\go-mapi.dll` and the x86 DLL at `$PROGRAMFILES32\\go-mapi\\go-mapi.dll`."
    - "HKLM native view (`SOFTWARE\\Clients\\Mail\\go-mapi`) `DLLPath` points at the x64 DLL; HKLM WOW6432 view (`SOFTWARE\\WOW6432Node\\Clients\\Mail\\go-mapi`) `DLLPath` points at the x86 DLL."
    - "Uninstall removes BOTH DLL files and BOTH install dirs; the new Pester cases assert this."
    - "If `go-mapi.exe` is running inside `$INSTDIR` when the installer or uninstaller starts, the user is offered a graceful close-and-retry dialog; a 10-second polling wait lets the app's `intentionalQuit` path fire before we Delete the binary."
  artifacts:
    - path: "scripts/diagnostics/collect-registration.ps1"
      provides: "Registration diagnostics without null-ref errors on missing (Default) values"
      contains: "Get-ItemProperty.*-Name '\\(Default\\)'.*-ErrorAction SilentlyContinue"
    - path: "scripts/diagnostics/collect-runtime.ps1"
      provides: "Runtime diagnostics with friendly 'queue dir not present yet' message"
    - path: "src/interceptor/build.ps1"
      provides: "Triple-prefixed clang build with -Arch {x64|x86} switch"
      contains: "i686-w64-mingw32-clang"
    - path: "src/interceptor/build-x64/bin/go-mapi.dll"
      provides: "64-bit MAPI interceptor DLL (PE32+)"
    - path: "src/interceptor/build-x86/bin/go-mapi.dll"
      provides: "32-bit MAPI interceptor DLL (PE32)"
    - path: "package.json"
      provides: "`build:interceptor:x64`, `build:interceptor:x86`, `build:interceptor` (both), and CC/CXX override for Wails build"
    - path: "src/installer/go-mapi.nsi"
      provides: "Dual-bitness install + WOW6432Node DLLPath + running-process guard"
    - path: "src/installer/tests/installer.Tests.ps1"
      provides: "Pester cases covering x86 DLL install + WOW6432 DLLPath + dual-path uninstall"
  key_links:
    - from: "package.json `build:interceptor`"
      to: "src/interceptor/build.ps1 -Arch x64 / -Arch x86"
      via: "npm-run chain"
      pattern: "build:interceptor:x64.*&&.*build:interceptor:x86"
    - from: "src/installer/go-mapi.nsi Section Install"
      to: "src/interceptor/build-x64/bin/go-mapi.dll + src/interceptor/build-x86/bin/go-mapi.dll"
      via: "NSIS `File` directives"
      pattern: "build-x86.*bin.*go-mapi\\.dll"
    - from: "src/installer/go-mapi.nsi Section Install + Section Uninstall"
      to: "EnsureAppNotRunning helper (tasklist + taskkill no-/F + 10s poll)"
      via: "`Call` into shared function"
      pattern: "EnsureAppNotRunning|un\\.EnsureAppNotRunning"
---

<objective>
Three bundled improvements in one quick task:

1. **Diagnostics:** fix NullReferenceException crashes in the two new `scripts/diagnostics/*.ps1` reports (missing `(Default)` values + missing queue dir on fresh installs).
2. **Uninstaller safety:** before deleting `$INSTDIR\go-mapi.exe`, check whether it is running — if so, offer graceful close-and-retry via `taskkill` (no `/F`) with a 10-second poll so the app's `intentionalQuit atomic.Bool` clean-shutdown path fires. Apply the same guard to the installer's upgrade path.
3. **32-bit DLL support:** now that the new `mingw-mstorsjo-llvm-ucrt` clang toolchain is multi-target, produce both x86_64 and i686 DLLs, install both, and register each in the matching registry view (native + WOW6432Node) so legacy 32-bit apps get routed too.

Purpose:
- T1 unblocks usable bug-report output from the two scripts that shipped in quick/260423-msq.
- T2 eliminates the silent "delete failed because file locked" failure that leaves leftover binaries post-uninstall.
- T3 is the main user-visible win: legacy 32-bit Windows apps (very common for the target audience) will have their MAPI calls intercepted instead of falling back to Outlook or failing.

Output:
- Updated diagnostic scripts that run clean on a fresh machine.
- Updated build pipeline that emits both DLL bitnesses with triple-prefixed clang.
- Updated installer that lays down both DLLs, registers both views, and gracefully handles a running app.
- Pester test coverage for the new installer behaviours.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@CLAUDE.md

# Current state of the files being edited
@scripts/diagnostics/collect-registration.ps1
@scripts/diagnostics/collect-runtime.ps1
@src/interceptor/build.ps1
@src/interceptor/CMakeLists.txt
@package.json
@src/installer/go-mapi.nsi
@src/installer/tests/installer.Tests.ps1

# Reference — real output showing the T1 bugs (read-only)
@tests/live/go-mapi-registration-20260423-165325.txt
@tests/live/go-mapi-runtime-20260423-165335.txt

<interfaces>
<!-- Stable literals / contracts the executor MUST preserve byte-for-byte. -->

From src/app/main.go (referenced — not edited here):
- `intentionalQuit atomic.Bool` — set to true by the tray "Quit" handler and WM_QUERYENDSESSION handler.
  `taskkill /PID <pid>` (without /F) sends WM_CLOSE, which maps to the same clean-shutdown path.
  Using /F bypasses this and can leave the queue watcher or keyring session in a bad state.

From src/installer/go-mapi.nsi (existing literals — do NOT rename):
- `InstallDir "$PROGRAMFILES64\go-mapi"` (line 47) — x64 install path
- `SetRegView 64` / `SetRegView 32` / `SetRegView default` already in use (lines 269, 282, 292, 300)
- Existing `File "${__FILEDIR__}\..\interceptor\build\bin\go-mapi.dll"` at line 84 MUST be updated to `build-x64`.

From scoop toolchain (ALREADY INSTALLED — verify via `Test-Path`):
- `$env:USERPROFILE\scoop\apps\mingw-mstorsjo-llvm-ucrt\current\bin\x86_64-w64-mingw32-clang.exe`
- `$env:USERPROFILE\scoop\apps\mingw-mstorsjo-llvm-ucrt\current\bin\x86_64-w64-mingw32-clang++.exe`
- `$env:USERPROFILE\scoop\apps\mingw-mstorsjo-llvm-ucrt\current\bin\i686-w64-mingw32-clang.exe`
- `$env:USERPROFILE\scoop\apps\mingw-mstorsjo-llvm-ucrt\current\bin\i686-w64-mingw32-clang++.exe`
- `ninja.exe` lives in the same `bin` dir.
- DO NOT touch the `gcc-aarch64-none-elf` scoop package or `~/scoop/shims/gcc.exe`.
- DO NOT rely on unprefixed `gcc` / `g++` / `cmake` on PATH — always use the absolute triple-prefixed paths.

From src/installer/tests/installer.Tests.ps1 (existing Pester v5 conventions — keep):
- `New-PesterConfiguration` / `Describe` / `Context` / `It` / `Should -BeTrue`
- NO Pester 4 `EnableExit` switch (D-30).
- Existing item numbering 1..13 — append NEW items starting at 14.
</interfaces>
</context>

<tasks>

<!--
  Task 1 — Diagnostic script null-ref fixes (small, ~8-12% context)
  TDD-lite: no Pester suite exists for these scripts yet, and writing one from
  scratch is out of scope for this quick. We verify via manual run-through on
  a machine where the queue dir does not yet exist and where the
  HKLM\SOFTWARE\Clients\Mail (Default) value is absent — matching the
  reference error output in tests/live/*.txt.
-->
<task type="auto">
  <name>Task 1: Harden diagnostic scripts against missing registry values and missing queue dir</name>
  <files>
    scripts/diagnostics/collect-registration.ps1,
    scripts/diagnostics/collect-runtime.ps1
  </files>
  <action>
    Fix the null-reference crashes observed in `tests/live/go-mapi-registration-20260423-165325.txt` and `tests/live/go-mapi-runtime-20260423-165335.txt`.

    **A. collect-registration.ps1 — three Safe-Invoke blocks to harden:**

    1. Section 2 "HKLM mail clients (native view)" (Safe-Invoke 'HKLM Mail clients', currently lines ~103-112):
       - Replace the `Get-ItemProperty ... | Format-List '(default)', '*'` chain with a guarded read:
         ```powershell
         $props = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Clients\Mail' -ErrorAction SilentlyContinue
         if ($props -and ($props.PSObject.Properties.Name -contains '(default)')) {
             Append-Line "  (default) = $($props.'(default)')"
         } else {
             Append-Line "  (default) = <not set>"
         }
         $props | Format-List * | Append-Block
         ```
       - `Set-StrictMode -Version Latest` is active at the top of the script — referencing a non-existent property throws a null-ref, which is what `tests/live/...-165325.txt` shows. The guarded read is the fix.

    2. Section 3 "HKLM mail clients (WOW6432 view)" (Safe-Invoke 'HKLM WOW6432 Mail clients', currently lines ~118-131):
       - Apply the same guarded `(default)` read pattern inside the existing `Test-Path` branch.

    3. Section 4 "HKLM go-mapi registration" (Safe-Invoke "Dump $root", currently lines ~141-156):
       - Guard the `Get-ItemProperty -LiteralPath $root | Format-List *` call: if the key has no values at all, `Format-List *` under StrictMode throws. Use:
         ```powershell
         $props = Get-ItemProperty -LiteralPath $root -ErrorAction SilentlyContinue
         if ($props) {
             $props | Format-List * | Append-Block
         } else {
             Append-Line '  (no values on this key)'
         }
         ```
       - Apply the same guard to the recursive subkey dump.

    **B. collect-runtime.ps1 — one Test-Path guard to add:**

    1. Section 2 "Queue directory tree" (currently lines ~104-120):
       - Existing `if (Test-Path -LiteralPath $queueRoot)` branch already skips when the dir is absent, so the reported null-ref must come from the ELSE branch being silently triggered AFTER a half-created tree. Inspect the actual error in `tests/live/go-mapi-runtime-20260423-165335.txt` and adjust: replace the current empty-queue message with a more verbose, actionable message:
         ```powershell
         Append-Line "(queue directory does not exist yet — this is expected on a fresh install before the first MAPI call; will be created by the DLL on first use)"
         ```
       - Additionally, if `Test-Path $queueRoot` is true but `Get-ChildItem` throws (e.g. access denied on a half-created dir), catch it inside `Safe-Invoke` — the existing `Safe-Invoke` wrapper already handles this; just verify the block's scope.

    **C. Scope discipline:** Do NOT refactor the scripts, do NOT change their output format beyond these error-path fixes, do NOT add new sections. Touch only the lines necessary to stop the null-refs.

    Commit as one atomic commit:
    - `fix(diagnostics): guard collect-*.ps1 against missing (Default) and missing queue dir`
  </action>
  <verify>
    <automated>
      powershell -NoProfile -ExecutionPolicy Bypass -Command "& {
        $out = [IO.Path]::GetTempPath();
        & scripts/diagnostics/collect-registration.ps1 -OutputDir $out;
        & scripts/diagnostics/collect-runtime.ps1 -OutputDir $out;
        $regReport = Get-ChildItem $out -Filter 'go-mapi-registration-*.txt' | Sort-Object LastWriteTime -Desc | Select-Object -First 1;
        $runReport = Get-ChildItem $out -Filter 'go-mapi-runtime-*.txt'      | Sort-Object LastWriteTime -Desc | Select-Object -First 1;
        $reg = Get-Content $regReport.FullName -Raw;
        $run = Get-Content $runReport.FullName -Raw;
        if ($reg -match 'Referencia a objeto' -or $reg -match 'NullReference' -or $reg -match 'Object reference') { throw 'registration report still contains null-ref' };
        if ($run -match 'Referencia a objeto' -or $run -match 'NullReference' -or $run -match 'Object reference') { throw 'runtime report still contains null-ref' };
        Write-Host 'OK'
      }"
    </automated>
  </verify>
  <done>
    Both diagnostic scripts run to completion on a machine where:
    (a) HKLM\SOFTWARE\Clients\Mail has no `(Default)` value, and
    (b) %LOCALAPPDATA%\go-mapi\queue does not exist.
    Neither output file contains any null-reference / "Referencia a objeto" text; every section prints either real data or a clear placeholder message. Single atomic commit.
  </done>
</task>

<!--
  Task 2 — Running-process guard in installer + uninstaller (medium, ~15-20% context)
  TDD: add a Pester case (ephemeral CI only) that starts a fake 'go-mapi.exe'
  in $INSTDIR, runs the uninstaller silently, and asserts that the uninstaller
  either (a) closed the fake app cleanly, or (b) aborted with a non-zero exit
  code. The check logic is implemented inside go-mapi.nsi as a reusable
  function pair (EnsureAppNotRunning / un.EnsureAppNotRunning) so both
  install and uninstall paths share the same code.
-->
<task type="auto" tdd="true">
  <name>Task 2: Add running-process guard to installer + uninstaller with clean-close retry</name>
  <files>
    src/installer/go-mapi.nsi,
    src/installer/tests/installer.Tests.ps1
  </files>
  <behavior>
    - When `go-mapi.exe` is NOT running in `$INSTDIR`, the installer / uninstaller proceeds unchanged (all existing 13 Pester cases stay green).
    - When `go-mapi.exe` IS running in `$INSTDIR` and the user chooses "Close and retry":
        * Uninstaller calls `taskkill /PID <pid>` (NO `/F`) → sends WM_CLOSE → app's `intentionalQuit` path fires → process exits → Delete succeeds.
        * Poll every 500 ms up to 10 s (20 iterations) for the process to exit.
        * If still running after 10 s, abort with a clear MessageBox + non-zero exit code.
    - When the user chooses "Cancel", the installer / uninstaller exits immediately with `Quit` and a non-zero exit code; no registry writes, no Deletes.
    - Silent mode (`/S`) MUST NOT block on a MessageBox — in silent mode, the function behaves as "Close and retry" automatically (CI-friendly).
    - Installer upgrade path (old go-mapi already installed + running) gets the same guard at the start of `Section "Install"` BEFORE any `File` overwrite.
  </behavior>
  <action>
    **A. Add `EnsureAppNotRunning` + `un.EnsureAppNotRunning` functions in `src/installer/go-mapi.nsi`:**

    Both functions share identical logic — NSIS requires the `un.` prefix for
    uninstaller-scope functions, so we duplicate the body (NSIS macros are the
    usual workaround but the code is small enough to inline; prefer clarity
    over macro indirection for 40 lines). Place the installer-scope function
    near `BackupPreviousMailClient` (around line 142) and the uninstaller-scope
    function near `un.RestorePreviousMailClient` (around line 515).

    Detection primitive — use `nsExec::ExecToStack` with `tasklist` to avoid
    adding a new NSIS plugin dependency:
    ```
    nsExec::ExecToStack 'tasklist /FI "IMAGENAME eq go-mapi.exe" /NH /FO CSV'
    Pop $0   ; exit code
    Pop $1   ; stdout (CSV rows, one per running instance, or "INFO: No tasks..." when none)
    ```

    Parsing: if `$1` contains the literal `go-mapi.exe` substring, at least one
    instance is running. For multi-instance defensiveness, extract the PID from
    each CSV row (`"go-mapi.exe","<PID>",...`) using NSIS's `StrCpy` substring
    primitives already used in this file (see `un.StrContains` / `un.StrExtract`
    for the existing pattern — reuse them in the uninstaller function).

    Narrow the match to the installation directory so we do NOT kill an
    unrelated `go-mapi.exe` living elsewhere. `tasklist /M` does not return the
    full image path, so add a second filter: after extracting candidate PIDs,
    call:
    ```
    nsExec::ExecToStack 'wmic process where "ProcessID=<PID>" get ExecutablePath /format:csv'
    ```
    Only include PIDs whose `ExecutablePath` starts with `$INSTDIR` (case-insensitive).
    If `wmic` is missing on the runner (removed on recent Windows 11), fall back
    to matching on image name only and document the trade-off in a comment — in
    practice, `go-mapi.exe` is unique enough that a stale duplicate is acceptable
    risk for v3.0.

    Close-and-retry primitive — for each matched PID:
    ```
    nsExec::ExecToStack 'taskkill /PID <PID>'   ; NO /F — send WM_CLOSE
    ```

    Poll loop — use NSIS `IntOp` + `Sleep 500` for 20 iterations, re-running
    `tasklist` each iteration. Exit the loop early when no matching PIDs remain.

    Silent mode detection — NSIS exposes `${Silent}` via the `!insertmacro
    SilentCheck` primitive or the `IfSilent` directive:
    ```
    IfSilent silent_retry ask_user
    ```

    Call sites:
    - `Section "Install"` (line 77): insert `Call EnsureAppNotRunning` as the
      FIRST statement, before `SetOutPath "$INSTDIR"`.
    - `Section "Uninstall"` (line 448): insert `Call un.EnsureAppNotRunning` as
      the FIRST statement, before the firewall rule delete.

    Additionally, update step 9 (line 490) from `Delete "$INSTDIR\go-mapi.exe"`
    — no change needed; after `un.EnsureAppNotRunning` has completed, the
    Delete will succeed. Keep the line as-is but add a comment noting the
    preceding guard.

    **B. Pester tests — D-21 items 14 + 15 in `src/installer/tests/installer.Tests.ps1`:**

    Append inside the existing `Context "Silent install"` block:
    ```powershell
    # QUICK-260423-ntu item 14 — install-time running-process guard (silent)
    It "14. silent install succeeds when go-mapi.exe is already running in InstallDir" {
        # Pre-condition: install completed in item 1. Launch a decoy process
        # from the installed path, then re-run the installer in /S mode and
        # assert the exe is still runnable post-install (i.e. the installer
        # closed the old instance cleanly, overwrote it, and did NOT abort).
        $exe = Join-Path $script:InstallDir 'go-mapi.exe'
        $decoy = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden
        try {
            Start-Sleep -Seconds 1
            $proc = Start-Process -FilePath $script:SetupExe -ArgumentList '/S',"/D=$($script:InstallDir)" -Wait -PassThru
            $proc.ExitCode | Should -Be 0
            Test-Path $exe | Should -BeTrue
        } finally {
            # Belt-and-braces cleanup in case the installer did not close it
            if (-not $decoy.HasExited) { $decoy.Kill() }
        }
    }
    ```

    Append inside the existing `Context "Silent uninstall"` block:
    ```powershell
    # QUICK-260423-ntu item 15 — uninstall-time running-process guard (silent)
    It "15. silent uninstall closes a running go-mapi.exe in InstallDir and removes the binary" {
        # Re-install first because item 7 already uninstalled.
        Start-Process -FilePath $script:SetupExe -ArgumentList '/S',"/D=$($script:InstallDir)" -Wait
        $exe = Join-Path $script:InstallDir 'go-mapi.exe'
        $decoy = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden
        try {
            Start-Sleep -Seconds 1
            $uninst = Join-Path $script:InstallDir 'uninstall.exe'
            $proc = Start-Process -FilePath $uninst -ArgumentList '/S' -Wait -PassThru
            $proc.ExitCode | Should -Be 0
            Start-Sleep -Seconds 2   # NSIS batch-wrapper self-delete
            Test-Path $exe | Should -BeFalse -Because "uninstaller should have closed the running instance and deleted the binary"
            $decoy.HasExited | Should -BeTrue
        } finally {
            if (-not $decoy.HasExited) { $decoy.Kill() }
        }
    }
    ```

    **C. Scope discipline:**
    - Do NOT refactor other uninstaller steps.
    - Do NOT add new NSIS plugin dependencies (tasklist + wmic only).
    - Do NOT touch `Function un.RestorePreviousMailClient` or the WebView2 install path.

    Commit as one atomic commit once the Pester tests are first added (RED —
    though they only go RED on CI, not locally, since the harness needs
    `makensis` output), then the function body makes them GREEN in the same
    commit (TDD-lite given the NSIS build gate):
    - `feat(installer): guard install+uninstall against running go-mapi.exe`
  </action>
  <verify>
    <automated>
      powershell -NoProfile -ExecutionPolicy Bypass -Command "& {
        # Compile check only — the full Pester run requires windows-latest CI because it mutates HKLM + ProgramFiles.
        $nsi = 'src/installer/go-mapi.nsi';
        if (-not (Get-Command makensis -ErrorAction SilentlyContinue)) {
          Write-Host 'makensis not on PATH — skipping compile check';
          exit 0
        }
        Push-Location src/installer;
        try {
          makensis -DGOMAPI_VERSION=3.0.0-dev go-mapi.nsi 2>&1 | Tee-Object -Variable out | Out-Null;
          if ($LASTEXITCODE -ne 0) { throw (\"makensis failed: \" + ($out -join [Environment]::NewLine)) };
          # Sanity: the new function names appear in the compiled script log
          if (-not ($out -match 'EnsureAppNotRunning')) { throw 'EnsureAppNotRunning not present in build output' };
        } finally { Pop-Location }
      }"
    </automated>
  </verify>
  <done>
    (1) `makensis src/installer/go-mapi.nsi` compiles clean. (2) The two new Pester items (14 + 15) are present and syntactically valid (verifiable via `Invoke-Pester -Output Detailed -DryRun`). (3) Install section and Uninstall section both `Call` into the new guard as the FIRST statement. Single atomic commit.
  </done>
</task>

<!--
  Task 3 — 32-bit DLL build + dual-bitness installer (large, ~25-30% context)
  Broken into 4 atomic commits internally (3a/3b/3c/3d).
  TDD: the new Pester cases (3d) go RED before 3c's installer code turns them
  GREEN. The build-pipeline changes (3a/3b) are verified by PE-magic inspection
  of the produced DLLs.
-->
<task type="auto" tdd="true">
  <name>Task 3: Produce both x86_64 + i686 DLLs and install them into matching registry views</name>
  <files>
    src/interceptor/build.ps1,
    src/interceptor/CMakeLists.txt,
    package.json,
    src/installer/go-mapi.nsi,
    src/installer/tests/installer.Tests.ps1
  </files>
  <behavior>
    - `powershell src/interceptor/build.ps1 -Arch x64 -Config Release` produces `src/interceptor/build-x64/bin/go-mapi.dll` with PE32+ magic (0x20B) linked against x86_64.
    - `powershell src/interceptor/build.ps1 -Arch x86 -Config Release` produces `src/interceptor/build-x86/bin/go-mapi.dll` with PE32 magic (0x10B) linked against i686.
    - `npm run build:interceptor:x64` + `npm run build:interceptor:x86` each drive the matching arch.
    - `npm run build:interceptor` runs BOTH in sequence and exits non-zero if either fails.
    - `npm run build` (full Wails build) succeeds on ARM64 Windows with `gcc-aarch64-none-elf` shimmed as `gcc.exe`, because CC/CXX are explicitly overridden.
    - After install: `$PROGRAMFILES64\go-mapi\go-mapi.dll` is the x64 PE32+ binary; `$PROGRAMFILES32\go-mapi\go-mapi.dll` is the x86 PE32 binary.
    - After install: `HKLM:\SOFTWARE\Clients\Mail\go-mapi\DLLPath = $PROGRAMFILES64\go-mapi\go-mapi.dll`; `HKLM:\SOFTWARE\WOW6432Node\Clients\Mail\go-mapi\DLLPath = $PROGRAMFILES32\go-mapi\go-mapi.dll`.
    - After uninstall: both install dirs and both registry entries are gone.
  </behavior>
  <action>
    Split into FOUR atomic commits. Each sub-task ends with a commit before the
    next begins.

    ---
    **Sub-task 3a — CMake + build.ps1 toolchain: `feat(interceptor): add -Arch switch to build.ps1 using triple-prefixed clang`**

    1. `src/interceptor/build.ps1`:
       - Add a new parameter:
         ```powershell
         [ValidateSet('x64','x86')]
         [string]$Arch = 'x64',
         ```
       - Replace the existing MinGW discovery loop (lines 24-43) with a clang
         discovery loop keyed on the new toolchain + arch:
         ```powershell
         $clangBin = "$env:USERPROFILE\scoop\apps\mingw-mstorsjo-llvm-ucrt\current\bin"
         if (-not (Test-Path $clangBin)) {
             Write-Error "mingw-mstorsjo-llvm-ucrt not found. Install with: scoop install mingw-mstorsjo-llvm-ucrt"
             exit 1
         }
         $triple = if ($Arch -eq 'x64') { 'x86_64-w64-mingw32' } else { 'i686-w64-mingw32' }
         $gccPath = Join-Path $clangBin "$triple-clang.exe"
         $gxxPath = Join-Path $clangBin "$triple-clang++.exe"
         foreach ($p in @($gccPath, $gxxPath)) {
             if (-not (Test-Path $p)) { Write-Error "Required compiler not found: $p"; exit 1 }
         }
         ```
       - Update `$buildDir` to be arch-specific:
         ```powershell
         $buildDir = Join-Path $interceptorRoot "build-$Arch"
         ```
       - Keep the existing CMake arg assembly but drop `-DCMAKE_MAKE_PROGRAM` if
         ninja is on PATH within the clangBin dir; otherwise retain the fallback.
       - Update the version read (line 99-105) to read from `<repo>/package.json` not the stale `src/native-host/package.json` path which no longer exists — use:
         ```powershell
         $packageJson = Join-Path $repoRoot "package.json"
         ```

    2. `src/interceptor/CMakeLists.txt`:
       - No structural changes needed — `MINGW` is set by CMake when the C++
         compiler is mingw-style clang, so the existing `elseif(MINGW)` branch
         continues to apply. Verify by running the new `build.ps1 -Arch x86`
         and confirming the link flags + `-static-libgcc -static-libstdc++`
         options come through. If CMake does not set `MINGW=1` for the clang
         driver, add `if(CMAKE_C_COMPILER MATCHES "mingw32-clang")` alongside
         the existing `MINGW` branch.

    3. Sanity verify both builds succeed:
       ```powershell
       & src/interceptor/build.ps1 -Arch x64 -Config Release -Clean
       & src/interceptor/build.ps1 -Arch x86 -Config Release -Clean
       # Then PE-magic check on each output:
       function Test-PEMagic($p, $expected) {
         $b = [IO.File]::ReadAllBytes($p);
         $e = [BitConverter]::ToInt32($b, 0x3C);
         $m = [BitConverter]::ToUInt16($b, $e + 4 + 20);
         if ($m -ne $expected) { throw "PE magic mismatch for $p : got 0x$($m.ToString('X')), expected 0x$($expected.ToString('X'))" }
       }
       Test-PEMagic 'src/interceptor/build-x64/bin/go-mapi.dll' 0x20B
       Test-PEMagic 'src/interceptor/build-x86/bin/go-mapi.dll' 0x10B
       ```
       Commit.

    ---
    **Sub-task 3b — package.json: `feat(build): npm scripts for x64+x86 interceptor and CC/CXX override for Wails`**

    Update `package.json` scripts:
    ```json
    {
      "scripts": {
        "build": "npm run build:interceptor && set CC=x86_64-w64-mingw32-clang&& set CXX=x86_64-w64-mingw32-clang++&& cd src/app && wails build -platform windows/amd64",
        "build:interceptor": "npm run build:interceptor:x64 && npm run build:interceptor:x86",
        "build:interceptor:x64": "powershell -ExecutionPolicy Bypass -File src/interceptor/build.ps1 -Arch x64 -Config Release",
        "build:interceptor:x86": "powershell -ExecutionPolicy Bypass -File src/interceptor/build.ps1 -Arch x86 -Config Release",
        "build:interceptor:debug": "powershell -ExecutionPolicy Bypass -File src/interceptor/build.ps1 -Arch x64 -Config Debug -Tests",
        "clean:interceptor": "powershell -ExecutionPolicy Bypass -Command \"Remove-Item -Recurse -Force src/interceptor/build-x64, src/interceptor/build-x86 -ErrorAction SilentlyContinue\""
      }
    }
    ```

    NOTES on the `build` script:
    - Windows `cmd.exe` / `npm` on Windows uses `set CC=...&& set CXX=...&&` (NO
      space between value and `&&`, otherwise the space becomes part of the
      variable value). This is the documented npm-on-Windows idiom.
    - Do NOT add `cross-env` — Marc's machine is Windows-only and the script
      explicitly targets `windows/amd64`.
    - `npm run build:interceptor:debug` drops to x64-only to keep the
      existing BUILD_TESTS=ON path runnable without doubling test harness time.
    - Update `test:interceptor` path from `src/interceptor/build/bin/...` to
      `src/interceptor/build-x64/bin/...` to match the new build dirs.

    Also update `test:interceptor`:
    ```json
    "test:interceptor": "powershell -ExecutionPolicy Bypass -Command \"src/interceptor/build-x64/bin/go-mapi-test-harness.exe src/interceptor/build-x64/bin/go-mapi.dll\""
    ```

    Verify:
    ```powershell
    npm run clean:interceptor
    npm run build:interceptor   # must run both arches and exit 0
    npm run build                # must succeed and produce src/app/build/bin/go-mapi.exe
    ```
    Commit.

    ---
    **Sub-task 3c — installer: `feat(installer): install both x64+x86 DLLs and register WOW6432Node DLLPath`**

    Edits to `src/installer/go-mapi.nsi`:

    1. Section "Install" (around line 83-84) — replace the existing DLL `File`
       directive with dual-bitness layout:
       ```nsis
         ; x64 binary lives in $INSTDIR (= $PROGRAMFILES64\go-mapi)
         SetOutPath "$INSTDIR"
         File "${__FILEDIR__}\..\app\build\bin\go-mapi.exe"
         File "${__FILEDIR__}\..\interceptor\build-x64\bin\go-mapi.dll"

         ; x86 DLL goes into $PROGRAMFILES32\go-mapi (auto-resolved by NSIS)
         CreateDirectory "$PROGRAMFILES32\go-mapi"
         SetOutPath "$PROGRAMFILES32\go-mapi"
         File "${__FILEDIR__}\..\interceptor\build-x86\bin\go-mapi.dll"

         ; Reset $OUTDIR for the rest of the install section
         SetOutPath "$INSTDIR"
       ```

    2. Section "Install" — after the existing native-view MAPI key writes
       (lines 102-104), add the WOW6432Node view writes:
       ```nsis
         ; 32-bit view — routes 32-bit MAPI callers to the i686 DLL
         SetRegView 32
         WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "" "go-mapi"
         WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "DLLPath" "$PROGRAMFILES32\go-mapi\go-mapi.dll"
         WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "go-mapi"
         SetRegView default
       ```
       NSIS's `SetRegView 32` redirects HKLM reads/writes to the WOW6432Node
       subtree. `SetRegView default` restores the 64-bit view (matching the
       existing pattern at lines 269/282/292/300).

    3. `BackupPreviousMailClient` (around line 147) — the backup currently only
       reads the native view. For symmetry, add a secondary backup of the
       WOW6432 view into the SAME JSON under a new key `previousClient32`.
       Keep the JSON shape backward-compatible:
       ```nsis
         ReadRegStr $0 HKLM "SOFTWARE\Clients\Mail" ""         ; native
         SetRegView 32
         ReadRegStr $4 HKLM "SOFTWARE\Clients\Mail" ""         ; WOW6432
         SetRegView default
         ; ... existing escape + timestamp plumbing ...
         FileWrite $1 '{"previousClient":"$0","previousClient32":"$4","backedUpAt":"$3"}'
       ```
       Also add the equivalent to the `BackupNull` path (write `"previousClient32":null` when $4 is empty).
       Apply the same JSON-escape call to $4 as already applied to $0.

    4. Section "Uninstall" (around line 461 + 490-491):
       - Add a 3b step after existing step 3 (DeleteRegKey native view) to also
         clean the WOW6432Node view:
         ```nsis
         ; 3b. WOW6432 MAPI handler key (32-bit view)
         SetRegView 32
         DeleteRegKey HKLM "SOFTWARE\Clients\Mail\go-mapi"
         SetRegView default
         ```
       - Update step 9 to also delete the x86 DLL + directory:
         ```nsis
         ; 9. Binaries (x64 side)
         Delete "$INSTDIR\go-mapi.exe"
         Delete "$INSTDIR\go-mapi.dll"
         Delete "$INSTDIR\uninstall.exe"
         Delete "$INSTDIR\install.log"

         ; 9c. x86 DLL + its parallel install dir
         Delete "$PROGRAMFILES32\go-mapi\go-mapi.dll"
         RMDir  "$PROGRAMFILES32\go-mapi"
         ```
       - `un.RestorePreviousMailClient` — extend to also restore the WOW6432 view
         using `previousClient32` from the backup JSON. Reuse the existing
         `un.StrContains` / `un.StrExtract` primitives with a new needle
         `"previousClient32":"`. Wrap the WOW6432 restore in `SetRegView 32` /
         `SetRegView default` exactly like the Install section does.

    5. Installer header — no changes needed to `InstallDir`; keep it pointed at
       `$PROGRAMFILES64\go-mapi`. The x86 path is resolved inline via
       `$PROGRAMFILES32` at runtime.

    Verify the installer still compiles cleanly:
    ```
    cd src/installer; makensis -DGOMAPI_VERSION=3.0.0-dev go-mapi.nsi
    ```
    Commit.

    ---
    **Sub-task 3d — Pester coverage for dual-bitness install: `test(installer): cover x86 DLL install + WOW6432 DLLPath + dual-path uninstall`**

    Append THREE new items to `src/installer/tests/installer.Tests.ps1`. Number
    them 16, 17, 18 (items 14 + 15 are taken by Task 2). Reuse the existing
    `$script:*` setup variables; add:
    ```powershell
    # In BeforeAll, after the existing $script:CredTarget line:
    $script:InstallDir32 = "${env:ProgramFiles(x86)}\go-mapi"
    $script:MapiKey32    = 'HKLM:\SOFTWARE\WOW6432Node\Clients\Mail\go-mapi'
    ```

    New tests inside `Context "Silent install"`:
    ```powershell
    # QUICK-260423-ntu item 16 — x86 DLL deposited alongside x64 DLL
    It "16. go-mapi.dll is deposited in both ProgramFiles and ProgramFiles(x86)" {
        Test-Path (Join-Path $script:InstallDir   'go-mapi.dll') | Should -BeTrue
        Test-Path (Join-Path $script:InstallDir32 'go-mapi.dll') | Should -BeTrue
    }

    # QUICK-260423-ntu item 17 — each DLL has the matching PE bitness
    It "17. x64 DLL is PE32+ and x86 DLL is PE32" {
        function Get-PeMagic($p) {
            $b = [IO.File]::ReadAllBytes($p)
            $e = [BitConverter]::ToInt32($b, 0x3C)
            return [BitConverter]::ToUInt16($b, $e + 4 + 20)
        }
        Get-PeMagic (Join-Path $script:InstallDir   'go-mapi.dll') | Should -Be 0x20B
        Get-PeMagic (Join-Path $script:InstallDir32 'go-mapi.dll') | Should -Be 0x10B
    }

    # QUICK-260423-ntu item 18 — WOW6432Node DLLPath points at the x86 DLL
    It "18. HKLM WOW6432Node MAPI key is registered with 32-bit DLLPath" {
        # Use the 32-bit registry view by reading from the WOW6432Node path directly
        Test-Path $script:MapiKey32 | Should -BeTrue
        $props = Get-ItemProperty -Path $script:MapiKey32
        $props.DLLPath | Should -Match '(?i)Program Files \(x86\)\\go-mapi\\go-mapi\.dll$'
    }
    ```

    New tests inside `Context "Silent uninstall"` (append after item 13):
    ```powershell
    # QUICK-260423-ntu item 19 — x86 DLL + install dir removed by uninstall
    It "19. ProgramFiles(x86)\go-mapi is gone after uninstall" {
        $exists = Test-Path $script:InstallDir32
        if ($exists) {
            (Get-ChildItem $script:InstallDir32 -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
        }
        Test-Path (Join-Path $script:InstallDir32 'go-mapi.dll') | Should -BeFalse
    }

    # QUICK-260423-ntu item 20 — WOW6432Node MAPI key removed
    It "20. HKLM WOW6432Node MAPI handler key is gone after uninstall" {
        Test-Path $script:MapiKey32 | Should -BeFalse
    }
    ```

    Verify the Pester file parses:
    ```powershell
    [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path src/installer/tests/installer.Tests.ps1).Path,
        [ref]$null,
        [ref]$null
    )
    ```

    Commit.

    **D. Scope discipline across all four sub-tasks:**
    - Do NOT migrate CMake to toolchain files (Option B) — stay in Option A (-Arch switch in build.ps1).
    - Do NOT touch `gcc-aarch64-none-elf` scoop package.
    - Do NOT touch `src/app/main.go`, `src/app/watcher_bridge.go`, or any Go source.
    - Do NOT touch WebView2 bootstrap, firewall rule, or AUMID logic in the installer.
    - Do NOT install diagnostics scripts into the x86 install dir (they stay in `$INSTDIR\diagnostics\` only — per context constraint).
  </action>
  <verify>
    <automated>
      powershell -NoProfile -ExecutionPolicy Bypass -Command "& {
        # Sub-task 3a + 3b: full interceptor build for both arches
        npm run clean:interceptor 2>&1 | Out-Null;
        npm run build:interceptor;
        if ($LASTEXITCODE -ne 0) { throw 'build:interceptor failed' };

        function Get-PeMagic($p) {
            $b = [IO.File]::ReadAllBytes($p);
            $e = [BitConverter]::ToInt32($b, 0x3C);
            return [BitConverter]::ToUInt16($b, $e + 4 + 20)
        }
        $x64 = 'src/interceptor/build-x64/bin/go-mapi.dll';
        $x86 = 'src/interceptor/build-x86/bin/go-mapi.dll';
        if (-not (Test-Path $x64)) { throw \"missing $x64\" };
        if (-not (Test-Path $x86)) { throw \"missing $x86\" };
        $m64 = Get-PeMagic $x64;
        $m86 = Get-PeMagic $x86;
        if ($m64 -ne 0x20B) { throw \"x64 DLL wrong PE magic: 0x$($m64.ToString('X'))\" };
        if ($m86 -ne 0x10B) { throw \"x86 DLL wrong PE magic: 0x$($m86.ToString('X'))\" };
        Write-Host 'PE bitness OK (x64 -> 0x20B, x86 -> 0x10B)';

        # Sub-task 3c: installer compiles
        if (Get-Command makensis -ErrorAction SilentlyContinue) {
            Push-Location src/installer;
            try {
                makensis -DGOMAPI_VERSION=3.0.0-dev go-mapi.nsi 2>&1 | Tee-Object -Variable nsiOut | Out-Null;
                if ($LASTEXITCODE -ne 0) { throw \"makensis failed: $($nsiOut -join [Environment]::NewLine)\" };
            } finally { Pop-Location }
        } else {
            Write-Host 'makensis not on PATH — installer compile check SKIPPED (CI will cover)'
        }

        # Sub-task 3d: Pester file parses clean
        $errs = $null;
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path src/installer/tests/installer.Tests.ps1).Path,
            [ref]$null,
            [ref]$errs
        ) | Out-Null;
        if ($errs -and $errs.Count -gt 0) { throw \"installer.Tests.ps1 parse errors: $($errs -join '; ')\" };
        Write-Host 'Pester file parses clean';

        # Wails build — only run if wails CLI is on PATH locally
        if (Get-Command wails -ErrorAction SilentlyContinue) {
            npm run build;
            if ($LASTEXITCODE -ne 0) { throw 'npm run build (Wails) failed' };
            if (-not (Test-Path 'src/app/build/bin/go-mapi.exe')) { throw 'go-mapi.exe not produced' };
            Write-Host 'Wails build OK'
        } else {
            Write-Host 'wails CLI not on PATH — Wails build SKIPPED'
        }
      }"
    </automated>
  </verify>
  <done>
    All four sub-tasks committed as separate atomic commits in order 3a → 3b → 3c → 3d. `npm run build:interceptor` produces both DLLs with correct PE bitness. `npm run build` still produces `src/app/build/bin/go-mapi.exe` with the CC/CXX override. `makensis` compiles the installer. The Pester file contains new items 14-20 (five from Task 2+3: 14, 15, 16, 17, 18, 19, 20 — seven total) and parses clean. No untracked changes in scoop shims or any Go source.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| Installer → HKLM | Admin-elevated NSIS writes registry values; a compromised installer binary could register a malicious DLLPath |
| Installer → filesystem | Admin-elevated writes to `$PROGRAMFILES64` + `$PROGRAMFILES32` |
| Uninstaller → running process | `taskkill` without `/F` sends WM_CLOSE; a process could refuse to close |
| Diagnostic scripts → registry (read-only) | No elevation needed; read-only |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-QUICK-NTU-01 | Tampering | x86 DLL path | accept | Same install-path trust model as x64 (both admin-elevated NSIS writes). No new attack surface vs. existing x64-only flow. |
| T-QUICK-NTU-02 | Denial of Service | Uninstaller running-process guard | mitigate | 10-second bounded poll loop — if the app refuses to close, uninstaller exits with a clear MessageBox rather than hanging indefinitely. Silent mode also bounded. |
| T-QUICK-NTU-03 | Elevation of Privilege | `nsExec::ExecToStack` on `tasklist` / `wmic` | accept | NSIS already runs as SYSTEM during silent install / uninstall; invoking core Windows tools from SYSTEM context is baseline and not a new trust boundary. |
| T-QUICK-NTU-04 | Information Disclosure | Diagnostic scripts output | mitigate | Existing script already documents "sanitized" — extended null-ref fixes do NOT widen the data surface; output continues to contain ONLY registry keys, file paths, PE bitness, and SHA256 hashes (no tokens, no email content). |
| T-QUICK-NTU-05 | Tampering | Wrong DLL registered in wrong view | mitigate | Pester items 17 + 18 assert that each registry view's DLLPath points at the matching-bitness DLL; PE magic bytes are asserted directly. |
</threat_model>

<verification>
Phase-level checks (run in order):

1. `git status` clean at the start.
2. Task 1 verify block passes.
3. Task 2 verify block passes (makensis compile — Pester full run happens on CI).
4. Task 3 verify block passes:
   - `npm run build:interceptor` → both DLLs with correct PE magic.
   - `npm run build` → Wails exe if CLI is local.
   - `makensis` → installer compiles.
   - Pester file parses clean.
5. `git log --oneline` shows the expected commit sequence:
   - `fix(diagnostics): guard collect-*.ps1 against missing (Default) and missing queue dir`
   - `feat(installer): guard install+uninstall against running go-mapi.exe`
   - `feat(interceptor): add -Arch switch to build.ps1 using triple-prefixed clang`
   - `feat(build): npm scripts for x64+x86 interceptor and CC/CXX override for Wails`
   - `feat(installer): install both x64+x86 DLLs and register WOW6432Node DLLPath`
   - `test(installer): cover x86 DLL install + WOW6432 DLLPath + dual-path uninstall`
</verification>

<success_criteria>
- Diagnostic scripts run clean on a machine with no go-mapi install and no MAPI (Default) value. (Task 1)
- NSIS installer + uninstaller both `Call` the running-process guard as their first statement, with `tasklist`-based detection, WM_CLOSE retry via `taskkill` (no `/F`), 10-second poll, silent-mode auto-retry. (Task 2)
- `npm run build:interceptor` exits 0 and deposits `build-x64/bin/go-mapi.dll` (PE32+) + `build-x86/bin/go-mapi.dll` (PE32). (Task 3a+3b)
- `npm run build` still succeeds on ARM64 Windows via CC/CXX env override. (Task 3b)
- `makensis go-mapi.nsi` compiles; install deposits both DLLs; registry writes populate both native + WOW6432 views. (Task 3c)
- Pester file has new items 14, 15, 16, 17, 18, 19, 20 — parses clean; ready for CI. (Task 2 + Task 3d)
- Six atomic commits total on `develop`.
- No changes to Go source, Svelte frontend, or scoop toolchain shims.
</success_criteria>

<output>
After completion, create `.planning/quick/260423-ntu-32-bit-dll-support-uninstaller-process-c/260423-ntu-SUMMARY.md` following the GSD summary template.
</output>
