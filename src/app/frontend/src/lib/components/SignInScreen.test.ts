// Component tests for SignInScreen.svelte — renders the welcome screen + sign-in button.
import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/svelte';
import SignInScreen from './SignInScreen.svelte';

describe('SignInScreen', () => {
  it('renders the welcome heading and sign-in button copy', () => {
    const onSignIn = vi.fn();
    const { getByRole, getByText } = render(SignInScreen, { props: { onSignIn } });
    expect(getByRole('heading', { level: 1 })).toHaveTextContent('go-mapi');
    expect(getByText(/Sign in with Google/i)).toBeInTheDocument();
  });

  it('calls onSignIn when the sign-in button is clicked', async () => {
    const onSignIn = vi.fn();
    const { getByRole } = render(SignInScreen, { props: { onSignIn } });
    const btn = getByRole('button', { name: /sign in with google/i });
    await fireEvent.click(btn);
    expect(onSignIn).toHaveBeenCalledOnce();
  });
});
