package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestQueueConsumerStartsWithoutInterceptor(t *testing.T) {
	queue := filepath.Join(t.TempDir(), "missing", "queue")
	consumer, err := newQueueConsumerWithEmitter(context.Background(), queue, func(error) {}, noopEmitter)
	if err != nil {
		t.Fatalf("start empty queue: %v", err)
	}
	defer consumer.Close()
	if _, err := os.Stat(queue); err != nil {
		t.Fatalf("queue was not created: %v", err)
	}
	if got := consumer.watcher.Snapshot(); len(got) != 0 {
		t.Fatalf("empty queue snapshot = %#v", got)
	}
}

func TestQueueConsumerEmitsCanonicalMessage(t *testing.T) {
	queue := t.TempDir()
	var once sync.Once
	emitted := make(chan struct{})
	consumer, err := newQueueConsumerWithEmitter(context.Background(), queue, func(err error) { t.Errorf("queue error: %v", err) }, func(string, ...interface{}) { once.Do(func() { close(emitted) }) })
	if err != nil {
		t.Fatalf("start queue: %v", err)
	}
	defer consumer.Close()
	fixture := filepath.Join("..", "..", "tests", "protocol-fixtures", "queue-v1", "plain-message.json")
	data, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(queue, "mail.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	select {
	case <-emitted:
		if got := consumer.watcher.Snapshot(); len(got) != 1 {
			t.Fatalf("snapshot length = %d, want 1", len(got))
		}
	case <-time.After(3 * time.Second):
		t.Fatal("queue update not emitted")
	}
}

// The app owns this consumer/bridge seam.  These fixture tests deliberately
// exercise it rather than only testing the shared watcher package: the
// installed user application must accept queue-v1 producer output, expose
// attachments staged beside a descriptor, reject malformed descriptors via
// its error callback, and tolerate future additive fields.
func TestQueueConsumerAcceptsQueueV1FixturesAndStagedAttachment(t *testing.T) {
	for _, fixtureName := range []string{"plain-message.json", "html-with-attachment.json"} {
		t.Run(fixtureName, func(t *testing.T) {
			queue := t.TempDir()
			name, data := appQueueFixture(t, fixtureName)
			stem := strings.TrimSuffix(name, ".json")
			if fixtureName == "html-with-attachment.json" {
				attachmentDir := filepath.Join(queue, stem)
				if err := os.MkdirAll(attachmentDir, 0700); err != nil {
					t.Fatal(err)
				}
				attachmentPath := filepath.Join(attachmentDir, "forecast.pdf")
				if err := os.WriteFile(attachmentPath, []byte("fixture attachment"), 0600); err != nil {
					t.Fatal(err)
				}
				data = rewriteFixtureAttachmentPath(t, data, attachmentPath)
			}

			emitted := make(chan struct{}, 1)
			consumer, err := newQueueConsumerWithEmitter(context.Background(), queue, func(err error) {
				t.Errorf("queue error: %v", err)
			}, func(string, ...interface{}) { emitted <- struct{}{} })
			if err != nil {
				t.Fatalf("start consumer: %v", err)
			}
			defer consumer.Close()
			if err := os.WriteFile(filepath.Join(queue, name), data, 0600); err != nil {
				t.Fatal(err)
			}
			select {
			case <-emitted:
			case <-time.After(3 * time.Second):
				t.Fatal("queue update not emitted")
			}
			messages := consumer.watcher.Snapshot()
			if len(messages) != 1 {
				t.Fatalf("snapshot length = %d, want 1", len(messages))
			}
			if fixtureName == "html-with-attachment.json" {
				if got := messages[0].Message.Attachments; len(got) != 1 || got[0].Path != filepath.Join(queue, stem, "forecast.pdf") {
					t.Fatalf("staged attachment = %#v", got)
				}
			}
		})
	}
}

func TestQueueConsumerRejectsInvalidQueueV1Fixtures(t *testing.T) {
	for _, fixtureName := range []string{"invalid-attachment.json", "invalid-timestamp.json", "invalid-unsupported-version.json"} {
		t.Run(fixtureName, func(t *testing.T) {
			queue := t.TempDir()
			name, data := appQueueFixture(t, fixtureName)
			if err := os.WriteFile(filepath.Join(queue, name), data, 0600); err != nil {
				t.Fatal(err)
			}
			errs := make(chan error, 1)
			consumer, err := newQueueConsumerWithEmitter(context.Background(), queue, func(err error) { errs <- err }, noopEmitter)
			if err != nil {
				t.Fatalf("start consumer: %v", err)
			}
			defer consumer.Close()
			select {
			case err := <-errs:
				if err == nil {
					t.Fatal("expected rejection error")
				}
			case <-time.After(time.Second):
				t.Fatal("invalid fixture did not reach app error callback")
			}
			if got := consumer.watcher.Snapshot(); len(got) != 0 {
				t.Fatalf("invalid fixture entered app snapshot: %#v", got)
			}
			if _, err := os.Stat(filepath.Join(queue, "errors", name)); err != nil {
				t.Fatalf("invalid fixture was not moved to errors: %v", err)
			}
		})
	}
}

func TestQueueConsumerToleratesAdditiveQueueV1Fields(t *testing.T) {
	queue := t.TempDir()
	name, data := appQueueFixture(t, "plain-message.json")
	var descriptor map[string]interface{}
	if err := json.Unmarshal(data, &descriptor); err != nil {
		t.Fatal(err)
	}
	descriptor["futureProducerMetadata"] = map[string]interface{}{"delivery": "queue-v2-preview"}
	data, err := json.Marshal(descriptor)
	if err != nil {
		t.Fatal(err)
	}
	emitted := make(chan struct{}, 1)
	consumer, err := newQueueConsumerWithEmitter(context.Background(), queue, func(err error) { t.Errorf("queue error: %v", err) }, func(string, ...interface{}) { emitted <- struct{}{} })
	if err != nil {
		t.Fatal(err)
	}
	defer consumer.Close()
	if err := os.WriteFile(filepath.Join(queue, name), data, 0600); err != nil {
		t.Fatal(err)
	}
	select {
	case <-emitted:
	case <-time.After(3 * time.Second):
		t.Fatal("additive descriptor did not reach bridge")
	}
	if got := consumer.watcher.Snapshot(); len(got) != 1 || got[0].Message.Subject != "Quarterly report" {
		t.Fatalf("additive descriptor snapshot = %#v", got)
	}
}

func TestQueueConsumerQuarantinesIncompatibleProducerVersions(t *testing.T) {
	for _, version := range []string{"", "3.9.9", "v4.0.0", "5.0"} {
		t.Run(strings.ReplaceAll(version, ".", "_"), func(t *testing.T) {
			queue := t.TempDir()
			name, data := appQueueFixture(t, "plain-message.json")
			var descriptor map[string]interface{}
			if err := json.Unmarshal(data, &descriptor); err != nil {
				t.Fatal(err)
			}
			descriptor["interceptorVersion"] = version
			data, _ = json.Marshal(descriptor)
			errs := make(chan error, 1)
			consumer, err := newQueueConsumerWithEmitter(context.Background(), queue, func(err error) { errs <- err }, noopEmitter)
			if err != nil {
				t.Fatal(err)
			}
			defer consumer.Close()
			if err := os.WriteFile(filepath.Join(queue, name), data, 0600); err != nil {
				t.Fatal(err)
			}
			select {
			case <-errs:
			case <-time.After(3 * time.Second):
				t.Fatal("incompatible descriptor was not rejected")
			}
			if got := consumer.watcher.Snapshot(); len(got) != 0 {
				t.Fatalf("descriptor entered snapshot: %#v", got)
			}
			if _, err := os.Stat(filepath.Join(queue, "errors", name)); err != nil {
				t.Fatalf("descriptor not quarantined: %v", err)
			}
		})
	}
}

func appQueueFixture(t *testing.T, fixtureName string) (string, []byte) {
	t.Helper()
	path := filepath.Join("..", "..", "tests", "protocol-fixtures", "queue-v1", fixtureName)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return "message.json", data
}

func rewriteFixtureAttachmentPath(t *testing.T, data []byte, attachmentPath string) []byte {
	t.Helper()
	var descriptor map[string]interface{}
	if err := json.Unmarshal(data, &descriptor); err != nil {
		t.Fatal(err)
	}
	attachments, ok := descriptor["attachments"].([]interface{})
	if !ok || len(attachments) != 1 {
		t.Fatalf("fixture attachments = %#v", descriptor["attachments"])
	}
	attachment, ok := attachments[0].(map[string]interface{})
	if !ok {
		t.Fatalf("fixture attachment = %#v", attachments[0])
	}
	attachment["path"] = attachmentPath
	result, err := json.Marshal(descriptor)
	if err != nil {
		t.Fatal(err)
	}
	return result
}
