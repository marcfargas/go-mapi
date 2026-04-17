package main

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/zalando/go-keyring"
)

func TestOAuthTokensJSONRoundTrip(t *testing.T) {
	t.Parallel()
	in := OAuthTokens{
		AccessToken:  "ya29.access",
		RefreshToken: "1//refresh",
		TokenType:    "Bearer",
		Expiry:       time.Date(2026, 4, 15, 13, 45, 12, 0, time.UTC),
	}
	raw, err := json.Marshal(in)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var out OAuthTokens
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out != in {
		t.Fatalf("round-trip mismatch:\n got %+v\n want %+v", out, in)
	}
}

func TestAuthStatusZeroValueOmitsEmptyFields(t *testing.T) {
	t.Parallel()
	raw, err := json.Marshal(AuthStatus{})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	s := string(raw)
	if strings.Contains(s, "email") || strings.Contains(s, "name") {
		t.Fatalf("expected email/name omitted, got %s", s)
	}
	if !strings.Contains(s, `"authenticated":false`) {
		t.Fatalf("expected authenticated:false, got %s", s)
	}
}

func TestAuthManagerKeyringRoundTrip(t *testing.T) {
	// Uses the real Windows Credential Manager. Sequential (no t.Parallel)
	// because we share a single service/user key. Cleanup on exit.
	am := NewAuthManager()
	am.tokens = &OAuthTokens{
		AccessToken:  "a",
		RefreshToken: "r",
		TokenType:    "Bearer",
		Expiry:       time.Date(2026, 4, 15, 0, 0, 0, 0, time.UTC),
	}
	if err := am.SaveToKeyring(); err != nil {
		t.Fatalf("save: %v", err)
	}
	t.Cleanup(func() { _ = am.ClearTokens() })

	am2 := NewAuthManager()
	if err := am2.LoadFromKeyring(); err != nil {
		t.Fatalf("load: %v", err)
	}
	if am2.tokens == nil {
		t.Fatal("tokens nil after load")
	}
	if *am2.tokens != *am.tokens {
		t.Fatalf("round-trip mismatch:\n got %+v\n want %+v", *am2.tokens, *am.tokens)
	}
}

func TestLoadFromKeyringNoEntryIsSignedOut(t *testing.T) {
	// Ensure a fresh state.
	_ = keyring.Delete(keyringService, keyringUser)

	am := NewAuthManager()
	if err := am.LoadFromKeyring(); err != nil {
		t.Fatalf("expected nil on ErrNotFound, got: %v", err)
	}
	if am.tokens != nil {
		t.Fatalf("expected tokens nil, got %+v", am.tokens)
	}
}

func TestClearTokensIsIdempotent(t *testing.T) {
	am := NewAuthManager()
	// First call on an already-empty keyring must not error.
	_ = keyring.Delete(keyringService, keyringUser)
	if err := am.ClearTokens(); err != nil {
		t.Fatalf("clear on empty: %v", err)
	}
	// Second call must also not error.
	if err := am.ClearTokens(); err != nil {
		t.Fatalf("clear on cleared: %v", err)
	}
}

func TestStatusReflectsInMemoryFields(t *testing.T) {
	t.Parallel()
	am := NewAuthManager()
	if am.Status().Authenticated {
		t.Fatal("fresh AuthManager should be signed out")
	}
	am.tokens = &OAuthTokens{AccessToken: "a"}
	am.email = "marc@example.com"
	am.name = "Marc"
	st := am.Status()
	if !st.Authenticated || st.Email != "marc@example.com" || st.Name != "Marc" {
		t.Fatalf("unexpected status: %+v", st)
	}
}

// Quiet unused-import guard if a future refactor drops errors.
var _ = errors.Is
