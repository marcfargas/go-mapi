//go:build windows

package main

import (
	"context"
	"os"
	"syscall"
	"time"
	"unsafe"
)

const (
	wmQueryEndSession = 0x0011
	wmEndSession      = 0x0016
	hwndMessage       = ^uintptr(2) // (HWND)(-3) sentinel for message-only window
)

var (
	kernel32            = syscall.NewLazyDLL("kernel32.dll")
	procGetModuleHandle = kernel32.NewProc("GetModuleHandleW")

	user32            = syscall.NewLazyDLL("user32.dll")
	procRegisterClass = user32.NewProc("RegisterClassExW")
	procCreateWindow  = user32.NewProc("CreateWindowExW")
	procDefWindowProc = user32.NewProc("DefWindowProcW")
	procDestroyWindow = user32.NewProc("DestroyWindow")
	procGetMessage    = user32.NewProc("GetMessageW")
	procTranslateMsg  = user32.NewProc("TranslateMessage")
	procDispatchMsg   = user32.NewProc("DispatchMessageW")
	procPostQuitMsg   = user32.NewProc("PostQuitMessage")
	procPostMessage   = user32.NewProc("PostMessageW")

	// procMessageBoxW is used by webview2_check.go to show the native
	// runtime-missing dialog (D-08). Declared here alongside the other
	// user32 procs to avoid redeclaring the user32 LazyDLL handle in a
	// sibling file (Go would fail with "user32 redeclared in this block"
	// because both files are `package main`).
	procMessageBoxW = user32.NewProc("MessageBoxW")
)

type wndclassex struct {
	cbSize        uint32
	style         uint32
	lpfnWndProc   uintptr
	cbClsExtra    int32
	cbWndExtra    int32
	hInstance     uintptr
	hIcon         uintptr
	hCursor       uintptr
	hbrBackground uintptr
	lpszMenuName  *uint16
	lpszClassName *uint16
	hIconSm       uintptr
}

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      struct{ X, Y int32 }
}

// sessionEndSignal is called by WndProc when WM_QUERYENDSESSION arrives.
// MUST be non-blocking — set by registerSessionEndHandler.
var sessionEndSignal func()

// registerSessionEndHandler creates a hidden message-only HWND and starts a message pump goroutine.
// onQueryEnd is called NON-BLOCKING from WndProc when WM_QUERYENDSESSION arrives.
// Returns a cancel() that destroys the window and exits the pump.
//
// CRITICAL (REVIEWS HIGH): WndProc must NOT perform I/O. It returns TRUE immediately.
// The actual watcher drain is scheduled asynchronously via the shutdown context by the caller.
func registerSessionEndHandler(onQueryEnd func()) (cancel func(), err error) {
	sessionEndSignal = onQueryEnd

	className, _ := syscall.UTF16PtrFromString("GoMapiSessionEndWnd")
	hInstance, _, _ := procGetModuleHandle.Call(0)

	wc := wndclassex{
		cbSize:        uint32(unsafe.Sizeof(wndclassex{})),
		lpfnWndProc:   syscall.NewCallback(sessionEndWndProc),
		hInstance:     hInstance,
		lpszClassName: className,
	}
	procRegisterClass.Call(uintptr(unsafe.Pointer(&wc)))

	hwnd, _, _ := procCreateWindow.Call(
		0, uintptr(unsafe.Pointer(className)), 0,
		0, 0, 0, 0, 0,
		hwndMessage,
		0, hInstance, 0,
	)
	if hwnd == 0 {
		return nil, syscall.GetLastError()
	}

	pumpDone := make(chan struct{})
	go func() {
		defer close(pumpDone)
		var m msg
		for {
			ret, _, _ := procGetMessage.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
			if int32(ret) <= 0 {
				// GetMessage returns 0 on WM_QUIT, -1 on error.
				return
			}
			procTranslateMsg.Call(uintptr(unsafe.Pointer(&m)))
			procDispatchMsg.Call(uintptr(unsafe.Pointer(&m)))
		}
	}()

	cancel = func() {
		// Post WM_QUIT to the HWND's thread message queue so GetMessage unblocks.
		// Use PostMessage(hwnd, WM_QUIT, 0, 0) — this posts to the thread that
		// owns hwnd, which is the goroutine running the message pump above.
		procDestroyWindow.Call(hwnd)
		// PostQuitMessage posts WM_QUIT to current thread — but the pump runs on its
		// own goroutine (different OS thread due to GOMAXPROCS). Instead, post directly.
		const wmQuit = 0x0012
		procPostMessage.Call(hwnd, wmQuit, 0, 0)
		select {
		case <-pumpDone:
		case <-time.After(500 * time.Millisecond):
			// If pump doesn't exit in 500ms, give up — don't block shutdown.
		}
	}
	return cancel, nil
}

// sessionEndWndProc — CRITICAL: returns immediately on WM_QUERYENDSESSION.
// No I/O, no watcher.Stop(), no bridge.Close() from inside this function. Those happen
// asynchronously in the drain goroutine below (REVIEWS HIGH fix).
func sessionEndWndProc(hwnd uintptr, umsg uint32, wParam, lParam uintptr) uintptr {
	switch umsg {
	case wmQueryEndSession:
		// Non-blocking signal: cancel the shutdown context. The async drain goroutine picks it up.
		if sessionEndSignal != nil {
			sessionEndSignal()
		}
		return 1 // TRUE — tell Windows we agree to end. RETURN IMMEDIATELY.
	case wmEndSession:
		return 0
	}
	ret, _, _ := procDefWindowProc.Call(hwnd, uintptr(umsg), wParam, lParam)
	return ret
}

// runBoundedDrain waits for shutdownCtx.Done(), then drains watcher + bridge with a 2-second
// bounded timeout. If the drain stalls (e.g., watcher.Stop hangs on a file lock), os.Exit
// forces termination so Windows logoff isn't blocked past the deadline.
func runBoundedDrain(shutdownCtx context.Context, drain func()) {
	<-shutdownCtx.Done()

	drainDone := make(chan struct{})
	timeoutCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	go func() {
		drain()
		close(drainDone)
	}()

	select {
	case <-drainDone:
		// Clean shutdown; caller's Wails shutdown path continues normally.
		return
	case <-timeoutCtx.Done():
		// Drain exceeded 2s — force exit so logoff proceeds.
		logError("session-end drain exceeded 2s timeout; forcing os.Exit")
		os.Exit(0)
	}
}
