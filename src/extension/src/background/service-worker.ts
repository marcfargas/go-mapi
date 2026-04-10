import {
  MSG_TYPE,
  type NativeIncomingMessage,
  type NativeOutgoingMessage,
  type EmailWithId,
  type ExtensionMessage,
  type RecentDraft,
} from '../types/messages';
import {
  classifyLastError,
  classifyReadyMessage,
  type HostState,
} from '../lib/hostDetector';

const NATIVE_HOST = 'com.gomapi.host';
const RECONNECT_ALARM = 'reconnect';

// State
let nativePort: chrome.runtime.Port | null = null;
let emails: Map<string, EmailWithId> = new Map();
let isConnected = false;
let hostVersion = '';

// EXT-04: host detector state machine. The classifiers in lib/hostDetector own
// the logic; this service worker owns the variable and the broadcast lifecycle.
let hostState: HostState = 'UNKNOWN';
let hostErrorMessage: string | undefined;
// EXT-06: one-time success toast flag on the MISSING → READY edge. Persisted
// in chrome.storage.session so it survives service worker sleep/wake but
// resets cleanly on browser restart (acceptable per D-18).
let hasShownInstalledToast = false;

// Recent drafts shown in popup
let recentDrafts: RecentDraft[] = [];

// --- Persistence helpers ---

async function persistEmails() {
  const obj: Record<string, EmailWithId> = {};
  for (const [k, v] of emails) obj[k] = v;
  await chrome.storage.session.set({ emails: obj });
}

async function persistDrafts() {
  if (recentDrafts.length > 20) recentDrafts = recentDrafts.slice(0, 20);
  await chrome.storage.session.set({ recentDrafts });
}

async function loadState() {
  const result = await chrome.storage.session.get([
    'emails',
    'recentDrafts',
    'hasShownInstalledToast',
  ]);
  if (result.emails) emails = new Map(Object.entries(result.emails as Record<string, EmailWithId>));
  if (result.recentDrafts) recentDrafts = result.recentDrafts as RecentDraft[];
  if (result.hasShownInstalledToast === true) hasShownInstalledToast = true;
}

// EXT-06: persist the one-time toast flag so it survives service worker
// sleep/wake within a browser session.
async function persistInstalledToastFlag() {
  await chrome.storage.session.set({ hasShownInstalledToast });
}

// Badge: red = pending emails, blue = drafts ready, empty = idle
function updateBadge() {
  const pending = emails.size;
  if (pending > 0) {
    chrome.action.setBadgeText({ text: String(pending) });
    chrome.action.setBadgeBackgroundColor({ color: '#dc3545' });
  } else if (recentDrafts.length > 0) {
    chrome.action.setBadgeText({ text: String(recentDrafts.length) });
    chrome.action.setBadgeBackgroundColor({ color: '#0d6efd' });
  } else {
    chrome.action.setBadgeText({ text: '' });
  }
}

function broadcastToPopup(message: ExtensionMessage) {
  chrome.runtime.sendMessage(message).catch(() => {});
}

// EXT-04: transition the host detector state machine and broadcast the new
// state to the popup. The popup subscribes to HOST_STATE via its existing
// chrome.runtime.onMessage listener. No-op when the target state and error
// message are both unchanged.
//
// EXT-06: on the MISSING → READY edge, fire a one-time HOST_INSTALLED_TOAST
// broadcast so the popup (if open) can render a success toast. The flag is
// persisted via chrome.storage.session so it only fires once per browser
// session even if the service worker sleeps and wakes between transitions.
function transitionHostState(
  next: HostState,
  opts: { errorMessage?: string } = {}
) {
  if (next === hostState && opts.errorMessage === hostErrorMessage) return;
  const prev = hostState;
  hostState = next;
  hostErrorMessage = opts.errorMessage;
  console.log('[go-mapi] hostState →', next, opts);
  broadcastToPopup({
    type: 'HOST_STATE',
    state: next,
    hostVersion: hostVersion || undefined,
    errorMessage: opts.errorMessage,
  });
  if (prev === 'MISSING' && next === 'READY' && !hasShownInstalledToast) {
    hasShownInstalledToast = true;
    persistInstalledToastFlag();
    broadcastToPopup({ type: 'HOST_INSTALLED_TOAST' });
  }
}

// --- Native host connection ---

function connectToNativeHost() {
  if (nativePort) return;

  console.log('[go-mapi] Connecting to native host...');
  transitionHostState('PROBING');
  try {
    nativePort = chrome.runtime.connectNative(NATIVE_HOST);

    nativePort.onMessage.addListener((message: NativeIncomingMessage) => {
      console.log('[go-mapi] Received:', message);
      handleNativeMessage(message);
    });

    nativePort.onDisconnect.addListener(() => {
      // EXT-02: log the verbatim lastError message for forward compatibility
      // with future Chrome phrasing changes, then classify it into a HostState.
      const lastError = chrome.runtime.lastError?.message || 'Unknown error';
      console.log('[go-mapi] Disconnected:', lastError);
      nativePort = null;
      isConnected = false;
      const classified = classifyLastError(lastError);
      transitionHostState(classified, { errorMessage: lastError });
      // Legacy CONNECTION_STATUS broadcast preserved so existing popup code
      // that reads `state.connected` continues to work unchanged.
      broadcastToPopup({ type: 'CONNECTION_STATUS', connected: false, error: lastError });
      chrome.alarms.create(RECONNECT_ALARM, { delayInMinutes: 0.1 });
    });
  } catch (error) {
    console.error('[go-mapi] Failed to connect:', error);
    isConnected = false;
    transitionHostState('ERROR', { errorMessage: String(error) });
    broadcastToPopup({ type: 'CONNECTION_STATUS', connected: false, error: String(error) });
  }
}

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONNECT_ALARM && !nativePort) connectToNativeHost();
});

function sendToNativeHost(message: NativeOutgoingMessage) {
  if (!nativePort) {
    console.warn('[go-mapi] Not connected to native host');
    return;
  }
  console.log('[go-mapi] Sending:', message);
  nativePort.postMessage(message);
}

// --- Handle native host messages ---

function handleNativeMessage(message: NativeIncomingMessage) {
  switch (message.type) {
    case MSG_TYPE.READY: {
      isConnected = true;
      // Prefer the new canonical hostVersion field (FOUND-02) but fall back
      // to the legacy top-level `version` field per Phase 1 handoff decision #1.
      hostVersion = message.hostVersion || message.version;
      console.log('[go-mapi] Host ready, version:', hostVersion);
      // EXT-04 / D-03: only transition to READY on actual NativeReadyMessage
      // arrival — a successful connectNative call alone is not enough.
      const readyState = classifyReadyMessage(hostVersion);
      transitionHostState(readyState, { errorMessage: undefined });
      broadcastToPopup({ type: 'CONNECTION_STATUS', connected: true });
      sendToNativeHost({ type: MSG_TYPE.LIST });
      break;
    }

    case MSG_TYPE.EMAIL: {
      const emailWithId: EmailWithId = { ...message.data, id: message.id };
      emails.set(message.id, emailWithId);
      persistEmails();
      updateBadge();
      broadcastToPopup({ type: 'QUEUE_UPDATE', emails: Array.from(emails.values()) });
      autoCreateDraft(emailWithId);
      break;
    }

    case MSG_TYPE.REMOVED:
      emails.delete(message.id);
      persistEmails();
      updateBadge();
      broadcastToPopup({ type: 'QUEUE_UPDATE', emails: Array.from(emails.values()) });
      break;

    case MSG_TYPE.DRAFT_CREATED: {
      // Go created the draft (with attachments) — record it
      const email = emails.get(message.id);
      const subject = email?.subject || '(No Subject)';
      const attachCount = email?.attachments?.length || 0;

      // Move JSON to processed
      sendToNativeHost({ type: MSG_TYPE.PROCESS, id: message.id });
      emails.delete(message.id);
      persistEmails();

      recentDrafts.unshift({
        draftId: message.draftId,
        subject,
        timestamp: new Date().toISOString(),
        attachmentCount: attachCount,
        gmailUrl: message.gmailUrl,
      });
      persistDrafts();
      updateBadge();
      broadcastToPopup({ type: 'DRAFTS_UPDATE', recentDrafts });
      broadcastToPopup({ type: 'QUEUE_UPDATE', emails: Array.from(emails.values()) });

      // Desktop notification
      const attachText = attachCount > 0 ? ` (${attachCount} file${attachCount > 1 ? 's' : ''})` : '';
      chrome.notifications.create(`draft:${message.draftId}`, {
        type: 'basic',
        iconUrl: 'icons/icon128.png',
        title: 'go-mapi: Draft created',
        message: `${subject}${attachText}`,
        priority: 2,
      });
      break;
    }

    case MSG_TYPE.DRAFT_ERROR: {
      console.error('[go-mapi] Draft error:', message.error);
      const email = emails.get(message.id);
      chrome.notifications.create(`error:${message.id}`, {
        type: 'basic',
        iconUrl: 'icons/icon128.png',
        title: 'go-mapi: Draft failed',
        message: `${email?.subject || '(No Subject)'}: ${message.error}`,
        priority: 2,
      });
      broadcastToPopup({ type: 'ERROR', error: message.error });
      break;
    }

    case MSG_TYPE.ERROR:
      console.error('[go-mapi] Host error:', message.error);
      broadcastToPopup({ type: 'ERROR', error: message.error });
      break;
  }
}

// --- Auto-draft: get token, send email to Go host ---

async function autoCreateDraft(email: EmailWithId) {
  try {
    // Try non-interactive auth first
    let token: string;
    try {
      token = await new Promise<string>((resolve, reject) => {
        chrome.identity.getAuthToken({ interactive: false }, (t) => {
          if (chrome.runtime.lastError || !t) {
            reject(new Error(chrome.runtime.lastError?.message || 'Not signed in'));
          } else {
            resolve(t);
          }
        });
      });
    } catch {
      // Not signed in — show notification
      chrome.notifications.create(`auth:${email.id}`, {
        type: 'basic',
        iconUrl: 'icons/icon128.png',
        title: 'go-mapi: Sign in required',
        message: `Click to sign in and create draft for: ${email.subject || '(No Subject)'}`,
        priority: 2,
      });
      return;
    }

    // Send everything to Go — it builds MIME and creates draft in one API call
    sendToNativeHost({
      type: MSG_TYPE.CREATE_DRAFT,
      id: email.id,
      token,
      email,
    });
  } catch (error) {
    console.error('[go-mapi] Auto-draft failed:', error);
    chrome.notifications.create(`error:${email.id}`, {
      type: 'basic',
      iconUrl: 'icons/icon128.png',
      title: 'go-mapi: Draft failed',
      message: `${email.subject || '(No Subject)'}: ${error}`,
      priority: 2,
    });
  }
}

// --- Notification clicks ---

chrome.notifications.onClicked.addListener((notificationId) => {
  if (notificationId.startsWith('draft:')) {
    const draftId = notificationId.slice('draft:'.length);
    chrome.tabs.create({
      url: `https://mail.google.com/mail/u/0/#drafts?compose=${draftId}`,
    });
    chrome.notifications.clear(notificationId);
  } else if (notificationId.startsWith('auth:')) {
    chrome.identity.getAuthToken({ interactive: true }, (token) => {
      if (token) {
        for (const email of emails.values()) {
          autoCreateDraft(email);
        }
      }
    });
    chrome.notifications.clear(notificationId);
  }
});

// --- Popup message handlers ---

chrome.runtime.onMessage.addListener((request, _sender, sendResponse) => {
  console.log('[go-mapi] Popup message:', request);

  (async () => {
    try {
      switch (request.action) {
        case 'getEmails':
          sendResponse({
            success: true,
            emails: Array.from(emails.values()),
            connected: isConnected,
            recentDrafts,
          });
          break;

        case 'clearDrafts':
          recentDrafts = [];
          persistDrafts();
          updateBadge();
          sendResponse({ success: true });
          break;

        case 'createDraft': {
          const email = emails.get(request.id);
          if (!email) {
            sendResponse({ success: false, error: 'Email not found' });
            return;
          }
          // Get token and delegate to Go
          const token = await new Promise<string>((resolve, reject) => {
            chrome.identity.getAuthToken({ interactive: true }, (t) => {
              if (chrome.runtime.lastError || !t) reject(new Error(chrome.runtime.lastError?.message || 'Auth failed'));
              else resolve(t);
            });
          });
          sendToNativeHost({ type: MSG_TYPE.CREATE_DRAFT, id: request.id, token, email });
          sendResponse({ success: true });
          break;
        }

        case 'deleteEmail':
          sendToNativeHost({ type: MSG_TYPE.DELETE, id: request.id });
          sendResponse({ success: true });
          break;

        case 'reconnect':
          if (!nativePort) connectToNativeHost();
          sendResponse({ success: true });
          break;

        default:
          sendResponse({ success: false, error: 'Unknown action' });
      }
    } catch (error) {
      console.error('[go-mapi] Error:', error);
      sendResponse({ success: false, error: String(error) });
    }
  })();

  return true;
});

// --- Initialize ---

console.log('[go-mapi] Service worker starting');
loadState().then(() => {
  updateBadge();
  connectToNativeHost();
});
