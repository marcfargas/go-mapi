package service

import (
	"testing"
	"time"
)

func setValidationTimers(t *testing.T, startup, heartbeat, failure, interval string) {
	t.Helper()
	oldStartup, oldHeartbeat, oldFailure, oldInterval := MachineValidationStartupDelaySeconds, MachineValidationHeartbeatSeconds, MachineValidationFailureBaseSeconds, MachineCheckIntervalSeconds
	t.Cleanup(func() {
		MachineValidationStartupDelaySeconds, MachineValidationHeartbeatSeconds, MachineValidationFailureBaseSeconds, MachineCheckIntervalSeconds = oldStartup, oldHeartbeat, oldFailure, oldInterval
	})
	MachineValidationStartupDelaySeconds, MachineValidationHeartbeatSeconds, MachineValidationFailureBaseSeconds, MachineCheckIntervalSeconds = startup, heartbeat, failure, interval
}

// The production timers are pinned by a test that sets no validation input:
// the resident start-up delay, heartbeat and interval and the default check
// interval are the values the release build ships.
func TestProductionResidentTimersAreFixedWithoutValidationInputs(t *testing.T) {
	setValidationTimers(t, "", "", "", "")
	if residentInitialDelay != 2*time.Minute || residentInterval != 6*time.Hour || residentHeartbeatInterval != time.Minute {
		t.Fatalf("resident timers = %s %s %s", residentInitialDelay, residentInterval, residentHeartbeatInterval)
	}
	if got, err := machineCheckInterval(); err != nil || got != 6*time.Hour {
		t.Fatalf("default check interval = %s %v", got, err)
	}
	timers, present, err := loadMachineValidationTimers()
	if err != nil || present || timers != (machineValidationTimers{}) {
		t.Fatalf("production build carries validation timers: %+v %v %v", timers, present, err)
	}
	applyResidentTimers(timers, present)
	if residentInitialDelay != 2*time.Minute || residentHeartbeatInterval != time.Minute {
		t.Fatalf("an absent validation set changed the resident timers: %s %s", residentInitialDelay, residentHeartbeatInterval)
	}
}

func TestMachineValidationTimersOnlyShortenProductionValues(t *testing.T) {
	for _, tc := range []struct {
		name                        string
		startup, heartbeat, failure string
		valid                       bool
		wantStartup, wantHeartbeat  time.Duration
		wantFailure                 time.Duration
	}{
		{"typical", "5", "2", "30", true, 5 * time.Second, 2 * time.Second, 30 * time.Second},
		{"production values", "120", "60", "900", true, 2 * time.Minute, time.Minute, 15 * time.Minute},
		{"minimum", "1", "1", "1", true, time.Second, time.Second, time.Second},
		{"zero startup", "0", "2", "30", false, 0, 0, 0},
		{"negative heartbeat", "5", "-1", "30", false, 0, 0, 0},
		{"non-numeric failure", "5", "2", "abc", false, 0, 0, 0},
		{"fractional", "5", "2.5", "30", false, 0, 0, 0},
		{"startup above production", "121", "2", "30", false, 0, 0, 0},
		{"heartbeat above production", "5", "61", "30", false, 0, 0, 0},
		{"failure above production", "5", "2", "901", false, 0, 0, 0},
		{"only startup", "5", "", "", false, 0, 0, 0},
		{"missing heartbeat", "5", "", "30", false, 0, 0, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			setValidationTimers(t, tc.startup, tc.heartbeat, tc.failure, "")
			timers, present, err := loadMachineValidationTimers()
			if (err == nil) != tc.valid || present != tc.valid {
				t.Fatalf("present=%v err=%v", present, err)
			}
			if tc.valid && (timers.StartupDelay != tc.wantStartup || timers.Heartbeat != tc.wantHeartbeat || timers.FailureDelayBase != tc.wantFailure) {
				t.Fatalf("timers = %+v", timers)
			}
		})
	}
}

func TestSubMinuteCheckIntervalNeedsTheValidationTimerSet(t *testing.T) {
	for _, tc := range []struct {
		name                        string
		startup, heartbeat, failure string
		interval                    string
		want                        time.Duration
		valid                       bool
	}{
		{"production minimum", "", "", "", "60", time.Minute, true},
		{"sub-minute without timers", "", "", "", "5", 0, false},
		{"sub-minute with timers", "5", "2", "30", "5", 5 * time.Second, true},
		{"one second with timers", "5", "2", "30", "1", time.Second, true},
		{"zero with timers", "5", "2", "30", "0", 0, false},
		{"negative with timers", "5", "2", "30", "-5", 0, false},
		{"above a day with timers", "5", "2", "30", "86401", 0, false},
		{"broken timers", "5", "", "30", "5", 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			setValidationTimers(t, tc.startup, tc.heartbeat, tc.failure, tc.interval)
			got, err := machineCheckInterval()
			if (err == nil) != tc.valid || tc.valid && got != tc.want {
				t.Fatalf("interval = %s %v", got, err)
			}
		})
	}
}

func TestApplyResidentTimersShortensTheScheduleOnce(t *testing.T) {
	oldDelay, oldHeartbeat := residentInitialDelay, residentHeartbeatInterval
	t.Cleanup(func() { residentInitialDelay, residentHeartbeatInterval = oldDelay, oldHeartbeat })
	applyResidentTimers(machineValidationTimers{StartupDelay: 5 * time.Second, Heartbeat: 2 * time.Second, FailureDelayBase: 30 * time.Second}, true)
	if residentInitialDelay != 5*time.Second || residentHeartbeatInterval != 2*time.Second || residentInterval != 6*time.Hour {
		t.Fatalf("resident timers = %s %s %s", residentInitialDelay, residentHeartbeatInterval, residentInterval)
	}
}
