//go:build !bindings

package main

import (
	"strings"
	"testing"
)

// Tests for checkOAuthCredentials after the D-10 refactor. The production file
// carries the same //go:build !bindings tag so this test file must too — the
// `bindings`-tagged variant in credentials_check_bindings.go returns nil
// unconditionally (the introspection build does not need credentials).
//
// Tests mutate the package-level oauthClientID / oauthClientSecret vars that
// -ldflags normally injects at build time, so they cannot run t.Parallel
// against each other (shared mutable state).

func TestCheckOAuthCredentials_OKWhenBothSet(t *testing.T) {
	oldID, oldSecret := oauthClientID, oauthClientSecret
	t.Cleanup(func() {
		oauthClientID = oldID
		oauthClientSecret = oldSecret
	})
	oauthClientID = "test-id.apps.googleusercontent.com"
	oauthClientSecret = "test-secret"
	if err := checkOAuthCredentials(); err != nil {
		t.Fatalf("unexpected error with both set: %v", err)
	}
}

func TestCheckOAuthCredentials_ErrorsWhenClientIDEmpty(t *testing.T) {
	oldID, oldSecret := oauthClientID, oauthClientSecret
	t.Cleanup(func() {
		oauthClientID = oldID
		oauthClientSecret = oldSecret
	})
	oauthClientID = ""
	oauthClientSecret = "test-secret"
	err := checkOAuthCredentials()
	if err == nil {
		t.Fatal("expected error when client_id empty, got nil")
	}
	if !strings.Contains(err.Error(), "client_id") {
		t.Errorf("error %q should mention client_id", err.Error())
	}
}

func TestCheckOAuthCredentials_ErrorsWhenClientSecretEmpty(t *testing.T) {
	oldID, oldSecret := oauthClientID, oauthClientSecret
	t.Cleanup(func() {
		oauthClientID = oldID
		oauthClientSecret = oldSecret
	})
	oauthClientID = "test-id.apps.googleusercontent.com"
	oauthClientSecret = ""
	err := checkOAuthCredentials()
	if err == nil {
		t.Fatal("expected error when client_secret empty, got nil")
	}
	if !strings.Contains(err.Error(), "client_secret") {
		t.Errorf("error %q should mention client_secret", err.Error())
	}
}
