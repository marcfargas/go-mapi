//go:build !bindings

package main

import "errors"

// checkOAuthCredentials is the D-10 fatal guard — run on every normal startup
// (production, wails dev) but skipped under the `bindings` build tag so that
// `wails build` / `wails generate module` can regenerate TypeScript bindings
// without real credentials being present in the dev environment.
//
// Returns a non-nil error if the OAuth client_id or client_secret is empty
// (indicating the -ldflags / env var injection was not wired correctly).
// Callers — specifically main.go — decide how to react (log + os.Exit);
// returning an error instead of exiting directly makes this testable.
func checkOAuthCredentials() error {
	if oauthClientID == "" {
		return errors.New("OAuth client_id missing — build was not wired correctly (expected -ldflags -X main.oauthClientID, or GOMAPI_OAUTH_CLIENT_ID env var for wails dev)")
	}
	if oauthClientSecret == "" {
		return errors.New("OAuth client_secret missing — build was not wired correctly (expected -ldflags -X main.oauthClientSecret, or GOMAPI_OAUTH_CLIENT_SECRET env var for wails dev)")
	}
	return nil
}
