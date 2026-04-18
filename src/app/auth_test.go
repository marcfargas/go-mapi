package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/zalando/go-keyring"
	"golang.org/x/oauth2"
)

// fakeKeyringStore is an in-memory KeyringStore for cross-platform unit tests.
// It mirrors zalando/go-keyring semantics: Get returns keyring.ErrNotFound when
// an entry is absent. Concurrent-safe via mu. Zero value is NOT ready — use
// newFakeKeyringStore.
type fakeKeyringStore struct {
	mu sync.Mutex
	m  map[string]string
	// getErr, if non-nil, is returned from Get for any non-ErrNotFound scenario.
	// Used to exercise "credential store unavailable" branches (D-11).
	getErr error
}

func newFakeKeyringStore() *fakeKeyringStore {
	return &fakeKeyringStore{m: map[string]string{}}
}

func (f *fakeKeyringStore) key(service, user string) string {
	return service + "\x00" + user
}

func (f *fakeKeyringStore) Get(service, user string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.getErr != nil {
		return "", f.getErr
	}
	v, ok := f.m[f.key(service, user)]
	if !ok {
		return "", keyring.ErrNotFound
	}
	return v, nil
}

func (f *fakeKeyringStore) Set(service, user, secret string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.m[f.key(service, user)] = secret
	return nil
}

func (f *fakeKeyringStore) Delete(service, user string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.m, f.key(service, user))
	return nil
}

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

// TestAuthManagerKeyringRoundTrip_Fake exercises the cross-platform
// round-trip against the in-memory fakeKeyringStore. The real Windows
// Credential Manager round-trip is covered in auth_keyring_windows_test.go.
func TestAuthManagerKeyringRoundTrip_Fake(t *testing.T) {
	t.Parallel()
	store := newFakeKeyringStore()
	am := NewAuthManagerWithStore(store)
	am.tokens = &OAuthTokens{
		AccessToken:  "a",
		RefreshToken: "r",
		TokenType:    "Bearer",
		Expiry:       time.Date(2026, 4, 15, 0, 0, 0, 0, time.UTC),
	}
	if err := am.SaveToKeyring(); err != nil {
		t.Fatalf("save: %v", err)
	}

	am2 := NewAuthManagerWithStore(store)
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
	t.Parallel()
	am := NewAuthManagerWithStore(newFakeKeyringStore())
	if err := am.LoadFromKeyring(); err != nil {
		t.Fatalf("expected nil on ErrNotFound, got: %v", err)
	}
	if am.tokens != nil {
		t.Fatalf("expected tokens nil, got %+v", am.tokens)
	}
}

func TestClearTokensIsIdempotent(t *testing.T) {
	t.Parallel()
	am := NewAuthManagerWithStore(newFakeKeyringStore())
	// First call on an already-empty keyring must not error.
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
	am := NewAuthManagerWithStore(newFakeKeyringStore())
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
	am := NewAuthManagerWithStore(newFakeKeyringStore())
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
	am := NewAuthManagerWithStore(newFakeKeyringStore())
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
	am := NewAuthManagerWithStore(newFakeKeyringStore())
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

// ---- Task 1 (Plan 04): refresh, revoke, MakeAuthenticatedGmailCall tests ----

func TestRefreshIfNeededFastPath(t *testing.T) {
	t.Parallel()
	am := NewAuthManagerWithStore(newFakeKeyringStore())
	am.tokens = &OAuthTokens{AccessToken: "A", RefreshToken: "R", Expiry: time.Now().Add(30 * time.Minute)}
	if err := am.refreshIfNeededLocked(context.Background()); err != nil {
		t.Fatalf("expected nil (fast path), got %v", err)
	}
	if am.tokens.AccessToken != "A" {
		t.Fatal("expected unchanged access token")
	}
}

func TestRefreshIfNeededNoTokens(t *testing.T) {
	t.Parallel()
	am := NewAuthManagerWithStore(newFakeKeyringStore())
	if err := am.refreshIfNeededLocked(context.Background()); !errors.Is(err, ErrNotAuthenticated) {
		t.Fatalf("expected ErrNotAuthenticated, got %v", err)
	}
}

func TestRefreshInvalidGrantClears(t *testing.T) {
	// Stub token endpoint returning 400 invalid_grant.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		_, _ = w.Write([]byte(`{"error":"invalid_grant"}`))
	}))
	defer srv.Close()

	tokenEndpointOverride = srv.URL
	t.Cleanup(func() { tokenEndpointOverride = "" })

	store := newFakeKeyringStore()
	am := NewAuthManagerWithStore(store)
	am.tokens = &OAuthTokens{AccessToken: "old", RefreshToken: "dead", Expiry: time.Now().Add(-time.Minute)}
	_ = am.saveToKeyringLocked()

	err := am.refreshIfNeededLocked(context.Background())
	if !errors.Is(err, ErrInvalidGrant) {
		t.Fatalf("expected ErrInvalidGrant, got %v", err)
	}
	if am.tokens != nil {
		t.Fatal("expected tokens cleared")
	}
	// Keyring should also be empty now.
	_, getErr := store.Get(keyringService, keyringUser)
	if !errors.Is(getErr, keyring.ErrNotFound) {
		t.Fatalf("expected keyring cleared, got %v", getErr)
	}
}

func TestRefreshHappyPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Errorf("parse form: %v", err)
		}
		if r.Form.Get("grant_type") != "refresh_token" {
			t.Errorf("expected grant_type=refresh_token, got %q", r.Form.Get("grant_type"))
		}
		if r.Form.Get("refresh_token") != "my-refresh" {
			t.Errorf("expected refresh_token=my-refresh, got %q", r.Form.Get("refresh_token"))
		}
		_, _ = w.Write([]byte(`{"access_token":"NEW","expires_in":3600,"token_type":"Bearer"}`))
	}))
	defer srv.Close()
	tokenEndpointOverride = srv.URL
	t.Cleanup(func() { tokenEndpointOverride = "" })

	am := NewAuthManagerWithStore(newFakeKeyringStore())
	am.tokens = &OAuthTokens{AccessToken: "old", RefreshToken: "my-refresh", TokenType: "Bearer", Expiry: time.Now().Add(1 * time.Minute)}
	if err := am.refreshIfNeededLocked(context.Background()); err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if am.tokens.AccessToken != "NEW" {
		t.Fatalf("expected NEW access token, got %q", am.tokens.AccessToken)
	}
	if time.Until(am.tokens.Expiry) < 50*time.Minute {
		t.Fatalf("expected expiry ~1h out, got %s", am.tokens.Expiry)
	}
}

func TestRefreshTransient5xxRetainsTokens(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(503)
	}))
	defer srv.Close()
	tokenEndpointOverride = srv.URL
	t.Cleanup(func() { tokenEndpointOverride = "" })

	am := NewAuthManagerWithStore(newFakeKeyringStore())
	am.tokens = &OAuthTokens{AccessToken: "A", RefreshToken: "R", Expiry: time.Now().Add(-time.Minute)}
	err := am.refreshIfNeededLocked(context.Background())
	if err == nil || errors.Is(err, ErrInvalidGrant) {
		t.Fatalf("expected transient error (not invalid_grant), got %v", err)
	}
	if am.tokens == nil {
		t.Fatal("expected tokens retained on transient failure")
	}
}

func TestRevoke200IsSuccess(t *testing.T) {
	var got string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err == nil {
			got = r.Form.Get("token")
		}
		w.WriteHeader(200)
	}))
	defer srv.Close()
	revokeEndpointOverride = srv.URL
	t.Cleanup(func() { revokeEndpointOverride = "" })

	am := NewAuthManagerWithStore(newFakeKeyringStore())
	am.tokens = &OAuthTokens{RefreshToken: "rt-abc"}
	am.revokeRefreshToken(context.Background())
	if got != "rt-abc" {
		t.Fatalf("expected token=rt-abc in form, got %q", got)
	}
}

func TestRevoke400InvalidTokenTreatedAsSuccess(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		_, _ = w.Write([]byte(`{"error":"invalid_token"}`))
	}))
	defer srv.Close()
	revokeEndpointOverride = srv.URL
	t.Cleanup(func() { revokeEndpointOverride = "" })

	am := NewAuthManagerWithStore(newFakeKeyringStore())
	am.tokens = &OAuthTokens{RefreshToken: "rt"}
	// Should not panic, should return quickly.
	am.revokeRefreshToken(context.Background())
}

// TestMakeAuthenticatedGmailCall_RetryOn401Succeeds covers the happy
// retry path: first fn invocation returns HTTP 401, triggering a single
// refresh; second invocation returns 200 and the helper returns success.
func TestMakeAuthenticatedGmailCall_RetryOn401Succeeds(t *testing.T) {
	// Stub token endpoint that succeeds with a NEW access token.
	var refreshCount int
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		refreshCount++
		_, _ = w.Write([]byte(`{"access_token":"NEW","expires_in":3600,"token_type":"Bearer"}`))
	}))
	defer tokenSrv.Close()
	tokenEndpointOverride = tokenSrv.URL
	t.Cleanup(func() { tokenEndpointOverride = "" })

	app := NewApp()
	app.auth = NewAuthManagerWithStore(newFakeKeyringStore())
	// Seed signed-in, access token fresh-ish so the proactive refresh is a no-op.
	app.auth.tokens = &OAuthTokens{
		AccessToken:  "OLD",
		RefreshToken: "my-refresh",
		TokenType:    "Bearer",
		Expiry:       time.Now().Add(30 * time.Minute),
	}

	var callCount int
	var seenTokens []string
	fn := func(accessToken string) (int, error) {
		callCount++
		seenTokens = append(seenTokens, accessToken)
		if callCount == 1 {
			return 401, nil
		}
		return 200, nil
	}

	if err := app.MakeAuthenticatedGmailCall(context.Background(), fn); err != nil {
		t.Fatalf("expected nil, got %v", err)
	}
	if callCount != 2 {
		t.Fatalf("expected fn called exactly 2 times, got %d", callCount)
	}
	if refreshCount != 1 {
		t.Fatalf("expected exactly 1 refresh between calls, got %d", refreshCount)
	}
	if len(seenTokens) != 2 || seenTokens[0] != "OLD" || seenTokens[1] != "NEW" {
		t.Fatalf("expected tokens [OLD, NEW] across the two calls, got %v", seenTokens)
	}
	if app.auth.tokens == nil || app.auth.tokens.AccessToken != "NEW" {
		t.Fatalf("expected in-memory token updated to NEW")
	}
}

// TestMakeAuthenticatedGmailCall_DoubleFailClassifiesInvalidGrant covers
// the classification path: fn returns 401 twice AND the refresh endpoint
// returns invalid_grant. Expect: ErrInvalidGrant returned, tokens cleared.
func TestMakeAuthenticatedGmailCall_DoubleFailClassifiesInvalidGrant(t *testing.T) {
	// Stub token endpoint: returns invalid_grant.
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		_, _ = w.Write([]byte(`{"error":"invalid_grant"}`))
	}))
	defer tokenSrv.Close()
	tokenEndpointOverride = tokenSrv.URL
	t.Cleanup(func() { tokenEndpointOverride = "" })

	store := newFakeKeyringStore()
	app := NewApp()
	app.auth = NewAuthManagerWithStore(store)
	app.auth.tokens = &OAuthTokens{
		AccessToken:  "OLD",
		RefreshToken: "dead",
		TokenType:    "Bearer",
		Expiry:       time.Now().Add(30 * time.Minute),
	}
	_ = app.auth.SaveToKeyring()

	fn := func(accessToken string) (int, error) {
		return 401, nil
	}

	err := app.MakeAuthenticatedGmailCall(context.Background(), fn)
	if !errors.Is(err, ErrInvalidGrant) {
		t.Fatalf("expected ErrInvalidGrant, got %v", err)
	}
	// Status() is the same source of truth used by emitAuthChanged.
	if app.auth.Status().Authenticated {
		t.Fatal("expected Status().Authenticated == false after invalid_grant")
	}
	if app.auth.tokens != nil {
		t.Fatal("expected in-memory tokens cleared")
	}
	// Keyring cleared.
	if _, gerr := store.Get(keyringService, keyringUser); !errors.Is(gerr, keyring.ErrNotFound) {
		t.Fatalf("expected keyring cleared, got %v", gerr)
	}
}

// ---- Task 2 (Plan 04): SignOut + bootstrapAuth tests ----

func TestSignOutEmitsAndClears(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()
	revokeEndpointOverride = srv.URL
	t.Cleanup(func() { revokeEndpointOverride = "" })

	store := newFakeKeyringStore()
	app := NewApp()
	app.auth = NewAuthManagerWithStore(store)
	app.auth.tokens = &OAuthTokens{AccessToken: "a", RefreshToken: "r"}
	_ = app.auth.SaveToKeyring()

	if err := app.SignOut(); err != nil {
		t.Fatalf("sign out: %v", err)
	}
	if app.auth.tokens != nil {
		t.Fatal("expected tokens cleared")
	}
	_, err := store.Get(keyringService, keyringUser)
	if !errors.Is(err, keyring.ErrNotFound) {
		t.Fatalf("expected keyring cleared, got %v", err)
	}
}

func TestSignOutIdempotent(t *testing.T) {
	app := NewApp()
	app.auth = NewAuthManagerWithStore(newFakeKeyringStore())
	// No tokens set.
	if err := app.SignOut(); err != nil {
		t.Fatalf("sign out on empty: %v", err)
	}
	if err := app.SignOut(); err != nil {
		t.Fatalf("sign out again: %v", err)
	}
}

func TestBootstrapAuthSignedOutPath(t *testing.T) {
	app := NewApp()
	app.auth = NewAuthManagerWithStore(newFakeKeyringStore())
	// No ctx — bootstrapAuth must not panic; emitAuthChanged guards nil ctx.
	app.bootstrapAuth()
	if app.auth.tokens != nil {
		t.Fatal("expected tokens nil after bootstrap with no keyring entry")
	}
	if app.auth.Status().Authenticated {
		t.Fatal("expected signed-out status")
	}
}

func TestBootstrapAuthSignedInPath(t *testing.T) {
	// Seed a fake keyring with a valid token payload and share it with the App.
	store := newFakeKeyringStore()
	seed := NewAuthManagerWithStore(store)
	seed.tokens = &OAuthTokens{
		AccessToken:  "a",
		RefreshToken: "r",
		TokenType:    "Bearer",
		Expiry:       time.Now().Add(30 * time.Minute), // fast path, no refresh
	}
	if err := seed.SaveToKeyring(); err != nil {
		t.Fatalf("seed: %v", err)
	}

	app := NewApp()
	app.auth = NewAuthManagerWithStore(store)
	app.bootstrapAuth()
	if !app.auth.Status().Authenticated {
		t.Fatal("expected authenticated after bootstrap with valid keyring entry")
	}
}
