package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// TestMain points every per-user settings and log location at a temporary
// profile, so no test in this package can read or write the real
// %APPDATA%\go-mapi settings (NewApp loads settings.json). Per-test t.Setenv
// overrides still apply and are restored to these values afterwards.
func TestMain(m *testing.M) {
	root, err := os.MkdirTemp("", "gomapi-app-test-")
	if err != nil {
		fmt.Fprintf(os.Stderr, "TestMain: create temp profile: %v\n", err)
		os.Exit(1)
	}
	roaming := filepath.Join(root, "Roaming")
	appData := filepath.Join(roaming, "go-mapi")
	if err := os.MkdirAll(appData, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "TestMain: create temp profile: %v\n", err)
		os.Exit(1)
	}
	for key, value := range map[string]string{
		"APPDATA":            roaming,
		"GOMAPI_APPDATA_DIR": appData,
	} {
		if err := os.Setenv(key, value); err != nil {
			fmt.Fprintf(os.Stderr, "TestMain: set %s: %v\n", key, err)
			os.Exit(1)
		}
	}
	code := m.Run()
	// Best effort: on Windows app.log may still be held open by the logger.
	_ = os.RemoveAll(root)
	os.Exit(code)
}
