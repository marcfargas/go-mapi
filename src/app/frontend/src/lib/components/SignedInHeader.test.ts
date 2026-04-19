// Component tests for SignedInHeader.svelte — the authenticated header with sign-out button.
// Asserts the $derived logic: email || name || 'your Google account'.
import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/svelte';
import SignedInHeader from './SignedInHeader.svelte';

describe('SignedInHeader', () => {
  it('renders email when email is present ($derived: email wins over name)', () => {
    const onSignOut = vi.fn();
    const { getByText } = render(SignedInHeader, {
      props: { email: 'a@b.com', name: 'Alice', onSignOut, mode: 'manual', onModeChange: vi.fn() },
    });
    expect(getByText('a@b.com')).toBeInTheDocument();
  });

  it('falls back to name when email is empty', () => {
    const onSignOut = vi.fn();
    const { getByText } = render(SignedInHeader, {
      props: { email: '', name: 'Alice', onSignOut, mode: 'manual', onModeChange: vi.fn() },
    });
    expect(getByText('Alice')).toBeInTheDocument();
  });

  it('falls back to "your Google account" when both email and name are empty', () => {
    const onSignOut = vi.fn();
    const { getByText } = render(SignedInHeader, {
      props: { email: '', name: '', onSignOut, mode: 'manual', onModeChange: vi.fn() },
    });
    expect(getByText('your Google account')).toBeInTheDocument();
  });

  it('calls onSignOut when the sign-out button is clicked', async () => {
    const onSignOut = vi.fn();
    const { getByRole } = render(SignedInHeader, {
      props: { email: 'a@b.com', name: '', onSignOut, mode: 'manual', onModeChange: vi.fn() },
    });
    await fireEvent.click(getByRole('button', { name: /sign out/i }));
    expect(onSignOut).toHaveBeenCalledOnce();
  });

  it('renders the ModeToggle (role=group aria-label="Draft mode")', () => {
    const { getByRole } = render(SignedInHeader, {
      props: {
        email: 'marc@example.com',
        name: 'Marc',
        onSignOut: vi.fn(),
        mode: 'manual',
        onModeChange: vi.fn(),
      },
    });
    expect(getByRole('group', { name: /draft mode/i })).toBeTruthy();
  });

  it('forwards mode-toggle clicks to onModeChange', async () => {
    const onModeChange = vi.fn();
    const { getByRole } = render(SignedInHeader, {
      props: {
        email: 'marc@example.com',
        name: 'Marc',
        onSignOut: vi.fn(),
        mode: 'manual',
        onModeChange,
      },
    });
    await fireEvent.click(getByRole('button', { name: /auto-draft/i }));
    expect(onModeChange).toHaveBeenCalledWith('auto-draft');
  });
});
