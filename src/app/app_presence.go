package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// appPresenceFileName is deliberately versioned: the interceptor may use this
// file without linking to the Wails app, so a future incompatible format gets a
// new filename rather than changing the meaning of an existing marker.
const appPresenceFileName = "app-presence-v1"

// appPresenceToken is intentionally fixed and contains no user or machine
// data. The marker answers only whether the per-user app is alive.
const appPresenceToken = "go-mapi-app-presence-v1\n"

// These are part of the app/interceptor presence contract. The interceptor
// treats a marker older than appPresenceStaleAfter as absent.
const (
	appPresenceHeartbeatInterval = time.Minute
	appPresenceStaleAfter        = 5 * time.Minute
)

// appPresence owns the per-user marker written by the Wails app. Function
// fields keep lifecycle behaviour testable without requiring a real app-data
// directory or waiting for the production heartbeat interval.
type appPresence struct {
	path     string
	interval time.Duration
	refresh  func(string) error
	remove   func(string) error
}

func newAppPresence(root string) *appPresence {
	return &appPresence{
		path:     filepath.Join(root, appPresenceFileName),
		interval: appPresenceHeartbeatInterval,
		refresh:  writeAppPresenceAtomically,
		remove:   removeAppPresence,
	}
}

func clearAppPresence(root string) error {
	return removeAppPresence(filepath.Join(root, appPresenceFileName))
}

// start creates the marker before returning, then refreshes it until ctx is
// cancelled. Its deferred cleanup makes normal Wails shutdown and session-end
// cancellation remove the marker promptly rather than waiting for staleness.
func (p *appPresence) start(ctx context.Context) error {
	if err := p.refresh(p.path); err != nil {
		return err
	}

	go func() {
		ticker := time.NewTicker(p.interval)
		defer ticker.Stop()
		defer func() {
			if err := p.remove(p.path); err != nil {
				logError("app presence cleanup: %v", err)
			}
		}()

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if err := p.refresh(p.path); err != nil {
					// Keep the last successful marker in place. Its mtime will
					// naturally cross the stale threshold if the failure persists.
					logError("app presence refresh: %v", err)
				}
			}
		}
	}()
	return nil
}

// writeAppPresenceAtomically writes the fixed marker through a sibling temp
// file and rename, so the interceptor never observes a partial token.
func writeAppPresenceAtomically(path string) (err error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create app presence directory: %w", err)
	}

	tmp, err := os.CreateTemp(dir, ".app-presence-*")
	if err != nil {
		return fmt.Errorf("create app presence marker: %w", err)
	}
	tmpName := tmp.Name()
	defer func() {
		if err != nil {
			_ = os.Remove(tmpName)
		}
	}()

	if err = tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("set app presence marker permissions: %w", err)
	}
	if _, err = tmp.WriteString(appPresenceToken); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write app presence marker: %w", err)
	}
	if err = tmp.Sync(); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("sync app presence marker: %w", err)
	}
	if err = tmp.Close(); err != nil {
		return fmt.Errorf("close app presence marker: %w", err)
	}
	if err = moveFileAtomic(tmpName, path); err != nil {
		return fmt.Errorf("replace app presence marker: %w", err)
	}
	return nil
}

func removeAppPresence(path string) error {
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove app presence marker: %w", err)
	}
	return nil
}
