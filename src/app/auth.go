package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/zalando/go-keyring"
)

// Keyring service+user coordinates per CONTEXT D-11.
const (
	keyringService = "go-mapi"
	keyringUser    = "oauth-tokens"
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

// ---- Wails bindings on *App (D-19). Real implementations land in later plans. ----

// GetAuthStatus is called by the frontend on mount to render the
// welcome/sign-in screen vs the queue view. Never returns an error.
func (a *App) GetAuthStatus() AuthStatus {
	if a.auth == nil {
		return AuthStatus{Authenticated: false}
	}
	return a.auth.Status()
}

// SignIn launches the desktop OAuth flow. Stub — Plan 03 implements.
func (a *App) SignIn() error {
	if a.auth == nil {
		return errors.New("auth manager not initialized")
	}
	return errors.New("SignIn not implemented until Plan 03")
}

// SignOut revokes + clears tokens. Stub — Plan 04 implements the full D-15 path.
func (a *App) SignOut() error {
	if a.auth == nil {
		return errors.New("auth manager not initialized")
	}
	return errors.New("SignOut not implemented until Plan 04")
}
