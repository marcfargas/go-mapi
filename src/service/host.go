package service

import (
	"context"
	"errors"
	"fmt"
	"time"
)

const (
	// ServiceName is the one and only registered resident go-mapi daemon.
	ServiceName        = "go-mapi"
	ServiceDisplayName = "go-mapi system service"
	ServiceExecutable  = `%ProgramFiles%\go-mapi\service\go-mapi-service.exe`
	ServiceArgument    = "service"
	ServiceImagePath   = `"%ProgramFiles%\go-mapi\service\go-mapi-service.exe" service`
)

type ExecutableMode string

const (
	ModeService                ExecutableMode = "service"
	ModeUpdateRunner           ExecutableMode = "update-runner"
	ModeBeginFinalUninstall    ExecutableMode = "begin-final-uninstall"
	ModeRollbackFinalUninstall ExecutableMode = "rollback-final-uninstall"
)

type ExecutableInvocation struct {
	Mode          ExecutableMode
	TransactionID string
}

// ParseExecutableMode keeps the resident topology closed. The later one-shot
// updater runner is a short-lived process and will be added as a distinct,
// unregistered mode; it must never become another service.
func ParseExecutableMode(args []string) (ExecutableInvocation, error) {
	if len(args) == 1 && args[0] == ServiceArgument {
		return ExecutableInvocation{Mode: ModeService}, nil
	}
	if len(args) == 2 && args[0] == "--update-runner" && transactionIDPattern.MatchString(args[1]) {
		return ExecutableInvocation{Mode: ModeUpdateRunner, TransactionID: args[1]}, nil
	}
	if len(args) == 1 && args[0] == "--begin-final-uninstall" {
		return ExecutableInvocation{Mode: ModeBeginFinalUninstall}, nil
	}
	if len(args) == 1 && args[0] == "--rollback-final-uninstall" {
		return ExecutableInvocation{Mode: ModeRollbackFinalUninstall}, nil
	}
	return ExecutableInvocation{}, fmt.Errorf("expected exactly %q or a bounded update-runner transaction", ServiceArgument)
}

type Control uint8

const (
	ControlStop Control = iota + 1
	ControlShutdown
)

type HostState uint8

const (
	HostStartPending HostState = iota + 1
	HostRunning
	HostStopPending
)

type AcceptedControls uint8

const (
	AcceptStop AcceptedControls = 1 << iota
	AcceptShutdown
)

type HostStatus struct {
	State   HostState
	Accepts AcceptedControls
}

type Schedule interface {
	Run(context.Context)
}

type ScheduleFunc func(context.Context)

func (schedule ScheduleFunc) Run(ctx context.Context) { schedule(ctx) }

type Delay interface {
	Wait(context.Context, time.Duration) bool
}

type DelayFunc func(context.Context, time.Duration) bool

func (delay DelayFunc) Wait(ctx context.Context, duration time.Duration) bool {
	return delay(ctx, duration)
}

type TimerDelay struct{}

func (TimerDelay) Wait(ctx context.Context, duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-ctx.Done():
		return false
	}
}

// PeriodicSchedule delays the first network/update attempt so SCM startup and
// MSI reconciliation can settle, then invokes the same bounded check at a
// fixed cadence. Delay is injected so the behavior remains deterministic in
// platform-neutral tests.
type PeriodicSchedule struct {
	InitialDelay time.Duration
	Interval     time.Duration
	Delay        Delay
	Check        func(context.Context)
}

func (schedule PeriodicSchedule) Run(ctx context.Context) {
	if schedule.InitialDelay <= 0 || schedule.Interval <= 0 || schedule.Delay == nil || schedule.Check == nil {
		return
	}
	if !schedule.Delay.Wait(ctx, schedule.InitialDelay) {
		return
	}
	for {
		schedule.Check(ctx)
		if ctx.Err() != nil || !schedule.Delay.Wait(ctx, schedule.Interval) {
			return
		}
	}
}

var ErrControlChannelClosed = errors.New("service control channel closed")

// Host owns the platform-neutral lifetime of scheduled service work. The
// Windows adapter below reports these states to SCM and translates only Stop
// and Shutdown controls. Schedule owns the actual initial/update delay.
type Host struct {
	Schedule Schedule
}

func (host Host) Run(parent context.Context, controls <-chan Control, statuses chan<- HostStatus) error {
	if host.Schedule == nil {
		return errors.New("service schedule is required")
	}
	ctx, cancel := context.WithCancel(parent)
	defer cancel()

	statuses <- HostStatus{State: HostStartPending}
	statuses <- HostStatus{State: HostRunning, Accepts: AcceptStop | AcceptShutdown}
	workDone := make(chan struct{})
	go func() {
		defer close(workDone)
		host.Schedule.Run(ctx)
	}()

	for {
		select {
		case <-workDone:
			statuses <- HostStatus{State: HostStopPending}
			return nil
		case <-parent.Done():
			statuses <- HostStatus{State: HostStopPending}
			cancel()
			<-workDone
			return parent.Err()
		case control, ok := <-controls:
			if !ok {
				cancel()
				<-workDone
				return ErrControlChannelClosed
			}
			if control != ControlStop && control != ControlShutdown {
				continue
			}
			statuses <- HostStatus{State: HostStopPending}
			cancel()
			<-workDone
			return nil
		}
	}
}
