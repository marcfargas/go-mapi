package main

import (
	"os"
	"path/filepath"
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

// TestWatcherDir_EnvPrecedence covers the override order in paths.go:
//
//	1. GOMAPI_WATCH_DIR  → used as-is (no "go-mapi" suffix)
//	2. TEMP              → filepath.Join(TEMP, "go-mapi")
//	3. TMP               → filepath.Join(TMP, "go-mapi")  (fallback when TEMP empty)
//	4. os.TempDir()      → filepath.Join(os.TempDir(), "go-mapi")  (final fallback)
//
// Subtests cannot use t.Parallel — they mutate process-wide env vars.
func TestWatcherDir_EnvPrecedence(t *testing.T) {
	overrideDir := filepath.Join(t.TempDir(), "override")
	tempA := t.TempDir()
	tempB := t.TempDir()

	t.Run("GOMAPI_WATCH_DIR wins over TEMP and TMP", func(t *testing.T) {
		t.Setenv("GOMAPI_WATCH_DIR", overrideDir)
		t.Setenv("TEMP", tempA)
		t.Setenv("TMP", tempB)
		got := watcherDir()
		if got != overrideDir {
			t.Errorf("watcherDir() = %q, want %q (used as-is)", got, overrideDir)
		}
	})

	t.Run("falls back to TEMP when GOMAPI_WATCH_DIR unset", func(t *testing.T) {
		t.Setenv("GOMAPI_WATCH_DIR", "")
		t.Setenv("TEMP", tempA)
		t.Setenv("TMP", tempB)
		want := filepath.Join(tempA, "go-mapi")
		got := watcherDir()
		if got != want {
			t.Errorf("watcherDir() = %q, want %q", got, want)
		}
	})

	t.Run("falls back to TMP when GOMAPI_WATCH_DIR and TEMP unset", func(t *testing.T) {
		t.Setenv("GOMAPI_WATCH_DIR", "")
		t.Setenv("TEMP", "")
		t.Setenv("TMP", tempB)
		want := filepath.Join(tempB, "go-mapi")
		got := watcherDir()
		if got != want {
			t.Errorf("watcherDir() = %q, want %q", got, want)
		}
	})

	t.Run("falls back to os.TempDir when GOMAPI_WATCH_DIR, TEMP, and TMP all unset", func(t *testing.T) {
		t.Setenv("GOMAPI_WATCH_DIR", "")
		t.Setenv("TEMP", "")
		t.Setenv("TMP", "")
		// On Windows, os.TempDir() reads from the same TEMP/TMP env vars, so
		// capture its return value under the same env to match what paths.go sees.
		want := filepath.Join(os.TempDir(), "go-mapi")
		got := watcherDir()
		if got != want {
			t.Errorf("watcherDir() = %q, want %q", got, want)
		}
		if got == "" {
			t.Error("watcherDir() returned empty string")
		}
	})
}
