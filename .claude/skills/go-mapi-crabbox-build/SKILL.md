---
name: go-mapi-crabbox-build
description: Build and package go-mapi (interceptor DLLs + Wails app + NSIS installer) from a bare Windows box, e.g. a crabbox-leased VM.
---

# go-mapi-crabbox-build

Portable build recipe for producing go-mapi's Windows artifacts (interceptor
DLLs, the Wails app, and the NSIS installer) on a bare Windows box with no
preinstalled toolchain. Verified working end-to-end.

For crabbox lease/provider/SKU gotchas on this machine, see your crabbox skill.

## Toolchain (install via scoop)

```powershell
scoop install mingw-mstorsjo-llvm-ucrt   # triple-prefixed clang, x64+x86 (interceptor DLL)
scoop install cmake ninja                # NOT bundled by the mingw pkg — required on a bare box (CI gets them free from the GitHub runner image)
scoop install go                         # satisfies go.mod (Go 1.25+)
scoop install nodejs-lts                 # Node >=20, npm >=9
scoop bucket add extras; scoop install nsis   # makensis (installer packaging)
go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0
```

## Build

1. Interceptor DLLs (x64 + x86):
   ```powershell
   npm run build:interceptor
   ```
   → `src/interceptor/build-x64/bin/go-mapi.dll` (~1.46 MB) + `src/interceptor/build-x86/bin/go-mapi.dll` (~1.46 MB)

2. Wails app:
   ```powershell
   npm ci
   npm run -w @marcfargas/go-mapi-app-frontend build
   cd src/app
   wails build -platform windows/amd64
   ```
   → `src/app/build/bin/go-mapi.exe` (~16.7 MB, PE32+ x64)

## Package (NSIS installer)

```powershell
cd src/installer
makensis /DGOMAPI_VERSION=<version> go-mapi.nsi
```
→ `go-mapi-setup.exe` (~7.1 MB) — the `.nsi` pulls in `go-mapi.exe` + both DLLs
+ the bundled WebView2 bootstrapper.

## OAuth caveat (shippable vs sanity build)

- A LAUNCHABLE/shippable binary needs OAuth creds injected via ldflags —
  provide a `.env.local` at the repo ROOT (`GOMAPI_OAUTH_CLIENT_ID` /
  `GOMAPI_OAUTH_CLIENT_SECRET`) and build via `scripts/build-wails.ps1`, which
  reads `.env.local` and injects
  `-X main.oauthClientID=... -X main.oauthClientSecret=...`.
- Without `.env.local`, a plain `wails build` still COMPILES cleanly (the
  OAuth guard in `credentials_check.go` is a RUNTIME startup guard, not a
  build gate) — the binary just has no OAuth baked in and would fatal only if
  launched. Good enough to prove buildability; not shippable.

## Artifacts summary

`go-mapi-setup.exe` (NSIS installer) · `go-mapi.exe` · `go-mapi-x64.dll` · `go-mapi-x86.dll`
