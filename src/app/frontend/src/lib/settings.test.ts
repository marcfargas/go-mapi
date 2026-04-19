import { describe, it, expect, vi, beforeEach } from 'vitest';

// Mock wailsjs bindings — Plan 04 surfaces these.
vi.mock('../../wailsjs/go/main/App', () => ({
  GetSettings: vi.fn(),
  SaveSettings: vi.fn(),
  GetMode: vi.fn(),
  SetMode: vi.fn(),
  PauseWatching: vi.fn(),
  ResumeWatching: vi.fn(),
  GetPausedState: vi.fn(),
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
    await saveSettings({ mode: 'auto-draft' });
    expect(SaveSettings).toHaveBeenCalledWith({ mode: 'auto-draft' });
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
});
