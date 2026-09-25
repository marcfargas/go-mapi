//go:build windows

package main

import (
	"errors"
	"os"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

func updateDistributionChannel() string {
	channel, err := newHandoffPlatform().CurrentChannel()
	if err != nil {
		return "unknown"
	}
	if channel == channelStore || channel == channelStandalone || channel == channelMachine {
		return string(channel)
	}
	return "unknown"
}

func installedInterceptorUpdateVersion() string {
	path, err := installedInterceptorManifestPath()
	if err != nil {
		return "unknown"
	}
	data, err := osReadFile(path)
	if errors.Is(err, osErrNotExist) {
		return "absent"
	}
	if err != nil {
		return "unknown"
	}
	var manifest installedInterceptorManifest
	if decodeExactJSON(data, &manifest) != nil || !mapi.IsStrictReleaseVersion(manifest.Version) {
		return "unknown"
	}
	return manifest.Version
}

// These indirections keep platform/path cases testable without reading a real
// Program Files installation.
var osReadFile = func(path string) ([]byte, error) { return os.ReadFile(path) }
var osErrNotExist = os.ErrNotExist
