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
