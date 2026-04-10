---
phase: 02-extension-install-ux
plan: 03
status: complete
completed: 2026-04-10
---

# Plan 02-03 Summary: InstallPrompt component + App.tsx wiring

## What shipped

A new React Bootstrap component and an App.tsx update that conditionally
renders it based on the broadcast `hostState`. Users who open the popup
without the native host installed now see a clear install banner with a
download button and SmartScreen guidance — no manual reload required for
the host-installed path (that's plan 02-04's toast logic).

## Files changed

| File | Change |
|---|---|
| `src/extension/src/popup/InstallPrompt.tsx` | NEW — React Bootstrap Card with heading, explanation, download button, SmartScreen Alert; supports MISSING/ERROR/OUTDATED variants |
| `src/extension/src/popup/App.tsx` | HOST_STATE subscription, `hostState` + `hostErrorMessage` React state, `showInstallPrompt` gate, InstallPrompt render |

## InstallPrompt highlights

- **Placeholder URL constant** at the top of the file:
  ```ts
  // EXT-07: swap in Phase 3 when the real installer URL is published to GitHub Releases.
  const INSTALLER_DOWNLOAD_URL =
    'https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe';
  ```
- **React Bootstrap only** — Card, Button, Alert. No new CSS rules added
  to `styles.css`.
- **English copy** per the external-project i18n rule.
- **SmartScreen guidance** in an Alert variant="warning": "Windows
  SmartScreen: you may see a 'Windows protected your PC' prompt on the
  downloaded installer. Click More info then Run anyway to continue."
- **Three variants** — MISSING (install from scratch), OUTDATED (update
  — dead branch in v2.0.0), ERROR (reinstall / check logs, with the
  verbatim error shown underneath).
- **No GitHub redirect** per D-11 — the button links directly to the
  placeholder `releases/latest/download/go-mapi-setup.exe`.
- **`target="_blank" rel="noopener noreferrer"`** for the download button.

## App.tsx wiring

1. New import: `InstallPrompt` and type `HostState`.
2. `AppState` gained two fields: `hostState: HostState`, `hostErrorMessage: string | null`.
3. New `'HOST_STATE'` case in the `onMessage` switch that updates both fields.
4. A derived boolean `showInstallPrompt` computed from `hostState`:
   ```ts
   const showInstallPrompt =
     !state.loading &&
     (state.hostState === 'MISSING' ||
       state.hostState === 'ERROR' ||
       state.hostState === 'OUTDATED');
   ```
5. The content div's ternary ladder now checks `showInstallPrompt` first
   and renders `<InstallPrompt state={state.hostState} errorMessage={...}/>`
   before falling through to the existing loading/selected/list branches.
6. The Recent Drafts block and the Empty state block are gated on
   `!showInstallPrompt` so they don't appear beneath the install banner.
7. The `state.connected` status dot in the header is preserved — the
   legacy `CONNECTION_STATUS` broadcast still drives it.

## Verification

| Command | Result |
|---|---|
| `cd src/extension && npx tsc --noEmit` | exit 0 |
| `cd src/extension && npm run lint` | exit 0 |
| `cd src/extension && npm run test:run` | 3 files / 43 tests passed |

- `grep -c "INSTALLER_DOWNLOAD_URL" src/extension/src/popup/InstallPrompt.tsx` → 2 ✓
- `grep -c "EXT-07" src/extension/src/popup/InstallPrompt.tsx` → 1 ✓
- `grep -c "SmartScreen" src/extension/src/popup/InstallPrompt.tsx` → 1 ✓
- `grep -c "import InstallPrompt" src/extension/src/popup/App.tsx` → 1 ✓
- `grep -c "hostState: HostState" src/extension/src/popup/App.tsx` → 1 ✓
- `grep -c "'HOST_STATE'" src/extension/src/popup/App.tsx` → 1 ✓
- `grep -c "<InstallPrompt" src/extension/src/popup/App.tsx` → 1 ✓

## Scope discipline audit

- [x] No new CSS rules (no changes to `styles.css`)
- [x] No changes to `EmailList.tsx` or `EmailDetail.tsx`
- [x] No test files added (Phase 4 TSTEST-04)
- [x] No changes under `src/native-host/`
- [x] English-only copy
- [x] Placeholder URL marked with `// EXT-07: swap in Phase 3` comment
- [x] React Bootstrap components only (Card, Button, Alert) — no new imports beyond those already used in the popup
