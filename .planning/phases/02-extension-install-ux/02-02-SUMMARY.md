---
phase: 02-extension-install-ux
plan: 02
status: complete
completed: 2026-04-10
---

# Plan 02-02 Summary: service worker HOST_STATE broadcast

## What shipped

Two changes that wire the Phase 2 detector helpers into the live extension:

1. `src/extension/src/types/messages.ts` — the loose `ExtensionMessage`
   interface has been replaced with a discriminated union that includes
   two new internal message shapes: `HostStateMessage` and
   `HostInstalledToastMessage`. None of these are added to the native-
   messaging wire protocol; they travel only between the service worker
   and the popup via `chrome.runtime.sendMessage`.
2. `src/extension/src/background/service-worker.ts` — a new
   `transitionHostState(next, opts)` helper broadcasts `HOST_STATE` on
   every state transition, and the existing connect/disconnect/ready
   handlers now call it in four places.

The legacy `CONNECTION_STATUS` broadcast is preserved so the existing
`state.connected` header indicator in the popup keeps working unchanged.
`protocol.go` and everything under `src/native-host/` is untouched.

## Files modified

| File | Change |
|---|---|
| `src/extension/src/types/messages.ts` | Discriminated `ExtensionMessage` union with two new internal message types |
| `src/extension/src/background/service-worker.ts` | `hostState` + `hostErrorMessage` state, `transitionHostState` helper, classifier wiring in 4 call sites |

## ExtensionMessage final shape

```ts
export type ExtensionMessage =
  | QueueUpdateMessage         // existing
  | DraftsUpdateMessage        // existing
  | ConnectionStatusMessage    // existing (preserved, not deleted)
  | ErrorBroadcastMessage      // existing
  | HostStateMessage           // NEW — EXT-04
  | HostInstalledToastMessage; // NEW — EXT-04 (consumed by plan 02-04)
```

## transitionHostState call sites

| Site | Target state | Rationale |
|---|---|---|
| `connectToNativeHost()` entry | `PROBING` | D-01: transitions UNKNOWN → PROBING when we start a probe |
| `onDisconnect` handler | `MISSING` or `ERROR` (from `classifyLastError`) | D-02: substring match on "Specified native messaging host not found" |
| `connectToNativeHost()` catch block | `ERROR` | D-04: connectNative throw path |
| `handleNativeMessage` READY case | `READY` or `OUTDATED` (from `classifyReadyMessage`) | D-03 + D-16: only transition on actual NativeReadyMessage arrival |

## Legacy `version` fallback preserved

```ts
hostVersion = message.hostVersion || message.version;
```

Per Phase 1 handoff decision #1: v1 extensions read `version`, new code
prefers `hostVersion`. Both fields continue to be sent by the host; the
extension prefers the new canonical field but falls back gracefully.

## Verification

| Command | Result |
|---|---|
| `cd src/extension && npx tsc --noEmit` | exit 0 |
| `cd src/extension && npm run lint` | exit 0 |
| `cd src/extension && npm run test:run` | 3 files / 43 tests passed |

- `grep -c "let hostState: HostState" src/extension/src/background/service-worker.ts` → 1 ✓
- `grep -c "function transitionHostState" src/extension/src/background/service-worker.ts` → 1 ✓
- `grep -c "classifyLastError" src/extension/src/background/service-worker.ts` → 2 ✓ (import + call)
- `grep -c "classifyReadyMessage" src/extension/src/background/service-worker.ts` → 2 ✓ (import + call)
- `grep -c "'HOST_STATE'" src/extension/src/background/service-worker.ts` → 1 ✓
- `grep -c "CONNECTION_STATUS" src/extension/src/background/service-worker.ts` → 4 ✓ (legacy broadcasts preserved)
- `grep -c "message.hostVersion" src/extension/src/background/service-worker.ts` → 1 ✓

## Scope discipline audit

- [x] No changes under `src/native-host/` (`git diff --name-only src/native-host/` empty)
- [x] `protocol.go` untouched — no new wire types
- [x] Legacy `CONNECTION_STATUS` broadcast preserved in all four original sites
- [x] No new alarm added — existing 6-second reconnect alarm reused as-is
- [x] HOST_INSTALLED_TOAST broadcast deferred to plan 02-04
- [x] Strict TS, no `any`
