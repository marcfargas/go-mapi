---
phase: 05-release-cut
plan: 02
type: execute
wave: 1
depends_on: []
files_modified:
  - tests/sandbox/sandbox.wsb
  - tests/sandbox/README.md
  - tests/sandbox/run-sandbox-test.ps1
  - tests/sandbox/install-and-verify.ps1
autonomous: true
requirements: [REL-02]
must_haves:
  truths:
    - "A committed `.wsb` config file exists under `tests/sandbox/` so Marc can launch a Windows Sandbox declaratively (D-03)"
    - "`pwsh tests/sandbox/run-sandbox-test.ps1 -FullTest` on a Windows 11 24H2+ host runs the v2.0.0 install → smoke verify → uninstall flow inside a sandbox and produces a clearly-green or clearly-red result (REL-02)"
    - "`tests/sandbox/README.md` documents the prerequisites (Windows 11 24H2+, `wsb` CLI, Windows Sandbox feature enabled), the entry-point commands, and expected runtime"
  artifacts:
    - path: "tests/sandbox/sandbox.wsb"
      provides: "Declarative Windows Sandbox configuration (shared folders, networking, memory)"
      contains: "<HostFolder>"
    - path: "tests/sandbox/install-and-verify.ps1"
      provides: "In-sandbox installer runner + registry verification + uninstall round-trip"
      contains: "go-mapi-setup.exe"
    - path: "tests/sandbox/README.md"
      provides: "Phase 5 local repro path documentation"
      contains: "Windows 11 24H2+"
    - path: "tests/sandbox/run-sandbox-test.ps1"
      provides: "Hardened -FullTest branch that actually runs the install flow (not the current TODO stub)"
      contains: "install-and-verify.ps1"
  key_links:
    - from: "run-sandbox-test.ps1 -FullTest"
      to: "sandbox.wsb"
      via: "wsb start --config tests/sandbox/sandbox.wsb"
      pattern: "sandbox\\.wsb"
    - from: "run-sandbox-test.ps1 -FullTest"
      to: "install-and-verify.ps1"
      via: "wsb exec of the in-sandbox installer runner"
      pattern: "install-and-verify\\.ps1"
    - from: "install-and-verify.ps1"
      to: "src/installer/dist/go-mapi-setup.exe"
      via: "Start-Process with /VERYSILENT"
      pattern: "go-mapi-setup\\.exe"
---

<objective>
Harden the existing `tests/sandbox/` harness into a real local repro path for the full v2.0.0 install → smoke verify → uninstall flow, per REL-02 and D-03. Today the harness only covers DLL registration; after this plan it runs the actual Inno Setup installer inside a Windows Sandbox and asserts registry + file state + clean uninstall. This doesn't replace `installer-smoke.yml` on CI — it's the fast local feedback loop that didn't exist before (~5 min sandbox cycle vs ~15 min CI cycle), and it gives Marc a way to reproduce any first-run CI failures from REL-01 locally on marcwin without touching host state.

Purpose: REL-02 is the "I can reproduce this locally on a clean Windows in 5 minutes" capability that Phase 5 needs when CI shows a flake, and it's the secondary UAT environment option for REL-06.
Output: A committed `.wsb` declarative config, a new `install-and-verify.ps1` in-sandbox runner, a hardened `-FullTest` branch in `run-sandbox-test.ps1`, and `README.md` with prerequisites + expected runtime + failure modes.
</objective>

<execution_context>
@C:/dev/go-mapi/.claude/get-shit-done/workflows/execute-plan.md
@C:/dev/go-mapi/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/phases/05-release-cut/05-CONTEXT.md
@tests/sandbox/run-sandbox-test.ps1
@tests/sandbox/setup.ps1
@tests/sandbox/test-dll-registration.ps1
@src/installer/go-mapi.iss
@src/installer/tests/installer.Tests.ps1
@.github/workflows/installer-smoke.yml

<interfaces>
<!-- Existing run-sandbox-test.ps1 surface area (reuse — do not rewrite):
     - Parameters: -SetupOnly, -RegistrationOnly, -FullTest, -KeepRunning
     - Uses `wsb start --raw | ConvertFrom-Json` to get sandbox Id
     - Uses `wsb share --id <id> --host-path <path> --sandbox-path <path>` for folder mapping
     - Uses `wsb exec --id <id> --command <ps> --run-as System --raw | ConvertFrom-Json` for in-sandbox commands
     - Logs to `C:\output\*.log` via a writable share to `$env:TEMP\go-mapi-sandbox-output`
     - Line 143-145 of run-sandbox-test.ps1 currently has:
         if ($FullTest) {
             Write-Host "`n=== FULL TEST (WinAppDriver) ===" -ForegroundColor Yellow
             Write-Host "TODO: Implement WinAppDriver-based UI automation"
         }
       This plan REPLACES that stub with the install-and-verify.ps1 invocation.
-->

<!-- Inno Setup output path (from src/installer/go-mapi.iss / Phase 3):
     - Compiled installer lives at src/installer/dist/go-mapi-setup.exe after `iscc.exe ... go-mapi.iss`
     - Silent install flag: /VERYSILENT /SUPPRESSMSGBOXES
     - Silent uninstall: <InstallDir>\unins000.exe /VERYSILENT
     - HKLM registry keys (from go-mapi.iss [Registry] section):
         HKLM\SOFTWARE\Clients\Mail\go-mapi
         HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host
         HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host
         HKLM\SOFTWARE\Chromium\NativeMessagingHosts\com.gomapi.host
         HKLM\SOFTWARE\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.gomapi.host
         HKLM\SOFTWARE\Vivaldi\NativeMessagingHosts\com.gomapi.host
     - File system targets:
         %ProgramFiles%\go-mapi\go-mapi.dll
         %ProgramFiles%\go-mapi\go-mapi-host.exe
         %ProgramData%\go-mapi\com.gomapi.host.json
         %ProgramData%\go-mapi\uninst\previous-mail-client.json
-->

<!-- Pester installer smoke test (reference only — this plan does NOT call Pester):
     - src/installer/tests/installer.Tests.ps1 already asserts everything via Pester 5
     - We intentionally do NOT re-run the Pester test inside the sandbox; we keep the
       sandbox script lightweight so it runs in ~5 min. Pester stays the CI authority
       via installer-smoke.yml.
-->

<!-- Windows Sandbox .wsb schema (XML, well-documented on MS Learn):
     Root: <Configuration>
     Children used: <VGpu>Disable</VGpu>, <Networking>Default</Networking>,
                    <MappedFolders><MappedFolder><HostFolder>...</HostFolder>
                    <SandboxFolder>...</SandboxFolder><ReadOnly>true|false</ReadOnly>
                    </MappedFolder></MappedFolders>,
                    <MemoryInMB>8192</MemoryInMB>,
                    <LogonCommand><Command>...</Command></LogonCommand>
     Note: HostFolder must be an absolute path; $env:... does NOT expand in .wsb.
           For a committed config, use a placeholder path + a note in README.md telling
           Marc to either (a) clone to `C:\dev\go-mapi` (marcwin convention) or (b) edit
           the path before launching. The PowerShell wrapper (run-sandbox-test.ps1) uses
           `wsb share` dynamically instead, so the committed .wsb is primarily a
           declarative baseline for `wsb start --config`. -->
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Create sandbox.wsb declarative config and install-and-verify.ps1 in-sandbox runner</name>
  <files>tests/sandbox/sandbox.wsb, tests/sandbox/install-and-verify.ps1</files>
  <read_first>
    - tests/sandbox/run-sandbox-test.ps1 (lines 45-60 for the wsb share pattern already in use — the .wsb config must be compatible with both direct-launch and dynamic-share launch paths)
    - tests/sandbox/setup.ps1 (for the logging convention — "C:\output\*.log" + Add-Content logging pattern, reuse this in install-and-verify.ps1)
    - src/installer/go-mapi.iss (sections [Files], [Registry], [Setup] — extract the exact registry keys and install targets that install-and-verify.ps1 must assert)
    - src/installer/README.md (confirm silent install flags — `/VERYSILENT /SUPPRESSMSGBOXES` — are the correct Inno Setup flags)
  </read_first>
  <action>
    **Create `tests/sandbox/sandbox.wsb`** with this exact XML content (use Write tool):

    ```xml
    <Configuration>
        <VGpu>Disable</VGpu>
        <Networking>Default</Networking>
        <MemoryInMB>8192</MemoryInMB>
        <AudioInput>Disable</AudioInput>
        <VideoInput>Disable</VideoInput>
        <ProtectedClient>Enable</ProtectedClient>
        <PrinterRedirection>Disable</PrinterRedirection>
        <ClipboardRedirection>Disable</ClipboardRedirection>
        <MappedFolders>
            <MappedFolder>
                <HostFolder>C:\dev\go-mapi</HostFolder>
                <SandboxFolder>C:\go-mapi</SandboxFolder>
                <ReadOnly>true</ReadOnly>
            </MappedFolder>
        </MappedFolders>
    </Configuration>
    ```

    Notes:
    - `HostFolder` is hardcoded to `C:\dev\go-mapi` (the marcwin convention from `~/.claude/CLAUDE.md` "Windows (marcwin): C:\dev\"). README.md in Task 2 tells Marc to edit this if his clone lives elsewhere. We intentionally do NOT substitute via variable — `.wsb` files do not expand env vars at launch.
    - `run-sandbox-test.ps1` launches the sandbox via `wsb start --raw` without `--config` (dynamic share flow). The committed `.wsb` is for the alternative "double-click to launch with a baseline config" workflow, not strictly required by the harness but required by REL-02's "committed .wsb config" acceptance criterion.
    - No `<LogonCommand>` — manual smoke inside the sandbox runs `install-and-verify.ps1` on demand via the orchestrator, not automatically on logon. Keeps the .wsb usable for other ad-hoc sandbox uses.

    **Create `tests/sandbox/install-and-verify.ps1`** (in-sandbox runner) with this structure. Use the exact logging convention from setup.ps1 (writes to `C:\output\install-and-verify.log`). The script assumes `C:\go-mapi` is the read-only project share (from sandbox.wsb or the dynamic share) and `C:\output` is the writable output share (from run-sandbox-test.ps1 lines 51-54).

    ```powershell
    # install-and-verify.ps1 — In-sandbox runner for REL-02 full install → verify → uninstall flow
    # Runs inside the Windows Sandbox as SYSTEM via `wsb exec`.
    # Preconditions: C:\go-mapi is the project folder (read-only share), C:\output is writable.
    # The installer MUST have been compiled already — this script does NOT run iscc.exe.
    # Compile go-mapi-setup.exe on the HOST first (outside the sandbox) via
    # `iscc.exe /DGOMAPIVersion=2.0.0-local src/installer/go-mapi.iss` — the
    # resulting src/installer/dist/go-mapi-setup.exe is read through the C:\go-mapi share.

    $ErrorActionPreference = "Stop"
    $OutputFile = "C:\output\install-and-verify.log"
    $InstallerPath = "C:\go-mapi\src\installer\dist\go-mapi-setup.exe"

    function Log($msg) {
        Write-Host $msg
        Add-Content -Path $OutputFile -Value $msg
    }

    "" | Set-Content $OutputFile
    Log "=== REL-02 Install + Verify + Uninstall ==="
    Log "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Log ""

    # Step 1: Verify the pre-built installer is present on the share
    Log "[1/6] Checking installer exists..."
    if (-not (Test-Path $InstallerPath)) {
        Log "FAILED: $InstallerPath not found. Compile it first on the host with:"
        Log "  iscc.exe /DGOMAPIVersion=2.0.0-local src\installer\go-mapi.iss"
        exit 1
    }
    Log "OK: Found $InstallerPath"
    Log "  Size: $((Get-Item $InstallerPath).Length) bytes"

    # Step 2: Silent install
    Log ""
    Log "[2/6] Running silent install (/VERYSILENT /SUPPRESSMSGBOXES)..."
    $proc = Start-Process -FilePath $InstallerPath -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/LOG=C:\output\inno-install.log" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Log "FAILED: Installer exit code $($proc.ExitCode). See C:\output\inno-install.log"
        exit 1
    }
    Log "OK: Installer exit code 0"

    # Step 3: Verify HKLM registry keys
    Log ""
    Log "[3/6] Verifying HKLM registry keys..."
    $expectedKeys = @(
        "HKLM:\SOFTWARE\Clients\Mail\go-mapi",
        "HKLM:\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host",
        "HKLM:\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host",
        "HKLM:\SOFTWARE\Chromium\NativeMessagingHosts\com.gomapi.host",
        "HKLM:\SOFTWARE\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.gomapi.host",
        "HKLM:\SOFTWARE\Vivaldi\NativeMessagingHosts\com.gomapi.host"
    )
    $regFail = $false
    foreach ($key in $expectedKeys) {
        if (Test-Path $key) {
            Log "  OK: $key"
        } else {
            Log "  FAILED: $key missing"
            $regFail = $true
        }
    }
    if ($regFail) { Log "FAILED: one or more registry keys missing"; exit 1 }
    Log "OK: all 6 registry keys present"

    # Step 4: Verify files on disk
    Log ""
    Log "[4/6] Verifying installed files..."
    $expectedFiles = @(
        "$env:ProgramFiles\go-mapi\go-mapi.dll",
        "$env:ProgramFiles\go-mapi\go-mapi-host.exe",
        "$env:ProgramData\go-mapi\com.gomapi.host.json",
        "$env:ProgramData\go-mapi\uninst\previous-mail-client.json"
    )
    $fileFail = $false
    foreach ($f in $expectedFiles) {
        if (Test-Path $f) {
            Log "  OK: $f"
        } else {
            Log "  FAILED: $f missing"
            $fileFail = $true
        }
    }
    if ($fileFail) { Log "FAILED: one or more files missing"; exit 1 }
    Log "OK: all 4 files present"

    # Step 5: Silent uninstall
    Log ""
    Log "[5/6] Running silent uninstall..."
    $uninst = "$env:ProgramFiles\go-mapi\unins000.exe"
    if (-not (Test-Path $uninst)) {
        Log "FAILED: uninstaller not found at $uninst"
        exit 1
    }
    $proc = Start-Process -FilePath $uninst -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/LOG=C:\output\inno-uninstall.log" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Log "FAILED: Uninstaller exit code $($proc.ExitCode)"
        exit 1
    }
    Log "OK: Uninstaller exit code 0"

    # Step 6: Verify clean state after uninstall
    Log ""
    Log "[6/6] Verifying clean post-uninstall state..."
    $stillPresent = @()
    foreach ($key in $expectedKeys) {
        if (Test-Path $key) { $stillPresent += "registry: $key" }
    }
    foreach ($f in @("$env:ProgramFiles\go-mapi\go-mapi.dll",
                     "$env:ProgramFiles\go-mapi\go-mapi-host.exe",
                     "$env:ProgramData\go-mapi\com.gomapi.host.json")) {
        if (Test-Path $f) { $stillPresent += "file: $f" }
    }
    if ($stillPresent.Count -gt 0) {
        Log "FAILED: post-uninstall state not clean:"
        foreach ($s in $stillPresent) { Log "  $s" }
        exit 1
    }
    Log "OK: post-uninstall state clean"

    Log ""
    Log "=== REL-02 FULL FLOW PASSED ==="
    exit 0
    ```

    Commit with: `test(05-02): add sandbox.wsb + install-and-verify.ps1 for REL-02 local repro`
  </action>
  <verify>
    <automated>test -f tests/sandbox/sandbox.wsb &amp;&amp; grep -q "&lt;HostFolder&gt;" tests/sandbox/sandbox.wsb &amp;&amp; grep -q "&lt;SandboxFolder&gt;C:\\\\go-mapi&lt;/SandboxFolder&gt;" tests/sandbox/sandbox.wsb &amp;&amp; test -f tests/sandbox/install-and-verify.ps1 &amp;&amp; grep -q "go-mapi-setup.exe" tests/sandbox/install-and-verify.ps1 &amp;&amp; grep -q "VERYSILENT" tests/sandbox/install-and-verify.ps1 &amp;&amp; grep -q "unins000.exe" tests/sandbox/install-and-verify.ps1 &amp;&amp; pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('tests/sandbox/install-and-verify.ps1', [ref]\$null, [ref]\$null); if (\$?) { exit 0 } else { exit 1 }"</automated>
  </verify>
  <acceptance_criteria>
    - `tests/sandbox/sandbox.wsb` exists
    - `grep -c "<HostFolder>" tests/sandbox/sandbox.wsb` returns `1`
    - `grep -q "<SandboxFolder>C:\\go-mapi</SandboxFolder>" tests/sandbox/sandbox.wsb` matches
    - `grep -q "<ReadOnly>true</ReadOnly>" tests/sandbox/sandbox.wsb` matches
    - `tests/sandbox/install-and-verify.ps1` exists
    - `grep -c "HKLM:\\\\SOFTWARE" tests/sandbox/install-and-verify.ps1` returns `>= 6` (the six browser + Mail client keys)
    - `grep -q "go-mapi-setup.exe" tests/sandbox/install-and-verify.ps1` matches
    - `grep -q "VERYSILENT" tests/sandbox/install-and-verify.ps1` matches
    - `grep -q "unins000.exe" tests/sandbox/install-and-verify.ps1` matches
    - PowerShell parses without errors: `pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('tests/sandbox/install-and-verify.ps1', [ref]$null, [ref]$null)"` returns zero errors
  </acceptance_criteria>
  <done>
    Sandbox has a declarative baseline config (`.wsb`) and a real in-sandbox script that runs the install → verify → uninstall flow.
  </done>
</task>

<task type="auto">
  <name>Task 2: Harden run-sandbox-test.ps1 -FullTest branch + write tests/sandbox/README.md</name>
  <files>tests/sandbox/run-sandbox-test.ps1, tests/sandbox/README.md</files>
  <read_first>
    - tests/sandbox/run-sandbox-test.ps1 (ENTIRE file — especially lines 141-145 which contain the TODO stub that this task replaces; also lines 60-75 for the Invoke-SandboxCommand helper that Task 1's install-and-verify.ps1 will be invoked through)
    - tests/sandbox/install-and-verify.ps1 (just created in Task 1 — confirm output log path is `C:\output\install-and-verify.log`)
    - tests/sandbox/setup.ps1 (for the log-retrieval pattern copied into the new FullTest branch)
  </read_first>
  <action>
    **Edit `tests/sandbox/run-sandbox-test.ps1`** to replace the FullTest stub. Use the Edit tool.

    Replace exactly this block (lines ~141-145):

    ```powershell
    # Full test with UI automation
    if ($FullTest) {
        Write-Host "`n=== FULL TEST (WinAppDriver) ===" -ForegroundColor Yellow
        Write-Host "TODO: Implement WinAppDriver-based UI automation"
    }
    ```

    with this block:

    ```powershell
    # Full test: install → verify → uninstall round-trip (REL-02)
    if ($FullTest) {
        Write-Host "`n[5/5] Running REL-02 install → verify → uninstall flow..." -ForegroundColor Cyan

        # Sanity check: the host-side Inno Setup compile must have happened already
        $hostInstaller = Join-Path $ProjectRoot 'src\installer\dist\go-mapi-setup.exe'
        if (-not (Test-Path $hostInstaller)) {
            Write-Host "ERROR: $hostInstaller not found." -ForegroundColor Red
            Write-Host "Compile it on the host first:" -ForegroundColor Yellow
            Write-Host '  & "C:\Program Files (x86)\Inno Setup 6\iscc.exe" /DGOMAPIVersion=2.0.0-local src\installer\go-mapi.iss' -ForegroundColor Yellow
            if (-not $KeepRunning) { wsb stop --id $sandboxId 2>&1 | Out-Null }
            exit 1
        }
        Write-Host "OK: Found $hostInstaller ($((Get-Item $hostInstaller).Length) bytes)" -ForegroundColor Green

        $fullSuccess = Invoke-SandboxCommand `
            -Command "powershell -ExecutionPolicy Bypass -File C:\go-mapi\tests\sandbox\install-and-verify.ps1" `
            -Description "Install-and-verify round-trip"

        # Retrieve the script log
        $fullLog = Join-Path $OutputFolder "install-and-verify.log"
        Write-Host "`n--- Install+Verify Output ---"
        if (Test-Path $fullLog) {
            Get-Content $fullLog
        } else {
            Write-Host "(No install-and-verify.log found at $fullLog)"
        }
        Write-Host "--- End Output ---"

        if (-not $fullSuccess) {
            Write-Host "`n=== REL-02 FULL TEST FAILED ===" -ForegroundColor Red
            if (-not $KeepRunning) { wsb stop --id $sandboxId 2>&1 | Out-Null }
            exit 1
        }
        Write-Host "`n=== REL-02 FULL TEST PASSED ===" -ForegroundColor Green
    }
    ```

    Do not modify any other line of `run-sandbox-test.ps1`.

    **Create `tests/sandbox/README.md`** with this exact content (use Write tool):

    ```markdown
    # tests/sandbox — Windows Sandbox local repro harness (REL-02)

    Local alternative to `.github/workflows/installer-smoke.yml`. Runs the full
    v2.0.0 installer install → verify registry → uninstall flow inside a fresh
    Windows Sandbox so you can reproduce CI failures (or verify changes)
    without touching your host's MAPI registration or `%ProgramFiles%`.

    **This does not replace CI.** `installer-smoke.yml` remains the
    authoritative ship gate. The sandbox harness is the fast local feedback
    loop (~5 min) and the fallback UAT environment for REL-06 when marcwin
    isn't available.

    ## Prerequisites

    - **Windows 11 24H2 or newer** — earlier Windows versions don't ship the
      `wsb` CLI. Verify with `wsb --version`.
    - **Windows Sandbox feature enabled.** Control Panel → Turn Windows features on or off → "Windows Sandbox". Requires a reboot on first enable.
    - **PowerShell 7+** (`pwsh`) — used by `run-sandbox-test.ps1`. Windows
      PowerShell 5.1 will parse but the harness uses `-raw` JSON output from
      `wsb` which is easier to handle in pwsh.
    - **Clone location:** the committed `sandbox.wsb` config assumes the repo
      lives at `C:\dev\go-mapi` (marcwin convention). If your clone is
      elsewhere, edit `<HostFolder>` in `sandbox.wsb` before running the
      harness. The `run-sandbox-test.ps1` orchestrator does NOT use the
      `.wsb` file directly — it dynamically shares `$PSScriptRoot | Split-Path | Split-Path`
      — so only the "double-click the .wsb" workflow is affected.
    - **Inno Setup 6 on the host** (`iscc.exe`) — the sandbox reads the
      compiled `go-mapi-setup.exe` through the read-only project share, it
      does NOT compile it. Compile on the host first (see next section).

    ## Entry points

    ### Fast path: DLL registration only (~1 min)

    ```powershell
    pwsh tests\sandbox\run-sandbox-test.ps1 -RegistrationOnly
    ```

    Runs `test-dll-registration.ps1` inside the sandbox. Asserts that the DLL
    exists, the `HKLM\SOFTWARE\Clients\Mail\go-mapi` key can be written, and
    the default Mail client is correctly set. This is the pre-existing test
    that shipped before Phase 5.

    ### Full path: REL-02 install → verify → uninstall (~5 min)

    Compile the installer on the host FIRST:

    ```powershell
    # From repo root
    cd src\interceptor && .\build.ps1 -Config Release -Clean ; cd ..\..
    cd src\native-host && go build -ldflags "-s -w -X main.Version=2.0.0-local" -o build\go-mapi-host.exe . ; cd ..\..
    & "C:\Program Files (x86)\Inno Setup 6\iscc.exe" /DGOMAPIVersion=2.0.0-local src\installer\go-mapi.iss
    ```

    Then run the full sandbox flow:

    ```powershell
    pwsh tests\sandbox\run-sandbox-test.ps1 -FullTest
    ```

    This:
    1. Stops any existing sandbox instance (`wsb list` + `wsb stop`).
    2. Launches a fresh sandbox (`wsb start --raw`).
    3. Shares the project folder read-only to `C:\go-mapi` inside.
    4. Shares `$env:TEMP\go-mapi-sandbox-output` as writable `C:\output` for log retrieval.
    5. Runs `test-dll-registration.ps1` (DLL sanity check).
    6. Runs `install-and-verify.ps1`:
       - Silent install of `go-mapi-setup.exe` with `/VERYSILENT /SUPPRESSMSGBOXES`
       - Asserts 6 HKLM registry keys (Clients\Mail\go-mapi + 5 browser native messaging hosts)
       - Asserts installed files (`go-mapi.dll`, `go-mapi-host.exe`, `com.gomapi.host.json`, `previous-mail-client.json`)
       - Silent uninstall via `unins000.exe /VERYSILENT`
       - Asserts clean post-uninstall state (no files, no registry leftovers)
    7. Copies the `install-and-verify.log` back to the host.
    8. Stops the sandbox (pass `-KeepRunning` to skip cleanup).

    ### Expected runtime

    | Operation | Typical time |
    |-----------|--------------|
    | Sandbox cold start | 30-60s |
    | DLL registration test | 5s |
    | Silent install | 15-30s |
    | Registry + file verification | 5s |
    | Silent uninstall | 10-20s |
    | Post-uninstall cleanup verify | 5s |
    | **Full `-FullTest` total** | **~3-5 min** |

    First run on a cold machine can take longer (up to 10 min) due to
    Windows Defender scanning the sandbox template.

    ## Failure modes

    - **`wsb CLI not found`** — you're not on Windows 11 24H2+. The harness
      exits with a clear message.
    - **"Existing sandbox found"** — the harness auto-stops any running
      sandbox before launching a new one. If `wsb stop` hangs, restart
      explorer.exe or reboot.
    - **Installer not compiled** — the `-FullTest` branch checks for
      `src\installer\dist\go-mapi-setup.exe` on the host BEFORE starting
      the sandbox and exits with a compile-command hint if missing.
    - **Silent install exit code non-zero** — check
      `$env:TEMP\go-mapi-sandbox-output\inno-install.log` (copied from
      `C:\output` inside the sandbox).
    - **Registry key missing** — `install-and-verify.log` lists the exact
      missing key. Cross-reference against `src/installer/go-mapi.iss`
      `[Registry]` section.
    - **Windows Defender scanning interferes** — sandbox-internal Defender
      is enabled by default. If the install step times out, add
      `<ProtectedClient>Disable</ProtectedClient>` to `sandbox.wsb` at the
      cost of lower isolation (sandbox-internal only — host protection is
      unaffected).

    ## Relation to other test surfaces

    | Test | Environment | Runs |
    |------|-------------|------|
    | `test-dll-registration.ps1` | sandbox, `-RegistrationOnly` | DLL registration sanity |
    | `install-and-verify.ps1` | sandbox, `-FullTest` | Install → verify → uninstall round-trip |
    | `src/installer/tests/installer.Tests.ps1` | CI (`installer-smoke.yml`) | Pester 5 authoritative smoke test |
    | Playwright `tests/e2e/*.spec.ts` | CI (`e2e.yml`) | End-to-end browser → host → mock Gmail |

    The sandbox harness is INTENTIONALLY lighter than the Pester smoke test
    — it runs in ~5 min vs ~15 min and has no browser/Playwright dependency.
    Pester stays the CI authority; the sandbox is the local feedback loop.

    ## Files in this directory

    - `run-sandbox-test.ps1` — orchestrator (host side, uses `wsb` CLI)
    - `setup.ps1` — in-sandbox WinAppDriver setup (legacy, used by `-SetupOnly`)
    - `test-dll-registration.ps1` — in-sandbox DLL registration sanity check
    - `install-and-verify.ps1` — in-sandbox install → verify → uninstall runner (REL-02)
    - `sandbox.wsb` — declarative Windows Sandbox config (for `wsb start --config` or double-click)
    - `README.md` — this file
    ```

    Commit with: `docs(05-02): harden tests/sandbox harness + README for REL-02 local repro`
  </action>
  <verify>
    <automated>test -f tests/sandbox/README.md &amp;&amp; grep -q "Windows 11 24H2" tests/sandbox/README.md &amp;&amp; grep -q "pwsh tests.sandbox.run-sandbox-test.ps1 -FullTest" tests/sandbox/README.md &amp;&amp; grep -q "install-and-verify.ps1" tests/sandbox/run-sandbox-test.ps1 &amp;&amp; ! grep -q "TODO: Implement WinAppDriver-based UI automation" tests/sandbox/run-sandbox-test.ps1 &amp;&amp; pwsh -NoProfile -Command "\$errors=@(); [System.Management.Automation.Language.Parser]::ParseFile('tests/sandbox/run-sandbox-test.ps1', [ref]\$null, [ref]\$errors); if (\$errors.Count -eq 0) { exit 0 } else { exit 1 }"</automated>
  </verify>
  <acceptance_criteria>
    - `tests/sandbox/README.md` exists
    - `grep -q "Windows 11 24H2" tests/sandbox/README.md` matches
    - `grep -q "pwsh tests\\\\sandbox\\\\run-sandbox-test.ps1 -FullTest" tests/sandbox/README.md` matches (the exact documented entry point)
    - `grep -q "install-and-verify.ps1" tests/sandbox/README.md` matches
    - `grep -q "wsb" tests/sandbox/README.md` matches (CLI prerequisite mentioned)
    - `grep -q "install-and-verify.ps1" tests/sandbox/run-sandbox-test.ps1` matches (new FullTest branch wired)
    - `grep -q "TODO: Implement WinAppDriver-based UI automation" tests/sandbox/run-sandbox-test.ps1` returns NO match (stub removed)
    - `grep -q "REL-02 FULL TEST PASSED" tests/sandbox/run-sandbox-test.ps1` matches (new success banner)
    - PowerShell parses `run-sandbox-test.ps1` with zero errors via `[Parser]::ParseFile`
    - No other file under `tests/sandbox/` was modified by this task (setup.ps1, test-dll-registration.ps1 untouched)
  </acceptance_criteria>
  <done>
    `pwsh tests/sandbox/run-sandbox-test.ps1 -FullTest` on a Windows 11 24H2+ host actually runs the full install → verify → uninstall flow instead of printing a TODO. README documents the prerequisites, expected runtime, and failure modes.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| host filesystem → sandbox guest | Read-only mount of the project folder into `C:\go-mapi` inside the sandbox |
| host filesystem → sandbox guest | Writable mount of `$env:TEMP\go-mapi-sandbox-output` into `C:\output` inside the sandbox (log retrieval) |
| sandbox guest → host system | None — Windows Sandbox is fully isolated at the VM level |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-05-02-01 | Tampering | Untrusted installer execution inside sandbox | accept | Sandbox is explicitly the quarantine environment — running the installer there is the entire point. Host is isolated at the VM level, and `<ReadOnly>true</ReadOnly>` on the project mount prevents guest-side tampering from contaminating the host source tree. |
| T-05-02-02 | Information Disclosure | `C:\output` writable share exposes guest logs to host | accept | By design — log retrieval requires this. Logs contain registry paths and file paths only; no credentials or user data pass through the installer (no OAuth, no network calls). |
| T-05-02-03 | Elevation of Privilege | Guest runs with `--run-as System` via `wsb exec` | accept | Required for HKLM writes inside the sandbox. Sandbox SYSTEM is isolated from host SYSTEM — no privilege escalation across the VM boundary. |
| T-05-02-04 | Denial of Service | Sandbox startup hangs on cold machine | mitigate | README.md documents the "first run can take 10 min due to Defender scanning the template" expectation. `run-sandbox-test.ps1` already auto-stops any existing sandbox before launching a new one, preventing accumulation of stuck sandboxes. |
| T-05-02-05 | Tampering | Committed `.wsb` config could be altered to remove `<ReadOnly>true</ReadOnly>` | mitigate | Task 1 acceptance criterion pins `<ReadOnly>true</ReadOnly>` via grep. Any PR modifying this line would fail the plan's verification on a replay. |
| T-05-02-06 | Supply Chain | `install-and-verify.ps1` downloads nothing, compiles nothing | accept | Everything is read from the host project share or produced by the installer being tested. No external downloads inside the script. |
</threat_model>

<verification>
- `test -f tests/sandbox/sandbox.wsb` succeeds and contains `<HostFolder>`, `<SandboxFolder>C:\go-mapi</SandboxFolder>`, and `<ReadOnly>true</ReadOnly>`
- `test -f tests/sandbox/install-and-verify.ps1` succeeds and contains the six expected HKLM keys, `VERYSILENT`, and `unins000.exe`
- `test -f tests/sandbox/README.md` succeeds and contains `Windows 11 24H2`, `install-and-verify.ps1`, and the `pwsh tests\sandbox\run-sandbox-test.ps1 -FullTest` entry point
- `run-sandbox-test.ps1` TODO stub is replaced with the `install-and-verify.ps1` invocation
- All PowerShell files parse cleanly via `[Parser]::ParseFile`
- Phase 5 goal-backward check: on a Windows 11 24H2 host, running `pwsh tests/sandbox/run-sandbox-test.ps1 -FullTest` after a local Inno Setup compile produces a green "REL-02 FULL TEST PASSED" banner or a clearly-red failure with the specific failing assertion in the log
</verification>

<success_criteria>
REL-02 closed: `tests/sandbox/` now contains the `.wsb` config, the install-and-verify runner, the hardened `-FullTest` branch, and the README.md with prerequisites (Windows 11 24H2+ + `wsb` CLI) and expected runtime. Marc has a local repro path for CI failures and a secondary UAT environment for REL-06.
</success_criteria>

<output>
After completion, create `.planning/phases/05-release-cut/05-02-SUMMARY.md` per the standard summary template.
</output>
