# Stack Research — go-mapi v2.0.0 Installer & Test-Suite Milestone

**Domain:** Windows native-host installer UX paired with a browser extension + test completeness for a mixed Go/TypeScript/C++ codebase
**Researched:** 2026-04-10
**Confidence:** HIGH overall (MEDIUM for SignPath eligibility specifics — verify at application time)

## Scope Note

This document recommends **additions** to the existing v1.0.0 stack for the two v2.0.0 goals (installer + test completeness). It does not re-litigate the existing Go 1.21 / C++17 / TypeScript 5.3 / React 18 / Vite 5 / Vitest 2 / Playwright 1.58 stack already documented in `.planning/codebase/STACK.md`. Re-use what already exists; do not introduce Jest, webpack, Mocha, or any parallel tool chain.

---

## Part A — Installer, Signing, Hosting

### A.1 Installer Technology

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| **Inno Setup** | 6.4.x (latest stable, 2026) | Build the single `go-mapi-setup.exe` that copies DLL + host, writes registry, installs native-messaging manifest, and registers uninstall | Free, FOSS-friendly (LGPL-compatible license), Pascal-scripted for the handful of conditional steps we need (detect Chrome/Edge, write both manifests), battle-tested for Windows consumer installers, trivially runnable from a Windows GitHub Actions runner via `iscc.exe`, has first-class `SignTool` directive so the same `.iss` script drives code signing. HKLM registry writes and elevated install are single-line `[Registry]` / `PrivilegesRequired=admin` directives. |

**Confidence:** HIGH — Inno Setup is the de-facto choice for FOSS Windows installers, and its `[Registry]` section maps exactly onto what go-mapi needs (`HKLM\SOFTWARE\Clients\Mail\go-mapi` for MAPI + `HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host` + the Edge equivalent under `HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host`).

**Rationale tied to go-mapi's constraints:**
- LGPL-3.0 project, zero budget → Inno Setup is free with a permissive license, no runtime fees, no per-install cost.
- Solo maintainer → Pascal scripting is imperative and readable; no XML authoring like WiX.
- Needs registry + filesystem + uninstall → all first-class in Inno's declarative sections.
- Needs to ship a pre-built `.exe` from CI → `iscc.exe` runs cleanly on `windows-latest` runners in 30 seconds.
- Must install native-messaging manifest for both Chrome and Edge → single `[Registry]` section can write both paths conditionally.

**Installer script skeleton** (put in `installer/go-mapi.iss`):

```pascal
[Setup]
AppId={{A1B2C3D4-E5F6-4A5B-8C7D-9E0F1A2B3C4D}
AppName=go-mapi
AppVersion={#MyAppVersion}
AppPublisher=Marc Fargas
AppPublisherURL=https://github.com/marcfargas/go-mapi
DefaultDirName={autopf}\go-mapi
DefaultGroupName=go-mapi
PrivilegesRequired=admin
OutputBaseFilename=go-mapi-setup-{#MyAppVersion}
Compression=lzma2/ultra
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
SignTool=signpath
WizardStyle=modern

[Files]
Source: "..\src\interceptor\build\bin\go-mapi.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\native-host\build\go-mapi-host.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "manifests\com.gomapi.host.json"; DestDir: "{app}"; Flags: ignoreversion

[Registry]
; MAPI handler registration
Root: HKLM; Subkey: "SOFTWARE\Clients\Mail\go-mapi"; ValueType: string; ValueName: ""; ValueData: "go-mapi"; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\Clients\Mail\go-mapi"; ValueType: string; ValueName: "DLLPath"; ValueData: "{app}\go-mapi.dll"
; Chrome native-messaging host
Root: HKLM; Subkey: "SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host"; ValueType: string; ValueName: ""; ValueData: "{app}\com.gomapi.host.json"; Flags: uninsdeletekey
; Edge native-messaging host
Root: HKLM; Subkey: "SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host"; ValueType: string; ValueName: ""; ValueData: "{app}\com.gomapi.host.json"; Flags: uninsdeletekey

[UninstallDelete]
Type: filesandordirs; Name: "{%TEMP}\go-mapi"
```

The manifest JSON is rewritten at install time (either via a small Pascal `[Code]` section or by templating `{app}` into the JSON before compilation) so the `path` field points to the installed `go-mapi-host.exe`.

### A.2 Code Signing

| Technology | Cost | Purpose | Why Recommended |
|------------|------|---------|-----------------|
| **SignPath Foundation** (Community program) | $0 for qualifying OSS | Sign the `go-mapi-setup.exe` and the embedded `go-mapi-host.exe` + `go-mapi.dll` | The only realistic free OV code-signing path for a solo LGPL-3.0 project in 2026. Signs with a SignPath Foundation certificate that carries established SmartScreen reputation through the shared Foundation identity. Integrates natively with GitHub Actions via `SignPath/github-action-submit-signing-request`. Each release requires a manual approval click (intentional security gate). |
| **SignPath.io GitHub Action** | Free | CI integration | `SignPath/github-action-submit-signing-request` uploads a GitHub Actions artifact, waits for signing, downloads the signed artifact back. Already production-ready. |

**Confidence:** HIGH on the mechanism, MEDIUM on go-mapi's specific eligibility until the application is submitted.

**SignPath Foundation eligibility checklist for go-mapi** (verify at application):
- [x] OSI-approved license without commercial dual-licensing — LGPL-3.0 qualifies
- [x] No proprietary/closed components — all three tiers are FOSS
- [x] Actively maintained — v1.0.0 just shipped, v2.0.0 in flight
- [x] Already released in the form to be signed — v1.0.0 exists
- [x] Functionality described on download page — Chrome Web Store listing + GitHub README
- [x] Binary artifacts built from source in verifiable way — GitHub Actions workflow with pinned SHA is the standard expectation
- [ ] Not malware/PUP — true, but the MAPI interception + registry writes require a clean explanation in the application

**Application URL:** https://signpath.org/ (the `.org` Foundation site, not `.io`)

**Don't rely on Azure Trusted Signing** for v2.0.0: it's $9.99/month minimum, individual signups are only available to US/Canada, and it's been rebranded to "Artifact Signing" which introduces process uncertainty. Re-evaluate only if SignPath Foundation rejects the application.

**Fallback if SignPath rejects:** ship unsigned with explicit SmartScreen guidance in the installer README and a prominent "More info → Run anyway" screenshot in the extension's install prompt. **Do not self-sign** — self-signed installers fire a worse UAC warning than unsigned ones and train users to ignore warnings.

**GitHub Actions signing step** (after the Inno Setup build):

```yaml
- name: Upload unsigned installer
  uses: actions/upload-artifact@v4
  with:
    name: unsigned-installer
    path: installer/Output/go-mapi-setup-*.exe

- name: Submit signing request
  uses: signpath/github-action-submit-signing-request@v1
  with:
    api-token: ${{ secrets.SIGNPATH_API_TOKEN }}
    organization-id: ${{ vars.SIGNPATH_ORG_ID }}
    project-slug: go-mapi
    signing-policy-slug: release-signing
    github-artifact-id: ${{ steps.upload.outputs.artifact-id }}
    wait-for-completion: true
    output-artifact-directory: installer/signed/
```

### A.3 Installer Hosting / Direct-Download URL

| Technology | Cost | Purpose | Why Recommended |
|------------|------|---------|-----------------|
| **GitHub Releases** with `latest` asset URL | $0 | Host `go-mapi-setup-X.Y.Z.exe` and expose a stable URL | The stable URL `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` (drop the version from the filename OR use a redirector) gives the extension a single unchanging link. GitHub serves via a CDN, is HTTPS-only, has no bandwidth limit for releases, is trusted by malware scanners, and requires zero infra. |

**Confidence:** HIGH.

**Implementation detail:** GitHub's `/releases/latest/download/{asset-name}` only works when the asset name is stable across releases. Two options:

1. **Stable asset name** (recommended): upload the signed installer as `go-mapi-setup.exe` (no version suffix) in addition to the versioned file. The extension links to `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`.

2. **blegal.dev redirector**: publish a short permalink at `https://go-mapi.blegal.dev/download` that 302-redirects to the current GitHub asset. This is nicer branding but adds an infra dependency; defer to v2.1.0 if the installer milestone needs to ship fast.

**Don't use** Cloudflare R2, S3, GCS, Netlify, or Vercel for installer hosting: GitHub Releases already solves the problem for free, with a better reputation signal for SmartScreen (SignPath + GitHub release = lower warning rate than SignPath + random CDN).

### A.4 Auto-Update

**Explicitly out of scope for v2.0.0** per `.planning/PROJECT.md`: "Host self-update (auto-download + replace) — not a priority for v2.0.0; users re-run the installer for updates."

**Do not introduce Velopack or Squirrel.Windows in v2.0.0.** They're excellent tools but solve a problem we've explicitly deferred. Revisit in a later milestone. Note for the future: if auto-update is ever added, Velopack (Rust, actively maintained) is the clear 2026 choice over the unmaintained Squirrel.Windows.

### A.5 "Install from Extension" UX

| Pattern | Implementation | Notes |
|---------|---------------|-------|
| **Disconnect-driven detection** | `chrome.runtime.connectNative('com.gomapi.host')` inside a `try` + listen on `port.onDisconnect` and check `chrome.runtime.lastError.message` for the string `"Specified native messaging host not found"` or `"Native host has exited"` | The only reliable signal Chrome provides. `connectNative` does not throw synchronously; the error surfaces on the first `onDisconnect` fire. |
| **Install banner in popup** | React component that renders when service-worker state is `host-missing`, with a single primary button linking to the GitHub `releases/latest/download` URL | Open the link via `chrome.tabs.create({ url: installerUrl })`, not a direct `<a>`, so it opens in a new tab even from the popup context. |
| **Auto-detect "host appeared"** | Service worker retries `connectNative` on a `chrome.alarms` schedule (existing 6-second backoff already in the codebase). On the first successful `onMessage`, broadcast `HOST_READY` to the popup | Already 80% built — the reconnect loop exists. Just add the "show toast on transition from host-missing → host-ready" state. |
| **Success moment** | A `chrome.notifications.create` toast on host-ready transition (when transition came from "was-missing" state, not a normal restart) + an in-popup green banner | Matches Bitwarden/KeePassXC-Browser patterns where the extension is quiet during normal operation but celebrates the first successful connection. |

**Reference implementations to look at** (no new dependencies — just read the source):
- **KeePassXC-Browser** — https://github.com/keepassxreboot/keepassxc-browser — shows a "KeePassXC not running" banner and re-probes on a timer. Closest match to go-mapi's architecture.
- **Bitwarden browser extension** — https://github.com/bitwarden/clients/tree/main/apps/browser — has a polished "Desktop app not detected → Install Bitwarden Desktop" flow with a direct download link.
- **1Password extension** — closed source but UX-wise: silent when host present, modal install prompt when missing, auto-transitions on host-ready.

**Confidence:** HIGH on the mechanism (native-messaging disconnect detection is documented on `developer.chrome.com`), MEDIUM on the exact error-string matching (Chrome error messages have changed between versions — match on a substring, not equality, and log the full message for diagnosis).

---

## Part B — Test-Suite Completeness

### B.1 Go — Gmail HTTP Client & `buildFullMIME`

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| **Standard library `net/http/httptest`** | Go 1.21 (built in) | Mock the Gmail API endpoint for `GmailClient` tests | Idiomatic, zero dependencies, maps cleanly onto go-mapi's existing "inject an interface" pattern already used by `NativeMessaging`. `httptest.NewServer` gives a real HTTP server on a random port; inject its `URL` into the `GmailClient` base URL via a test-only constructor. |
| **Golden-file testing** (stdlib) | Go 1.21 | Test `buildFullMIME()` output against known-good MIME fixtures | MIME is large, multi-line, and has specific byte-level requirements (CRLF, boundary strings, base64 encoding). Diffing against golden files in `src/native-host/testdata/mime/*.eml` gives readable test failures and is the standard Go idiom (used by `gofmt`, `go vet`, etc.). The `-update` flag pattern lets you regenerate goldens when intentional changes happen. |

**Confidence:** HIGH.

**Don't use** `gomock`, `testify/mock`, `gock`, `httpmock`, or any third-party HTTP-mocking library. go-mapi's testing style (from TESTING.md) is stdlib-only with manual `if` assertions and table-driven tests — adding mocking libraries now would fragment the style. `httptest.Server` + a small interface refactor gets us 100% of the coverage we need.

**Required refactor** to enable Gmail client testing (minimal):

```go
// gmail.go — add an optional base URL for tests
type GmailClient struct {
    httpClient *http.Client
    baseURL    string // default "https://gmail.googleapis.com" in NewGmailClient, overridden in tests
}

// gmail_test.go
func TestGmailClient_CreateDraft_Success(t *testing.T) {
    ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.URL.Path != "/gmail/v1/users/me/drafts" { t.Errorf("unexpected path: %s", r.URL.Path) }
        if r.Header.Get("Authorization") != "Bearer test-token" { t.Errorf("missing/bad auth header") }
        w.WriteHeader(http.StatusOK)
        w.Write([]byte(`{"id":"draft-123","message":{"id":"msg-456"}}`))
    }))
    defer ts.Close()

    client := &GmailClient{httpClient: ts.Client(), baseURL: ts.URL}
    id, err := client.CreateDraft("test-token", testMail)
    // assertions...
}
```

**Golden-file pattern for `buildFullMIME`:**

```go
// gmail_mime_test.go
func TestBuildFullMIME_SimpleEmail(t *testing.T) {
    mail := loadFixture(t, "simple-email.json")
    got, err := buildFullMIME(mail)
    if err != nil { t.Fatalf("buildFullMIME: %v", err) }

    goldenPath := filepath.Join("testdata", "mime", "simple-email.eml.golden")
    if *updateGoldens {
        os.WriteFile(goldenPath, got, 0644)
    }
    want, _ := os.ReadFile(goldenPath)
    if !bytes.Equal(normalizeBoundaries(got), normalizeBoundaries(want)) {
        t.Errorf("MIME mismatch. Got:\n%s\nWant:\n%s", got, want)
    }
}
```

`normalizeBoundaries` replaces the random multipart boundary string with a fixed token so goldens are stable across runs. Add a `-update` flag via `var updateGoldens = flag.Bool("update", false, "update golden files")` and document it in `src/native-host/testdata/README.md`.

### B.2 Go — Race Detection in CI

| Technology | Version | Purpose | Notes |
|------------|---------|---------|-------|
| **`go test -race`** | Go 1.21 | Catch concurrency bugs in the watcher and message loop | Already built into Go. The watcher uses goroutines + an RWMutex; race detection is the only way to catch a missing lock without reading every line of code. |

**Windows gotcha:** `-race` requires CGO on Windows. Go 1.21+ on `windows-latest` runners ships with the MSVC/MinGW `gcc` pre-installed, so `CGO_ENABLED=1 go test -race ./...` just works, but it must be set explicitly because some CI setups force `CGO_ENABLED=0` for smaller release binaries.

**GitHub Actions step:**

```yaml
- name: Test native host with race detector
  working-directory: src/native-host
  shell: pwsh
  env:
    CGO_ENABLED: '1'
  run: go test -race -v ./...
```

**Confidence:** HIGH. This is a well-trodden path for Windows-targeted Go projects.

**Don't** try to run `-race` in a separate Linux job to "save time on Windows runners" — the watcher is Windows-specific (`fsnotify` has different backends per OS) and race conditions can be OS-specific. Run on Windows.

### B.3 TypeScript — Extension Unit Tests

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| **Vitest** | 2.1.0 (already installed) | Test runner for all extension TS code | Already in the project. Zero additions. |
| **`@testing-library/react`** | 14.2.0 (already installed) | Component tests for `App`, `EmailList`, `EmailDetail` | Already in the project. |
| **`vitest-chrome`** | latest (~0.3.x, 2026) | Mock `chrome.*` APIs for service-worker + popup tests | Vitest-native equivalent of `jest-chrome`. Ships with `@types/chrome`-backed mocks for `chrome.runtime`, `chrome.storage`, `chrome.alarms`, `chrome.notifications`, `chrome.identity` — exactly the surface go-mapi uses. Drop-in setup via `vitest.config.ts` `setupFiles`. |

**Confidence:** HIGH on Vitest + Testing Library (already proven in project), MEDIUM on `vitest-chrome` (smaller community than `jest-chrome`, but actively maintained and purpose-built for our scenario).

**Install:**

```bash
npm install -D vitest-chrome
```

**Setup file** (`src/extension/vitest.setup.ts`):

```ts
import { chrome } from 'vitest-chrome';
import { vi, beforeEach } from 'vitest';

// @ts-expect-error - assign mock to global
global.chrome = chrome;

beforeEach(() => {
  chrome.runtime.connectNative.mockClear();
  chrome.storage.session.get.mockClear();
  // ... reset other mocks
});
```

**Mocking the native messaging Port** (critical for service-worker tests):

```ts
import { chrome } from 'vitest-chrome';

it('reconnects when native host disconnects', async () => {
  const mockPort = {
    onMessage: { addListener: vi.fn(), removeListener: vi.fn() },
    onDisconnect: { addListener: vi.fn(), removeListener: vi.fn() },
    postMessage: vi.fn(),
    disconnect: vi.fn(),
    name: 'com.gomapi.host',
  };
  chrome.runtime.connectNative.mockReturnValue(mockPort as any);

  // ... trigger service worker init
  // ... simulate disconnect by calling the listener registered on onDisconnect
  const disconnectListener = mockPort.onDisconnect.addListener.mock.calls[0][0];
  disconnectListener();
  // ... assert reconnect alarm was scheduled
});
```

**Don't use:**
- **`jest-chrome`** — it's mature but Jest-based; we're on Vitest and mixing runners is worse than a slightly smaller mock library.
- **`sinon-chrome`** — older, less TS-friendly, and requires Sinon as a second assertion ecosystem.
- **`webextension-polyfill`** at the test layer — it's a runtime polyfill, not a mock. Useful if we ever add Firefox support, not for unit tests.
- **`@vitest/browser`** for unit tests — it's real-browser testing, slower than JSDOM, and overkill for service-worker logic. Use it only if we need to test shadow-DOM or CSS behaviors (we don't for v2.0.0).

### B.4 C++ — DLL Testing

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| **doctest** | 2.4.11 (latest 2026) | Unit-test `ConvertAnsiMessage`, `ConvertWideMessage`, address normalization, and JSON writing in the DLL | Single-header (just drop `doctest.h` into `src/interceptor/tests/`), fastest compile time of the three candidates, trivial CMake integration, runs cleanly under MinGW. The MAPI interceptor has ~200 lines of testable pure logic (message conversion, JSON emission) — we don't need GoogleTest's full feature set. |

**Confidence:** HIGH.

**Why not the others:**
- **GoogleTest** — powerful but heavy: adds Abseil dependency chain and longer compile times. Overkill for the small testable surface of the DLL. Its MinGW support is "reported working" not "officially supported."
- **Catch2** — also good, but v3 dropped single-header mode (now requires a separate compilation unit), which complicates the MinGW + CMake flow we already have. Pre-v3 single-header mode has slow compile times because the header is huge.
- **doctest** — explicitly designed for "drop into existing project with zero friction," supports MinGW first-class, compiles faster than Catch2, and has compatible macros (`TEST_CASE`, `CHECK`) so the syntax is familiar.

**CMake integration:**

```cmake
# src/interceptor/tests/CMakeLists.txt
include(FetchContent)
FetchContent_Declare(doctest
    GIT_REPOSITORY https://github.com/doctest/doctest.git
    GIT_TAG v2.4.11
)
FetchContent_MakeAvailable(doctest)

add_executable(interceptor_tests
    test_convert_message.cpp
    test_normalize_address.cpp
    ../src/message_converter.cpp  # pure logic extracted from main.cpp
)
target_link_libraries(interceptor_tests PRIVATE doctest::doctest)
target_include_directories(interceptor_tests PRIVATE ../src)

include(doctest)
doctest_discover_tests(interceptor_tests)
```

**Refactor required:** today `MapiImpl::ConvertAnsiMessage` is likely inline in `main.cpp` alongside DLL entry points. Extract the pure conversion logic into `src/interceptor/src/message_converter.{h,cpp}` with no Windows-SDK dependency in the pure-logic functions (pass in already-parsed data structures, not raw `MapiMessage*` pointers). Test the pure logic; leave the DLL-boundary glue untested (it's what the E2E test covers).

**Don't** try to test the DLL by loading it with `LoadLibrary` in tests — that's an integration test, and the E2E Playwright flow already covers the end-to-end path. Unit-test the pure logic; integration-test the glue via E2E.

### B.5 E2E — MAPI → Gmail Happy Path

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| **Playwright** | 1.58.0 (already installed) | Drive the extension popup in a persistent Chromium context | Already in the project, already set up in `tests/e2e/playwright.config.ts`. No alternative needed. |
| **Go `httptest.Server`** (reused from B.1) | Go 1.21 | Fake Gmail API server for E2E | Same pattern as unit tests; start a `httptest.Server` in a small `cmd/fake-gmail` binary launched by the Playwright global setup, inject its URL via a Go-host env var like `GOMAPI_GMAIL_BASE_URL`. |
| **Direct JSON drop** | N/A | Simulate MAPI calls by writing `{uuid}.json` directly into `%TEMP%\go-mapi\` | The realistic, maintainable approach. Triggering a real `MAPISendMail` from a test requires a helper Win32 app that calls `mapi32.dll`, which is a rabbit hole. The watcher doesn't care how files arrive — drop a fixture JSON and the rest of the pipeline runs. |

**Confidence:** HIGH.

**E2E flow outline:**

```ts
// tests/e2e/happy-path.spec.ts
import { test, chromium } from '@playwright/test';
import { startFakeGmail, writeMapiJson } from './helpers';

test('MAPI email becomes Gmail draft', async () => {
  const fakeGmail = await startFakeGmail(); // spawns cmd/fake-gmail, returns { url, assertCalled }
  const hostProcess = await startNativeHostWithEnv({ GOMAPI_GMAIL_BASE_URL: fakeGmail.url });

  const userDataDir = await fs.mkdtemp(path.join(os.tmpdir(), 'gomapi-e2e-'));
  const context = await chromium.launchPersistentContext(userDataDir, {
    headless: false,
    args: [
      `--disable-extensions-except=${extensionPath}`,
      `--load-extension=${extensionPath}`,
    ],
  });

  // Get the extension ID from the service worker URL
  const [serviceWorker] = context.serviceWorkers();
  const extensionId = serviceWorker.url().split('/')[2];

  // Drop a fixture email file → pretends MAPI fired
  await writeMapiJson('fixtures/simple-email.json');

  // Open the popup
  const popup = await context.newPage();
  await popup.goto(`chrome-extension://${extensionId}/popup.html`);

  // Wait for the email to appear in the queue
  await popup.getByText('Test Subject').click();
  await popup.getByRole('button', { name: 'Save as Draft' }).click();

  // Assert the fake Gmail server received a POST to /drafts
  await expect.poll(() => fakeGmail.assertCalled('/gmail/v1/users/me/drafts')).toBe(true);
});
```

**OAuth token in E2E:** mock `chrome.identity.getAuthToken` via an extension-level test shim gated on a `E2E_TEST=1` build flag — do NOT try to drive real Google OAuth in tests.

**Don't:**
- **Don't** try to write a Win32 helper that invokes real `MAPISendMail` in CI. It adds C++ test code and a flaky dependency on `mapi32.dll` being present on the runner.
- **Don't** try to hit real Gmail in E2E. Ever. Test infrastructure should be offline.
- **Don't** use Playwright's `chromium.launch()` (non-persistent) — extensions only load with `launchPersistentContext`.
- **Don't** run E2E in headless mode — Chromium extensions are unsupported in headless. Use `headless: false` and rely on the GitHub Actions `windows-latest` runner's virtual display.

---

## Consolidated Installation

**New dev dependencies (extension):**

```bash
cd src/extension
npm install -D vitest-chrome
```

**New Go test dependencies:** none (stdlib `net/http/httptest` + `testing`).

**New C++ test dependencies:** doctest, fetched via CMake `FetchContent` — no system install.

**New tooling** installed on the Windows GitHub Actions runner:

```yaml
- name: Install Inno Setup
  shell: pwsh
  run: choco install innosetup -y --version=6.4.0
```

`innosetup` is pre-packaged in Chocolatey; the `windows-latest` runner has `choco` built in.

**New repo files:**

```
installer/
  go-mapi.iss                      # Inno Setup script
  manifests/
    com.gomapi.host.json.template  # native-messaging manifest with {app} placeholder
  README.md                        # explains the installer build + signing flow

src/interceptor/
  src/message_converter.h          # extracted pure logic
  src/message_converter.cpp
  tests/
    CMakeLists.txt
    test_convert_message.cpp
    test_normalize_address.cpp

src/native-host/
  gmail_test.go                    # httptest.Server based tests
  gmail_mime_test.go               # golden-file tests
  testdata/
    mime/
      simple-email.eml.golden
      email-with-attachment.eml.golden
      email-with-cc-bcc.eml.golden

src/extension/
  vitest.setup.ts                  # vitest-chrome wiring
  src/background/__tests__/
    service-worker.test.ts         # reconnect, host-missing detection, draft flow
  src/popup/__tests__/
    App.test.tsx
    EmailList.test.tsx
    EmailDetail.test.tsx

tests/e2e/
  happy-path.spec.ts
  helpers/
    fake-gmail.ts                  # spawns cmd/fake-gmail Go binary
    write-mapi-json.ts
  fixtures/
    simple-email.json
```

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Inno Setup 6 | WiX Toolset 5 | Only if an enterprise customer explicitly demands an `.msi` for Group Policy deployment. Not a realistic scenario for go-mapi's solo-FOSS audience. |
| Inno Setup 6 | NSIS | Only if we needed a sub-1 MB installer footprint. Inno Setup is ~400 KB overhead and perfectly acceptable; NSIS scripting is harder to read. |
| Inno Setup 6 | MSIX | Only if we wanted Microsoft Store distribution. MSIX cannot cleanly install a MAPI DLL handler (containerization blocks the HKLM registry surface MAPI needs), so it's a non-starter for this project architecturally, not just politically. |
| SignPath Foundation | Azure Artifact Signing ($9.99/mo basic) | Only if SignPath Foundation rejects the application. Adds a recurring cost and geographic (US/Canada only for individuals) limitations. |
| SignPath Foundation | Self-signed cert + user "accept warning" | Never. Worse UX than unsigned. |
| GitHub Releases hosting | Cloudflare R2 / blegal.dev redirector | Only if GitHub ever rate-limits us (they won't for a solo project) or if we want branded download URLs. Defer to v2.1.0+. |
| `httptest.Server` | gomock / testify mocks | Only if the test needs to verify interaction patterns on a complex multi-method interface. The `GmailClient` has one public method (`CreateDraft`); interaction mocks are overkill. |
| Golden files for MIME | testify snapshot testing | Only if snapshots need to live alongside the source code and be viewable in tooling. Golden files under `testdata/` are Go-idiomatic. |
| doctest | GoogleTest | Only if the DLL grows enough testable C++ logic to justify the heavier framework (fixtures, parameterized tests, death tests). Re-evaluate if interceptor LOC doubles. |
| doctest | Catch2 v3 | Only if we wanted Catch2's matcher library. doctest's assertions are sufficient for the message-conversion logic we're testing. |
| vitest-chrome | jest-chrome + Jest | Never — we're on Vitest. |
| vitest-chrome | Hand-rolled `chrome` globals | Fine for 2-3 tests; painful for 20+. Use the library. |
| Playwright + fake Gmail + direct JSON drop | Real MAPI + real Gmail | Never in CI. Consider a manual smoke-test checklist for release validation. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| **NSIS** | Older scripting model, harder to read, no concrete advantage over Inno Setup for our use case, smaller 2026 maintenance velocity | Inno Setup 6 |
| **WiX Toolset** | XML authoring, steep learning curve, designed for enterprise MSI workflows we don't need | Inno Setup 6 |
| **MSIX** | Containerization blocks HKLM MAPI handler registration; incompatible with go-mapi's core architecture | Inno Setup 6 |
| **Advanced Installer** | Paid (even the "free" tier strips features we'd want), not FOSS-aligned | Inno Setup 6 |
| **Velopack / Squirrel.Windows** | Auto-update is explicitly out of scope for v2.0.0 | Re-run the installer; revisit Velopack in a later milestone |
| **Squirrel.Windows** (even if auto-update were in scope) | Project is in disrepair in 2026 per velopack.io migration docs | Velopack (Rust, active) when the need arises |
| **Azure Trusted Signing / Artifact Signing** ($9.99/mo+) | Recurring cost, geographic restrictions for individuals, over-spec for a solo FOSS project | SignPath Foundation (free for qualifying OSS) |
| **Self-signed code signing** | SmartScreen shows a worse warning than unsigned; trains users to ignore security warnings | SignPath Foundation, or ship unsigned with explicit SmartScreen guidance |
| **EV code-signing certificates** ($300-500/year) | Budget doesn't allow, reputation benefit doesn't outweigh cost for our scale | SignPath Foundation |
| **Cloudflare R2 / S3 / Netlify / Vercel** for installer hosting | GitHub Releases already solves this for free with better SmartScreen reputation | GitHub Releases `latest/download` URL |
| **Jest** (for extension tests) | Project is on Vitest; running two test runners is a maintenance tax | Vitest (already installed) |
| **jest-chrome** | Jest-tied; we're on Vitest | vitest-chrome |
| **sinon-chrome** | Older, adds Sinon as a second assertion ecosystem, TypeScript types are thinner | vitest-chrome |
| **webextension-polyfill** at the test layer | It's a runtime polyfill, not a mock — solves a different problem | vitest-chrome for mocking; webextension-polyfill only if we add Firefox support |
| **Mocha / Chai / Jasmine** for extension | Same argument as Jest | Vitest |
| **gomock / testify/mock / gock / httpmock** | Inconsistent with go-mapi's stdlib-only test style; adds a mocking library to maintain | `httptest.Server` + interface injection |
| **testify** (any part of it) | go-mapi currently uses stdlib-only assertions; adding testify fragments the idiom for marginal benefit | Manual `if err != nil { t.Fatalf(...) }` matching existing style |
| **GoogleTest** | Heavy, longer compile times, MinGW support is "reported working" not first-class | doctest |
| **Catch2 v3** | v3 removed single-header mode, complicates MinGW + CMake flow | doctest |
| **Boost.Test** | Forces a Boost dependency on the interceptor for a tiny test surface | doctest |
| **Cypress** for extension E2E | Historically poor Chrome extension support; Playwright is ahead here | Playwright (already installed) |
| **Selenium / WebdriverIO** for extension E2E | Less maintained for MV3 extension testing; Playwright's persistent-context API is the 2026 standard | Playwright |
| **Real Gmail API in E2E** | Flaky, rate-limited, requires test credentials in CI secrets, violates "no external deps in tests" | `httptest.Server` fake Gmail |
| **Real `MAPISendMail` in E2E** | Requires a C++ test harness + `mapi32.dll` on the runner; adds failure modes for no coverage benefit | Direct JSON drop into `%TEMP%\go-mapi\` |
| **Headless Chromium for extension E2E** | Chromium does not load extensions in headless mode | `headless: false` in `launchPersistentContext` |
| **Running `-race` only on Linux** | Watcher is Windows-specific (fsnotify backend differs); races can be OS-specific | `-race` on `windows-latest` with `CGO_ENABLED=1` |
| **`@vitest/browser`** for extension unit tests | Real-browser mode is slower and overkill for service-worker logic; Vitest + JSDOM + vitest-chrome is faster | JSDOM (Vitest default) |

---

## Stack Patterns by Variant

**If SignPath Foundation rejects go-mapi's application:**
- Ship unsigned for v2.0.0
- Add explicit SmartScreen guidance in the extension's install prompt (screenshot of the "More info → Run anyway" dialog)
- Document in installer README
- Reapply to SignPath after 6 months of use or try Azure Artifact Signing as a paid fallback in v2.1.0

**If `-race` on Windows GitHub Actions is flaky:**
- First check CGO is enabled and the MinGW gcc is on PATH
- If still flaky, split into two jobs: fast tests (no `-race`) block PR merge; `-race` runs nightly on `main` branch and reports to an issue tracker
- Do NOT disable `-race` entirely

**If vitest-chrome proves insufficient for a specific Chrome API:**
- Hand-roll the missing mock in `vitest.setup.ts` (e.g., `global.chrome.somethingMissing = { method: vi.fn() }`)
- Do not switch test runners over a single missing API

**If the Playwright E2E test is flaky on CI:**
- First try `expect.poll` with longer timeouts (file-system watchers are timing-sensitive)
- Then try running the E2E in a `test.describe.serial` block to avoid port/context contention
- Last resort: tag as `@slow` and run nightly instead of on every PR; keep unit + integration tests on every PR

---

## Version Compatibility

| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| Inno Setup 6.4.x | Windows 7+ | go-mapi targets Win 10/11 so this is fine; Inno Setup 6 dropped XP/Vista support already |
| Inno Setup 6 + SignTool | Windows SDK 10.0.22621+ | SignTool ships with the Windows SDK; `windows-latest` runners have it pre-installed |
| doctest 2.4.11 | C++11 and later | go-mapi is C++17, compatible |
| doctest + MinGW | gcc 8+ | MinGW-w64 on `windows-latest` runners is gcc 13+, compatible |
| vitest-chrome | Vitest 1.x/2.x | Compatible with our Vitest 2.1.0 |
| vitest-chrome | `@types/chrome` 0.0.270+ | Transitive dependency; kept in sync by the package |
| Playwright 1.58 | Chromium channel | Extensions require `launchPersistentContext`, not plain `launch` |
| Go 1.21 + `-race` + Windows | CGO_ENABLED=1 | Must set env var explicitly in CI |
| SignPath GitHub Action v1 | `actions/upload-artifact@v4` | v4 is required as of 2025; do not use v3 (deprecated) |

---

## Sources

**Installer:**
- [Inno Setup documentation — SignTool directive](https://jrsoftware.org/ishelp/topic_setup_signtool.htm) — HIGH (official)
- [Inno Setup .issig signatures](https://jrsoftware.org/ishelp/topic_issig.htm) — HIGH (official)
- [Chrome Native Messaging host installation (registry keys)](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) — HIGH (official Chrome docs)
- [Microsoft Edge Native Messaging](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/native-messaging) — HIGH (official Microsoft)
- [WiX vs Inno Setup comparison 2026](https://www.advancedinstaller.com/versus/wix-toolset/wix-toolset-vs-inno-setup-packaging-tool.html) — MEDIUM (vendor blog, used for comparative context only)

**Code Signing:**
- [SignPath Foundation eligibility terms](https://signpath.org/terms.html) — HIGH (official)
- [SignPath Foundation main page](https://signpath.org/) — HIGH (official)
- [SignPath DevSec360 OSS program](https://signpath.io/solutions/open-source-community) — HIGH (official)
- [SignPath GitHub Action: submit-signing-request](https://github.com/SignPath/github-action-submit-signing-request) — HIGH (official repo)
- [SignPath GitHub Actions demo workflow](https://github.com/SignPath/github-actions-demo/blob/main/.github/workflows/build-and-sign.yml) — HIGH (official demo)
- [Azure Artifact Signing (formerly Trusted Signing) pricing](https://azure.microsoft.com/en-us/pricing/details/artifact-signing/) — HIGH (official)
- [Trusted Signing individual developer public preview](https://techcommunity.microsoft.com/blog/microsoft-security-blog/trusted-signing-is-now-open-for-individual-developers-to-sign-up-in-public-previ/4273554) — HIGH (Microsoft blog)

**Installer Hosting:**
- GitHub Releases latest-download URL pattern — HIGH (well-documented GitHub feature, no specific source needed beyond `docs.github.com`)

**Auto-Update (for future reference, not v2.0.0):**
- [Velopack GitHub repo](https://github.com/velopack/velopack) — HIGH (official)
- [Velopack from-Squirrel migration docs](https://docs.velopack.io/migrating/squirrel) — HIGH (official)

**Extension UX — Native Messaging Detection:**
- [Chrome `chrome.runtime` API reference](https://developer.chrome.com/docs/extensions/reference/api/runtime) — HIGH (official)
- [MDN `runtime.connectNative`](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/runtime/connectNative) — HIGH (official)
- KeePassXC-Browser and Bitwarden extension repos — MEDIUM (reference implementations, inspect source directly)

**Go Testing:**
- [Using httptest.Server in Go to mock external APIs](https://medium.com/@ullauri.byron/using-httptest-server-in-go-to-mock-and-test-external-api-calls-68ce444cf934) — MEDIUM (blog, pattern is stdlib-official)
- Go stdlib `net/http/httptest` documentation — HIGH (pkg.go.dev)
- [Using GitHub Actions with Go](https://blog.kowalczyk.info/article/8dd9c2c0413047c589a321b1ccba7129/using-github-actions-with-go.html) — MEDIUM
- [actions/setup-go](https://github.com/actions/setup-go) — HIGH (official)

**TypeScript Extension Testing:**
- [vitest-chrome repo](https://github.com/probil/vitest-chrome) — HIGH (official, maintained)
- [Vitest mocking guide](https://vitest.dev/guide/mocking.html) — HIGH (official)
- [vitest-dev/vitest discussion #3090 — testing Chrome extensions](https://github.com/vitest-dev/vitest/discussions/3090) — MEDIUM (community)

**C++ Testing:**
- [doctest GitHub repo](https://github.com/doctest/doctest) — HIGH (official)
- [Modern CMake GoogleTest guide](https://cliutils.gitlab.io/modern-cmake/chapters/testing/googletest.html) — HIGH (for comparison)
- [C++ test framework comparison](https://yurigeronimus.medium.com/guide-for-choosing-a-test-framework-for-your-c-project-2a7741b53317) — MEDIUM (blog)

**Playwright Extension E2E:**
- [Playwright Chrome extensions guide](https://playwright.dev/docs/chrome-extensions) — HIGH (official)
- [Playwright BrowserType API](https://playwright.dev/docs/api/class-browsertype) — HIGH (official)
- [E2E testing Chrome extensions with Playwright and CDP](https://dev.to/corrupt952/how-i-built-e2e-tests-for-chrome-extensions-using-playwright-and-cdp-11fl) — MEDIUM (community)
- [E2E testing the Web Monetization browser extension](https://interledger.org/developers/blog/e2e-testing-wm-browser-extension/) — MEDIUM (real-world case study)

---

*Stack research for: go-mapi v2.0.0 installer + test-suite milestone*
*Researched: 2026-04-10*
