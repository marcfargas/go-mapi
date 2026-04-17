//go:build bindings

package main

// checkOAuthCredentials is a no-op under the `bindings` build tag.
// The wailsbindings.exe binary only introspects types and method signatures —
// it never opens a browser or calls Google — so real OAuth credentials are
// not needed and the D-10 guard must not abort the process.
func checkOAuthCredentials() {}
