package service

import (
	"context"
	"errors"
	"log"
	"sync/atomic"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
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

// residentManagedSchedule retains the accepted immediate recovery/health
// observation. Metadata starts after two minutes; a one-minute heartbeat
// publishes liveness independently of the bounded network attempt.
func residentManagedSchedule(health func(context.Context) error, discovery func(context.Context) (bool, error), install func(context.Context) error, heartbeat func(context.Context) error) Schedule {
	return ScheduleFunc(func(ctx context.Context) {
		if err := health(ctx); err != nil {
			log.Printf("go-mapi resident health check: %v", err)
		}
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		start := time.Now()
		lastHealth := start
		var inflight atomic.Bool
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-ticker.C:
				if err := heartbeat(ctx); err != nil {
					log.Printf("go-mapi resident status heartbeat: %v", err)
				}
				if now.Sub(lastHealth) >= residentInterval {
					if err := health(ctx); err != nil {
						log.Printf("go-mapi resident health check: %v", err)
					}
					lastHealth = now
				}
				if discovery != nil && now.Sub(start) >= residentInitialDelay && inflight.CompareAndSwap(false, true) {
					go func() {
						defer inflight.Store(false)
						if err := runResidentManagedAttempt(ctx, discovery, install); err != nil {
							log.Printf("go-mapi resident discovery: %v", err)
						}
					}()
				}
			}
		}
	})
}

func runResidentManagedAttempt(ctx context.Context, discovery func(context.Context) (bool, error), install func(context.Context) error) error {
	metadataCtx, cancel := context.WithTimeout(ctx, time.Minute)
	fresh, err := discovery(metadataCtx)
	cancel()
	if err != nil || !fresh || install == nil {
		return err
	}
	installCtx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()
	return install(installCtx)
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
	if err != nil || (outcome != OutcomeCommitted && outcome != OutcomeRolledBack && outcome != OutcomeRepairRetired) {
		return outcome, false, err
	}
	next, err := load(ctx)
	if outcome == OutcomeRepairRetired {
		return outcome, next == nil && err == nil, err
	}
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

// Reconciliation may change or retire the record observed by the health
// check. Only the current merely-prepared record can exempt an existing O
// from the unhealthy-health closure.
func reconcileResidentSuitePending(
	ctx context.Context,
	pending PendingV1,
	load func(context.Context) (*PendingV1, error),
	loadBounded func(context.Context) (*PendingV1, error),
	reconcile func(context.Context, PendingV1) (Outcome, error),
	closeAdmission func(context.Context) error,
) (Outcome, bool, bool, error) {
	prepared := merelyPreparedSuitePending(&pending)
	if pending.SKU == update.Suite && !prepared {
		if err := closeAdmission(ctx); err != nil {
			return "", false, false, err
		}
	}
	outcome, retired, reconcileErr := reconcileResidentTerminal(ctx, pending, load, reconcile)
	current, loadErr := loadBounded(context.WithoutCancel(ctx))
	preparedNow := loadErr == nil && merelyPreparedSuitePending(current)
	var closeErr error
	if prepared && !preparedNow {
		closeErr = closeAdmission(context.WithoutCancel(ctx))
	}
	return outcome, retired, preparedNow, errors.Join(reconcileErr, loadErr, closeErr)
}

func merelyPreparedSuitePending(pending *PendingV1) bool {
	return pending != nil && pending.SKU == update.Suite && pending.Phase == PhasePrepared && pending.AppDrainDeadline == nil
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
// outcome follows a completed installed-product health probe, so report that
// candidate and the still-required reboot together.
func applyActiveOutcomeStatus(status *residentStatus, pending PendingV1, outcome Outcome) {
	status.Code = publicEventForOutcome(outcome)
	switch outcome {
	case OutcomeRebootPending:
		status.PackageVersion = pending.Candidate.PackageVersion
		status.ServiceVersion = pending.Candidate.Contained["service"]
		status.InterceptorVersion = pending.Candidate.Contained["interceptor"]
		status.AppVersion = pending.Candidate.Contained["app"]
		status.Health = "healthy"
	case OutcomeRepairRequired:
		status.Health = "repair-required"
	default:
		status.Health = ""
	}
}
