import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import InstallPrompt from '../InstallPrompt';

// TSTEST-04: React Testing Library component tests for InstallPrompt.
//
// Covers the three states rendered by the component (MISSING, OUTDATED,
// ERROR) plus the ERROR-without-errorMessage degenerate case.

const EXPECTED_URL =
  'https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe';

describe('InstallPrompt (MISSING)', () => {
  it('renders the install heading', () => {
    render(<InstallPrompt state="MISSING" />);
    expect(screen.getByText('Install the go-mapi host')).toBeInTheDocument();
  });

  it('renders the download installer button', () => {
    render(<InstallPrompt state="MISSING" />);
    expect(
      screen.getByRole('button', { name: /Download installer/i }),
    ).toBeInTheDocument();
  });

  it('download button points at the stable GitHub Releases URL', () => {
    render(<InstallPrompt state="MISSING" />);
    // React Bootstrap renders <Button href=... /> as an anchor; use getByRole('button')
    // and read the href attribute directly.
    const link = screen.getByRole('button', { name: /Download installer/i });
    expect(link).toHaveAttribute('href', EXPECTED_URL);
  });

  it('renders SmartScreen guidance copy', () => {
    render(<InstallPrompt state="MISSING" />);
    // Bootstrap Alert contents — match on key substring to avoid
    // coupling to exact punctuation / markup breakdown.
    expect(screen.getByText(/Windows SmartScreen/)).toBeInTheDocument();
    expect(screen.getByText(/Windows protected your/)).toBeInTheDocument();
    expect(screen.getByText(/More info/)).toBeInTheDocument();
    expect(screen.getByText(/Run anyway/)).toBeInTheDocument();
  });
});

describe('InstallPrompt (OUTDATED)', () => {
  it('renders the update heading (dead branch in v2.0.0)', () => {
    render(<InstallPrompt state="OUTDATED" />);
    expect(screen.getByText('Update the go-mapi host')).toBeInTheDocument();
  });

  it('renders the "Download update" button label', () => {
    render(<InstallPrompt state="OUTDATED" />);
    expect(
      screen.getByRole('button', { name: /Download update/i }),
    ).toBeInTheDocument();
  });

  it('OUTDATED button still points at the same stable URL', () => {
    render(<InstallPrompt state="OUTDATED" />);
    const link = screen.getByRole('button', { name: /Download update/i });
    expect(link).toHaveAttribute('href', EXPECTED_URL);
  });
});

describe('InstallPrompt (ERROR)', () => {
  it('renders the error heading', () => {
    render(<InstallPrompt state="ERROR" errorMessage="Broken pipe" />);
    expect(screen.getByText('go-mapi host error')).toBeInTheDocument();
  });

  it('surfaces the errorMessage verbatim', () => {
    render(<InstallPrompt state="ERROR" errorMessage="Broken pipe" />);
    expect(screen.getByText('Broken pipe')).toBeInTheDocument();
  });

  it('renders the download installer button (recovery path)', () => {
    render(<InstallPrompt state="ERROR" errorMessage="Broken pipe" />);
    expect(
      screen.getByRole('button', { name: /Download installer/i }),
    ).toBeInTheDocument();
  });

  it('renders without crash when errorMessage is undefined', () => {
    // Degenerate ERROR variant — no additional error alert should render.
    render(<InstallPrompt state="ERROR" />);
    expect(screen.getByText('go-mapi host error')).toBeInTheDocument();
    // The dedicated error-message danger alert should NOT be present.
    // We assert on a substring unlikely to appear elsewhere.
    expect(screen.queryByText('undefined')).not.toBeInTheDocument();
  });
});
