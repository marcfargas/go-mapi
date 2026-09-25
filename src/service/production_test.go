package service

import (
	"context"
	"testing"
	"time"
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
