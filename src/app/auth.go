package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os/exec"
	"sync"
	"time"

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

// OAuth scopes (D-17 userinfo + AUTH-01 gmail).
const (
	scopeGmailCompose    = "https://www.googleapis.com/auth/gmail.compose"
	scopeGmailSend       = "https://www.googleapis.com/auth/gmail.send"
	scopeUserinfoEmail   = "https://www.googleapis.com/auth/userinfo.email"
	scopeUserinfoProfile = "https://www.googleapis.com/auth/userinfo.profile"
	userinfoEndpoint     = "https://www.googleapis.com/oauth2/v3/userinfo"
	loopbackFlowTimeout  = 5 * time.Minute // Claude discretion per CONTEXT
)

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
}

// NewAuthManager constructs a fresh, signed-out AuthManager.
func NewAuthManager() *AuthManager {
	return &AuthManager{}
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

	raw, err := keyring.Get(keyringService, keyringUser)
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
	if err := keyring.Set(keyringService, keyringUser, string(data)); err != nil {
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

// ClearTokens wipes in-memory state AND the keyring entry. keyring.ErrNotFound
// on Delete is swallowed (signing out twice is a no-op — D-12).
func (am *AuthManager) ClearTokens() error {
	am.refresh.Lock()
	defer am.refresh.Unlock()
	am.tokens = nil
	am.email = ""
	am.name = ""
	if err := keyring.Delete(keyringService, keyringUser); err != nil && !errors.Is(err, keyring.ErrNotFound) {
		return fmt.Errorf("keyring delete: %w", err)
	}
	return nil
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

// openBrowser launches the user's default browser via rundll32 (D-02, AUTH-02).
// Start() is intentional — the browser is a separate detached process.
func openBrowser(authURL string) error {
	cmd := exec.Command("rundll32", "url.dll,FileProtocolHandler", authURL)
	return cmd.Start()
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
	req, err := http.NewRequestWithContext(ctx, "GET", userinfoEndpoint, nil)
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
	// Emit auth-changed so the Svelte frontend drops the welcome screen.
	wruntime.EventsEmit(a.ctx, "auth-changed", AuthStatus{
		Authenticated: true,
		Email:         a.auth.email,
		Name:          a.auth.name,
	})
	return nil
}

// SignOut revokes + clears tokens. Stub — Plan 04 implements the full D-15 path.
func (a *App) SignOut() error {
	if a.auth == nil {
		return errors.New("auth manager not initialized")
	}
	return errors.New("SignOut not implemented until Plan 04")
}
