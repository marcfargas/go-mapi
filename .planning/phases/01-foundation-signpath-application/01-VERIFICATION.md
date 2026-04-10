---
phase: 01
phase_name: Foundation & SignPath Application
status: passed
verified: 2026-04-10
verifier: orchestrator (in-session verification per plan)
---

# Phase 1 Verification: Foundation & SignPath Application

## Goal-backward check

**Phase goal (from ROADMAP.md):** "Land the small, mechanical refactors and async paperwork that everything else in v2.0.0 depends on."

**Was the goal achieved?** Yes. Every FOUND-* requirement is shipped and SIGN-01 has its Claude-side deliverable (draft) shipped with the human-side deliverable (actual filing) explicitly deferred by user decision.

## Requirement-by-requirement check

| Req | Status | Evidence |
|---|---|---|
| FOUND-01 | ✓ Complete | `CGO_ENABLED=1 GOARCH=amd64 go test -race ./src/native-host/...` clean; surgical 3-line fix in `watcher.go` (see 01-02-SUMMARY.md) |
| FOUND-02 | ✓ Complete | `src/native-host/version.go` exists with exported `Version` const; `READY` message carries `HostVersion` field; TypeScript mirror optional field added |
| FOUND-03 | ✓ Complete | `NewGmailClientWithBase(token, baseURL)` added to `gmail.go`; existing `NewGmailClient(token)` signature unchanged |
| FOUND-04 | ✓ Complete | `parseFlags()` added to `main.go`; `GOMAPI_WATCH_DIR` env var + `--watch-dir` flag + `--gmail-api-base` flag wired; `NewGmailClientWithBase` used in `handleCreateDraft` |
| FOUND-05 | ✓ Complete | `src/interceptor/message_converter.{h,cpp}` exists in `go_mapi::message_converter` namespace; CMake `message_converter_obj` OBJECT library consumed by DLL target; DLL builds with `cmake --build` producing 2.8MB `go-mapi.dll` with all 6 MAPI exports preserved |
| FOUND-06 | ✓ Complete | `.tmpl` files present for Chrome and Edge manifests; `install.ps1` renders templates in Local mode; resolved `.json` stubs preserved for backwards compat |
| SIGN-01 | ~ Draft ready, filing deferred | `SIGNPATH-APPLICATION.md` complete (140 lines, 8 sections); user decision to defer filing per 01-08-SUMMARY.md; license alignment tech debt resolved as part of closure |

## Build verification (orchestrator, end of phase)

```bash
cd src/native-host && go build ./... && go vet ./... && go test ./...
# → ok github.com/marcfargas/go-mapi/native-host

cd src/extension && npx tsc --noEmit
# → clean
```

Both ran clean at Phase 1 close.

## C++ DLL verification (captured during Plan 01-05 execution)

```bash
cmake -B build-verify -G "MinGW Makefiles" -DBUILD_TESTS=OFF src/interceptor
cmake --build build-verify --target go-mapi
# → build-verify/bin/go-mapi.dll (2,835,494 bytes)
# → exports: MAPIFreeBuffer, MAPILogon, MAPILogoff, MAPISendDocuments, MAPISendMail, MAPISendMailW
```

## Scope discipline audit

- [x] No `.github/workflows/` changes (GOTEST-03 stays Phase 4)
- [x] No HTTP timeout additions to `gmail.go`
- [x] No watcher debounce refactor beyond the surgical race fix
- [x] No drive-by renames
- [x] No new dependencies
- [x] No wire protocol version bump (`hostVersion` field is additive)

## Must-haves

1. **Race-free watcher** — verified with `-race` detector
2. **Version centralized and broadcast** — verified at build time
3. **GmailClient injectable** — verified via existing tests + new constructor compiles
4. **Watch dir + Gmail base injectable** — verified via parseFlags() integration in main()
5. **C++ conversion logic extractable for tests** — verified via OBJECT library build
6. **Manifest single source of truth** — verified via .tmpl files + install.ps1 renders
7. **SignPath application drafted** — verified via SIGNPATH-APPLICATION.md existence and content review

## Deviations from plan

1. **Plan 01-04 executor crashed mid-execution** with an API 401 error. Orchestrator verified the code edit was complete and correct (build/vet/test clean), committed manually, and wrote the SUMMARY.md on behalf of the executor. No code was lost or corrupted.
2. **Plan 01-08 SignPath filing deferred** by explicit user decision. Draft exists, filing is Marc's to do on his own schedule. Phase 1 closes without filing per the CONTEXT.md clause permitting "deliberate decision to defer filing."
3. **License alignment (LGPL-3.0-or-later)** performed during Plan 01-08 closure — technically scope expansion beyond Phase 1 but explicitly approved by user as part of the SignPath filing checkpoint resolution.

## Phase status

**Phase 1 COMPLETE.** Ready to advance to Phase 2 (Extension Install UX).
