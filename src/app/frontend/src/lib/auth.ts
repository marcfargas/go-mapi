import { EventsOn } from '../../wailsjs/runtime/runtime';
import { GetAuthStatus, SignIn, SignOut } from '../../wailsjs/go/main/App';
import type { main } from '../../wailsjs/go/models';

export type AuthStatus = main.AuthStatus;

const PREAUTH_SEEN_KEY = 'go-mapi.preauth-seen';

export function hasSeenPreAuthExplainer(): boolean {
  try {
    return localStorage.getItem(PREAUTH_SEEN_KEY) === '1';
  } catch {
    return false;
  }
}

export function markPreAuthExplainerSeen(): void {
  try {
    localStorage.setItem(PREAUTH_SEEN_KEY, '1');
  } catch {
    // ignore — non-fatal
  }
}

/**
 * Fetch the current auth status from Go. Safe to call at any time.
 */
export async function fetchAuthStatus(): Promise<AuthStatus> {
  return await GetAuthStatus();
}

/**
 * Subscribe to auth-changed events emitted by Go (startup, sign-in, sign-out,
 * invalid_grant). Returns an unsubscribe function.
 */
export function subscribeAuth(cb: (status: AuthStatus) => void): () => void {
  return EventsOn('auth-changed', (s: AuthStatus) => cb(s));
}

export async function signIn(): Promise<void> {
  await SignIn();
}

export async function signOut(): Promise<void> {
  await SignOut();
}
