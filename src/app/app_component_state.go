package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const (
	appComponentStateFileName = "app-component-state-v1.json"
	appComponentStateSchema   = "go-mapi-app-component-state-v1"
	componentQueueProtocol    = "queue-v1"
)

type appComponentStateRecord struct {
	Schema        string    `json:"schema"`
	Version       string    `json:"version"`
	QueueProtocol string    `json:"queueProtocol"`
	RefreshedAt   time.Time `json:"refreshedAt"`
}

type appComponentState struct {
	path     string
	version  string
	interval time.Duration
	now      func() time.Time
	write    func(string, appComponentStateRecord) error
	remove   func(string) error
}

func newAppComponentState(root, version string) *appComponentState {
	return &appComponentState{
		path: filepath.Join(root, appComponentStateFileName), version: version,
		interval: appPresenceHeartbeatInterval, now: time.Now,
		write: writeAppComponentStateAtomically, remove: removeAppComponentState,
	}
}

func clearAppComponentState(root string) error {
	return removeAppComponentState(filepath.Join(root, appComponentStateFileName))
}

func (s *appComponentState) record() appComponentStateRecord {
	return appComponentStateRecord{
		Schema: appComponentStateSchema, Version: s.version,
		QueueProtocol: componentQueueProtocol, RefreshedAt: s.now().UTC(),
	}
}

func (s *appComponentState) start(ctx context.Context) error {
	if err := s.write(s.path, s.record()); err != nil {
		return err
	}
	go func() {
		ticker := time.NewTicker(s.interval)
		defer ticker.Stop()
		defer func() {
			if err := s.remove(s.path); err != nil {
				logError("app component state cleanup: %v", err)
			}
		}()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if err := s.write(s.path, s.record()); err != nil {
					logError("app component state refresh: %v", err)
				}
			}
		}
	}()
	return nil
}

func writeAppComponentStateAtomically(path string, record appComponentStateRecord) (err error) {
	if !mapiVersionIsRuntimeValid(record.Version) {
		return fmt.Errorf("invalid app component version %q", record.Version)
	}
	data, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("encode app component state: %w", err)
	}
	dir := filepath.Dir(path)
	if err = os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create app component state directory: %w", err)
	}
	tmp, err := os.CreateTemp(dir, ".app-component-state-*")
	if err != nil {
		return fmt.Errorf("create app component state: %w", err)
	}
	tmpName := tmp.Name()
	defer func() {
		if err != nil {
			_ = os.Remove(tmpName)
		}
	}()
	if err = tmp.Chmod(0o600); err == nil {
		_, err = tmp.Write(data)
	}
	if err == nil {
		err = tmp.Sync()
	}
	closeErr := tmp.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return fmt.Errorf("write app component state: %w", err)
	}
	if err = moveFileAtomic(tmpName, path); err != nil {
		return fmt.Errorf("replace app component state: %w", err)
	}
	return nil
}

func removeAppComponentState(path string) error {
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove app component state: %w", err)
	}
	return nil
}
