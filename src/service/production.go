package service

import (
	"context"
	"errors"
	"log"
	"sync/atomic"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

const residentInterval = 6 * time.Hour

// Variables so tests can shorten them; a controlled validation build shortens
// the start-up delay and heartbeat once at start-up (applyResidentTimers). The
// heartbeat is the backstop for a closed suite admission gate; the admission
// retry reopens it within about a second after a machine transaction releases
// Windows Installer.
var (
	residentInitialDelay      = productionResidentInitialDelay
	residentHeartbeatInterval = productionResidentHeartbeat
	admissionRetryInterval    = time.Second
	admissionRetryBound       = 15 * time.Minute
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
// publishes liveness independently of the bounded network attempt. A health
// result that failed while Windows Installer was busy arms a bounded retry
// that re-runs the full health check once the installer is idle.
func residentManagedSchedule(health func(context.Context) error, discovery func(context.Context) (bool, error), install func(context.Context) error, heartbeat func(context.Context) error, installerIdle func(context.Context) (bool, error)) Schedule {
	return ScheduleFunc(func(ctx context.Context) {
		reopen := admissionReopen{idle: installerIdle}
		defer reopen.end()
		err := health(ctx)
		if err != nil {
			log.Printf("go-mapi resident health check: %v", err)
		}
		reopen.observe(ctx, err)
		ticker := time.NewTicker(residentHeartbeatInterval)
		defer ticker.Stop()
		start := time.Now()
		lastHealth := start
		var inflight atomic.Bool
		for {
			select {
			case <-ctx.Done():
				return
			case <-reopen.fire:
				reopen.tick(ctx, health)
			case now := <-ticker.C:
				err := heartbeat(ctx)
				if err != nil {
					log.Printf("go-mapi resident status heartbeat: %v", err)
				}
				reopen.observe(ctx, err)
				if now.Sub(lastHealth) >= residentInterval {
					err := health(ctx)
					if err != nil {
						log.Printf("go-mapi resident health check: %v", err)
					}
					reopen.observe(ctx, err)
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

// ErrSuiteInstallerBusy reports that Windows Installer owned the machine when
// the service would have reopened suite admission. Every machine transaction
// closes the gate, and a replacement service starts inside that transaction.
var ErrSuiteInstallerBusy = errors.New("windows installer is busy")

// errSuiteAdmissionAwaitsInstaller is the health result after the installed
// suite was proved healthy while Windows Installer kept admission closed.
var errSuiteAdmissionAwaitsInstaller = errors.New("suite admission awaits the installer")

// suiteHealthAfterOpen classifies the result of openHealthySuite once every
// other installed-health check passed. Only a busy installer outside a final
// uninstall or a pending machine update keeps the proven health; the gate then
// stays closed until the resident retry reopens it.
func suiteHealthAfterOpen(openErr error, openBlocked bool) (healthy, awaiting bool) {
	if openErr == nil {
		return true, false
	}
	if errors.Is(openErr, ErrSuiteInstallerBusy) && !openBlocked {
		return true, true
	}
	return false, false
}

// admissionReopen retries a health check soon after Windows Installer becomes
// idle, instead of on the next one-minute heartbeat. One episode starts at
// the first result that failed while the installer was busy and ends at the
// next other result. It probes at most once per interval and stops at the
// bound; after that only the heartbeat retries. It runs on the schedule
// goroutine only.
type admissionReopen struct {
	idle     func(context.Context) (bool, error)
	timer    *time.Timer
	fire     <-chan time.Time
	active   bool
	deadline time.Time
}

// observe classifies a health or heartbeat result outside the retry. A result
// in a running episode never re-arms or extends it.
func (r *admissionReopen) observe(ctx context.Context, err error) {
	if !r.retryable(ctx, err) {
		r.end()
		return
	}
	if r.active {
		return
	}
	r.active = true
	r.deadline = time.Now().Add(admissionRetryBound)
	r.arm()
}

func (r *admissionReopen) retryable(ctx context.Context, err error) bool {
	if err == nil || r.idle == nil || ctx.Err() != nil {
		return false
	}
	if errors.Is(err, ErrSuiteInstallerBusy) {
		return true
	}
	idle, probeErr := r.idle(ctx)
	return probeErr == nil && !idle
}

func (r *admissionReopen) tick(ctx context.Context, health func(context.Context) error) {
	r.fire = nil
	if !time.Now().Before(r.deadline) {
		return
	}
	idle, err := r.idle(ctx)
	if err != nil || !idle {
		r.arm()
		return
	}
	err = health(ctx)
	if err != nil {
		log.Printf("go-mapi resident admission retry: %v", err)
	}
	if errors.Is(err, ErrSuiteInstallerBusy) {
		r.arm()
		return
	}
	r.end()
}

func (r *admissionReopen) arm() {
	if !time.Now().Before(r.deadline) {
		return
	}
	if r.timer == nil {
		r.timer = time.NewTimer(admissionRetryInterval)
	} else {
		r.timer.Reset(admissionRetryInterval)
	}
	r.fire = r.timer.C
}

func (r *admissionReopen) end() {
	if r.timer != nil {
		r.timer.Stop()
	}
	r.fire = nil
	r.active = false
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
