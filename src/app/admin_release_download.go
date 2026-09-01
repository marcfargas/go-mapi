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
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const adminReleaseMaxRedirects = 3

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
		return true
	}
	return state.Sequence > 0 && len(state.Digest) == sha256.Size*2 && state.Digest == strings.ToLower(state.Digest) && isHex(state.Digest)
}

func isHex(value string) bool {
	_, err := hex.DecodeString(value)
	return err == nil
}

// downloadAuthorizedAdminRelease accepts only an already-authorized release.
// It bounds reads at the signed size and revalidates every redirect target
// against the same immutable origin/path rule.
func downloadAuthorizedAdminRelease(ctx context.Context, client *http.Client, root adminReleaseRoot, release authorizedAdminRelease, now time.Time) ([]byte, error) {
	if err := validateAdminReleasePayload(root, release.Payload, release.Payload.Requires.MinInclusive, now); err != nil {
		return nil, fmt.Errorf("revalidate authorized release: %w", err)
	}
	if client == nil {
		client = http.DefaultClient
	}
	copyClient := *client
	previousRedirect := copyClient.CheckRedirect
	copyClient.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if len(via) > adminReleaseMaxRedirects || !isAllowedAdminArtifactURL(root.AllowedOrigin, request.URL) {
			return errors.New("unauthorized admin artifact redirect")
		}
		if previousRedirect != nil {
			return previousRedirect(request, via)
		}
		return nil
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, release.Payload.Artifact.URL, nil)
	if err != nil {
		return nil, err
	}
	response, err := copyClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("download authorized admin artifact: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || !isAllowedAdminArtifactURL(root.AllowedOrigin, response.Request.URL) {
		return nil, errors.New("unauthorized admin artifact response")
	}
	expectedSize := release.Payload.Artifact.Size
	if response.ContentLength >= 0 && response.ContentLength != expectedSize {
		return nil, errors.New("admin artifact content length does not match metadata")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, expectedSize+1))
	if err != nil {
		return nil, fmt.Errorf("read authorized admin artifact: %w", err)
	}
	if int64(len(body)) != expectedSize {
		return nil, errors.New("admin artifact size does not match metadata")
	}
	sum := sha256.Sum256(body)
	if hex.EncodeToString(sum[:]) != release.Payload.Artifact.SHA256 {
		return nil, errors.New("admin artifact hash does not match metadata")
	}
	return body, nil
}
