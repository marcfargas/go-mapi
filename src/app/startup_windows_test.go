//go:build windows

package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	"golang.org/x/sys/windows/registry"
)

type fakeMSIXStartupTaskAPI struct {
	states  []string
	err     error
	actions []string
}

func (f *fakeMSIXStartupTaskAPI) State(_ context.Context, action string) (string, error) {
	f.actions = append(f.actions, action)
	if f.err != nil {
		return "", f.err
	}
	if len(f.states) == 0 {
		return "", errors.New("unexpected StartupTask request")
	}
	state := f.states[0]
	f.states = f.states[1:]
	return state, nil
}

type fakeStartupRegistrationStore struct {
	value     string
	exists    bool
	readErr   error
	writeErr  error
	deleteErr error
}

func (f *fakeStartupRegistrationStore) Read() (string, error) {
	if f.readErr != nil {
		return "", f.readErr
	}
	if !f.exists {
		return "", registry.ErrNotExist
	}
	return f.value, nil
}

func (f *fakeStartupRegistrationStore) Write(value string) error {
	if f.writeErr != nil {
		return f.writeErr
	}
	f.value = value
	f.exists = true
	return nil
}

func (f *fakeStartupRegistrationStore) Delete() error {
	if f.deleteErr != nil {
		return f.deleteErr
	}
	f.value = ""
	f.exists = false
	return nil
}

func TestStandaloneStartupStateDistinguishesRequestedRegisteredEffective(t *testing.T) {
	store := &fakeStartupRegistrationStore{exists: true, value: `"C:\Apps\go-mapi\go-mapi.exe" --startup`}
	service := &windowsStartupService{registration: store, exePath: `C:\Apps\go-mapi\go-mapi.exe`}
	state := service.State(context.Background(), true)
	if !state.Requested || !state.Registered || state.Effective != "enabled" || state.Warning != "" {
		t.Fatalf("state = %+v", state)
	}
}

func TestStandaloneStartupRejectsForeignExecutable(t *testing.T) {
	store := &fakeStartupRegistrationStore{exists: true, value: `"C:\Other\go-mapi.exe" --startup`}
	service := &windowsStartupService{registration: store, exePath: `C:\Apps\go-mapi\go-mapi.exe`}
	state := service.State(context.Background(), true)
	if state.Effective != "mismatched" || state.Warning == "" {
		t.Fatalf("state = %+v", state)
	}
}

func TestStandaloneStartupEnableRepairsMissingRegistration(t *testing.T) {
	store := &fakeStartupRegistrationStore{}
	service := &windowsStartupService{registration: store, exePath: `C:\Apps\go-mapi\go-mapi.exe`}
	state := service.Set(context.Background(), true)
	if state.Effective != "enabled" || state.Warning != "" {
		t.Fatalf("state = %+v", state)
	}
	if got := store.value; got != `"C:\Apps\go-mapi\go-mapi.exe" --startup` {
		t.Fatalf("unexpected startup registration: %q", got)
	}
}

func TestStandaloneStartupDisableRemovesOnlyPerUserRegistration(t *testing.T) {
	store := &fakeStartupRegistrationStore{exists: true, value: `"C:\Apps\go-mapi\go-mapi.exe" --startup`}
	service := &windowsStartupService{registration: store, exePath: `C:\Apps\go-mapi\go-mapi.exe`}
	state := service.Set(context.Background(), false)
	if store.exists || state.Registered || state.Effective != "missing" || state.Warning != "" {
		t.Fatalf("state = %+v, store = %+v", state, store)
	}
}

func TestMSIXStartupStatesExposeWindowsDenial(t *testing.T) {
	for _, tc := range []struct{ state, warning string }{
		{"Enabled", ""},
		{"DisabledByUser", "user"},
		{"DisabledByPolicy", "policy"},
		{"EnabledByPolicy", "policy"},
	} {
		t.Run(tc.state, func(t *testing.T) {
			msix := &fakeMSIXStartupTaskAPI{states: []string{tc.state}}
			service := &windowsStartupService{msix: msix, packaged: true}
			got := service.State(context.Background(), true)
			if got.Effective != strings.ToLower(tc.state) {
				t.Fatalf("state = %+v", got)
			}
			if tc.warning != "" && !strings.Contains(strings.ToLower(got.Warning), tc.warning) {
				t.Fatalf("warning = %q", got.Warning)
			}
		})
	}
}

func TestMSIXEnableUsesInProcessStartupTaskAPI(t *testing.T) {
	msix := &fakeMSIXStartupTaskAPI{states: []string{"Disabled"}}
	service := &windowsStartupService{msix: msix, packaged: true}
	got := service.Set(context.Background(), true)
	if got.Effective != "disabled" || got.Warning == "" {
		t.Fatalf("state = %+v", got)
	}
	if len(msix.actions) != 1 || msix.actions[0] != "enable" {
		t.Fatalf("actions = %v", msix.actions)
	}
}

func TestStartupTaskStateNames(t *testing.T) {
	for state, want := range map[int32]string{0: "Disabled", 1: "DisabledByUser", 2: "Enabled", 3: "DisabledByPolicy", 4: "EnabledByPolicy"} {
		if got := startupTaskStateName(state); got != want {
			t.Errorf("state %d = %q, want %q", state, got, want)
		}
	}
}
