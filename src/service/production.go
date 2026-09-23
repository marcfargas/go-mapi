package service

import (
	"context"
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
	return PeriodicSchedule{
		InitialDelay: residentInitialDelay,
		Interval:     residentInterval,
		Delay:        TimerDelay{},
		Check:        func(ctx context.Context) { _ = check(ctx) },
	}
}
