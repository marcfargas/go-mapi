package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

// TestIntegrationQueueConsumerProbe is intentionally dormant in ordinary test
// runs.  The component integration runner enables it only after a real native
// MAPISendMail harness has written GO_MAPI_INTEGRATION_DESCRIPTOR.  Keeping the
// acknowledgement in this app package makes the proof exercise the same
// queueConsumer/Wails bridge seam as the user component, rather than a second
// queue parser owned by the integration script.
func TestIntegrationQueueConsumerProbe(t *testing.T) {
	queue := os.Getenv("GO_MAPI_INTEGRATION_QUEUE")
	descriptorPath := os.Getenv("GO_MAPI_INTEGRATION_DESCRIPTOR")
	ackPath := os.Getenv("GO_MAPI_INTEGRATION_ACK_PATH")
	if queue == "" && descriptorPath == "" && ackPath == "" {
		t.Skip("integration queue probe is enabled by run-component-integration.ps1")
	}
	if queue == "" || descriptorPath == "" || ackPath == "" {
		t.Fatal("GO_MAPI_INTEGRATION_QUEUE, GO_MAPI_INTEGRATION_DESCRIPTOR, and GO_MAPI_INTEGRATION_ACK_PATH are all required")
	}

	descriptor, err := os.ReadFile(descriptorPath)
	if err != nil {
		t.Fatalf("read native caller descriptor: %v", err)
	}
	var expected mapi.MailMessage
	if err := json.Unmarshal(descriptor, &expected); err != nil {
		t.Fatalf("unmarshal native caller descriptor: %v", err)
	}

	consumer, err := newQueueConsumerWithEmitter(context.Background(), queue, func(err error) {
		t.Errorf("app queue consumer rejected native caller descriptor: %v", err)
	}, noopEmitter)
	if err != nil {
		t.Fatalf("start app queue consumer: %v", err)
	}
	defer consumer.Close()

	var observed *mapi.EmailWithId
	for _, item := range consumer.watcher.Snapshot() {
		if item.Message.Subject == expected.Subject &&
			item.Message.Timestamp == expected.Timestamp &&
			item.Message.InterceptorVersion == expected.InterceptorVersion {
			copy := item
			observed = &copy
			break
		}
	}
	if observed == nil {
		t.Fatalf("app consumer did not ingest native descriptor %q", filepath.Base(descriptorPath))
	}

	hash := sha256.Sum256(descriptor)
	ack := struct {
		DescriptorPath   string `json:"descriptorPath"`
		DescriptorSHA256 string `json:"descriptorSha256"`
		QueueMessageID   string `json:"queueMessageId"`
		Subject          string `json:"subject"`
		Interceptor      string `json:"interceptorVersion"`
	}{
		DescriptorPath:   descriptorPath,
		DescriptorSHA256: hex.EncodeToString(hash[:]),
		QueueMessageID:   observed.Id,
		Subject:          observed.Message.Subject,
		Interceptor:      observed.Message.InterceptorVersion,
	}
	data, err := json.Marshal(ack)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(ackPath), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ackPath, data, 0600); err != nil {
		t.Fatalf("write app ingestion acknowledgement: %v", err)
	}
}
