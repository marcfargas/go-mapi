import { describe, it, expect, beforeEach, vi } from 'vitest';
import { MISSING_HOST_CHROMIUM, UNKNOWN_HOST_ERROR } from '../../__fixtures__/chrome-errors';
import { chromeMock, resetChromeMocks } from '../../test/mocks/chrome';

// TSTEST-05: service-worker HOST_STATE broadcast tests.
//
// Drives the service worker module indirectly through the chrome mock:
//  - vi.resetModules() + dynamic import gives a fresh copy of the module
//    with pristine module-level state (hostState, hasShownInstalledToast).
//  - A custom connectNative factory captures the port listeners so the
//    test can fire onDisconnect and onMessage events on demand.
//  - A custom alarms.onAlarm.addListener captures the alarm callback so
//    the test can simulate the 6-second reconnect tick.
//  - All broadcasts are asserted by inspecting the mock.calls list on
//    chrome.runtime.sendMessage.
//
// The service worker's transitionHostState function is a closure over
// module-level state and cannot be imported directly. Testing it via
// side-effect observation is the deliberate workaround required by the
// Phase 4 no-source-modifications rule.

type Listener<T> = (arg: T) => void;

interface CapturedPort {
  onMessage: { addListener: ReturnType<typeof vi.fn> };
  onDisconnect: { addListener: ReturnType<typeof vi.fn> };
  postMessage: ReturnType<typeof vi.fn>;
  disconnect: ReturnType<typeof vi.fn>;
}

interface Harness {
  latestPort: CapturedPort;
  fireDisconnect: (errorMessage?: string) => void;
  fireReady: (hostVersion?: string) => void;
  fireAlarm: (name: string) => void;
  broadcasts: () => Array<Record<string, unknown>>;
  flushMicrotasks: () => Promise<void>;
}

async function importServiceWorker(): Promise<Harness> {
  // Reset the module registry so the next import re-runs the top-level
  // loadState().then(...) bootstrap with pristine module-level state.
  vi.resetModules();
  resetChromeMocks();

  // Captured listeners — populated by the custom mocks below.
  const portMessageListeners: Array<Listener<unknown>> = [];
  const portDisconnectListeners: Array<Listener<void>> = [];
  const alarmListeners: Array<Listener<{ name: string }>> = [];

  const portFactory = (): CapturedPort => {
    const port: CapturedPort = {
      onMessage: {
        addListener: vi.fn((cb: Listener<unknown>) => {
          portMessageListeners.push(cb);
        }),
      },
      onDisconnect: {
        addListener: vi.fn((cb: Listener<void>) => {
          portDisconnectListeners.push(cb);
        }),
      },
      postMessage: vi.fn(),
      disconnect: vi.fn(),
    };
    return port;
  };

  // Each connectNative call returns a fresh port — track the latest so
  // tests can drive it.
  let latest: CapturedPort = portFactory();
  chromeMock.runtime.connectNative = vi.fn(() => {
    latest = portFactory();
    return latest as unknown as chrome.runtime.Port;
  });

  chromeMock.alarms.onAlarm.addListener = vi.fn((cb: Listener<{ name: string }>) => {
    alarmListeners.push(cb);
  });

  // storage.session.get must resolve with an empty object so loadState
  // does not pre-populate any flags.
  chromeMock.storage.session.get = vi.fn(() => Promise.resolve({}));
  chromeMock.storage.session.set = vi.fn(() => Promise.resolve());

  // Dynamic import triggers the module's top-level init. Await the
  // resulting loadState().then() chain.
  await import('../service-worker');
  await flush();

  return {
    get latestPort() {
      return latest;
    },
    fireDisconnect(errorMessage?: string) {
      chromeMock.runtime.lastError = errorMessage ? { message: errorMessage } : null;
      const listeners = [...portDisconnectListeners];
      // Only the listeners on the CURRENT port should fire. Clear pool so
      // subsequent connects register cleanly.
      portDisconnectListeners.length = 0;
      portMessageListeners.length = 0;
      for (const l of listeners) l(undefined);
      chromeMock.runtime.lastError = null;
    },
    fireReady(hostVersion: string = '2.0.0') {
      for (const l of portMessageListeners) {
        l({ type: 'ready', hostVersion, version: hostVersion });
      }
    },
    fireAlarm(name: string) {
      for (const l of alarmListeners) l({ name });
    },
    broadcasts() {
      return chromeMock.runtime.sendMessage.mock.calls.map(
        (call) => call[0] as Record<string, unknown>,
      );
    },
    flushMicrotasks: flush,
  };
}

function flush(): Promise<void> {
  // Two microtask ticks cover loadState().then(...) → connectToNativeHost
  // → transitionHostState('PROBING') + broadcastToPopup (which itself
  // returns a promise whose .catch is scheduled).
  return Promise.resolve().then(() => Promise.resolve());
}

function hostStateBroadcasts(bs: Array<Record<string, unknown>>) {
  return bs.filter((m) => m.type === 'HOST_STATE');
}

function installedToastBroadcasts(bs: Array<Record<string, unknown>>) {
  return bs.filter((m) => m.type === 'HOST_INSTALLED_TOAST');
}

describe('service-worker HOST_STATE broadcast', () => {
  beforeEach(() => {
    // Ensure every test starts with a clean chrome mock state.
    resetChromeMocks();
  });

  it('broadcasts PROBING on initial connect', async () => {
    const h = await importServiceWorker();
    const states = hostStateBroadcasts(h.broadcasts()).map((m) => m.state);
    expect(states).toContain('PROBING');
  });

  it('broadcasts MISSING when onDisconnect carries the MISSING Chromium string', async () => {
    const h = await importServiceWorker();
    h.fireDisconnect(MISSING_HOST_CHROMIUM);
    await h.flushMicrotasks();

    const missingStates = hostStateBroadcasts(h.broadcasts()).filter(
      (m) => m.state === 'MISSING',
    );
    expect(missingStates.length).toBeGreaterThan(0);
    expect(missingStates[0].errorMessage).toBe(MISSING_HOST_CHROMIUM);
  });

  // PHASE-4-FINDING-01: HOST_INSTALLED_TOAST cannot fire on a real
  // reconnect because connectToNativeHost always transitions the state to
  // PROBING before the new port can receive a READY message. The toast
  // guard in service-worker.ts:108 requires a direct MISSING → READY
  // edge, but the reachable sequence is MISSING → PROBING → READY. The
  // toast therefore NEVER fires in production. Captured in 04-FINDINGS.md
  // as a bug in Phase 2 EXT-06 NOT to be fixed in Phase 4 (per the
  // no-source-modifications scope rule).
  //
  // These tests lock the current (buggy) behavior so any future fix is
  // forced to come with updated tests.
  it('does NOT fire HOST_INSTALLED_TOAST on a standard MISSING → PROBING → READY reconnect (PHASE-4-FINDING-01)', async () => {
    const h = await importServiceWorker();

    // Drive into MISSING.
    h.fireDisconnect(MISSING_HOST_CHROMIUM);
    await h.flushMicrotasks();
    expect(installedToastBroadcasts(h.broadcasts())).toHaveLength(0);

    // Trigger the reconnect alarm — creates a new port and re-runs
    // connectToNativeHost → PROBING.
    h.fireAlarm('reconnect');
    await h.flushMicrotasks();

    // Fire a READY message on the new port.
    h.fireReady('2.0.0');
    await h.flushMicrotasks();

    // READY was broadcast — the happy-path state transition works.
    const readyStates = hostStateBroadcasts(h.broadcasts()).filter(
      (m) => m.state === 'READY',
    );
    expect(readyStates.length).toBeGreaterThan(0);

    // ...but the toast did NOT fire, because the transition was
    // MISSING → PROBING → READY, not the direct MISSING → READY edge the
    // guard requires. When the bug is fixed, this assertion will flip to
    // `.toHaveLength(1)` and this test should be renamed.
    expect(installedToastBroadcasts(h.broadcasts())).toHaveLength(0);
  });

  it('HOST_INSTALLED_TOAST flag stays false across repeat MISSING → READY cycles', async () => {
    // Even though the toast does not fire (PHASE-4-FINDING-01), this
    // test locks the sticky-once-per-session invariant — if the bug is
    // fixed, a second cycle must NOT re-fire. Asserting the count stays
    // at zero here is both the bug-frozen state AND the future
    // upper-bound invariant.
    const h = await importServiceWorker();

    for (let i = 0; i < 2; i++) {
      h.fireDisconnect(MISSING_HOST_CHROMIUM);
      await h.flushMicrotasks();
      h.fireAlarm('reconnect');
      await h.flushMicrotasks();
      h.fireReady('2.0.0');
      await h.flushMicrotasks();
    }

    // Current buggy behavior: zero toasts across both cycles. Once the
    // bug is fixed, this should assert exactly 1 (first cycle fires,
    // second cycle does not re-fire per the hasShownInstalledToast flag).
    expect(installedToastBroadcasts(h.broadcasts())).toHaveLength(0);
  });

  it('broadcasts ERROR (not MISSING) when disconnect carries an unknown message', async () => {
    const h = await importServiceWorker();
    h.fireDisconnect(UNKNOWN_HOST_ERROR);
    await h.flushMicrotasks();

    const lastHostState = hostStateBroadcasts(h.broadcasts()).at(-1);
    expect(lastHostState?.state).toBe('ERROR');
    expect(lastHostState?.errorMessage).toBe(UNKNOWN_HOST_ERROR);
    expect(installedToastBroadcasts(h.broadcasts())).toHaveLength(0);
  });

  it('HOST_STATE payload shape matches the extension message contract', async () => {
    const h = await importServiceWorker();
    h.fireDisconnect(MISSING_HOST_CHROMIUM);
    await h.flushMicrotasks();

    const msg = hostStateBroadcasts(h.broadcasts()).find((m) => m.state === 'MISSING');
    expect(msg).toBeDefined();
    expect(Object.keys(msg as object).sort()).toEqual(
      ['errorMessage', 'hostVersion', 'state', 'type'].sort(),
    );
  });
});
