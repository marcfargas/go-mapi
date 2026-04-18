//go:build windows

package main

import (
	"errors"
	"testing"
	"time"

	"github.com/zalando/go-keyring"
)

// TestRealKeyring_WindowsRoundTrip exercises realKeyringStore against the
// real Windows Credential Manager. Runs only on windows-latest CI (and
// Windows developer machines). D-11 integration coverage: the cross-platform
// unit tests use fakeKeyringStore; this file confirms the real backend
// honours the same contract (Get/Set/Delete + keyring.ErrNotFound after Delete).
func TestRealKeyring_WindowsRoundTrip(t *testing.T) {
	// Ensure a clean state before and after.
	_ = keyring.Delete(keyringService, keyringUser)
	t.Cleanup(func() { _ = keyring.Delete(keyringService, keyringUser) })

	store := realKeyringStore{}
	payload := `{"access_token":"a","refresh_token":"r","token_type":"Bearer","expiry":"2026-04-15T00:00:00Z"}`

	if err := store.Set(keyringService, keyringUser, payload); err != nil {
		t.Fatalf("Set: %v", err)
	}
	got, err := store.Get(keyringService, keyringUser)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got != payload {
		t.Fatalf("round-trip mismatch:\n got %q\nwant %q", got, payload)
	}
	if err := store.Delete(keyringService, keyringUser); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := store.Get(keyringService, keyringUser); !errors.Is(err, keyring.ErrNotFound) {
		t.Fatalf("expected keyring.ErrNotFound after Delete, got %v", err)
	}
}

// TestAuthManagerKeyringRoundTrip_RealKeyring pairs AuthManager with the real
// keyring store (via NewAuthManager) and confirms SaveToKeyring/LoadFromKeyring
// round-trip through the Windows Credential Manager. Migrated from
// auth_test.go where it previously required a real keyring on every platform.
func TestAuthManagerKeyringRoundTrip_RealKeyring(t *testing.T) {
	_ = keyring.Delete(keyringService, keyringUser)
	t.Cleanup(func() { _ = keyring.Delete(keyringService, keyringUser) })

	am := NewAuthManager() // uses realKeyringStore
	am.tokens = &OAuthTokens{
		AccessToken:  "a",
		RefreshToken: "r",
		TokenType:    "Bearer",
		Expiry:       time.Date(2026, 4, 15, 0, 0, 0, 0, time.UTC),
	}
	if err := am.SaveToKeyring(); err != nil {
		t.Fatalf("save: %v", err)
	}

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
