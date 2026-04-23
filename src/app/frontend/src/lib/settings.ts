/**
 * Phase 9 — settings + automode event subscriptions.
 *
 * Thin typed wrappers over the Go Wails bindings introduced in Plan 04
 * (see src/app/app.go CreateDraftForID/DismissEmail/GetSettings/SaveSettings/
 * GetMode/SetMode/PauseWatching/ResumeWatching/GetPausedState).
 *
 * PRIVACY NOTE (QUAL-03): payloads delivered by subscribeAutoDraftResult /
 * subscribePauseChanged may include email ids. Do NOT log payloads. The Go
 * emitter strips subject/body/recipient before emit; the frontend must
 * preserve that by NEVER console.log'ing the whole payload.
 */

import { EventsOn } from '../../wailsjs/runtime/runtime';
import {
  GetSettings,
  SaveSettings,
  GetMode,
  SetMode,
  PauseWatching,
  ResumeWatching,
  GetPausedState,
  GetUpdateState,
  CheckForUpdatesNow,
} from '../../wailsjs/go/main/App';
import type { main } from '../../wailsjs/go/models';

export type AppSettings = main.AppSettings;
export type Mode = 'manual' | 'auto-draft';
export type ErrorCategory = 'signed-out' | 'network' | 'gmail';

export interface AutoDraftResult {
  emailId: string;
  success: boolean;
  errorCategory?: ErrorCategory;
  /**
   * QUICK-260423-tk6 — raw Go error text populated on failure (optional;
   * absent on success). Surfaced in the UI so users can distinguish
   * "attachment not found" from a Gmail 5xx without reading app.log.
   */
  reason?: string;
}

/**
 * Phase 11-03 — notify-only update state model shared with Go (`main.UpdateState`).
 *
 * Mirrors the generated `main.UpdateState` shape so the frontend never reaches
 * for `any` when reading update metadata. The Go side is the single source of
 * truth; this type exists to keep imports at one stable path without leaking
 * the auto-generated namespace into every component.
 */
export type UpdateState = main.UpdateState;

/** Read persisted settings from Go (settings.json in %APPDATA%\go-mapi\). */
export async function fetchSettings(): Promise<AppSettings> {
  return await GetSettings();
}

/** Persist settings. Single-writer invariant: call only from UI handlers. */
export async function saveSettings(s: AppSettings): Promise<void> {
  await SaveSettings(s);
}

/** Convenience: read current mode. Plan 09's App.svelte uses this on mount. */
export async function getMode(): Promise<Mode> {
  const m = await GetMode();
  return (m === 'auto-draft' ? 'auto-draft' : 'manual');
}

/** Convenience: set mode + persist. Wakes automode goroutine on switch to auto-draft. */
export async function setMode(mode: Mode): Promise<void> {
  await SetMode(mode);
}

/** Pause notifications + automode drain (session-only; not persisted — D-15). */
export async function pauseWatching(): Promise<void> {
  await PauseWatching();
}

/** Resume notifications + automode drain. */
export async function resumeWatching(): Promise<void> {
  await ResumeWatching();
}

/** Read current session pause state. */
export async function getPausedState(): Promise<boolean> {
  return await GetPausedState();
}

/**
 * Subscribe to `auto-draft-result` events from Go. Fires for both manual
 * (CreateDraftForID) and automode draft outcomes. Returns unsubscribe fn.
 */
export function subscribeAutoDraftResult(
  cb: (r: AutoDraftResult) => void,
): () => void {
  return EventsOn('auto-draft-result', (r: AutoDraftResult) => cb(r));
}

/**
 * Subscribe to `pause-changed` events from Go. Fires when PauseWatching/
 * ResumeWatching runs OR the tray Pause menu flips state. Returns unsubscribe fn.
 */
export function subscribePauseChanged(
  cb: (paused: boolean) => void,
): () => void {
  return EventsOn('pause-changed', (paused: boolean) => cb(paused));
}

// ---------------------------------------------------------------------------
// Phase 11-03 — notify-only update-state wrappers (D-01, D-02, D-06, D-08).
//
// Design:
//   - Frontend stays a thin consumer of the App-owned update state (plan 11-01).
//   - Hydrate via fetchUpdateState() inside the existing Promise.all startup
//     pattern in App.svelte — no second source of truth.
//   - checkForUpdatesNow() wraps the Wails binding so callers never need to
//     construct a context.Context (Wails auto-injects it at runtime).
//   - Silent-failure rule (D-04): the backend already logs and preserves the
//     prior cached state on network failure. The wrapper therefore swallows
//     any promise rejection so UI handlers do not accidentally surface a
//     user-visible error for a transient GitHub outage.
// ---------------------------------------------------------------------------

/** Fetch the current cached update state from Go (safe for Promise.all hydration). */
export async function fetchUpdateState(): Promise<UpdateState> {
  return await GetUpdateState();
}

/**
 * Manual "Check for updates now" (D-06). Bypasses the 24h cadence gate on the
 * Go side and fires a fresh `update-state-changed` event on success.
 *
 * Silent-failure (D-04): the backend already logs; this wrapper swallows
 * the rejection so the UI never shows a user-facing error banner for a
 * transient network failure. The caller can observe the effect via the
 * `update-state-changed` subscription or a follow-up fetchUpdateState().
 */
export async function checkForUpdatesNow(): Promise<void> {
  try {
    // Wails auto-injects context.Context as the first argument at runtime;
    // we intentionally pass nothing so the TS-typed binding is invoked the
    // same way Wails calls it from the generated js runtime shim.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (CheckForUpdatesNow as unknown as (...args: any[]) => Promise<void>)();
  } catch {
    // D-04: transient failures stay silent to the user.
  }
}

/**
 * Subscribe to `update-state-changed` events from Go. Fires on every
 * successful check (startup, 24h scheduler, manual) and whenever cached
 * state materially changes. Returns an unsubscribe function.
 */
export function subscribeUpdateState(
  cb: (state: UpdateState) => void,
): () => void {
  return EventsOn('update-state-changed', (state: UpdateState) => cb(state));
}
