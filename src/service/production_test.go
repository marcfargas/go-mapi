package service

import (
	"context"
	"errors"
	"os"
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
