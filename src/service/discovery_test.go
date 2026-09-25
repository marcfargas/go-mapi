package service

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func TestMachineInstallFailuresUseDurablePerSKURetryState(t *testing.T) {
	storage := mustStorage(t, testStorageRoot(t, "service"), privateStorage)
	store, err := NewFileDiscoveryStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	engine, err := update.NewEngine(update.Config{SKU: update.Suite, MetadataOrigin: "https://go-mapi.app", Client: &http.Client{}, Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	state := DiscoveryState{Schema: discoverySchema, SKU: update.Suite, Result: "available", InstalledVersion: "4.0.0", CandidateVersion: "4.0.1", CandidateExpiresAt: now.Add(time.Hour), LastAttemptAt: now, LastSuccessAt: now, NextAttemptAt: now.Add(6 * time.Hour), Accepted: update.ReplayState{Namespace: "suite", Sequence: 401, Digest: strings.Repeat("a", 64)}}
	if err := store.Save(context.Background(), state); err != nil {
		t.Fatal(err)
	}
	first, err := persistMachineInstallCheckState(context.Background(), store, update.Suite, engine.InstallFailureState)
	if err != nil || first.Failures != 1 || !first.NextAttemptAt.Equal(now.Add(15*time.Minute)) {
		t.Fatalf("first artifact failure = %#v, %v", first, err)
	}
	now = now.Add(15 * time.Minute)
	second, err := persistMachineInstallCheckState(context.Background(), store, update.Suite, engine.InstallFailureState)
	if err != nil || second.Failures != 2 || !second.NextAttemptAt.Equal(now.Add(30*time.Minute)) {
		t.Fatalf("second artifact failure = %#v, %v", second, err)
	}
	unchangedSystem, err := store.Load(context.Background(), update.System)
	if err != nil || unchangedSystem.Failures != 0 || !unchangedSystem.NextAttemptAt.IsZero() {
		t.Fatalf("suite failure changed system cadence: %#v, %v", unchangedSystem, err)
	}
	accepted, err := persistMachineInstallCheckState(context.Background(), store, update.Suite, engine.InstallSuccessState)
	if err != nil || accepted.Failures != 0 {
		t.Fatalf("accepted handoff did not reset retry state: %#v, %v", accepted, err)
	}
}

func TestMachineCheckStatePersistsSeparatelyBySKU(t *testing.T) {
	storage := mustStorage(t, testStorageRoot(t, "service"), privateStorage)
	store, err := NewFileDiscoveryStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	for _, sku := range []update.SKU{update.System, update.Suite} {
		initial, err := store.Load(context.Background(), sku)
		if err != nil || initial.SKU != sku || initial.Result != "unavailable" {
			t.Fatalf("initial %s check state = %#v, %v", sku, initial, err)
		}
	}
	now := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	system := DiscoveryState{Schema: discoverySchema, SKU: update.System, Result: "available", InstalledVersion: "4.0.0", CandidateVersion: "4.0.1", CandidateExpiresAt: now.Add(time.Hour), LastAttemptAt: now, LastSuccessAt: now, NextAttemptAt: now.Add(6 * time.Hour), Accepted: update.ReplayState{Namespace: "system", Sequence: 401, Digest: strings.Repeat("a", 64)}}
	if err := store.Save(context.Background(), system); err != nil {
		t.Fatal(err)
	}
	got, err := store.Load(context.Background(), update.System)
	if err != nil || got.CandidateVersion != "4.0.1" || !got.Effective(now, "4.0.0") {
		t.Fatalf("system state = %#v, %v", got, err)
	}
	suite, err := store.Load(context.Background(), update.Suite)
	if err != nil || suite.Accepted.Sequence != 0 || suite.LastAttemptAt != (time.Time{}) {
		t.Fatalf("suite cadence was changed by system: %#v, %v", suite, err)
	}
	system.Accepted.Digest = strings.Repeat("b", 64)
	if err := store.Save(context.Background(), system); err != ErrStateConflict {
		t.Fatalf("same-sequence different digest = %v", err)
	}
}
