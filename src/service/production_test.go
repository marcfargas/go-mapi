package service

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func TestProductionResidentSchedulePerformsInstalledHealthCheck(t *testing.T) {
	checks := 0
	ctx, cancel := context.WithCancel(context.Background())
	schedule := residentHealthSchedule(func(context.Context) error { checks++; cancel(); return nil })
	schedule.Run(ctx)
	if checks != 1 {
		t.Fatalf("startup health checks=%d, want one before delay", checks)
	}
}

func TestManagedAttemptRequiresFreshDiscoveryAndGivesInstallOwnDeadline(t *testing.T) {
	ctx := context.Background()
	installs := 0
	install := func(ctx context.Context) error {
		installs++
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) < 29*time.Minute {
			t.Fatal("installer inherited the one-minute metadata deadline")
		}
		return nil
	}
	for _, fresh := range []bool{false, true} {
		err := runResidentManagedAttempt(ctx, func(ctx context.Context) (bool, error) {
			deadline, ok := ctx.Deadline()
			if !ok || time.Until(deadline) > time.Minute {
				t.Fatal("metadata attempt lacks its one-minute deadline")
			}
			return fresh, nil
		}, install)
		if err != nil {
			t.Fatal(err)
		}
	}
	if installs != 1 {
		t.Fatalf("installs=%d, want one fresh install", installs)
	}
}

func TestActiveRebootStatusDoesNotFalselyRequireRepair(t *testing.T) {
	pending := PendingV1{Candidate: ProductSnapshot{
		PackageVersion: "5.0.1-alpha.2",
		Contained:      map[string]string{"service": "5.0.1-alpha.2", "interceptor": "5.0.1-alpha.1"},
	}}
	newStatus := func() residentStatus {
		return residentStatus{SKU: "system", Updates: "enabled", Health: "repair-required", Code: EventRepairNeeded, UpdatedAt: time.Now().UTC()}
	}
	reboot := newStatus()
	applyActiveOutcomeStatus(&reboot, pending, OutcomeRebootPending)
	if reboot.Code != EventRebootPending || reboot.Health != "healthy" ||
		reboot.PackageVersion != "5.0.1-alpha.2" || reboot.ServiceVersion != "5.0.1-alpha.2" ||
		reboot.InterceptorVersion != "5.0.1-alpha.1" {
		t.Fatalf("reboot status is not a healthy candidate needing reboot: %#v", reboot)
	}
	running := newStatus()
	applyActiveOutcomeStatus(&running, pending, OutcomeStillRunning)
	if running.Code != EventStillRunning || running.Health != "" {
		t.Fatalf("in-flight status falsely classifies health: %#v", running)
	}
	repair := newStatus()
	applyActiveOutcomeStatus(&repair, pending, OutcomeRepairRequired)
	if repair.Code != EventRepairNeeded || repair.Health != "repair-required" {
		t.Fatalf("repair status missing required action: %#v", repair)
	}
}

func TestPublicEventForReconciliationOutcome(t *testing.T) {
	for _, test := range []struct {
		outcome Outcome
		want    EventCode
	}{
		{OutcomeCommitted, EventCommitted},
		{OutcomeRolledBack, EventRolledBack},
		{OutcomeRebootPending, EventRebootPending},
		{OutcomeRepairRequired, EventRepairNeeded},
		{OutcomeStillRunning, EventStillRunning},
		{OutcomeOutcomeUnconfirmed, EventPending},
	} {
		if got := publicEventForOutcome(test.outcome); got != test.want {
			t.Errorf("publicEventForOutcome(%q) = %q, want %q", test.outcome, got, test.want)
		}
	}
}

func TestResidentTerminalReconciliationRetiresAndCanPublishHealth(t *testing.T) {
	ctx := context.Background()
	current := PendingV1{TransactionID: "signed-upgrade", Phase: PhaseRunning}
	pending := &current
	calls := 0
	load := func(context.Context) (*PendingV1, error) { return pending, nil }
	reconcile := func(_ context.Context, observed PendingV1) (Outcome, error) {
		calls++
		switch calls {
		case 1:
			if observed.Phase != PhaseRunning {
				t.Fatalf("first observed phase = %q", observed.Phase)
			}
			pending = &PendingV1{TransactionID: current.TransactionID, Phase: PhaseCommitted}
		case 2:
			if observed.Phase != PhaseCommitted {
				t.Fatalf("terminal observed phase = %q", observed.Phase)
			}
			pending = nil
		default:
			t.Fatal("terminal record reconciled more than once")
		}
		return OutcomeCommitted, nil
	}
	outcome, retired, err := reconcileResidentTerminal(ctx, current, load, reconcile)
	if err != nil || outcome != OutcomeCommitted || !retired || calls != 2 {
		t.Fatalf("terminal result = %q, retired=%t, calls=%d, err=%v", outcome, retired, calls, err)
	}
}

func TestResidentNonterminalReconciliationDoesNotAdvance(t *testing.T) {
	current := PendingV1{TransactionID: "in-flight", Phase: PhaseRunning}
	loads := 0
	outcome, retired, err := reconcileResidentTerminal(context.Background(), current,
		func(context.Context) (*PendingV1, error) { loads++; return &current, nil },
		func(context.Context, PendingV1) (Outcome, error) { return OutcomeStillRunning, nil })
	if err != nil || outcome != OutcomeStillRunning || retired || loads != 0 {
		t.Fatalf("in-flight result = %q, retired=%t, loads=%d, err=%v", outcome, retired, loads, err)
	}
}

func TestResidentRepairRetirementRequiresPendingAbsenceWithoutSecondPass(t *testing.T) {
	current := PendingV1{TransactionID: "suite-repair", Phase: PhaseRepairRequired, Result: ResultAmbiguous}
	for _, remaining := range []bool{false, true} {
		calls := 0
		outcome, retired, err := reconcileResidentTerminal(context.Background(), current,
			func(context.Context) (*PendingV1, error) {
				if remaining {
					return &current, nil
				}
				return nil, nil
			},
			func(context.Context, PendingV1) (Outcome, error) { calls++; return OutcomeRepairRetired, nil })
		if err != nil || outcome != OutcomeRepairRetired || retired == remaining || calls != 1 {
			t.Fatalf("remaining=%v outcome=%s retired=%v calls=%d err=%v", remaining, outcome, retired, calls, err)
		}
	}
}

func TestResidentPreparedReconcileClosesEarlierOpenOnCurrentState(t *testing.T) {
	for _, tc := range []struct {
		name    string
		product string
		busy    bool
		want    Outcome
		open    bool
	}{
		{"candidate without exit", "candidate", false, OutcomeOutcomeUnconfirmed, false},
		{"foreign product", "foreign", false, OutcomeRepairRequired, false},
		{"old product retired", "old", false, OutcomeRolledBack, false},
		{"unchanged prepared while server busy", "candidate", true, OutcomeStillRunning, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pending := suiteRepairPending(t, nil)
			pending.Phase, pending.Result = PhasePrepared, ResultNone
			pending.Runner, pending.Installer = nil, nil
			if err := pending.Validate(); err != nil {
				t.Fatal(err)
			}
			store := &memoryPendingStore{pending: &pending}
			deps := defaultDependencies(t)
			deps.Pending, deps.Boot = store, fixedBootID("boot-one")
			product := pending.Candidate
			switch tc.product {
			case "old":
				product = pending.Old
			case "foreign":
				product.SKU = update.System
			}
			deps.Inventory = &fakeInventory{products: []InstalledProduct{{Snapshot: product}}}
			deps.Health = fakeHealthProbe{healthy: true}
			deps.Processes = &fakeProcessProbe{}
			server := &fakeInstallerServerProbe{}
			if tc.busy {
				server.busyOnCall = 1
			}
			deps.InstallerServer = server
			coordinator := mustCoordinator(t, update.Suite, deps)
			gate, err := os.CreateTemp(t.TempDir(), "admission-")
			if err != nil {
				t.Fatal(err)
			}
			defer gate.Close()
			if _, err := writeSuiteByte(gate, 'O'); err != nil {
				t.Fatal(err)
			}
			closes := 0
			closeGate := func(context.Context) error {
				closes++
				_, err := writeSuiteByte(gate, 'C')
				return err
			}
			outcome, retired, prepared, err := reconcileResidentSuitePending(context.Background(), pending,
				store.Load, store.Load,
				func(ctx context.Context, _ PendingV1) (Outcome, error) { return coordinator.Reconcile(ctx) }, closeGate)
			var admission [1]byte
			if _, readErr := gate.ReadAt(admission[:], 0); readErr != nil {
				t.Fatal(readErr)
			}
			wantByte := byte('C')
			if tc.open {
				wantByte = 'O'
			}
			if err != nil || outcome != tc.want || admission[0] != wantByte || prepared != tc.open {
				t.Fatalf("outcome=%s retired=%v prepared=%v admission=%c closes=%d pending=%+v err=%v", outcome, retired, prepared, admission[0], closes, store.pending, err)
			}
			if tc.open && closes != 0 || !tc.open && closes != 1 {
				t.Fatalf("gate closures=%d", closes)
			}
			if tc.product == "old" && (!retired || store.pending != nil) {
				t.Fatalf("old product was not retired: retired=%v pending=%+v", retired, store.pending)
			}
		})
	}
}

func TestResidentPreparedReconcileUnreadableCurrentStateClosesEarlierOpen(t *testing.T) {
	pending := suiteRepairPending(t, nil)
	pending.Phase, pending.Result = PhasePrepared, ResultNone
	pending.Runner, pending.Installer = nil, nil
	closed := false
	_, _, prepared, err := reconcileResidentSuitePending(context.Background(), pending,
		func(context.Context) (*PendingV1, error) { return &pending, nil },
		func(context.Context) (*PendingV1, error) { return nil, errors.New("unreadable pending") },
		func(context.Context, PendingV1) (Outcome, error) { return OutcomeStillRunning, nil },
		func(context.Context) error { closed = true; return nil })
	if err == nil || prepared || !closed {
		t.Fatalf("unreadable state: prepared=%v closed=%v err=%v", prepared, closed, err)
	}
}

// awaitingAdmission is what healthCheck returns when it proved the installed
// suite healthy but Windows Installer still owned the machine.
var awaitingAdmission = fmt.Errorf("%w: %w", errSuiteAdmissionAwaitsInstaller, ErrSuiteInstallerBusy)

func shortenAdmissionRetry(t *testing.T, interval, bound, heartbeat time.Duration) {
	t.Helper()
	oldInterval, oldBound, oldHeartbeat := admissionRetryInterval, admissionRetryBound, residentHeartbeatInterval
	admissionRetryInterval, admissionRetryBound, residentHeartbeatInterval = interval, bound, heartbeat
	t.Cleanup(func() {
		admissionRetryInterval, admissionRetryBound, residentHeartbeatInterval = oldInterval, oldBound, oldHeartbeat
	})
}

// runSchedule runs the resident schedule until stop is called and reports
// whether the schedule goroutine ended.
func runSchedule(t *testing.T, health func(context.Context) error, heartbeat func(context.Context) error, idle func(context.Context) (bool, error)) (stop func() bool) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		residentManagedSchedule(health, nil, nil, heartbeat, idle).Run(ctx)
	}()
	stopped := false
	stop = func() bool {
		if !stopped {
			stopped = true
			cancel()
		}
		select {
		case <-done:
			return true
		case <-time.After(2 * time.Second):
			return false
		}
	}
	t.Cleanup(func() { stop() })
	return stop
}

func eventually(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestResidentScheduleReopensAdmissionWhenInstallerIdle(t *testing.T) {
	shortenAdmissionRetry(t, 10*time.Millisecond, time.Second, time.Hour)
	var healthCalls, probeCalls, probeCallsAtSecondHealth atomic.Int32
	var inHealth atomic.Bool
	health := func(context.Context) error {
		inHealth.Store(true)
		defer inHealth.Store(false)
		if healthCalls.Add(1) == 1 {
			return awaitingAdmission
		}
		probeCallsAtSecondHealth.Store(probeCalls.Load())
		return nil
	}
	idle := func(context.Context) (bool, error) {
		if inHealth.Load() {
			t.Error("installer probe ran while the health check ran")
		}
		// busy, busy, then idle
		return probeCalls.Add(1) >= 3, nil
	}
	stop := runSchedule(t, health, func(context.Context) error { return nil }, idle)
	eventually(t, "the health check after the installer became idle", func() bool { return healthCalls.Load() == 2 })
	time.Sleep(100 * time.Millisecond)
	if !stop() {
		t.Fatal("schedule did not end")
	}
	if healthCalls.Load() != 2 || probeCalls.Load() != 3 || probeCallsAtSecondHealth.Load() != 3 {
		t.Fatalf("health=%d probes=%d probes before retry=%d, want health only after the third (idle) probe and no attempt after success",
			healthCalls.Load(), probeCalls.Load(), probeCallsAtSecondHealth.Load())
	}
}

func TestResidentScheduleAdmissionRetryCases(t *testing.T) {
	t.Run("other error with an idle installer arms no retry", func(t *testing.T) {
		shortenAdmissionRetry(t, 10*time.Millisecond, time.Second, time.Hour)
		var healthCalls, probeCalls atomic.Int32
		stop := runSchedule(t,
			func(context.Context) error { healthCalls.Add(1); return errors.New("service configuration differs") },
			func(context.Context) error { return nil },
			func(context.Context) (bool, error) { probeCalls.Add(1); return true, nil })
		time.Sleep(100 * time.Millisecond)
		stop()
		if healthCalls.Load() != 1 || probeCalls.Load() != 1 {
			t.Fatalf("health=%d probes=%d, want one health check and one classification probe", healthCalls.Load(), probeCalls.Load())
		}
	})
	t.Run("unhealthy result while the installer is busy arms the retry", func(t *testing.T) {
		shortenAdmissionRetry(t, 10*time.Millisecond, time.Second, time.Hour)
		var healthCalls, probeCalls atomic.Int32
		stop := runSchedule(t,
			func(context.Context) error {
				if healthCalls.Add(1) == 1 {
					return errors.New("product registration not visible yet")
				}
				return nil
			},
			func(context.Context) error { return nil },
			func(context.Context) (bool, error) { return probeCalls.Add(1) > 1, nil })
		eventually(t, "the retried health check", func() bool { return healthCalls.Load() == 2 })
		time.Sleep(50 * time.Millisecond)
		stop()
		if healthCalls.Load() != 2 || probeCalls.Load() != 2 {
			t.Fatalf("health=%d probes=%d, want one busy classification probe, one idle retry probe and one retried health", healthCalls.Load(), probeCalls.Load())
		}
	})
	t.Run("the bound stops fast retries", func(t *testing.T) {
		shortenAdmissionRetry(t, 5*time.Millisecond, 60*time.Millisecond, time.Hour)
		var healthCalls, probeCalls atomic.Int32
		stop := runSchedule(t,
			func(context.Context) error { healthCalls.Add(1); return awaitingAdmission },
			func(context.Context) error { return nil },
			func(context.Context) (bool, error) { probeCalls.Add(1); return false, nil })
		time.Sleep(200 * time.Millisecond)
		settled := probeCalls.Load()
		time.Sleep(150 * time.Millisecond)
		stop()
		if settled == 0 || probeCalls.Load() != settled || healthCalls.Load() != 1 {
			t.Fatalf("probes settled=%d final=%d health=%d, want fast probes to stop at the bound", settled, probeCalls.Load(), healthCalls.Load())
		}
	})
	t.Run("cancellation ends the loop", func(t *testing.T) {
		shortenAdmissionRetry(t, 5*time.Millisecond, time.Hour, time.Hour)
		var probeCalls atomic.Int32
		stop := runSchedule(t,
			func(context.Context) error { return awaitingAdmission },
			func(context.Context) error { return nil },
			func(context.Context) (bool, error) { probeCalls.Add(1); return false, nil })
		eventually(t, "fast probes", func() bool { return probeCalls.Load() > 2 })
		if !stop() {
			t.Fatal("schedule did not end on cancellation while the retry was armed")
		}
		ended := probeCalls.Load()
		time.Sleep(50 * time.Millisecond)
		if probeCalls.Load() != ended {
			t.Fatal("installer probes continued after cancellation")
		}
	})
	t.Run("an awaiting heartbeat result arms the retry", func(t *testing.T) {
		shortenAdmissionRetry(t, 5*time.Millisecond, time.Second, 20*time.Millisecond)
		var healthCalls, heartbeats atomic.Int32
		stop := runSchedule(t,
			func(context.Context) error { healthCalls.Add(1); return nil },
			func(context.Context) error {
				if heartbeats.Add(1) == 1 {
					return awaitingAdmission
				}
				return nil
			},
			func(context.Context) (bool, error) { return true, nil })
		eventually(t, "the retry armed by the heartbeat", func() bool { return healthCalls.Load() == 2 })
		stop()
	})
	t.Run("awaiting heartbeats neither re-arm nor extend an episode", func(t *testing.T) {
		shortenAdmissionRetry(t, 5*time.Millisecond, 80*time.Millisecond, 15*time.Millisecond)
		var probeCalls, heartbeats atomic.Int32
		stop := runSchedule(t,
			func(context.Context) error { return awaitingAdmission },
			func(context.Context) error { heartbeats.Add(1); return awaitingAdmission },
			func(context.Context) (bool, error) { probeCalls.Add(1); return false, nil })
		time.Sleep(250 * time.Millisecond)
		settled, settledHeartbeats := probeCalls.Load(), heartbeats.Load()
		time.Sleep(150 * time.Millisecond)
		stop()
		if heartbeats.Load() <= settledHeartbeats || settled == 0 || probeCalls.Load() != settled || settled > 20 {
			t.Fatalf("heartbeats settled=%d final=%d, probes settled=%d final=%d, want the bound to hold across awaiting heartbeats",
				settledHeartbeats, heartbeats.Load(), settled, probeCalls.Load())
		}
	})
	t.Run("a healthy result ends the episode so a later one gets its own bound", func(t *testing.T) {
		shortenAdmissionRetry(t, 5*time.Millisecond, 50*time.Millisecond, 30*time.Millisecond)
		var heartbeats, probeCalls, probesBeforeSecond, probesAtEnd atomic.Int32
		stop := runSchedule(t,
			func(context.Context) error { return nil },
			func(context.Context) error {
				// awaiting, healthy, awaiting, then healthy; the second
				// episode starts after the first episode's bound expired.
				switch heartbeats.Add(1) {
				case 1:
					return awaitingAdmission
				case 3:
					probesBeforeSecond.Store(probeCalls.Load())
					return awaitingAdmission
				case 4:
					probesAtEnd.Store(probeCalls.Load())
				}
				return nil
			},
			func(context.Context) (bool, error) { probeCalls.Add(1); return false, nil })
		eventually(t, "two episodes", func() bool { return heartbeats.Load() >= 4 })
		stop()
		if probesBeforeSecond.Load() == 0 || probesAtEnd.Load() <= probesBeforeSecond.Load() {
			t.Fatalf("probes before second episode=%d at its end=%d, want fast probes in both episodes", probesBeforeSecond.Load(), probesAtEnd.Load())
		}
	})
}

func TestSuiteHealthAfterOpen(t *testing.T) {
	busy := fmt.Errorf("installer server is not idle: %w", ErrSuiteInstallerBusy)
	for _, test := range []struct {
		name              string
		err               error
		blocked           bool
		healthy, awaiting bool
	}{
		{"opened", nil, false, true, false},
		{"busy installer", busy, false, true, true},
		{"installer became busy during the proof", fmt.Errorf("installer server changed during health proof: %w", ErrSuiteInstallerBusy), false, true, true},
		{"busy installer during a final uninstall or pending update", busy, true, false, false},
		{"state conflict", ErrStateConflict, false, false, false},
		{"fenced", ErrFinalUninstallFenced, false, false, false},
		{"other failure", errors.New("marker mismatch"), false, false, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			healthy, awaiting := suiteHealthAfterOpen(test.err, test.blocked)
			if healthy != test.healthy || awaiting != test.awaiting {
				t.Fatalf("healthy=%v awaiting=%v, want %v %v", healthy, awaiting, test.healthy, test.awaiting)
			}
		})
	}
	if !errors.Is(awaitingAdmission, ErrSuiteInstallerBusy) {
		t.Fatal("the awaiting result must wrap the busy-installer sentinel")
	}
}

func TestSuiteOpenBlockedByFenceOrPendingRecord(t *testing.T) {
	ctx := context.Background()
	storage := mustStorage(t, testStorageRoot(t, "protected"), privateStorage)
	state, err := NewFileStateStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	if blocked, err := state.SuiteOpenBlocked(); err != nil || blocked {
		t.Fatalf("empty state blocked=%v err=%v", blocked, err)
	}
	if err := state.BeginFinalUninstall(ctx); err != nil {
		t.Fatal(err)
	}
	if blocked, err := state.SuiteOpenBlocked(); err != nil || !blocked {
		t.Fatalf("final-uninstall fence blocked=%v err=%v", blocked, err)
	}
	if err := state.RollbackFinalUninstall(); err != nil {
		t.Fatal(err)
	}
	if err := state.CompareAndSave(ctx, nil, pendingForReconcile(t, nil)); err != nil {
		t.Fatal(err)
	}
	if blocked, err := state.SuiteOpenBlocked(); err != nil || !blocked {
		t.Fatalf("pending record blocked=%v err=%v", blocked, err)
	}
}
