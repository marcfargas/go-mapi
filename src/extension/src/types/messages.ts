// Native Messaging protocol types

export const MSG_TYPE = {
  // Host → Extension
  EMAIL: 'email',
  REMOVED: 'removed',
  READY: 'ready',
  ERROR: 'error',
  DRAFT_CREATED: 'draft-created',
  DRAFT_ERROR: 'draft-error',
  // Extension → Host
  PROCESS: 'process',
  DELETE: 'delete',
  LIST: 'list',
  SHUTDOWN: 'shutdown',
  CREATE_DRAFT: 'create-draft',
} as const;

export interface Recipient {
  name: string;
  address: string;
}

export interface Attachment {
  filename: string;
  path: string;
  size: number;
}

export interface Recipients {
  to: Recipient[];
  cc: Recipient[];
  bcc: Recipient[];
}

export interface MailMessage {
  version: number;
  interceptorVersion?: string;
  hostVersion?: string;
  timestamp: string;
  subject: string;
  body: string;
  bodyFormat: 'plain' | 'html';
  recipients: Recipients;
  attachments: Attachment[];
  originApp: string;
}

export interface EmailWithId extends MailMessage {
  id: string;
}

// Messages from native host
export interface NativeEmailMessage {
  type: typeof MSG_TYPE.EMAIL;
  id: string;
  data: MailMessage;
}

export interface NativeRemovedMessage {
  type: typeof MSG_TYPE.REMOVED;
  id: string;
}

export interface NativeReadyMessage {
  type: typeof MSG_TYPE.READY;
  version: string; // legacy field — kept for backwards compat
  hostVersion?: string; // FOUND-02: new canonical host version field, consumed by EXT-03 in Phase 2
}

export interface NativeErrorMessage {
  type: typeof MSG_TYPE.ERROR;
  error: string;
}

export interface NativeDraftCreatedMessage {
  type: typeof MSG_TYPE.DRAFT_CREATED;
  id: string;
  draftId: string;
  gmailUrl: string;
}

export interface NativeDraftErrorMessage {
  type: typeof MSG_TYPE.DRAFT_ERROR;
  id: string;
  error: string;
}

export type NativeIncomingMessage =
  | NativeEmailMessage
  | NativeRemovedMessage
  | NativeReadyMessage
  | NativeErrorMessage
  | NativeDraftCreatedMessage
  | NativeDraftErrorMessage;

// Messages to native host
export interface NativeProcessMessage {
  type: typeof MSG_TYPE.PROCESS;
  id: string;
}

export interface NativeDeleteMessage {
  type: typeof MSG_TYPE.DELETE;
  id: string;
}

export interface NativeListMessage {
  type: typeof MSG_TYPE.LIST;
}

export interface NativeShutdownMessage {
  type: typeof MSG_TYPE.SHUTDOWN;
}

export interface NativeCreateDraftMessage {
  type: typeof MSG_TYPE.CREATE_DRAFT;
  id: string;
  token: string;
  email: MailMessage;
}

export type NativeOutgoingMessage =
  | NativeProcessMessage
  | NativeDeleteMessage
  | NativeListMessage
  | NativeShutdownMessage
  | NativeCreateDraftMessage;

// Internal extension messages (between service worker and popup)
export interface RecentDraft {
  draftId: string;
  subject: string;
  timestamp: string;
  attachmentCount: number;
  gmailUrl: string;
}

export interface ExtensionMessage {
  type: 'QUEUE_UPDATE' | 'CONNECTION_STATUS' | 'ERROR' | 'DRAFTS_UPDATE';
  emails?: EmailWithId[];
  connected?: boolean;
  error?: string;
  recentDrafts?: RecentDraft[];
}

// User settings
export interface Settings {
  defaultAction: 'draft' | 'send';
  showNotifications: boolean;
}

export const DEFAULT_SETTINGS: Settings = {
  defaultAction: 'draft',
  showNotifications: true,
};
