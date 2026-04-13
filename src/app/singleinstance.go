//go:build windows

package main

import (
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
// CRITICAL (REVIEWS HIGH): CreateMutex returns a valid handle even when ERROR_ALREADY_EXISTS.
// The error is reported via GetLastError, NOT via the err return. Call GetLastError BEFORE any
// other syscall on this thread to avoid clobbering it.
func acquireSingleInstance() (raised bool, err error) {
	name, err := windows.UTF16PtrFromString(mutexName)
	if err != nil {
		return false, fmt.Errorf("utf16 mutex name: %w", err)
	}

	handle, createErr := windows.CreateMutex(nil, false, name)
	// GetLastError MUST be called before any other syscall on this goroutine (REVIEWS HIGH fix).
	lastErr := windows.GetLastError()

	if handle == 0 {
		// Genuine CreateMutex failure (rare) — fail closed only if we can't create state.
		return false, fmt.Errorf("createmutex failed: %v (lastErr=%v)", createErr, lastErr)
	}

	if lastErr == windows.ERROR_ALREADY_EXISTS {
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
	evtName, _ := windows.UTF16PtrFromString(raiseEventName)
	evt, evtErr := windows.CreateEvent(nil, 0 /* auto-reset */, 0 /* non-signaled */, evtName)
	if evt == 0 {
		logError("createevent for raise transport: %v", evtErr)
		// Not fatal — mutex still enforces single-instance; we just lose the UX raise.
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
