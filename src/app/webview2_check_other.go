//go:build !windows && !bindings

package main

// WebView2 is a Windows runtime concern. Non-Windows builds exercise the
// user-component logic without requiring a desktop shell.
func checkWebView2() error { return nil }

func showWebView2MissingDialog() {}
