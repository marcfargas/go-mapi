//go:build e2e

package main

import "testing"

func TestE2EBuildSkipsTray(t *testing.T) {
	if shouldStartTray() {
		t.Fatal("E2E build must not require an interactive system tray")
	}
}
