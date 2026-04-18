// Unit tests for src/app/frontend/src/lib/auth.ts
//
// The production auth module is the contract — these tests mock wailsjs
// bindings and assert behaviour documented in auth.ts (localStorage explainer
// flag + Wails IPC pass-through).
import { describe, it, expect, vi, beforeEach } from 'vitest';

// Mock wailsjs auto-generated modules BEFORE importing auth.ts — Vitest hoists
// vi.mock calls to the top of the file.
vi.mock('../../wailsjs/go/main/App', () => ({
  GetAuthStatus: vi.fn(),
  SignIn: vi.fn(),
  SignOut: vi.fn(),
}));
vi.mock('../../wailsjs/runtime/runtime', () => ({
  EventsOn: vi.fn(() => () => {}),
}));

import {
  fetchAuthStatus,
  signIn,
  signOut,
  subscribeAuth,
  hasSeenPreAuthExplainer,
  markPreAuthExplainerSeen,
} from './auth';
import { GetAuthStatus, SignIn, SignOut } from '../../wailsjs/go/main/App';
import { EventsOn } from '../../wailsjs/runtime/runtime';

describe('auth module — localStorage pre-auth explainer flag', () => {
  beforeEach(() => {
    // setup.ts already clears localStorage; explicit here for intent.
    localStorage.clear();
  });

  it('hasSeenPreAuthExplainer returns false on a fresh localStorage', () => {
    expect(hasSeenPreAuthExplainer()).toBe(false);
  });

  it('markPreAuthExplainerSeen persists and hasSeen reads it back as true', () => {
    markPreAuthExplainerSeen();
    expect(hasSeenPreAuthExplainer()).toBe(true);
  });
});

describe('auth module — Wails IPC bindings', () => {
  it('fetchAuthStatus resolves with the payload returned by GetAuthStatus', async () => {
    const payload = { authenticated: true, email: 'x@y.com', name: 'X' };
    (GetAuthStatus as unknown as ReturnType<typeof vi.fn>).mockResolvedValue(payload);
    await expect(fetchAuthStatus()).resolves.toEqual(payload);
    expect(GetAuthStatus).toHaveBeenCalledOnce();
  });

  it('fetchAuthStatus rejects when GetAuthStatus rejects', async () => {
    const err = new Error('ipc fail');
    (GetAuthStatus as unknown as ReturnType<typeof vi.fn>).mockRejectedValue(err);
    await expect(fetchAuthStatus()).rejects.toThrow('ipc fail');
  });

  it('signIn calls the SignIn binding', async () => {
    (SignIn as unknown as ReturnType<typeof vi.fn>).mockResolvedValue(undefined);
    await signIn();
    expect(SignIn).toHaveBeenCalledOnce();
  });

  it('signOut calls the SignOut binding', async () => {
    (SignOut as unknown as ReturnType<typeof vi.fn>).mockResolvedValue(undefined);
    await signOut();
    expect(SignOut).toHaveBeenCalledOnce();
  });

  it('subscribeAuth wires EventsOn("auth-changed", handler) and returns the unsubscribe fn', () => {
    const unsub = vi.fn();
    (EventsOn as unknown as ReturnType<typeof vi.fn>).mockReturnValue(unsub);
    const cb = vi.fn();
    const ret = subscribeAuth(cb);
    expect(EventsOn).toHaveBeenCalledWith('auth-changed', expect.any(Function));
    expect(ret).toBe(unsub);
  });

  it('subscribeAuth forwards emitted status to the caller callback', () => {
    let eventHandler: ((s: unknown) => void) | undefined;
    (EventsOn as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (_: string, h: (s: unknown) => void) => {
        eventHandler = h;
        return () => {};
      },
    );
    const cb = vi.fn();
    subscribeAuth(cb);
    eventHandler!({ authenticated: true, email: 'a@b.com' });
    expect(cb).toHaveBeenCalledWith({ authenticated: true, email: 'a@b.com' });
  });
});
