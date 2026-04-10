package main

// Version is the native host version string.
// Set at build time via -ldflags "-X main.Version=..." from the root package.json.
// Falls back to "0.0.0-dev" for local development builds.
var Version = "0.0.0-dev"
