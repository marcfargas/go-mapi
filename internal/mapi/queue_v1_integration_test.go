package mapi

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/marcfargas/go-mapi/internal/mapi/testutil"
)

// Queue-v1 fixtures are deliberately bare MailMessage JSON. The older files
// in tests/protocol-fixtures/ retain their native-messaging envelopes and are
// covered separately by protocol_integration_test.go.
func TestQueueV1BareFixtures(t *testing.T) {
	fixtures := []string{
		"queue-v1/plain-message.json",
		"queue-v1/html-with-attachment.json",
	}

	for _, fixture := range fixtures {
		t.Run(fixture, func(t *testing.T) {
			data, err := os.ReadFile(testutil.FixturePath(fixture))
			if err != nil {
				t.Fatalf("read fixture: %v", err)
			}

			var message MailMessage
			if err := json.Unmarshal(data, &message); err != nil {
				t.Fatalf("unmarshal bare queue-v1 message: %v", err)
			}
			if err := ValidateMailMessage(&message); err != nil {
				t.Fatalf("ValidateMailMessage() = %v", err)
			}
			if message.Version != 1 {
				t.Fatalf("version = %d, want 1", message.Version)
			}
		})
	}
}

func TestQueueV1RejectsCanonicalInvalidFixtures(t *testing.T) {
	for _, fixture := range []string{
		"queue-v1/invalid-unsupported-version.json",
		"queue-v1/invalid-timestamp.json",
		"queue-v1/invalid-attachment.json",
	} {
		t.Run(fixture, func(t *testing.T) {
			data, err := os.ReadFile(testutil.FixturePath(fixture))
			if err != nil {
				t.Fatalf("read fixture: %v", err)
			}

			var message MailMessage
			if err := json.Unmarshal(data, &message); err != nil {
				t.Fatalf("unmarshal bare queue-v1 message: %v", err)
			}
			if err := ValidateMailMessage(&message); err == nil {
				t.Fatal("ValidateMailMessage() returned nil")
			}
		})
	}
}

func TestQueueV1AcceptsUnknownAdditiveFields(t *testing.T) {
	data := []byte(`{"version":1,"timestamp":"2026-08-29T00:00:00Z","bodyFormat":"plain","futureField":{"enabled":true}}`)
	var mail MailMessage
	if err := json.Unmarshal(data, &mail); err != nil {
		t.Fatalf("unmarshal queue-v1 message: %v", err)
	}
	if err := ValidateMailMessage(&mail); err != nil {
		t.Fatalf("ValidateMailMessage() = %v", err)
	}
}
