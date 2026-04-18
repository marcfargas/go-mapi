// Unit tests for src/app/frontend/src/lib/queue.ts
//
// Key regression: WR-03 — GetQueue binding returns null when the queue is
// empty; fetchQueue MUST normalize null → []. See
// .planning/phases/08-oauth-credentials/08-REVIEW-FIX.md for the original bug.
import { describe, it, expect, vi } from 'vitest';

vi.mock('../../wailsjs/go/main/App', () => ({
  GetQueue: vi.fn(),
}));
vi.mock('../../wailsjs/runtime/runtime', () => ({
  EventsOn: vi.fn(() => () => {}),
}));

import { fetchQueue, subscribeQueue, type EmailWithId } from './queue';
import { GetQueue } from '../../wailsjs/go/main/App';
import { EventsOn } from '../../wailsjs/runtime/runtime';

describe('queue module — fetchQueue null-guard (WR-03 regression)', () => {
  it('returns [] when GetQueue resolves to null', async () => {
    (GetQueue as unknown as ReturnType<typeof vi.fn>).mockResolvedValue(null);
    await expect(fetchQueue()).resolves.toEqual([]);
  });

  it('returns the array unchanged when GetQueue resolves to a populated array', async () => {
    const items: EmailWithId[] = [
      { id: 'abc', message: { version: 1, timestamp: '2026-04-18T00:00:00Z', bodyFormat: 'plain' } },
    ];
    (GetQueue as unknown as ReturnType<typeof vi.fn>).mockResolvedValue(items);
    await expect(fetchQueue()).resolves.toEqual(items);
  });
});

describe('queue module — subscribeQueue', () => {
  it('wires EventsOn with the queue-update event name', () => {
    const unsub = vi.fn();
    (EventsOn as unknown as ReturnType<typeof vi.fn>).mockReturnValue(unsub);
    const onChange = vi.fn();
    const ret = subscribeQueue(onChange);
    expect(EventsOn).toHaveBeenCalledWith('queue-update', expect.any(Function));
    expect(ret).toBe(unsub);
  });

  it('invokes onChange with the latest queue snapshot when the event fires', async () => {
    let eventHandler: (() => void) | undefined;
    (EventsOn as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (_: string, h: () => void) => {
        eventHandler = h;
        return () => {};
      },
    );
    const onChange = vi.fn();
    const items: EmailWithId[] = [{ id: 'x' }];
    (GetQueue as unknown as ReturnType<typeof vi.fn>).mockResolvedValue(items);

    subscribeQueue(onChange);
    eventHandler!();
    // Flush the microtask queue so the .then(onChange) callback runs.
    await new Promise((r) => setTimeout(r, 0));
    expect(onChange).toHaveBeenCalledWith(items);
  });

  it('invokes onError when GetQueue rejects after an event', async () => {
    let eventHandler: (() => void) | undefined;
    (EventsOn as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (_: string, h: () => void) => {
        eventHandler = h;
        return () => {};
      },
    );
    const onChange = vi.fn();
    const onError = vi.fn();
    const err = new Error('ipc fail');
    (GetQueue as unknown as ReturnType<typeof vi.fn>).mockRejectedValue(err);

    subscribeQueue(onChange, onError);
    eventHandler!();
    await new Promise((r) => setTimeout(r, 0));
    expect(onError).toHaveBeenCalledWith(err);
    expect(onChange).not.toHaveBeenCalled();
  });

  it('does not throw when GetQueue rejects and no onError was supplied (graceful no-op)', async () => {
    let eventHandler: (() => void) | undefined;
    (EventsOn as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (_: string, h: () => void) => {
        eventHandler = h;
        return () => {};
      },
    );
    (GetQueue as unknown as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('ipc fail'));
    // Silence the console.error that queue.ts emits on error for cleaner test output.
    const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

    subscribeQueue(vi.fn());
    expect(() => eventHandler!()).not.toThrow();
    await new Promise((r) => setTimeout(r, 0));
    // Confirm queue.ts still logged — documented behaviour per queue.ts line 29.
    expect(consoleSpy).toHaveBeenCalled();
    consoleSpy.mockRestore();
  });
});
