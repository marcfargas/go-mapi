package main

import (
	"bytes"
	"testing"
	"time"
)

func TestComputeTrayVisual(t *testing.T) {
	tests := []struct {
		name     string
		state    trayState
		wantIcon []byte
		wantTip  string
	}{
		{"error overrides everything",
			trayState{Mode: "auto-draft", Paused: true, SignedIn: true, ErrorMsg: "watcher stopped", Count: 3},
			trayErrorIcon, "go-mapi — watcher stopped"},
		{"has-queue when signed in + count > 0, auto-draft mode",
			trayState{Mode: "auto-draft", SignedIn: true, Count: 3},
			trayHasQueueIcon, "go-mapi — Auto-draft — 3 pending"},
		{"has-queue when signed in + count > 0, manual mode",
			trayState{Mode: "manual", SignedIn: true, Count: 1},
			trayHasQueueIcon, "go-mapi — Manual — 1 pending"},
		{"idle when signed in + count 0",
			trayState{Mode: "manual", SignedIn: true, Count: 0},
			trayIdleIcon, "go-mapi — Manual — 0 pending"},
		{"idle when signed out regardless of count (signed-out segment)",
			trayState{Mode: "manual", SignedIn: false, Count: 2},
			trayIdleIcon, "go-mapi — Signed out — 2 pending"},
		{"idle when paused (even with queue)",
			trayState{Mode: "auto-draft", Paused: true, SignedIn: true, Count: 2},
			trayIdleIcon, "go-mapi — Paused — 2 pending"},
		{"paused segment wins over mode segment",
			trayState{Mode: "auto-draft", Paused: true, SignedIn: true, Count: 0},
			trayIdleIcon, "go-mapi — Paused — 0 pending"},
		{"signed-out segment wins over mode segment",
			trayState{Mode: "auto-draft", Paused: false, SignedIn: false, Count: 0},
			trayIdleIcon, "go-mapi — Signed out — 0 pending"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotIcon, gotTip := computeTrayVisual(tt.state)
			if !bytes.Equal(gotIcon, tt.wantIcon) {
				t.Errorf("icon mismatch for state %+v", tt.state)
			}
			if gotTip != tt.wantTip {
				t.Errorf("tooltip: got %q, want %q", gotTip, tt.wantTip)
			}
		})
	}
}

// TestSignalTrayRefresh_Coalesces verifies that 100 rapid signals to a 1-slot
// channel coalesce to exactly 1 wake (drop-if-full semantic per T-9-11).
func TestSignalTrayRefresh_Coalesces(t *testing.T) {
	app := &App{trayRefreshCh: make(chan struct{}, 1)}
	for i := 0; i < 100; i++ {
		app.signalTrayRefresh()
	}
	// Drain — expect exactly 1.
	count := 0
	timeout := time.After(50 * time.Millisecond)
drain:
	for {
		select {
		case <-app.trayRefreshCh:
			count++
		case <-timeout:
			break drain
		}
	}
	if count != 1 {
		t.Errorf("1-slot channel should buffer exactly 1 signal for a 100-burst, got %d", count)
	}
}

// TestSetLastError_SignalsRefreshOnlyOnChange verifies idempotent error signalling:
// setting the same message twice only signals once; a distinct message re-signals.
func TestSetLastError_SignalsRefreshOnlyOnChange(t *testing.T) {
	app := &App{trayRefreshCh: make(chan struct{}, 1)}
	app.setLastError("watcher stopped")
	// Drain the initial signal.
	select {
	case <-app.trayRefreshCh:
		// expected
	case <-time.After(50 * time.Millisecond):
		t.Fatal("setLastError should have signalled on first call")
	}
	// Same error again — should NOT re-signal.
	app.setLastError("watcher stopped")
	select {
	case <-app.trayRefreshCh:
		t.Error("setLastError should not signal on unchanged value")
	case <-time.After(50 * time.Millisecond):
		// ok
	}
	// Distinct error — must re-signal.
	app.setLastError("different error")
	select {
	case <-app.trayRefreshCh:
		// ok
	case <-time.After(50 * time.Millisecond):
		t.Error("setLastError should signal on changed value")
	}
}
