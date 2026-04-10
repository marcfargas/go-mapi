---
phase: 02-extension-install-ux
plan: 01
status: complete
completed: 2026-04-10
---

# Plan 02-01 Summary: hostVersion + hostDetector libs

## What shipped

Two new pure TypeScript modules under `src/extension/src/lib/`:

- `hostVersion.ts` — minimum-version constant + numeric comparator.
- `hostDetector.ts` — HostState union + classifier helpers.

No Chrome API calls, no side effects. Both modules are consumable by the
service worker (plan 02-02) and the popup (plan 02-03).

## Files created

| File | Purpose |
|---|---|
| `src/extension/src/lib/hostVersion.ts` | `MIN_SUPPORTED_HOST_VERSION`, `compareHostVersion`, `isHostVersionSupported` |
| `src/extension/src/lib/hostDetector.ts` | `HostState`, `MISSING_HOST_SUBSTRING`, `classifyLastError`, `classifyReadyMessage`, `HostStateSnapshot` |

## Key decisions realized

- **MIN_SUPPORTED_HOST_VERSION = '2.0.0'** (literal, not import) — D-06 says
  "pick simpler" and the literal avoids pulling `package.json` into the
  extension bundle. The comment on the constant explicitly notes that
  bumping it in v3.0.0 activates the OUTDATED branch without any
  wire-protocol change.
- **`isHostVersionSupported(undefined)` returns `true`** — a legacy host
  that doesn't stamp `hostVersion` yet must not be classified as outdated.
  This mirrors the Phase 1 decision to keep both `version` (legacy) and
  `hostVersion` (new canonical) fields on the READY message.
- **`classifyLastError(undefined)` returns `'ERROR'`** — an absent error
  should not be mistaken for "host missing"; callers must have captured
  a concrete `lastError.message` before calling the classifier.
- **Substring match**, not equality, on `'Specified native messaging host not found'`
  — per D-02, so future Chrome phrasing tweaks still land in MISSING.
- **OUTDATED ships as dead code** in v2.0.0 — `classifyReadyMessage` never
  returns `'OUTDATED'` while min == current, but the comparator is wired
  and ready.

## Code highlights

### `compareHostVersion` algorithm (hostVersion.ts)

Split on `.`, parse each segment with `Number.parseInt`, compare
major/minor/patch numerically, treat missing segments as 0. No semver
library — plain x.y.z per CONTEXT D-05.

### `classifyLastError` logic (hostDetector.ts)

```ts
if (message === undefined || message === '') return 'ERROR';
if (message.includes(MISSING_HOST_SUBSTRING)) return 'MISSING';
return 'ERROR';
```

Verbatim logging is the caller's responsibility — keeps this module pure
and testable without a console spy.

## Verification

| Command | Result |
|---|---|
| `cd src/extension && npx tsc --noEmit` | exit 0 |
| `cd src/extension && npm run lint` | exit 0 |
| `cd src/extension && npm run test:run` | 3 files / 43 tests passed (existing) |

- `grep -c "MIN_SUPPORTED_HOST_VERSION" src/extension/src/lib/hostVersion.ts` → 3 ✓
- `grep -c "export function compareHostVersion" src/extension/src/lib/hostVersion.ts` → 1 ✓
- `grep -c "'2.0.0'" src/extension/src/lib/hostVersion.ts` → 1 ✓
- `grep -c "export type HostState" src/extension/src/lib/hostDetector.ts` → 1 ✓
- `grep -c "'Specified native messaging host not found'" src/extension/src/lib/hostDetector.ts` → 1 ✓
- `grep -c "chrome\\." src/extension/src/lib/hostDetector.ts` → 0 ✓ (no Chrome API calls)

## Scope discipline audit

- [x] No Chrome API calls in either module
- [x] No changes to `src/native-host/`
- [x] No changes to `src/extension/src/types/messages.ts` (deferred to plan 02-02)
- [x] No test files authored (Phase 4 TSTEST-02)
- [x] No wire-protocol changes
- [x] Strict TS, no `any`, explicit return types
