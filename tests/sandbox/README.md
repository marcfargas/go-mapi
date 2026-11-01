# Windows Sandbox guest checks

Use the [Windows development guide](../../docs/windows-development.md) for host
setup and compilation. The Justfile is the command entrypoint; host orchestration
lives in `scripts/`, its contracts in `scripts/tests/`, and guest programs here.
`phase11/` remains a separate human-observed installed-email journey.

## Execution boundary

Crabbox is the preferred lifecycle owner. The native `wsb` runner is a bounded
workaround until Crabbox demonstrates selected-input isolation, SYSTEM execution,
retained diagnostics, bounded waits and exact-owned cleanup. Remove the native
runner and its provider-specific contracts together when that replacement passes.

Run Sandbox commands from an interactive Windows desktop with PowerShell 7 and
`wsb` on PATH. Session 0 is rejected before launch. The runner refuses existing
sandboxes and stops only its returned ID; do not run other Sandbox tools concurrently.

```powershell
just sandbox-smoke
just sandbox-test -InputDirectory C:\selected-artifacts\check -ScriptPath Test.ps1 -RunAs System -TimeoutSeconds 600
```

Smoke checks sharing, identity, execution, retained output and cleanup, without
product tests. Custom scripts receive `-InputDirectory C:\input -OutputDirectory
C:\output` under Windows PowerShell 5.1. `ScriptPath` is relative to the selected
input directory. Inputs are read-only; only the unique output share is writable.
Select only required artifacts, fixtures and scripts. Repository/profile roots,
`.git`, `.env*` and reparse points are refused; inspect other inputs for secrets.
Copy artifacts locally in the guest before modifying them. Check every native
exit code and save diagnostics as work proceeds. A reboot is outside this contract.
The default identity is SYSTEM. `-RunAs ExistingLogin` (or `-RunAsExistingLogin`)
waits up to 90 seconds within the overall run deadline for a harmless guest probe
to exit zero and observe Explorer in its own session with its owner SID. Add
`-Connect` to start a hidden, asynchronous `wsb connect` client for the exact owned
guest after sharing inputs; connection alone does not prove readiness. The runner
retains connection streams and every readiness attempt, retries only the probe,
and executes the selected script once. It creates no users or logon credentials.
Owned-guest stop keeps its separate 30-second allowance, and only the retained
connection client is terminated/disposed during cleanup.

## Native and optional service feedback

Build x86/x64 test artifacts using the host commands in the development guide.
The current Ninja/static-runtime layout is supported; extra runtime DLLs and
multi-configuration builds are outside this procedure. Native compilation needs
a checkout path without spaces because of an existing linker argument limitation.
Staging already-built artifacts from paths with spaces is supported.

In a host PowerShell 7 shell, optionally compile service tests and stage inputs:

```powershell
go test -c -o .tmp/service.test.exe ./src/service
if ($LASTEXITCODE -ne 0) { throw 'Service test compilation failed' }
$selected = & ./scripts/prepare-native-inputs.ps1 `
    -OutputDirectory (Join-Path $PWD ('test-results/native-' + [guid]::NewGuid().ToString('N'))) `
    -ServiceTestBinary .tmp/service.test.exe
just sandbox-test -InputDirectory $selected.InputDirectory -ScriptPath $selected.ScriptPath -RunAs System -TimeoutSeconds 900
```

`just prepare-native-inputs` exposes the same preparer for command-line use.
Omit `-ServiceTestBinary` for native-only proof. The preparer reads existing
artifacts, refuses an existing output directory, and validates PE architectures,
hashes and compiled fixture definitions. `-CheckoutRoot`, `-X64BuildDirectory`,
`-X86BuildDirectory` and `-Configuration Debug` select alternate builds.
`-FixtureSourceRoot` selects the directory containing `protocol-fixtures` and
`component-compatibility` when fixtures have moved.

Unit binaries contain absolute fixture paths. `native-inputs.json` records each
build's compiled destinations, source/build metadata, checkout identity and selected
file hashes. Relocation changes input locations, never compiled destinations.
The v2 manifest requires optional service inputs to include the binary and the
hashed `src/service/runner_windows.go` fixture from `-CheckoutRoot`; the guest
copies both together and runs tests from that directory. Older manifests must be
prepared again. Only this required service source file is staged.
Retain source/build evidence separately: checkout HEAD alone cannot identify dirty
inputs used to build an existing binary.

The guest verifies hashes, restores fixtures at compiled paths (using guest-local
`subst` for missing drives), and runs four unit executables plus the matching DLL
harness for each architecture. Harnesses write the canonical queue. Optional
service tests change process privilege and create a disabled service fixture;
the guest requires its initial absence and checks removal afterward. These
machine effects belong only in the disposable guest.

Inspect `output/native-result.json`, the copied manifest and individual command
stdout/stderr/results. A failure stops subsequent tests. Partial evidence remains
useful if timeout prevents a final summary. This proves native/direct-DLL and
optional service-test behavior; installed email and package lifecycle need their
own journeys.

## Evidence and host contracts

The runner prints its unique evidence directory before launch. By default it is
under `%LOCALAPPDATA%\agent-work\retained\go-mapi\sandbox`; `-EvidenceRoot`
selects another parent outside inputs. It retains input hashes, command arguments,
separate stdout/stderr, exit codes, owned ID, guest transcript and `result.json`.
Success returns `Status = PASS`, `Cleanup = stopped` and `GuestExitCode = 0`.
Failures throw, including malformed CLI JSON or unsuccessful cleanup.

`TimeoutSeconds` bounds list/start/share/exec (default 300, range 1-3600), after
input validation/hashing. Cleanup has a separate 30-second deadline and runs despite
evidence-write failures. A start failure without a usable ID leaves ownership
unknown: inspect `wsb list --raw` and retained diagnostics; never guess an ID or
kill processes by name. A failed owned stop records its ID for manual inspection.

```powershell
just test-windows-tooling
just test-native-inputs -ServiceTestBinary .tmp/service.test.exe
```

The first runs host script contracts without a guest. The second separately
requires existing Release artifacts and Windows PowerShell 5.1; it checks staging,
relocation, hashes, rejection and harmless native exit/stream handling. Neither
command executes product native/service tests or establishes a real guest pass.
