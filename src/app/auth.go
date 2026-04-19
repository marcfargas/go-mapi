package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/pkg/browser"
	"github.com/zalando/go-keyring"
	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// Keyring service+user coordinates per CONTEXT D-11.
const (
	keyringService = "go-mapi"
	keyringUser    = "oauth-tokens"
)

// KeyringStore abstracts the OS credential store so tests can inject a fake.
// The real implementation wraps zalando/go-keyring; the in-memory fake lives
// in auth_test.go. Methods must mirror zalando/go-keyring semantics:
// Get returns keyring.ErrNotFound when the entry is absent.
type KeyringStore interface {
	Get(service, user string) (string, error)
	Set(service, user, secret string) error
	Delete(service, user string) error
}

// realKeyringStore delegates to zalando/go-keyring package-level functions.
// Production code (via NewAuthManager) uses this; tests inject fakeKeyringStore.
type realKeyringStore struct{}

func (realKeyringStore) Get(service, user string) (string, error) {
	return keyring.Get(service, user)
}

func (realKeyringStore) Set(service, user, secret string) error {
	return keyring.Set(service, user, secret)
}

func (realKeyringStore) Delete(service, user string) error {
	return keyring.Delete(service, user)
}

// OAuth scopes (D-17 userinfo + AUTH-01 gmail).
const (
	scopeGmailCompose    = "https://www.googleapis.com/auth/gmail.compose"
	scopeGmailSend       = "https://www.googleapis.com/auth/gmail.send"
	scopeUserinfoEmail   = "https://www.googleapis.com/auth/userinfo.email"
	scopeUserinfoProfile = "https://www.googleapis.com/auth/userinfo.profile"
	loopbackFlowTimeout  = 5 * time.Minute // Claude discretion per CONTEXT
)

// userinfoEndpointOverride is empty in production (the real Google endpoint is
// used); tests set this to point at an httptest stub. Mirrors the
// tokenEndpointOverride / revokeEndpointOverride pattern.
var userinfoEndpointOverride = ""

func userinfoEndpoint() string {
	if userinfoEndpointOverride != "" {
		return userinfoEndpointOverride
	}
	return "https://www.googleapis.com/oauth2/v3/userinfo"
}

// ErrNotAuthenticated is returned when an auth-requiring operation runs
// against an AuthManager that has no tokens loaded.
var ErrNotAuthenticated = errors.New("not authenticated")

// ErrInvalidGrant signals that the refresh token was rejected by Google.
// Callers MUST treat this as "sign the user out and prompt re-auth"
// (CONTEXT D-05). Plan 04 wires the event emission.
var ErrInvalidGrant = errors.New("invalid_grant")

// OAuthTokens is the JSON blob stored in the Windows Credential Manager
// (single entry, no multi-account — D-11).
type OAuthTokens struct {
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token"`
	TokenType    string    `json:"token_type"`
	Expiry       time.Time `json:"expiry"`
}

// AuthStatus is the Wails-bound payload consumed by the frontend for
// both GetAuthStatus() (pull) and the "auth-changed" event (push).
// Email / Name are in-memory only per D-17 (never persisted).
type AuthStatus struct {
	Authenticated bool   `json:"authenticated"`
	Email         string `json:"email,omitempty"`
	Name          string `json:"name,omitempty"`
}

// AuthManager owns the OAuth token lifecycle. Ref held on *App.
type AuthManager struct {
	// refresh serializes token refresh (D-13) AND sign-in (a user-initiated
	// sign-in with no token cannot race a refresh — draft buttons are
	// disabled per D-07, so contention is impossible in practice).
	refresh sync.Mutex

	// tokens is nil when signed out.
	tokens *OAuthTokens

	// email/name are fetched from userinfo after sign-in (D-17).
	// In-memory only — never written to disk.
	email string
	name  string

	// cancelFlow is set by SignIn while the loopback listener is running,
	// so a UI Cancel button can abort the flow. Plan 03 wires this.
	cancelFlow context.CancelFunc

	// keyring is the credential-store backend. Production uses realKeyringStore
	// (zalando/go-keyring); tests inject fakeKeyringStore for cross-platform
	// unit tests. Always non-nil — constructors set it.
	keyring KeyringStore
}

// NewAuthManager constructs a fresh, signed-out AuthManager backed by the
// real Windows Credential Manager (via zalando/go-keyring).
func NewAuthManager() *AuthManager {
	return NewAuthManagerWithStore(realKeyringStore{})
}

// NewAuthManagerWithStore constructs an AuthManager with a custom keyring
// backend. Tests use this to inject an in-memory fakeKeyringStore; production
// code should use NewAuthManager. The store must not be nil.
func NewAuthManagerWithStore(store KeyringStore) *AuthManager {
	return &AuthManager{keyring: store}
}

// Status returns the current in-memory auth view. Safe to call concurrently.
func (am *AuthManager) Status() AuthStatus {
	am.refresh.Lock()
	defer am.refresh.Unlock()
	if am.tokens == nil {
		return AuthStatus{Authenticated: false}
	}
	return AuthStatus{
		Authenticated: true,
		Email:         am.email,
		Name:          am.name,
	}
}

// LoadFromKeyring reads persisted tokens out of Windows Credential Manager.
// keyring.ErrNotFound is converted to nil + tokens=nil (signed-out state,
// D-12 — not an error on first run or after sign-out).
func (am *AuthManager) LoadFromKeyring() error {
	am.refresh.Lock()
	defer am.refresh.Unlock()

	raw, err := am.keyring.Get(keyringService, keyringUser)
	if errors.Is(err, keyring.ErrNotFound) {
		am.tokens = nil
		return nil
	}
	if err != nil {
		return fmt.Errorf("keyring load: %w", err)
	}
	var t OAuthTokens
	if err := json.Unmarshal([]byte(raw), &t); err != nil {
		return fmt.Errorf("keyring decode: %w", err)
	}
	am.tokens = &t
	return nil
}

// saveToKeyringLocked persists am.tokens. Caller must hold am.refresh OR be in
// a single-threaded context (e.g., inside SignIn which already locks).
// Separate exported variant is intentional — Plan 03 calls this while
// already holding the mutex. Do NOT add locking here.
func (am *AuthManager) saveToKeyringLocked() error {
	if am.tokens == nil {
		return errors.New("saveToKeyring: tokens is nil")
	}
	data, err := json.Marshal(am.tokens)
	if err != nil {
		return fmt.Errorf("keyring encode: %w", err)
	}
	if err := am.keyring.Set(keyringService, keyringUser, string(data)); err != nil {
		return fmt.Errorf("keyring save: %w", err)
	}
	return nil
}

// SaveToKeyring is the public wrapper that acquires the mutex.
// Used only by tests; production code paths call saveToKeyringLocked
// while already holding am.refresh.
func (am *AuthManager) SaveToKeyring() error {
	am.refresh.Lock()
	defer am.refresh.Unlock()
	return am.saveToKeyringLocked()
}

// clearTokensLocked wipes in-memory state AND the keyring entry. Caller must
// hold am.refresh. keyring.ErrNotFound on Delete is swallowed (signing out
// twice is a no-op — D-12). Mirrors the saveToKeyringLocked pattern so callers
// inside a critical section can invoke the clear without re-locking.
func (am *AuthManager) clearTokensLocked() error {
	am.tokens = nil
	am.email = ""
	am.name = ""
	if err := am.keyring.Delete(keyringService, keyringUser); err != nil && !errors.Is(err, keyring.ErrNotFound) {
		return fmt.Errorf("keyring delete: %w", err)
	}
	return nil
}

// ClearTokens wipes in-memory state AND the keyring entry. keyring.ErrNotFound
// on Delete is swallowed (signing out twice is a no-op — D-12).
func (am *AuthManager) ClearTokens() error {
	am.refresh.Lock()
	defer am.refresh.Unlock()
	return am.clearTokensLocked()
}

// newOAuthConfig builds a *oauth2.Config with the four required scopes and the
// Google endpoint. redirectURL must include the loopback port (e.g.,
// "http://127.0.0.1:12345/callback").
func newOAuthConfig(redirectURL string) *oauth2.Config {
	return &oauth2.Config{
		ClientID:     oauthClientID,
		ClientSecret: oauthClientSecret,
		RedirectURL:  redirectURL,
		Scopes: []string{
			scopeGmailCompose,
			scopeGmailSend,
			scopeUserinfoEmail,
			scopeUserinfoProfile,
		},
		Endpoint: google.Endpoint,
	}
}

// randomState generates a 43-char URL-safe base64 state parameter (32 random
// bytes → 43 base64url chars). Used as CSRF token per T-08-20.
func randomState() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("randomState: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// openBrowser launches the user's default browser via github.com/pkg/browser
// (D-02, AUTH-02). This avoids passing the auth URL as a rundll32 positional
// argument, removing a command-injection surface on Windows.
func openBrowser(authURL string) error {
	return browser.OpenURL(authURL)
}

// prepareLoopback binds a single-shot HTTP listener on 127.0.0.1:<ephemeral>,
// registers the callback handler, and returns the redirectURL before blocking.
// This split allows the caller to hand the redirectURL to newOAuthConfig and
// then call wait() after opening the browser.
//
// cleanup MUST be called regardless of wait() outcome (defer is recommended).
// wait() blocks until a callback arrives or ctx is cancelled.
func (am *AuthManager) prepareLoopback(ctx context.Context, expectedState string) (redirectURL string, wait func() (string, error), cleanup func(), err error) {
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, nil, fmt.Errorf("loopback listen: %w", err)
	}
	port := lis.Addr().(*net.TCPAddr).Port
	redirectURL = fmt.Sprintf("http://127.0.0.1:%d/callback", port)

	codeCh := make(chan string, 1)
	errCh := make(chan error, 1)
	var once sync.Once
	send := func(c string, e error) {
		once.Do(func() {
			if e != nil {
				errCh <- e
			} else {
				codeCh <- c
			}
		})
	}

	const successHTML = `<!doctype html><html><head><meta charset="utf-8"><title>go-mapi</title></head><body style="font-family:sans-serif;padding:2em"><h2>Signed in to go-mapi</h2><p>You can close this tab and return to the app.</p></body></html>`
	const failureHTML = `<!doctype html><html><head><meta charset="utf-8"><title>go-mapi</title></head><body style="font-family:sans-serif;padding:2em"><h2>Sign-in failed</h2><p>Return to go-mapi to try again.</p></body></html>`

	srv := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/callback" {
				http.NotFound(w, r)
				return
			}
			q := r.URL.Query()
			if e := q.Get("error"); e != "" {
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				_, _ = w.Write([]byte(failureHTML))
				send("", fmt.Errorf("oauth error: %s", e))
				return
			}
			if q.Get("state") != expectedState {
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				_, _ = w.Write([]byte(failureHTML))
				send("", errors.New("state mismatch"))
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte(successHTML))
			send(q.Get("code"), nil)
		}),
	}

	go func() { _ = srv.Serve(lis) }()

	cleanup = func() { _ = srv.Shutdown(context.Background()) }
	wait = func() (string, error) {
		select {
		case c := <-codeCh:
			return c, nil
		case e := <-errCh:
			return "", e
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}
	return redirectURL, wait, cleanup, nil
}

// runLoopback is the convenience wrapper used by SignIn. It calls prepareLoopback,
// blocks until a callback arrives (or ctx cancels), then shuts down the listener.
func (am *AuthManager) runLoopback(ctx context.Context, expectedState string) (string, string, error) {
	redirectURL, wait, cleanup, err := am.prepareLoopback(ctx, expectedState)
	if err != nil {
		return "", "", err
	}
	defer cleanup()
	code, err := wait()
	return code, redirectURL, err
}

// userinfoResponse matches https://www.googleapis.com/oauth2/v3/userinfo.
// Only email + name are consumed; other fields are tolerated but ignored.
type userinfoResponse struct {
	Email string `json:"email"`
	Name  string `json:"name"`
}

// fetchUserInfoLocked populates am.email / am.name from the userinfo endpoint.
// Non-fatal: logged and swallowed if it fails (signed-in state still valid).
// Caller must hold am.refresh.
func (am *AuthManager) fetchUserInfoLocked(ctx context.Context) {
	if am.tokens == nil {
		return
	}
	req, err := http.NewRequestWithContext(ctx, "GET", userinfoEndpoint(), nil)
	if err != nil {
		logError("oauth userinfo: build request: %v", err)
		return
	}
	req.Header.Set("Authorization", "Bearer "+am.tokens.AccessToken)
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		logError("oauth userinfo: %v", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		logError("oauth userinfo: status %d", resp.StatusCode)
		return
	}
	var u userinfoResponse
	if err := json.NewDecoder(resp.Body).Decode(&u); err != nil {
		logError("oauth userinfo decode: %v", err)
		return
	}
	am.email = u.Email
	am.name = u.Name
	logInfo("oauth: signed in as %s", am.email)
}

// signInLocked drives the full loopback + PKCE flow. Caller holds am.refresh.
func (am *AuthManager) signInLocked(parent context.Context) error {
	flowCtx, cancel := context.WithTimeout(parent, loopbackFlowTimeout)
	defer cancel()
	am.cancelFlow = cancel

	state, err := randomState()
	if err != nil {
		return err
	}
	verifier := oauth2.GenerateVerifier()

	redirectURL, wait, cleanup, err := am.prepareLoopback(flowCtx, state)
	if err != nil {
		return err
	}
	defer cleanup()

	cfg := newOAuthConfig(redirectURL)
	authURL := cfg.AuthCodeURL(
		state,
		oauth2.AccessTypeOffline,
		oauth2.S256ChallengeOption(verifier),
		oauth2.SetAuthURLParam("prompt", "consent"),
	)

	logInfo("oauth: opening browser for sign-in (redirect=%s)", redirectURL)
	if err := openBrowser(authURL); err != nil {
		return fmt.Errorf("open browser: %w", err)
	}

	code, err := wait()
	if err != nil {
		return fmt.Errorf("loopback wait: %w", err)
	}

	token, err := cfg.Exchange(flowCtx, code, oauth2.VerifierOption(verifier))
	if err != nil {
		return fmt.Errorf("token exchange: %w", err)
	}
	if token.RefreshToken == "" {
		return errors.New("token exchange: no refresh_token returned (consent may not have been re-granted)")
	}

	am.tokens = &OAuthTokens{
		AccessToken:  token.AccessToken,
		RefreshToken: token.RefreshToken,
		TokenType:    token.TokenType,
		Expiry:       token.Expiry,
	}
	if err := am.saveToKeyringLocked(); err != nil {
		// Keyring write failure: wipe in-memory so we don't pretend to be signed in.
		am.tokens = nil
		return fmt.Errorf("keyring save: %w", err)
	}

	// Userinfo is non-fatal — log if it fails, user is still signed in.
	am.fetchUserInfoLocked(flowCtx)

	logInfo("oauth: sign-in complete, token expires %s", token.Expiry.Format(time.RFC3339))
	return nil
}

// ---- Wails bindings on *App (D-19). ----

// GetAuthStatus is called by the frontend on mount to render the
// welcome/sign-in screen vs the queue view. Never returns an error.
func (a *App) GetAuthStatus() AuthStatus {
	if a.auth == nil {
		return AuthStatus{Authenticated: false}
	}
	return a.auth.Status()
}

// SignIn runs the full desktop OAuth flow. Emits "auth-changed" on success.
// Plan 04 adds the event emission in the OnStartup path and refresh failures;
// the SignIn success emission is added here so the frontend refreshes.
func (a *App) SignIn() error {
	if a.auth == nil {
		return errors.New("auth manager not initialized")
	}
	a.auth.refresh.Lock()
	defer a.auth.refresh.Unlock()
	if err := a.auth.signInLocked(a.ctx); err != nil {
		logError("oauth sign-in failed: %v", err)
		return err
	}
	// Flip tray to idle — sign-in clears the "sign in required" / expired state
	// the tray has been carrying since bootstrap or a previous sign-out.
	a.SetTrayIdle("watching for emails")
	// Emit auth-changed so the Svelte frontend drops the welcome screen.
	wruntime.EventsEmit(a.ctx, "auth-changed", AuthStatus{
		Authenticated: true,
		Email:         a.auth.email,
		Name:          a.auth.name,
	})
	return nil
}

// tokenEndpointOverride / revokeEndpointOverride are empty in production
// (the real Google endpoints are used); tests set these to point at httptest stubs.
var (
	tokenEndpointOverride  = ""
	revokeEndpointOverride = ""
)

func tokenEndpoint() string {
	if tokenEndpointOverride != "" {
		return tokenEndpointOverride
	}
	return "https://oauth2.googleapis.com/token"
}

func revokeEndpoint() string {
	if revokeEndpointOverride != "" {
		return revokeEndpointOverride
	}
	return "https://oauth2.googleapis.com/revoke"
}

// refreshIfNeededLocked implements the D-13 proactive refresh.
// Caller must hold am.refresh. Returns ErrNotAuthenticated when no tokens,
// nil when the current access token is still valid >5 minutes out,
// ErrInvalidGrant on 400 invalid_grant (tokens are cleared), or a wrapped
// error for transient failures (tokens are retained).
func (am *AuthManager) refreshIfNeededLocked(ctx context.Context) error {
	if am.tokens == nil {
		return ErrNotAuthenticated
	}
	if time.Until(am.tokens.Expiry) > 5*time.Minute {
		return nil
	}
	if am.tokens.RefreshToken == "" {
		return ErrInvalidGrant
	}

	form := url.Values{
		"client_id":     {oauthClientID},
		"client_secret": {oauthClientSecret},
		"refresh_token": {am.tokens.RefreshToken},
		"grant_type":    {"refresh_token"},
	}
	req, err := http.NewRequestWithContext(ctx, "POST", tokenEndpoint(), strings.NewReader(form.Encode()))
	if err != nil {
		return fmt.Errorf("refresh: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("refresh: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == 400 {
		var e struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(body, &e)
		if e.Error == "invalid_grant" || e.Error == "invalid_client" {
			// D-05 / D-12: clear tokens, clear keyring, bubble up classified error.
			logError("oauth refresh: %s — clearing tokens", e.Error)
			am.tokens = nil
			am.email = ""
			am.name = ""
			_ = am.keyring.Delete(keyringService, keyringUser)
			return ErrInvalidGrant
		}
		return fmt.Errorf("refresh: 400 %s", e.Error)
	}
	if resp.StatusCode != 200 {
		return fmt.Errorf("refresh: status %d", resp.StatusCode)
	}

	var r struct {
		AccessToken  string `json:"access_token"`
		ExpiresIn    int    `json:"expires_in"`
		TokenType    string `json:"token_type"`
		RefreshToken string `json:"refresh_token,omitempty"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return fmt.Errorf("refresh: decode: %w", err)
	}
	if r.AccessToken == "" {
		return errors.New("refresh: empty access_token in response")
	}

	am.tokens.AccessToken = r.AccessToken
	am.tokens.Expiry = time.Now().Add(time.Duration(r.ExpiresIn) * time.Second)
	if r.TokenType != "" {
		am.tokens.TokenType = r.TokenType
	}
	if r.RefreshToken != "" {
		am.tokens.RefreshToken = r.RefreshToken
	}
	if err := am.saveToKeyringLocked(); err != nil {
		logError("oauth refresh: keyring save: %v", err)
		// Don't fail the refresh on keyring save error — in-memory token is good
		// for this process. Next restart will re-refresh.
	}
	logInfo("oauth: access token refreshed, new expiry %s", am.tokens.Expiry.Format(time.RFC3339))
	return nil
}

// revokeRefreshToken is best-effort per D-15 (5s timeout). Failures are
// logged; caller (SignOut) clears the keyring regardless.
func (am *AuthManager) revokeRefreshToken(parent context.Context) {
	if am.tokens == nil || am.tokens.RefreshToken == "" {
		return
	}
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()

	body := "token=" + url.QueryEscape(am.tokens.RefreshToken)
	req, err := http.NewRequestWithContext(ctx, "POST", revokeEndpoint(), strings.NewReader(body))
	if err != nil {
		logError("oauth revoke: build request: %v", err)
		return
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		logError("oauth revoke: %v", err)
		return
	}
	defer resp.Body.Close()
	// 200 = revoked. 400 with invalid_token = already revoked (treat as success).
	if resp.StatusCode == 200 {
		logInfo("oauth: refresh token revoked")
		return
	}
	if resp.StatusCode == 400 {
		logInfo("oauth: revoke returned 400 (token likely already revoked) — treating as success")
		return
	}
	logError("oauth revoke: status %d", resp.StatusCode)
}

// GmailCall is the signature Phase 9's draft-creation code will satisfy.
// The statusCode return is ONLY inspected for 401 — it is the caller's signal
// that the access token was rejected and a refresh + retry should be attempted.
// Any other status with a non-nil err is bubbled up verbatim (no retry).
// Callers that return (non-401, nil) are treated as success regardless of the
// numeric status; callers must therefore always pair a failed HTTP response with
// a non-nil err. The (0, someErr) case (transport failure before any HTTP status
// is known) is safely handled: status 0 != 401, so the error is returned directly.
type GmailCall func(accessToken string) (statusCode int, err error)

// MakeAuthenticatedGmailCall is the public helper Phase 9 uses. It ensures
// a fresh access token (proactive D-13), invokes fn, and on a single 401
// forces a refresh and retries once. A second 401 — or any refresh error
// classifying as invalid_grant — triggers sign-out and emits auth-changed.
//
// Contract: fn must return (401, non-nil-err) to trigger the retry path.
// Any other (status, err) combination where err != nil is returned as-is.
// Any (status, nil) combination where status != 401 is treated as success.
func (a *App) MakeAuthenticatedGmailCall(ctx context.Context, fn GmailCall) error {
	if a.auth == nil {
		return ErrNotAuthenticated
	}
	// Proactive refresh.
	a.auth.refresh.Lock()
	if err := a.auth.refreshIfNeededLocked(ctx); err != nil {
		a.auth.refresh.Unlock()
		if errors.Is(err, ErrInvalidGrant) {
			a.emitAuthChanged()
			a.SetTrayError("sign-in expired")
		}
		return err
	}
	token := a.auth.tokens.AccessToken
	a.auth.refresh.Unlock()

	status, err := fn(token)
	if err == nil && status != 401 {
		return nil
	}
	if status != 401 {
		return err
	}

	// Reactive: force refresh and retry once. We hold am.refresh across the
	// retry fn() call AND the classify-and-clear that follows, so no concurrent
	// caller can observe the stale access token between the refresh result and
	// the clear. The retry is bounded by fn's own HTTP timeout.
	a.auth.refresh.Lock()
	// Force refresh by backdating expiry.
	if a.auth.tokens != nil {
		a.auth.tokens.Expiry = time.Now().Add(-time.Minute)
	}
	if err := a.auth.refreshIfNeededLocked(ctx); err != nil {
		a.auth.refresh.Unlock()
		if errors.Is(err, ErrInvalidGrant) {
			a.emitAuthChanged()
			a.SetTrayError("sign-in expired")
		}
		return err
	}
	token = a.auth.tokens.AccessToken

	status, err = fn(token)
	if status == 401 {
		// Second 401 after fresh token — classify as invalid_grant path.
		// Clear while still holding the lock to close the race window.
		_ = a.auth.clearTokensLocked()
		a.auth.refresh.Unlock()
		a.emitAuthChanged()
		a.SetTrayError("sign-in expired")
		return ErrInvalidGrant
	}
	a.auth.refresh.Unlock()
	return err
}

// emitAuthChanged pushes the current Status() to the frontend.
func (a *App) emitAuthChanged() {
	if a.ctx == nil || a.auth == nil {
		return
	}
	wruntime.EventsEmit(a.ctx, "auth-changed", a.auth.Status())
}

// SignOut revokes the refresh token (best-effort, 5s), clears the keyring
// entry unconditionally, clears in-memory userinfo, and emits auth-changed.
// Does NOT quit the app (D-16) — watcher keeps running, tray stays.
//
// The revoke HTTP call is made under a.auth.refresh with a 5s bound
// (see revokeRefreshToken). Intentional: per D-07 UI disables draft-
// creating buttons while signing out, so no other caller can contend for
// this mutex; holding it across revoke prevents any partial-state window.
func (a *App) SignOut() error {
	if a.auth == nil {
		return errors.New("auth manager not initialized")
	}
	// Use a background context as fallback when a.ctx is nil (e.g. in tests
	// without a live Wails runtime). revokeRefreshToken applies its own 5s timeout.
	ctx := a.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	a.auth.refresh.Lock()
	a.auth.revokeRefreshToken(ctx) // best-effort; logs on failure; 5s bounded
	a.auth.tokens = nil
	a.auth.email = ""
	a.auth.name = ""
	_ = a.auth.keyring.Delete(keyringService, keyringUser) // ignore ErrNotFound
	a.auth.refresh.Unlock()

	a.emitAuthChanged()
	a.SetTrayError("signed out")
	logInfo("oauth: sign-out complete")
	return nil
}

// bootstrapAuth loads any persisted tokens, triggers a proactive refresh if
// needed, and emits the initial auth-changed event. Runs under App.startup.
// On invalid_grant or any keyring error, proceeds as signed-out.
// Safe to call once per startup.
//
// Returns a channel that is closed when the async userinfo fetch goroutine
// completes so callers (tests) can wait deterministically. Production callers
// MAY discard the channel; discarding a receive-only channel is valid Go.
//
// WR-02 (2026-04-19): prior to this change, bootstrapAuth spawned a
// fire-and-forget goroutine that leaked under -race in TestBootstrapAuth*
// tests because tests exited before the goroutine contacted the real Google
// userinfo endpoint. The returned channel lets tests stub userinfoEndpointOverride
// and wait with a timeout select instead of relying on process-exit timing.
func (a *App) bootstrapAuth() <-chan struct{} {
	done := make(chan struct{})
	if a.auth == nil {
		close(done)
		return done
	}
	if err := a.auth.LoadFromKeyring(); err != nil {
		logError("oauth bootstrap: keyring load: %v", err)
		a.SetTrayError("credential store unavailable")
		a.emitAuthChanged()
		close(done)
		return done
	}
	if a.auth.tokens == nil {
		logInfo("oauth bootstrap: no tokens, signed-out state")
		a.SetTrayError("sign in required")
		a.emitAuthChanged()
		close(done)
		return done
	}
	// Proactive refresh if within 5 minutes of expiry.
	a.auth.refresh.Lock()
	err := a.auth.refreshIfNeededLocked(a.ctx)
	a.auth.refresh.Unlock()
	if errors.Is(err, ErrInvalidGrant) {
		logInfo("oauth bootstrap: invalid_grant — prompting re-sign-in")
		a.SetTrayError("sign-in expired")
		a.emitAuthChanged()
		close(done)
		return done
	}
	if err != nil {
		// Transient: keep tokens (refreshIfNeededLocked did not clear them),
		// surface as signed-in with a warning log. First Gmail call will retry.
		logError("oauth bootstrap: refresh deferred: %v", err)
	}
	// Tokens present and valid (or transient-error kept) — tray should show idle
	// regardless of the async userinfo fetch outcome.
	a.SetTrayIdle("watching for emails")
	logInfo("oauth bootstrap: signed in, token expires %s", a.auth.tokens.Expiry.Format(time.RFC3339))
	// Kick off async userinfo fetch and emit auth-changed ONCE after it settles.
	// We deliberately do NOT emit synchronously here — a pre-userinfo emission
	// would flash an authenticated header with empty email/name. The Svelte
	// frontend renders the queue view from the initial GetAuthStatus() pull
	// on mount, and updates email/name via this single async emit.
	// The returned done channel is closed when the goroutine completes (WR-02).
	go func() {
		defer close(done)
		a.auth.refresh.Lock()
		a.auth.fetchUserInfoLocked(a.ctx)
		a.auth.refresh.Unlock()
		a.emitAuthChanged()    // single emission, email/name populated
		a.signalTrayRefresh() // tray reads SignedIn from auth.Status() — refresh after auth settles
	}()
	return done
}
