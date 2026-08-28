# tests/sandbox — Windows Sandbox local repro harness (REL-02)

Local alternative to `.github/workflows/build.yml`. Runs the full
v2.0.0 installer install → verify registry → uninstall flow inside a fresh
Windows Sandbox so you can reproduce CI failures (or verify changes)
without touching your host's MAPI registration or `%ProgramFiles%`.

**This does not replace CI.** `build.yml` remains the
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
cd src\interceptor; .\build.ps1 -Config Release -Clean; cd ..\..
cd src\native-host; go build -ldflags "-s -w -X main.Version=2.0.0-local" -o build\go-mapi-host.exe .; cd ..\..
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
| `src/installer/tests/installer.Tests.ps1` | CI (`build.yml`) | Pester 5 authoritative smoke test |
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
