package main

import "os"

// Injected at build time via:
//   -ldflags "-X 'main.oauthClientID=...' -X 'main.oauthClientSecret=...'"
// `var` (not const) is REQUIRED — -X only overwrites string vars. Mirrors the
// pattern used for `Version` in main.go (line 15).
var (
	oauthClientID     = ""
	oauthClientSecret = ""
)

// init lets `wails dev` pick up credentials from environment variables
// (populated from .env.local via scripts/dev-wails.ps1) without requiring
// the developer to repeat the -ldflags dance each run. In release builds
// the env vars are unset and the -ldflags-injected values win.
//
// Per CONTEXT D-09, the env var names are the same as the GitHub secrets
// used by CI in Phase 10: GOMAPI_OAUTH_CLIENT_ID, GOMAPI_OAUTH_CLIENT_SECRET.
func init() {
	if v := os.Getenv("GOMAPI_OAUTH_CLIENT_ID"); v != "" {
		oauthClientID = v
	}
	if v := os.Getenv("GOMAPI_OAUTH_CLIENT_SECRET"); v != "" {
		oauthClientSecret = v
	}
}
