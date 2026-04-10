# Technology Stack

**Analysis Date:** 2026-04-10

## Languages

**Primary:**
- Go 1.21 - Native messaging host (`src/native-host/`)
- C++ 17 - MAPI interceptor DLL (`src/interceptor/`)
- TypeScript 5.3.3 - Browser extension UI and logic (`src/extension/`)

**Secondary:**
- PowerShell - Installation and build scripts (`scripts/install.ps1`, `src/interceptor/build.ps1`)

## Runtime

**Environment:**
- Windows 10/11 (MAPI is Windows-only)
- Go runtime for native host
- Chrome/Chromium (and Edge) browser runtime for extension

**Package Managers:**
- npm 9+ (Node 18+) - JavaScript/TypeScript dependencies
- go modules - Go dependencies

## Frameworks

**Core:**
- React 18.2.0 - Extension popup UI (`src/extension/src/popup/`)
- React Bootstrap 2.10.0 - UI components
- Bootstrap 5.3.2 - CSS framework

**Build/Dev:**
- Vite 5.0.12 - TypeScript/React bundling for extension
- TypeScript 5.3.3 - Type safety and transpilation
- cmake 3.16+ - C++ build configuration for interceptor
- MinGW (gcc/g++ toolchain) - C++ compilation to DLL

**Testing:**
- Vitest 2.1.0 - Unit tests for extension (`src/extension/src/**/__tests__/`)
- Go test - Native host testing (`src/native-host/*_test.go`)
- @testing-library/react 14.2.0 - React component testing
- Playwright 1.58.0 - E2E browser testing (`tests/e2e/`)

**Linting/Formatting:**
- ESLint 9.0.0 with @eslint/js and typescript-eslint - TypeScript/extension linting
- Go vet - Native host linting

## Key Dependencies

**Critical:**
- github.com/fsnotify/fsnotify v1.7.0 - File system watching for email JSON files in native host
- golang.org/x/sys v0.4.0 - Windows system calls for native host

**Infrastructure:**
- react (18.2.0) - Extension UI framework
- react-dom (18.2.0) - React DOM rendering for popup
- vite (5.0.12) - Extension bundle creation
- typescript (5.3.3) - Type checking for extension code

**Testing Infrastructure:**
- @testing-library/jest-dom (6.4.0) - DOM matchers for tests
- jsdom (24.0.0) - DOM simulation for Node.js tests
- vitest (2.1.0) - Test runner and assertion library
- @vitest/coverage-v8 (2.1.0) - Code coverage reporting

**Build Tools:**
- sharp (0.34.5) - Image processing (extension icon handling)

## Configuration

**Environment:**
- No explicit .env configuration required for core functionality
- OAuth credentials are baked into extension manifest: `src/extension/public/manifest.json` contains GCP OAuth client ID
- Installation sets Windows Registry keys: `HKLM:\SOFTWARE\Clients\Mail\go-mapi` for MAPI handler registration
- Native messaging manifest: `src/native-host/manifests/` (generated during install for both Chrome and Edge)

**Build:**
- TypeScript config: `src/extension/tsconfig.json` - strict mode, modern target
- Vite config: `src/extension/vite.config.ts` - extension-specific bundling (no code splitting)
- CMake config: `src/interceptor/CMakeLists.txt` - DLL build with MinGW
- ESLint config: `eslint.config.mjs` - flat config format, extends recommended rules
- Playwright config: `tests/e2e/playwright.config.ts` - browser testing configuration

## Platform Requirements

**Development:**
- Windows 10/11
- Node 18+
- Go 1.21+
- MinGW with gcc/g++ toolchain (for C++ compilation)
- CMake 3.16+
- Ninja or Make (for cmake)
- Chrome or Edge for testing
- Admin PowerShell access for installing registry entries

**Production:**
- Windows 10/11
- Chrome or Edge browser (requires extension installation)
- Gmail or Google Workspace account (with OAuth access)
- Admin privileges for initial installation (DLL + registry)

## Build Pipeline

**Full Build:**
```bash
npm run build              # Builds all three components
```

**Components (parallel execution):**
- `npm run build:interceptor` → MinGW + CMake → `src/interceptor/build/bin/go-mapi.dll`
- `npm run build:native-host` → Go build → `src/native-host/build/go-mapi-host.exe`
- `npm run build:extension` → Vite + TypeScript → `src/extension/dist/`

**Version Injection:**
- Build scripts read version from root `package.json` and pass via `-ldflags` to Go and CMake
- Version embedded in binaries at build time (no runtime version detection)

## Compilation Targets

**Interceptor (DLL):**
- Output: 32-bit and 64-bit Windows DLL (`go-mapi.dll`)
- Compiled from C++17 sources with MinGW
- Links: kernel32, user32 system libraries
- Release builds: `-O2` optimization, stripped symbols

**Native Host (Executable):**
- Output: `go-mapi-host.exe` (Windows binary)
- Go 1.21 compilation with ldflags for version embedding
- Release builds: `-s -w` strip symbols and debug info (smaller binary)
- Debug builds: keep symbols for debugging

**Extension:**
- Output: Chrome extension bundle in `src/extension/dist/`
- Built with Vite (single-pass bundling)
- Manifest v3 compatible
- Service worker (background script) + popup HTML/CSS/JS

---

*Stack analysis: 2026-04-10*
