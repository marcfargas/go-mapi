package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestDetachedRunnerLauncherCopiesReverifiesAndAwaitsDurableReady(t *testing.T) {
	storage := mustStorage(t, filepath.Join(t.TempDir(), "updates"), privateStorage)
	source := filepath.Join(t.TempDir(), "go-mapi-service.exe")
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
	auth := &recordingAuthenticode{}
	spawner := &recordingSpawner{identity: runnerID}
	awaiter := fixedReadyAwaiter{ready: RunnerReadyV1{Schema: RunnerReadySchemaV1, TransactionID: "tx-80", Runner: runnerID, Installer: installerID, ReadyAt: time.Now().UTC()}}
	launcher, err := NewDetachedRunnerLauncher(storage, &memoryReadyStore{order: &[]string{}}, auth, spawner, awaiter, source)
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := launcher.Launch(context.Background(), HandoffRequest{TransactionID: "tx-80", Artifact: StagedArtifact{Handle: handle, SHA256: digest}})
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
	if !reflect.DeepEqual(auth.paths, []string{source, staged}) {
		t.Fatalf("Authenticode paths = %v", auth.paths)
	}
}

func TestDetachedRunnerLauncherRejectsArbitraryArtifactHandle(t *testing.T) {
	storage := mustStorage(t, filepath.Join(t.TempDir(), "updates"), privateStorage)
	source := filepath.Join(t.TempDir(), "service.exe")
	_ = os.WriteFile(source, []byte("x"), 0700)
	launcher, _ := NewDetachedRunnerLauncher(storage, &memoryReadyStore{order: &[]string{}}, &recordingAuthenticode{}, &recordingSpawner{}, fixedReadyAwaiter{}, source)
	for _, handle := range []string{"/absolute.msi", "../outside.msi", "system/42/../../outside.msi", "system/42/file:stream"} {
		if _, err := launcher.Launch(context.Background(), HandoffRequest{TransactionID: "tx-1", Artifact: StagedArtifact{Handle: handle, SHA256: strings.Repeat("a", 64)}}); err == nil {
			t.Fatalf("accepted handle %q", handle)
		}
	}
}

type recordingAuthenticode struct {
	paths []string
	err   error
}

func (verifier *recordingAuthenticode) VerifyAuthenticode(_ context.Context, path string) error {
	verifier.paths = append(verifier.paths, path)
	return verifier.err
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

func (awaiter fixedReadyAwaiter) Await(_ context.Context, _ RunnerReadyStore, transaction string, runner ProcessIdentity) (RunnerReadyV1, error) {
	if awaiter.ready.TransactionID != "" && (awaiter.ready.TransactionID != transaction || awaiter.ready.Runner != runner) {
		return RunnerReadyV1{}, context.Canceled
	}
	return awaiter.ready, awaiter.err
}
