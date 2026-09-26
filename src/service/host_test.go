package service

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestResidentServiceIdentityIsFixed(t *testing.T) {
	if ServiceName != "go-mapi" || ServiceDisplayName != "go-mapi system service" {
		t.Fatalf("service identity = %q/%q", ServiceName, ServiceDisplayName)
	}
	if ServiceExecutable != `%ProgramFiles%\go-mapi\service\go-mapi-service.exe` {
		t.Fatalf("service executable = %q", ServiceExecutable)
	}
	if ServiceImagePath != `"%ProgramFiles%\go-mapi\service\go-mapi-service.exe" service` {
		t.Fatalf("service ImagePath = %q", ServiceImagePath)
	}
}

func TestParseExecutableModeAcceptsOnlyRegisteredService(t *testing.T) {
	invocation, err := ParseExecutableMode([]string{"service"})
	if err != nil || invocation.Mode != ModeService || invocation.TransactionID != "" {
		t.Fatalf("ParseExecutableMode(service) = %#v, %v", invocation, err)
	}
	runner, err := ParseExecutableMode([]string{"--update-runner", "transaction-42"})
	if err != nil || runner.Mode != ModeUpdateRunner || runner.TransactionID != "transaction-42" {
		t.Fatalf("ParseExecutableMode(update-runner) = %#v, %v", runner, err)
	}
	for _, args := range [][]string{nil, {}, {"--service"}, {"service", "extra"}, {"--update-runner"}, {"--update-runner", `..\\outside`}, {"--update-runner", "tx", "extra"}} {
		if _, err := ParseExecutableMode(args); err == nil {
			t.Errorf("ParseExecutableMode(%q) accepted an unregistered process mode", args)
		}
	}
}

func TestHostStopsPromptlyWhenScheduleCompletesAfterReadyHandoff(t *testing.T) {
	release := make(chan struct{})
	host := Host{Schedule: ScheduleFunc(func(context.Context) { <-release })}
	statuses := make(chan HostStatus, 3)
	done := make(chan error, 1)
	go func() { done <- host.Run(context.Background(), make(chan Control), statuses) }()
	assertStatus(t, statuses, HostStartPending)
	assertStatus(t, statuses, HostRunning)
	close(release)
	assertStatus(t, statuses, HostStopPending)
	if err := <-done; err != nil {
		t.Fatalf("Host.Run: %v", err)
	}
}

func TestHostReportsRunningThenCancelsScheduledWorkOnStop(t *testing.T) {
	started := make(chan struct{})
	stopped := make(chan struct{})
	host := Host{Schedule: ScheduleFunc(func(ctx context.Context) {
		close(started)
		<-ctx.Done()
		close(stopped)
	})}
	controls := make(chan Control, 1)
	statuses := make(chan HostStatus, 3)
	done := make(chan error, 1)
	go func() { done <- host.Run(context.Background(), controls, statuses) }()

	assertStatus(t, statuses, HostStartPending)
	status := assertStatus(t, statuses, HostRunning)
	if status.Accepts != AcceptStop|AcceptShutdown {
		t.Fatalf("running accepts = %v", status.Accepts)
	}
	await(t, started, "scheduled work start")
	controls <- ControlStop
	assertStatus(t, statuses, HostStopPending)
	await(t, stopped, "scheduled work cancellation")
	if err := <-done; err != nil {
		t.Fatalf("Host.Run: %v", err)
	}
}

func TestHostHandlesShutdownAndPropagatesUnexpectedChannelClosure(t *testing.T) {
	t.Run("shutdown", func(t *testing.T) {
		host := Host{Schedule: ScheduleFunc(func(ctx context.Context) { <-ctx.Done() })}
		controls := make(chan Control, 1)
		statuses := make(chan HostStatus, 3)
		done := make(chan error, 1)
		go func() { done <- host.Run(context.Background(), controls, statuses) }()
		assertStatus(t, statuses, HostStartPending)
		assertStatus(t, statuses, HostRunning)
		controls <- ControlShutdown
		assertStatus(t, statuses, HostStopPending)
		if err := <-done; err != nil {
			t.Fatalf("Host.Run: %v", err)
		}
	})

	t.Run("closed control channel", func(t *testing.T) {
		controls := make(chan Control)
		close(controls)
		err := (Host{Schedule: ScheduleFunc(func(context.Context) {})}).Run(context.Background(), controls, make(chan HostStatus, 3))
		if !errors.Is(err, ErrControlChannelClosed) {
			t.Fatalf("Host.Run error = %v", err)
		}
	})
}

func TestPeriodicScheduleWaitsBeforeFirstCheckAndBetweenChecks(t *testing.T) {
	delays := make(chan time.Duration, 2)
	releases := make(chan struct{}, 2)
	checks := make(chan struct{}, 2)
	ctx, cancel := context.WithCancel(context.Background())
	schedule := PeriodicSchedule{
		InitialDelay: 3 * time.Minute,
		Interval:     6 * time.Hour,
		Delay: DelayFunc(func(ctx context.Context, duration time.Duration) bool {
			delays <- duration
			select {
			case <-releases:
				return true
			case <-ctx.Done():
				return false
			}
		}),
		Check: func(context.Context) { checks <- struct{}{} },
	}
	done := make(chan struct{})
	go func() {
		schedule.Run(ctx)
		close(done)
	}()

	if got := <-delays; got != 3*time.Minute {
		t.Fatalf("initial delay = %v", got)
	}
	select {
	case <-checks:
		t.Fatal("check ran before initial delay")
	default:
	}
	releases <- struct{}{}
	await(t, checks, "first scheduled check")
	if got := <-delays; got != 6*time.Hour {
		t.Fatalf("recurring delay = %v", got)
	}
	cancel()
	await(t, done, "schedule cancellation")
}

func assertStatus(t *testing.T, statuses <-chan HostStatus, want HostState) HostStatus {
	t.Helper()
	select {
	case got := <-statuses:
		if got.State != want {
			t.Fatalf("status = %v, want %v", got.State, want)
		}
		return got
	case <-time.After(time.Second):
		t.Fatalf("timed out waiting for status %v", want)
		return HostStatus{}
	}
}

func await(t *testing.T, signal <-chan struct{}, label string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(time.Second):
		t.Fatalf("timed out waiting for %s", label)
	}
}
