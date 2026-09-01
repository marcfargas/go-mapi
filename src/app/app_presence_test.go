package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestAppPresenceStartRefreshesAndCleansUp(t *testing.T) {
	root := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	presence := newAppPresence(root)
	presence.interval = time.Millisecond
	if err := presence.start(ctx); err != nil {
		t.Fatalf("start: %v", err)
	}

	path := filepath.Join(root, appPresenceFileName)
	if got, err := os.ReadFile(path); err != nil || string(got) != appPresenceToken {
		t.Fatalf("marker = %q, %v; want fixed token", got, err)
	}

	// The production implementation is atomic; use an injected refresh to make
	// the heartbeat observable without asserting filesystem timestamp precision.
	var mu sync.Mutex
	refreshes := 0
	presence2 := newAppPresence(t.TempDir())
	presence2.interval = time.Millisecond
	presence2.refresh = func(string) error {
		mu.Lock()
		refreshes++
		mu.Unlock()
		return nil
	}
	presence2.remove = func(string) error { return nil }
	ctx2, cancel2 := context.WithCancel(context.Background())
	defer cancel2()
	if err := presence2.start(ctx2); err != nil {
		t.Fatalf("start injected presence: %v", err)
	}
	time.Sleep(5 * time.Millisecond)
	mu.Lock()
	gotRefreshes := refreshes
	mu.Unlock()
	if gotRefreshes < 2 {
		t.Fatalf("refresh calls = %d, want initial write plus heartbeat", gotRefreshes)
	}

	cancel()
	deadline := time.Now().Add(time.Second)
	for {
		if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("marker %s was not removed after cancellation", path)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestWriteAppPresenceAtomicallyReplacesOnlyCompleteToken(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", appPresenceFileName)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeAppPresenceAtomically(path); err != nil {
		t.Fatalf("write: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != appPresenceToken {
		t.Errorf("marker = %q, want %q", got, appPresenceToken)
	}
	matches, err := filepath.Glob(filepath.Join(filepath.Dir(path), ".app-presence-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 0 {
		t.Errorf("atomic write leaked temporary markers: %v", matches)
	}
}

func TestRemoveAppPresenceIsIdempotent(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, appPresenceFileName)
	if err := clearAppPresence(root); err != nil {
		t.Fatalf("remove absent marker: %v", err)
	}
	if err := writeAppPresenceAtomically(path); err != nil {
		t.Fatal(err)
	}
	if err := clearAppPresence(root); err != nil {
		t.Fatalf("remove marker: %v", err)
	}
}
