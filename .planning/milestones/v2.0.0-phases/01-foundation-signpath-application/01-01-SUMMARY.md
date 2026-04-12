---
phase: 01-foundation-signpath-application
plan: 01
subsystem: infra
tags: [go, typescript, native-messaging, protocol, version]

requires:
  - phase: none
    provides: "Pre-existing main.Version and READY native-messaging message from v1.0.0"
provides:
  - "Single source of truth for host version in src/native-host/version.go"
  - "Additive hostVersion field on OutgoingMessage / READY wire protocol"
  - "Optional hostVersion?: string on TypeScript NativeReadyMessage interface"
affects: [phase-02-extension-ux, EXT-03]

tech-stack:
  added: []
  patterns:
    - "Package-level Go version constants live in their own version.go file (not main.go)"
    - "Additive, backwards-compatible protocol evolution — new optional field without version bump"

key-files:
  created:
    - src/native-host/version.go
  modified:
    - src/native-host/main.go
    - src/native-host/protocol.go
    - src/extension/src/types/messages.ts

key-decisions:
  - "Kept legacy Version field on OutgoingMessage alongside new HostVersion — no protocol version bump, pure additive change"
  - "SendReady populates both Version and HostVersion from same input so v1 extensions keep working while Phase 2 EXT-03 can consume the new field"
  - "TypeScript mirror uses optional hostVersion?: string to stay backwards compatible with hosts that have not yet been rebuilt"

patterns-established:
  - "version.go file pattern: single package-level var Version with ldflags comment"
  - "Additive protocol field convention: keep legacy field + add new canonical one with clear inline comments"

requirements-completed: [FOUND-02]

# Metrics
duration: 3 min
completed: 2026-04-10
---

# Phase 1 Plan 1: FOUND-02 host version centralization Summary

**Extracted Go host Version into version.go and added additive hostVersion field on the READY native-messaging message with TypeScript mirror — unblocks Phase 2 EXT-03 without a wire protocol bump.**

## Performance

- **Duration:** ~3 min
- **Started:** 2026-04-10T15:33:59Z
- **Completed:** 2026-04-10T15:36:38Z
- **Tasks:** 3
- **Files modified:** 3 (+1 created)

## Accomplishments

- `src/native-host/version.go` is now the single source of truth for the host version string. `main.go` no longer declares `var Version`, and the `-ldflags "-X main.Version=..."` build path from `package.json` continues to stamp the version correctly (verified with `go build -ldflags "-X main.Version=2.0.0-test" ./...`).
- `OutgoingMessage` in `src/native-host/protocol.go` gained a new `HostVersion string \`json:"hostVersion,omitempty"\`` field. `SendReady` now populates both `Version` (legacy) and `HostVersion` (new canonical) from its `version` argument — no protocol version bump, fully backwards compatible.
- `NativeReadyMessage` in `src/extension/src/types/messages.ts` mirrors the new field as `hostVersion?: string`. Existing `version: string` field stays untouched; Phase 2 EXT-03 will wire the new field into a dedicated `hostVersion.ts` module.

## Task Commits

Each task was committed atomically on `develop`:

1. **Task 1: Extract Version into version.go** — `faf7e9d` (refactor)
2. **Task 2: Add HostVersion field + SendReady plumbing** — `0cc453b` (feat)
3. **Task 3: Mirror hostVersion in TypeScript NativeReadyMessage** — `739eb85` (feat)

Plan metadata commit pending.

## Files Created/Modified

- `src/native-host/version.go` **(created)** — Single source of truth for the host version string. Package-level `var Version = "0.0.0-dev"` with comment documenting the `-ldflags "-X main.Version=..."` override path.
- `src/native-host/main.go` **(modified)** — Removed the duplicate `var Version = "0.0.0-dev"` declaration and its preceding comment. No other changes. Both files share `package main`, so the ldflag symbol resolution is unchanged.
- `src/native-host/protocol.go` **(modified)** — Added `HostVersion string \`json:"hostVersion,omitempty"\`` field to `OutgoingMessage`. Updated `SendReady` to populate both `Version` (legacy) and `HostVersion` (canonical). Ran gofmt-aligned struct tag column widening, consistent with existing gofmt output.
- `src/extension/src/types/messages.ts` **(modified)** — Added `hostVersion?: string` optional field to `NativeReadyMessage` alongside the existing `version: string` field.

## Exact Final State of Key Symbols

**`src/native-host/version.go`:**
```go
package main

// Version is the native host version string.
// Set at build time via -ldflags "-X main.Version=..." from the root package.json.
// Falls back to "0.0.0-dev" for local development builds.
var Version = "0.0.0-dev"
```

**`src/native-host/protocol.go` OutgoingMessage struct:**
```go
type OutgoingMessage struct {
    Type        string       `json:"type"`
    ID          string       `json:"id,omitempty"`
    Data        *MailMessage `json:"data,omitempty"`
    Error       string       `json:"error,omitempty"`
    Version     string       `json:"version,omitempty"`     // legacy field — kept for backwards compat, do not remove
    HostVersion string       `json:"hostVersion,omitempty"` // FOUND-02: new canonical host version field

    // Draft creation response
    DraftID  string `json:"draftId,omitempty"`
    GmailURL string `json:"gmailUrl,omitempty"`
}
```

**`src/native-host/protocol.go` SendReady:**
```go
func (nm *NativeMessaging) SendReady(version string) error {
    return nm.Write(&OutgoingMessage{
        Type:        MsgTypeReady,
        Version:     version, // legacy field — kept for backwards compat
        HostVersion: version, // FOUND-02: new canonical field, consumed by Phase 2 EXT-03
    })
}
```

**`src/extension/src/types/messages.ts` NativeReadyMessage:**
```ts
export interface NativeReadyMessage {
  type: typeof MSG_TYPE.READY;
  version: string; // legacy field — kept for backwards compat
  hostVersion?: string; // FOUND-02: new canonical host version field, consumed by EXT-03 in Phase 2
}
```

## Build Verification

- `cd src/native-host && go build ./...` — clean
- `cd src/native-host && go build -ldflags "-X main.Version=2.0.0-test" ./...` — clean (ldflags path confirmed working against the new `version.go`)
- `cd src/native-host && go vet ./...` — no errors
- `cd src/native-host && go test ./...` — all existing tests pass (including `TestNativeMessaging_Write_ReadyMessage` which still asserts `msg.Version == "1.0.0"`; the new `HostVersion` is additive and does not break the assertion)
- `cd src/extension && npx tsc --noEmit` — zero errors

## Decisions Made

- **Kept legacy Version field alongside new HostVersion:** Per CONTEXT.md `FOUND-02` decision "No protocol version bump — additive field only". Any v1 extension reading `version` keeps working; Phase 2 EXT-03 reads the new canonical `hostVersion` field.
- **SendReady populates both fields from the same parameter:** Avoids API signature churn and keeps the call site in `main.go` untouched (`messaging.SendReady(Version)` still works).
- **TypeScript field is optional (`hostVersion?: string`):** Strictly backwards compatible — older hosts that have not been rebuilt will not send this field, and the extension must tolerate its absence until Phase 2 rewires consumers.

## Deviations from Plan

None — plan executed exactly as written. Every acceptance criterion was verified before moving to the next task, and all three tasks landed with the exact file contents specified in the plan (modulo gofmt column alignment on the struct tags, which is the standard Go formatting output).

## Issues Encountered

None.

Note: service-worker.ts line 107 currently reads `hostVersion = message.version;` (reading the legacy `version` field). This is intentional and out of scope — Phase 2 EXT-03 will migrate the consumer to the new `hostVersion` field. No change needed in this plan (scope discipline).

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- **Ready for Plan 01-02** (next FOUND-* plan in Phase 1).
- Phase 2 EXT-03 (`hostVersion.ts` module) is unblocked: the wire field exists from day one, and the TypeScript type already mirrors it as optional so consumers can be migrated incrementally.
- No blockers or concerns.

## Self-Check: PASSED

- `src/native-host/version.go` exists on disk (checked after creation)
- `src/native-host/main.go` no longer contains `^var Version` (grep empty)
- `src/native-host/protocol.go` contains both `hostVersion` (2 matches: OutgoingMessage + MailMessage) and `json:"version,omitempty"` (legacy field preserved)
- TypeScript `NativeReadyMessage` contains `hostVersion?: string`
- Commits exist in `git log --oneline`: `faf7e9d`, `0cc453b`, `739eb85`
- All verification commands pass: `go build -ldflags`, `go vet`, `go test`, `npx tsc --noEmit`

---
*Phase: 01-foundation-signpath-application*
*Completed: 2026-04-10*
