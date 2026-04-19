# Phase 10: Installer + Migration - Pattern Map

**Mapped:** 2026-04-19
**Files analyzed:** 14 (8 created, 4 modified, 2 deleted)
**Analogs found:** 12 / 14 (2 are vendored binaries with no code analog)

## File Classification

| File | Role | Data Flow | Closest Analog | Match Quality |
|------|------|-----------|----------------|---------------|
| **CREATED** | | | | |
| `src/installer/go-mapi.nsi` | installer-script | batch / registry-IO | v2.0 `src/installer/go-mapi.iss` (deleted; reference: `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/03-01-PLAN.md`) + RESEARCH §Code Examples 1,2,3,4,6,7,8,9,10 | role-match (tool change Inno → NSIS, same surface) |
| `src/installer/plugins/x86-unicode/ApplicationID.dll` | vendored-binary | n/a | **none** (downloaded once from nsis.sourceforge.io/ApplicationID_plug-in) | no analog |
| `src/installer/MicrosoftEdgeWebview2Setup.exe` | vendored-binary | n/a | **none** (Microsoft redistributable; ~2 MB) | no analog |
| `src/installer/tests/installer.Tests.ps1` | test (Pester 5) | assertion / registry-IO | `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/03-04-PLAN.md` Task 1 (v2.0 Pester) + RESEARCH §Code Example 11,12 | exact (role + data flow; Pester 5 syntax identical) |
| `src/app/webview2_check.go` | go-source (fatal startup guard) | request-response (sync check → error) | `src/app/credentials_check.go` (lines 1–24) | **exact** (same role: build-tag-split fatal guard returning `error`) |
| `src/app/webview2_check_bindings.go` | go-source (bindings stub) | no-op | `src/app/credentials_check_bindings.go` (lines 1–10) | **exact** (1:1 sibling pattern) |
| `.github/workflows/installer-release.yml` | ci-workflow | tag-trigger pipeline | `.github/workflows/build.yml` (structure) + `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/03-03-PLAN.md` (release-workflow v2.0) + RESEARCH §Code Example 14 | role-match (new workflow, composed from build.yml + v2.0 release pattern + RESEARCH seed) |
| `.github/workflows/installer-smoke.yml` | ci-workflow | push/PR gate | `.github/workflows/build.yml` (structure) + `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/03-04-PLAN.md` Task 2 + RESEARCH §Code Example 13 | role-match |
| **MODIFIED** | | | | |
| `src/app/main.go` | go-source (entry) | add startup check | `src/app/main.go:37-40` (existing `checkOAuthCredentials` call) | exact (add a second guard call of the same shape) |
| `src/app/wails.json` | build-config | add `info.productVersion` | existing `src/app/wails.json:1-13` | exact (additive field per wails schema) |
| `README.md` | docs | add note | existing README sections | role-match (docs task, no code analog needed) |
| `.github/release-template.md` (optional) | docs | release-notes scaffold | v2.0 D-24 release-notes template (if present under v2.0 phase) | role-match |
| **DELETED** | | | | |
| `src/installer/dist/go-mapi-setup.exe` | built-artifact | n/a | v2.0 build output — stale per D-31 | n/a |
| `src/installer/go-mapi.iss` | installer-script | n/a | **does NOT exist today** (confirmed via `Glob src/installer/**/*` returned only `src\installer\dist\go-mapi-setup.exe`). D-31 allows skipping this deletion since the file is already absent. | n/a |

---

## Pattern Assignments

### `src/app/webview2_check.go` (go-source, fatal startup guard)

**Analog:** `src/app/credentials_check.go` (exact match — this is the reference precedent per CONTEXT D-08 and RESEARCH §Pattern 1).

**Build tag header + package comment pattern** (analog lines 1–15):

```go
//go:build !bindings

package main

import "errors"

// checkOAuthCredentials is the D-10 fatal guard — run on every normal startup
// (production, wails dev) but skipped under the `bindings` build tag so that
// `wails build` / `wails generate module` can regenerate TypeScript bindings
// without real credentials being present in the dev environment.
//
// Returns a non-nil error if the OAuth client_id or client_secret is empty
// (indicating the -ldflags / env var injection was not wired correctly).
// Callers — specifically main.go — decide how to react (log + os.Exit);
// returning an error instead of exiting directly makes this testable.
```

**Core pattern** (analog lines 16–24):

```go
func checkOAuthCredentials() error {
    if oauthClientID == "" {
        return errors.New("OAuth client_id missing — build was not wired correctly (...)")
    }
    if oauthClientSecret == "" {
        return errors.New("OAuth client_secret missing — build was not wired correctly (...)")
    }
    return nil
}
```

**Divergences Phase 10 must make:**
1. Function name: `checkWebView2` (not `checkOAuthCredentials`).
2. Import list: add `golang.org/x/sys/windows/registry` (confirmed available — `src/app/go.mod:14` declares `golang.org/x/sys v0.30.0`).
3. Body: registry-key probe loop per RESEARCH §Pattern 1 (three registry paths: WOW6432Node 64-bit view, direct HKLM, then HKCU per-user).
4. Success condition: `pv` string value present AND not `"0.0.0.0"`.
5. Error message: `"WebView2 runtime not installed"`.
6. Also adds a sibling function `showWebView2MissingDialog()` for the `MessageBoxW` native dialog (RESEARCH §Code Example 5). See "Shared Pattern: `user32.dll` LazyDLL" below — this MUST extend the existing `user32` handle in `sessionend.go`, not create a second one.

---

### `src/app/webview2_check_bindings.go` (go-source, bindings stub)

**Analog:** `src/app/credentials_check_bindings.go` (exact match — 1:1 sibling pattern).

**Full analog** (all 10 lines):

```go
//go:build bindings

package main

// checkOAuthCredentials is a no-op under the `bindings` build tag.
// The wailsbindings.exe binary only introspects types and method signatures —
// it never opens a browser or calls Google — so real OAuth credentials are
// not needed and the D-10 guard must not abort the process. Returns nil
// to match the signature in credentials_check.go.
func checkOAuthCredentials() error { return nil }
```

**Divergences Phase 10 must make:**
1. Rename function: `checkWebView2` returns `nil`.
2. Update the doc comment: "never touches WebView2" instead of "never opens a browser".
3. Also add no-op stub for `showWebView2MissingDialog()` if that helper is referenced in the `!bindings` tagged file (keep symbol shapes identical across both build tags — compile cleanly under `go build -tags=bindings`).

---

### `src/app/main.go` (modification — add WebView2 check before OAuth check)

**Analog:** `src/app/main.go:37-40` (existing guard invocation pattern):

```go
// D-10: Fail fast if OAuth credentials were not injected. A release build
// with empty client_id silently cannot sign anyone in — louder now is kinder.
// Guard is skipped under the `bindings` build tag (wailsbindings.exe) so that
// Wails can generate TypeScript bindings without needing real credentials at
// dev time. In production and wails dev, the guard is always active.
// The check itself returns an error (testable); main owns the os.Exit(1).
if err := checkOAuthCredentials(); err != nil {
    logError("FATAL: %s", err.Error())
    os.Exit(1)
}
```

**Insertion point:** Between line 29 (`defer releaseSingleInstance()`) and line 37 (existing OAuth check). Per RESEARCH §Pattern 1, WebView2 check runs **before** OAuth check — there's no point warming up credentials if the UI layer can't render.

**Divergence from the analog pattern:** On WebView2 failure the branch is not a simple log+exit; it does three things before `os.Exit(1)`:
1. `logError("FATAL: WebView2 runtime missing")`
2. `showWebView2MissingDialog()` (blocks on OK)
3. `_ = browser.OpenURL("https://developer.microsoft.com/en-us/microsoft-edge/webview2/")`
4. `os.Exit(1)`

Add `"github.com/pkg/browser"` import (confirmed already in deps per CLAUDE.md stack list + Phase 8 OAuth usage).

---

### `src/installer/go-mapi.nsi` (installer-script)

**Analog (structural):** v2.0 `src/installer/go-mapi.iss` — **deleted** from current tree but documented in `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/03-01-SUMMARY.md` and `03-02-SUMMARY.md`. Since the Inno `.iss` no longer exists as a file, the primary code source is **RESEARCH §Code Examples 1, 2, 3, 4, 6, 7, 8, 9, 10** — these are NSIS-native scaffolds drafted by the researcher for exactly this plan.

**Pattern 1 — Script header + ModernUI2 + admin (RESEARCH §Code Example 1):**

```nsi
Unicode True
!define PRODUCT_NAME      "go-mapi"
!define PRODUCT_VERSION   "${GOMAPI_VERSION}"
!define AUMID             "com.marcfargas.gomapi"

SetCompressor /SOLID lzma
RequestExecutionLevel admin
InstallDir   "$PROGRAMFILES64\go-mapi"
OutFile      "go-mapi-setup.exe"

!addplugindir "${__FILEDIR__}\plugins"
!include "MUI2.nsh"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${__FILEDIR__}\..\..\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
```

**Pattern 2 — Install section with MAPI handler + AUMID + firewall (RESEARCH §Code Example 2, 6, 10):**

```nsi
Section "Install" SecInstall
  SetOutPath "$INSTDIR"
  File "${__FILEDIR__}\..\app\build\bin\go-mapi.exe"
  File "${__FILEDIR__}\..\interceptor\build\bin\go-mapi.dll"

  Call BackupPreviousMailClient                          ; D-10

  WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "" "go-mapi"
  WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "DLLPath" "$INSTDIR\go-mapi.dll"
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "go-mapi"   ; D-09 — AFTER backup

  WriteUninstaller "$INSTDIR\uninstall.exe"
  ; Add/Remove Programs metadata
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "DisplayName"    "${PRODUCT_NAME}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "DisplayVersion" "${PRODUCT_VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "UninstallString" '"$INSTDIR\uninstall.exe"'

  Call InstallWebView2
  Call CreateShortcutAndAUMID
  Call AddFirewallRule
SectionEnd
```

**Pattern 3 — AUMID stamping via plugin (RESEARCH §Code Example 6, §Pitfall 2):**

```nsi
Function CreateShortcutAndAUMID
  CreateShortcut "$SMPROGRAMS\go-mapi.lnk" "$INSTDIR\go-mapi.exe" "" "$INSTDIR\go-mapi.exe" 0 SW_SHOWNORMAL "" "go-mapi — MAPI-to-Gmail bridge"
  ApplicationID::Set "$SMPROGRAMS\go-mapi.lnk" "${AUMID}"
  Pop $0
  StrCmp $0 "0" +3
    DetailPrint "WARNING: AUMID stamp rc=$0 — Action Center persistence may break"
FunctionEnd
```

**Pattern 4 — Firewall rule via netsh (RESEARCH §Code Example 10, §Pitfall 4):**

```nsi
Function AddFirewallRule
  ExecWait 'netsh advfirewall firewall add rule name="go-mapi OAuth loopback" dir=in program="$INSTDIR\go-mapi.exe" action=allow profile=any' $0
  DetailPrint "firewall add rc=$0"
FunctionEnd
```

**Pattern 5 — Uninstall 10-step scrub (RESEARCH §Code Example 7, D-18):**

```nsi
Section "Uninstall"
  ExecWait 'netsh advfirewall firewall delete rule name="go-mapi OAuth loopback"' $0
  Delete "$SMPROGRAMS\go-mapi.lnk"
  DeleteRegKey HKLM "SOFTWARE\Clients\Mail\go-mapi"
  Call un.RestorePreviousMailClient
  RMDir /r "$APPDATA\..\..\ProgramData\go-mapi\uninst"
  RMDir    "$APPDATA\..\..\ProgramData\go-mapi"
  RMDir /r "$TEMP\go-mapi"
  RMDir /r "$APPDATA\go-mapi"
  ExecWait 'cmdkey /delete:go-mapi:oauth-tokens' $0
  Delete "$INSTDIR\go-mapi.exe"
  Delete "$INSTDIR\go-mapi.dll"
  Delete "$INSTDIR\uninstall.exe"
  Delete "$INSTDIR\install.log"
  RMDir "$INSTDIR"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}"
SectionEnd
```

**Divergences Phase 10 must make from v2.0 `.iss`:**
1. Pascal Script → NSIS Script (different grammar; no `procedure`/`begin`/`end` blocks — NSIS uses `Function` / `FunctionEnd` with labels + `Goto`).
2. Inno's built-in `ssPostInstall` event handler → NSIS `Section`/`Call` composition.
3. Inno native `IsAdminLoggedOn` → NSIS `RequestExecutionLevel admin` (no runtime check needed, NSIS enforces at launch).
4. `/VERYSILENT /SUPPRESSMSGBOXES` (Inno flags) → `/S` (NSIS, capital S only per §Pitfall 5).
5. AUMID: v2.0 used external PowerShell `ExecWait`; Phase 10 uses `ApplicationID::Set` plugin one-liner (D-14).
6. WebView2: NEW in Phase 10 (v2.0 did not bundle a runtime bootstrapper).
7. Version injection: `iscc /DMyAppVersion=3.0.0` → `makensis /DGOMAPI_VERSION=3.0.0`.

---

### `src/installer/tests/installer.Tests.ps1` (test — Pester 5)

**Analog:** v2.0 `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/03-04-PLAN.md` Task 1 (full Pester skeleton, ~250 lines). Pester 5 syntax applies directly — RESEARCH §Code Example 11 provides the Phase-10-specific adaptation.

**BeforeAll pattern (v2.0 analog, 03-04-PLAN.md lines 38–56):**

```powershell
BeforeAll {
    $script:InstallerPath = Join-Path $PSScriptRoot '..\dist\go-mapi-setup.exe' | Resolve-Path -ErrorAction Stop
    $script:InstallDir = Join-Path $env:ProgramFiles 'go-mapi'
    $script:ProgramData = Join-Path $env:ProgramData 'go-mapi'
    $script:BackupPath = Join-Path $script:ProgramData 'uninst\previous-mail-client.json'
    $script:MapiHandlerKey = 'HKLM:\SOFTWARE\Clients\Mail\go-mapi'
    $script:MailClientsKey = 'HKLM:\SOFTWARE\Clients\Mail'
}
```

**Phase 10 adaptation (RESEARCH §Code Example 11, lines 822–826):**

```powershell
BeforeAll {
    $script:SetupExe   = Join-Path $PSScriptRoot '..\..\..\go-mapi-setup.exe' | Resolve-Path
    $script:InstallDir = "$env:ProgramFiles\go-mapi"
    $script:Aumid      = 'com.marcfargas.gomapi'
}
```

**Install-phase It pattern (v2.0 analog, lines 61–67):**

```powershell
It 'runs the installer silently and exits 0' {
    $proc = Start-Process -FilePath $script:InstallerPath `
        -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' `
        -Wait -PassThru
    $proc.ExitCode | Should -Be 0
}
```

**Phase 10 adaptation (silent flag changes per §Pitfall 5):**

```powershell
It "exits 0 when invoked with /S /D=..." {
    $proc = Start-Process -FilePath $script:SetupExe -ArgumentList '/S',"/D=$script:InstallDir" -Wait -PassThru
    $proc.ExitCode | Should -Be 0
}
```

**AUMID verification primitive (RESEARCH §Code Example 12):** Inline `Add-Type` with C# `IPersistFile` + `IPropertyStore` + `PropVariantToString` to read `PKEY_AppUserModel_ID` from the `.lnk`. Mirrors `scripts/register-dev-aumid.ps1` (stamp side, lines 60+) but in read mode. **Do NOT use `Get-StartApps`** (flaky per RESEARCH §Anti-Patterns).

**Credential Manager assertion (RESEARCH §Pitfall 3):**

```powershell
It "removes Credential Manager entry" {
    $out = & cmdkey /list:go-mapi:oauth-tokens 2>&1
    $out | Select-String -Pattern 'go-mapi:oauth-tokens' | Should -BeNullOrEmpty
}
```

Target string is `go-mapi:oauth-tokens` (colon, not slash — verified against `src/app/auth.go:27-28` + zalando/go-keyring Windows backend).

**Divergences from v2.0 Pester:**
1. Silent flags `/VERYSILENT /SUPPRESSMSGBOXES` → `/S` + `/D=...`.
2. Uninstaller path: `unins000.exe` (Inno) → `uninstall.exe` (NSIS).
3. NEW assertions: AUMID on `.lnk`, firewall rule present/gone, `%APPDATA%\go-mapi\` gone, Credential Manager scrubbed.
4. REMOVED: browser native-messaging keys (v2.x scope; clean-break per D-20).
5. Pester 5 syntax required (D-30); `-EnableExit` forbidden.
6. Invocation via `New-PesterConfiguration` + `Invoke-Pester -Configuration $config`.

---

### `.github/workflows/installer-smoke.yml` (ci-workflow)

**Analog (structural):** `.github/workflows/build.yml` — the existing per-PR Wails-build workflow. Same runner (`windows-latest`), same Go/Node setup chain, same artifact upload pattern. Phase 10 smoke workflow is additive — does NOT modify `build.yml` (per D-27 scope discipline).

**Setup-chain pattern** (analog `build.yml:60-78`):

```yaml
    steps:
      - uses: actions/checkout@v4

      - name: Setup Go
        uses: actions/setup-go@v5
        with:
          go-version: '1.25'

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 20

      - name: Install npm workspace dependencies
        run: npm ci

      - name: Build frontend (produces src/app/frontend/dist for go:embed)
        run: npm run -w @marcfargas/go-mapi-app-frontend build
```

**DLL build pattern** (analog `build.yml:22-29`):

```yaml
      - name: Install MinGW and Ninja
        run: |
          choco install mingw ninja cmake --no-progress -y
          echo "C:\ProgramData\chocolatey\lib\mingw\tools\install\mingw64\bin" >> $env:GITHUB_PATH

      - name: Build Interceptor and Test Harness
        working-directory: src/interceptor
        run: .\build.ps1 -Config ${{ matrix.config }} -Tests -Clean
```

**Phase 10 adaptation (RESEARCH §Code Example 13, lines 1013–1065):**

```yaml
name: Installer smoke test
on:
  push:
    branches: [main, develop]
    paths:
      - 'src/installer/**'
      - 'src/interceptor/**'
      - 'src/app/**'
      - '.github/workflows/installer-smoke.yml'
  pull_request:
    paths:
      - 'src/installer/**'
      - 'src/interceptor/**'
      - 'src/app/**'
      - '.github/workflows/installer-smoke.yml'
  workflow_dispatch:

jobs:
  smoke:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.25' }
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - name: Install Wails CLI
        run: go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0
      - name: Build interceptor DLL
        run: npm run build:interceptor
      - name: Build Wails app (dev creds — no SignPath for smoke)
        working-directory: src/app
        env:
          GOMAPI_OAUTH_CLIENT_ID:     ${{ secrets.GOMAPI_OAUTH_CLIENT_ID }}
          GOMAPI_OAUTH_CLIENT_SECRET: ${{ secrets.GOMAPI_OAUTH_CLIENT_SECRET }}
        run: |
          wails build -platform windows/amd64 -ldflags "-X main.aumidOverride=com.marcfargas.gomapi -X main.oauthClientID=$env:GOMAPI_OAUTH_CLIENT_ID -X main.oauthClientSecret=$env:GOMAPI_OAUTH_CLIENT_SECRET"
      - name: Compile installer
        run: makensis /DGOMAPI_VERSION=0.0.0-smoke src\installer\go-mapi.nsi
      - name: Run Pester
        shell: pwsh
        run: |
          $config = New-PesterConfiguration
          $config.Run.Path        = 'src/installer/tests/installer.Tests.ps1'
          $config.Run.Exit        = $true
          $config.Output.Verbosity = 'Detailed'
          Invoke-Pester -Configuration $config
```

**Divergences from `build.yml`:**
1. No matrix (single config — smoke test is end-to-end, not multi-config).
2. Skips `go vet` / `go test` / `svelte-check` / `vitest` steps (those are `build.yml`'s job — duplication avoided).
3. ADDS `makensis` compile step + `Invoke-Pester` step.
4. Uses `secrets.GOMAPI_OAUTH_CLIENT_ID` / `SECRET` from repo secrets (same names used by the dev `.env.local` convention per Phase 8 D-09).
5. Triggered path-filtered (per Open Question 3 recommendation) — NOT on every push to every file.

---

### `.github/workflows/installer-release.yml` (ci-workflow)

**Analog (structural):** `.github/workflows/build.yml` + v2.0 `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/03-03-PLAN.md` (v2.0 release workflow with SignPath two-call gating).

**Setup-chain pattern:** Identical to `installer-smoke.yml` above (checkout + Go + Node + Wails CLI + MinGW for DLL).

**Two-phase SignPath pattern (RESEARCH §Pattern 5 + §Code Example 14, lines 1074–1186):**

```yaml
name: Installer release
on:
  push:
    tags: ['v*']

permissions:
  contents: write       # for softprops/action-gh-release@v2
  actions:  read        # for SignPath v2 to read artifacts

jobs:
  release:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.25' }
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - name: Install Wails CLI
        run: go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0

      - name: Extract version + validate against tag
        id: version
        shell: pwsh
        run: |
          $json = Get-Content src/app/wails.json | ConvertFrom-Json
          $wailsVer = $json.info.productVersion
          $tagVer   = "${{ github.ref_name }}" -replace '^v',''
          if ($wailsVer -ne $tagVer) { throw "Tag $tagVer != wails.json $wailsVer" }
          "version=$wailsVer" >> $env:GITHUB_OUTPUT

      - name: Build interceptor DLL
        run: npm run build:interceptor

      - name: Build Wails app (release ldflags)
        working-directory: src/app
        env:
          GOMAPI_OAUTH_CLIENT_ID:     ${{ secrets.GOMAPI_OAUTH_CLIENT_ID }}
          GOMAPI_OAUTH_CLIENT_SECRET: ${{ secrets.GOMAPI_OAUTH_CLIENT_SECRET }}
        run: |
          wails build -platform windows/amd64 -ldflags "-X main.Version=${{ steps.version.outputs.version }} -X main.aumidOverride=com.marcfargas.gomapi -X main.oauthClientID=$env:GOMAPI_OAUTH_CLIENT_ID -X main.oauthClientSecret=$env:GOMAPI_OAUTH_CLIENT_SECRET"

      # SignPath pass 1: binaries pre-makensis
      - name: Upload binaries for SignPath (step 1)
        if: ${{ secrets.SIGNPATH_API_TOKEN != '' }}
        id: upload-binaries
        uses: actions/upload-artifact@v4
        with:
          name: go-mapi-binaries-unsigned
          path: staged/

      - name: SignPath — sign binaries
        if: ${{ secrets.SIGNPATH_API_TOKEN != '' }}
        uses: signpath/github-action-submit-signing-request@v2
        with:
          api-token:           ${{ secrets.SIGNPATH_API_TOKEN }}
          organization-id:     ${{ secrets.SIGNPATH_ORG_ID }}
          project-slug:        ${{ secrets.SIGNPATH_PROJECT_SLUG }}
          signing-policy-slug: ${{ secrets.SIGNPATH_SIGNING_POLICY_SLUG }}
          github-artifact-id:  ${{ steps.upload-binaries.outputs.artifact-id }}
          output-artifact-directory: staged-signed
          wait-for-completion: true

      # ... makensis compile, SignPath pass 2 on installer, then softprops/action-gh-release@v2 ...
```

**Divergences Phase 10 must make from v2.0 release workflow:**
1. `SignPath/github-action-submit-signing-request` pinned at `@v2` (CONTEXT D-23 says `@v1` — RESEARCH §State of the Art explicitly flags this as deprecated; planner MUST use `@v2`).
2. `softprops/action-gh-release@v2` stays (v3 is Node 24 beta, not ready).
3. Version source: `wails.json` `info.productVersion` (NEW) instead of `package.json` (v2.0).
4. ldflags list: `-X main.Version=...`, `-X main.aumidOverride=com.marcfargas.gomapi` (NEW — Phase 9 WR-01 seam), `-X main.oauthClientID=...`, `-X main.oauthClientSecret=...` (Phase 8 seams).
5. `permissions: contents: write` + `actions: read` at job level (RESEARCH §Code Example 14 note).
6. `iscc.exe` → `makensis.exe`; installer output `go-mapi-setup.exe` (unchanged name per D-03).

---

### `src/app/wails.json` (modification — add `info.productVersion`)

**Analog:** existing `src/app/wails.json` (all 13 lines). Phase 10 adds an `info` object with a single field.

**Current shape (verbatim):**

```json
{
  "$schema": "https://wails.io/schemas/config.v2.json",
  "name": "go-mapi",
  "outputfilename": "go-mapi",
  "frontend:install": "npm install",
  "frontend:build": "npm run build",
  "frontend:dev:watcher": "npm run dev",
  "frontend:dev:serverUrl": "auto",
  "author": {
    "name": "Marc Fargas",
    "email": "marc@marcfargas.com"
  }
}
```

**Required addition (D-26 + RESEARCH §Runtime State Inventory row 6):**

```json
{
  ...
  "info": {
    "productVersion": "3.0.0"
  },
  ...
}
```

Schema reference: `https://wails.io/schemas/config.v2.json` supports the `info.productVersion` field per Wails docs.

---

### `src/installer/plugins/x86-unicode/ApplicationID.dll` + `src/installer/MicrosoftEdgeWebview2Setup.exe` (vendored binaries)

**Analog:** none (code-level) — these are Microsoft + community redistributable binaries.

**Provenance:**
- `ApplicationID.dll`: NSIS plugin from https://nsis.sourceforge.io/ApplicationID_plug-in — download once, commit to `src/installer/plugins/x86-unicode/` (Unicode NSIS build default). Must be the `x86-unicode` variant (not `x86-ansi`) because the Phase 10 `.nsi` declares `Unicode True` per RESEARCH §Code Example 1.
- `MicrosoftEdgeWebview2Setup.exe`: ~2 MB online bootstrapper from https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution. Redistribution permitted per Microsoft terms. RESEARCH Open Question 4 recommends committing (determinism); alternative is fetch-at-CI with pinned SHA256.

**Licensing note for planner:** Both are compatible with LGPL-3.0 distribution (Microsoft bootstrapper is freely redistributable; ApplicationID plugin is zlib/libpng license per NSIS plugin conventions).

---

### `README.md` + optional `.github/release-template.md` (docs)

**Analog:** existing project README (structure); v2.0 D-24 release notes template (if present under `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/`).

**Required additions per D-20 + D-19:**
1. "Before installing v3.0: please uninstall any prior go-mapi v2.x from Add/Remove Programs." (one line, near install instructions)
2. Multi-user caveat: "Uninstalling go-mapi only scrubs the uninstalling user's stored Gmail credentials and settings. On multi-user machines, other users may need to manually remove their own `%APPDATA%\go-mapi\` directory and Credential Manager entry (`cmdkey /delete:go-mapi:oauth-tokens`)." (added to Uninstall section)

**No code excerpt needed — docs task only.**

---

## Shared Patterns

### Shared Pattern 1: Build-tag split for fatal startup guards
**Source:** `src/app/credentials_check.go` (lines 1–24) + `src/app/credentials_check_bindings.go` (lines 1–10)
**Apply to:** `webview2_check.go` + `webview2_check_bindings.go` (Phase 10 plan 10-02)

**Contract:**
1. `//go:build !bindings` file: real check, returns `error`.
2. `//go:build bindings` file: stub returns `nil`.
3. Function signatures match bit-for-bit so both files compile cleanly.
4. Caller in `main.go` handles the error (typically `logError` + `os.Exit(1)`, per current precedent).

**Verification:** The `bindings` tag is consumed by `wailsbindings.exe` at `wails build` time to introspect types without triggering fatal guards. Tests for this pattern live in `credentials_check_test.go` (also `//go:build !bindings` tagged — Phase 10 adds a sibling `webview2_check_test.go`).

---

### Shared Pattern 2: `user32.dll` LazyDLL handle (CRITICAL REUSE)
**Source:** `src/app/sessionend.go:23-33` (existing declarations):

```go
var (
    kernel32            = syscall.NewLazyDLL("kernel32.dll")
    procGetModuleHandle = kernel32.NewProc("GetModuleHandleW")

    user32            = syscall.NewLazyDLL("user32.dll")
    procRegisterClass = user32.NewProc("RegisterClassExW")
    procCreateWindow  = user32.NewProc("CreateWindowExW")
    procDefWindowProc = user32.NewProc("DefWindowProcW")
    procDestroyWindow = user32.NewProc("DestroyWindow")
    procGetMessage    = user32.NewProc("GetMessageW")
    procTranslateMsg  = user32.NewProc("TranslateMessage")
    procDispatchMsg   = user32.NewProc("DispatchMessageW")
    procPostQuitMsg   = user32.NewProc("PostQuitMessage")
    procPostMessage   = user32.NewProc("PostMessageW")
)
```

**Apply to:** `webview2_check.go` (`MessageBoxW` call).

**CRITICAL rule (pre-empts RESEARCH §Code Example 5 line 632 which naively re-declares `user32`):** `sessionend.go` already has `//go:build windows` + `var user32 = syscall.NewLazyDLL("user32.dll")`. Phase 10 `webview2_check.go` MUST NOT redeclare a second `user32` LazyDLL — Go would error with "user32 redeclared in this block" because both files are in `package main`.

**Correct pattern for `webview2_check.go`:**

```go
//go:build !bindings

package main

import (
    "syscall"
    "unsafe"
)

// REUSES the existing user32 LazyDLL declared in sessionend.go (var block).
// DO NOT redeclare — add a new sibling NewProc on the existing handle.
var procMessageBoxW = user32.NewProc("MessageBoxW")
```

**Alternative (planner's call):** add `procMessageBoxW` directly into the `var (...)` block in `sessionend.go` alongside the other user32 procs. This keeps all user32 handles co-located and matches the existing file's convention. Scope-discipline rule says the additive-in-a-new-file approach is preferred (keeps plan 10-02 diff narrow to `webview2_check.go`).

**Build tag alignment:** `sessionend.go` is `//go:build windows`; `webview2_check.go` is `//go:build !bindings`. Both tags are compatible — a production Windows build has neither the `bindings` tag nor is the non-windows fallback active, so both files compile together.

---

### Shared Pattern 3: Keyring target string convention
**Source:** `src/app/auth.go:27-28`

```go
const (
    keyringService = "go-mapi"
    keyringUser    = "oauth-tokens"
)
```

**Windows Credential Manager target shape (verified via zalando/go-keyring source):** `service + ":" + username` → `go-mapi:oauth-tokens` (colon separator).

**Apply to:**
1. NSIS uninstaller (plan 10-04): `ExecWait 'cmdkey /delete:go-mapi:oauth-tokens' $0`.
2. Pester test (plan 10-05): `cmdkey /list:go-mapi:oauth-tokens` + `Select-String -Pattern 'go-mapi:oauth-tokens'`.

**Anti-pattern to block (RESEARCH §Pitfall 3):** CONTEXT.md specifics line 199 writes the target as `go-mapi/oauth-tokens` (slash) — this is **wrong** per RESEARCH §State of the Art. Planner must use the colon form.

---

### Shared Pattern 4: ldflags injection var (no `const`, always `var`)
**Source:** `src/app/auth_credentials.go:9-12` + `src/app/toast.go:53` + `src/app/main.go:15`

```go
var (
    oauthClientID     = ""
    oauthClientSecret = ""
)

var aumidOverride string

var Version = "0.0.0-dev"
```

**Rule:** `-ldflags -X <pkg>.<var>=<value>` overwrites only `var` (not `const`). All three ldflags injection points are `var`; Phase 10 release workflow passes all four:
1. `-X main.Version=<version-from-wails.json>` (Phase 8 pattern)
2. `-X main.aumidOverride=com.marcfargas.gomapi` (Phase 9 WR-01 — **`main.` prefix, NOT `github.com/marcfargas/go-mapi/src/app.`** per RESEARCH §State of the Art correction to CONTEXT D-15)
3. `-X main.oauthClientID=<secret>` (Phase 8 D-08)
4. `-X main.oauthClientSecret=<secret>` (Phase 8 D-09)

**CONTEXT D-15 error to correct:** The context document specifies `-X github.com/marcfargas/go-mapi/src/app.aumidOverride=...`. That package path is wrong — `src/app/toast.go` is `package main`, so the correct form is `-X main.aumidOverride=com.marcfargas.gomapi`. RESEARCH §State of the Art line 1209 explicitly flags this.

**Apply to:** plan 10-06 (release workflow ldflags line) and plan 10-05 (smoke workflow's matching dev-build line, minus Version).

---

### Shared Pattern 5: NSIS silent invocation (Pester + end-user)
**Source:** RESEARCH §Pattern 3 + §Pitfall 5

**Pattern:** `/S` (capital; NSIS silent flag) + `/D=<path>` (LAST argument, NO quoting even for paths with spaces).

```powershell
$proc = Start-Process -FilePath $setup -ArgumentList '/S',"/D=$installDir" -Wait -PassThru
```

**Apply to:** plan 10-05 Pester install + uninstall invocations.

---

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `src/installer/plugins/x86-unicode/ApplicationID.dll` | vendored-binary | n/a | Third-party NSIS plugin — downloaded, not authored. No code analog in this repo. |
| `src/installer/MicrosoftEdgeWebview2Setup.exe` | vendored-binary | n/a | Microsoft redistributable — downloaded, not authored. No code analog in this repo. |

Both are acquired once and committed — see Provenance block above under their individual file entries.

---

## Planner-Facing Correction Log (pre-empts CONTEXT.md errors flagged by research)

The following CONTEXT.md statements are **superseded** by RESEARCH.md §State of the Art — the planner must use the corrected form, not the CONTEXT original:

| CONTEXT.md Location | Original (WRONG) | Corrected |
|---------------------|------------------|-----------|
| D-15 ldflags path | `-X github.com/marcfargas/go-mapi/src/app.aumidOverride=com.marcfargas.gomapi` | `-X main.aumidOverride=com.marcfargas.gomapi` (package is `main`, verified at `src/app/toast.go:53`) |
| D-23 SignPath action version | `SignPath/github-action-submit-signing-request@v1` | `signpath/github-action-submit-signing-request@v2` (v2 is current per docs.signpath.io 2026) |
| Specifics line 199 keyring target | `go-mapi/oauth-tokens` (slash) | `go-mapi:oauth-tokens` (colon — verified against zalando/go-keyring Windows backend) |
| D-26 wails.json version field | assumes `info.productVersion` exists | **field does NOT exist today**; plan 10-06 must ADD `"info": { "productVersion": "3.0.0" }` to `src/app/wails.json` as an explicit task (not a while-I'm-here edit) |

---

## Metadata

**Analog search scope:** `src/app/`, `src/installer/`, `.github/workflows/`, `scripts/`, `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/`
**Files scanned:** 14 new/modified/deleted Phase 10 files mapped; 8 repo analog files read (`credentials_check.go`, `credentials_check_bindings.go`, `credentials_check_test.go`, `auth_credentials.go`, `main.go`, `sessionend.go`, `auth.go`, `toast.go`, `wails.json`, `build.yml`, `register-dev-aumid.ps1`, v2.0 `03-04-PLAN.md`).
**Pattern extraction date:** 2026-04-19
**Research primary source:** `.planning/phases/10-installer-migration/10-RESEARCH.md` §Code Examples 1–14 provides NSIS-native scaffolds for all installer-side primitives (the v2.0 `.iss` analog is no longer on disk, so RESEARCH is the authoritative pattern source for the NSIS script).
