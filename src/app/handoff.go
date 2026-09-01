package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type installChannel string

const (
	channelStandalone    installChannel = "standalone"
	channelStore         installChannel = "store"
	handoffSchemaVersion                = 1
)

type handoffPhase string

const (
	handoffRequested     handoffPhase = "requested"
	handoffSourceRemoved handoffPhase = "source-removed"
	handoffVerified      handoffPhase = "verified"
)

type handoffJournal struct {
	SchemaVersion int            `json:"schema_version"`
	Source        installChannel `json:"source"`
	Target        installChannel `json:"target"`
	Phase         handoffPhase   `json:"phase"`
	Token         string         `json:"token"`
	UpdatedAt     string         `json:"updated_at"`
}

type handoffPlatform interface {
	CurrentChannel() (installChannel, error)
	IsInstalled(context.Context, installChannel) (bool, error)
	RemoveSource(context.Context, installChannel) error
	VerifyTargetOnly(context.Context, installChannel) error
	Activate(context.Context, installChannel) error
}

type handoffCoordinator struct{ platform handoffPlatform }

func handoffJournalPath() string { return filepath.Join(appDataDir(), "channel-handoff-v1.json") }

func (h *handoffCoordinator) Begin(source, target installChannel) (handoffJournal, error) {
	if source == target || !validChannel(source) || !validChannel(target) {
		return handoffJournal{}, fmt.Errorf("invalid handoff %q -> %q", source, target)
	}
	if existing, err := loadHandoffJournal(); err == nil {
		if existing.Source == source && existing.Target == target {
			return existing, nil
		}
		return handoffJournal{}, fmt.Errorf("another channel handoff is pending: %s -> %s", existing.Source, existing.Target)
	} else if !errors.Is(err, os.ErrNotExist) {
		return handoffJournal{}, err
	}
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		return handoffJournal{}, fmt.Errorf("handoff token: %w", err)
	}
	journal := handoffJournal{
		SchemaVersion: handoffSchemaVersion, Source: source, Target: target,
		Phase: handoffRequested, Token: hex.EncodeToString(tokenBytes),
	}
	return journal, saveHandoffJournal(journal)
}

// Resume is idempotent. Each mutation is followed by an atomic phase write;
// repeating RemoveSource or verification after a crash is required to be safe.
func (h *handoffCoordinator) Resume(ctx context.Context) error {
	journal, err := loadHandoffJournal()
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	current, err := h.platform.CurrentChannel()
	if err != nil {
		return fmt.Errorf("handoff channel: %w", err)
	}
	if current != journal.Target {
		return fmt.Errorf("handoff target is %s but current channel is %s", journal.Target, current)
	}
	if journal.Phase == handoffRequested {
		if err := h.platform.RemoveSource(ctx, journal.Source); err != nil {
			return fmt.Errorf("remove %s registration: %w", journal.Source, err)
		}
		journal.Phase = handoffSourceRemoved
		if err := saveHandoffJournal(journal); err != nil {
			return err
		}
	}
	if journal.Phase == handoffSourceRemoved {
		if err := h.platform.VerifyTargetOnly(ctx, journal.Target); err != nil {
			return fmt.Errorf("verify %s handoff: %w", journal.Target, err)
		}
		journal.Phase = handoffVerified
		if err := saveHandoffJournal(journal); err != nil {
			return err
		}
	}
	if journal.Phase != handoffVerified {
		return fmt.Errorf("unknown handoff phase %q", journal.Phase)
	}
	if err := os.Remove(handoffJournalPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("complete handoff: %w", err)
	}
	return nil
}

func validChannel(channel installChannel) bool {
	return channel == channelStandalone || channel == channelStore
}

func loadHandoffJournal() (handoffJournal, error) {
	data, err := os.ReadFile(handoffJournalPath())
	if err != nil {
		return handoffJournal{}, err
	}
	var journal handoffJournal
	if err := json.Unmarshal(data, &journal); err != nil {
		return handoffJournal{}, fmt.Errorf("parse handoff journal: %w", err)
	}
	if journal.SchemaVersion != handoffSchemaVersion || !validChannel(journal.Source) || !validChannel(journal.Target) || journal.Source == journal.Target || len(journal.Token) != 64 {
		return handoffJournal{}, errors.New("invalid handoff journal")
	}
	return journal, nil
}

func saveHandoffJournal(journal handoffJournal) error {
	journal.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	data, err := json.Marshal(journal)
	if err != nil {
		return err
	}
	dir := filepath.Dir(handoffJournalPath())
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "channel-handoff-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return moveFileAtomic(tmpPath, handoffJournalPath())
}

func pendingHandoffRequestsShutdown() bool {
	journal, err := loadHandoffJournal()
	if err != nil {
		return false
	}
	platform := newHandoffPlatform()
	current, err := platform.CurrentChannel()
	return err == nil && current == journal.Source && journal.Phase == handoffRequested
}
