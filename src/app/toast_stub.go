//go:build !windows

package main

import "github.com/marcfargas/go-mapi/internal/mapi"

// Non-Windows stubs for cross-compile + non-Windows test runs.
// All functions are no-ops so the codebase compiles cleanly on Linux/macOS.

func initToasts(_ *App) error                           { return nil }
func emitArrivalToast(_ *App, _ mapi.EmailWithId)       {}
func emitDraftSuccessToast(_ *App, _, _ string)         {}
func emitErrorToast(_ *App, _, _ string)                {}
func emitSummaryInvalidGrantToast(_ *App)               {}
func clearToastForEmail(_ string)                       {}
