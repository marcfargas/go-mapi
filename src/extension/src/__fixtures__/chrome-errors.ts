/**
 * Real chrome.runtime.lastError.message strings observed across Chromium
 * versions when the native messaging host is not registered or is denied
 * access for the extension origin.
 *
 * E2E-06: These values are seeded from the Chromium source tree. The first
 * successful E2E run on windows-latest (E2E-03 / E2E-04 in Wave 4) may
 * update these with strings captured verbatim from the running browser
 * if they differ. TSTEST-02 imports this file to exercise the
 * classifyLastError substring matcher against realistic inputs.
 *
 * Source reference (strings):
 *   chrome/browser/extensions/api/messaging/native_message_host_chromeos.cc
 *   extensions/browser/api/messaging/native_process_launcher.cc
 *   //content/public/common/content_switches.cc (command line errors)
 *
 * These strings are used by tests in:
 *   src/extension/src/lib/__tests__/hostDetector.test.ts
 *   src/extension/src/background/__tests__/service-worker.test.ts
 */

/** Chromium string emitted when the native messaging manifest is not registered. */
export const MISSING_HOST_CHROMIUM = 'Specified native messaging host not found.';

/** Chromium string emitted when allowed_origins does not include this extension ID. */
export const ACCESS_FORBIDDEN = 'Access to the specified native messaging host is forbidden.';

/**
 * Generic communication failure — not a known exact Chromium string, but
 * representative of the class of errors that should classify as ERROR
 * rather than MISSING. Kept here so tests have an explicit non-MISSING,
 * non-ACCESS error to assert against.
 */
export const UNKNOWN_HOST_ERROR = 'Error when communicating with the native messaging host.';
