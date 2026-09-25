package service

import (
	"context"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func TestPreparationSerializesFloorsSettingMarkerFenceAndPending(t *testing.T) {
	for _, test := range []struct {
		name         string
		prepare      func(*testing.T, *ProtectedStorage, update.Release, machineProductMarker) (machineProductMarker, bool)
		wantErr      bool
		changedFloor bool
	}{
		{"equal discovery floor", nil, false, false},
		{"disabled setting", func(_ *testing.T, _ *ProtectedStorage, _ update.Release, marker machineProductMarker) (machineProductMarker, bool) {
			return marker, false
		}, true, false},
		{"changed marker", func(_ *testing.T, _ *ProtectedStorage, _ update.Release, marker machineProductMarker) (machineProductMarker, bool) {
			marker.ServiceVersion = "4.0.9"
			return marker, true
		}, true, false},
		{"final uninstall fence", func(t *testing.T, storage *ProtectedStorage, _ update.Release, marker machineProductMarker) (machineProductMarker, bool) {
			state, _ := NewFileStateStore(storage)
			if err := state.BeginFinalUninstall(context.Background()); err != nil {
				t.Fatal(err)
			}
			return marker, true
		}, true, false},
		{"higher committed floor", func(t *testing.T, storage *ProtectedStorage, _ update.Release, marker machineProductMarker) (machineProductMarker, bool) {
			other := authorizedRelease(t, update.System, "4.0.2")
			floor, _ := update.AcceptReplay(update.ReplayState{}, other)
			store, _ := NewFileReplayStore(storage)
			if err := store.Save(context.Background(), floor); err != nil {
				t.Fatal(err)
			}
			return marker, true
		}, true, false},
		{name: "equal sequence changed digest", wantErr: true, changedFloor: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			storage := mustStorage(t, testStorageRoot(t, "preparation"), privateStorage)
			release := authorizedRelease(t, update.System, "4.0.1")
			replay, err := update.AcceptReplay(update.ReplayState{}, release)
			if err != nil {
				t.Fatal(err)
			}
			floorReplay := replay
			if test.changedFloor {
				floorReplay.Digest = strings.Repeat("a", 64)
			}
			floor, _ := NewFileDiscoveryStore(storage)
			if err := floor.Save(context.Background(), DiscoveryState{Schema: discoverySchema, SKU: update.System, Accepted: floorReplay, Result: "no-update"}); err != nil {
				t.Fatal(err)
			}
			marker := machineProductMarker{SKU: "system", PackageRelease: "4.0.0", ServiceVersion: "4.0.0", InterceptorVersion: "4.0.0"}
			current, enabled := marker, true
			if test.prepare != nil {
				current, enabled = test.prepare(t, storage, release, marker)
			}
			authorizer, err := NewFilePreparationAuthorizer(storage, func(context.Context) (machineProductMarker, bool, error) { return current, enabled, nil })
			if err != nil {
				t.Fatal(err)
			}
			retry := coordinatorNow.Add(10 * time.Minute)
			pending := PendingV1{Schema: PendingSchemaV2, TransactionID: "tx-preparation", SKU: update.System,
				Old: oldProduct(update.System), Candidate: mustProductFromRelease(t, release), Replay: replay,
				ArtifactSHA256: release.Payload().Artifact.SHA256, Phase: PhasePrepared, LaunchBootID: "boot-one",
				PreparedAt: coordinatorNow, UpdatedAt: coordinatorNow, Attempt: 1, RetryDeadline: &retry}
			decision := PreparationDecision{Observation: PreparationObservation{Product: pending.Old, Marker: marker, Enabled: true}, Release: release, Pending: pending, CurrentTime: func() time.Time { return coordinatorNow }}
			err = authorizer.AuthorizeAndSave(context.Background(), decision)
			if (err != nil) != test.wantErr {
				t.Fatalf("AuthorizeAndSave error = %v; want error %v", err, test.wantErr)
			}
			state, _ := NewFileStateStore(storage)
			actual, err := state.Load(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if (actual == nil) != test.wantErr {
				t.Fatalf("pending = %#v; want error %v", actual, test.wantErr)
			}
			if !test.wantErr {
				if err := authorizer.AuthorizeAndSave(context.Background(), decision); !errors.Is(err, ErrStateConflict) {
					t.Fatalf("second preparation = %v", err)
				}
			}
		})
	}
}

func TestDiscardPreservesPendingArtifactAndRemovesUnreferencedStage(t *testing.T) {
	stateStorage := mustStorage(t, testStorageRoot(t, "state"), privateStorage)
	updateStorage := mustStorage(t, testStorageRoot(t, "updates"), privateStorage)
	release := authorizedRelease(t, update.System, "4.0.1")
	store, err := NewProtectedArtifactStore(updateStorage, stateStorage)
	if err != nil {
		t.Fatal(err)
	}
	artifact, err := store.StageWith(context.Background(), release, func(writer io.Writer) error { _, err := io.WriteString(writer, "verified installer"); return err })
	if err != nil {
		t.Fatal(err)
	}
	replay, _ := update.AcceptReplay(update.ReplayState{}, release)
	retry := coordinatorNow.Add(10 * time.Minute)
	pending := PendingV1{Schema: PendingSchemaV2, TransactionID: "tx-discard", SKU: update.System,
		Old: oldProduct(update.System), Candidate: mustProductFromRelease(t, release), Replay: replay,
		ArtifactSHA256: artifact.SHA256, Phase: PhasePrepared, LaunchBootID: "boot-one",
		PreparedAt: coordinatorNow, UpdatedAt: coordinatorNow, Attempt: 1, RetryDeadline: &retry}
	state, _ := NewFileStateStore(stateStorage)
	if err := state.CompareAndSave(context.Background(), nil, pending); err != nil {
		t.Fatal(err)
	}
	components := strings.Split(artifact.Handle, "/")
	if err := store.Discard(context.Background(), artifact); err != nil {
		t.Fatal(err)
	}
	if _, err := updateStorage.Read(components, release.Payload().Artifact.Size); err != nil {
		t.Fatalf("pending artifact was deleted: %v", err)
	}
	if err := state.CompareAndClear(context.Background(), pending); err != nil {
		t.Fatal(err)
	}
	if err := store.Discard(context.Background(), artifact); err != nil {
		t.Fatal(err)
	}
	if _, err := updateStorage.Read(components, release.Payload().Artifact.Size); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("unreferenced stage remained: %v", err)
	}
}

func TestPendingResumeAuthorizesItsInstalledSKU(t *testing.T) {
	for _, sku := range []update.SKU{update.System, update.Suite} {
		t.Run(string(sku), func(t *testing.T) {
			installed := oldProduct(sku)
			if sku == update.Suite {
				installed.Contained["app"] = "4.0.0"
			}
			pending := PendingV1{SKU: sku, Old: installed}
			if err := authorizePendingProductSnapshot(pending, installed); err != nil {
				t.Fatalf("matching installed product was rejected: %v", err)
			}
			changed := installed
			changed.ProductCode = "DIFFERENT"
			if err := authorizePendingProductSnapshot(pending, changed); err == nil {
				t.Fatal("changed installed product was accepted")
			}
			foreign := installed
			if sku == update.System {
				foreign.SKU = update.Suite
			} else {
				foreign.SKU = update.System
			}
			if err := authorizePendingProductSnapshot(pending, foreign); err == nil {
				t.Fatal("foreign installed SKU was accepted")
			}
		})
	}
	installed := oldProduct(update.System)
	if err := authorizePendingProductSnapshot(PendingV1{SKU: "unknown", Old: installed}, installed); err == nil {
		t.Fatal("unknown pending SKU was accepted")
	}
}
