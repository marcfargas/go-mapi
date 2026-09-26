import { describe, expect, it, vi } from 'vitest';
import { fireEvent, render } from '@testing-library/svelte';
import UpdatePanel from './UpdatePanel.svelte';
import type { UpdateState } from '../settings';

const { openUpdateAction } = vi.hoisted(() => ({ openUpdateAction: vi.fn() }));
vi.mock('../../../wailsjs/go/main/App', () => ({ OpenUpdateAction: openUpdateAction }));
vi.mock('../settings', () => ({ checkForUpdatesNow: vi.fn() }));

function state(overrides: Partial<UpdateState> = {}): UpdateState {
  return {
    currentVersion: '4.0.0', latestVersion: '', latestReleaseUrl: '', installerUrl: '',
    updateAvailable: false, lastCheckedAt: '', enabled: true, ...overrides,
  } as UpdateState;
}

describe('UpdatePanel channel guidance', () => {
  it('does not claim up to date before a valid response', () => {
    const { getByRole, getByText } = render(UpdatePanel, { props: { update: state({ distributionChannel: 'standalone' }), onClose: vi.fn() } });
    expect(getByRole('heading', { name: 'Update status unavailable' })).toBeInTheDocument();
    expect(getByText('No verified update result is available yet.')).toBeInTheDocument();
  });

  it('uses the fixed Store action and never presents a standalone installer', async () => {
    openUpdateAction.mockClear();
    const update = state({ latestVersion: '4.0.1', updateAvailable: true, distributionChannel: 'store',
      updateActionUrl: 'ms-windows-store://downloadsandupdates', updateActionLabel: 'Open Microsoft Store updates' });
    const { getByRole, queryByText } = render(UpdatePanel, { props: { update, onClose: vi.fn() } });
    await fireEvent.click(getByRole('button', { name: 'Open Microsoft Store updates' }));
    expect(openUpdateAction).toHaveBeenCalledOnce();
    expect(queryByText(/download and run the installer/i)).toBeNull();
  });

  it('gives machine repair guidance without a self-install action', () => {
    const update = state({ distributionChannel: 'machine', updateGuidance: 'The machine installation needs repair. Contact your administrator.' });
    const { getByText, queryByRole } = render(UpdatePanel, { props: { update, onClose: vi.fn() } });
    expect(getByText(update.updateGuidance!)).toBeInTheDocument();
    expect(queryByRole('button', { name: /check for updates now/i })).toBeNull();
    expect(queryByRole('button', { name: /open download page/i })).toBeNull();
  });

  it('shows local installed health rather than server release compatibility', () => {
    const update = state({ compatibility: 'compatible', lastSuccessfulAt: '2026-09-25T00:00:00Z' });
    const { getByText, queryByText } = render(UpdatePanel, { props: { update, componentsHealthy: false, onClose: vi.fn() } });
    expect(getByText('Need attention — see the main window')).toBeInTheDocument();
    expect(queryByText('compatible')).toBeNull();
  });
});
