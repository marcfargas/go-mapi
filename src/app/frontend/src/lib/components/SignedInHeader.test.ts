// Component tests for SignedInHeader.svelte — the authenticated header with sign-out button.
// Asserts the $derived logic: email || name || 'your Google account'.
import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/svelte';
import SignedInHeader from './SignedInHeader.svelte';

describe('SignedInHeader', () => {
  it('renders email when email is present ($derived: email wins over name)', () => {
    const onSignOut = vi.fn();
    const { getByText } = render(SignedInHeader, {
      props: { email: 'a@b.com', name: 'Alice', onSignOut },
    });
    expect(getByText('a@b.com')).toBeInTheDocument();
  });

  it('falls back to name when email is empty', () => {
    const onSignOut = vi.fn();
    const { getByText } = render(SignedInHeader, {
      props: { email: '', name: 'Alice', onSignOut },
    });
    expect(getByText('Alice')).toBeInTheDocument();
  });

  it('falls back to "your Google account" when both email and name are empty', () => {
    const onSignOut = vi.fn();
    const { getByText } = render(SignedInHeader, {
      props: { email: '', name: '', onSignOut },
    });
    expect(getByText('your Google account')).toBeInTheDocument();
  });

  it('calls onSignOut when the sign-out button is clicked', async () => {
    const onSignOut = vi.fn();
    const { getByRole } = render(SignedInHeader, {
      props: { email: 'a@b.com', name: '', onSignOut },
    });
    await fireEvent.click(getByRole('button', { name: /sign out/i }));
    expect(onSignOut).toHaveBeenCalledOnce();
  });
});
