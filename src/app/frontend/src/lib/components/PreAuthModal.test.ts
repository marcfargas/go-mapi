// Component tests for PreAuthModal.svelte — the Google unverified-app explainer modal.
import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/svelte';
import PreAuthModal from './PreAuthModal.svelte';

describe('PreAuthModal', () => {
  it('renders the explainer copy including the Advanced + Go to go-mapi (unsafe) steps', () => {
    const onContinue = vi.fn();
    const onCancel = vi.fn();
    const { getByText } = render(PreAuthModal, { props: { onContinue, onCancel } });
    expect(getByText('Advanced')).toBeInTheDocument();
    expect(getByText('Go to go-mapi (unsafe)')).toBeInTheDocument();
  });

  it('calls onContinue when the primary button is clicked', async () => {
    const onContinue = vi.fn();
    const onCancel = vi.fn();
    const { getByRole } = render(PreAuthModal, { props: { onContinue, onCancel } });
    await fireEvent.click(getByRole('button', { name: /continue to google/i }));
    expect(onContinue).toHaveBeenCalledOnce();
    expect(onCancel).not.toHaveBeenCalled();
  });

  it('calls onCancel when the cancel button is clicked', async () => {
    const onContinue = vi.fn();
    const onCancel = vi.fn();
    const { getByRole } = render(PreAuthModal, { props: { onContinue, onCancel } });
    await fireEvent.click(getByRole('button', { name: /cancel/i }));
    expect(onCancel).toHaveBeenCalledOnce();
    expect(onContinue).not.toHaveBeenCalled();
  });
});
