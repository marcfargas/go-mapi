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
} from '../../wailsjs/go/main/App';
import type { main } from '../../wailsjs/go/models';

export type AppSettings = main.AppSettings;
export type Mode = 'manual' | 'auto-draft';
export type ErrorCategory = 'signed-out' | 'network' | 'gmail';

export interface AutoDraftResult {
  emailId: string;
  success: boolean;
  errorCategory?: ErrorCategory;
}

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
