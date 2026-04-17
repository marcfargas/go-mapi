//go:build !bindings

package main

import "os"

// checkOAuthCredentials is the D-10 fatal guard — run on every normal startup
// (production, wails dev) but skipped under the `bindings` build tag so that
// `wails build` / `wails generate module` can regenerate TypeScript bindings
// without real credentials being present in the dev environment.
func checkOAuthCredentials() {
	if oauthClientID == "" || oauthClientSecret == "" {
		logError("FATAL: OAuth client credentials missing — build was not wired correctly (expected -ldflags -X main.oauthClientID / main.oauthClientSecret, or GOMAPI_OAUTH_CLIENT_ID / GOMAPI_OAUTH_CLIENT_SECRET env vars for wails dev)")
		os.Exit(1)
	}
}
