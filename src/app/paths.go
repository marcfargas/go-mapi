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

// appDataDir returns the directory that holds per-user go-mapi state:
// settings.json (Phase 9), app.log (Phase 7/8), future: toast icon cache, etc.
//
// Precedence:
//  1. GOMAPI_APPDATA_DIR env var (test override — same pattern as GOMAPI_WATCH_DIR).
//  2. %APPDATA% env var + "go-mapi" (production Windows path).
//  3. Platform fallback (os.UserConfigDir) — keeps the helper callable on non-
//     Windows during `go test ./src/app/...` on POSIX CI.
//
// Callers are responsible for `os.MkdirAll(dir, 0700)` before writing —
// mirrors the invariant enforced at logging.go initLog() line 27.
func appDataDir() string {
	if dir := os.Getenv("GOMAPI_APPDATA_DIR"); dir != "" {
		return dir
	}
	if appData := os.Getenv("APPDATA"); appData != "" {
		return filepath.Join(appData, "go-mapi")
	}
	// Non-Windows fallback for test compilation. On Windows this branch is
	// unreachable in practice (APPDATA is always set for logon sessions).
	if cfg, err := os.UserConfigDir(); err == nil {
		return filepath.Join(cfg, "go-mapi")
	}
	return filepath.Join(".", "go-mapi")
}
