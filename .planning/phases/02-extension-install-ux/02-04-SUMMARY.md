---
phase: 02-extension-install-ux
plan: 04
status: complete
completed: 2026-04-10
---

# Plan 02-04 Summary: MISSING → READY success toast

## What shipped

The final piece of the install UX loop: when a user installs the host
after seeing the InstallPrompt, the popup auto-transitions to the email
queue view AND shows a one-time success toast. No manual reload, no
chrome.notifications popup — the toast is a local React Bootstrap
component rendered inside the popup.

## Files changed

| File | Change |
|---|---|
| `src/extension/src/background/service-worker.ts` | `hasShownInstalledToast` flag, edge detection in `transitionHostState`, `persistInstalledToastFlag` helper, hydrate from session storage in `loadState` |
| `src/extension/src/popup/App.tsx` | `Toast`/`ToastContainer` import, `showInstalledToast` state, `HOST_INSTALLED_TOAST` case, fixed-position ToastContainer in the app root |

## Edge detection code

Inside `transitionHostState`, after the broadcast:

```ts
if (prev === 'MISSING' && next === 'READY' && !hasShownInstalledToast) {
  hasShownInstalledToast = true;
  persistInstalledToastFlag();
  broadcastToPopup({ type: 'HOST_INSTALLED_TOAST' });
}
```

The `prev === 'MISSING'` guard is critical — without it, the first
ever transition (`UNKNOWN → PROBING → READY` on a healthy machine that
never had a missing host) would also fire the toast, which is wrong.

## Reconnect alarm

No new alarm. The existing 6-second reconnect alarm (`RECONNECT_ALARM`,
`delayInMinutes: 0.1`) is reused as-is. On each tick while `nativePort`
is null, `connectToNativeHost()` runs, transitions to `PROBING`,
attempts `chrome.runtime.connectNative`, and classifies the result.
When the manifest finally exists and the host finally emits `READY`,
the `handleNativeMessage` READY case calls `transitionHostState('READY')`
which then fires the one-time toast.

## Persistence

The `hasShownInstalledToast` flag is stored in `chrome.storage.session`
alongside the existing `emails` and `recentDrafts` keys. `loadState()`
hydrates it on service worker startup so the flag survives service
worker sleep/wake. D-18 explicitly accepts "reset on service worker
restart" — session storage is cleared when the browser closes, which
is the intended scoping.

## Toast component

Fixed-position React Bootstrap `ToastContainer` anchored to the top of
the popup with `z-index: 1080` so it floats above the header and error
alert. The `Toast` auto-hides after 5 seconds and can also be manually
dismissed. Body text: "go-mapi host detected — you're all set."

No `chrome.notifications` call. No new CSS rules.

## Verification

| Command | Result |
|---|---|
| `cd src/extension && npx tsc --noEmit` | exit 0 |
| `cd src/extension && npm run lint` | exit 0 |
| `cd src/extension && npm run test:run` | 3 files / 43 tests passed |

- `grep -c "hasShownInstalledToast" src/extension/src/background/service-worker.ts` → 7 ✓
- `grep -c "'HOST_INSTALLED_TOAST'" src/extension/src/background/service-worker.ts` → 1 ✓
- `grep -c "prev === 'MISSING' && next === 'READY'" src/extension/src/background/service-worker.ts` → 1 ✓
- `grep -c "persistInstalledToastFlag" src/extension/src/background/service-worker.ts` → 2 ✓
- `grep -c "chrome.alarms.create(RECONNECT_ALARM" src/extension/src/background/service-worker.ts` → 1 ✓ (alarm still re-armed on disconnect)
- `grep -c "Toast" src/extension/src/popup/App.tsx` → 6 ✓ (import + render)
- `grep -c "'HOST_INSTALLED_TOAST'" src/extension/src/popup/App.tsx` → 1 ✓
- `grep -c "showInstalledToast" src/extension/src/popup/App.tsx` → 5 ✓
- `grep -c "autohide" src/extension/src/popup/App.tsx` → 1 ✓

## Scope discipline audit

- [x] No new alarm created — existing 6-second reconnect alarm reused
- [x] No `chrome.notifications` calls (D-17: "Toast is React Bootstrap, not OS-level")
- [x] No changes under `src/native-host/`
- [x] No new wire-protocol types
- [x] No new CSS rules
- [x] Strict TS, no `any`
- [x] English-only copy
