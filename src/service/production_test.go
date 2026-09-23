package service

import (
	"context"
	"testing"
	"time"
)

type productionDelay struct {
	waits   []time.Duration
	results []bool
}

func (delay *productionDelay) Wait(_ context.Context, duration time.Duration) bool {
	delay.waits = append(delay.waits, duration)
	result := delay.results[0]
	delay.results = delay.results[1:]
	return result
}

func TestProductionResidentSchedulePerformsInstalledHealthCheck(t *testing.T) {
	delay := &productionDelay{results: []bool{true, false}}
	checks := 0
	schedule := residentHealthSchedule(func(context.Context) error { checks++; return nil }).(PeriodicSchedule)
	schedule.Delay = delay
	schedule.Run(context.Background())
	if checks != 1 || len(delay.waits) != 2 || delay.waits[0] != residentInitialDelay || delay.waits[1] != residentInterval {
		t.Fatalf("checks=%d waits=%v", checks, delay.waits)
	}
}
