package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDetachedRunnerLauncherCopiesReverifiesAndAwaitsDurableReady(t *testing.T) {
	storage := mustStorage(t, testStorageRoot(t, "updates"), privateStorage)
	source := filepath.Join(storage.root, "go-mapi-service.exe")
	if err := os.WriteFile(source, []byte("signed executable"), 0700); err != nil {
		t.Fatal(err)
	}
	body := []byte("msi")
	sum := sha256.Sum256(body)
	digest := hex.EncodeToString(sum[:])
	handle := "system/42/go-mapi-system-4.0.1-x64.msi"
	if _, err := storage.WriteAtomic(context.Background(), strings.Split(handle, "/"), strings.NewReader(string(body)), int64(len(body)), int64(len(body)), digest); err != nil {
		t.Fatal(err)
	}
	runnerID := ProcessIdentity{PID: 80, CreatedAtUnixNano: 8000}
	installerID := ProcessIdentity{PID: 81, CreatedAtUnixNano: 8001}
	spawner := &recordingSpawner{identity: runnerID}
	awaiter := fixedReadyAwaiter{ready: RunnerReadyV1{Schema: RunnerReadySchemaV1, TransactionID: "tx-80", Attempt: 1, Runner: runnerID, Installer: installerID, ReadyAt: time.Now().UTC()}}
	launcher, err := NewDetachedRunnerLauncher(storage, &memoryReadyStore{order: &[]string{}}, spawner, awaiter, source)
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := launcher.Launch(context.Background(), HandoffRequest{TransactionID: "tx-80", Attempt: 1, Artifact: StagedArtifact{Handle: handle, SHA256: digest}})
	if err != nil {
		t.Fatal(err)
	}
	if !receipt.Ready || receipt.Runner != runnerID || receipt.Installer != installerID {
		t.Fatalf("receipt = %#v", receipt)
	}
	staged := filepath.Join(storage.root, "runners", "tx-80", stagedRunnerName)
	if spawner.path != staged || spawner.transaction != "tx-80" {
		t.Fatalf("spawn = %q %q", spawner.path, spawner.transaction)
	}
}

func TestDetachedRunnerLauncherRejectsArbitraryArtifactHandle(t *testing.T) {
	storage := mustStorage(t, testStorageRoot(t, "updates"), privateStorage)
	source := filepath.Join(storage.root, "service.exe")
	_ = os.WriteFile(source, []byte("x"), 0700)
	launcher, _ := NewDetachedRunnerLauncher(storage, &memoryReadyStore{order: &[]string{}}, &recordingSpawner{}, fixedReadyAwaiter{}, source)
	for _, handle := range []string{"/absolute.msi", "../outside.msi", "system/42/../../outside.msi", "system/42/file:stream"} {
		if _, err := launcher.Launch(context.Background(), HandoffRequest{TransactionID: "tx-1", Attempt: 1, Artifact: StagedArtifact{Handle: handle, SHA256: strings.Repeat("a", 64)}}); err == nil {
			t.Fatalf("accepted handle %q", handle)
		}
	}
}

type recordingSpawner struct {
	path, transaction string
	identity          ProcessIdentity
	err               error
}

func (spawner *recordingSpawner) SpawnDetached(path, transaction string) (ProcessIdentity, error) {
	spawner.path, spawner.transaction = path, transaction
	return spawner.identity, spawner.err
}

type fixedReadyAwaiter struct {
	ready RunnerReadyV1
	err   error
}

func (awaiter fixedReadyAwaiter) Await(_ context.Context, _ RunnerReadyStore, transaction string, attempt uint, runner ProcessIdentity) (RunnerReadyV1, error) {
	if awaiter.ready.TransactionID != "" && (awaiter.ready.TransactionID != transaction || awaiter.ready.Attempt != attempt || awaiter.ready.Runner != runner) {
		return RunnerReadyV1{}, context.Canceled
	}
	return awaiter.ready, awaiter.err
}
