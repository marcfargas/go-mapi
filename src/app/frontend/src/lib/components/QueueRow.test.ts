import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/svelte';
import QueueRow from './QueueRow.svelte';
import type { EmailWithId } from '../queue';

function mkItem(
  overrides: Partial<{
    from: { name: string; address: string };
    subject: string;
    attachments: { filename: string }[];
    timestamp: string;
  }> = {},
  id = 'abc',
): EmailWithId {
  return {
    id,
    message: {
      version: 1,
      timestamp: overrides.timestamp ?? '2026-04-19T12:00:00Z',
      bodyFormat: 'plain',
      from: overrides.from ?? { name: 'Alice', address: 'alice@example.com' },
      subject: overrides.subject ?? 'Hello',
      attachments: overrides.attachments ?? [],
    } as unknown as EmailWithId['message'],
  } as EmailWithId;
}

describe('QueueRow', () => {
  it('renders sender name', () => {
    const { getByText } = render(QueueRow, {
      props: { item: mkItem(), onCreateDraft: vi.fn(), onDismiss: vi.fn() },
    });
    expect(getByText('Alice')).toBeTruthy();
  });

  it('falls back to (unknown sender) when sender missing', () => {
    const { getByText } = render(QueueRow, {
      props: {
        item: mkItem({ from: { name: '', address: '' } }),
        onCreateDraft: vi.fn(),
        onDismiss: vi.fn(),
      },
    });
    expect(getByText('(unknown sender)')).toBeTruthy();
  });

  it('falls back to (no subject) when subject empty', () => {
    const { getByText } = render(QueueRow, {
      props: { item: mkItem({ subject: '' }), onCreateDraft: vi.fn(), onDismiss: vi.fn() },
    });
    expect(getByText('(no subject)')).toBeTruthy();
  });

  it('hides attachment count when count === 0 (D-02)', () => {
    const { queryByText } = render(QueueRow, {
      props: { item: mkItem({ attachments: [] }), onCreateDraft: vi.fn(), onDismiss: vi.fn() },
    });
    expect(queryByText(/📎/)).toBeNull();
  });

  it('shows 📎 N when attachment count > 0', () => {
    const { getByText } = render(QueueRow, {
      props: {
        item: mkItem({ attachments: [{ filename: 'a' }, { filename: 'b' }] }),
        onCreateDraft: vi.fn(),
        onDismiss: vi.fn(),
      },
    });
    expect(getByText(/📎 2/)).toBeTruthy();
  });

  it('Create draft click fires onCreateDraft with item.id', async () => {
    const onCreateDraft = vi.fn();
    const { getByRole } = render(QueueRow, {
      props: { item: mkItem({}, 'abc'), onCreateDraft, onDismiss: vi.fn() },
    });
    await fireEvent.click(getByRole('button', { name: /create draft/i }));
    expect(onCreateDraft).toHaveBeenCalledWith('abc');
  });

  it('Dismiss click fires onDismiss with item.id', async () => {
    const onDismiss = vi.fn();
    const { getByRole } = render(QueueRow, {
      props: { item: mkItem({}, 'xyz'), onCreateDraft: vi.fn(), onDismiss },
    });
    await fireEvent.click(getByRole('button', { name: /dismiss/i }));
    expect(onDismiss).toHaveBeenCalledWith('xyz');
  });

  it('state=in-flight shows Creating… label + buttons disabled', () => {
    const { getByRole, getByText } = render(QueueRow, {
      props: {
        item: mkItem(),
        state: 'in-flight',
        onCreateDraft: vi.fn(),
        onDismiss: vi.fn(),
      },
    });
    expect(getByText('Creating…')).toBeTruthy();
    const createBtn = getByRole('button', { name: /creating/i });
    expect((createBtn as HTMLButtonElement).disabled).toBe(true);
  });

  it('state=error renders AutoDraftErrorBadge with given category', () => {
    const { getByRole } = render(QueueRow, {
      props: {
        item: mkItem(),
        state: 'error',
        errorCategory: 'signed-out',
        onCreateDraft: vi.fn(),
        onDismiss: vi.fn(),
      },
    });
    expect(getByRole('status', { name: /signed out/i })).toBeTruthy();
  });

  it('state=drafted-flash shows ✓ Drafted in subject column', () => {
    const { getByText } = render(QueueRow, {
      props: {
        item: mkItem(),
        state: 'drafted-flash',
        onCreateDraft: vi.fn(),
        onDismiss: vi.fn(),
      },
    });
    expect(getByText('✓ Drafted')).toBeTruthy();
  });

  it('authenticated=false disables both buttons with title="Sign in first"', () => {
    const { getByRole } = render(QueueRow, {
      props: {
        item: mkItem(),
        authenticated: false,
        onCreateDraft: vi.fn(),
        onDismiss: vi.fn(),
      },
    });
    const create = getByRole('button', { name: /create draft/i }) as HTMLButtonElement;
    const dismiss = getByRole('button', { name: /dismiss/i }) as HTMLButtonElement;
    expect(create.disabled).toBe(true);
    expect(dismiss.disabled).toBe(true);
    expect(create.getAttribute('title')).toBe('Sign in first');
    expect(dismiss.getAttribute('title')).toBe('Sign in first');
  });

  it('row has tabindex=0 as focusable container (no onclick on li)', () => {
    const { container } = render(QueueRow, {
      props: { item: mkItem(), onCreateDraft: vi.fn(), onDismiss: vi.fn() },
    });
    const li = container.querySelector('li');
    expect(li?.getAttribute('tabindex')).toBe('0');
    // Row body is inert: no onclick attribute on the li itself
    expect(li?.getAttribute('onclick')).toBeNull();
  });
});
