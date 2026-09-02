//go:build !e2e

package main

import "testing"

func TestProductionBuildStartsTray(t *testing.T) {
	if !shouldStartTray() {
		t.Fatal("production build must start the system tray")
	}
}
