package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"

	mapi "github.com/marcfargas/go-mapi/native-host/internal/mapi"
)

// Message types for Native Messaging protocol
const (
	MsgTypeEmail    = "email"    // Host → Extension: new email detected
	MsgTypeRemoved  = "removed"  // Host → Extension: email file removed
	MsgTypeReady    = "ready"    // Host → Extension: host is ready
	MsgTypeError    = "error"    // Host → Extension: error occurred
	MsgTypeProcess  = "process"  // Extension → Host: mark as processed
	MsgTypeDelete   = "delete"   // Extension → Host: delete email
	MsgTypeList     = "list"     // Extension → Host: request current emails
	MsgTypeShutdown = "shutdown" // Extension → Host: graceful shutdown

	// Draft creation — Go builds full MIME (with attachments) and creates via Gmail API
	MsgTypeCreateDraft  = "create-draft"  // Extension → Host: create draft
	MsgTypeDraftCreated = "draft-created" // Host → Extension: draft created
	MsgTypeDraftError   = "draft-error"   // Host → Extension: draft creation failed
)

// OutgoingMessage is sent from host to extension
type OutgoingMessage struct {
	Type        string            `json:"type"`
	ID          string            `json:"id,omitempty"`
	Data        *mapi.MailMessage `json:"data,omitempty"`
	Error       string            `json:"error,omitempty"`
	Version     string            `json:"version,omitempty"`     // legacy field — kept for backwards compat, do not remove
	HostVersion string            `json:"hostVersion,omitempty"` // FOUND-02: new canonical host version field

	// Draft creation response
	DraftID  string `json:"draftId,omitempty"`
	GmailURL string `json:"gmailUrl,omitempty"`
}

// IncomingMessage is received from extension
type IncomingMessage struct {
	Type string `json:"type"`
	ID   string `json:"id,omitempty"`

	// create-draft fields
	Token string            `json:"token,omitempty"`
	Email *mapi.MailMessage `json:"email,omitempty"`
}

// NativeMessaging handles Chrome Native Messaging protocol
// Protocol: 4-byte length prefix (little-endian) + JSON message
type NativeMessaging struct {
	reader io.Reader
	writer io.Writer
}

// NewNativeMessaging creates a new Native Messaging handler
func NewNativeMessaging() *NativeMessaging {
	return &NativeMessaging{
		reader: os.Stdin,
		writer: os.Stdout,
	}
}

// Read reads a message from the extension
func (nm *NativeMessaging) Read() (*IncomingMessage, error) {
	// Read 4-byte length prefix (little-endian)
	var length uint32
	if err := binary.Read(nm.reader, binary.LittleEndian, &length); err != nil {
		if err == io.EOF {
			return nil, err
		}
		return nil, fmt.Errorf("failed to read message length: %w", err)
	}

	// Sanity check: max message size 1MB
	if length > 1024*1024 {
		return nil, fmt.Errorf("message too large: %d bytes", length)
	}

	// Read message body
	body := make([]byte, length)
	if _, err := io.ReadFull(nm.reader, body); err != nil {
		return nil, fmt.Errorf("failed to read message body: %w", err)
	}

	// Parse JSON
	var msg IncomingMessage
	if err := json.Unmarshal(body, &msg); err != nil {
		return nil, fmt.Errorf("failed to parse message: %w", err)
	}

	return &msg, nil
}

// Write sends a message to the extension
func (nm *NativeMessaging) Write(msg *OutgoingMessage) error {
	// Serialize to JSON
	body, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to serialize message: %w", err)
	}

	// Write 4-byte length prefix (little-endian)
	length := uint32(len(body))
	if err := binary.Write(nm.writer, binary.LittleEndian, length); err != nil {
		return fmt.Errorf("failed to write message length: %w", err)
	}

	// Write message body
	if _, err := nm.writer.Write(body); err != nil {
		return fmt.Errorf("failed to write message body: %w", err)
	}

	return nil
}

// SendEmail sends an email message to the extension
func (nm *NativeMessaging) SendEmail(id string, mail *mapi.MailMessage) error {
	return nm.Write(&OutgoingMessage{
		Type: MsgTypeEmail,
		ID:   id,
		Data: mail,
	})
}

// SendRemoved notifies extension that an email was removed
func (nm *NativeMessaging) SendRemoved(id string) error {
	return nm.Write(&OutgoingMessage{
		Type: MsgTypeRemoved,
		ID:   id,
	})
}

// SendReady notifies extension that host is ready
func (nm *NativeMessaging) SendReady(version string) error {
	return nm.Write(&OutgoingMessage{
		Type:        MsgTypeReady,
		Version:     version, // legacy field — kept for backwards compat
		HostVersion: version, // FOUND-02: new canonical field, consumed by Phase 2 EXT-03
	})
}

// SendError sends an error message to the extension
func (nm *NativeMessaging) SendError(errMsg string) error {
	return nm.Write(&OutgoingMessage{
		Type:  MsgTypeError,
		Error: errMsg,
	})
}

// SendDraftCreated notifies extension that a draft was created
func (nm *NativeMessaging) SendDraftCreated(emailID string, draftID string, gmailURL string) error {
	return nm.Write(&OutgoingMessage{
		Type:     MsgTypeDraftCreated,
		ID:       emailID,
		DraftID:  draftID,
		GmailURL: gmailURL,
	})
}

// SendDraftError notifies extension that draft creation failed
func (nm *NativeMessaging) SendDraftError(emailID string, errMsg string) error {
	return nm.Write(&OutgoingMessage{
		Type:  MsgTypeDraftError,
		ID:    emailID,
		Error: errMsg,
	})
}

// nativeMessagingAdapter implements mapi.WatcherCallback, bridging watcher
// events to native-messaging frames sent to the Chrome extension.
//
// The legacy wire protocol sends one frame per changed item (not per-snapshot),
// preserving the existing Extension ↔ Host contract:
//   - New ID in snapshot → SendEmail (added)
//   - ID absent from snapshot → SendRemoved (deleted/processed)
type nativeMessagingAdapter struct {
	nm      *NativeMessaging
	mu      sync.Mutex
	prevIDs map[string]struct{} // IDs seen in the last snapshot
}

func newNativeMessagingAdapter(nm *NativeMessaging) *nativeMessagingAdapter {
	return &nativeMessagingAdapter{
		nm:      nm,
		prevIDs: make(map[string]struct{}),
	}
}

func (a *nativeMessagingAdapter) OnQueueChanged(snapshot []mapi.EmailWithId) {
	a.mu.Lock()
	defer a.mu.Unlock()

	// Build current ID set
	currentIDs := make(map[string]struct{}, len(snapshot))
	for _, e := range snapshot {
		currentIDs[e.Id] = struct{}{}
	}

	// Send removed notifications for IDs that disappeared
	for id := range a.prevIDs {
		if _, found := currentIDs[id]; !found {
			_ = a.nm.SendRemoved(id)
		}
	}

	// Send email notifications for IDs that are new
	for _, e := range snapshot {
		if _, seen := a.prevIDs[e.Id]; !seen {
			// Stamp host version before sending (was done in watcher.processFile
			// previously; now the adapter is responsible since internal/mapi
			// does not have access to the Version variable).
			e.Message.HostVersion = Version
			_ = a.nm.SendEmail(e.Id, e.Message)
		}
	}

	a.prevIDs = currentIDs
}

func (a *nativeMessagingAdapter) OnError(err error) {
	_ = a.nm.SendError(err.Error())
}

