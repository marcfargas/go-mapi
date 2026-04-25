package main

import (
	"os"
	"path/filepath"
)

// watcherDir returns the directory that the MAPI interceptor DLL writes email JSON files to.
//
// As of quick/260423-msq: the DLL resolves this via SHGetFolderPathW(CSIDL_LOCAL_APPDATA)
// + "\\go-mapi\\queue", which is session-scoped and immune to per-process TEMP/TMP
// overrides (fixes the bug where legacy apps overriding TEMP redirected MAPI JSON away
// from the watcher). The Go side mirrors that resolution by reading LOCALAPPDATA directly.
//
// Precedence:
//  1. GOMAPI_WATCH_DIR — used as-is (test override / RDS per-session override).
//  2. %LOCALAPPDATA%\go-mapi\queue — production path; must match the DLL.
//  3. Platform fallback (os.UserCacheDir) — keeps Go test compile green on POSIX CI.
//
// TEMP and TMP are intentionally NOT consulted — doing so would reintroduce the bug.
func watcherDir() string {
	if dir := os.Getenv("GOMAPI_WATCH_DIR"); dir != "" {
		return dir
	}
	if localAppData := os.Getenv("LOCALAPPDATA"); localAppData != "" {
		return filepath.Join(localAppData, "go-mapi", "queue")
	}
	if cacheDir, err := os.UserCacheDir(); err == nil {
		return filepath.Join(cacheDir, "go-mapi", "queue")
	}
	return filepath.Join(".", "go-mapi", "queue")
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

// updatesStagingDir returns %ProgramData%\go-mapi\updates\ — the silent-update
// staging area: download asset, verify SHA-256, atomic-swap installed binary.
// Inherits %ProgramData% default ACL: SYSTEM + Administrators full, Users read.
// (RESEARCH §Don't Hand-Roll — Phase 10 D-12 already relies on this for %ProgramData%\go-mapi\uninst\.)
//
// Precedence:
//  1. GOMAPI_UPDATES_DIR — test override (mirrors GOMAPI_APPDATA_DIR / GOMAPI_WATCH_DIR).
//  2. %ProgramData%\go-mapi\updates — production path (machine-scope).
//  3. Platform fallback (filepath.Join(os.TempDir(), "go-mapi", "updates")) for POSIX CI compile.
//
// Callers must os.MkdirAll the result before writing.
func updatesStagingDir() string {
	if dir := os.Getenv("GOMAPI_UPDATES_DIR"); dir != "" {
		return dir
	}
	if pd := os.Getenv("ProgramData"); pd != "" {
		return filepath.Join(pd, "go-mapi", "updates")
	}
	return filepath.Join(os.TempDir(), "go-mapi", "updates")
}
