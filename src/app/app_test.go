package main

import (
	"sync"
	"testing"
)

// TestNewAppInitializesAuth asserts NewApp() constructs an App with a
// non-nil auth manager and that GetQueue returns nil before the watcher
// is bound in startup().
func TestNewAppInitializesAuth(t *testing.T) {
	t.Parallel()
	app := NewApp()
	if app == nil {
		t.Fatal("NewApp returned nil")
	}
	if app.auth == nil {
		t.Fatal("app.auth should be initialized")
	}
	// GetQueue short-circuits on nil watcher (app.go line ~173).
	if q := app.GetQueue(); q != nil {
		t.Fatalf("GetQueue with no watcher should be nil, got %v", q)
	}
}

// TestVisibilityRoundTrip confirms setVisible/isVisible round-trip.
// The App constructor does not set an initial visibility (the zero value of
// bool is false), so we set then read explicitly rather than asserting the
// initial state.
func TestVisibilityRoundTrip(t *testing.T) {
	t.Parallel()
	app := NewApp()
	app.setVisible(true)
	if !app.isVisible() {
		t.Fatal("expected visible after setVisible(true)")
	}
	app.setVisible(false)
	if app.isVisible() {
		t.Fatal("expected hidden after setVisible(false)")
	}
}

// TestVisibilityConcurrent exercises setVisible/isVisible from many
// goroutines concurrently. Under `go test -race` this catches any
// data-race regression in the visibilityMu + visible pair.
func TestVisibilityConcurrent(t *testing.T) {
	t.Parallel()
	app := NewApp()
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); app.setVisible(true) }()
		go func() { defer wg.Done(); _ = app.isVisible() }()
	}
	wg.Wait()
	// The test passes if -race did not fire.
}
