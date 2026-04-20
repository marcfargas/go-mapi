//go:build bindings

package main

// checkWebView2 is a no-op under the `bindings` build tag.
// The wailsbindings.exe binary only introspects types and method
// signatures — it never touches WebView2 — so the D-08 guard must not
// abort the process. Returns nil to match the signature in webview2_check.go.
func checkWebView2() error { return nil }

// showWebView2MissingDialog is a no-op under the `bindings` build tag.
// Matches the signature in webview2_check.go so both files compile cleanly
// regardless of tag.
func showWebView2MissingDialog() {}
