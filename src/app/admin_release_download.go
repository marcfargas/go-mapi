package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

// adminReleaseSequenceStore protects the highest accepted plain metadata
// sequence across elevated repair attempts.
type adminReleaseSequenceStore struct{ Path string }

func (s adminReleaseSequenceStore) Load() (update.ReplayState, error) {
	if s.Path == "" {
		return update.ReplayState{}, errors.New("admin release sequence path is empty")
	}
	data, err := os.ReadFile(s.Path)
	if errors.Is(err, os.ErrNotExist) {
		return update.ReplayState{}, nil
	}
	if err != nil {
		return update.ReplayState{}, fmt.Errorf("read admin release sequence: %w", err)
	}
	var state update.ReplayState
	if err := update.DecodeJSON(data, &state); err != nil || !validAdminReleaseSequence(state) {
		return update.ReplayState{}, errors.New("invalid admin release sequence")
	}
	return state, nil
}

func (s adminReleaseSequenceStore) Accept(release update.Release) error {
	if err := os.MkdirAll(filepath.Dir(s.Path), 0700); err != nil {
		return fmt.Errorf("create admin release sequence directory: %w", err)
	}
	return withAdminReleaseSequenceLock(s.Path+".lock", func() error {
		previous, err := s.Load()
		if err != nil {
			return err
		}
		next, err := update.AcceptReplay(previous, release)
		if err != nil {
			return err
		}
		data, err := json.Marshal(next)
		if err != nil {
			return err
		}
		temporary, err := os.CreateTemp(filepath.Dir(s.Path), ".admin-release-sequence-*")
		if err != nil {
			return err
		}
		temporaryName := temporary.Name()
		defer os.Remove(temporaryName)
		if _, err := temporary.Write(data); err != nil {
			temporary.Close()
			return err
		}
		if err := temporary.Chmod(0600); err != nil {
			temporary.Close()
			return err
		}
		if err := temporary.Close(); err != nil {
			return err
		}
		return os.Rename(temporaryName, s.Path)
	})
}

func validAdminReleaseSequence(state update.ReplayState) bool {
	if state.Sequence == 0 && state.Digest == "" {
		return state.Namespace == ""
	}
	return (state.Namespace == "" || state.Namespace == string(update.LegacyAdmin)) && state.Sequence > 0 && len(state.Digest) == sha256.Size*2 && state.Digest == strings.ToLower(state.Digest) && isHex(state.Digest)
}

func isHex(value string) bool {
	_, err := hex.DecodeString(value)
	return err == nil
}
