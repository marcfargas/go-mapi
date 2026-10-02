//go:build !windows

package mapi

import "path/filepath"

// resolveFinalPath returns path with every symbolic link resolved.
func resolveFinalPath(path string) (string, error) {
	return filepath.EvalSymlinks(path)
}
