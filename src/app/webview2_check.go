//go:build !bindings

package main

import (
	"errors"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows/registry"
)

// checkWebView2 is the D-08 fatal guard — run on every normal startup
// (production, wails dev) but skipped under the `bindings` build tag so that
// `wails build` / `wails generate module` can regenerate TypeScript bindings
// without a live WebView2 runtime being present.
//
// Returns a non-nil error if the Edge Evergreen runtime registry key is
// absent. The check probes three locations per Microsoft's distribution
// guidance:
//  1. HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-...}
//     (64-bit app on 64-bit Windows — per-machine install lands here)
//  2. HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-...}
//     (32-bit Windows, or odd install variants)
//  3. HKCU\Software\Microsoft\EdgeUpdate\Clients\{F3017226-...}
//     (per-user install)
//
// A non-empty `pv` value that isn't "0.0.0.0" signals a valid install.
func checkWebView2() error {
	paths := []struct {
		root registry.Key
		path string
	}{
		{registry.LOCAL_MACHINE, `SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`},
		{registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`},
		{registry.CURRENT_USER, `Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`},
	}
	for _, p := range paths {
		k, err := registry.OpenKey(p.root, p.path, registry.QUERY_VALUE)
		if err != nil {
			continue
		}
		pv, _, err := k.GetStringValue("pv")
		k.Close()
		if err == nil && pv != "" && pv != "0.0.0.0" {
			return nil
		}
	}
	return errors.New("WebView2 runtime not installed")
}

// showWebView2MissingDialog blocks until the user clicks OK on a native
// Win32 message box. Flags: MB_OK | MB_ICONERROR | MB_SYSTEMMODAL = 0x1010.
// Reuses the user32 LazyDLL + procMessageBoxW declared in sessionend.go
// (see PATTERNS.md Shared Pattern 2) — DOES NOT redeclare them here.
func showWebView2MissingDialog() {
	// syscall.UTF16PtrFromString returns (*uint16, error); the error is safely
	// discarded because the literals are compile-time constants with no NUL
	// bytes. Prefer this over the deprecated syscall.StringToUTF16Ptr (matches
	// sessionend.go, settings.go, singleinstance.go idiom).
	title, _ := syscall.UTF16PtrFromString("go-mapi — WebView2 required")
	body, _ := syscall.UTF16PtrFromString(
		"Microsoft Edge WebView2 Runtime is required to run go-mapi.\r\n\r\n" +
			"Your system browser will now open the Microsoft download page. " +
			"Install the runtime, then relaunch go-mapi.")
	procMessageBoxW.Call(
		0, // hWnd = null → system-modal
		uintptr(unsafe.Pointer(body)),
		uintptr(unsafe.Pointer(title)),
		uintptr(0x1010), // MB_OK | MB_ICONERROR
	)
}
