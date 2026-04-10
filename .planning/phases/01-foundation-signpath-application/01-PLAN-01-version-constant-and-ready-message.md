---
phase: 01-foundation-signpath-application
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - src/native-host/version.go
  - src/native-host/main.go
  - src/native-host/protocol.go
  - src/extension/src/types/messages.ts
autonomous: true
requirements: [FOUND-02]

must_haves:
  truths:
    - "A dedicated src/native-host/version.go file declares the package-level Version variable and is the single source of truth for the host version string"
    - "The native-messaging READY message carries the host version in a hostVersion field (additive, non-breaking)"
    - "The existing -ldflags '-X main.Version=...' build path still stamps the version correctly"
    - "The TypeScript NativeReadyMessage interface mirrors the new hostVersion field as an optional string (backwards compatible)"
  artifacts:
    - path: "src/native-host/version.go"
      provides: "Package-level Version variable"
      contains: "var Version"
    - path: "src/native-host/main.go"
      provides: "main entry point without duplicate Version declaration"
      contains: "main("
    - path: "src/native-host/protocol.go"
      provides: "OutgoingMessage with HostVersion field + SendReady wiring"
      contains: "HostVersion"
    - path: "src/extension/src/types/messages.ts"
      provides: "NativeReadyMessage with optional hostVersion"
      contains: "hostVersion?"
  key_links:
    - from: "src/native-host/main.go"
      to: "src/native-host/version.go"
      via: "shared package main, Version symbol"
      pattern: "Version"
    - from: "src/native-host/protocol.go SendReady"
      to: "src/native-host/version.go Version"
      via: "main.go passes Version into SendReady"
      pattern: "SendReady.*Version"
---

<objective>
Centralize the host version string in a dedicated `version.go` file and extend the existing READY native-messaging message with an additive `hostVersion` field, plus its TypeScript mirror. This is pure refactor + one additive protocol field — no behavior change from the extension's current perspective.

Purpose: Unblocks Phase 2 (EXT-03 `hostVersion.ts` module consumes this) and establishes a single source of truth for the host version string that the C++ interceptor, Go host, and TypeScript extension can all agree on.
Output: A `version.go` file, a `HostVersion` field on the outgoing READY message, and an optional `hostVersion?: string` field on the TypeScript `NativeReadyMessage` interface.
</objective>

<execution_context>
This plan implements FOUND-02 from REQUIREMENTS.md. Decisions are locked in `01-CONTEXT.md` section `### FOUND-02 (version constant + READY message)`:
- New file `src/native-host/version.go` with `var Version = "0.0.0-dev"` (mirroring the existing `-ldflags "-X main.Version=..."` build path — main.Version still resolves because both files are in `package main`)
- Remove the duplicate declaration from `main.go`
- Add `HostVersion string \`json:"hostVersion"\`` to the outgoing READY message and plumb it through `SendReady`
- Mirror as optional `hostVersion?: string` in TypeScript (per CONTEXT.md: "optional to stay backwards compatible — Phase 2 relies on it")
- **No protocol version bump** — additive field only
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/phases/01-foundation-signpath-application/01-CONTEXT.md
@src/native-host/main.go
@src/native-host/protocol.go
@src/extension/src/types/messages.ts

<interfaces>
<!-- Current state extracted from source so the executor does not need to re-scavenge -->

From src/native-host/main.go (lines 11-13) — the declaration to MOVE:
```go
// Version is set at build time via -ldflags "-X main.Version=..."
// Falls back to "0.0.0-dev" for development builds
var Version = "0.0.0-dev"
```

From src/native-host/protocol.go (lines 29-39) — current OutgoingMessage struct:
```go
type OutgoingMessage struct {
    Type    string       `json:"type"`
    ID      string       `json:"id,omitempty"`
    Data    *MailMessage `json:"data,omitempty"`
    Error   string       `json:"error,omitempty"`
    Version string       `json:"version,omitempty"`  // legacy top-level version — DO NOT remove, keep for backwards compat

    // Draft creation response
    DraftID  string `json:"draftId,omitempty"`
    GmailURL string `json:"gmailUrl,omitempty"`
}
```

From src/native-host/protocol.go (lines 170-176) — current SendReady:
```go
func (nm *NativeMessaging) SendReady(version string) error {
    return nm.Write(&OutgoingMessage{
        Type:    MsgTypeReady,
        Version: version,
    })
}
```

From src/extension/src/types/messages.ts (lines 65-68) — current NativeReadyMessage:
```ts
export interface NativeReadyMessage {
  type: typeof MSG_TYPE.READY;
  version: string;
}
```
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Extract Version into src/native-host/version.go</name>
  <files>src/native-host/version.go, src/native-host/main.go</files>
  <read_first>
    - src/native-host/main.go (confirm current `var Version = "0.0.0-dev"` declaration at lines 11-13)
    - src/native-host/build.ps1 or package.json build scripts if present (verify the ldflags path remains `-X main.Version=...`)
  </read_first>
  <action>
    Create `src/native-host/version.go` with exactly the following content (package main, standard Go header comment explaining the ldflags path):

    ```go
    package main

    // Version is the native host version string.
    // Set at build time via -ldflags "-X main.Version=..." from the root package.json.
    // Falls back to "0.0.0-dev" for local development builds.
    var Version = "0.0.0-dev"
    ```

    Then edit `src/native-host/main.go` to REMOVE the existing `var Version = "0.0.0-dev"` declaration (and its preceding comment lines). Do NOT rename the symbol. Do NOT touch any other part of main.go. The `-X main.Version=...` ldflag continues to work because both files share `package main`.

    Do not introduce a new package. Do not add any helper getters. This is a pure file-move refactor.
  </action>
  <verify>
    <automated>cd src/native-host && go build -ldflags "-X main.Version=2.0.0-test" ./... && go vet ./...</automated>
  </verify>
  <acceptance_criteria>
    - File `src/native-host/version.go` exists and contains exactly one `var Version` declaration in `package main`
    - File `src/native-host/main.go` no longer contains any `var Version` declaration (grep: `grep -n "^var Version" src/native-host/main.go` returns no matches)
    - `go build -ldflags "-X main.Version=2.0.0-test" ./...` from `src/native-host/` succeeds
    - `go vet ./...` from `src/native-host/` reports no errors
    - Existing tests still compile: `go test -run NONE ./...` (compile check) succeeds
  </acceptance_criteria>
  <done>
    Version declaration lives in `version.go`, `main.go` no longer declares it, build with ldflags still stamps the version, `go vet` clean.
  </done>
</task>

<task type="auto" tdd="false">
  <name>Task 2: Add HostVersion field to OutgoingMessage and plumb through SendReady</name>
  <files>src/native-host/protocol.go, src/native-host/main.go</files>
  <read_first>
    - src/native-host/protocol.go (full file — understand OutgoingMessage and SendReady)
    - src/native-host/main.go (find the existing `messaging.SendReady(Version)` call at line 54)
    - src/native-host/protocol_test.go (understand what's tested for OutgoingMessage serialization; do NOT add new tests — GOTEST is a Phase 4 deliverable)
  </read_first>
  <action>
    Add a `HostVersion` field to `OutgoingMessage` in `src/native-host/protocol.go` as an ADDITIVE json field (keep the existing `Version string \`json:"version,omitempty"\`` for backwards compatibility — per CONTEXT.md "No protocol version bump — additive field only"):

    ```go
    type OutgoingMessage struct {
        Type    string       `json:"type"`
        ID      string       `json:"id,omitempty"`
        Data    *MailMessage `json:"data,omitempty"`
        Error   string       `json:"error,omitempty"`
        Version string       `json:"version,omitempty"`      // legacy field — kept for backwards compat, do not remove
        HostVersion string   `json:"hostVersion,omitempty"`  // FOUND-02: new canonical host version field

        // Draft creation response
        DraftID  string `json:"draftId,omitempty"`
        GmailURL string `json:"gmailUrl,omitempty"`
    }
    ```

    Then update `SendReady` in the same file to populate BOTH fields so any existing consumer reading `Version` still works AND Phase 2 can read `HostVersion`:

    ```go
    func (nm *NativeMessaging) SendReady(version string) error {
        return nm.Write(&OutgoingMessage{
            Type:        MsgTypeReady,
            Version:     version,      // legacy field — kept for backwards compat
            HostVersion: version,      // FOUND-02: new canonical field, consumed by Phase 2 EXT-03
        })
    }
    ```

    Do NOT change the `SendReady(version string)` signature. Do NOT touch `main.go` call site — it already passes `Version` correctly.

    Scope discipline: Do NOT add HostVersion to any other outgoing message type (not SendEmail, not SendError, etc.). Only the READY path gets it in this phase.
  </action>
  <verify>
    <automated>cd src/native-host && go build ./... && go vet ./... && go test -run NONE ./...</automated>
  </verify>
  <acceptance_criteria>
    - `src/native-host/protocol.go` contains the exact line `HostVersion string   \`json:"hostVersion,omitempty"\`` (or equivalent gofmt output; grep: `grep -n "hostVersion" src/native-host/protocol.go` returns at least 1 match)
    - The legacy `Version string  \`json:"version,omitempty"\`` field is still present (grep: `grep -n "json:\"version,omitempty\"" src/native-host/protocol.go` returns at least 1 match)
    - `SendReady` populates both `Version:` and `HostVersion:` fields (grep: `grep -A 5 "func (nm \*NativeMessaging) SendReady" src/native-host/protocol.go | grep -c "Version:"` returns at least 2)
    - `go build ./...` succeeds
    - `go vet ./...` reports no errors
    - `go test -run NONE ./...` compile check succeeds (no test changes in this task)
    - JSON serialization test: running the existing protocol_test.go suite (`go test ./...`) continues to pass
  </acceptance_criteria>
  <done>
    OutgoingMessage has HostVersion field, SendReady emits both fields, legacy Version field untouched, existing tests still pass.
  </done>
</task>

<task type="auto" tdd="false">
  <name>Task 3: Mirror hostVersion field in TypeScript NativeReadyMessage</name>
  <files>src/extension/src/types/messages.ts</files>
  <read_first>
    - src/extension/src/types/messages.ts (full file — understand NativeReadyMessage and NativeIncomingMessage union)
    - src/extension/src/background/service-worker.ts (skim for any `version` reads on the ready message — do NOT modify, just confirm nothing breaks)
  </read_first>
  <action>
    Update the `NativeReadyMessage` interface in `src/extension/src/types/messages.ts` to add an optional `hostVersion?: string` field alongside the existing `version: string` field:

    ```ts
    export interface NativeReadyMessage {
      type: typeof MSG_TYPE.READY;
      version: string;             // legacy field — kept for backwards compat
      hostVersion?: string;        // FOUND-02: new canonical host version field, consumed by EXT-03 in Phase 2
    }
    ```

    Do NOT touch `MailMessage.hostVersion` (already exists at line 40, unrelated to this field).
    Do NOT modify any consumer of `NativeReadyMessage` — Phase 2 will wire this into `hostVersion.ts`.
    Do NOT bump the protocol version or any schema version.
    Do NOT add runtime validation.
  </action>
  <verify>
    <automated>cd src/extension && npx tsc --noEmit</automated>
  </verify>
  <acceptance_criteria>
    - `src/extension/src/types/messages.ts` `NativeReadyMessage` interface contains `hostVersion?: string` (grep: `grep -A 3 "interface NativeReadyMessage" src/extension/src/types/messages.ts | grep "hostVersion?"` returns a match)
    - Existing `version: string` field is still present on the interface
    - `npx tsc --noEmit` from `src/extension/` reports zero errors
    - `npm run lint` or equivalent from project root, if configured for the extension, reports no new errors (skip if no such script exists)
  </acceptance_criteria>
  <done>
    TypeScript NativeReadyMessage interface includes optional hostVersion field, strict TypeScript compilation clean, no consumer changes.
  </done>
</task>

</tasks>

<verification>
- Go native host builds cleanly with and without `-ldflags "-X main.Version=..."`
- `go vet ./src/native-host/...` reports no errors
- `go test ./src/native-host/...` passes (existing tests — no new tests added in this plan)
- `npx tsc --noEmit` from `src/extension/` reports zero errors
- Wire protocol is backwards compatible: a v1 extension receiving a READY message with both `version` and `hostVersion` fields continues to work (it ignores the new field)
</verification>

<success_criteria>
- `src/native-host/version.go` exists with exactly one `var Version` declaration
- `src/native-host/main.go` no longer declares `var Version`
- `src/native-host/protocol.go` OutgoingMessage has both `Version` (legacy) and `HostVersion` (new) fields
- `SendReady` populates both fields from its `version` parameter
- `NativeReadyMessage` TypeScript interface has optional `hostVersion?: string`
- All existing Go and TypeScript tests still pass
- No wire-protocol version bump
</success_criteria>

<output>
After completion, create `.planning/phases/01-foundation-signpath-application/01-01-SUMMARY.md` following the standard GSD summary template, documenting:
- Files created / modified
- Exact final state of `var Version`, `OutgoingMessage.HostVersion`, `SendReady`, and `NativeReadyMessage.hostVersion`
- Confirmation that `-ldflags` build path still works
- Any surprises encountered (e.g. if an additional consumer of `OutgoingMessage.Version` was discovered)
</output>
