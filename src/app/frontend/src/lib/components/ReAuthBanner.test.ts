// Component tests for ReAuthBanner.svelte — shown when auth transitions signed-in → signed-out.
import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/svelte';
import ReAuthBanner from './ReAuthBanner.svelte';

describe('ReAuthBanner', () => {
  it('renders with role="alert" and surfaces the sign-in expired copy', () => {
    const onRestore = vi.fn();
    const { getByRole, getByText } = render(ReAuthBanner, { props: { onRestore } });
    expect(getByRole('alert')).toBeInTheDocument();
    expect(getByText(/sign-in expired/i)).toBeInTheDocument();
  });

  it('calls onRestore when the "Sign in again" button is clicked', async () => {
    const onRestore = vi.fn();
    const { getByRole } = render(ReAuthBanner, { props: { onRestore } });
    await fireEvent.click(getByRole('button', { name: /sign in again/i }));
    expect(onRestore).toHaveBeenCalledOnce();
  });
});
