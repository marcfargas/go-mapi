package main

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

func testAdminHealth(component, action string) ComponentHealthState {
	issues := []ComponentHealthIssue{}
	if component != "" {
		issues = append(issues, ComponentHealthIssue{Component: component, Action: action, Code: "missing"})
	}
	return ComponentHealthState{Healthy: len(issues) == 0, Issues: issues}
}

func TestAdminInstallOfferConsumesComponentHealth(t *testing.T) {
	for _, tc := range []struct {
		name      string
		health    ComponentHealthState
		wantPhase AdminInstallPhase
	}{
		{"healthy", testAdminHealth("", ""), AdminInstallHealthy},
		{"missing interceptor", testAdminHealth("interceptor", "install-interceptor"), AdminInstallOffer},
		{"partial interceptor", testAdminHealth("interceptor", "repair-interceptor"), AdminInstallOffer},
		{"outdated interceptor", testAdminHealth("interceptor", "update-interceptor"), AdminInstallOffer},
		{"app must update", testAdminHealth("app", "update-app"), AdminInstallHealthy},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := adminInstallStateForHealth(tc.health, time.Now)
			if state.Phase != tc.wantPhase {
				t.Fatalf("phase = %q, want %q", state.Phase, tc.wantPhase)
			}
		})
	}
}

func TestAdminInstallRequiresExplicitConsent(t *testing.T) {
	health := testAdminHealth("interceptor", "install-interceptor")
	called := false
	coordinator := newAdminInstallCoordinator(func() ComponentHealthState { return health }, func(context.Context, ComponentHealthState) (bool, error) { called = true; return false, nil }, nil)
	coordinator.observe(health)
	if called {
		t.Fatal("observing an unhealthy component must not start a repair")
	}
	if err := coordinator.start(context.Background()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for !called && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !called {
		t.Fatal("repair was not started after explicit consent")
	}
}

func TestAdminInstallZeroExitNeedsHealthyPostcheck(t *testing.T) {
	health := testAdminHealth("interceptor", "repair-interceptor")
	coordinator := newAdminInstallCoordinator(func() ComponentHealthState { return health }, func(context.Context, ComponentHealthState) (bool, error) { return false, nil }, nil)
	if err := coordinator.start(context.Background()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for coordinator.snapshot().Phase == AdminInstallPreparing || coordinator.snapshot().Phase == AdminInstallRechecking {
		if time.Now().After(deadline) {
			t.Fatal("coordinator did not finish")
		}
		time.Sleep(time.Millisecond)
	}
	if got := coordinator.snapshot(); got.Phase != AdminInstallFailed || got.ErrorCode != "post-install-health-failed" {
		t.Fatalf("state = %#v, want failed postcheck", got)
	}
}

func TestAdminInstallSerializesAttempts(t *testing.T) {
	health := testAdminHealth("interceptor", "repair-interceptor")
	started := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	coordinator := newAdminInstallCoordinator(func() ComponentHealthState { return health }, func(context.Context, ComponentHealthState) (bool, error) {
		once.Do(func() { close(started) })
		<-release
		return false, errors.New("expected")
	}, nil)
	if err := coordinator.start(context.Background()); err != nil {
		t.Fatal(err)
	}
	<-started
	if err := coordinator.start(context.Background()); err == nil {
		t.Fatal("second concurrent consent must be rejected")
	}
	close(release)
}

func TestAdminInstallFailsClosedWithoutTrustedReleaseContract(t *testing.T) {
	health := testAdminHealth("interceptor", "install-interceptor")
	coordinator := newAdminInstallCoordinator(func() ComponentHealthState { return health }, nil, nil)
	if err := coordinator.start(context.Background()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for coordinator.snapshot().Phase == AdminInstallPreparing {
		if time.Now().After(deadline) {
			t.Fatal("coordinator did not fail closed")
		}
		time.Sleep(time.Millisecond)
	}
	state := coordinator.snapshot()
	if state.Phase != AdminInstallFailed || state.ErrorCode != "release-contract-unavailable" || !state.Retryable {
		t.Fatalf("state = %#v", state)
	}
}
