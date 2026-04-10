import { Card, Button, Alert } from 'react-bootstrap';
import type { HostState } from '../lib/hostDetector';

// EXT-07: swap in Phase 3 when the real installer URL is published to GitHub Releases.
// Placeholder matches the planned final URL so Phase 3 only changes the value if the
// URL format changes — no string wrangling elsewhere in the codebase.
const INSTALLER_DOWNLOAD_URL =
  'https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe';

interface InstallPromptProps {
  state: HostState;
  errorMessage?: string;
}

/**
 * InstallPrompt (EXT-05) — rendered when the host detector reports that the
 * native messaging host is not available. Covers three variants:
 *
 *   MISSING  — classified from the "Specified native messaging host not found"
 *              substring. Standard happy-path for a first-time user.
 *   OUTDATED — dead branch in v2.0.0 (min supported version equals current).
 *              Kept wired so v3.0.0 activation needs no component change.
 *   ERROR    — any other chrome.runtime.lastError value. Copy nudges the
 *              user to reinstall and surfaces the verbatim error underneath.
 *
 * React Bootstrap only — no new CSS rules, keeps bundle and review surface small.
 * English-only copy per the external-project i18n rule.
 */
export default function InstallPrompt({ state, errorMessage }: InstallPromptProps) {
  const isOutdated = state === 'OUTDATED';
  const isError = state === 'ERROR';

  const heading = isOutdated
    ? 'Update the go-mapi host'
    : isError
      ? 'go-mapi host error'
      : 'Install the go-mapi host';

  const explanation = isOutdated
    ? 'Your installed go-mapi host is older than this extension expects. Download the latest installer to update.'
    : isError
      ? 'The extension could not connect to the go-mapi host. Reinstall the host, or check the service worker log for details.'
      : 'go-mapi needs a small Windows helper to route "Send to Mail recipient" into Gmail. Download and install it to get started.';

  const buttonLabel = isOutdated ? 'Download update' : 'Download installer';

  return (
    <Card className="install-prompt" body>
      <h5 className="mb-2">{heading}</h5>
      <p className="mb-3" style={{ fontSize: '0.85rem' }}>
        {explanation}
      </p>

      <div className="d-grid mb-3">
        <Button
          variant="primary"
          href={INSTALLER_DOWNLOAD_URL}
          target="_blank"
          rel="noopener noreferrer"
        >
          {buttonLabel}
        </Button>
      </div>

      <Alert variant="warning" className="mb-0" style={{ fontSize: '0.75rem' }}>
        <strong>Windows SmartScreen:</strong> you may see a &quot;Windows protected your
        PC&quot; prompt on the downloaded installer. Click <em>More info</em> then{' '}
        <em>Run anyway</em> to continue.
      </Alert>

      {isError && errorMessage && (
        <Alert variant="danger" className="mt-2 mb-0" style={{ fontSize: '0.7rem' }}>
          {errorMessage}
        </Alert>
      )}
    </Card>
  );
}
