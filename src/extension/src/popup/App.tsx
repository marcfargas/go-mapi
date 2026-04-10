import { useState, useEffect, useCallback } from 'react';
import { Alert, Spinner } from 'react-bootstrap';
import EmailList from './EmailList';
import EmailDetail from './EmailDetail';
import InstallPrompt from './InstallPrompt';
import type { EmailWithId, ExtensionMessage, RecentDraft } from '../types/messages';
import type { HostState } from '../lib/hostDetector';

interface AppState {
  emails: EmailWithId[];
  recentDrafts: RecentDraft[];
  selectedEmail: EmailWithId | null;
  connected: boolean;
  loading: boolean;
  error: string | null;
  sending: boolean;
  // EXT-04: host detector state, broadcast from the service worker.
  hostState: HostState;
  hostErrorMessage: string | null;
}

export default function App() {
  const [state, setState] = useState<AppState>({
    emails: [],
    recentDrafts: [],
    selectedEmail: null,
    connected: false,
    loading: true,
    error: null,
    sending: false,
    hostState: 'UNKNOWN',
    hostErrorMessage: null,
  });

  // Load initial data
  useEffect(() => {
    chrome.runtime.sendMessage({ action: 'getEmails' }, (response) => {
      if (response?.success) {
        setState((s) => ({
          ...s,
          emails: response.emails || [],
          recentDrafts: response.recentDrafts || [],
          connected: response.connected || false,
          loading: false,
        }));
      } else {
        setState((s) => ({
          ...s,
          loading: false,
          error: response?.error || 'Failed to load emails',
        }));
      }
    });
  }, []);

  // Listen for updates from service worker
  useEffect(() => {
    const listener = (message: ExtensionMessage) => {
      switch (message.type) {
        case 'QUEUE_UPDATE':
          setState((s) => {
            const newState = { ...s, emails: message.emails || [] };
            if (s.selectedEmail && !message.emails?.find((e) => e.id === s.selectedEmail?.id)) {
              newState.selectedEmail = null;
            }
            return newState;
          });
          break;
        case 'DRAFTS_UPDATE':
          setState((s) => ({ ...s, recentDrafts: message.recentDrafts || [] }));
          break;
        case 'CONNECTION_STATUS':
          setState((s) => ({
            ...s,
            connected: message.connected || false,
            error: message.error || null,
          }));
          break;
        case 'ERROR':
          setState((s) => ({ ...s, error: message.error || null }));
          break;
        case 'HOST_STATE':
          setState((s) => ({
            ...s,
            hostState: message.state,
            hostErrorMessage: message.errorMessage ?? null,
          }));
          break;
      }
    };

    chrome.runtime.onMessage.addListener(listener);
    return () => chrome.runtime.onMessage.removeListener(listener);
  }, []);

  const handleSelect = useCallback((email: EmailWithId) => {
    setState((s) => ({ ...s, selectedEmail: email }));
  }, []);

  const handleBack = useCallback(() => {
    setState((s) => ({ ...s, selectedEmail: null }));
  }, []);

  const handleCreateDraft = useCallback(async () => {
    if (!state.selectedEmail) return;
    setState((s) => ({ ...s, sending: true, error: null }));
    chrome.runtime.sendMessage(
      { action: 'createDraft', id: state.selectedEmail.id },
      (response) => {
        setState((s) => ({ ...s, sending: false }));
        if (!response?.success) {
          setState((s) => ({ ...s, error: response?.error || 'Failed to create draft' }));
        }
      }
    );
  }, [state.selectedEmail]);

  const handleDelete = useCallback(async () => {
    if (!state.selectedEmail) return;
    chrome.runtime.sendMessage(
      { action: 'deleteEmail', id: state.selectedEmail.id },
      (response) => {
        if (!response?.success) {
          setState((s) => ({ ...s, error: response?.error || 'Failed to delete email' }));
        } else {
          setState((s) => ({ ...s, selectedEmail: null }));
        }
      }
    );
  }, [state.selectedEmail]);

  const handleReconnect = useCallback(() => {
    setState((s) => ({ ...s, error: null }));
    chrome.runtime.sendMessage({ action: 'reconnect' });
  }, []);

  const handleClearDrafts = useCallback(() => {
    chrome.runtime.sendMessage({ action: 'clearDrafts' });
    setState((s) => ({ ...s, recentDrafts: [] }));
  }, []);

  const handleOpenDraft = useCallback((gmailUrl: string) => {
    chrome.tabs.create({ url: gmailUrl });
  }, []);

  // EXT-05: show the install prompt when the host detector reports that the
  // native host is unreachable. The main queue UI (Pending list, Recent
  // Drafts, empty state) is suppressed in these states so the banner is the
  // only thing the user sees.
  const showInstallPrompt =
    !state.loading &&
    (state.hostState === 'MISSING' ||
      state.hostState === 'ERROR' ||
      state.hostState === 'OUTDATED');

  return (
    <div className="app-container">
      <header className="app-header">
        <h1>go-mapi</h1>
        <div className="status">
          <span className={`status-dot ${state.connected ? 'connected' : 'disconnected'}`} />
          {state.connected ? 'Connected' : 'Disconnected'}
        </div>
      </header>

      {state.error && (
        <Alert
          variant="danger"
          className="error-alert"
          dismissible
          onClose={() => setState((s) => ({ ...s, error: null }))}
        >
          {state.error}
          {!state.connected && (
            <button className="btn btn-link btn-sm p-0 ms-2" onClick={handleReconnect}>
              Retry
            </button>
          )}
        </Alert>
      )}

      <div className="content">
        {showInstallPrompt ? (
          <InstallPrompt
            state={state.hostState}
            errorMessage={state.hostErrorMessage ?? undefined}
          />
        ) : state.loading ? (
          <div className="loading">
            <Spinner animation="border" variant="primary" />
          </div>
        ) : state.selectedEmail ? (
          <EmailDetail
            email={state.selectedEmail}
            onBack={handleBack}
            onCreateDraft={handleCreateDraft}
            onDelete={handleDelete}
            sending={state.sending}
          />
        ) : state.emails.length > 0 ? (
          <>
            <div className="section-label">Pending</div>
            <EmailList emails={state.emails} onSelect={handleSelect} />
          </>
        ) : null}

        {/* Recent drafts */}
        {!showInstallPrompt && !state.selectedEmail && state.recentDrafts.length > 0 && (
          <>
            <div className="section-label" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span>Recent Drafts</span>
              <button
                className="btn btn-link btn-sm p-0"
                onClick={handleClearDrafts}
                style={{ fontSize: '0.7rem' }}
              >
                Clear
              </button>
            </div>
            <ul className="email-list">
              {state.recentDrafts.map((draft) => (
                <li
                  key={draft.draftId}
                  className="email-item"
                  onClick={() => handleOpenDraft(draft.gmailUrl)}
                >
                  <div className="email-subject">{draft.subject}</div>
                  <div className="email-meta">
                    <span>{formatTime(draft.timestamp)}</span>
                    {draft.attachmentCount > 0 && (
                      <span className="attachment-badge">
                        <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                          <path d="M21.44 11.05l-9.19 9.19a6 6 0 01-8.49-8.49l9.19-9.19a4 4 0 015.66 5.66l-9.2 9.19a2 2 0 01-2.83-2.83l8.49-8.48" />
                        </svg>
                        {draft.attachmentCount}
                      </span>
                    )}
                    <span style={{ color: '#198754', fontSize: '0.75rem' }}>Open in Gmail ↗</span>
                  </div>
                </li>
              ))}
            </ul>
          </>
        )}

        {/* Empty state */}
        {!showInstallPrompt && !state.selectedEmail && state.emails.length === 0 && state.recentDrafts.length === 0 && (
          <div className="empty-state">
            <svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
              <path d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z" />
            </svg>
            <h3>No pending emails</h3>
            <p>
              Use "Send to → Mail recipient" in Windows Explorer
              <br />
              to create Gmail drafts
            </p>
          </div>
        )}
      </div>
    </div>
  );
}

function formatTime(timestamp: string): string {
  try {
    const date = new Date(timestamp);
    const now = new Date();
    const diff = now.getTime() - date.getTime();
    if (diff < 60000) return 'Just now';
    if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`;
    if (diff < 86400000) return `${Math.floor(diff / 3600000)}h ago`;
    return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  } catch {
    return '';
  }
}
