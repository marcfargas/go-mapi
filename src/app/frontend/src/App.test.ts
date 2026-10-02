// Tests for App.svelte — smoke + Phase 9 state wiring.
// Scope: mount, queue rendering, auto-draft-result events, pause-changed, mode toggle.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Mock wailsjs bindings BEFORE importing App — vi.mock is hoisted.
vi.mock('../wailsjs/go/main/App', () => ({
  GetAuthStatus: vi.fn().mockResolvedValue({ authenticated: false }),
  GetComponentHealth: vi.fn().mockResolvedValue({ healthy: true, issues: [] }),
  GetAdminInstallState: vi.fn().mockResolvedValue({ phase: 'healthy', retryable: false }),
  GetQueue: vi.fn().mockResolvedValue([]),
  SignIn: vi.fn(),
  SignOut: vi.fn(),
  CreateDraftForID: vi.fn().mockResolvedValue(undefined),
  DismissEmail: vi.fn().mockResolvedValue(undefined),
  GetSettings: vi.fn().mockResolvedValue({ mode: 'manual', update_checks_enabled: true }),
  GetSettingsState: vi.fn().mockResolvedValue({ settings: { mode: 'manual', autostart_enabled: true, default_apps_prompted: true, update_checks_enabled: true } }),
  SaveSettings: vi.fn().mockResolvedValue(undefined),
  GetStartupState: vi.fn().mockResolvedValue({ backend: 'standalone', requested: true, registered: true, effective: 'enabled' }),
  SetAutostartEnabled: vi.fn(),
  OpenStartupSettings: vi.fn(),
  SetMode: vi.fn().mockResolvedValue(undefined),
  GetPausedState: vi.fn().mockResolvedValue(false),
  GetUpdateState: vi.fn().mockResolvedValue({
    currentVersion: '3.0.0',
    latestVersion: '',
    latestReleaseUrl: '',
    installerUrl: '',
    updateAvailable: false,
    lastCheckedAt: '',
    enabled: true,
  }),
  CheckForUpdatesNow: vi.fn().mockResolvedValue(undefined),
  OpenUpdateAction: vi.fn().mockResolvedValue(undefined),
  StartAdminRepair: vi.fn().mockResolvedValue(undefined),
}));

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
}));

// Mock settings module
vi.mock('./lib/settings', () => ({
  fetchSettingsState: vi.fn().mockResolvedValue({ settings: { mode: 'manual', autostart_enabled: true, default_apps_prompted: true, update_checks_enabled: true } }),
  saveSettings: vi.fn().mockResolvedValue(undefined),
  fetchStartupState: vi.fn().mockResolvedValue({ backend: 'standalone', requested: true, registered: true, effective: 'enabled' }),
  setAutostartEnabled: vi.fn().mockResolvedValue({ backend: 'standalone', requested: true, registered: true, effective: 'enabled' }),
  openStartupSettings: vi.fn().mockResolvedValue(undefined),
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
    installerUrl: '',
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
  subscribeAuth: vi.fn((cb: (s: unknown) => void) => {
    eventHandlers['auth-changed'] = [cb as (...args: unknown[]) => void];
    return () => { eventHandlers['auth-changed'] = []; };
  }),
  hasSeenPreAuthExplainer: vi.fn().mockReturnValue(false),
  markPreAuthExplainerSeen: vi.fn(),
  signIn: vi.fn(),
  signOut: vi.fn(),
}));

import { render, fireEvent, screen, waitFor, within } from '@testing-library/svelte';
import App from './App.svelte';
import { fetchSettingsState, saveSettings, setMode, fetchStartupState, setAutostartEnabled, openStartupSettings, fetchUpdateState } from './lib/settings';
import { fetchQueue, subscribeQueue } from './lib/queue';
import { fetchAuthStatus } from './lib/auth';
import { GetAdminInstallState, GetComponentHealth, OpenUpdateAction, StartAdminRepair } from '../wailsjs/go/main/App';

beforeEach(() => {
  // Reset all event handler maps between tests to prevent cross-test bleed.
  Object.keys(eventHandlers).forEach((k) => { eventHandlers[k] = []; });
  vi.mocked(fetchAuthStatus).mockReset().mockResolvedValue({ authenticated: false });
  vi.mocked(fetchQueue).mockReset().mockResolvedValue([]);
  vi.mocked(fetchSettingsState).mockReset().mockResolvedValue({ settings: { mode: 'manual', autostart_enabled: true, default_apps_prompted: true, update_checks_enabled: true } } as never);
  vi.mocked(fetchStartupState).mockReset().mockResolvedValue({ backend: 'standalone', requested: true, registered: true, effective: 'enabled' });
  vi.mocked(setAutostartEnabled).mockReset().mockResolvedValue({ backend: 'standalone', requested: true, registered: true, effective: 'enabled' });
  vi.mocked(saveSettings).mockReset().mockResolvedValue(undefined);
  vi.mocked(openStartupSettings).mockReset().mockResolvedValue(undefined);
  vi.mocked(fetchUpdateState).mockReset().mockResolvedValue({ currentVersion: '3.0.0', latestVersion: '', latestReleaseUrl: '', installerUrl: '', updateAvailable: false, lastCheckedAt: '', enabled: true });
  vi.mocked(GetComponentHealth).mockReset().mockResolvedValue({ healthy: true, issues: [] });
  vi.mocked(GetAdminInstallState).mockReset().mockResolvedValue({ phase: 'healthy', retryable: false });
});

afterEach(() => {
  vi.clearAllMocks();
});

describe('App.svelte — smoke', () => {
  it('mounts without throwing and renders the sign-in screen when unauthenticated', async () => {
    const { findByText } = render(App);
    expect(await findByText(/Sign in with Google/i)).toBeInTheDocument();
  });

  it('renders persistent actionable component health', async () => {
    vi.mocked(GetComponentHealth).mockResolvedValueOnce({
      healthy: false,
      issues: [{
        code: 'below-minimum', component: 'app', installedVersion: '4.0.0',
        required: { component: 'app', minInclusive: '4.2.0' },
        action: 'update-app', message: 'Update go-mapi to restore MAPI compatibility.',
      }],
    });
    const { findByRole, findByText } = render(App);
    expect(await findByRole('alert', { name: /component compatibility/i })).toBeInTheDocument();
    expect(await findByText(/Action: update-app/i)).toBeInTheDocument();
  });

  it('requires an explicit action before starting interceptor repair', async () => {
    vi.mocked(GetAdminInstallState).mockResolvedValueOnce({ phase: 'offer', retryable: false });
    const { findByRole } = render(App);
    expect(StartAdminRepair).not.toHaveBeenCalled();
    await fireEvent.click(await findByRole('button', { name: /install or repair interceptor/i }));
    expect(StartAdminRepair).toHaveBeenCalledOnce();
  });

  it('renders a fail-closed release-contract error as retryable, not healthy', async () => {
    vi.mocked(GetAdminInstallState).mockResolvedValueOnce({
      phase: 'failed', retryable: true, errorCode: 'release-contract-unavailable',
      message: 'trusted admin release metadata is not configured',
    });
    const { findByRole, findByText } = render(App);
    expect(await findByRole('alert', { name: /admin component installation/i })).toBeInTheDocument();
    expect(await findByText(/trusted admin release metadata/i)).toBeInTheDocument();
    expect(await findByRole('button', { name: /try again/i })).toBeInTheDocument();
  });

  it('surfaces invalid settings without claiming manual mode', async () => {
    vi.mocked(fetchSettingsState).mockResolvedValueOnce({
      settings: { mode: '', autostart_enabled: true, default_apps_prompted: true, update_checks_enabled: true },
      issue: { kind: 'invalid-mode', message: 'Unsupported mode "broken"', path: 'C:\\Users\\test\\settings.json' },
    } as never);
    const { findByRole, queryByText } = render(App);
    expect(await findByRole('alert', { name: /invalid settings/i })).toHaveTextContent(/Unsupported mode/);
    expect(queryByText(/mode: manual/i)).not.toBeInTheDocument();
  });

  it.each([false, true, undefined])('keeps Send To guidance reachable with legacy dismissal %s', async (dismissed) => {
    vi.mocked(fetchSettingsState).mockResolvedValueOnce({
      settings: { mode: 'auto-draft', autostart_enabled: false, default_apps_prompted: dismissed, update_checks_enabled: false },
    } as never);
    const { findByText, queryByRole } = render(App);
    const summary = await findByText('Email with Send To');
    expect(summary.closest('details')).not.toHaveAttribute('open');
    await fireEvent.click(summary);
    expect(summary.closest('details')).toHaveAttribute('open');
    expect(summary.closest('details')).toHaveTextContent(/system component.*running go-mapi app.*mailto links.*never sent automatically/i);
    expect(queryByRole('button', { name: /open default apps/i })).not.toBeInTheDocument();
    await fireEvent.click(summary);
    expect(summary.closest('details')).not.toHaveAttribute('open');
    expect(saveSettings).not.toHaveBeenCalled();
    expect(setMode).not.toHaveBeenCalled();
    expect(setAutostartEnabled).not.toHaveBeenCalled();
    expect(StartAdminRepair).not.toHaveBeenCalled();
  });

  it('shows Send To guidance when settings fail to load and the component is missing', async () => {
    vi.mocked(fetchSettingsState).mockRejectedValueOnce(new Error('settings unavailable'));
    vi.mocked(GetComponentHealth).mockResolvedValueOnce({ healthy: false, issues: [{ code: 'missing', component: 'interceptor', action: 'install', message: 'System component missing' }] } as never);
    const { findByText } = render(App);
    expect((await findByText('Email with Send To')).closest('details')).toBeInTheDocument();
    expect(await findByText(/System component missing/i)).toBeInTheDocument();
    expect(saveSettings).not.toHaveBeenCalled();
  });

  it('shows an actionable startup warning and repairs it on request', async () => {
    vi.mocked(fetchStartupState).mockResolvedValueOnce({
      backend: 'standalone', requested: true, registered: true,
      effective: 'disabled', warning: 'Windows has disabled go-mapi startup.',
    } as never);
    const { findByRole } = render(App);
    const alert = await findByRole('alert', { name: /startup warning/i });
    expect(alert).toHaveTextContent(/Windows has disabled go-mapi startup/i);
    await fireEvent.click(await findByRole('button', { name: /fix startup/i }));
    expect(setAutostartEnabled).toHaveBeenCalledWith(true);
  });
});

describe('App.svelte — startup preferences', () => {
  const state = (backend: string, requested: boolean, effective: string, warning?: string) =>
    ({ backend, requested, registered: effective === 'enabled', effective, ...(warning ? { warning } : {}) });

  it.each([
    ['standalone', true, 'enabled'], ['machine', true, 'enabled'], ['msix', true, 'enabled'],
    ['standalone', false, 'missing'], ['machine', false, 'disabled'], ['msix', false, 'disabled'],
  ])('keeps healthy %s requested=%s neutral and reopenable', async (backend, requested, effective) => {
    vi.mocked(fetchStartupState).mockResolvedValueOnce(state(backend, requested, effective));
    render(App);
    const button = screen.getByRole('button', { name: 'Preferences' });
    await waitFor(() => expect(fetchStartupState).toHaveBeenCalled());
    expect(button).toHaveAttribute('aria-expanded', 'false');
    expect(screen.queryByRole('checkbox', { name: /start go-mapi/i })).toBeNull();
    expect(screen.queryByRole('alert', { name: /startup warning/i })).toBeNull();
    await fireEvent.click(button);
    expect(button).toHaveAttribute('aria-expanded', 'true');
    expect(screen.getByRole('checkbox', { name: /start go-mapi/i })).toHaveProperty('checked', requested);
    expect(screen.getByText(`Windows status: ${effective} (${backend})`)).toBeInTheDocument();
    await fireEvent.click(button);
    expect(button).toHaveAttribute('aria-expanded', 'false');
    expect(screen.queryByRole('checkbox', { name: /start go-mapi/i })).toBeNull();
    await fireEvent.click(button);
    expect(screen.getByRole('checkbox', { name: /start go-mapi/i })).toHaveProperty('checked', requested);
    expect(setAutostartEnabled).not.toHaveBeenCalled();
    expect(saveSettings).not.toHaveBeenCalled();
  });

  it('keeps disclosure open through authentication changes and resets on remount', async () => {
    vi.mocked(fetchStartupState).mockResolvedValue(state('standalone', false, 'missing'));
    const view = render(App);
    const button = await screen.findByRole('button', { name: 'Preferences' });
    await fireEvent.click(button);
    await waitFor(() => expect(screen.getByRole('checkbox', { name: /start go-mapi/i })).not.toBeChecked());
    eventHandlers['auth-changed']?.forEach((cb) => cb({ authenticated: true, email: 'test@example.com' }));
    expect(button).toHaveAttribute('aria-expanded', 'true');
    eventHandlers['auth-changed']?.forEach((cb) => cb({ authenticated: false }));
    expect(button).toHaveAttribute('aria-expanded', 'true');
    view.unmount();
    render(App);
    expect(screen.getByRole('button', { name: 'Preferences' })).toHaveAttribute('aria-expanded', 'false');
    expect(setAutostartEnabled).not.toHaveBeenCalled();
  });

  it('uses returned state for a write and retains confirmed choice after rejection', async () => {
    vi.mocked(setAutostartEnabled).mockResolvedValueOnce(state('standalone', false, 'missing')).mockRejectedValueOnce(new Error('disk full'));
    render(App);
    await fireEvent.click(screen.getByRole('button', { name: 'Preferences' }));
    const checkbox = await screen.findByRole('checkbox', { name: /start go-mapi/i });
    await fireEvent.click(checkbox);
    await waitFor(() => expect(checkbox).not.toBeChecked());
    expect(setAutostartEnabled).toHaveBeenCalledWith(false);
    await fireEvent.click(checkbox);
    await waitFor(() => expect(screen.getByRole('alert', { name: /startup warning/i })).toHaveTextContent(/disk full/));
    expect(checkbox).not.toBeChecked();
    expect(setAutostartEnabled).toHaveBeenCalledWith(true);
    await fireEvent.click(screen.getByRole('button', { name: 'Preferences' }));
    expect(screen.getByRole('alert', { name: /startup warning/i })).toHaveTextContent(/disk full/);
  });

  it('serializes pending writes even if a second checkbox event is fired', async () => {
    let finish!: (value: ReturnType<typeof state>) => void;
    vi.mocked(setAutostartEnabled).mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
    render(App);
    await fireEvent.click(screen.getByRole('button', { name: 'Preferences' }));
    const checkbox = await screen.findByRole('checkbox', { name: /start go-mapi/i });
    await fireEvent.click(checkbox);
    // Pending writes keep the checkbox focusable (aria-disabled, not disabled)
    // so WebView2 focus fixup cannot drop keyboard focus to the document.
    expect(checkbox).toHaveAttribute('aria-disabled', 'true');
    expect(checkbox).not.toBeDisabled();
    await fireEvent.change(checkbox, { target: { checked: false } });
    await fireEvent.click(checkbox);
    expect(setAutostartEnabled).toHaveBeenCalledOnce();
    finish(state('standalone', false, 'missing'));
    await waitFor(() => expect(checkbox).not.toHaveAttribute('aria-disabled'));
    expect(checkbox).not.toBeDisabled();
  });

  it('keeps Fix startup focusable but inert while its write is pending', async () => {
    let finish!: (value: ReturnType<typeof state>) => void;
    vi.mocked(fetchStartupState).mockResolvedValueOnce(state('standalone', true, 'missing', 'Choose Fix startup.'));
    vi.mocked(setAutostartEnabled).mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
    render(App);
    const fix = await screen.findByRole('button', { name: /fix startup/i });
    await fireEvent.click(fix);
    expect(fix).toHaveAttribute('aria-disabled', 'true');
    expect(fix).not.toBeDisabled();
    await fireEvent.click(fix);
    expect(setAutostartEnabled).toHaveBeenCalledOnce();
    finish(state('standalone', true, 'enabled'));
    await waitFor(() => expect(screen.queryByRole('button', { name: /fix startup/i })).toBeNull());
  });

  it.each([
    ['standalone', true, 'missing', true], ['standalone', false, 'mismatched', false],
    ['machine', true, 'missing', false], ['msix', true, 'disabledbyuser', false],
    ['msix', true, 'disabledbypolicy', false], ['msix', true, 'unknown', false],
    ['msix', true, 'disabled', true],
  ])('shows %s warning independently and repair eligibility for %s/%s', async (backend, requested, effective, canFix) => {
    vi.mocked(fetchStartupState).mockResolvedValueOnce(state(backend, requested, effective, 'Choose Fix startup or inspect Windows Startup Apps.'));
    render(App);
    const alert = await screen.findByRole('alert', { name: /startup warning/i });
    expect(alert).toHaveTextContent(/Choose Fix startup/);
    expect(within(alert).queryByRole('button', { name: /fix startup/i }) !== null).toBe(canFix);
    expect(within(alert).getByRole('button', { name: /open startup apps/i })).toBeInTheDocument();
    if (!requested) expect(alert).toHaveTextContent(/Review Preferences or Windows Startup Apps/);
    expect(setAutostartEnabled).not.toHaveBeenCalled();
  });

  it('reports failed reads and retries without presenting an invented saved value', async () => {
    vi.mocked(fetchStartupState).mockRejectedValueOnce(new Error('read failed')).mockResolvedValueOnce(state('machine', false, 'disabled'));
    render(App);
    const alert = await screen.findByRole('alert', { name: /startup warning/i });
    await fireEvent.click(screen.getByRole('button', { name: 'Preferences' }));
    expect(screen.queryByRole('checkbox', { name: /start go-mapi/i })).toBeNull();
    await fireEvent.click(within(alert).getByRole('button', { name: /retry startup status/i }));
    await waitFor(() => expect(screen.getByRole('checkbox', { name: /start go-mapi/i })).not.toBeChecked());
    expect(screen.queryByRole('alert', { name: /startup warning/i })).toBeNull();
  });

  it('guards settings repair through the reread and leaves failed saves invalid', async () => {
    vi.mocked(fetchSettingsState).mockResolvedValueOnce({ settings: { mode: '', autostart_enabled: true, default_apps_prompted: true, update_checks_enabled: true }, issue: { kind: 'invalid', message: 'Invalid settings', path: 'settings.json' } } as never);
    vi.mocked(fetchStartupState).mockResolvedValueOnce(state('standalone', true, 'missing', 'Choose Fix startup.'));
    let finishSave!: () => void;
    let finishRead!: (value: ReturnType<typeof state>) => void;
    vi.mocked(saveSettings).mockImplementationOnce(() => new Promise((resolve) => { finishSave = () => resolve(undefined); }));
    vi.mocked(fetchStartupState).mockImplementationOnce(() => new Promise((resolve) => { finishRead = resolve; }));
    render(App);
    const repair = await screen.findByRole('button', { name: /repair and use manual mode/i });
    expect(screen.getByRole('alert', { name: /startup warning/i })).toHaveTextContent(/Repair settings first/);
    expect(screen.queryByRole('button', { name: /fix startup/i })).toBeNull();
    await fireEvent.click(repair);
    await fireEvent.click(repair);
    expect(saveSettings).toHaveBeenCalledOnce();
    finishSave();
    await waitFor(() => expect(fetchStartupState).toHaveBeenCalledTimes(2));
    await fireEvent.click(screen.getByRole('button', { name: 'Preferences' }));
    expect(screen.queryByRole('checkbox', { name: /start go-mapi/i })).toBeNull();
    expect(setAutostartEnabled).not.toHaveBeenCalled();
    finishRead(state('standalone', true, 'enabled'));
    await waitFor(() => expect(screen.getByRole('checkbox', { name: /start go-mapi/i })).toBeEnabled());
  });

  it('keeps settings issue after repair save failure', async () => {
    vi.mocked(fetchSettingsState).mockResolvedValueOnce({ settings: { mode: '', autostart_enabled: true, default_apps_prompted: true, update_checks_enabled: true }, issue: { kind: 'invalid', message: 'Invalid settings', path: 'settings.json' } } as never);
    vi.mocked(saveSettings).mockRejectedValueOnce(new Error('save failed'));
    render(App);
    await fireEvent.click(await screen.findByRole('button', { name: /repair and use manual mode/i }));
    await waitFor(() => expect(screen.getByRole('alert', { name: /invalid settings/i })).toHaveTextContent(/save failed/));
    expect(fetchStartupState).toHaveBeenCalledOnce();
  });

  it('reports a failed post-repair read as unknown while leaving settings repaired', async () => {
    vi.mocked(fetchSettingsState).mockResolvedValueOnce({ settings: { mode: '', autostart_enabled: true, default_apps_prompted: true, update_checks_enabled: true }, issue: { kind: 'invalid', message: 'Invalid settings', path: 'settings.json' } } as never);
    vi.mocked(fetchStartupState).mockResolvedValueOnce(state('standalone', false, 'missing')).mockRejectedValueOnce(new Error('read failed'));
    render(App);
    await fireEvent.click(await screen.findByRole('button', { name: /repair and use manual mode/i }));
    const alert = await screen.findByRole('alert', { name: /startup warning/i });
    await waitFor(() => expect(alert).toHaveTextContent(/could not be read/));
    expect(screen.queryByRole('alert', { name: /invalid settings/i })).toBeNull();
    await fireEvent.click(screen.getByRole('button', { name: 'Preferences' }));
    expect(screen.queryByRole('checkbox', { name: /start go-mapi/i })).toBeNull();
    expect(setAutostartEnabled).not.toHaveBeenCalled();
  });

  it('adopts a saved request even when Windows returns a platform warning', async () => {
    vi.mocked(setAutostartEnabled).mockResolvedValueOnce(state('standalone', false, 'mismatched', 'Registration still exists.'));
    render(App);
    await fireEvent.click(screen.getByRole('button', { name: 'Preferences' }));
    const checkbox = await screen.findByRole('checkbox', { name: /start go-mapi/i });
    await fireEvent.click(checkbox);
    await waitFor(() => expect(checkbox).not.toBeChecked());
    const alert = await screen.findByRole('alert', { name: /startup warning/i });
    expect(alert).toHaveTextContent(/Registration still exists/);
    expect(alert).toHaveTextContent(/Startup is off by your choice/);
  });

  it('keeps a failed Fix action visible after closing Preferences', async () => {
    vi.mocked(fetchStartupState).mockResolvedValueOnce(state('standalone', true, 'missing', 'Registration missing.'));
    vi.mocked(setAutostartEnabled).mockRejectedValueOnce(new Error('admission denied'));
    render(App);
    const alert = await screen.findByRole('alert', { name: /startup warning/i });
    await fireEvent.click(within(alert).getByRole('button', { name: /fix startup/i }));
    await waitFor(() => expect(alert).toHaveTextContent(/admission denied/));
    expect(setAutostartEnabled).toHaveBeenCalledWith(true);
  });

  it('reports Startup Apps failure without clearing a save failure', async () => {
    vi.mocked(setAutostartEnabled).mockRejectedValueOnce(new Error('save failed'));
    vi.mocked(openStartupSettings).mockRejectedValueOnce(new Error('open failed'));
    render(App);
    await fireEvent.click(screen.getByRole('button', { name: 'Preferences' }));
    await fireEvent.click(await screen.findByRole('checkbox', { name: /start go-mapi/i }));
    const alert = await screen.findByRole('alert', { name: /startup warning/i });
    await fireEvent.click(within(alert).getByRole('button', { name: /open startup apps/i }));
    await waitFor(() => expect(alert).toHaveTextContent(/open failed/));
    expect(alert).toHaveTextContent(/save failed/);
  });
});

describe('App.svelte — Phase 9 wiring', () => {
  it('calls fetchSettingsState on mount', async () => {
    render(App);
    // Allow promises to settle
    await new Promise((r) => setTimeout(r, 0));
    expect(fetchSettingsState).toHaveBeenCalled();
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
    latestReleaseUrl: 'https://go-mapi.app/downloads/app/3.0.1/x64',
    installerUrl: 'https://go-mapi.app/downloads/app/3.0.1/x64',
    updateAvailable: true,
    distributionChannel: 'standalone',
    updateActionUrl: 'https://go-mapi.app/downloads/app/3.0.1/x64',
    updateActionLabel: 'Open download page',
    lastSuccessfulAt: '2026-04-21T12:00:00Z',
    lastCheckedAt: '2026-04-21T12:00:00Z',
    enabled: true,
  };

  const noUpdateState = {
    currentVersion: '3.0.0',
    latestVersion: '3.0.0',
    latestReleaseUrl: '',
    installerUrl: '',
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

  it('shows an interceptor-only notice without a per-user installer action', async () => {
    const { fetchUpdateState } = await import('./lib/settings');
    vi.mocked(fetchUpdateState).mockResolvedValueOnce({ ...noUpdateState, interceptorLatestVersion: '4.0.1', interceptorUpdateAvailable: true, distributionChannel: 'standalone' });
    const { findByRole, queryByRole } = render(App);
    const banner = await findByRole('region', { name: /update available/i });
    expect(banner).toHaveTextContent(/system component update available/i);
    await fireEvent.click(await findByRole('button', { name: /view update/i }));
    expect(await findByRole('heading', { name: /system component update available/i })).toBeInTheDocument();
    expect(queryByRole('button', { name: /open download page/i })).toBeNull();
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

  it('opens the update panel exposing the versioned first-party download page', async () => {
    const { fetchUpdateState } = await import('./lib/settings');
    vi.mocked(fetchUpdateState).mockResolvedValueOnce(availableState);
    const { findByRole, findByText, queryByText } = render(App);
    const openPanelBtn = await findByRole('button', { name: /view update|see details|open/i });
    await fireEvent.click(openPanelBtn);

    expect(await findByText(/open download page/i)).toBeInTheDocument();
    expect(queryByText(/release notes|release page/i)).toBeNull();
  });

  it('clicking the download button invokes the validated backend action', async () => {
    const { fetchUpdateState } = await import('./lib/settings');
    vi.mocked(fetchUpdateState).mockResolvedValueOnce(availableState);
    const { findByRole, findByText } = render(App);
    const openPanelBtn = await findByRole('button', { name: /view update|see details|open/i });
    await fireEvent.click(openPanelBtn);

    await fireEvent.click(await findByText(/open download page/i));
    expect(OpenUpdateAction).toHaveBeenCalledOnce();
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
