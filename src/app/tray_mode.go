//go:build !e2e

package main

// shouldStartTray keeps the shipped desktop application integrated with the
// Windows notification area. The E2E build has no interactive shell session,
// so its build-tag override deliberately leaves this OS integration disabled.
func shouldStartTray() bool { return true }
