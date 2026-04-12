# Phase 1: Foundation & SignPath Application - Context

**Gathered:** 2026-04-10
**Status:** Ready for planning
**Mode:** Smart discuss (autonomous)

<domain>
## Phase Boundary

Land the small, mechanical refactors and async paperwork that everything else in v2.0.0 depends on. Scope is FOUND-01 through FOUND-06 (code refactors, all internal, no user-facing behavior) plus SIGN-01 (SignPath Foundation OSS application). Success means every Phase 2/3/4 dependency is in place and the SignPath review clock has started.

Explicit non-goals for this phase:
- No new user-facing behavior (no popup, no installer, no test CI changes beyond what FOUND-01 unlocks)
- No turning `-race` on in CI (that's GOTEST-03 in Phase 4)
- No actually signing binaries (that's Phase 3)
- No waiting for SignPath approval — Phase 1 completes when the application is filed, not accepted

</domain>

<decisions>
## Implementation Decisions

### FOUND-01 (emails map race fix)
- Fix location: `src/native-host/watcher.go` — the `EmailWatcher.emails` map access currently mixes read and write paths without consistent locking
- Scope: Surface the exact race via `go test -race ./...` against existing watcher tests first, then apply the minimal locking fix (extend existing `sync.RWMutex`, no new abstractions)
- Out of scope: Any broader concurrency refactor; do not touch the debounce loop structure beyond what the race fix requires
- Verification: `go test -race ./src/native-host/...` runs clean locally on Windows with CGO enabled

### FOUND-02 (version constant + READY message)
- New file: `src/native-host/version.go` exporting `const Version = "0.0.0-dev"` (build-time overridden via existing `-ldflags "-X main.Version=..."`)
- Refactor: Move the existing `var Version` declaration out of `main.go` into `version.go` to centralize
- READY message: Extend existing `ReadyMessage` struct in `protocol.go` with a `HostVersion string \`json:"hostVersion"\`` field populated from the constant
- TypeScript mirror: Add `hostVersion?: string` to the `ReadyMessage` interface in `src/extension/src/types/messages.ts` (optional to stay backwards compatible — Phase 2 relies on it, but the wire field exists from day one of Phase 1)
- No protocol version bump — additive field only

### FOUND-03 (GmailClient baseURL injection)
- Add `baseURL string` field to `GmailClient` struct in `src/native-host/gmail.go`
- Default: `"https://gmail.googleapis.com"` (keep the existing constant `gmailAPIBase` as the default value assigned in `NewGmailClient`)
- Constructor: Extend `NewGmailClient` to accept an optional base URL override, or add a separate `NewGmailClientWithBase` — pick whichever keeps existing callers unchanged without variadic surprises (Claude's choice during plan)
- All internal HTTP calls use `c.baseURL` instead of the package constant
- No new tests in this phase — GOTEST-01 in Phase 4 consumes the injection point

### FOUND-04 (env var + CLI flag)
- `GOMAPI_WATCH_DIR` environment variable: when set, overrides the default `%TEMP%\go-mapi\` watch directory in `main.go` before constructing the `EmailWatcher`
- `--gmail-api-base` CLI flag: parsed in `main.go`, passed through to `GmailClient` construction via FOUND-03's injection point
- Precedence: CLI flag > env var > default (for both watch dir and gmail base — though env var for gmail base is not required, only watch dir)
- Use Go stdlib `flag` package (already present or add if absent — no third-party flag libraries)
- Log the resolved values at startup via existing `logInfo` so E2E runs can verify from the log

### FOUND-05 (C++ message_converter extraction)
- New files: `src/interceptor/message_converter.h` and `src/interceptor/message_converter.cpp`
- Extract: The functions that convert MAPI `lpMapiMessage` / `lpMapiMessageW` into the internal JSON structure — recipient normalization, ANSI/Wide handling, body content extraction
- Stay in `main.cpp`: DLL entry point, `MAPISendMail`/`MAPISendMailW` exports, file I/O glue, logging
- CMake: Add `message_converter.cpp` to the existing `go-mapi` DLL target; structure `CMakeLists.txt` so a future `BUILD_TESTS=ON` target can link `message_converter.cpp` into a doctest binary without pulling in the DLL entry point
- No tests yet — CPPTEST-01/02/03 in Phase 4 consume this

### FOUND-06 (manifest templates)
- New files: `src/native-host/manifests/com.gomapi.host.chrome.json.tmpl` and `com.gomapi.host.edge.json.tmpl` (and any other existing manifests converted)
- Placeholders: Use `{{HOST_PATH}}` and `{{EXTENSION_ID}}` (Go text/template style — chosen because the installer can render them with simple string replacement too)
- Refactor `scripts/install.ps1` to read the `.tmpl`, substitute placeholders with the resolved absolute host path and the Chrome/Edge extension IDs from `src/extension/public/manifest.json`, and write the resolved JSON to the registry-referenced path
- The Phase 3 Inno Setup installer will consume the same `.tmpl` files via its own template rendering — no duplication between PowerShell and Pascal Script
- Keep the existing resolved-manifest files in place until the refactor lands so installs don't break mid-refactor

### SIGN-01 (SignPath application — draft-only in this phase)
- **Decision**: Claude drafts the application text, Marc files it manually via SignPath's form. Phase 1 completes when (a) draft text exists in the repo and (b) Marc confirms "filed" during verification.
- **Draft location**: `.planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` (out of the repo tree so it doesn't ship in the installer; lives in planning for traceability)
- **Draft contents**: Project name, LGPL-3.0 license, short MAPI-interception behavior explanation (defensive wording — emphasize user consent via registry handler registration, privacy-by-design, no telemetry, FOSS), link to the Chrome Web Store listing if live (placeholder text if not yet published), Marc's GitHub username, link to the public repo
- **Known risk**: The Chrome Web Store listing may not exist when Marc files. Draft includes a clearly marked placeholder — Marc decides whether to file with placeholder or wait for CWS publication. Phase 1 does not block on the listing being live.
- **Out of scope**: Actually creating the CWS listing, paying fees, setting up SignPath org pages, responding to reviewer follow-up questions

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `sync.RWMutex` already present in `EmailWatcher` (watcher.go) — FOUND-01 extends existing locking, doesn't introduce new primitives
- `var Version` already declared in `main.go` with `-ldflags` injection — FOUND-02 moves this into `version.go`, ldflags path unchanged
- `gmailAPIBase` const and `http.Client` already present in `gmail.go` — FOUND-03 wraps the const as a struct field, no new HTTP client
- `flag` package usage already present in `main.go` (check during plan) — FOUND-04 adds two flags
- `logInfo` / `logError` helpers in `main.go` — FOUND-04 uses these to log resolved paths
- MAPI structure parsing already centralized in `main.cpp` near the `MAPISendMail` exports — FOUND-05 is a cut-and-paste into the new files, not a rewrite
- `scripts/install.ps1` already writes native-messaging manifests — FOUND-06 swaps its JSON generation for template rendering

### Established Patterns
- Go: pointer receivers for state-modifying methods, lowercase unexported fields, error wrapping with `fmt.Errorf(..., %w)`, `logInfo`/`logError` for side effects
- C++: DLL exports in `main.cpp`, helper functions grouped by purpose, no class hierarchy
- TypeScript: strict mode, additive protocol changes, optional fields on extension-side type defs
- Build: version injected via `-ldflags`, no runtime version detection
- Tests: co-located `_test.go`, fixtures in `tests/protocol-fixtures/`

### Integration Points
- `src/native-host/main.go` — reads flags, env vars, constructs watcher and Gmail client
- `src/native-host/protocol.go` — READY message struct
- `src/extension/src/types/messages.ts` — mirrored TypeScript protocol types
- `src/interceptor/CMakeLists.txt` — DLL build target, gains `message_converter.cpp` source and optional test target hook
- `scripts/install.ps1` — gains template rendering logic using the new `.tmpl` files

</code_context>

<specifics>
## Specific Ideas

- **SignPath wording tone**: Defensive and factual. Emphasize (a) MAPI handler is registered with explicit user consent via the installer's UAC prompt, (b) no telemetry or persistence, (c) LGPL-3.0 public source, (d) Gmail-only draft creation — no SMTP send. SignPath reviewers have historically pushed back on anything that sounds like "interception" in a security-sensitive context; frame as "standard MAPI handler replacement that any Mail client registration does."
- **FOUND-01 race investigation**: Before planning the fix, run `go test -race ./src/native-host/...` and capture the exact race report in the plan file. Match the fix surgically to the race locations — do not sprinkle extra locks.
- **FOUND-04 precedence**: Document the CLI > env > default order in the flag help text so E2E test authors in Phase 4 don't need to read source.
- **FOUND-06 template choice**: Go's `text/template` would be cleaner but adds a build-time dependency for nothing; PowerShell string replacement + Inno Setup `StringChange` both handle `{{PLACEHOLDER}}` trivially. Pick the simpler path.

</specifics>

<deferred>
## Deferred Ideas

- Actually signing binaries — Phase 3 (SIGN-02)
- Any CI changes around `-race` — Phase 4 (GOTEST-03)
- Creating the Chrome Web Store listing — out of roadmap scope; separate effort
- Responding to SignPath reviewer follow-ups — ongoing, not Phase 1 scope
- Any new telemetry or update channels — explicitly anti-feature per PROJECT.md

</deferred>
