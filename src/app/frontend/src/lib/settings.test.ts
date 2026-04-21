import { describe, it, expect, vi, beforeEach } from 'vitest';

// Mock wailsjs bindings — Plan 04 surfaces these; Plan 11-03 adds update wrappers.
vi.mock('../../wailsjs/go/main/App', () => ({
  GetSettings: vi.fn(),
  SaveSettings: vi.fn(),
  GetMode: vi.fn(),
  SetMode: vi.fn(),
  PauseWatching: vi.fn(),
  ResumeWatching: vi.fn(),
  GetPausedState: vi.fn(),
  GetUpdateState: vi.fn(),
  CheckForUpdatesNow: vi.fn(),
}));

vi.mock('../../wailsjs/runtime/runtime', () => ({
  EventsOn: vi.fn(),
}));

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
import { EventsOn } from '../../wailsjs/runtime/runtime';
import {
  fetchSettings,
  saveSettings,
  getMode,
  setMode,
  pauseWatching,
  resumeWatching,
  getPausedState,
  subscribeAutoDraftResult,
  subscribePauseChanged,
  fetchUpdateState,
  checkForUpdatesNow,
  subscribeUpdateState,
  type UpdateState,
} from './settings';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const asMock = <T extends (...args: any[]) => any>(fn: T) =>
  fn as unknown as ReturnType<typeof vi.fn>;

describe('settings.ts', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('fetchSettings returns AppSettings from the Go binding', async () => {
    asMock(GetSettings).mockResolvedValue({ mode: 'auto-draft' });
    const s = await fetchSettings();
    expect(s).toEqual({ mode: 'auto-draft' });
    expect(GetSettings).toHaveBeenCalledOnce();
  });

  it('saveSettings forwards to SaveSettings with the given value', async () => {
    asMock(SaveSettings).mockResolvedValue(undefined);
    // Phase 11-03: AppSettings now includes the update-check fields (D-08).
    const next = { mode: 'auto-draft' as const, update_checks_enabled: true };
    await saveSettings(next);
    expect(SaveSettings).toHaveBeenCalledWith(next);
  });

  it('getMode returns "manual" or "auto-draft" (narrows unknown strings)', async () => {
    asMock(GetMode).mockResolvedValueOnce('auto-draft');
    expect(await getMode()).toBe('auto-draft');
    asMock(GetMode).mockResolvedValueOnce('manual');
    expect(await getMode()).toBe('manual');
    asMock(GetMode).mockResolvedValueOnce('garbage');
    expect(await getMode()).toBe('manual'); // narrowing fallback
  });

  it('setMode forwards to SetMode', async () => {
    asMock(SetMode).mockResolvedValue(undefined);
    await setMode('auto-draft');
    expect(SetMode).toHaveBeenCalledWith('auto-draft');
  });

  it('pauseWatching + resumeWatching forward to their bindings', async () => {
    asMock(PauseWatching).mockResolvedValue(undefined);
    asMock(ResumeWatching).mockResolvedValue(undefined);
    await pauseWatching();
    await resumeWatching();
    expect(PauseWatching).toHaveBeenCalledOnce();
    expect(ResumeWatching).toHaveBeenCalledOnce();
  });

  it('getPausedState returns the Go-reported bool', async () => {
    asMock(GetPausedState).mockResolvedValueOnce(true);
    expect(await getPausedState()).toBe(true);
    asMock(GetPausedState).mockResolvedValueOnce(false);
    expect(await getPausedState()).toBe(false);
  });

  it('subscribeAutoDraftResult registers on auto-draft-result + returns unsubscribe', () => {
    const unsub = vi.fn();
    asMock(EventsOn).mockReturnValue(unsub);
    const cb = vi.fn();
    const off = subscribeAutoDraftResult(cb);
    expect(EventsOn).toHaveBeenCalledWith('auto-draft-result', expect.any(Function));
    // Fire the handler captured by EventsOn.
    const handler = asMock(EventsOn).mock.calls[0]?.[1] as ((r: unknown) => void) | undefined;
    handler?.({ emailId: 'abc', success: false, errorCategory: 'network' });
    expect(cb).toHaveBeenCalledWith({ emailId: 'abc', success: false, errorCategory: 'network' });
    off();
    expect(unsub).toHaveBeenCalledOnce();
  });

  it('subscribePauseChanged registers on pause-changed + returns unsubscribe', () => {
    const unsub = vi.fn();
    asMock(EventsOn).mockReturnValue(unsub);
    const cb = vi.fn();
    const off = subscribePauseChanged(cb);
    expect(EventsOn).toHaveBeenCalledWith('pause-changed', expect.any(Function));
    const handler = asMock(EventsOn).mock.calls[0]?.[1] as ((paused: unknown) => void) | undefined;
    handler?.(true);
    expect(cb).toHaveBeenCalledWith(true);
    off();
    expect(unsub).toHaveBeenCalledOnce();
  });

  // ---------------------------------------------------------------
  // Phase 11-03 — update-state wrappers
  // ---------------------------------------------------------------

  describe('update-state wrappers (Phase 11-03)', () => {
    const sampleState: UpdateState = {
      currentVersion: '3.0.0',
      latestVersion: '3.0.1',
      latestReleaseUrl: 'https://github.com/marcfargas/go-mapi/releases/tag/v3.0.1',
      installerUrl: 'https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe',
      updateAvailable: true,
      lastCheckedAt: '2026-04-21T12:00:00Z',
      enabled: true,
    };

    it('fetchUpdateState returns the typed UpdateState from the Go binding', async () => {
      asMock(GetUpdateState).mockResolvedValueOnce(sampleState);
      const s = await fetchUpdateState();
      expect(s).toEqual(sampleState);
      expect(GetUpdateState).toHaveBeenCalledOnce();
    });

    it('fetchUpdateState typed fields expose current version, last checked, enabled flag, and release links', async () => {
      asMock(GetUpdateState).mockResolvedValueOnce(sampleState);
      const s = await fetchUpdateState();
      // Compile-time: UpdateState must expose each field without `any`.
      const version: string = s.currentVersion;
      const last: string = s.lastCheckedAt;
      const enabled: boolean = s.enabled;
      const release: string = s.latestReleaseUrl;
      const installer: string = s.installerUrl;
      expect(version).toBe('3.0.0');
      expect(last).toBe('2026-04-21T12:00:00Z');
      expect(enabled).toBe(true);
      expect(release).toContain('releases/tag/');
      expect(installer).toContain('go-mapi-setup.exe');
    });

    it('checkForUpdatesNow forwards to CheckForUpdatesNow without requiring a context argument', async () => {
      // Wails auto-injects context.Context; the typed wrapper must hide that arg.
      asMock(CheckForUpdatesNow).mockResolvedValueOnce(undefined);
      await checkForUpdatesNow();
      expect(CheckForUpdatesNow).toHaveBeenCalledOnce();
    });

    it('checkForUpdatesNow returning an error from the binding resolves silently (D-04 silent-failure)', async () => {
      // The wrapper must not propagate the error — backend treats it as silent/log-only.
      asMock(CheckForUpdatesNow).mockRejectedValueOnce(new Error('boom'));
      await expect(checkForUpdatesNow()).resolves.toBeUndefined();
    });

    it('subscribeUpdateState registers on update-state-changed + returns unsubscribe', () => {
      const unsub = vi.fn();
      asMock(EventsOn).mockReturnValue(unsub);
      const cb = vi.fn();
      const off = subscribeUpdateState(cb);
      expect(EventsOn).toHaveBeenCalledWith('update-state-changed', expect.any(Function));

      const handler = asMock(EventsOn).mock.calls[0]?.[1] as
        | ((state: unknown) => void)
        | undefined;
      handler?.(sampleState);
      expect(cb).toHaveBeenCalledWith(sampleState);

      off();
      expect(unsub).toHaveBeenCalledOnce();
    });
  });
});
