package main

import "testing"

func TestMachineStartupArguments(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want bool
	}{
		{[]string{"--startup", "--machine-install"}, true},
		{[]string{"--machine-install", "--startup"}, false},
		{[]string{"--startup"}, false},
		{[]string{"--machine-install"}, false},
		{[]string{"--startup", "--machine-install", "--purge-user-data"}, false},
	} {
		if got := isMachineStartup(tc.args); got != tc.want {
			t.Fatalf("isMachineStartup(%q) = %v, want %v", tc.args, got, tc.want)
		}
	}
}

func TestMachineStartupHonorsPerUserOptOutBeforeQueue(t *testing.T) {
	if !allowMachineStartup(SettingsLoadResult{Settings: defaultAppSettings()}) {
		t.Fatal("first-run default should permit machine startup")
	}
	disabled := defaultAppSettings()
	disabled.AutostartEnabled = false
	if allowMachineStartup(SettingsLoadResult{Settings: disabled}) {
		t.Fatal("per-user opt-out must suppress machine startup")
	}
	if allowMachineStartup(SettingsLoadResult{Settings: defaultAppSettings(), Issue: &SettingsIssue{Kind: "malformed"}}) {
		t.Fatal("unreadable settings must suppress unattended machine startup")
	}
}
