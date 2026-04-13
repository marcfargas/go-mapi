package mapi

import (
	"fmt"
	"strings"
)

// MailMessage represents an intercepted email
type MailMessage struct {
	Version            int          `json:"version"`
	InterceptorVersion string       `json:"interceptorVersion,omitempty"`
	HostVersion        string       `json:"hostVersion,omitempty"`
	Timestamp          string       `json:"timestamp"`
	Subject            string       `json:"subject"`
	Body               string       `json:"body"`
	BodyFormat         string       `json:"bodyFormat"`
	Recipients         Recipients   `json:"recipients"`
	Attachments        []Attachment `json:"attachments"`
	OriginApp          string       `json:"originApp"`
}

// Recipients contains email recipients by type
type Recipients struct {
	To  []Recipient `json:"to"`
	CC  []Recipient `json:"cc"`
	BCC []Recipient `json:"bcc"`
}

// Recipient represents a single email recipient
type Recipient struct {
	Name    string `json:"name"`
	Address string `json:"address"`
}

// Attachment represents an email attachment
type Attachment struct {
	Filename string `json:"filename"`
	Path     string `json:"path"`
	Size     int64  `json:"size"`
}

// ValidateMailMessage validates required fields on a MailMessage.
// Returns an error describing the first missing or invalid field.
func ValidateMailMessage(mail *MailMessage) error {
	if mail.Version == 0 {
		return fmt.Errorf("missing version")
	}
	if mail.Timestamp == "" {
		return fmt.Errorf("missing timestamp")
	}
	if mail.BodyFormat != "plain" && mail.BodyFormat != "html" {
		return fmt.Errorf("invalid bodyFormat: %s", mail.BodyFormat)
	}
	// Recipients are optional but if present must have address
	for i, r := range mail.Recipients.To {
		if r.Address == "" {
			return fmt.Errorf("recipient to[%d] missing address", i)
		}
	}
	for i, r := range mail.Recipients.CC {
		if r.Address == "" {
			return fmt.Errorf("recipient cc[%d] missing address", i)
		}
	}
	for i, r := range mail.Recipients.BCC {
		if r.Address == "" {
			return fmt.Errorf("recipient bcc[%d] missing address", i)
		}
	}
	return nil
}

// normalizeAddress strips common MAPI address prefixes (SMTP:, mailto:)
func normalizeAddress(addr string) string {
	prefixes := []string{"SMTP:", "smtp:", "MAILTO:", "mailto:"}
	for _, prefix := range prefixes {
		if strings.HasPrefix(addr, prefix) {
			return strings.TrimPrefix(addr, prefix)
		}
	}
	return addr
}

// normalizeRecipients applies address normalization to a slice of recipients
func normalizeRecipients(recipients []Recipient) {
	for i := range recipients {
		recipients[i].Address = normalizeAddress(recipients[i].Address)
	}
}
