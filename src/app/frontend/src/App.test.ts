// Smoke test for App.svelte. Scope is intentionally minimal per CONTEXT D-09:
// "at least a render-and-mount smoke test." Deeper App state logic (queue
// rendering, automode toggles, etc.) lands in Phase 9 tests.
import { describe, it, expect, vi } from 'vitest';

// Mock wailsjs bindings BEFORE importing App — vi.mock is hoisted.
vi.mock('../wailsjs/go/main/App', () => ({
  GetAuthStatus: vi.fn().mockResolvedValue({ authenticated: false }),
  GetQueue: vi.fn().mockResolvedValue([]),
  SignIn: vi.fn(),
  SignOut: vi.fn(),
}));
vi.mock('../wailsjs/runtime/runtime', () => ({
  EventsOn: vi.fn(() => () => {}),
}));

import { render } from '@testing-library/svelte';
import App from './App.svelte';

describe('App.svelte — smoke', () => {
  it('mounts without throwing and renders the sign-in screen when unauthenticated', async () => {
    const { findByText } = render(App);
    expect(await findByText(/Sign in with Google/i)).toBeInTheDocument();
  });
});
