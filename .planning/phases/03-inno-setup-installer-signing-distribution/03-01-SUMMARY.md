---
plan: 03-01
phase: 03
status: complete
completed: 2026-04-10
commits:
  - ba4d562 feat(03-01): add Inno Setup installer script (INST-01..06)
---

# Plan 03-01 Summary: Inno Setup installer script

## What shipped

- `src/installer/go-mapi.iss` — complete Inno Setup 6 script (~320 lines
  including Pascal Script `[Code]` section) producing a single
  `go-mapi-setup.exe` installer.
- `src/installer/README.md` — build instructions, silent install/uninstall
  switches, what the installer does, manifest schema pointer, extension ID
  update procedure, smoke test pointer.

## Requirements satisfied

- **INST-01**: `src/installer/` directory with a first-class `go-mapi.iss`
  Inno Setup 6 script. `OutputBaseFilename=go-mapi-setup` produces
  `go-mapi-setup.exe` so the stable `latest/download` URL works.
- **INST-02**: `[Files]` copies `go-mapi.dll` and `go-mapi-host.exe` to
  `{app}=%ProgramFiles%\go-mapi`. `[Registry]` registers the MAPI handler
  at `HKLM\SOFTWARE\Clients\Mail\go-mapi` with `DLLPath={app}\go-mapi.dll`.
- **INST-03**: `RenderManifest()` Pascal helper reads the embedded
  `com.gomapi.host.chrome.json.tmpl` (extracted via
  `ExtractTemporaryFile`), performs literal `StringChange` substitution of
  `{{HOST_PATH}}` (JSON-escaped) and `{{EXTENSION_ID}}`, and writes the
  rendered manifest to `{commonappdata}\go-mapi\com.gomapi.host.json`.
  `[Registry]` writes five HKLM browser trees (Chrome, Chromium, Edge,
  Brave, Vivaldi), all pointing at the shared manifest path.
- **INST-04**: `PrivilegesRequired=admin` gives a single UAC prompt. All
  state under HKLM and `{commonappdata}\go-mapi\`, no per-user state. The
  runtime `%TEMP%\go-mapi\` directory is created by the native host at
  first run, not by the installer.
- **INST-05**: `BackupPreviousMailClient()` writes a JSON backup to
  `{commonappdata}\go-mapi\uninst\previous-mail-client.json` before the
  default is overwritten. The "skip if backup exists" rule preserves the
  original backup across upgrade reinstalls, so the uninstaller always
  restores the value that was in place BEFORE the first go-mapi install.
- **INST-06**: `CurUninstallStepChanged` removes the shared manifest,
  backup JSON, `{commonappdata}\go-mapi` directory, and best-effort
  `%TEMP%\go-mapi\`. The five browser trees and MAPI handler key are
  removed declaratively via the `uninsdeletekey` flag on the `[Registry]`
  entries. `RestorePreviousMailClient()` reads the backup JSON via a
  minimal Pascal Script substring parser (`ExtractJsonStringField`) and
  restores the value; falls back to `Microsoft Outlook`, `Outlook`,
  `Windows Mail` in order, or clears the key if none exist.

## Notable decisions

- Pascal Script over declarative `[Run]` sections wherever custom logic is
  needed (backup, manifest rendering, restore, temp cleanup). The
  `[Registry]` section handles the deterministic key writes/deletes via
  `uninsdeletekey`.
- Manifest template embedded via `Flags: dontcopy` in `[Files]` — stored
  in the installer binary, extracted on demand via `ExtractTemporaryFile`.
  No separate installation step for the template, no external file
  dependency at install time.
- JSON-escape backslashes in the host path (`StringChange(..., '\\', '\\\\')`)
  before template substitution, matching the PowerShell helper in
  `scripts/install.ps1` (comment block at lines ~174-186 there).
- `AppId` is a fixed GUID (`{{A5F0B0B6-3E2A-4B5C-8C7D-9F1E2A3B4C5D}`) so
  upgrade installs are recognized as the same product across versions.
  Chosen randomly once and committed; never regenerate.
- `GO_MAPI_EXTENSION_ID` constant in `[Code]` is the placeholder
  `PLACEHOLDER_EXTENSION_ID_32CHR` (matches `scripts/install.ps1`'s
  fallback). Single-point edit when the Chrome Web Store listing is
  published.

## Verification

- **Grep checks (on executor host)**: all acceptance-criteria grep
  patterns from the plan match. 22/22 pass. See plan file for the full
  list.
- **`iscc.exe` compile**: NOT verified on the executor host (no Inno
  Setup installed here). Will be verified in CI by the smoke-test
  workflow (Plan 03-04) on every PR.
- **Pascal Script semantics**: reviewed against Inno Setup 6
  documentation — all functions used (`LoadStringFromFile`,
  `SaveStringToFile`, `StringChange`, `RegQueryStringValue`,
  `RegWriteStringValue`, `RegKeyExists`, `ExtractTemporaryFile`,
  `DelTree`, `DeleteFile`, `RemoveDir`, `ForceDirectories`,
  `ExpandConstant`, `GetDateTimeString`, `GetEnv`, `SetArrayLength`,
  `Pos`, `Copy`, `Length`) are standard Pascal Script builtins available
  since Inno Setup 5.x.

## Known gaps

- `%TEMP%\go-mapi\` cleanup is best-effort and only sees the
  uninstaller's `%TEMP%` (usually SYSTEM's temp on elevated uninstall),
  not real-user temp directories. Documented in CONTEXT D-15 as
  acceptable given the native host already deletes runtime files
  on-process.
- The `[Files]` source paths use `{#SourcePath}\..\..\src\interceptor\build\bin\go-mapi.dll`
  which is correct relative to `src/installer/go-mapi.iss` but requires
  the caller to invoke `iscc` with the `.iss` file as an argument (so
  `#SourcePath` resolves to `src/installer/`). The CI workflow does this
  correctly. Local invocations must not `cd` into `src/installer/`
  because `#SourcePath` is compile-time-resolved to the `.iss` parent.
