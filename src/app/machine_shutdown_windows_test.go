//go:build windows

package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func useMachineAdmissionForTest(t *testing.T, app *App) {
	t.Helper()
	previous := AppDistribution
	AppDistribution = "machine"
	t.Cleanup(func() { AppDistribution = previous })
	app.machineOperations.gate = func(_ context.Context, fn func() error) error { return fn() }
}

func TestManualAndAutomaticDraftDrainThroughQueueAcknowledgement(t *testing.T) {
	app, dir := setupAppForBindingTests(t)
	useMachineAdmissionForTest(t, app)
	var open atomic.Bool
	open.Store(true)
	app.machineAdmissionOpen = func(context.Context) (bool, error) { return open.Load(), nil }
	app.machineOperations.gate = func(_ context.Context, fn func() error) error {
		if !open.Load() {
			return errMachineDraining
		}
		return fn()
	}
	ticks := make(chan time.Time)
	app.machineDrainTicks = ticks
	quit := make(chan struct{}, 1)
	app.machineQuit = func() { quit <- struct{}{} }
	if !app.startMachineDrain() {
		t.Fatal("open gate refused startup")
	}
	entered := make(chan struct{}, 2)
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		entered <- struct{}{}
		<-release
		_, _ = w.Write([]byte(`{"id":"draft"}`))
	}))
	t.Cleanup(server.Close)
	gmailBaseURLOverride = server.URL
	t.Cleanup(func() { gmailBaseURLOverride = "" })
	manualID := seedBindingEmail(t, app, dir, "manual.json", "manual")
	autoID := seedBindingEmail(t, app, dir, "automatic.json", "automatic")
	var automaticEmail = app.watcher.Snapshot()[0]
	for _, email := range app.watcher.Snapshot() {
		if email.Id == autoID {
			automaticEmail = email
		}
	}
	manualResult, autoResult := make(chan error, 1), make(chan error, 1)
	go func() { manualResult <- app.CreateDraftForID(manualID) }()
	autoEvents := make(chan map[string]any, 1)
	automatic := newAutomodeWithEmitter(app, nil, func(name string, payload any) {
		if name == "auto-draft-result" {
			autoEvents <- payload.(map[string]any)
		}
	})
	go func() { autoResult <- automatic.draftOne(automaticEmail) }()
	for i := 0; i < 2; i++ {
		select {
		case <-entered:
		case <-time.After(5 * time.Second):
			t.Fatal("Gmail calls did not enter")
		}
	}
	open.Store(false)
	ticks <- time.Now()
	waitForMachineClosure(t, app)
	drained := app.machineOperations.close()
	if err := app.DismissEmail(manualID); err == nil {
		t.Fatal("new mutation admitted during drain")
	}
	select {
	case <-drained:
		t.Fatal("drain finished before Gmail/queue acknowledgement")
	default:
	}
	close(release)
	for _, result := range []<-chan error{manualResult, autoResult} {
		select {
		case err := <-result:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("admitted draft did not finish")
		}
	}
	select {
	case event := <-autoEvents:
		if event["success"] != true {
			t.Fatalf("automatic callback before quit = %#v", event)
		}
	default:
		t.Fatal("automatic completion callback missing before drain")
	}
	<-drained
	select {
	case <-quit:
	case <-time.After(5 * time.Second):
		t.Fatal("drained callbacks did not request quit")
	}
	for _, name := range []string{"manual.json", "automatic.json"} {
		if _, err := os.Stat(filepath.Join(dir, name)); !os.IsNotExist(err) {
			t.Fatalf("%s remains after acknowledged drain: %v", name, err)
		}
	}
}

func TestManualDraftDoesNotClaimSuccessWhenQueueDeleteFails(t *testing.T) {
	app, dir := setupAppForBindingTests(t)
	useMachineAdmissionForTest(t, app)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"id":"draft"}`))
	}))
	t.Cleanup(server.Close)
	gmailBaseURLOverride = server.URL
	t.Cleanup(func() { gmailBaseURLOverride = "" })
	id := seedBindingEmail(t, app, dir, "locked.json", "locked")
	path, err := windows.UTF16PtrFromString(filepath.Join(dir, "locked.json"))
	if err != nil {
		t.Fatal(err)
	}
	handle, err := windows.CreateFile(path, windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(handle)
	if err := app.CreateDraftForID(id); err == nil {
		t.Fatal("draft claimed success despite failed queue acknowledgement")
	}
	if _, err := os.Stat(filepath.Join(dir, "locked.json")); err != nil {
		t.Fatalf("queue descriptor lost after failed acknowledgement: %v", err)
	}
}

func TestAutomaticDraftReportsQueueAcknowledgementFailure(t *testing.T) {
	app, dir := setupAppForBindingTests(t)
	useMachineAdmissionForTest(t, app)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"id":"draft"}`))
	}))
	t.Cleanup(server.Close)
	gmailBaseURLOverride = server.URL
	t.Cleanup(func() { gmailBaseURLOverride = "" })
	id := seedBindingEmail(t, app, dir, "automatic-locked.json", "locked")
	path, err := windows.UTF16PtrFromString(filepath.Join(dir, "automatic-locked.json"))
	if err != nil {
		t.Fatal(err)
	}
	handle, err := windows.CreateFile(path, windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(handle)
	var events []map[string]any
	automatic := newAutomodeWithEmitter(app, nil, func(name string, payload any) {
		if name == "auto-draft-result" {
			events = append(events, payload.(map[string]any))
		}
	})
	var emailFound bool
	for _, email := range app.watcher.Snapshot() {
		if email.Id != id {
			continue
		}
		emailFound = true
		if err := automatic.draftOne(email); err == nil {
			t.Fatal("automatic draft claimed acknowledged success")
		}
	}
	if !emailFound {
		t.Fatal("queued email missing before automatic draft")
	}
	if len(events) != 1 || events[0]["success"] != false || events[0]["errorCategory"] != "queue" {
		t.Fatalf("automatic failure callback = %#v", events)
	}
	if _, err := os.Stat(filepath.Join(dir, "automatic-locked.json")); err != nil {
		t.Fatalf("failed acknowledgement lost descriptor: %v", err)
	}
}
