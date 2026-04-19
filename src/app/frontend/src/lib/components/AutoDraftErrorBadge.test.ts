import { describe, it, expect } from 'vitest';
import { render } from '@testing-library/svelte';
import AutoDraftErrorBadge from './AutoDraftErrorBadge.svelte';

describe('AutoDraftErrorBadge', () => {
  it('renders the `!` glyph', () => {
    const { getByText } = render(AutoDraftErrorBadge, {
      props: { category: 'signed-out' },
    });
    expect(getByText('!')).toBeTruthy();
  });

  it('has role="status" and tabindex="0"', () => {
    const { getByRole } = render(AutoDraftErrorBadge, {
      props: { category: 'signed-out' },
    });
    const badge = getByRole('status');
    expect(badge.getAttribute('tabindex')).toBe('0');
  });

  it('signed-out category → title="Signed out" + aria-label contains "Signed out"', () => {
    const { getByRole } = render(AutoDraftErrorBadge, {
      props: { category: 'signed-out' },
    });
    const badge = getByRole('status');
    expect(badge.getAttribute('title')).toBe('Signed out');
    expect(badge.getAttribute('aria-label')).toContain('Signed out');
  });

  it('network category → title="Network error"', () => {
    const { getByRole } = render(AutoDraftErrorBadge, {
      props: { category: 'network' },
    });
    expect(getByRole('status').getAttribute('title')).toBe('Network error');
  });

  it('gmail category → title="Gmail error"', () => {
    const { getByRole } = render(AutoDraftErrorBadge, {
      props: { category: 'gmail' },
    });
    expect(getByRole('status').getAttribute('title')).toBe('Gmail error');
  });
});
