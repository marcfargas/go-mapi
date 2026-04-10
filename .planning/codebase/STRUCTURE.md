# Codebase Structure

**Analysis Date:** 2026-04-10

## Directory Layout

```
go-mapi/
├── src/
│   ├── interceptor/          # C++ DLL - MAPI interception
│   │   ├── main.cpp          # DLL entry point, MAPI exports
│   │   ├── mapi_impl.cpp     # Core MAPI logic, message conversion
│   │   ├── mapi_impl.h       # MAPI class interface
│   │   ├── mapi_types.h      # MAPI structure definitions
│   │   ├── json_writer.cpp   # JSON serialization
│   │   ├── json_writer.h     # JSON writer interface
│   │   ├── fs_utils.cpp      # File system helpers
│   │   ├── fs_utils.h        # FS utilities interface
│   │   ├── build/            # CMake build output (bin/, CMakeFiles/)
│   │   ├── test-harness/     # Test suite for DLL
│   │   │   ├── src/          # Test cases (ANSI, Unicode, attachments, etc.)
│   │   │   └── CMakeLists.txt
│   │   ├── CMakeLists.txt    # CMake build config
│   │   └── build.ps1         # PowerShell build script
│   │
│   ├── native-host/          # Go - File watcher, native messaging, Gmail API
│   │   ├── main.go           # Entrypoint, logging, message loop
│   │   ├── protocol.go       # Native messaging protocol (4-byte framing + JSON)
│   │   ├── protocol_test.go  # Unit tests for protocol handler
│   │   ├── watcher.go        # File system watcher, email processing
│   │   ├── watcher_test.go   # Watcher tests (debouncing, ID generation)
│   │   ├── gmail.go          # Gmail API client, MIME builder
│   │   ├── protocol_integration_test.go # E2E protocol tests
│   │   ├── manifests/        # Native messaging manifest templates
│   │   └── build/            # Go build output (executable)
│   │
│   └── extension/            # Browser extension (Chrome/Edge)
│       ├── src/
│       │   ├── background/
│       │   │   ├── service-worker.ts       # Background service, connection management
│       │   │   └── __tests__/              # Service worker tests
│       │   │
│       │   ├── popup/
│       │   │   ├── main.tsx                # Extension popup entry point
│       │   │   ├── App.tsx                 # Root popup component, state management
│       │   │   ├── EmailList.tsx           # Email queue list view
│       │   │   ├── EmailDetail.tsx         # Email detail/preview view
│       │   │   └── __tests__/              # Component tests
│       │   │
│       │   ├── lib/
│       │   │   ├── gmail.ts                # Chrome Identity API wrapper
│       │   │   └── __tests__/              # Lib tests
│       │   │
│       │   ├── types/
│       │   │   └── messages.ts             # Shared message protocol types
│       │   │
│       │   ├── components/                 # (Empty, reserved for UI components)
│       │   ├── hooks/                      # (Empty, reserved for custom hooks)
│       │   └── test/
│       │       ├── setup.ts                # Vitest setup, DOM environment
│       │       ├── mocks/
│       │       │   └── chrome.ts           # Mock Chrome API
│       │       └── protocol.integration.test.ts
│       │
│       ├── public/
│       │   ├── manifest.json               # Extension manifest (MV3)
│       │   └── icons/                      # Extension icons (16, 32, 48, 128px)
│       │
│       ├── popup.html                      # Extension popup HTML template
│       ├── dist/                           # Built extension (generated)
│       ├── package.json                    # Extension dependencies (React, Bootstrap, etc.)
│       ├── tsconfig.json                   # TypeScript config
│       ├── vite.config.ts                  # Vite build config
│       └── vitest.config.ts                # Vitest test config
│
├── scripts/
│   ├── install.ps1                   # PowerShell installer (auto-detect, download, register)
│   ├── package-extension.ps1         # Extension packaging script
│   └── uninstall.ps1                 # (Part of install.ps1 with -Uninstall flag)
│
├── tests/
│   └── e2e/
│       └── playwright.config.ts       # End-to-end test configuration
│
├── docs/                              # Documentation (webstore descriptions, etc.)
├── .github/                           # GitHub Actions workflows
├── package.json                       # Root workspace (defines workspaces)
├── tsconfig.json                      # Root TypeScript config
├── eslint.config.mjs                  # ESLint configuration
│
└── .planning/
    └── codebase/                      # GSD analysis documents
        ├── ARCHITECTURE.md
        └── STRUCTURE.md
```

## Directory Purposes

**`src/interceptor/`:**
- Purpose: MAPI interception DLL (C++ / MinGW)
- Contains: MAPI function implementations, JSON serialization, file I/O
- Key files: `mapi_impl.cpp` (core logic), `main.cpp` (exports), `json_writer.cpp` (JSON generation)
- Build output: `src/interceptor/build/bin/go-mapi.dll`

**`src/native-host/`:**
- Purpose: Filesystem watcher and Gmail API bridge (Go)
- Contains: File system monitoring (fsnotify), message protocol handler, Gmail API client
- Key files: `main.go` (entry point), `watcher.go` (file watching), `gmail.go` (draft creation)
- Build output: `src/native-host/build/go-mapi-host.exe`
- Logging: `%TEMP%\go-mapi\native-host.log`

**`src/extension/`:**
- Purpose: Browser extension (React + TypeScript + Vite)
- Contains: Popup UI, background service worker, protocol types, tests
- Key files: `public/manifest.json` (extension manifest), `src/background/service-worker.ts` (connection hub), `src/popup/App.tsx` (UI root)
- Build output: `src/extension/dist/` (Chrome/Edge extension package)

**`src/extension/src/background/`:**
- Purpose: Service worker (persistent background script)
- Contains: Native host connection management, email queue state, notification handling
- Key file: `service-worker.ts` (all logic in one file, ~325 lines)
- Pattern: Global `emails` Map, global `nativePort`, message handlers registered at load time

**`src/extension/src/popup/`:**
- Purpose: User interface components
- Contains: Email list, email detail preview, draft buttons, notifications
- Key files: `App.tsx` (state + listeners), `EmailList.tsx` (list rendering), `EmailDetail.tsx` (preview + actions)
- Pattern: Props-based component architecture; state in App, passed down to children

**`src/extension/src/types/`:**
- Purpose: Shared message protocol definitions
- Contains: TypeScript interfaces for all native messaging message types
- Key file: `messages.ts` (all types, ~156 lines)
- Convention: Mirrors Go struct definitions in `src/native-host/protocol.go`

**`scripts/`:**
- Purpose: Installation and deployment automation
- Key files: `install.ps1` (main installer), `package-extension.ps1` (extension packaging)
- Pattern: PowerShell for Windows compatibility; supports automated deployment via `-Unattended`

## Key File Locations

**Entry Points:**

- `src/interceptor/main.cpp`: DLL entry point — `DllMain()` and MAPI function exports
- `src/native-host/main.go`: Native host entry point — `main()` initializes logging, watcher, message loop
- `src/extension/src/popup/main.tsx`: Extension popup entry point — renders `<App />` into DOM
- `src/extension/src/background/service-worker.ts`: Service worker entry point — initializes at bottom of file

**Configuration:**

- `src/extension/public/manifest.json`: Chrome extension manifest (permissions, APIs, icons, OAuth)
- `src/extension/vite.config.ts`: Vite build config (entry points, output paths)
- `src/extension/vitest.config.ts`: Vitest test config (JSDOM, mocks)
- `package.json`: Root workspace config (npm scripts, build targets)

**Core Logic:**

- `src/interceptor/mapi_impl.cpp`: Message conversion (ANSI/Unicode to JSON)
- `src/native-host/watcher.go`: File system watching, email processing, validation
- `src/native-host/gmail.go`: Gmail API client, MIME message building
- `src/extension/src/background/service-worker.ts`: Connection hub, state management, notification orchestration

**Testing:**

- `src/native-host/*_test.go`: Go unit tests (protocol, watcher, integration)
- `src/extension/src/**/__tests__/`: TypeScript tests (components, protocol)
- `src/interceptor/test-harness/`: C++ test suite for DLL

**Protocol & Types:**

- `src/native-host/protocol.go`: Go message types and native messaging handler
- `src/extension/src/types/messages.ts`: TypeScript message types (mirrors Go)

## Naming Conventions

**Files:**

- Go: snake_case with `_test.go` suffix for tests (e.g., `watcher.go`, `watcher_test.go`)
- TypeScript: PascalCase for components (`.tsx`), camelCase for utilities (`.ts`)
- C++: snake_case for source/headers (e.g., `mapi_impl.cpp`, `mapi_impl.h`)
- Build outputs: lowercase with dashes (e.g., `go-mapi.dll`, `go-mapi-host.exe`)

**Directories:**

- Go packages: Single directory per package, named for purpose (e.g., `native-host`)
- TS feature dirs: PascalCase for features (e.g., `background`, `popup`), lowercase for infra (`lib`, `test`, `types`)
- Tests: `__tests__` or `_test.go` suffix

**Message Types:**

- Constants: UPPER_CASE (e.g., `MsgTypeEmail`, `MSG_TYPE.EMAIL`)
- Structs/Interfaces: PascalCase (e.g., `MailMessage`, `EmailWithId`)
- Fields: camelCase (e.g., `draftId`, `gmailUrl`, `originApp`)

## Where to Add New Code

**New Feature (UI):**
- Primary code: `src/extension/src/popup/` or `src/extension/src/background/`
- Tests: Colocated in `__tests__/` folder
- Types: Add to `src/extension/src/types/messages.ts` if new messaging types needed

**New Component:**
- Implementation: `src/extension/src/components/` (currently empty, reserved for shared UI)
- Test: `src/extension/src/components/__tests__/ComponentName.test.tsx`
- Pattern: Accept state via props from App or service worker

**New Go Service (e.g., database layer):**
- Implementation: `src/native-host/` in separate file (e.g., `database.go`)
- Tests: `database_test.go` in same directory
- Exported functions: Called from `main.go` message loop

**New MAPI Feature (e.g., MAPISendDocuments):**
- Implementation: `src/interceptor/mapi_impl.cpp`
- Conversion logic: Add to `ConvertAnsiMessage()` or `ConvertWideMessage()`
- Tests: `src/interceptor/test-harness/src/test_*.cpp`

**Utilities:**
- Shared helpers: `src/extension/src/lib/` for TS, `src/native-host/` for Go
- File system: `src/interceptor/fs_utils.cpp` for C++
- Pattern: Single responsibility per file

## Special Directories

**`src/extension/dist/`:**
- Purpose: Built extension package (Chrome/Edge)
- Generated: Yes (via `npm run build`)
- Committed: No (in `.gitignore`)
- Contents: Compiled JS (service-worker.js, popup.html + assets), manifest.json, icons

**`src/native-host/manifests/`:**
- Purpose: Native messaging manifest templates (for each browser)
- Generated: No (manual, used by installer)
- Committed: Yes
- Pattern: `com.gomapi.host.json` with path to executable

**`src/interceptor/build/` and `src/native-host/build/`:**
- Purpose: CMake/Go build artifacts
- Generated: Yes (via build scripts)
- Committed: No (in `.gitignore`)
- Cleaned: Via `npm run clean:interceptor` / `npm run clean:native-host`

**`test-results/`:**
- Purpose: Test result artifacts (coverage, reports)
- Generated: Yes (via test runs)
- Committed: No
- Content: JSON coverage, test outputs

**`.planning/codebase/`:**
- Purpose: GSD analysis documents (ARCHITECTURE.md, STRUCTURE.md, etc.)
- Generated: Yes (via agents)
- Committed: Yes (for reference)
- Audience: Other Claude agents and developers

---

*Structure analysis: 2026-04-10*
