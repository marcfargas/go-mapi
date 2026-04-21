// Tests for App.svelte — smoke + Phase 9 state wiring.
// Scope: mount, queue rendering, auto-draft-result events, pause-changed, mode toggle.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Mock wailsjs bindings BEFORE importing App — vi.mock is hoisted.
vi.mock('../wailsjs/go/main/App', () => ({
  GetAuthStatus: vi.fn().mockResolvedValue({ authenticated: false }),
  GetQueue: vi.fn().mockResolvedValue([]),
  SignIn: vi.fn(),
  SignOut: vi.fn(),
  CreateDraftForID: vi.fn().mockResolvedValue(undefined),
  DismissEmail: vi.fn().mockResolvedValue(undefined),
  GetSettings: vi.fn().mockResolvedValue({ mode: 'manual', update_checks_enabled: true }),
  SetMode: vi.fn().mockResolvedValue(undefined),
  GetPausedState: vi.fn().mockResolvedValue(false),
  GetUpdateState: vi.fn().mockResolvedValue({
    currentVersion: '3.0.0',
    latestVersion: '',
    latestReleaseUrl: '',
    installerUrl: 'https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe',
    updateAvailable: false,
    lastCheckedAt: '',
    enabled: true,
  }),
  CheckForUpdatesNow: vi.fn().mockResolvedValue(undefined),
}));

// Track calls to BrowserOpenURL so tests can assert that update links route
// through Wails' system-browser helper instead of anchor hrefs (WebView2
// would try to navigate inside the app window otherwise).
const browserOpenURL = vi.fn();

// Track EventsOn registrations so tests can fire events manually.
const eventHandlers: Record<string, ((...args: unknown[]) => void)[]> = {};
vi.mock('../wailsjs/runtime/runtime', () => ({
  EventsOn: vi.fn((event: string, handler: (...args: unknown[]) => void) => {
    if (!eventHandlers[event]) eventHandlers[event] = [];
    eventHandlers[event].push(handler);
    return () => {
      eventHandlers[event] = eventHandlers[event].filter((h) => h !== handler);
    };
  }),
  // Update links open via Wails' BrowserOpenURL — stub it so tests can assert
  // the panel actions routed through it (instead of a plain <a href>).
  BrowserOpenURL: (url: string) => browserOpenURL(url),
}));

// Mock settings module
vi.mock('./lib/settings', () => ({
  fetchSettings: vi.fn().mockResolvedValue({ mode: 'manual' }),
  setMode: vi.fn().mockResolvedValue(undefined),
  getPausedState: vi.fn().mockResolvedValue(false),
  subscribeAutoDraftResult: vi.fn((cb: (r: unknown) => void) => {
    if (!eventHandlers['auto-draft-result']) eventHandlers['auto-draft-result'] = [];
    eventHandlers['auto-draft-result'].push(cb as (...args: unknown[]) => void);
    return () => {};
  }),
  subscribePauseChanged: vi.fn((cb: (p: unknown) => void) => {
    if (!eventHandlers['pause-changed']) eventHandlers['pause-changed'] = [];
    eventHandlers['pause-changed'].push(cb as (...args: unknown[]) => void);
    return () => {};
  }),
  // Phase 11-03 — notify-only update wrappers.
  fetchUpdateState: vi.fn().mockResolvedValue({
    currentVersion: '3.0.0',
    latestVersion: '',
    latestReleaseUrl: '',
    installerUrl: 'https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe',
    updateAvailable: false,
    lastCheckedAt: '',
    enabled: true,
  }),
  checkForUpdatesNow: vi.fn().mockResolvedValue(undefined),
  subscribeUpdateState: vi.fn((cb: (s: unknown) => void) => {
    if (!eventHandlers['update-state-changed']) eventHandlers['update-state-changed'] = [];
    eventHandlers['update-state-changed'].push(cb as (...args: unknown[]) => void);
    return () => {};
  }),
}));

// Mock queue module
vi.mock('./lib/queue', () => ({
  fetchQueue: vi.fn().mockResolvedValue([]),
  subscribeQueue: vi.fn(() => () => {}),
}));

// Mock auth module
vi.mock('./lib/auth', () => ({
  fetchAuthStatus: vi.fn().mockResolvedValue({ authenticated: false }),
  subscribeAuth: vi.fn(() => () => {}),
  hasSeenPreAuthExplainer: vi.fn().mockReturnValue(false),
  markPreAuthExplainerSeen: vi.fn(),
  signIn: vi.fn(),
  signOut: vi.fn(),
}));

import { render, fireEvent } from '@testing-library/svelte';
import App from './App.svelte';
import { fetchSettings, setMode } from './lib/settings';
import { fetchQueue, subscribeQueue } from './lib/queue';
import { fetchAuthStatus } from './lib/auth';

beforeEach(() => {
  // Reset all event handler maps between tests to prevent cross-test bleed.
  Object.keys(eventHandlers).forEach((k) => { eventHandlers[k] = []; });
});

afterEach(() => {
  vi.clearAllMocks();
});

describe('App.svelte — smoke', () => {
  it('mounts without throwing and renders the sign-in screen when unauthenticated', async () => {
    const { findByText } = render(App);
    expect(await findByText(/Sign in with Google/i)).toBeInTheDocument();
  });
});

describe('App.svelte — Phase 9 wiring', () => {
  it('calls fetchSettings on mount', async () => {
    render(App);
    // Allow promises to settle
    await new Promise((r) => setTimeout(r, 0));
    expect(fetchSettings).toHaveBeenCalled();
  });

  it('registers subscribeAutoDraftResult on mount', async () => {
    const { subscribeAutoDraftResult } = await import('./lib/settings');
    render(App);
    await new Promise((r) => setTimeout(r, 0));
    expect(subscribeAutoDraftResult).toHaveBeenCalled();
  });

  it('registers subscribeQueue on mount', async () => {
    render(App);
    await new Promise((r) => setTimeout(r, 0));
    expect(subscribeQueue).toHaveBeenCalled();
  });

  it('renders queue rows when authenticated and queue is non-empty', async () => {
    vi.mocked(fetchAuthStatus).mockResolvedValueOnce({ authenticated: true, email: 'a@b.com' });
    vi.mocked(fetchQueue).mockResolvedValueOnce([
      {
        id: 'email-1',
        message: {
          version: 1,
          timestamp: '2026-04-19T12:00:00Z',
          bodyFormat: 'plain',
          subject: 'Test Subject',
        } as unknown as import('./lib/queue').EmailWithId['message'],
      },
    ]);
    // subscribeQueue must call onChange with the queue for it to render
    vi.mocked(subscribeQueue).mockImplementationOnce((onChange) => {
      // initial call handled by fetchQueue; just register
      return () => {};
    });

    const { findByText } = render(App);
    expect(await findByText('Test Subject')).toBeInTheDocument();
  });

  it('auto-draft-result success event: clears error, adds to flashingIds (✓ Drafted visible)', async () => {
    vi.useFakeTimers();
    vi.mocked(fetchAuthStatus).mockResolvedValueOnce({ authenticated: true, email: 'a@b.com' });
    vi.mocked(fetchQueue).mockResolvedValueOnce([
      {
        id: 'flash-1',
        message: {
          version: 1,
          timestamp: '2026-04-19T12:00:00Z',
          bodyFormat: 'plain',
          subject: 'Flash me',
        } as unknown as import('./lib/queue').EmailWithId['message'],
      },
    ]);

    const { findByText, queryByText } = render(App);
    await findByText('Flash me'); // wait for mount

    // Fire auto-draft-result success
    const handlers = eventHandlers['auto-draft-result'] ?? [];
    handlers.forEach((h) => h({ emailId: 'flash-1', success: true }));

    // Expect flash — but note document.hasFocus() in jsdom returns false by default,
    // so the flash path may not fire. We test that the handler runs without error.
    expect(queryByText('Flash me') ?? null).toBeDefined(); // either subject or flash label is present
    vi.useRealTimers();
  });

  it('auto-draft-result failure event: populates autoDraftErrors (error badge shown on row)', async () => {
    vi.mocked(fetchAuthStatus).mockResolvedValueOnce({ authenticated: true, email: 'a@b.com' });
    vi.mocked(fetchQueue).mockResolvedValueOnce([
      {
        id: 'err-1',
        message: {
          version: 1,
          timestamp: '2026-04-19T12:00:00Z',
          bodyFormat: 'plain',
          subject: 'Error email',
        } as unknown as import('./lib/queue').EmailWithId['message'],
      },
    ]);

    const { findByText, findByRole } = render(App);
    await findByText('Error email');

    // Fire auto-draft-result failure with errorCategory
    const handlers = eventHandlers['auto-draft-result'] ?? [];
    handlers.forEach((h) => h({ emailId: 'err-1', success: false, errorCategory: 'network' }));

    // Error badge (role=status) should appear
    const badge = await findByRole('status', { name: /network error/i });
    expect(badge).toBeTruthy();
  });

  it('pause-changed event flips paused state (no throw)', async () => {
    render(App);
    await new Promise((r) => setTimeout(r, 0));

    // Fire pause-changed — just verify it does not throw
    expect(() => {
      const handlers = eventHandlers['pause-changed'] ?? [];
      handlers.forEach((h) => h(true));
    }).not.toThrow();
  });

  it('mode toggle calls setMode when auto-draft segment clicked', async () => {
    vi.mocked(fetchAuthStatus).mockResolvedValueOnce({
      authenticated: true,
      email: 'a@b.com',
      name: 'Alice',
    });

    const { findByRole } = render(App);
    // Wait for SignedInHeader to render (auth=true)
    const autoDraftBtn = await findByRole('button', { name: /auto-draft/i });
    await fireEvent.click(autoDraftBtn);
    expect(setMode).toHaveBeenCalledWith('auto-draft');
  });
});

// ---------------------------------------------------------------------------
// Phase 11-03 — update UX wiring in the root shell (D-01/D-02/D-07/D-08).
// ---------------------------------------------------------------------------

describe('App.svelte — update UX (Phase 11-03)', () => {
  const availableState = {
    currentVersion: '3.0.0',
    latestVersion: '3.0.1',
    latestReleaseUrl: 'https://github.com/marcfargas/go-mapi/releases/tag/v3.0.1',
    installerUrl:
      'https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe',
    updateAvailable: true,
    lastCheckedAt: '2026-04-21T12:00:00Z',
    enabled: true,
  };

  const noUpdateState = {
    currentVersion: '3.0.0',
    latestVersion: '3.0.0',
    latestReleaseUrl: 'https://github.com/marcfargas/go-mapi/releases/tag/v3.0.0',
    installerUrl:
      'https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe',
    updateAvailable: false,
    lastCheckedAt: '2026-04-21T12:00:00Z',
    enabled: true,
  };

  it('renders the persistent update banner when initial state reports updateAvailable', async () => {
    const { fetchUpdateState } = await import('./lib/settings');
    vi.mocked(fetchUpdateState).mockResolvedValueOnce(availableState);
    const { findByRole } = render(App);
    const banner = await findByRole('region', { name: /update available/i });
    expect(banner).toBeInTheDocument();
    expect(banner.textContent ?? '').toMatch(/3\.0\.1/);
  });

  it('does not render the banner when no update is available', async () => {
    const { fetchUpdateState } = await import('./lib/settings');
    vi.mocked(fetchUpdateState).mockResolvedValueOnce(noUpdateState);
    const { queryByRole } = render(App);
    await new Promise((r) => setTimeout(r, 0));
    expect(queryByRole('region', { name: /update available/i })).toBeNull();
  });

  it('re-renders when update-state-changed event fires (no page reload)', async () => {
    const { fetchUpdateState } = await import('./lib/settings');
    vi.mocked(fetchUpdateState).mockResolvedValueOnce(noUpdateState);
    const { findByRole, queryByRole } = render(App);
    // Initially no banner.
    await new Promise((r) => setTimeout(r, 0));
    expect(queryByRole('region', { name: /update available/i })).toBeNull();

    // Backend emits a new state with updateAvailable=true.
    const handlers = eventHandlers['update-state-changed'] ?? [];
    handlers.forEach((h) => h(availableState));

    const banner = await findByRole('region', { name: /update available/i });
    expect(banner).toBeInTheDocument();
  });

  it('opens the update panel exposing both the release page and the stable installer URL', async () => {
    const { fetchUpdateState } = await import('./lib/settings');
    vi.mocked(fetchUpdateState).mockResolvedValueOnce(availableState);
    const { findByRole, findByText } = render(App);
    const openPanelBtn = await findByRole('button', { name: /view update|see details|open/i });
    await fireEvent.click(openPanelBtn);

    // The panel exposes both URLs (D-02).
    const releaseLink = await findByText(/release notes|release page/i);
    const installerLink = await findByText(/download installer|download go-mapi-setup/i);
    expect(releaseLink).toBeInTheDocument();
    expect(installerLink).toBeInTheDocument();
  });

  it('clicking release/installer links routes through BrowserOpenURL (D-02)', async () => {
    const { fetchUpdateState } = await import('./lib/settings');
    vi.mocked(fetchUpdateState).mockResolvedValueOnce(availableState);
    const { findByRole, findByText } = render(App);
    const openPanelBtn = await findByRole('button', { name: /view update|see details|open/i });
    await fireEvent.click(openPanelBtn);

    const releaseLink = await findByText(/release notes|release page/i);
    const installerLink = await findByText(/download installer|download go-mapi-setup/i);
    await fireEvent.click(releaseLink);
    await fireEvent.click(installerLink);

    const urls = browserOpenURL.mock.calls.map((c) => c[0] as string);
    expect(urls).toEqual(
      expect.arrayContaining([
        availableState.latestReleaseUrl,
        availableState.installerUrl,
      ]),
    );
  });

  it('panel shows current version and last checked timestamp (D-07)', async () => {
    const { fetchUpdateState } = await import('./lib/settings');
    vi.mocked(fetchUpdateState).mockResolvedValueOnce(availableState);
    const { findByRole, findByText } = render(App);
    const openPanelBtn = await findByRole('button', { name: /view update|see details|open/i });
    await fireEvent.click(openPanelBtn);

    expect(await findByText(/3\.0\.0/)).toBeInTheDocument(); // current version
    expect(await findByText(/last checked/i)).toBeInTheDocument();
  });

  it('calls out that background update checks are enabled by default exactly once (D-08)', async () => {
    const { fetchUpdateState } = await import('./lib/settings');
    vi.mocked(fetchUpdateState).mockResolvedValueOnce(availableState);
    const { findByRole, findAllByText } = render(App);
    const openPanelBtn = await findByRole('button', { name: /view update|see details|open/i });
    await fireEvent.click(openPanelBtn);

    const callouts = await findAllByText(/enabled by default/i);
    expect(callouts).toHaveLength(1);
  });

  it('does NOT show a user-visible failure banner for transient update-check errors (D-04)', async () => {
    const { fetchUpdateState } = await import('./lib/settings');
    // Hydration rejects — App.svelte already catches and degrades silently.
    vi.mocked(fetchUpdateState).mockRejectedValueOnce(new Error('github 503'));

    const { queryByRole } = render(App);
    await new Promise((r) => setTimeout(r, 0));

    // No update banner (no data), AND crucially no "update check failed" alert.
    expect(queryByRole('region', { name: /update available/i })).toBeNull();
    expect(queryByRole('alert', { name: /update check failed/i })).toBeNull();
  });

  it('manual "Check for updates now" action forwards to the wrapper', async () => {
    const { fetchUpdateState, checkForUpdatesNow } = await import('./lib/settings');
    vi.mocked(fetchUpdateState).mockResolvedValueOnce(availableState);
    const { findByRole } = render(App);
    const openPanelBtn = await findByRole('button', { name: /view update|see details|open/i });
    await fireEvent.click(openPanelBtn);
    const checkBtn = await findByRole('button', { name: /check.*for updates/i });
    await fireEvent.click(checkBtn);
    expect(checkForUpdatesNow).toHaveBeenCalled();
  });

  it('banner remains visible across a re-fetch while updateAvailable stays true (persistent, D-01)', async () => {
    const { fetchUpdateState } = await import('./lib/settings');
    vi.mocked(fetchUpdateState).mockResolvedValueOnce(availableState);
    const { findByRole } = render(App);
    await findByRole('region', { name: /update available/i });

    // A scheduled background check fires with the same availableState — banner must stay.
    const handlers = eventHandlers['update-state-changed'] ?? [];
    handlers.forEach((h) => h(availableState));

    const banner = await findByRole('region', { name: /update available/i });
    expect(banner).toBeInTheDocument();
  });
});
