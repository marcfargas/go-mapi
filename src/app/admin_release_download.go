package main

// This file is deliberately limited to verification and staging. It neither
// invokes msiexec nor requests elevation: callers get verified bytes and must
// make a separate, explicit install decision.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

// adminReleaseReplayStore persists only the highest accepted sequence and the
// digest that bound it. Accept takes an advisory, process-wide file lock before
// reading and replacement-atomically writing, so independent app processes
// cannot each accept a different candidate from the same prior state.
type adminReleaseReplayStore struct{ Path string }

func (s adminReleaseReplayStore) Load() (adminReleaseReplayState, error) {
	if s.Path == "" {
		return adminReleaseReplayState{}, errors.New("admin release replay state path is empty")
	}
	data, err := os.ReadFile(s.Path)
	if errors.Is(err, os.ErrNotExist) {
		return adminReleaseReplayState{}, nil
	}
	if err != nil {
		return adminReleaseReplayState{}, fmt.Errorf("read admin release replay state: %w", err)
	}
	var state adminReleaseReplayState
	if err := decodeAdminReleaseJSON(data, &state); err != nil || !validAdminReleaseReplayState(state) {
		return adminReleaseReplayState{}, errors.New("invalid admin release replay state")
	}
	return state, nil
}

func (s adminReleaseReplayStore) Accept(candidate authorizedAdminRelease) error {
	if err := os.MkdirAll(filepath.Dir(s.Path), 0700); err != nil {
		return fmt.Errorf("create admin release replay state directory: %w", err)
	}
	return withAdminReleaseReplayLock(s.Path+".lock", func() error {
		previous, err := s.Load()
		if err != nil {
			return err
		}
		next, err := acceptAdminReleaseSequence(previous, candidate)
		if err != nil {
			return err
		}
		data, err := json.Marshal(next)
		if err != nil {
			return fmt.Errorf("encode admin release replay state: %w", err)
		}
		temporary, err := os.CreateTemp(filepath.Dir(s.Path), ".admin-release-replay-*")
		if err != nil {
			return fmt.Errorf("create admin release replay state: %w", err)
		}
		temporaryName := temporary.Name()
		defer os.Remove(temporaryName)
		if _, err := temporary.Write(data); err != nil {
			temporary.Close()
			return fmt.Errorf("write admin release replay state: %w", err)
		}
		if err := temporary.Chmod(0600); err != nil {
			temporary.Close()
			return fmt.Errorf("protect admin release replay state: %w", err)
		}
		if err := temporary.Close(); err != nil {
			return fmt.Errorf("close admin release replay state: %w", err)
		}
		if err := os.Rename(temporaryName, s.Path); err != nil {
			return fmt.Errorf("commit admin release replay state: %w", err)
		}
		return nil
	})
}

func validAdminReleaseReplayState(state adminReleaseReplayState) bool {
	if state.Sequence == 0 && state.Digest == "" {
		return state.Namespace == ""
	}
	return (state.Namespace == "" || state.Namespace == string(update.LegacyAdmin)) && state.Sequence > 0 && len(state.Digest) == sha256.Size*2 && state.Digest == strings.ToLower(state.Digest) && isHex(state.Digest)
}

func isHex(value string) bool {
	_, err := hex.DecodeString(value)
	return err == nil
}

// downloadAuthorizedAdminRelease accepts only an already-authorized release.
// It bounds reads at the signed size and revalidates every redirect target
// against the same immutable origin/path rule.
func downloadAuthorizedAdminRelease(ctx context.Context, client *http.Client, root adminReleaseRoot, release authorizedAdminRelease, now time.Time) ([]byte, error) {
	policy, err := update.NewLegacyAdminPolicy(root)
	if err != nil {
		return nil, err
	}
	return policy.Download(ctx, client, release.trusted, now)
}
