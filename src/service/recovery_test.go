package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

type launchFunc func(context.Context, HandoffRequest) (HandoffReceipt, error)

func (f launchFunc) Launch(ctx context.Context, r HandoffRequest) (HandoffReceipt, error) {
	return f(ctx, r)
}

type recoveryClock struct{ now time.Time }

func (c *recoveryClock) Now() time.Time { return c.now }

type recoveryIDs struct{ count int }

func (i *recoveryIDs) NewID() string { i.count++; return fmt.Sprintf("recovery-%d", i.count) }

type recoveryHarness struct {
	c        *Coordinator
	storage  *ProtectedStorage
	state    *FileStateStore
	journal  *FileRecoveryStore
	clock    *recoveryClock
	marker   machineProductMarker
	enabled  bool
	launches int
	fail     bool
}

func newRecoveryHarness(t *testing.T, sku update.SKU) *recoveryHarness {
	t.Helper()
	storage := mustStorage(t, testStorageRoot(t, "recovery"), privateStorage)
	state, _ := NewFileStateStore(storage)
	journal, _ := NewFileRecoveryStore(storage)
	h := &recoveryHarness{storage: storage, state: state, journal: journal, clock: &recoveryClock{coordinatorNow}, enabled: true, fail: true}
	h.marker = machineProductMarker{SKU: string(sku), PackageRelease: "4.0.0", ServiceVersion: "4.0.0", InterceptorVersion: "4.0.0"}
	deps := defaultDependencies(t)
	deps.Pending = state
	deps.Recovery = journal
	deps.Clock = h.clock
	deps.IDs = &recoveryIDs{}
	deps.Inventory = &fakeInventory{products: []InstalledProduct{{Snapshot: oldProduct(sku)}}}
	deps.RecoveryLock = func() (func(), error) { return func() {}, nil }
	deps.PrepareAuthorization, _ = NewFilePreparationAuthorizer(storage, func(context.Context) (machineProductMarker, bool, error) { return h.marker, h.enabled, nil })
	deps.ObservePreparation = func(context.Context) (PreparationObservation, error) {
		return PreparationObservation{Product: deps.Inventory.(*fakeInventory).products[0].Snapshot, Marker: h.marker, Enabled: h.enabled}, nil
	}
	deps.Launcher = launchFunc(func(ctx context.Context, request HandoffRequest) (HandoffReceipt, error) {
		h.launches++
		receipt := HandoffReceipt{Runner: ProcessIdentity{PID: uint32(100 + h.launches), CreatedAtUnixNano: int64(1000 + h.launches)}}
		if h.fail {
			return receipt, errors.New("controlled no readiness")
		}
		p, err := state.Load(ctx)
		if err != nil {
			return receipt, err
		}
		previous := *p
		receipt.Installer = ProcessIdentity{PID: uint32(200 + h.launches), CreatedAtUnixNano: int64(2000 + h.launches)}
		receipt.Ready = true
		p.Runner, p.Installer = &receipt.Runner, &receipt.Installer
		p.Phase = PhaseInstallerRunning
		p.Exit = &ExitEvidence{Code: 0, ObservedAt: h.clock.Now()}
		return receipt, state.CompareAndSave(ctx, &previous, *p)
	})
	h.c = mustCoordinator(t, sku, deps)
	return h
}
func (h *recoveryHarness) install(t *testing.T, version string) error {
	t.Helper()
	release := authorizedRelease(t, h.c.config.SKU, version)
	_, err := h.c.InstallPrepared(context.Background(), release, StagedArtifact{Handle: string(h.c.config.SKU) + "/42/artifact.msi", SHA256: release.Payload().Artifact.SHA256})
	return err
}
func (h *recoveryHarness) record(t *testing.T) *RecoveryV1 {
	t.Helper()
	r, err := h.journal.Load(context.Background(), h.c.config.SKU)
	if err != nil || r == nil {
		t.Fatalf("journal=%+v %v", r, err)
	}
	return r
}
func (h *recoveryHarness) reconstruct(t *testing.T) {
	t.Helper()
	journal, _ := NewFileRecoveryStore(h.storage)
	h.journal = journal
	deps := h.c.deps
	deps.Recovery = journal
	h.c = mustCoordinator(t, h.c.config.SKU, deps)
}
func (h *recoveryHarness) reconcile(t *testing.T) Outcome {
	t.Helper()
	o, err := h.c.Reconcile(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return o
}

func TestReadinessRecoveryPersistsThreeLaunchBudgetBothSKUs(t *testing.T) {
	for _, sku := range []update.SKU{update.System, update.Suite} {
		t.Run(string(sku), func(t *testing.T) {
			h := newRecoveryHarness(t, sku)
			var previousID string
			for attempt := uint(1); attempt <= 3; attempt++ {
				if err := h.install(t, "4.0.1"); err == nil {
					t.Fatal("obstructed handoff passed")
				}
				r := h.record(t)
				if r.Consumed != attempt || r.Failures != attempt || r.Reservation.TransactionID == previousID {
					t.Fatalf("bad reservation %+v", r)
				}
				previousID = r.Reservation.TransactionID
				due := r.DueAt
				delay := 15 * time.Minute
				if attempt > 1 {
					delay = 30 * time.Minute
				}
				if !due.Equal(h.clock.Now().Add(delay)) {
					t.Fatalf("due=%v want %v", due, h.clock.Now().Add(delay))
				}
				h.reconstruct(t)
				h.reconcile(t)
				p, _ := h.state.Load(context.Background())
				if p != nil {
					t.Fatalf("pending not fenced/retired: %+v", p)
				}
				if h.record(t).DueAt != due {
					t.Fatal("restart moved due")
				}
				if h.c.deps.LastResult.(*memoryLastResultStore).result != nil {
					t.Fatal("no-install became MSI rollback")
				}
				h.clock.now = due
			}
			if r := h.record(t); r.Stage != "exhausted" || r.Reason != "readiness-exhausted" {
				t.Fatalf("not exhausted: %+v", r)
			}
			h.fail = false
			h.enabled = false
			h.reconstruct(t)
			h.enabled = true
			h.clock.now = h.clock.now.Add(48 * time.Hour)
			if err := h.install(t, "4.0.1"); err == nil || h.launches != 3 {
				t.Fatalf("exhausted target relaunched: %v, %d", err, h.launches)
			}
		})
	}
}
func TestReadinessTransientRecoveryCommitsFreshTransaction(t *testing.T) {
	for _, sku := range []update.SKU{update.System, update.Suite} {
		t.Run(string(sku), func(t *testing.T) {
			h := newRecoveryHarness(t, sku)
			_ = h.install(t, "4.0.1")
			first := h.record(t)
			h.reconcile(t)
			h.clock.now = first.DueAt
			h.fail = false
			if err := h.install(t, "4.0.1"); err != nil {
				t.Fatal(err)
			}
			r := h.record(t)
			if r.Reservation.TransactionID == first.Reservation.TransactionID || r.Consumed != 2 {
				t.Fatalf("reused grant %+v", r)
			}
			h.c.deps.Inventory = &fakeInventory{products: []InstalledProduct{{Snapshot: r.Reservation.Candidate}}}
			if o := h.reconcile(t); o != OutcomeCommitted {
				t.Fatal(o)
			}
			h.reconcile(t)
			if r := h.record(t); r.Stage != "completed" {
				t.Fatalf("completion lost: %+v", r)
			}
		})
	}
}
func TestReadinessSafetyBlocksWithoutMovingDueOrCount(t *testing.T) {
	for _, test := range []struct {
		name   string
		change func(*recoveryHarness)
	}{
		{"runner lock", func(h *recoveryHarness) { h.c.deps.RecoveryLock = func() (func(), error) { return nil, ErrBusy } }},
		{"live process", func(h *recoveryHarness) { h.c.deps.Processes = &fakeProcessProbe{alive: true} }},
		{"installer busy", func(h *recoveryHarness) { h.c.deps.InstallerServer = &fakeInstallerServerProbe{busyOnCall: 1} }},
		{"changed product", func(h *recoveryHarness) { h.c.deps.Inventory = &fakeInventory{} }},
		{"unhealthy", func(h *recoveryHarness) { h.c.deps.Health = fakeHealthProbe{healthy: false} }},
	} {
		t.Run(test.name, func(t *testing.T) {
			h := newRecoveryHarness(t, update.System)
			_ = h.install(t, "4.0.1")
			before := h.record(t)
			test.change(h)
			h.reconcile(t)
			after := h.record(t)
			p, _ := h.state.Load(context.Background())
			if after.Stage != "safety-blocked" || after.DueAt != before.DueAt || after.Consumed != before.Consumed || p == nil || p.Phase != PhasePrepared || h.launches != 1 {
				t.Fatalf("unsafe recovery %+v %+v", after, p)
			}
		})
	}
}

type recoveryFaultPlatform struct {
	storagePlatform
	target    string
	remaining int
}

func (p *recoveryFaultPlatform) replace(source, destination string) error {
	if filepath.Base(destination) == p.target {
		p.remaining--
		if p.remaining == 0 {
			return errors.New("injected replace failure")
		}
	}
	return p.storagePlatform.replace(source, destination)
}
func TestRecoveryReconstructsOrderedWriteCuts(t *testing.T) {
	for _, cut := range []string{"reservation", "pending", "fence", "witness", "clear"} {
		t.Run(cut, func(t *testing.T) {
			h := newRecoveryHarness(t, update.System)
			platform := h.storage.platform
			if cut == "reservation" || cut == "pending" {
				target := "pending-v2.json"
				if cut == "reservation" {
					target = "recovery-system-v1.json"
				}
				h.storage.platform = &recoveryFaultPlatform{storagePlatform: platform, target: target, remaining: 1}
			}
			_ = h.install(t, "4.0.1")
			h.storage.platform = platform
			if cut == "reservation" {
				if r, _ := h.journal.Load(context.Background(), update.System); r != nil {
					t.Fatal("failed reservation consumed")
				}
				if h.launches != 0 {
					t.Fatal("spawn without reservation")
				}
				return
			}
			r := h.record(t)
			if cut == "pending" {
				if h.launches != 0 {
					t.Fatal("spawn after pending failure")
				}
				h.clock.now = r.LaunchDeadline
			}
			if cut == "fence" || cut == "witness" {
				target := "pending-v2.json"
				if cut == "witness" {
					target = "recovery-system-v1.json"
				}
				h.storage.platform = &recoveryFaultPlatform{storagePlatform: platform, target: target, remaining: 1}
				if _, err := h.c.Reconcile(context.Background()); err == nil {
					t.Fatal("injection did not fire")
				}
				h.storage.platform = platform
			}
			if cut == "clear" {
				h.storage.platform = &recoveryClearFaultPlatform{storagePlatform: platform, root: h.storage.root}
				if _, err := h.c.Reconcile(context.Background()); err == nil {
					t.Fatal("clear fault missed")
				}
				h.storage.platform = platform
			}
			h.reconstruct(t)
			h.reconcile(t)
			after := h.record(t)
			p, _ := h.state.Load(context.Background())
			if p != nil || after.Consumed != 1 || after.Stage != "due" || h.launches > 1 {
				t.Fatalf("cut lost reservation %+v pending=%+v", after, p)
			}
		})
	}
}
func TestRecoveryFenceRejectsStaleSnapshotAndLateInitialLoad(t *testing.T) {
	h := newRecoveryHarness(t, update.System)
	_ = h.install(t, "4.0.1")
	old, _ := h.state.Load(context.Background())
	h.reconcile(t)
	stale := *old
	id := ProcessIdentity{PID: 9, CreatedAtUnixNano: 10}
	stale.Runner = &id
	if err := h.state.CompareAndSave(context.Background(), old, stale); err == nil {
		t.Fatal("stale runner replaced retired pending")
	}
	h.clock.now = h.record(t).DueAt
	_ = h.install(t, "4.0.1")
	p, _ := h.state.Load(context.Background())
	if p.TransactionID == old.TransactionID {
		t.Fatal("old initial-load command can adopt new attempt")
	}
}
func TestRecoveryMonotonicTargetAndStrictState(t *testing.T) {
	h := newRecoveryHarness(t, update.System)
	_ = h.install(t, "4.0.1")
	h.reconcile(t)
	r := h.record(t)
	r.Consumed = 3
	r.Stage, r.Reason = "exhausted", "readiness-exhausted"
	if err := h.journal.saveLocked(context.Background(), *r); err != nil {
		t.Fatal(err)
	}
	if err := h.install(t, "4.0.2"); err == nil {
		t.Fatal("obstructed higher target passed")
	}
	if h.record(t).Consumed != 1 {
		t.Fatal("higher authorized target did not replace budget")
	}
	h.reconcile(t)
	h.clock.now = h.record(t).DueAt
	if err := h.install(t, "4.0.1"); err == nil || h.launches != 2 {
		t.Fatal("old target reset watermark")
	}
	name, _ := recoveryName(update.System)
	data, _ := h.storage.Read([]string{name}, maxStateBytes)
	changed := strings.Replace(string(data), `"schema":`, `"untrusted":"command","schema":`, 1)
	if _, err := h.storage.WriteAtomic(context.Background(), []string{name}, strings.NewReader(changed), maxStateBytes, int64(len(changed)), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := h.journal.Load(context.Background(), update.System); err == nil {
		t.Fatal("unknown authority field accepted")
	}
}
func TestFinalRecoveryGrantSharesExactPendingCAS(t *testing.T) {
	for _, mutation := range []string{"none", "expired", "disabled", "uninstall", "replay", "reservation"} {
		t.Run(mutation, func(t *testing.T) {
			h := newRecoveryHarness(t, update.System)
			_ = h.install(t, "4.0.1")
			p, _ := h.state.Load(context.Background())
			p.Phase = PhaseChildRecorded
			p.Runner = &ProcessIdentity{PID: 10, CreatedAtUnixNano: 10}
			p.Installer = &ProcessIdentity{PID: 11, CreatedAtUnixNano: 11}
			p.InstallerThread = &ProcessIdentity{PID: 12, CreatedAtUnixNano: 12}
			if err := h.state.Save(context.Background(), *p); err != nil {
				t.Fatal(err)
			}
			h.state.FinalGrant = func(ctx context.Context, next PendingV1) error {
				return h.journal.validateGrantLocked(ctx, next, func(context.Context) (machineProductMarker, bool, error) { return h.marker, h.enabled, nil }, h.clock.Now())
			}
			switch mutation {
			case "expired":
				h.clock.now = h.record(t).LaunchDeadline
			case "disabled":
				h.enabled = false
			case "uninstall":
				_, _ = h.storage.WriteAtomic(context.Background(), []string{finalUninstallFenceName}, strings.NewReader("x"), 64, 1, "")
			case "replay":
				replay, _ := NewFileReplayStore(h.storage)
				_ = replay.Save(context.Background(), update.ReplayState{Namespace: "system", Sequence: p.Replay.Sequence + 1, Digest: strings.Repeat("a", 64)})
			case "reservation":
				r := h.record(t)
				r.Reservation.TransactionID = "different"
				_ = h.journal.saveLocked(context.Background(), *r)
			}
			next := *p
			next.Phase = PhaseResumeAuthorized
			err := h.state.CompareAndSave(context.Background(), p, next)
			if (err == nil) != (mutation == "none") {
				t.Fatalf("grant=%v for %s", err, mutation)
			}
			actual, _ := h.state.Load(context.Background())
			if mutation != "none" && actual.Phase != PhaseChildRecorded {
				t.Fatal("failed grant resumed")
			}
			if mutation == "none" {
				h.clock.now = h.clock.now.Add(time.Hour)
				running := next
				running.Phase = PhaseRunning
				if err := h.state.CompareAndSave(context.Background(), &next, running); err != nil {
					t.Fatalf("expiry revoked durable grant: %v", err)
				}
			}
		})
	}
}
func TestRecoveryConcurrentExactRetirement(t *testing.T) {
	h := newRecoveryHarness(t, update.System)
	_ = h.install(t, "4.0.1")
	p, _ := h.state.Load(context.Background())
	r := h.record(t)
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s, _ := NewFileRecoveryStore(h.storage)
			results <- s.retire(context.Background(), p, *r, h.clock.Now())
		}()
	}
	wg.Wait()
	close(results)
	success := 0
	for err := range results {
		if err == nil {
			success++
		}
	}
	if success != 1 {
		t.Fatalf("exact clear winners=%d", success)
	}
	if h.record(t).Consumed != 1 {
		t.Fatal("concurrent callback changed budget")
	}
}
func TestRecoveryPublicCompanionUsesPublicACLAndNoAuthority(t *testing.T) {
	h := newRecoveryHarness(t, update.System)
	_ = h.install(t, "4.0.1")
	public := mustStorage(t, testStorageRoot(t, "status"), publicReadStorage)
	if err := publishRecovery(context.Background(), public, *h.record(t)); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(public.root, "recovery-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"artifactSha256", "marker", "reservation", "http", "command"} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("public authority field %s", secret)
		}
	}
	if err := publishRecovery(context.Background(), h.storage, *h.record(t)); err == nil {
		t.Fatal("private storage used as public status")
	}
}

func (h *recoveryHarness) busyExit(t *testing.T) {
	t.Helper()
	p, err := h.state.Load(context.Background())
	if err != nil || p == nil {
		t.Fatalf("pending %v %v", p, err)
	}
	p.Exit = &ExitEvidence{Code: 1618, ObservedAt: h.clock.Now()}
	if err := h.state.Save(context.Background(), *p); err != nil {
		t.Fatal(err)
	}
}
func TestRecoveryGenuineBusyKeeps30And120SecondBackoff(t *testing.T) {
	h := newRecoveryHarness(t, update.System)
	h.fail = false
	h.c.deps.RetryGate = retryAllowFunc(func(context.Context, PendingV1) (bool, error) { return true, nil })
	if err := h.install(t, "4.0.1"); err != nil {
		t.Fatal(err)
	}
	for attempt := 1; attempt <= 3; attempt++ {
		h.busyExit(t)
		h.reconcile(t)
		p, _ := h.state.Load(context.Background())
		if attempt < 3 {
			delay := 30 * time.Second
			if attempt == 2 {
				delay = 120 * time.Second
			}
			if p.Result != ResultRetryScheduled || p.NextAttemptAt == nil || !p.NextAttemptAt.Equal(h.clock.Now().Add(delay)) {
				t.Fatalf("wrong1618 backoff: %+v", p)
			}
			oldID := p.TransactionID
			h.clock.now = *p.NextAttemptAt
			h.reconstruct(t)
			h.reconcile(t)
			r := h.record(t)
			if r.Consumed != uint(attempt+1) || r.Reservation.TransactionID == oldID {
				t.Fatalf("busy reused launch %+v", r)
			}
		} else {
			if p.Result != ResultBusyExhausted {
				t.Fatalf("genuine1618 classification %+v", p)
			}
			h.reconcile(t)
		}
	}
	if h.launches != 3 || h.record(t).Stage != "msi-terminal" {
		t.Fatal("busy exhaustion wrong")
	}
	r := h.record(t)
	r.UpdatedAt = h.clock.now.Add(-24 * time.Hour)
	if err := h.journal.saveLocked(context.Background(), *r); err != nil {
		t.Fatal(err)
	}
	h.c.deps.LastResult.(*memoryLastResultStore).result.FinishedAt = r.UpdatedAt
	if err := h.install(t, "4.0.1"); err != nil || h.record(t).Consumed != 1 {
		t.Fatalf("real MSI cooldown did not permit chain: %v", err)
	}
}

type retryAllowFunc func(context.Context, PendingV1) (bool, error)

func (f retryAllowFunc) AllowRetry(ctx context.Context, p PendingV1) (bool, error) { return f(ctx, p) }
func TestRecoveryMixedBusyAndReadinessShareThreeLaunches(t *testing.T) {
	h := newRecoveryHarness(t, update.System)
	h.fail = false
	h.c.deps.RetryGate = retryAllowFunc(func(context.Context, PendingV1) (bool, error) { return true, nil })
	if err := h.install(t, "4.0.1"); err != nil {
		t.Fatal(err)
	}
	h.busyExit(t)
	h.reconcile(t)
	p, _ := h.state.Load(context.Background())
	h.clock.now = *p.NextAttemptAt
	h.fail = true
	if _, err := h.c.Reconcile(context.Background()); err == nil {
		t.Fatal("missing readiness passed")
	}
	if h.record(t).Consumed != 2 {
		t.Fatal("busy launch uncounted")
	}
	h.reconcile(t)
	h.clock.now = h.record(t).DueAt
	_ = h.install(t, "4.0.1")
	h.reconcile(t)
	if h.record(t).Stage != "exhausted" || h.launches != 3 {
		t.Fatal("mixed caps multiplied")
	}
}
func TestRecoveryBusyReservationPendingWriteCrashDoesNotReplay(t *testing.T) {
	h := newRecoveryHarness(t, update.System)
	h.fail = false
	h.c.deps.RetryGate = retryAllowFunc(func(context.Context, PendingV1) (bool, error) { return true, nil })
	if err := h.install(t, "4.0.1"); err != nil {
		t.Fatal(err)
	}
	h.busyExit(t)
	h.reconcile(t)
	p, _ := h.state.Load(context.Background())
	h.clock.now = *p.NextAttemptAt
	platform := h.storage.platform
	h.storage.platform = &recoveryFaultPlatform{storagePlatform: platform, target: "pending-v2.json", remaining: 1}
	if _, err := h.c.Reconcile(context.Background()); err == nil {
		t.Fatal("write fault missed")
	}
	h.storage.platform = platform
	r := h.record(t)
	if r.Consumed != 2 || h.launches != 1 {
		t.Fatal("reservation ordering failed")
	}
	h.reconstruct(t)
	h.clock.now = r.LaunchDeadline
	h.reconcile(t)
	p, _ = h.state.Load(context.Background())
	if p != nil || h.launches != 1 || h.record(t).Consumed != 2 || h.record(t).Stage != "due" {
		t.Fatal("busy orphan replayed/lost")
	}
}

type recoveryClearFaultPlatform struct {
	storagePlatform
	root string
}

func (p *recoveryClearFaultPlatform) checkPath(root, path string, required bool) error {
	if filepath.Base(path) == "pending-v2.json" && required {
		data, _ := os.ReadFile(filepath.Join(p.root, "recovery-system-v1.json"))
		var r RecoveryV1
		if json.Unmarshal(data, &r) == nil && r.Stage == "due" {
			return errors.New("injected exact-clear fault")
		}
	}
	return p.storagePlatform.checkPath(root, path, required)
}
func TestRecoveryLegacyPreparedFailsClosedWithoutFalseRollback(t *testing.T) {
	h := newRecoveryHarness(t, update.System)
	p := pendingForReconcile(t, nil)
	p.Phase = PhasePrepared
	p.Runner, p.Installer = nil, nil
	if err := h.state.Save(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	h.clock.now = p.UpdatedAt.Add(recoveryGrantBound)
	h.reconcile(t)
	if h.record(t).Stage != "exhausted" || h.launches != 0 || h.c.deps.LastResult.(*memoryLastResultStore).result != nil {
		t.Fatal("legacy uncounted grant launched or became rollback")
	}
}

func TestRecoveryLegacyImportCannotGrantLateChildBothSKUs(t *testing.T) {
	for _, sku := range []update.SKU{update.System, update.Suite} {
		for _, markerMatches := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/marker-matches=%v", sku, markerMatches), func(t *testing.T) {
				h := newRecoveryHarness(t, sku)
				p := pendingForReconcile(t, nil)
				p.SKU = sku
				p.Old, p.Candidate = oldProduct(sku), candidateProduct(t, sku, "4.0.1")
				p.Replay.Namespace = string(sku)
				p.Phase, p.Runner, p.Installer = PhasePrepared, nil, nil
				if err := h.state.Save(context.Background(), p); err != nil {
					t.Fatal(err)
				}
				h.clock.now = p.UpdatedAt.Add(time.Second)
				h.reconcile(t)
				r := h.record(t)
				child := p
				child.Phase = PhaseChildRecorded
				child.Runner = &ProcessIdentity{PID: 10, CreatedAtUnixNano: 10}
				child.Installer = &ProcessIdentity{PID: 11, CreatedAtUnixNano: 11}
				child.InstallerThread = &ProcessIdentity{PID: 12, CreatedAtUnixNano: 12}
				if err := h.state.Save(context.Background(), child); err != nil {
					t.Fatal(err)
				}
				marker := h.marker
				if markerMatches {
					// Deliberately remove the incidental marker-mismatch defense.
					marker = r.Marker
				}
				h.state.FinalGrant = func(ctx context.Context, next PendingV1) error {
					return h.journal.validateGrantLocked(ctx, next, func(context.Context) (machineProductMarker, bool, error) {
						return marker, true, nil
					}, h.clock.Now())
				}
				next := child
				next.Phase = PhaseResumeAuthorized
				if err := h.state.CompareAndSave(context.Background(), &child, next); !errors.Is(err, ErrUnauthorizedCandidate) {
					t.Fatalf("legacy import authorized an ungranted child: %v", err)
				}
				actual, _ := h.state.Load(context.Background())
				if actual.Phase != PhaseChildRecorded {
					t.Fatal("rejected legacy grant changed pending")
				}
				if !r.ExpiresAt.IsZero() {
					t.Fatal("legacy import fabricated signed expiry")
				}
				withoutProvenance := *r
				withoutProvenance.LegacyUncounted = false
				if withoutProvenance.Validate() == nil {
					t.Fatal("ordinary authorization accepted absent signed expiry")
				}
				withInventedExpiry := *r
				withInventedExpiry.ExpiresAt = r.LaunchDeadline
				if withInventedExpiry.Validate() == nil {
					t.Fatal("legacy witness accepted invented signed expiry")
				}
				// A separately supplied already-durable grant is irrevocable.
				// Seed that crash-recovery boundary directly; do not authorize it
				// through the rejected legacy CAS above.
				if err := h.state.Save(context.Background(), next); err != nil {
					t.Fatal(err)
				}
				h.clock.now = r.LaunchDeadline.Add(time.Hour)
				running := next
				running.Phase = PhaseRunning
				if err := h.state.CompareAndSave(context.Background(), &next, running); err != nil {
					t.Fatalf("legacy classification revoked a durable grant: %v", err)
				}
			})
		}
	}
}
func TestRecoveryLateReadyAndInstallerEvidenceOverridesRetry(t *testing.T) {
	h := newRecoveryHarness(t, update.System)
	_ = h.install(t, "4.0.1")
	r := h.record(t)
	p, _ := h.state.Load(context.Background())
	p.Phase = PhaseRunning
	p.Runner = &ProcessIdentity{PID: 10, CreatedAtUnixNano: 10}
	p.Installer = &ProcessIdentity{PID: 11, CreatedAtUnixNano: 11}
	p.InstallerThread = &ProcessIdentity{PID: 12, CreatedAtUnixNano: 12}
	if err := h.state.Save(context.Background(), *p); err != nil {
		t.Fatal(err)
	}
	h.c.deps.Processes = &fakeProcessProbe{alive: true}
	h.clock.now = r.DueAt
	if outcome := h.reconcile(t); outcome != OutcomeStillRunning {
		t.Fatalf("late ready installer got %s", outcome)
	}
	if err := h.install(t, "4.0.1"); err == nil || h.launches != 1 {
		t.Fatal("late installation overlapped")
	}
}

func TestRecoveryReservationAllowsTimeSpentInPreparation(t *testing.T) {
	h := newRecoveryHarness(t, update.System)
	observe := h.c.deps.ObservePreparation
	h.c.deps.ObservePreparation = func(ctx context.Context) (PreparationObservation, error) {
		h.clock.now = h.clock.now.Add(time.Second)
		return observe(ctx)
	}
	_ = h.install(t, "4.0.1")
	r := h.record(t)
	if h.launches != 1 || !r.LaunchDeadline.Equal(r.Reservation.UpdatedAt.Add(recoveryGrantBound)) {
		t.Fatal("elapsed authorization time rejected reservation or extended grant")
	}
}
