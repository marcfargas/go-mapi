package main

import (
	"os"
	"path/filepath"
)

// watcherDir returns the directory that the MAPI interceptor DLL writes email JSON files to.
// Mirrors the logic in src/native-host/main.go defaultWatchDir().
// DLL, native-host, and Wails app must all agree on this path.
func watcherDir() string {
	// Check GOMAPI_WATCH_DIR env var first (allows per-session override under RDS).
	if dir := os.Getenv("GOMAPI_WATCH_DIR"); dir != "" {
		return dir
	}

	// Default: %TEMP%\go-mapi\ — matches the MAPI interceptor DLL and native-host.
	tempDir := os.Getenv("TEMP")
	if tempDir == "" {
		tempDir = os.Getenv("TMP")
	}
	if tempDir == "" {
		tempDir = os.TempDir()
	}
	return filepath.Join(tempDir, "go-mapi")
}
