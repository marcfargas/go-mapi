package service

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func suiteRepairPending(t *testing.T, exit *ExitEvidence) PendingV1 {
	t.Helper()
	release := authorizedRelease(t, update.Suite, "4.0.1")
	replay, err := update.AcceptReplay(update.ReplayState{}, release)
	if err != nil {
		t.Fatal(err)
	}
	old := oldProduct(update.Suite)
	old.Contained["app"] = "4.0.0"
	return PendingV1{Schema: PendingSchemaV2, TransactionID: "suite-repair-1", SKU: update.Suite,
		Old: old, Candidate: mustProductFromRelease(t, release), Replay: replay, ArtifactSHA256: release.Payload().Artifact.SHA256,
		Phase: PhaseRepairRequired, Result: ResultAmbiguous, LaunchBootID: "boot-one",
		Runner: &ProcessIdentity{PID: 41, CreatedAtUnixNano: 1001}, Installer: &ProcessIdentity{PID: 42, CreatedAtUnixNano: 1002}, Exit: exit,
		PreparedAt: coordinatorNow.Add(-time.Minute), UpdatedAt: coordinatorNow, Attempt: 1}
}

func TestSuiteRepairRetiresOnlyProvedUnitAndKeepsOriginalOutcome(t *testing.T) {
	cases := []struct {
		name        string
		candidate   bool
		exit        *ExitEvidence
		boot        fixedBootID
		healthy     bool
		alive       bool
		busyOnCall  int
		changed     bool
		lockBusy    bool
		wantRetired bool
	}{
		{name: "failed numeric candidate", candidate: true, exit: exitEvidence(1603), boot: "boot-one", healthy: true, wantRetired: true},
		{name: "missing exit candidate same boot", candidate: true, boot: "boot-one", healthy: true},
		{name: "missing exit candidate later boot", candidate: true, boot: "boot-two", healthy: true, wantRetired: true},
		{name: "missing exit repaired old", boot: "boot-one", healthy: true, wantRetired: true},
		{name: "reboot code same boot", candidate: true, exit: exitEvidence(3010), boot: "boot-one", healthy: true},
		{name: "reboot code later boot", candidate: true, exit: exitEvidence(3010), boot: "boot-two", healthy: true, wantRetired: true},
		{name: "unhealthy candidate", candidate: true, exit: exitEvidence(1603), boot: "boot-one"},
		{name: "live original installer", candidate: true, exit: exitEvidence(1603), boot: "boot-one", healthy: true, alive: true},
		{name: "server changes", candidate: true, exit: exitEvidence(1603), boot: "boot-one", healthy: true, busyOnCall: 2},
		{name: "inventory changes", candidate: true, exit: exitEvidence(1603), boot: "boot-one", healthy: true, changed: true},
		{name: "runner lock busy", candidate: true, exit: exitEvidence(1603), boot: "boot-one", healthy: true, lockBusy: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			original := suiteRepairPending(t, tc.exit)
			deps := defaultDependencies(t)
			store := &memoryPendingStore{pending: &original}
			deps.Pending = store
			observed := original.Old
			if tc.candidate {
				observed = original.Candidate
			}
			inv := &fakeInventory{products: []InstalledProduct{{Snapshot: observed}}}
			if tc.changed {
				other := original.Old
				if !tc.candidate {
					other = original.Candidate
				}
				inv.productsAfter = []InstalledProduct{{Snapshot: other}}
			}
			deps.Inventory = inv
			deps.Health = fakeHealthProbe{healthy: tc.healthy}
			deps.Processes = &fakeProcessProbe{alive: tc.alive}
			server := &fakeInstallerServerProbe{busyOnCall: tc.busyOnCall}
			deps.InstallerServer = server
			deps.Boot = tc.boot
			lockHeld := false
			deps.RecoveryLock = func() (func(), error) {
				if tc.lockBusy {
					return nil, errors.New("busy")
				}
				lockHeld = true
				return func() { lockHeld = false }, nil
			}
			retired := false
			deps.RetireRepair = func(ctx context.Context, expected PendingV1, unit ProductSnapshot) error {
				if !lockHeld || !reflect.DeepEqual(expected, original) || !sameProduct(unit, observed) {
					t.Fatal("repair finalizer lost exclusion or exact evidence")
				}
				retired = true
				if err := deps.LastResult.Save(ctx, lastResultFromPending(expected)); err != nil {
					return err
				}
				return store.CompareAndClear(ctx, expected)
			}
			outcome, err := mustCoordinator(t, update.Suite, deps).Reconcile(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if (outcome == OutcomeRepairRetired) != tc.wantRetired || retired != tc.wantRetired {
				t.Fatalf("outcome=%s retired=%v", outcome, retired)
			}
			if deps.Replay.(*memoryReplayStore).saves != 0 {
				t.Fatal("repair advanced committed replay")
			}
			if tc.wantRetired {
				witness := deps.LastResult.(*memoryLastResultStore).result
				if store.pending != nil || witness == nil || witness.Result != ResultAmbiguous || !reflect.DeepEqual(witness.Exit, original.Exit) || !witness.FinishedAt.Equal(original.UpdatedAt) {
					t.Fatalf("repair witness=%#v pending=%#v", witness, store.pending)
				}
				if len(server.requireStopped) != 2 || !server.requireStopped[0] || !server.requireStopped[1] {
					t.Fatalf("server proof=%v", server.requireStopped)
				}
			} else if store.pending == nil || deps.LastResult.(*memoryLastResultStore).result != nil {
				t.Fatal("unproved repair changed durable state")
			}
		})
	}
}

func TestFileRepairRetirementOrdersOriginalWitnessBeforeExactClear(t *testing.T) {
	ctx := context.Background()
	storage := mustStorage(t, testStorageRoot(t, "service"), privateStorage)
	state, _ := NewFileStateStore(storage)
	last, _ := NewFileLastResultStore(storage)
	pending := suiteRepairPending(t, exitEvidence(1603))
	if err := state.Save(ctx, pending); err != nil {
		t.Fatal(err)
	}
	witness := lastResultFromPending(pending)
	// Repeating after a crash between witness and clear must be idempotent.
	if err := last.Save(ctx, witness); err != nil {
		t.Fatal(err)
	}
	if err := state.CompareAndRetireRepair(ctx, pending, last); err != nil {
		t.Fatal(err)
	}
	if got, err := last.Load(ctx); err != nil || !reflect.DeepEqual(got, &witness) {
		t.Fatalf("witness=%#v err=%v", got, err)
	}
	if got, err := state.Load(ctx); err != nil || got != nil {
		t.Fatalf("pending=%#v err=%v", got, err)
	}
	if err := state.Save(ctx, pending); err != nil {
		t.Fatal(err)
	}
	stale := pending
	stale.UpdatedAt = stale.UpdatedAt.Add(time.Second)
	if err := state.CompareAndRetireRepair(ctx, stale, last); !errors.Is(err, ErrStateConflict) {
		t.Fatalf("stale retirement=%v", err)
	}
}

func TestSuiteOpenRequiresEmptyStateAndRetriesFailedFlush(t *testing.T) {
	ctx := context.Background()
	storage := mustStorage(t, testStorageRoot(t, "service"), privateStorage)
	state, _ := NewFileStateStore(storage)
	pending := suiteRepairPending(t, exitEvidence(1603))
	if err := state.Save(ctx, pending); err != nil {
		t.Fatal(err)
	}
	writes := 0
	write := func(byte) error { writes++; return nil }
	if err := state.PublishSuiteOpen(ctx, write); !errors.Is(err, ErrStateConflict) || writes != 0 {
		t.Fatalf("opened with pending: err=%v writes=%d", err, writes)
	}
	if err := state.CompareAndClear(ctx, pending); err != nil {
		t.Fatal(err)
	}
	flushErr := errors.New("flush failed")
	if err := state.PublishSuiteOpen(ctx, func(byte) error { return flushErr }); !errors.Is(err, flushErr) {
		t.Fatalf("flush failure=%v", err)
	}
	if err := state.PublishSuiteOpen(ctx, write); err != nil || writes != 1 {
		t.Fatalf("healthy retry err=%v writes=%d", err, writes)
	}
	if err := state.BeginFinalUninstall(ctx); err != nil {
		t.Fatal(err)
	}
	if err := state.PublishSuiteOpen(ctx, write); !errors.Is(err, ErrFinalUninstallFenced) || writes != 1 {
		t.Fatalf("opened across uninstall fence: err=%v writes=%d", err, writes)
	}
}

func TestSuiteClosurePersistsDeadlineSampledBeforeStateWork(t *testing.T) {
	ctx := context.Background()
	storage := mustStorage(t, testStorageRoot(t, "service"), privateStorage)
	state, _ := NewFileStateStore(storage)
	pending := suiteRepairPending(t, exitEvidence(1603))
	if err := state.Save(ctx, pending); err != nil {
		t.Fatal(err)
	}
	closedAt := coordinatorNow.Add(time.Second)
	got, err := state.SaveSuiteDrainDeadline(ctx, pending, closedAt)
	if err != nil {
		t.Fatal(err)
	}
	want := closedAt.Add(suiteGraceDuration)
	if got.AppDrainDeadline == nil || !got.AppDrainDeadline.Equal(want) || !got.UpdatedAt.Equal(closedAt) {
		t.Fatalf("deadline=%v updatedAt=%s, want closure at %s", got.AppDrainDeadline, got.UpdatedAt, closedAt)
	}
	loaded, err := state.Load(ctx)
	if err != nil || loaded == nil || loaded.AppDrainDeadline == nil || !loaded.AppDrainDeadline.Equal(want) {
		t.Fatalf("stored deadline=%#v err=%v", loaded, err)
	}
	// A recovery closure reuses the saved deadline even after it expires.
	retried, err := state.SaveSuiteDrainDeadline(ctx, got, closedAt.Add(time.Minute))
	if err != nil || !retried.AppDrainDeadline.Equal(want) {
		t.Fatalf("retry deadline=%#v err=%v", retried.AppDrainDeadline, err)
	}
}
