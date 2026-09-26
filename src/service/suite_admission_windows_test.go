//go:build windows

package service

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func testSuiteGate(t *testing.T) *SuiteAdmission {
	t.Helper()
	storage, err := NewPublicStatusStorage(testStorageRoot(t, "status"))
	if err != nil {
		t.Fatal(err)
	}
	gate, err := NewSuiteAdmission(storage)
	if err != nil {
		t.Fatal(err)
	}
	if err := gate.Close(context.Background()); err != nil {
		t.Fatal(err)
	}
	return gate
}

func TestHeldStateLockBoundsSuiteClosureAndReleasesAdmission(t *testing.T) {
	ctx := context.Background()
	storage := mustStorage(t, testStorageRoot(t, "service"), privateStorage)
	state, _ := NewFileStateStore(storage)
	pending := suiteRepairPending(t, exitEvidence(1603))
	if err := state.Save(ctx, pending); err != nil {
		t.Fatal(err)
	}
	gate := testSuiteGate(t)
	held, err := ownStateLock(storage)
	if err != nil {
		t.Fatal(err)
	}
	shortCtx, cancel := context.WithTimeout(ctx, 150*time.Millisecond)
	defer cancel()
	started := time.Now()
	err = gate.withExclusive(shortCtx, func(lock *suiteAdmissionLock) error {
		if err := lock.write('C'); err != nil {
			return err
		}
		_, err := state.SaveSuiteDrainDeadline(shortCtx, pending, time.Now())
		return err
	})
	if !errors.Is(err, context.DeadlineExceeded) || time.Since(started) > time.Second {
		t.Fatalf("held state lock was not bounded: %v, elapsed %s", err, time.Since(started))
	}
	if err := held.Close(); err != nil {
		t.Fatal(err)
	}
	open, err := gate.IsOpen(ctx)
	if err != nil || open {
		t.Fatalf("admission remained locked or opened: open=%v err=%v", open, err)
	}
}

func TestProductionSuiteHealthFailureClosesEarlierOpenAndRecovers(t *testing.T) {
	ctx := context.Background()
	gate := testSuiteGate(t)
	storage := mustStorage(t, testStorageRoot(t, "service"), privateStorage)
	state, _ := NewFileStateStore(storage)
	openHealthy := func() error {
		return gate.withExclusive(ctx, func(lock *suiteAdmissionLock) error {
			return state.PublishSuiteOpen(ctx, lock.write)
		})
	}
	if err := openHealthy(); err != nil {
		t.Fatal(err)
	}
	if err := closeUnhealthySuiteAdmission(ctx, gate, false, "repair-required"); err != nil {
		t.Fatal(err)
	}
	if open, err := gate.IsOpen(ctx); err != nil || open {
		t.Fatalf("previous O survived no-pending health failure: open=%v err=%v", open, err)
	}
	// An unreadable pending record is never classified as merely prepared.
	if err := openHealthy(); err != nil {
		t.Fatal(err)
	}
	if _, err := storage.WriteAtomic(ctx, []string{"pending-v2.json"}, strings.NewReader("{"), maxStateBytes, 1, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := state.Load(ctx); err == nil {
		t.Fatal("pending corruption was accepted")
	}
	if err := closeUnhealthySuiteAdmission(ctx, gate, false, "repair-required"); err != nil {
		t.Fatal(err)
	}
	if open, err := gate.IsOpen(ctx); err != nil || open {
		t.Fatalf("previous O survived unreadable pending: open=%v err=%v", open, err)
	}
	if err := storage.Remove("pending-v2.json"); err != nil {
		t.Fatal(err)
	}
	if err := openHealthy(); err != nil {
		t.Fatal(err)
	}
	if open, err := gate.IsOpen(ctx); err != nil || !open {
		t.Fatalf("healthy retry did not reopen: open=%v err=%v", open, err)
	}
	if err := closeUnhealthySuiteAdmission(ctx, gate, false, "healthy"); err != nil {
		t.Fatal(err)
	}
	if open, err := gate.IsOpen(ctx); err != nil || !open {
		t.Fatalf("healthy heartbeat closed admission: open=%v err=%v", open, err)
	}
	if err := closeUnhealthySuiteAdmission(ctx, gate, true, "repair-required"); err != nil {
		t.Fatal(err)
	}
	if open, err := gate.IsOpen(ctx); err != nil || !open {
		t.Fatalf("merely prepared state closed admission: open=%v err=%v", open, err)
	}
}

func TestHealthyOpenSuiteIgnoresUnrelatedBusyInstallerServer(t *testing.T) {
	ctx := context.Background()
	gate := testSuiteGate(t)
	storage := mustStorage(t, testStorageRoot(t, "service"), privateStorage)
	state, err := NewFileStateStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	server := &fakeInstallerServerProbe{busyOnCall: 1}
	// A closed gate must wait for an idle server before any O publication.
	if err := openHealthySuiteWithServer(ctx, gate, state, storage, InstallerInventory{}, ProductSnapshot{}, server); err == nil {
		t.Fatal("busy server allowed a closed gate to open")
	}
	if open, err := gate.IsOpen(ctx); err != nil || open || server.calls != 1 || len(server.requireStopped) != 1 || server.requireStopped[0] {
		t.Fatalf("closed proof: open=%v err=%v server=%+v", open, err, server)
	}
	if err := gate.withExclusive(ctx, func(lock *suiteAdmissionLock) error {
		return state.PublishSuiteOpen(ctx, lock.write)
	}); err != nil {
		t.Fatal(err)
	}
	server = &fakeInstallerServerProbe{busyOnCall: 1}
	if err := openHealthySuiteWithServer(ctx, gate, state, storage, InstallerInventory{}, ProductSnapshot{}, server); err != nil {
		t.Fatalf("already-open healthy suite was refused: %v", err)
	}
	if open, err := gate.IsOpen(ctx); err != nil || !open || server.calls != 0 {
		t.Fatalf("existing O was disturbed: open=%v err=%v server calls=%d", open, err, server.calls)
	}
}
