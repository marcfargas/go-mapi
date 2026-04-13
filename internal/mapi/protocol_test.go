package mapi

import (
	"testing"
)

func TestValidateMailMessage_Valid(t *testing.T) {
	mail := &MailMessage{
		Version:    1,
		Timestamp:  "2024-01-01T00:00:00Z",
		Subject:    "Test",
		Body:       "Test body",
		BodyFormat: "plain",
		Recipients: Recipients{
			To: []Recipient{{Name: "John", Address: "john@example.com"}},
		},
	}

	if err := ValidateMailMessage(mail); err != nil {
		t.Errorf("ValidateMailMessage() error = %v, want nil", err)
	}
}

func TestValidateMailMessage_ValidHTML(t *testing.T) {
	mail := &MailMessage{
		Version:    1,
		Timestamp:  "2024-01-01T00:00:00Z",
		Subject:    "Test",
		Body:       "<p>Test body</p>",
		BodyFormat: "html",
		Recipients: Recipients{
			To: []Recipient{{Address: "test@example.com"}},
		},
	}

	if err := ValidateMailMessage(mail); err != nil {
		t.Errorf("ValidateMailMessage() error = %v, want nil", err)
	}
}

func TestValidateMailMessage_MissingVersion(t *testing.T) {
	mail := &MailMessage{
		Version:    0, // Missing/zero
		Timestamp:  "2024-01-01T00:00:00Z",
		BodyFormat: "plain",
	}

	err := ValidateMailMessage(mail)
	if err == nil {
		t.Error("ValidateMailMessage() expected error for missing version")
	}
}

func TestValidateMailMessage_MissingTimestamp(t *testing.T) {
	mail := &MailMessage{
		Version:    1,
		Timestamp:  "", // Missing
		BodyFormat: "plain",
	}

	err := ValidateMailMessage(mail)
	if err == nil {
		t.Error("ValidateMailMessage() expected error for missing timestamp")
	}
}

func TestValidateMailMessage_InvalidBodyFormat(t *testing.T) {
	mail := &MailMessage{
		Version:    1,
		Timestamp:  "2024-01-01T00:00:00Z",
		BodyFormat: "invalid", // Not plain or html
	}

	err := ValidateMailMessage(mail)
	if err == nil {
		t.Error("ValidateMailMessage() expected error for invalid bodyFormat")
	}
}

func TestValidateMailMessage_EmptyBodyFormat(t *testing.T) {
	mail := &MailMessage{
		Version:    1,
		Timestamp:  "2024-01-01T00:00:00Z",
		BodyFormat: "",
	}

	err := ValidateMailMessage(mail)
	if err == nil {
		t.Error("ValidateMailMessage() expected error for empty bodyFormat")
	}
}

func TestValidateMailMessage_ToRecipientMissingAddress(t *testing.T) {
	mail := &MailMessage{
		Version:    1,
		Timestamp:  "2024-01-01T00:00:00Z",
		BodyFormat: "plain",
		Recipients: Recipients{
			To: []Recipient{{Name: "John", Address: ""}}, // Missing address
		},
	}

	err := ValidateMailMessage(mail)
	if err == nil {
		t.Error("ValidateMailMessage() expected error for recipient missing address")
	}
}

func TestValidateMailMessage_CCRecipientMissingAddress(t *testing.T) {
	mail := &MailMessage{
		Version:    1,
		Timestamp:  "2024-01-01T00:00:00Z",
		BodyFormat: "plain",
		Recipients: Recipients{
			To: []Recipient{{Address: "to@example.com"}},
			CC: []Recipient{{Name: "CC Person", Address: ""}},
		},
	}

	err := ValidateMailMessage(mail)
	if err == nil {
		t.Error("ValidateMailMessage() expected error for CC recipient missing address")
	}
}

func TestValidateMailMessage_BCCRecipientMissingAddress(t *testing.T) {
	mail := &MailMessage{
		Version:    1,
		Timestamp:  "2024-01-01T00:00:00Z",
		BodyFormat: "plain",
		Recipients: Recipients{
			To:  []Recipient{{Address: "to@example.com"}},
			BCC: []Recipient{{Name: "BCC Person", Address: ""}},
		},
	}

	err := ValidateMailMessage(mail)
	if err == nil {
		t.Error("ValidateMailMessage() expected error for BCC recipient missing address")
	}
}

func TestValidateMailMessage_MultipleRecipients(t *testing.T) {
	mail := &MailMessage{
		Version:    1,
		Timestamp:  "2024-01-01T00:00:00Z",
		Subject:    "Test",
		Body:       "Body",
		BodyFormat: "plain",
		Recipients: Recipients{
			To:  []Recipient{{Address: "to1@example.com"}, {Address: "to2@example.com"}},
			CC:  []Recipient{{Address: "cc@example.com"}},
			BCC: []Recipient{{Address: "bcc@example.com"}},
		},
	}

	if err := ValidateMailMessage(mail); err != nil {
		t.Errorf("ValidateMailMessage() error = %v, want nil", err)
	}
}

func TestValidateMailMessage_NoRecipients(t *testing.T) {
	// Email with no recipients is valid (recipients are optional per the code)
	mail := &MailMessage{
		Version:    1,
		Timestamp:  "2024-01-01T00:00:00Z",
		BodyFormat: "plain",
		Recipients: Recipients{},
	}

	if err := ValidateMailMessage(mail); err != nil {
		t.Errorf("ValidateMailMessage() error = %v, want nil", err)
	}
}

func TestNormalizeAddress(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"SMTP:user@example.com", "user@example.com"},
		{"smtp:user@example.com", "user@example.com"},
		{"MAILTO:user@example.com", "user@example.com"},
		{"mailto:user@example.com", "user@example.com"},
		{"user@example.com", "user@example.com"},
		{"", ""},
		{"SMTP:", ""},
		{"OTHER:user@example.com", "OTHER:user@example.com"},
	}

	for _, tt := range tests {
		result := normalizeAddress(tt.input)
		if result != tt.expected {
			t.Errorf("normalizeAddress(%q) = %q, want %q", tt.input, result, tt.expected)
		}
	}
}

func TestNormalizeRecipients(t *testing.T) {
	recipients := []Recipient{
		{Name: "John", Address: "SMTP:john@example.com"},
		{Name: "Jane", Address: "mailto:jane@example.com"},
		{Name: "Bob", Address: "bob@example.com"},
	}

	normalizeRecipients(recipients)

	expected := []string{"john@example.com", "jane@example.com", "bob@example.com"}
	for i, r := range recipients {
		if r.Address != expected[i] {
			t.Errorf("normalizeRecipients[%d].Address = %q, want %q", i, r.Address, expected[i])
		}
	}
}
