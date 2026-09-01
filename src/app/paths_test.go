package main

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestAppDataDir_EnvPrecedence — mirrors TestWatcherDir_EnvPrecedence shape.
// Subtests cannot t.Parallel — they mutate process-wide env vars.
func TestAppDataDir_EnvPrecedence(t *testing.T) {
	t.Run("GOMAPI_APPDATA_DIR wins", func(t *testing.T) {
		tmp := t.TempDir()
		t.Setenv("GOMAPI_APPDATA_DIR", tmp)
		t.Setenv("APPDATA", "C:\\Users\\other\\AppData\\Roaming")
		got := appDataDir()
		if got != tmp {
			t.Errorf("GOMAPI_APPDATA_DIR should win: got %q, want %q", got, tmp)
		}
	})
	t.Run("APPDATA used when override empty", func(t *testing.T) {
		t.Setenv("GOMAPI_APPDATA_DIR", "")
		t.Setenv("APPDATA", "C:\\Users\\test\\AppData\\Roaming")
		got := appDataDir()
		want := filepath.Join("C:\\Users\\test\\AppData\\Roaming", "go-mapi")
		if got != want {
			t.Errorf("APPDATA path: got %q, want %q", got, want)
		}
	})
	t.Run("fallback when no env", func(t *testing.T) {
		t.Setenv("GOMAPI_APPDATA_DIR", "")
		t.Setenv("APPDATA", "")
		got := appDataDir()
		if got == "" {
			t.Error("appDataDir() returned empty string with no env vars set")
		}
		// We don't assert the exact fallback path — os.UserConfigDir is
		// platform-dependent; just ensure it's non-empty.
	})
}

// TestWatcherDir_EnvPrecedence — quick/260423-msq rewires the resolution chain
// to ignore TEMP/TMP entirely and resolve via %LOCALAPPDATA%\go-mapi\queue to
// match the DLL-side SHGetFolderPathW(CSIDL_LOCAL_APPDATA) path.
//
//  1. GOMAPI_WATCH_DIR        → used as-is (test / per-session override)
//  2. %LOCALAPPDATA%\go-mapi\queue
//  3. platform fallback (os.UserCacheDir) — POSIX CI compile only
//
// TEMP and TMP are intentionally NOT consulted. This regression guard fails
// if either env var ever leaks back into the resolved path.
//
// Subtests cannot use t.Parallel — they mutate process-wide env vars.
func TestWatcherDir_EnvPrecedence(t *testing.T) {
	overrideDir := filepath.Join(t.TempDir(), "override")
	localAppData := filepath.Join(t.TempDir(), "localappdata")

	t.Run("GOMAPI_WATCH_DIR wins — used as-is", func(t *testing.T) {
		t.Setenv("GOMAPI_WATCH_DIR", overrideDir)
		t.Setenv("LOCALAPPDATA", localAppData)
		t.Setenv("TEMP", "C:\\BOGUS\\TEMP")
		t.Setenv("TMP", "C:\\BOGUS\\TMP")
		if got := watcherDir(); got != overrideDir {
			t.Errorf("watcherDir() = %q, want %q (as-is)", got, overrideDir)
		}
	})

	t.Run("LOCALAPPDATA used when GOMAPI_WATCH_DIR empty — TEMP and TMP ignored", func(t *testing.T) {
		t.Setenv("GOMAPI_WATCH_DIR", "")
		t.Setenv("LOCALAPPDATA", localAppData)
		bogusTemp := filepath.Join(t.TempDir(), "process-local-temp")
		bogusTmp := filepath.Join(t.TempDir(), "process-local-tmp")
		t.Setenv("TEMP", bogusTemp)
		t.Setenv("TMP", bogusTmp)

		want := filepath.Join(localAppData, "go-mapi", "queue")
		got := watcherDir()
		if got != want {
			t.Errorf("watcherDir() = %q, want %q", got, want)
		}
		// Regression guard for the bug this plan fixes: TEMP/TMP must have zero
		// influence on the resolved path.
		if strings.Contains(got, bogusTemp) || strings.Contains(got, bogusTmp) {
			t.Errorf("watcherDir() = %q leaked TEMP=%q or TMP=%q into the path", got, bogusTemp, bogusTmp)
		}
	})

	t.Run("non-empty fallback when LOCALAPPDATA and GOMAPI_WATCH_DIR both empty", func(t *testing.T) {
		t.Setenv("GOMAPI_WATCH_DIR", "")
		t.Setenv("LOCALAPPDATA", "")
		if got := watcherDir(); got == "" {
			t.Error("watcherDir() returned empty string with no env vars set — callers assume non-empty")
		}
	})
}
