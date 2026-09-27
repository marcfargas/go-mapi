package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"testing"
	"time"
)

func machineDistributionForTest(t *testing.T, distribution string) {
	t.Helper()
	previous := AppDistribution
	AppDistribution = distribution
	t.Cleanup(func() { AppDistribution = previous })
}

func waitForMachineClosure(t *testing.T, app *App) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for !app.machineOperations.isClosing() {
		if time.Now().After(deadline) {
			t.Fatal("machine monitor did not close local admission")
		}
		runtime.Gosched()
	}
}

func TestMachineStartupDrainOrdersGateMutationAndQuit(t *testing.T) {
	machineDistributionForTest(t, "machine")
	t.Setenv("GOMAPI_APPDATA_DIR", t.TempDir())
	app := NewApp()
	app.shutdownCtx, app.shutdownCancel = context.WithCancel(context.Background())
	t.Cleanup(app.shutdownCancel)
	var open atomic.Bool
	open.Store(true)
	app.machineAdmissionOpen = func(context.Context) (bool, error) { return open.Load(), nil }
	app.machineOperations.gate = func(_ context.Context, fn func() error) error {
		if !open.Load() {
			return errors.New("closed gate")
		}
		return fn()
	}
	ticks := make(chan time.Time)
	app.machineDrainTicks = ticks
	quit := make(chan struct{}, 1)
	app.machineQuit = func() { quit <- struct{}{} }
	if !app.startMachineDrain() {
		t.Fatal("open gate refused machine startup")
	}
	settings := app.GetSettings()
	settings.Mode = "auto-draft"
	if err := app.SaveSettings(settings); err != nil {
		t.Fatalf("open gate denied settings save: %v", err)
	}
	before, err := os.ReadFile(filepath.Join(appDataDir(), "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	finish, err := app.beginMachineOperation(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	open.Store(false)
	ticks <- time.Now()
	waitForMachineClosure(t, app)
	settings.Mode = "manual"
	if err := app.SaveSettings(settings); !errors.Is(err, errMachineDraining) {
		t.Fatalf("closed gate allowed settings persistence: %v", err)
	}
	after, err := os.ReadFile(filepath.Join(appDataDir(), "settings.json"))
	if err != nil || string(after) != string(before) {
		t.Fatalf("refused mutation changed saved settings: %v", err)
	}
	select {
	case <-quit:
		t.Fatal("quit requested before admitted operation completed")
	default:
	}
	finish()
	select {
	case <-quit:
	case <-time.After(time.Second):
		t.Fatal("drained machine did not request quit")
	}
}

func TestMachineStartupRefusalAndDistributionBypass(t *testing.T) {
	for _, status := range []struct {
		name string
		open bool
		err  error
	}{
		{"closed", false, nil},
		{"unavailable", false, errors.New("read failure")},
	} {
		t.Run(status.name, func(t *testing.T) {
			machineDistributionForTest(t, "machine")
			app := NewApp()
			app.machineAdmissionOpen = func(context.Context) (bool, error) { return status.open, status.err }
			if app.startMachineDrain() {
				t.Fatal("machine startup accepted closed/unavailable admission")
			}
			if _, err := app.beginMachineOperation(context.Background()); !errors.Is(err, errMachineDraining) {
				t.Fatalf("startup refusal admitted callback: %v", err)
			}
		})
	}
	for _, distribution := range []string{"", "store"} {
		t.Run("bypass-"+distribution, func(t *testing.T) {
			machineDistributionForTest(t, distribution)
			app := NewApp()
			app.machineAdmissionOpen = func(context.Context) (bool, error) { t.Fatal("non-machine read admission"); return false, nil }
			app.machineOperations.gate = func(context.Context, func() error) error { t.Fatal("non-machine entered gate"); return nil }
			if !app.startMachineDrain() {
				t.Fatal("non-machine startup refused")
			}
			finish, err := app.beginMachineOperation(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			finish()
		})
	}
}

func TestLateStartupGateClosureWaitsForBootstrapWork(t *testing.T) {
	machineDistributionForTest(t, "machine")
	app := NewApp()
	app.shutdownCtx, app.shutdownCancel = context.WithCancel(context.Background())
	t.Cleanup(app.shutdownCancel)
	var open atomic.Bool
	open.Store(true)
	app.machineAdmissionOpen = func(context.Context) (bool, error) { return open.Load(), nil }
	app.machineDrainTicks = make(chan time.Time)
	app.machineOperations.gate = func(_ context.Context, fn func() error) error { return fn() }
	quit := make(chan struct{}, 2)
	app.machineQuit = func() { quit <- struct{}{} }
	if !app.startMachineDrain() || !app.machineStartupCanProceed() {
		t.Fatal("open gate stopped startup before queue initialization")
	}
	finish, err := app.beginMachineOperation(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	open.Store(false)
	if app.machineStartupCanProceed() {
		t.Fatal("closed gate allowed automatic work initialization")
	}
	if _, err := app.beginMachineOperation(context.Background()); !errors.Is(err, errMachineDraining) {
		t.Fatalf("late startup closure admitted operation: %v", err)
	}
	select {
	case <-quit:
		t.Fatal("quit cancelled admitted bootstrap work")
	default:
	}
	finish()
	select {
	case <-quit:
	case <-time.After(time.Second):
		t.Fatal("late closure did not request quit after drain")
	}
	if app.machineStartupCanProceed() {
		t.Fatal("closed startup gate reopened locally")
	}
	select {
	case <-quit:
		t.Fatal("repeated closure requested quit twice")
	default:
	}
}

func TestBootstrapUserInfoKeepsMachineDrainPending(t *testing.T) {
	machineDistributionForTest(t, "machine")
	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		entered <- struct{}{}
		<-release
		_, _ = w.Write([]byte(`{"email":"drain@example.com","name":"Drain"}`))
	}))
	t.Cleanup(server.Close)
	userinfoEndpointOverride = server.URL
	t.Cleanup(func() { userinfoEndpointOverride = "" })
	store := newFakeKeyringStore()
	seed := NewAuthManagerWithStore(store)
	seed.tokens = &OAuthTokens{AccessToken: "a", RefreshToken: "r", TokenType: "Bearer", Expiry: time.Now().Add(time.Hour)}
	if err := seed.SaveToKeyring(); err != nil {
		t.Fatal(err)
	}
	app := NewApp()
	app.auth = NewAuthManagerWithStore(store)
	app.machineOperations.gate = func(_ context.Context, fn func() error) error { return fn() }
	done := app.bootstrapAuth()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("userinfo callback did not start")
	}
	drained := app.machineOperations.close()
	select {
	case <-drained:
		t.Fatal("bootstrap released count before userinfo settled")
	default:
	}
	if err := app.SignOut(); !errors.Is(err, errMachineDraining) {
		t.Fatalf("closed gate admitted sign-out: %v", err)
	}
	if app.auth.tokens == nil {
		t.Fatal("refused sign-out cleared credentials")
	}
	close(release)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("userinfo callback did not finish")
	}
	select {
	case <-drained:
	case <-time.After(time.Second):
		t.Fatal("bootstrap did not release drain after callback")
	}
	if app.auth.email != "drain@example.com" {
		t.Fatalf("callback did not publish identity: %q", app.auth.email)
	}
}

func TestBootstrapSynchronousExitReleasesMachineOperation(t *testing.T) {
	machineDistributionForTest(t, "machine")
	for _, auth := range []*AuthManager{nil, NewAuthManagerWithStore(newFakeKeyringStore())} {
		app := NewApp()
		app.auth = auth
		app.machineOperations.gate = func(_ context.Context, fn func() error) error { return fn() }
		select {
		case <-app.bootstrapAuth():
		default:
			t.Fatal("synchronous bootstrap did not complete")
		}
		select {
		case <-app.machineOperations.close():
		default:
			t.Fatal("synchronous bootstrap retained an operation")
		}
	}
}

func TestMachineOperationDrainWaitsForBothAdmittedCalls(t *testing.T) {
	operations := &machineOperations{gate: func(_ context.Context, fn func() error) error { return fn() }}
	finishManual, err := operations.begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	finishAutomatic, err := operations.begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	drained := operations.close()
	if _, err := operations.begin(context.Background()); !errors.Is(err, errMachineDraining) {
		t.Fatalf("new operation after closure: %v", err)
	}
	finishManual()
	select {
	case <-drained:
		t.Fatal("drain completed before automatic acknowledgement")
	default:
	}
	finishAutomatic()
	select {
	case <-drained:
	case <-time.After(time.Second):
		t.Fatal("drain did not finish")
	}
	if operations.close() != drained {
		t.Fatal("repeated closure replaced the drain")
	}
}
