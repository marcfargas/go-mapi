package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/zalando/go-keyring"
	"golang.org/x/oauth2"
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

// ---- Task 1: PKCE + loopback tests ----

func TestGenerateVerifierLength(t *testing.T) {
	t.Parallel()
	v := oauth2.GenerateVerifier()
	if len(v) != 43 {
		t.Fatalf("expected 43-char verifier, got %d: %q", len(v), v)
	}
}

func TestAuthCodeURLHasPKCE(t *testing.T) {
	t.Parallel()
	// Populate ldflags vars for the test — normally empty in source tree.
	oauthClientID = "test-client.apps.googleusercontent.com"
	oauthClientSecret = "test-secret"
	t.Cleanup(func() { oauthClientID = ""; oauthClientSecret = "" })

	cfg := newOAuthConfig("http://127.0.0.1:12345/callback")
	v := oauth2.GenerateVerifier()
	u := cfg.AuthCodeURL("state-xyz", oauth2.AccessTypeOffline, oauth2.S256ChallengeOption(v))

	parsed, err := url.Parse(u)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	q := parsed.Query()
	if q.Get("code_challenge_method") != "S256" {
		t.Fatalf("expected code_challenge_method=S256, got %q", q.Get("code_challenge_method"))
	}
	if len(q.Get("code_challenge")) < 20 {
		t.Fatalf("expected non-trivial code_challenge, got %q", q.Get("code_challenge"))
	}
	if q.Get("access_type") != "offline" {
		t.Fatalf("expected access_type=offline, got %q", q.Get("access_type"))
	}
	scope := q.Get("scope")
	for _, want := range []string{"gmail.compose", "gmail.send", "userinfo.email", "userinfo.profile"} {
		if !strings.Contains(scope, want) {
			t.Fatalf("scope missing %q: %q", want, scope)
		}
	}
	if q.Get("state") != "state-xyz" {
		t.Fatalf("expected state=state-xyz, got %q", q.Get("state"))
	}
}

func TestRandomStateUnique(t *testing.T) {
	t.Parallel()
	a, err := randomState()
	if err != nil {
		t.Fatal(err)
	}
	b, err := randomState()
	if err != nil {
		t.Fatal(err)
	}
	if a == b {
		t.Fatal("expected distinct states")
	}
	if len(a) != 43 {
		t.Fatalf("expected 43-char base64url state, got %d", len(a))
	}
}

func TestRunLoopbackStateMismatchRejected(t *testing.T) {
	t.Parallel()
	am := NewAuthManager()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	redirectURL, wait, cleanup, err := am.prepareLoopback(ctx, "expected-state")
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	defer cleanup()

	// Send callback with WRONG state
	bad := redirectURL + "?state=wrong&code=abc123"
	resp, err := http.Get(bad) //nolint:noctx // test helper
	if err != nil {
		t.Fatalf("GET bad state: %v", err)
	}
	_ = resp.Body.Close()

	_, waitErr := wait()
	if waitErr == nil || !strings.Contains(waitErr.Error(), "state mismatch") {
		t.Fatalf("expected state mismatch error, got %v", waitErr)
	}
}

func TestRunLoopbackHappyPath(t *testing.T) {
	t.Parallel()
	am := NewAuthManager()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	redirectURL, wait, cleanup, err := am.prepareLoopback(ctx, "s1")
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	defer cleanup()

	good := redirectURL + "?state=s1&code=MY_CODE"
	resp, err := http.Get(good) //nolint:noctx // test helper
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	_ = resp.Body.Close()

	code, err := wait()
	if err != nil {
		t.Fatalf("wait: %v", err)
	}
	if code != "MY_CODE" {
		t.Fatalf("expected MY_CODE, got %q", code)
	}
}

func TestRunLoopbackContextCancel(t *testing.T) {
	t.Parallel()
	am := NewAuthManager()
	ctx, cancel := context.WithCancel(context.Background())
	_, wait, cleanup, err := am.prepareLoopback(ctx, "s2")
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	defer cleanup()
	cancel()
	_, waitErr := wait()
	if !errors.Is(waitErr, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", waitErr)
	}
}

// ---- Task 2: userinfo decode test ----

func TestUserinfoResponseDecode(t *testing.T) {
	t.Parallel()
	body := `{"sub":"1","email":"marc@example.com","name":"Marc","email_verified":true,"locale":"en"}`
	var u userinfoResponse
	if err := json.Unmarshal([]byte(body), &u); err != nil {
		t.Fatal(err)
	}
	if u.Email != "marc@example.com" || u.Name != "Marc" {
		t.Fatalf("unexpected: %+v", u)
	}
}

// Quiet unused-import guard if a future refactor drops errors.
var _ = errors.Is
