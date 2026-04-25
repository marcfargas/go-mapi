//go:build bindings

package main

import "context"

// runSilentUpdate is a no-op stub used only when wailsbindings.exe runs the
// binary with the `bindings` build tag to introspect App method signatures.
// The real implementation lives in updates_silent.go (//go:build windows && !bindings).
// RESEARCH §Pitfall 7: keep wailsbindings.exe out of the os.Exit path.
func runSilentUpdate(_ context.Context) int { return 0 }
