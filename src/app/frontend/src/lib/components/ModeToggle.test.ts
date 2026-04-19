import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/svelte';
import ModeToggle from './ModeToggle.svelte';

describe('ModeToggle', () => {
  it('renders both segment labels', () => {
    const { getByRole } = render(ModeToggle, {
      props: { mode: 'manual', onModeChange: vi.fn() },
    });
    expect(getByRole('button', { name: /manual/i })).toBeTruthy();
    expect(getByRole('button', { name: /auto-draft/i })).toBeTruthy();
  });

  it('container has role="group" + aria-label="Draft mode"', () => {
    const { getByRole } = render(ModeToggle, {
      props: { mode: 'manual', onModeChange: vi.fn() },
    });
    const group = getByRole('group', { name: /draft mode/i });
    expect(group).toBeTruthy();
  });

  it('active segment has aria-pressed=true when mode=manual', () => {
    const { getByRole } = render(ModeToggle, {
      props: { mode: 'manual', onModeChange: vi.fn() },
    });
    const manual = getByRole('button', { name: /manual/i });
    const auto = getByRole('button', { name: /auto-draft/i });
    expect(manual.getAttribute('aria-pressed')).toBe('true');
    expect(auto.getAttribute('aria-pressed')).toBe('false');
  });

  it('active segment has aria-pressed=true when mode=auto-draft', () => {
    const { getByRole } = render(ModeToggle, {
      props: { mode: 'auto-draft', onModeChange: vi.fn() },
    });
    expect(getByRole('button', { name: /manual/i }).getAttribute('aria-pressed')).toBe('false');
    expect(getByRole('button', { name: /auto-draft/i }).getAttribute('aria-pressed')).toBe('true');
  });

  it('click on inactive segment fires onModeChange with the other value', async () => {
    const onModeChange = vi.fn();
    const { getByRole } = render(ModeToggle, {
      props: { mode: 'manual', onModeChange },
    });
    await fireEvent.click(getByRole('button', { name: /auto-draft/i }));
    expect(onModeChange).toHaveBeenCalledWith('auto-draft');
    expect(onModeChange).toHaveBeenCalledOnce();
  });

  it('click on active segment does NOT fire onModeChange', async () => {
    const onModeChange = vi.fn();
    const { getByRole } = render(ModeToggle, {
      props: { mode: 'manual', onModeChange },
    });
    await fireEvent.click(getByRole('button', { name: /manual/i }));
    expect(onModeChange).not.toHaveBeenCalled();
  });

  it('clicking Auto-draft when mode=auto-draft does NOT fire onModeChange', async () => {
    const onModeChange = vi.fn();
    const { getByRole } = render(ModeToggle, {
      props: { mode: 'auto-draft', onModeChange },
    });
    await fireEvent.click(getByRole('button', { name: /auto-draft/i }));
    expect(onModeChange).not.toHaveBeenCalled();
  });
});
