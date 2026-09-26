package service

import (
	"testing"
	"time"
)

func TestMachineCheckIntervalIsBoundedBuildValue(t *testing.T) {
	old := MachineCheckIntervalSeconds
	t.Cleanup(func() { MachineCheckIntervalSeconds = old })
	for _, tc := range []struct {
		value string
		want  time.Duration
		valid bool
	}{{"", 6 * time.Hour, true}, {"60", time.Minute, true}, {"21600", 6 * time.Hour, true}, {"59", 0, false}, {"86401", 0, false}, {"abc", 0, false}} {
		MachineCheckIntervalSeconds = tc.value
		got, err := machineCheckInterval()
		if (err == nil) != tc.valid || tc.valid && got != tc.want {
			t.Fatalf("interval %q: %s %v", tc.value, got, err)
		}
	}
}
