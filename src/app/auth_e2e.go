//go:build e2e

package main

// E2E build-tag shim for the Playwright harness (Phase 11 plan 06).
//
// This file compiles ONLY under `-tags e2e`. The shipped installer never
// includes it (mitigates T-11-06-01: e2e flag must NOT reach production).
//
// The shim runs in init() — earlier than NewAuthManager() so the keyring
// factory swap is in place before AuthManager is constructed. It reads four
// optional env vars set by the Playwright fixture in tests/e2e/:
//
//   GOMAPI_E2E_FAKE_TOKEN_JSON  Whole OAuthTokens JSON blob to pre-populate
//                               the in-memory keyring with. When non-empty,
//                               the AuthManager boots already-authenticated
//                               with no need to drive the browser flow.
//   GOMAPI_E2E_GMAIL_BASE_URL   Override for the Gmail API base (httptest /
//                               fake-gmail.ts). Wires gmailBaseURLOverride.
//   GOMAPI_E2E_TOKEN_ENDPOINT   Override for the OAuth token endpoint.
//   GOMAPI_E2E_REVOKE_ENDPOINT  Override for the OAuth revoke endpoint.
//
// All four are optional individually so tests can mix-and-match (e.g. a test
// that exercises sign-in flow may leave FAKE_TOKEN_JSON unset). Production
// builds without -tags e2e get a no-op (init never runs because this file is
// not compiled in); no stub file is needed because keyringStoreFactory has a
// real default in auth.go and the override vars default to empty.

import (
	"os"
	"sync"

	"github.com/zalando/go-keyring"
)

// e2eMemKeyringStore is a process-lifetime in-memory KeyringStore used only
// by the Playwright harness. Mirrors zalando/go-keyring semantics: Get
// returns keyring.ErrNotFound when an entry is absent. Concurrent-safe.
//
// Critically, this NEVER touches the real Windows Credential Manager
// (mitigates T-11-06-02: fake keyring must not persist).
type e2eMemKeyringStore struct {
	mu sync.Mutex
	m  map[string]string
}

func newE2EMemKeyringStore() *e2eMemKeyringStore {
	return &e2eMemKeyringStore{m: map[string]string{}}
}

func (s *e2eMemKeyringStore) key(service, user string) string {
	return service + "\x00" + user
}

func (s *e2eMemKeyringStore) Get(service, user string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := s.m[s.key(service, user)]
	if !ok {
		return "", keyring.ErrNotFound
	}
	return v, nil
}

func (s *e2eMemKeyringStore) Set(service, user, secret string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.m[s.key(service, user)] = secret
	return nil
}

func (s *e2eMemKeyringStore) Delete(service, user string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.m, s.key(service, user))
	return nil
}

// e2eSharedKeyring is the single in-memory store used for the lifetime of
// the e2e-tagged process. The keyringStoreFactory swap returns this same
// instance on every call so AuthManager always sees the same backing map.
var e2eSharedKeyring = newE2EMemKeyringStore()

func init() {
	// Swap the keyring factory BEFORE NewAuthManager runs. main() builds
	// the App / AuthManager well after Go's package-init phase, so this
	// assignment is observed by every constructor call.
	keyringStoreFactory = func() KeyringStore { return e2eSharedKeyring }

	// Pre-populate the keyring with the harness-supplied token JSON. The
	// AuthManager.LoadFromKeyring path will pick this up on first read.
	if blob := os.Getenv("GOMAPI_E2E_FAKE_TOKEN_JSON"); blob != "" {
		_ = e2eSharedKeyring.Set(keyringService, keyringUser, blob)
	}

	// Endpoint overrides. Each var has its own production default, so an
	// unset env var leaves the override empty and the production default
	// (real Google endpoints) is used.
	if v := os.Getenv("GOMAPI_E2E_GMAIL_BASE_URL"); v != "" {
		gmailBaseURLOverride = v
	}
	if v := os.Getenv("GOMAPI_E2E_TOKEN_ENDPOINT"); v != "" {
		tokenEndpointOverride = v
	}
	if v := os.Getenv("GOMAPI_E2E_REVOKE_ENDPOINT"); v != "" {
		revokeEndpointOverride = v
	}
}
