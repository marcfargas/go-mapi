package service

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestUpdateRunnerPersistsIdentityBeforeReadyThenRecordsExit(t *testing.T) {
	now := time.Date(2026, 9, 23, 9, 0, 0, 0, time.UTC)
	pending := validPending(now)
	store := &orderedPendingStore{pending: &pending}
	ready := &memoryReadyStore{order: &store.order}
	process := &fakeInstallerProcess{identity: ProcessIdentity{PID: 52, CreatedAtUnixNano: 2002}, code: 3010, order: &store.order}
	runtime := &fakeRunnerRuntime{self: ProcessIdentity{PID: 51, CreatedAtUnixNano: 2001}, process: process, order: &store.order}
	runner := UpdateRunner{Pending: store, Ready: ready, Artifacts: fixedArtifactResolver("/protected/update.msi"), Integrity: &fakeIntegrityVerifier{order: &store.order}, Runtime: runtime, Clock: fixedRunnerClock(now)}

	if err := runner.Run(context.Background(), pending.TransactionID); err != nil {
		t.Fatal(err)
	}
	wantOrder := []string{"verify", "save-runner", "start-installer", "save-installer-running", "ready", "wait", "save-exit"}
	if !reflect.DeepEqual(store.order, wantOrder) {
		t.Fatalf("runner order = %v, want %v", store.order, wantOrder)
	}
	if store.pending.Exit == nil || store.pending.Exit.Code != 3010 {
		t.Fatalf("exit evidence = %#v", store.pending.Exit)
	}
	if ready.ready == nil || ready.ready.Installer != process.identity {
		t.Fatalf("ready evidence = %#v", ready.ready)
	}
}

func TestUpdateRunnerCancellationCannotCancelInstallerAfterReady(t *testing.T) {
	now := time.Date(2026, 9, 23, 9, 0, 0, 0, time.UTC)
	pending := validPending(now)
	store := &orderedPendingStore{pending: &pending}
	ctx, cancel := context.WithCancel(context.Background())
	process := &fakeInstallerProcess{identity: ProcessIdentity{PID: 62, CreatedAtUnixNano: 3002}, code: 0, wait: func() { cancel() }, order: &store.order}
	runner := UpdateRunner{Pending: store, Ready: &memoryReadyStore{order: &store.order}, Artifacts: fixedArtifactResolver("/protected/update.msi"), Integrity: &fakeIntegrityVerifier{order: &store.order}, Runtime: &fakeRunnerRuntime{self: ProcessIdentity{PID: 61, CreatedAtUnixNano: 3001}, process: process, order: &store.order}, Clock: fixedRunnerClock(now)}

	if err := runner.Run(ctx, pending.TransactionID); err != nil {
		t.Fatalf("post-ready cancellation reached runner: %v", err)
	}
	if store.pending.Exit == nil || store.pending.Exit.Code != 0 {
		t.Fatalf("exit evidence = %#v", store.pending.Exit)
	}
}

func TestUpdateRunnerFailureBoundariesLeaveNoFalseReadyOrExit(t *testing.T) {
	now := time.Date(2026, 9, 23, 9, 0, 0, 0, time.UTC)
	for _, test := range []struct {
		name      string
		integrity error
		start     error
		wait      error
		wantReady bool
	}{
		{name: "changed artifact", integrity: errors.New("hash mismatch")},
		{name: "installer start", start: errors.New("create process")},
		{name: "missing numeric exit", wait: errors.New("lost process handle"), wantReady: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			pending := validPending(now)
			store := &orderedPendingStore{pending: &pending}
			ready := &memoryReadyStore{order: &store.order}
			process := &fakeInstallerProcess{identity: ProcessIdentity{PID: 72, CreatedAtUnixNano: 4002}, err: test.wait, order: &store.order}
			runner := UpdateRunner{Pending: store, Ready: ready, Artifacts: fixedArtifactResolver("/protected/update.msi"), Integrity: &fakeIntegrityVerifier{err: test.integrity, order: &store.order}, Runtime: &fakeRunnerRuntime{self: ProcessIdentity{PID: 71, CreatedAtUnixNano: 4001}, process: process, err: test.start, order: &store.order}, Clock: fixedRunnerClock(now)}
			if err := runner.Run(context.Background(), pending.TransactionID); err == nil {
				t.Fatal("Run unexpectedly succeeded")
			}
			if (ready.ready != nil) != test.wantReady {
				t.Fatalf("ready = %#v, want published %v", ready.ready, test.wantReady)
			}
			if store.pending.Exit != nil {
				t.Fatalf("false exit evidence = %#v", store.pending.Exit)
			}
		})
	}
}

type orderedPendingStore struct {
	pending *PendingV1
	order   []string
}

func (store *orderedPendingStore) Load(context.Context) (*PendingV1, error) {
	if store.pending == nil {
		return nil, nil
	}
	copy := *store.pending
	return &copy, nil
}
func (store *orderedPendingStore) Save(_ context.Context, pending PendingV1) error {
	copy := pending
	store.pending = &copy
	switch {
	case pending.Exit != nil:
		store.order = append(store.order, "save-exit")
	case pending.Installer != nil:
		store.order = append(store.order, "save-installer-running")
	case pending.Runner != nil:
		store.order = append(store.order, "save-runner")
	}
	return nil
}
func (store *orderedPendingStore) Clear(context.Context) error { store.pending = nil; return nil }

type memoryReadyStore struct {
	ready *RunnerReadyV1
	order *[]string
}

func (store *memoryReadyStore) Publish(_ context.Context, ready RunnerReadyV1) error {
	if err := ready.Validate(); err != nil {
		return err
	}
	copy := ready
	store.ready = &copy
	*store.order = append(*store.order, "ready")
	return nil
}
func (store *memoryReadyStore) Load(_ context.Context, transactionID string) (*RunnerReadyV1, error) {
	if store.ready == nil || store.ready.TransactionID != transactionID {
		return nil, nil
	}
	copy := *store.ready
	return &copy, nil
}

type fixedArtifactResolver string

func (resolver fixedArtifactResolver) Resolve(context.Context, PendingV1) (string, error) {
	return string(resolver), nil
}

type fakeIntegrityVerifier struct {
	err   error
	order *[]string
}

func (verifier *fakeIntegrityVerifier) VerifySHA256(_ context.Context, path, hash string) error {
	if path == "" || !validSHA256(hash) {
		return errors.New("invalid verification request")
	}
	*verifier.order = append(*verifier.order, "verify")
	return verifier.err
}

type fakeRunnerRuntime struct {
	self    ProcessIdentity
	process InstallerProcess
	err     error
	order   *[]string
}

func (runtime *fakeRunnerRuntime) SelfIdentity() (ProcessIdentity, error) { return runtime.self, nil }
func (runtime *fakeRunnerRuntime) StartInstaller(path string) (InstallerProcess, error) {
	if !strings.HasSuffix(path, ".msi") {
		return nil, errors.New("not MSI")
	}
	*runtime.order = append(*runtime.order, "start-installer")
	return runtime.process, runtime.err
}

type fakeInstallerProcess struct {
	identity ProcessIdentity
	code     uint32
	err      error
	wait     func()
	order    *[]string
}

func (process *fakeInstallerProcess) Identity() ProcessIdentity { return process.identity }
func (process *fakeInstallerProcess) Wait() (uint32, error) {
	*process.order = append(*process.order, "wait")
	if process.wait != nil {
		process.wait()
	}
	return process.code, process.err
}

type fixedRunnerClock time.Time

func (clock fixedRunnerClock) Now() time.Time { return time.Time(clock) }
