package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

type adminReleaseRoundTripper func(*http.Request) (*http.Response, error)

func (f adminReleaseRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func TestAdminReleaseReplayStorePersistsAndRejectsReplay(t *testing.T) {
	store := adminReleaseReplayStore{Path: filepath.Join(t.TempDir(), "state", "highest.json")}
	first := authorizedAdminRelease{Payload: adminReleasePayload{Sequence: 7}, Digest: strings.Repeat("a", 64)}
	if err := store.Accept(first); err != nil {
		t.Fatal(err)
	}
	state, err := store.Load()
	if err != nil || state != (adminReleaseReplayState{Sequence: 7, Digest: first.Digest}) {
		t.Fatalf("persisted replay state = %#v, %v", state, err)
	}
	if err := store.Accept(authorizedAdminRelease{Payload: adminReleasePayload{Sequence: 6}, Digest: strings.Repeat("b", 64)}); err == nil {
		t.Fatal("accepted stale sequence")
	}
	if err := store.Accept(authorizedAdminRelease{Payload: adminReleasePayload{Sequence: 7}, Digest: strings.Repeat("b", 64)}); err == nil {
		t.Fatal("accepted changed payload at the same sequence")
	}
	if err := store.Accept(first); err != nil {
		t.Fatalf("idempotent replay failed: %v", err)
	}
	// Windows ACLs, not POSIX mode bits, enforce the per-user replay-state
	// boundary. Do not interpret its synthetic 0666 mode as a failed ACL.
	if runtime.GOOS != "windows" {
		info, err := os.Stat(store.Path)
		if err != nil || info.Mode().Perm()&0077 != 0 {
			t.Fatalf("state permissions = %v, %v", info.Mode(), err)
		}
	}
}

func TestAdminReleaseReplayStoreRejectsCorruptState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "highest.json")
	if err := os.WriteFile(path, []byte(`{"sequence":9,"digest":"not-a-digest"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := (adminReleaseReplayStore{Path: path}).Load(); err == nil {
		t.Fatal("accepted corrupt replay state")
	}
}

func TestAdminReleaseReplayStoreSerializesConcurrentAccepts(t *testing.T) {
	store := adminReleaseReplayStore{Path: filepath.Join(t.TempDir(), "state", "highest.json")}
	candidates := []authorizedAdminRelease{
		{Payload: adminReleasePayload{Sequence: 7}, Digest: strings.Repeat("a", 64)},
		{Payload: adminReleasePayload{Sequence: 8}, Digest: strings.Repeat("b", 64)},
	}
	var wg sync.WaitGroup
	for i := 0; i < 40; i++ {
		candidate := candidates[i%len(candidates)]
		wg.Add(1)
		go func() {
			defer wg.Done()
			// A stale contender may correctly lose the race. The important
			// property is that it never overwrites the newer durable state.
			_ = store.Accept(candidate)
		}()
	}
	wg.Wait()
	state, err := store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if state.Sequence != 8 || state.Digest != candidates[1].Digest {
		t.Fatalf("concurrent state = %#v, want highest accepted release", state)
	}
}

func TestAdminArtifactURLRejectsPathPrefixTraversalAndQuery(t *testing.T) {
	for _, raw := range []string{
		"https://example.test/releases-evil/interceptor.msi",
		"https://example.test/releases/../outside/interceptor.msi",
		"https://example.test/releases/interceptor.msi?redirect=https://attacker.test",
		"https://example.test/releases/interceptor.msi#fragment",
		"https://example.test/releases/latest/interceptor.msi",
	} {
		u, _ := http.NewRequest(http.MethodGet, raw, nil)
		if isAllowedAdminArtifactURL("https://example.test/releases/", u.URL) {
			t.Fatalf("accepted unauthorized artifact URL %q", raw)
		}
	}
	u, _ := http.NewRequest(http.MethodGet, "https://EXAMPLE.test/releases/admin-v4/interceptor.msi", nil)
	if !isAllowedAdminArtifactURL("https://example.test/releases/", u.URL) {
		t.Fatal("rejected valid artifact URL")
	}
}

func TestDownloadAuthorizedAdminReleaseChecksSizeAndHash(t *testing.T) {
	body := []byte("signed installer bytes")
	digest := sha256.Sum256(body)
	client := &http.Client{Transport: adminReleaseRoundTripper(func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case "/releases/admin-v4.0.1/go-mapi-interceptor.msi":
			return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), ContentLength: int64(len(body)), Body: io.NopCloser(strings.NewReader(string(body))), Request: request}, nil
		default:
			return &http.Response{StatusCode: http.StatusNotFound, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("")), Request: request}, nil
		}
	})}

	rootPub, _ := adminTestKey(t)
	targetPub, _ := adminTestKey(t)
	root := adminTestRoot(t, 1, rootPub, targetPub)
	root.AllowedOrigin = "https://example.test/releases/"
	release := authorizedAdminRelease{Payload: adminTestPayload()}
	release.Payload.Artifact.URL = "https://example.test/releases/admin-v4.0.1/go-mapi-interceptor.msi"
	release.Payload.Artifact.Size = int64(len(body))
	release.Payload.Artifact.SHA256 = hex.EncodeToString(digest[:])
	release.Payload.IssuedAt = "2026-08-31T10:00:00Z"
	release.Payload.ExpiresAt = "2026-09-01T10:00:00Z"
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	got, err := downloadAuthorizedAdminRelease(context.Background(), client, root, release, now)
	if err != nil || string(got) != string(body) {
		t.Fatalf("download = %q, %v", got, err)
	}

	release.Payload.Artifact.SHA256 = strings.Repeat("0", 64)
	if _, err := downloadAuthorizedAdminRelease(context.Background(), client, root, release, now); err == nil {
		t.Fatal("accepted hash mismatch")
	}
	release.Payload.Artifact.SHA256 = hex.EncodeToString(digest[:])
	release.Payload.Artifact.Size++
	if _, err := downloadAuthorizedAdminRelease(context.Background(), client, root, release, now); err == nil {
		t.Fatal("accepted size mismatch")
	}
}
