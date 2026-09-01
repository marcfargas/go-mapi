package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAppComponentStateLifecycle(t *testing.T) {
	root := t.TempDir()
	state := newAppComponentState(root, "4.2.0")
	state.interval = time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	if err := state.start(ctx); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, appComponentStateFileName)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var record appComponentStateRecord
	if err := json.Unmarshal(data, &record); err != nil {
		t.Fatal(err)
	}
	if record.Schema != appComponentStateSchema || record.Version != "4.2.0" || record.QueueProtocol != componentQueueProtocol || record.RefreshedAt.IsZero() {
		t.Fatalf("record = %#v", record)
	}
	for _, secret := range []string{"oauth", "recipient", "attachment", "machine", "install"} {
		if strings.Contains(strings.ToLower(string(data)), secret) {
			t.Errorf("state leaks forbidden field %q", secret)
		}
	}
	cancel()
	deadline := time.Now().Add(time.Second)
	for {
		_, err := os.Stat(path)
		if errors.Is(err, os.ErrNotExist) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("state was not removed")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestAppComponentStateRejectsInvalidVersion(t *testing.T) {
	err := writeAppComponentStateAtomically(filepath.Join(t.TempDir(), appComponentStateFileName), appComponentStateRecord{Schema: appComponentStateSchema, Version: "v4", QueueProtocol: componentQueueProtocol, RefreshedAt: time.Now()})
	if err == nil {
		t.Fatal("expected invalid version error")
	}
}
