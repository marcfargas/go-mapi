package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

type recordingStartupService struct {
	sets    []bool
	warning string
}

func (s *recordingStartupService) State(_ context.Context, requested bool) StartupState {
	return StartupState{Backend: "test", Requested: requested, Effective: "disabled"}
}

func (s *recordingStartupService) Set(_ context.Context, requested bool) StartupState {
	s.sets = append(s.sets, requested)
	return StartupState{Backend: "test", Requested: requested, Effective: "error", Warning: s.warning}
}

func (s *recordingStartupService) OpenSettings() error { return nil }

func TestStartupSetterPersistsRequestBeforePlatformWarning(t *testing.T) {
	t.Setenv("GOMAPI_APPDATA_DIR", t.TempDir())
	service := &recordingStartupService{warning: "Windows registration failed"}
	a := &App{settings: defaultAppSettings(), startupService: service, trayRefreshCh: make(chan struct{}, 1)}
	for _, enabled := range []bool{false, true} {
		state, err := a.SetAutostartEnabled(enabled)
		if err != nil {
			t.Fatalf("SetAutostartEnabled(%t): %v", enabled, err)
		}
		if state.Requested != enabled || state.Warning != service.warning {
			t.Fatalf("returned state = %+v", state)
		}
		if loaded := loadSettings(); loaded.Issue != nil || loaded.Settings.AutostartEnabled != enabled {
			t.Fatalf("durable settings = %+v, want requested %t", loaded, enabled)
		}
		fresh := &App{settings: loadSettings().Settings, startupService: service}
		if got := fresh.GetStartupState(); got.Requested != enabled {
			t.Fatalf("fresh GetStartupState = %+v, want requested %t", got, enabled)
		}
	}
	if len(service.sets) != 2 || service.sets[0] || !service.sets[1] {
		t.Fatalf("platform calls = %v", service.sets)
	}
}

func TestStartupSetterSaveFailurePreservesRequestAndSkipsPlatform(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)
	if err := os.Mkdir(filepath.Join(dir, "settings.json"), 0700); err != nil {
		t.Fatal(err)
	}
	service := &recordingStartupService{}
	a := &App{settings: defaultAppSettings(), startupService: service, trayRefreshCh: make(chan struct{}, 1)}
	if _, err := a.SetAutostartEnabled(false); err == nil {
		t.Fatal("expected save failure")
	}
	if !a.settings.AutostartEnabled || len(service.sets) != 0 {
		t.Fatalf("failed save changed memory or platform: settings=%+v calls=%v", a.settings, service.sets)
	}
	if info, err := os.Stat(filepath.Join(dir, "settings.json")); err != nil || !info.IsDir() {
		t.Fatalf("existing settings path changed: info=%v err=%v", info, err)
	}
}
