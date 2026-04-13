//go:build windows

package main

import (
	"errors"
	"fmt"

	"golang.org/x/sys/windows"
)

// mutexName is scoped to the Windows session (Local\ prefix), so each RDS user gets one instance.
// Ref: PITFALLS §7, RESEARCH §Pattern 4, REVIEWS HIGH Plan 03.
const mutexName = `Local\go-mapi-singleton-v3`

// raiseEventName is the session-scoped named event the first instance listens on.
// Second instance calls SetEvent to ask first instance to show its window.
// Replaces FindWindowW title-based raise (REVIEWS HIGH — title spoofing / locale / timing risk).
const raiseEventName = `Local\go-mapi-raise-v3`

var (
	mutexHandle windows.Handle
	eventHandle windows.Handle
)

// acquireSingleInstance tries to grab the per-session mutex.
// Returns raised=true if another instance already owns it (and signals that instance via named event).
//
// CORRECTNESS NOTE (post-Plan-03 fix): The earlier implementation called
// `windows.GetLastError()` AFTER `windows.CreateMutex` and compared against
// ERROR_ALREADY_EXISTS. That is unreliable in Go: the runtime may run other
// goroutines / syscalls on this OS thread between the CreateMutex syscall and
// the GetLastError syscall, clobbering the per-thread last-error value. The
// `golang.org/x/sys/windows.CreateMutex` wrapper already inspects the syscall's
// raw `e1` errno immediately and sets the `err` return to ERROR_ALREADY_EXISTS
// when the mutex pre-existed (see the //sys directive in syscall_windows.go:
// `[failretval == 0 || e1 == ERROR_ALREADY_EXISTS]`). So the canonical, race-
// free check is: inspect `err` directly, NOT GetLastError.
//
// The bug this fixes: with the GetLastError approach, the second instance saw
// lastErr=0 (success) instead of ERROR_ALREADY_EXISTS, treated itself as the
// first instance, kept its CreateMutex handle, and proceeded into wails.Run —
// so multiple processes coexisted instead of single-instance enforcement.
func acquireSingleInstance() (raised bool, err error) {
	name, err := windows.UTF16PtrFromString(mutexName)
	if err != nil {
		return false, fmt.Errorf("utf16 mutex name: %w", err)
	}

	handle, createErr := windows.CreateMutex(nil, false, name)
	// Canonical check: x/sys/windows.CreateMutex sets createErr to
	// ERROR_ALREADY_EXISTS (an errors.Is-compatible Errno) when the mutex
	// pre-existed. handle is still valid in that case and must be closed.
	if handle == 0 {
		return false, fmt.Errorf("CreateMutex failed: %w", createErr)
	}

	if errors.Is(createErr, windows.ERROR_ALREADY_EXISTS) {
		// Another instance owns the mutex. Close our duplicate handle.
		_ = windows.CloseHandle(handle)
		// Signal the first instance via named event.
		if raiseErr := raiseExistingInstance(); raiseErr != nil {
			logError("raise existing instance via named event: %v", raiseErr)
			// Fallback: intentionally none in primary path. FindWindowW fallback is
			// documented as a Plan 04 escape hatch if named-event path proves unreliable
			// during RAM-gate validation.
		}
		return true, nil
	}

	// We are the first instance. Keep the mutex handle for process lifetime.
	mutexHandle = handle

	// Create the named event (auto-reset, initial non-signaled) so the second instance can
	// find and signal it. Create BEFORE wails.Run so second-instance SetEvent works even if
	// our window isn't up yet; the dispatcher goroutine (started in app.startup) waits on it.
	//
	// Same correctness note as CreateMutex: use the err return, not GetLastError.
	evtName, _ := windows.UTF16PtrFromString(raiseEventName)
	evt, evtErr := windows.CreateEvent(nil, 0 /* auto-reset */, 0 /* non-signaled */, evtName)
	if evt == 0 {
		logError("createevent for raise transport: %v", evtErr)
		// Not fatal — mutex still enforces single-instance; we just lose the UX raise.
	} else if errors.Is(evtErr, windows.ERROR_ALREADY_EXISTS) {
		// Stale event from a previously-killed first instance — adopt the existing handle.
		// SetEvent / WaitForSingleObject both work on the existing kernel object.
		eventHandle = evt
		logInfo("adopted existing named event (stale from previous run)")
	} else {
		eventHandle = evt
	}

	return false, nil
}

// raiseExistingInstance opens the session-scoped named event and signals it.
// The first instance's dispatcher goroutine (see app.startup) wakes on the event and
// calls runtime.WindowShow / WindowUnminimise to bring the window forward.
//
// This is the ONLY raise transport in the primary code path. FindWindowW is NOT used.
func raiseExistingInstance() error {
	name, err := windows.UTF16PtrFromString(raiseEventName)
	if err != nil {
		return fmt.Errorf("utf16 event name: %w", err)
	}
	// EVENT_MODIFY_STATE = 0x0002 — minimum rights needed to call SetEvent.
	const eventModifyState = 0x0002
	h, err := windows.OpenEvent(eventModifyState, false, name)
	if err != nil || h == 0 {
		return fmt.Errorf("openevent: %w", err)
	}
	defer windows.CloseHandle(h)
	if err := windows.SetEvent(h); err != nil {
		return fmt.Errorf("setevent: %w", err)
	}
	return nil
}

// waitForRaiseSignal blocks on eventHandle; when the second instance calls SetEvent,
// this returns and the caller should show the main window. Returns when done channel closes.
func waitForRaiseSignal(done <-chan struct{}, onRaise func()) {
	if eventHandle == 0 {
		return // event wasn't created; no raise UX available
	}
	for {
		// Wait with a 500ms tick so done-channel shutdown isn't blocked indefinitely.
		const waitTickMs = 500
		rc, _ := windows.WaitForSingleObject(eventHandle, waitTickMs)
		select {
		case <-done:
			return
		default:
		}
		// WAIT_OBJECT_0 = 0 — signaled. Any other return code (timeout, abandoned) → loop.
		if rc == 0 {
			onRaise()
		}
	}
}

func releaseSingleInstance() {
	if mutexHandle != 0 {
		_ = windows.ReleaseMutex(mutexHandle)
		_ = windows.CloseHandle(mutexHandle)
		mutexHandle = 0
	}
	if eventHandle != 0 {
		_ = windows.CloseHandle(eventHandle)
		eventHandle = 0
	}
}
