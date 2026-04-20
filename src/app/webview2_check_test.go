//go:build windows && !bindings

package main

import (
	"strings"
	"testing"

	"golang.org/x/sys/windows/registry"
)

const webview2TestGUID = `{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`

// seedPVInHKCU writes pv=value under
// HKCU\Software\Microsoft\EdgeUpdate\Clients\{GUID}. Returns a cleanup func
// that deletes the (sub)key we created.
func seedPVInHKCU(t *testing.T, value string) func() {
	t.Helper()
	parentPath := `Software\Microsoft\EdgeUpdate\Clients\` + webview2TestGUID
	k, _, err := registry.CreateKey(registry.CURRENT_USER, parentPath, registry.SET_VALUE|registry.QUERY_VALUE)
	if err != nil {
		t.Fatalf("CreateKey HKCU %s: %v", parentPath, err)
	}
	if err := k.SetStringValue("pv", value); err != nil {
		k.Close()
		t.Fatalf("SetStringValue pv=%q: %v", value, err)
	}
	k.Close()
	return func() {
		_ = registry.DeleteKey(registry.CURRENT_USER, parentPath)
	}
}

// anyHKLMRuntimePresent returns true if either HKLM probe path has a
// non-empty, non-"0.0.0.0" pv value. Used to skip tests that assume the
// HKLM view is clean (e.g. `windows-latest` has WebView2 preinstalled).
func anyHKLMRuntimePresent(t *testing.T) bool {
	t.Helper()
	paths := []string{
		`SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\` + webview2TestGUID,
		`SOFTWARE\Microsoft\EdgeUpdate\Clients\` + webview2TestGUID,
	}
	for _, p := range paths {
		k, err := registry.OpenKey(registry.LOCAL_MACHINE, p, registry.QUERY_VALUE)
		if err != nil {
			continue
		}
		pv, _, err := k.GetStringValue("pv")
		k.Close()
		if err == nil && pv != "" && pv != "0.0.0.0" {
			return true
		}
	}
	return false
}

func TestCheckWebView2_ReturnsNilWhenPVPresent(t *testing.T) {
	cleanup := seedPVInHKCU(t, "120.0.2210.144")
	defer cleanup()
	if err := checkWebView2(); err != nil {
		t.Fatalf("expected nil error with pv seeded in HKCU, got %v", err)
	}
}

func TestCheckWebView2_IgnoresZeroVersion(t *testing.T) {
	if anyHKLMRuntimePresent(t) {
		t.Skip("HKLM already has a valid pv — cannot test zero-version fallthrough without elevation to delete HKLM keys")
	}
	cleanup := seedPVInHKCU(t, "0.0.0.0")
	defer cleanup()
	if err := checkWebView2(); err == nil {
		t.Fatal("expected non-nil error with pv=0.0.0.0 and no HKLM runtime, got nil")
	}
}

func TestCheckWebView2_ErrorMessageMentionsRuntime(t *testing.T) {
	// If ANY probed path has a valid pv, checkWebView2 returns nil → skip.
	if anyHKLMRuntimePresent(t) {
		t.Skip("WebView2 is installed on this machine; cannot test error-path message shape")
	}
	// Also skip if HKCU already has a value (not created by this test).
	hkcuPath := `Software\Microsoft\EdgeUpdate\Clients\` + webview2TestGUID
	if k, err := registry.OpenKey(registry.CURRENT_USER, hkcuPath, registry.QUERY_VALUE); err == nil {
		if pv, _, err := k.GetStringValue("pv"); err == nil && pv != "" && pv != "0.0.0.0" {
			k.Close()
			t.Skipf("HKCU %s pv=%q present — cannot test error path without disturbing it", hkcuPath, pv)
		}
		k.Close()
	}
	err := checkWebView2()
	if err == nil {
		t.Fatal("expected error when no runtime present")
	}
	if !strings.Contains(err.Error(), "WebView2") || !strings.Contains(err.Error(), "not installed") {
		t.Fatalf("error message missing expected keywords: %q", err.Error())
	}
}
