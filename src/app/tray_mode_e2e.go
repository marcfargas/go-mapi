//go:build e2e

package main

// The Playwright harness runs the app through CDP without an interactive
// Windows shell. Starting systray there fails before the Wails UI can boot.
func shouldStartTray() bool { return false }
