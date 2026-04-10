// Host detector state machine helpers (EXT-01, EXT-02).
//
// Pure module: classifies inputs from the service worker's Chrome Native
// Messaging layer into a HostState without touching chrome.* APIs itself.
// The service worker owns the actual hostState variable and the port
// lifecycle; this module owns the classification logic so it can be tested
// in isolation (Phase 4 TSTEST-02).

import { isHostVersionSupported } from './hostVersion';

/**
 * High-level host detector states.
 *
 *   UNKNOWN  — initial state, before the first probe has started
 *   PROBING  — a connectNative call is in flight and no result has arrived
 *   READY    — the host has sent a NativeReadyMessage with a supported version
 *   MISSING  — classified from the "not found" substring in lastError
 *   OUTDATED — dead branch in v2.0.0; will activate in v3.0.0 when
 *              MIN_SUPPORTED_HOST_VERSION is bumped above current
 *   ERROR    — any lastError that doesn't match the MISSING substring
 */
export type HostState =
  | 'UNKNOWN'
  | 'PROBING'
  | 'READY'
  | 'MISSING'
  | 'OUTDATED'
  | 'ERROR';

/**
 * The substring Chrome uses in chrome.runtime.lastError.message when the
 * native messaging manifest is not registered for the extension.
 *
 * We classify on substring match rather than exact equality so future Chrome
 * phrasing tweaks (e.g. surrounding quotes, localized punctuation) still
 * land in MISSING. The verbatim message is logged separately by the caller
 * so a regression can be diagnosed without re-deploying the extension.
 */
export const MISSING_HOST_SUBSTRING = 'Specified native messaging host not found';

/**
 * Classify a chrome.runtime.lastError.message string into MISSING or ERROR.
 *
 * Callers are responsible for logging the full verbatim message — this
 * helper only returns the classified HostState bucket.
 */
export function classifyLastError(message: string | undefined): 'MISSING' | 'ERROR' {
  if (message === undefined || message === '') return 'ERROR';
  if (message.includes(MISSING_HOST_SUBSTRING)) return 'MISSING';
  return 'ERROR';
}

/**
 * Classify an incoming NativeReadyMessage's hostVersion field into
 * READY or OUTDATED.
 *
 * In v2.0.0 this returns 'OUTDATED' only if the host stamps a version
 * string strictly below MIN_SUPPORTED_HOST_VERSION. Because the minimum
 * is pinned to the current release, OUTDATED is a dead branch in v2.0.0
 * — but the wiring is complete so v3.0.0 can activate it by bumping the
 * constant without any wire-protocol change.
 */
export function classifyReadyMessage(
  hostVersion: string | undefined
): 'READY' | 'OUTDATED' {
  return isHostVersionSupported(hostVersion) ? 'READY' : 'OUTDATED';
}

/**
 * Snapshot of the detector's current state, suitable for broadcasting to
 * the popup. The service worker builds this object when it calls
 * transitionHostState() and the popup consumes it via the HOST_STATE
 * internal extension message.
 */
export interface HostStateSnapshot {
  state: HostState;
  hostVersion?: string;
  /** The full chrome.runtime.lastError.message, verbatim, for debugging. */
  errorMessage?: string;
}
