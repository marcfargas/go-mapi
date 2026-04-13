package mapi

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/marcfargas/go-mapi/internal/mapi/testutil"
)

// TestProtocolFixtures_MailMessage validates that MailMessage JSON parsing from
// shared protocol fixtures works correctly. This tests the data types in
// internal/mapi independently of the native-messaging framing layer.

func TestFixture_MailMessage_Fields(t *testing.T) {
	data, err := os.ReadFile(testutil.FixturePath("email-message.json"))
	if err != nil {
		t.Fatalf("failed to load fixture: %v", err)
	}

	// The fixture is an OutgoingMessage envelope; extract the data field.
	var envelope struct {
		Type string       `json:"type"`
		ID   string       `json:"id"`
		Data *MailMessage `json:"data"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		t.Fatalf("failed to parse fixture: %v", err)
	}

	if envelope.Data == nil {
		t.Fatal("data is nil")
	}
	if envelope.Data.Subject != "Test Email Subject" {
		t.Errorf("subject = %v, want %v", envelope.Data.Subject, "Test Email Subject")
	}
	if envelope.Data.BodyFormat != "plain" {
		t.Errorf("bodyFormat = %v, want %v", envelope.Data.BodyFormat, "plain")
	}
	if len(envelope.Data.Recipients.To) != 1 {
		t.Errorf("to recipients count = %v, want 1", len(envelope.Data.Recipients.To))
	}
	if len(envelope.Data.Recipients.CC) != 1 {
		t.Errorf("cc recipients count = %v, want 1", len(envelope.Data.Recipients.CC))
	}
	if len(envelope.Data.Attachments) != 1 {
		t.Errorf("attachments count = %v, want 1", len(envelope.Data.Attachments))
	}
}

func TestFixture_MailMessage_Validation(t *testing.T) {
	data, err := os.ReadFile(testutil.FixturePath("email-message.json"))
	if err != nil {
		t.Fatalf("failed to load fixture: %v", err)
	}

	var envelope struct {
		Data *MailMessage `json:"data"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		t.Fatalf("failed to parse fixture: %v", err)
	}

	if err := ValidateMailMessage(envelope.Data); err != nil {
		t.Errorf("ValidateMailMessage() on fixture = %v, want nil", err)
	}
}

func TestFixture_MailMessage_RecipientNormalization(t *testing.T) {
	// Verify normalizeRecipients works on fixture data (MAPI prefixes stripped)
	mail := &MailMessage{
		Version:    1,
		Timestamp:  "2024-01-01T00:00:00Z",
		BodyFormat: "plain",
		Recipients: Recipients{
			To: []Recipient{{Address: "SMTP:alice@example.com"}},
		},
	}
	normalizeRecipients(mail.Recipients.To)
	if mail.Recipients.To[0].Address != "alice@example.com" {
		t.Errorf("normalizeRecipients did not strip SMTP: prefix, got %q", mail.Recipients.To[0].Address)
	}
}
