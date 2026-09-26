package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

var coordinatorNow = time.Date(2026, 9, 23, 8, 0, 0, 0, time.UTC)

func TestPreparedMachineCandidateUsesPendingBeforeHandoff(t *testing.T) {
	for _, sku := range []update.SKU{update.System, update.Suite} {
		t.Run(string(sku), func(t *testing.T) {
			deps := defaultDependencies(t)
			deps.Inventory = &fakeInventory{products: []InstalledProduct{{Snapshot: oldProduct(sku)}}}
			coordinator := mustCoordinator(t, sku, deps)
			release := authorizedRelease(t, sku, "4.0.1")
			eligible, err := coordinator.Eligible(context.Background(), release)
			if err != nil || !eligible {
				t.Fatalf("candidate eligibility = %t, %v", eligible, err)
			}
			artifact := StagedArtifact{Handle: string(sku) + "/42/artifact.msi", SHA256: release.Payload().Artifact.SHA256}
			outcome, err := coordinator.InstallPrepared(context.Background(), release, artifact)
			if err != nil || outcome != OutcomeHandedOff {
				t.Fatalf("prepared install = %q, %v", outcome, err)
			}
			pending := deps.Pending.(*memoryPendingStore)
			if len(pending.phases) < 2 || pending.phases[0] != PhasePrepared || deps.Launcher.(*fakeLauncher).request.Artifact != artifact {
				t.Fatalf("pending was not recorded before launch: phases=%v", pending.phases)
			}
		})
	}
}

func TestPreparedMachineCandidateRejectsForeignSKU(t *testing.T) {
	deps := defaultDependencies(t)
	coordinator := mustCoordinator(t, update.System, deps)
	eligible, err := coordinator.Eligible(context.Background(), authorizedRelease(t, update.Suite, "4.0.1"))
	if eligible || !errors.Is(err, ErrUnauthorizedCandidate) {
		t.Fatalf("foreign candidate = %t, %v", eligible, err)
	}
}

func TestReconcileUsesProcessCreationIdentityAndFullProductHealth(t *testing.T) {
	tests := []struct {
		name       string
		products   []InstalledProduct
		healthy    bool
		exit       *ExitEvidence
		alive      bool
		want       Outcome
		wantPhase  Phase
		wantReplay bool
	}{
		{"still running", []InstalledProduct{{Snapshot: oldProduct(update.System)}}, true, exitEvidence(0), true, OutcomeStillRunning, PhaseInstallerRunning, false},
		{"healthy candidate commits", []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}}, true, exitEvidence(0), false, OutcomeCommitted, PhaseCommitted, true},
		{"failed exit with candidate requires repair", []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}}, true, exitEvidence(1603), false, OutcomeRepairRequired, PhaseRepairRequired, false},
		{"healthy old rolls back", []InstalledProduct{{Snapshot: oldProduct(update.System)}}, true, exitEvidence(1603), false, OutcomeRolledBack, PhaseRolledBack, false},
		{"reboot exit 3010 remains pending", []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}}, true, exitEvidence(3010), false, OutcomeRebootPending, PhaseRebootPending, false},
		{"reboot exit 1641 remains pending", []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}}, true, exitEvidence(1641), false, OutcomeRebootPending, PhaseRebootPending, false},
		{"missing exit with healthy old rolls back", []InstalledProduct{{Snapshot: oldProduct(update.System)}}, true, nil, false, OutcomeRolledBack, PhaseRolledBack, false},
		{"missing exit with healthy candidate needs restart proof", []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}}, true, nil, false, OutcomeOutcomeUnconfirmed, PhaseOutcomeUnconfirmed, false},
		{"partial candidate repairs", []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}}, false, exitEvidence(0), false, OutcomeRepairRequired, PhaseRepairRequired, false},
		{"zero products repairs", nil, false, exitEvidence(0), false, OutcomeRepairRequired, PhaseRepairRequired, false},
		{"two products repair", []InstalledProduct{{Snapshot: oldProduct(update.System)}, {Snapshot: candidateProduct(t, update.System, "4.0.1")}}, true, exitEvidence(0), false, OutcomeRepairRequired, PhaseRepairRequired, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			deps := defaultDependencies(t)
			pending := pendingForReconcile(t, test.exit)
			deps.Pending = &memoryPendingStore{pending: &pending}
			deps.Inventory = &fakeInventory{products: test.products}
			deps.Health = fakeHealthProbe{healthy: test.healthy}
			deps.Processes = &fakeProcessProbe{alive: test.alive}
			coordinator := mustCoordinator(t, update.System, deps)
			outcome, err := coordinator.Reconcile(context.Background())
			if err != nil || outcome != test.want {
				t.Fatalf("Reconcile() = %q, %v; want %q", outcome, err, test.want)
			}
			stored := deps.Pending.(*memoryPendingStore).pending
			if stored == nil || stored.Phase != test.wantPhase {
				t.Fatalf("stored phase = %#v; want %q", stored, test.wantPhase)
			}
			gotReplay := deps.Replay.(*memoryReplayStore).saves > 0
			if gotReplay != test.wantReplay {
				t.Fatalf("replay advanced = %v; want %v", gotReplay, test.wantReplay)
			}
			if test.alive {
				probe := deps.Processes.(*fakeProcessProbe)
				if len(probe.seen) == 0 || probe.seen[0].CreatedAtUnixNano == 0 {
					t.Fatal("process probe did not receive PID plus creation time")
				}
			}
		})
	}
}

func TestReconcileRebootCodeRequiresDifferentBootAndHealthyCandidate(t *testing.T) {
	for _, test := range []struct {
		name       string
		exit       *ExitEvidence
		boot       fixedBootID
		healthy    bool
		want       Outcome
		wantReplay bool
	}{
		{"same boot", exitEvidence(3010), "boot-one", true, OutcomeRebootPending, false},
		{"later boot", exitEvidence(3010), "boot-two", true, OutcomeCommitted, true},
		{"restart code later boot", exitEvidence(1641), "boot-two", true, OutcomeCommitted, true},
		{"missing exit later boot", nil, "boot-two", true, OutcomeCommitted, true},
		{"unhealthy later boot", exitEvidence(3010), "boot-two", false, OutcomeRepairRequired, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			deps := defaultDependencies(t)
			pending := pendingForReconcile(t, test.exit)
			deps.Pending = &memoryPendingStore{pending: &pending}
			deps.Inventory = &fakeInventory{products: []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}}}
			deps.Health = fakeHealthProbe{healthy: test.healthy}
			deps.Boot = test.boot
			coordinator := mustCoordinator(t, update.System, deps)
			outcome, err := coordinator.Reconcile(context.Background())
			if err != nil || outcome != test.want {
				t.Fatalf("Reconcile() = %q, %v; want %q", outcome, err, test.want)
			}
			if replayed := deps.Replay.(*memoryReplayStore).saves > 0; replayed != test.wantReplay {
				t.Fatalf("replay advanced = %v; want %v", replayed, test.wantReplay)
			}
		})
	}
}

func TestReconcileBoundsInstallerBusyRetries(t *testing.T) {
	for _, attempt := range []uint{1, 3} {
		deps := defaultDependencies(t)
		pending := pendingForReconcile(t, exitEvidence(1618))
		pending.Schema = PendingSchemaV2
		deadline := pending.PreparedAt.Add(10 * time.Minute)
		pending.RetryDeadline = &deadline
		pending.Attempt = attempt
		deps.Pending = &memoryPendingStore{pending: &pending}
		deps.Inventory = &fakeInventory{products: []InstalledProduct{{Snapshot: oldProduct(update.System)}}}
		coordinator := mustCoordinator(t, update.System, deps)
		outcome, err := coordinator.Reconcile(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		stored := deps.Pending.(*memoryPendingStore).pending
		if attempt < 3 {
			if outcome != OutcomeBackoff || stored.Result != ResultRetryScheduled || stored.NextAttemptAt == nil {
				t.Fatalf("attempt %d was not scheduled: %q %#v", attempt, outcome, stored)
			}
		} else if outcome != OutcomeRolledBack || stored.NextAttemptAt != nil || stored.Result != ResultBusyExhausted {
			t.Fatalf("attempt %d exceeded bound incorrectly: %q %#v", attempt, outcome, stored)
		}
	}
}

func TestReconcileWaitsForMSIServerBeforeAndAfterHealth(t *testing.T) {
	for _, busyOnCall := range []int{1, 2} {
		deps := defaultDependencies(t)
		pending := pendingForReconcile(t, exitEvidence(0))
		deps.Pending = &memoryPendingStore{pending: &pending}
		deps.Inventory = &fakeInventory{products: []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}}}
		probe := &fakeInstallerServerProbe{busyOnCall: busyOnCall}
		deps.InstallerServer = probe
		coordinator := mustCoordinator(t, update.System, deps)
		outcome, err := coordinator.Reconcile(context.Background())
		if err != nil || outcome != OutcomeStillRunning || deps.Replay.(*memoryReplayStore).saves != 0 {
			t.Fatalf("busy observation %d: outcome=%q err=%v replay advanced", busyOnCall, outcome, err)
		}
		if deps.Pending.(*memoryPendingStore).pending.Phase != PhaseInstallerRunning {
			t.Fatalf("busy observation %d changed durable phase", busyOnCall)
		}
	}
}

func TestMissingExitRequiresStoppedMSIServer(t *testing.T) {
	deps := defaultDependencies(t)
	pending := pendingForReconcile(t, nil)
	deps.Pending = &memoryPendingStore{pending: &pending}
	deps.Inventory = &fakeInventory{products: []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}}}
	probe := &fakeInstallerServerProbe{}
	deps.InstallerServer = probe
	coordinator := mustCoordinator(t, update.System, deps)
	if outcome, err := coordinator.Reconcile(context.Background()); err != nil || outcome != OutcomeOutcomeUnconfirmed {
		t.Fatalf("missing exit = %q, %v", outcome, err)
	}
	if len(probe.requireStopped) != 2 || !probe.requireStopped[0] || !probe.requireStopped[1] {
		t.Fatalf("missing-exit server probes = %v", probe.requireStopped)
	}
}

func TestOutcomeUnconfirmedRechecksServerAndHealthAfterRestart(t *testing.T) {
	deps := defaultDependencies(t)
	pending := pendingForReconcile(t, nil)
	pending.Phase = PhaseOutcomeUnconfirmed
	pending.Result = ResultOutcomeUnconfirmed
	deps.Pending = &memoryPendingStore{pending: &pending}
	deps.Inventory = &fakeInventory{products: []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}}}
	probe := &fakeInstallerServerProbe{busyOnCall: 1}
	deps.InstallerServer = probe
	deps.Boot = fixedBootID("boot-one")
	beforeRestart := mustCoordinator(t, update.System, deps)
	if outcome, err := beforeRestart.Reconcile(context.Background()); err != nil || outcome != OutcomeOutcomeUnconfirmed {
		t.Fatalf("same-boot unconfirmed outcome = %q, %v", outcome, err)
	}
	if probe.calls != 0 || deps.Replay.(*memoryReplayStore).saves != 0 {
		t.Fatal("same-boot unconfirmed outcome was reclassified")
	}
	deps.Boot = fixedBootID("boot-two")
	coordinator := mustCoordinator(t, update.System, deps)
	if outcome, err := coordinator.Reconcile(context.Background()); err != nil || outcome != OutcomeStillRunning {
		t.Fatalf("busy server after restart = %q, %v", outcome, err)
	}
	if deps.Replay.(*memoryReplayStore).saves != 0 || deps.Pending.(*memoryPendingStore).pending.Phase != PhaseOutcomeUnconfirmed {
		t.Fatal("busy server retired unconfirmed outcome")
	}
	if outcome, err := coordinator.Reconcile(context.Background()); err != nil || outcome != OutcomeCommitted {
		t.Fatalf("healthy candidate after server settles = %q, %v", outcome, err)
	}
	if deps.Replay.(*memoryReplayStore).saves != 1 {
		t.Fatal("verified candidate did not advance replay after restart")
	}
}

func TestReconcileDiscardsChangingInventoryObservation(t *testing.T) {
	deps := defaultDependencies(t)
	pending := pendingForReconcile(t, exitEvidence(0))
	deps.Pending = &memoryPendingStore{pending: &pending}
	deps.Inventory = &fakeInventory{
		products:      []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}},
		productsAfter: []InstalledProduct{{Snapshot: oldProduct(update.System)}},
	}
	coordinator := mustCoordinator(t, update.System, deps)
	outcome, err := coordinator.Reconcile(context.Background())
	if err != nil || outcome != OutcomeStillRunning || deps.Replay.(*memoryReplayStore).saves != 0 {
		t.Fatalf("changing inventory observation committed: outcome=%q err=%v", outcome, err)
	}
}

func TestReconcilePreservesInstallerBusyRetryDeadline(t *testing.T) {
	deps := defaultDependencies(t)
	pending := pendingForReconcile(t, exitEvidence(1618))
	pending.Phase = PhaseRolledBack
	pending.Result = ResultRetryScheduled
	deadline := coordinatorNow.Add(3 * time.Minute)
	retryDeadline := pending.PreparedAt.Add(10 * time.Minute)
	pending.NextAttemptAt = &deadline
	pending.RetryDeadline = &retryDeadline
	deps.Pending = &memoryPendingStore{pending: &pending}
	coordinator := mustCoordinator(t, update.System, deps)

	outcome, err := coordinator.Reconcile(context.Background())
	if err != nil || outcome != OutcomeBackoff {
		t.Fatalf("Reconcile() = %q, %v", outcome, err)
	}
	stored := deps.Pending.(*memoryPendingStore).pending
	if stored == nil || stored.NextAttemptAt == nil || !stored.NextAttemptAt.Equal(deadline) {
		t.Fatalf("retry deadline slid from %v to %#v", deadline, stored)
	}
}

func TestReconcileDoesNotOverwriteConcurrentRunnerRecord(t *testing.T) {
	deps := defaultDependencies(t)
	pending := pendingForReconcile(t, exitEvidence(0))
	deps.Pending.(*memoryPendingStore).pending = &pending
	newer := pending
	newer.UpdatedAt = coordinatorNow.Add(time.Second)
	deps.Health = fakeHealthProbe{healthy: true, afterCheck: func() {
		deps.Pending.(*memoryPendingStore).pending = &newer
	}}
	deps.Inventory.(*fakeInventory).products = []InstalledProduct{{Snapshot: pending.Candidate}}
	coordinator := mustCoordinator(t, update.System, deps)
	if _, err := coordinator.Reconcile(context.Background()); !errors.Is(err, ErrStateConflict) {
		t.Fatalf("Reconcile() error = %v; want state conflict", err)
	}
	if got := deps.Pending.(*memoryPendingStore).pending; got == nil || got.UpdatedAt != newer.UpdatedAt || got.Phase != newer.Phase {
		t.Fatalf("newer runner record was overwritten: %#v", got)
	}
	if deps.Replay.(*memoryReplayStore).saves != 0 {
		t.Fatal("replay advanced despite pending state conflict")
	}
}

func TestReconcileResumesReplayAfterCommittedState(t *testing.T) {
	deps := defaultDependencies(t)
	pending := pendingForReconcile(t, exitEvidence(0))
	pending.Phase = PhaseCommitted
	pending.Result = ResultInstalled
	deps.Pending.(*memoryPendingStore).pending = &pending
	coordinator := mustCoordinator(t, update.System, deps)
	if outcome, err := coordinator.Reconcile(context.Background()); err != nil || outcome != OutcomeCommitted {
		t.Fatalf("Reconcile() = %q, %v", outcome, err)
	}
	if deps.Replay.(*memoryReplayStore).saves != 1 {
		t.Fatal("committed replay was not resumed")
	}
	if deps.Pending.(*memoryPendingStore).pending != nil || deps.LastResult.(*memoryLastResultStore).result == nil {
		t.Fatal("committed transaction was not durably retired after replay and last result")
	}
	if deps.Inventory.(*fakeInventory).calls != 0 {
		t.Fatal("committed transaction was reclassified")
	}
}

func TestReconcileRetiresHealthyOldTerminalResult(t *testing.T) {
	deps := defaultDependencies(t)
	pending := pendingForReconcile(t, exitEvidence(1603))
	pending.Phase, pending.Result = PhaseRolledBack, ResultRolledBack
	deps.Pending.(*memoryPendingStore).pending = &pending
	coordinator := mustCoordinator(t, update.System, deps)
	if outcome, err := coordinator.Reconcile(context.Background()); err != nil || outcome != OutcomeRolledBack {
		t.Fatalf("Reconcile() = %q, %v", outcome, err)
	}
	if deps.Pending.(*memoryPendingStore).pending != nil || deps.LastResult.(*memoryLastResultStore).result == nil {
		t.Fatal("rolled-back result was not retained and retired")
	}
	if deps.Replay.(*memoryReplayStore).saves != 0 {
		t.Fatal("failed transaction advanced replay")
	}
}

type fixedRetryGate bool

func (gate fixedRetryGate) AllowRetry(context.Context, PendingV1) (bool, error) {
	return bool(gate), nil
}

func TestPreparedRetrySurvivesCrashBeforeRunnerCreation(t *testing.T) {
	deps := defaultDependencies(t)
	pending := pendingForReconcile(t, nil)
	pending.Schema, pending.Phase, pending.Result = PendingSchemaV2, PhasePrepared, ResultNone
	pending.Attempt = 2
	deadline := pending.PreparedAt.Add(10 * time.Minute)
	pending.RetryDeadline = &deadline
	pending.Runner, pending.Installer, pending.InstallerThread, pending.Exit = nil, nil, nil, nil
	deps.Pending.(*memoryPendingStore).pending = &pending
	deps.RetryGate = fixedRetryGate(true)
	coordinator := mustCoordinator(t, update.System, deps)
	if outcome, err := coordinator.Reconcile(context.Background()); err != nil || outcome != OutcomeBackoff {
		t.Fatalf("prepared retry reconcile = %q, %v", outcome, err)
	}
	if stored := deps.Pending.(*memoryPendingStore).pending; stored == nil || stored.Phase != PhasePrepared || stored.Attempt != 2 {
		t.Fatalf("prepared retry was lost: %#v", stored)
	}
	if outcome, err := coordinator.ResumePreparedRetry(context.Background()); err != nil || outcome != OutcomeHandedOff {
		t.Fatalf("prepared retry resume = %q, %v", outcome, err)
	}
	if launcher := deps.Launcher.(*fakeLauncher); launcher.calls != 1 || launcher.request.Attempt != 2 || launcher.request.Artifact.SHA256 != pending.ArtifactSHA256 {
		t.Fatalf("prepared retry changed authorization: %#v", launcher)
	}

}

func TestRecoveryOnlyCoordinatorResumesPreparedRetryWithoutDiscovery(t *testing.T) {
	deps := defaultDependencies(t)
	pending := pendingForReconcile(t, nil)
	pending.Schema, pending.Phase, pending.Result = PendingSchemaV2, PhasePrepared, ResultNone
	pending.Attempt = 2
	deadline := pending.PreparedAt.Add(10 * time.Minute)
	pending.RetryDeadline = &deadline
	pending.Runner, pending.Installer, pending.InstallerThread, pending.Exit = nil, nil, nil, nil
	deps.Pending.(*memoryPendingStore).pending = &pending
	deps.RetryGate = fixedRetryGate(true)
	coordinator, err := NewReconciler(Config{SKU: update.System, MaxInstallerBusyRetries: 3}, deps)
	if err != nil {
		t.Fatal(err)
	}
	if outcome, err := coordinator.ResumePreparedRetry(context.Background()); err != nil || outcome != OutcomeHandedOff {
		t.Fatalf("recovery-only retry = %q, %v", outcome, err)
	}
	if launcher := deps.Launcher.(*fakeLauncher); launcher.calls != 1 || launcher.request.Attempt != 2 {
		t.Fatalf("recovery-only launcher = %#v", launcher)
	}
}

func TestExpiredPreparedRetryRetiresOnlyAfterOldProductHealth(t *testing.T) {
	deps := defaultDependencies(t)
	pending := pendingForReconcile(t, nil)
	pending.Schema, pending.Phase, pending.Result = PendingSchemaV2, PhasePrepared, ResultNone
	pending.Attempt = 2
	deadline := coordinatorNow.Add(-time.Second)
	pending.RetryDeadline = &deadline
	pending.Runner, pending.Installer, pending.InstallerThread, pending.Exit = nil, nil, nil, nil
	deps.Pending.(*memoryPendingStore).pending = &pending
	coordinator := mustCoordinator(t, update.System, deps)
	if outcome, err := coordinator.Reconcile(context.Background()); err != nil || outcome != OutcomeRolledBack {
		t.Fatalf("expired prepared retry = %q, %v", outcome, err)
	}
	if deps.Pending.(*memoryPendingStore).pending != nil || deps.LastResult.(*memoryLastResultStore).result.Result != ResultBusyExhausted {
		t.Fatal("expired prepared retry did not retire with busy-exhausted evidence")
	}
}

func TestRecoveryOnlyCoordinatorReconcilesWithoutDiscoveryAuthority(t *testing.T) {
	deps := defaultDependencies(t)
	pending := pendingForReconcile(t, exitEvidence(0))
	deps.Pending.(*memoryPendingStore).pending = &pending
	deps.Inventory.(*fakeInventory).products = []InstalledProduct{{Snapshot: pending.Candidate}}
	deps.Launcher = nil
	deps.IDs = nil
	coordinator, err := NewReconciler(Config{SKU: update.System, MaxInstallerBusyRetries: 3}, deps)
	if err != nil {
		t.Fatal(err)
	}
	if outcome, err := coordinator.Reconcile(context.Background()); err != nil || outcome != OutcomeCommitted {
		t.Fatalf("recovery-only Reconcile() = %q, %v", outcome, err)
	}

}

func defaultDependencies(t *testing.T) Dependencies {
	t.Helper()
	pending := &memoryPendingStore{}
	return Dependencies{
		Inventory:       &fakeInventory{products: []InstalledProduct{{Snapshot: oldProduct(update.System)}}},
		Launcher:        &fakeLauncher{pending: pending, receipt: HandoffReceipt{Runner: ProcessIdentity{PID: 41, CreatedAtUnixNano: 1001}, Installer: ProcessIdentity{PID: 42, CreatedAtUnixNano: 1002}, Ready: true}},
		Health:          fakeHealthProbe{healthy: true},
		Processes:       &fakeProcessProbe{},
		InstallerServer: &fakeInstallerServerProbe{},
		Pending:         pending,
		Replay:          &memoryReplayStore{},
		LastResult:      &memoryLastResultStore{},
		Events:          &memoryEventSink{},
		Clock:           fixedClock{coordinatorNow},
		Boot:            fixedBootID("boot-one"),
		IDs:             fixedIDs("tx-123"),
	}
}

func mustCoordinator(t *testing.T, sku update.SKU, deps Dependencies) *Coordinator {
	t.Helper()
	coordinator, err := NewCoordinator(Config{SKU: sku, MaxInstallerBusyRetries: 3}, deps)
	if err != nil {
		t.Fatal(err)
	}
	return coordinator
}

type fakeInstallerServerProbe struct {
	busyOnCall     int
	calls          int
	requireStopped []bool
}

func (probe *fakeInstallerServerProbe) Idle(_ context.Context, requireStopped bool) (bool, error) {
	probe.calls++
	probe.requireStopped = append(probe.requireStopped, requireStopped)
	return probe.calls != probe.busyOnCall, nil
}

type fakeInventory struct {
	products      []InstalledProduct
	productsAfter []InstalledProduct
	calls         int
	err           error
}

func (f *fakeInventory) Products(context.Context) ([]InstalledProduct, error) {
	f.calls++
	if f.calls > 1 && f.productsAfter != nil {
		return append([]InstalledProduct(nil), f.productsAfter...), f.err
	}
	return append([]InstalledProduct(nil), f.products...), f.err
}

type fakeLauncher struct {
	calls   int
	receipt HandoffReceipt
	request HandoffRequest
	pending *memoryPendingStore
	exit    *ExitEvidence
}

func (f *fakeLauncher) Launch(_ context.Context, request HandoffRequest) (HandoffReceipt, error) {
	f.calls++
	f.request = request
	if f.pending != nil && f.pending.pending != nil && f.receipt.Ready {
		pending := *f.pending.pending
		pending.Runner = &f.receipt.Runner
		pending.Installer = &f.receipt.Installer
		pending.Phase = PhaseInstallerRunning
		pending.Exit = f.exit
		_ = f.pending.Save(context.Background(), pending)
	}
	return f.receipt, nil
}

type fakeHealthProbe struct {
	healthy    bool
	afterCheck func()
}

func (f fakeHealthProbe) Healthy(context.Context, ProductSnapshot) (bool, error) {
	if f.afterCheck != nil {
		f.afterCheck()
	}
	return f.healthy, nil
}

type fakeProcessProbe struct {
	alive bool
	seen  []ProcessIdentity
}

func (f *fakeProcessProbe) Alive(_ context.Context, identity ProcessIdentity) (bool, error) {
	f.seen = append(f.seen, identity)
	return f.alive, nil
}

type memoryPendingStore struct {
	pending *PendingV1
	phases  []Phase
}

func (m *memoryPendingStore) Load(context.Context) (*PendingV1, error) {
	if m.pending == nil {
		return nil, nil
	}
	p := *m.pending
	return &p, nil
}
func (m *memoryPendingStore) Save(_ context.Context, pending PendingV1) error {
	p := pending
	m.pending = &p
	m.phases = append(m.phases, pending.Phase)
	return nil
}
func (m *memoryPendingStore) CompareAndSave(ctx context.Context, expected *PendingV1, pending PendingV1) error {
	if expected == nil {
		if m.pending != nil {
			return ErrStateConflict
		}
	} else if m.pending == nil || !reflect.DeepEqual(*m.pending, *expected) {
		return ErrStateConflict
	}
	return m.Save(ctx, pending)
}
func (m *memoryPendingStore) CompareAndClear(_ context.Context, expected PendingV1) error {
	if m.pending == nil || !reflect.DeepEqual(*m.pending, expected) {
		return ErrStateConflict
	}
	m.pending = nil
	return nil
}

type memoryReplayStore struct {
	state update.ReplayState
	saves int
}

type memoryLastResultStore struct {
	result *LastResultV1
	saves  int
}

func (m *memoryLastResultStore) Load(context.Context) (*LastResultV1, error) { return m.result, nil }
func (m *memoryLastResultStore) Save(_ context.Context, result LastResultV1) error {
	m.result = &result
	m.saves++
	return nil
}

func (m *memoryReplayStore) Load(context.Context, update.SKU) (update.ReplayState, error) {
	return m.state, nil
}
func (m *memoryReplayStore) Save(_ context.Context, state update.ReplayState) error {
	m.state = state
	m.saves++
	return nil
}

type memoryEventSink struct{ events []Event }

func (m *memoryEventSink) Record(_ context.Context, event Event) {
	m.events = append(m.events, event)
}

type fixedClock struct{ now time.Time }

func (f fixedClock) Now() time.Time { return f.now }

type fixedIDs string

func (f fixedIDs) NewID() string { return string(f) }

func oldProduct(sku update.SKU) ProductSnapshot {
	return ProductSnapshot{SKU: sku, PackageVersion: "4.0.0", ProductVersion: "4.0.0", ProductCode: "OLD", Contained: map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}}
}

func candidateProduct(t *testing.T, sku update.SKU, version string) ProductSnapshot {
	t.Helper()
	product, err := productFromRelease(authorizedRelease(t, sku, version))
	if err != nil {
		t.Fatal(err)
	}
	return product
}

func pendingForReconcile(t *testing.T, exit *ExitEvidence) PendingV1 {
	t.Helper()
	release := authorizedRelease(t, update.System, "4.0.1")
	replay, err := update.AcceptReplay(update.ReplayState{}, release)
	if err != nil {
		t.Fatal(err)
	}
	return PendingV1{
		Schema: PendingSchemaV2, TransactionID: "tx-123", SKU: update.System,
		Old: oldProduct(update.System), Candidate: mustProductFromRelease(t, release), Replay: replay,
		ArtifactSHA256: release.Payload().Artifact.SHA256, Phase: PhaseInstallerRunning,
		LaunchBootID: "boot-one",
		Runner:       &ProcessIdentity{PID: 41, CreatedAtUnixNano: 1001}, Installer: &ProcessIdentity{PID: 42, CreatedAtUnixNano: 1002}, Exit: exit,
		PreparedAt: coordinatorNow.Add(-time.Minute), UpdatedAt: coordinatorNow, Attempt: 1,
	}
}

type fixedBootID string

func (boot fixedBootID) CurrentBootID(context.Context) (string, error) { return string(boot), nil }

func mustProductFromRelease(t *testing.T, release update.Release) ProductSnapshot {
	t.Helper()
	product, err := productFromRelease(release)
	if err != nil {
		t.Fatal(err)
	}
	return product
}

func exitEvidence(code uint32) *ExitEvidence {
	return &ExitEvidence{Code: code, ObservedAt: coordinatorNow}
}

func authorizedRelease(t *testing.T, sku update.SKU, version string) update.Release {
	t.Helper()
	body := []byte("verified installer")
	sum := sha256.Sum256(body)
	upgrade := "B3C97B33-3F10-47CA-9FA7-24EE3B75E325"
	contained := []update.ContainedComponent{{Component: "service", Version: version}, {Component: "interceptor", Version: version}}
	compatibility := []update.Requirement{{Component: "service", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}, {Component: "interceptor", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}}
	if sku == update.Suite {
		upgrade = "2E050A24-94A2-4FC9-B176-C5CCC1225FE6"
		contained = append(contained, update.ContainedComponent{Component: "app", Version: version})
		compatibility = append(compatibility, update.Requirement{Component: "app", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"})
	}
	identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(sku), version)
	if err != nil {
		t.Fatal(err)
	}
	payload := update.Payload{Schema: update.MachineTargetsSchema, SKU: sku, ProductCode: identity.ProductCode, UpgradeCode: upgrade, Version: version, QueueProtocol: "queue-v1", Sequence: identity.Sequence, IssuedAt: coordinatorNow.Add(-time.Hour).Format(time.RFC3339), ExpiresAt: coordinatorNow.Add(time.Hour).Format(time.RFC3339), Contained: contained, Compatibility: compatibility, Artifact: update.Artifact{URL: "https://github.com/marcfargas/go-mapi/releases/download/" + string(sku) + "-v" + version + "/go-mapi-" + string(sku) + "-" + version + "-x64.msi", Size: int64(len(body)), SHA256: hex.EncodeToString(sum[:])}}
	raw, _ := json.Marshal(payload)
	installed := map[string]string{"service": "4.0.0", "interceptor": "4.0.0", "app": "4.0.0"}
	release, err := update.ParseTarget(sku, raw, installed, coordinatorNow, update.MachineArtifactOrigin)
	if err != nil {
		t.Fatal(err)
	}
	return release
}

func TestHandoffRequestHasNoInstallerArgumentsOrReleaseURL(t *testing.T) {
	typeOf := reflect.TypeOf(HandoffRequest{})
	for i := 0; i < typeOf.NumField(); i++ {
		name := strings.ToLower(typeOf.Field(i).Name)
		if strings.Contains(name, "argument") || strings.Contains(name, "property") || strings.Contains(name, "url") {
			t.Fatalf("privileged handoff exposes caller-controlled field %q", typeOf.Field(i).Name)
		}
	}
}
