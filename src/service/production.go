package service

import (
	"context"
	"log"
	"time"
)

const (
	residentInitialDelay = 2 * time.Minute
	residentInterval     = 6 * time.Hour
)

// residentHealthSchedule composes the installed-instance and protected-state
// probes now owned by the system MSI. Authenticated discovery is intentionally
// added only when its embedded production policy is available; until then the
// resident process performs useful local health checks and cannot fetch.
func residentHealthSchedule(check func(context.Context) error) Schedule {
	periodic := PeriodicSchedule{
		InitialDelay: residentInitialDelay,
		Interval:     residentInterval,
		Delay:        TimerDelay{},
		Check: func(ctx context.Context) {
			if err := check(ctx); err != nil {
				log.Printf("go-mapi resident health check: %v", err)
			}
		},
	}
	return ScheduleFunc(func(ctx context.Context) {
		periodic.Check(ctx)
		periodic.Run(ctx)
	})
}

// A completed installer first writes a terminal pending record, then retires
// it with the ordered last-result update. Finish those two bounded steps in
// one resident observation so public health does not stay stale until the
// next periodic check.
func reconcileResidentTerminal(
	ctx context.Context,
	current PendingV1,
	load func(context.Context) (*PendingV1, error),
	reconcile func(context.Context, PendingV1) (Outcome, error),
) (Outcome, bool, error) {
	outcome, err := reconcile(ctx, current)
	if err != nil || (outcome != OutcomeCommitted && outcome != OutcomeRolledBack) {
		return outcome, false, err
	}
	next, err := load(ctx)
	if err != nil || next == nil {
		return outcome, next == nil && err == nil, err
	}
	if next.TransactionID != current.TransactionID ||
		(next.Phase != PhaseCommitted && next.Phase != PhaseRolledBack) {
		return outcome, false, nil
	}
	if _, err := reconcile(ctx, *next); err != nil {
		return outcome, false, err
	}
	remaining, err := load(ctx)
	return outcome, remaining == nil && err == nil, err
}

type productInventoryFunc func(context.Context) ([]InstalledProduct, error)

func (f productInventoryFunc) Products(ctx context.Context) ([]InstalledProduct, error) {
	return f(ctx)
}

type healthProbeFunc func(context.Context, ProductSnapshot) (bool, error)

func (f healthProbeFunc) Healthy(ctx context.Context, product ProductSnapshot) (bool, error) {
	return f(ctx, product)
}

type wallClock struct{}

func (wallClock) Now() time.Time { return time.Now().UTC() }

// Resident recovery records only bounded codes. The public snapshot is
// published by the health schedule after the reconciliation observation.
type discardEvents struct{}

func (discardEvents) Record(context.Context, Event) {}

func publicEventForOutcome(outcome Outcome) EventCode {
	switch outcome {
	case OutcomeCommitted:
		return EventCommitted
	case OutcomeRolledBack:
		return EventRolledBack
	case OutcomeRebootPending:
		return EventRebootPending
	case OutcomeRepairRequired:
		return EventRepairNeeded
	case OutcomeStillRunning:
		return EventStillRunning
	default:
		return EventPending
	}
}

// An active transaction is not a broken installation by default. A reboot
// outcome follows a completed installed-product health and signature probe,
// so report that verified candidate and the still-required reboot together.
func applyActiveOutcomeStatus(status *PublicStatusV1, pending PendingV1, outcome Outcome) {
	status.Code = publicEventForOutcome(outcome)
	switch outcome {
	case OutcomeRebootPending:
		status.PackageVersion = pending.Candidate.PackageVersion
		status.ServiceVersion = pending.Candidate.Contained["service"]
		status.InterceptorVersion = pending.Candidate.Contained["interceptor"]
		status.AppVersion = pending.Candidate.Contained["app"]
		status.Health = "healthy"
		status.Signature = "verified"
	case OutcomeRepairRequired:
		status.Health = "repair-required"
	default:
		status.Health = ""
	}
}
