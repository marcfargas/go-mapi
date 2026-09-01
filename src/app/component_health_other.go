//go:build !windows

package main

import "fmt"

func installedInterceptorManifestPath() (string, error) {
	return "", fmt.Errorf("Program Files known-folder lookup is only available on Windows")
}
func readPEProductVersion(string) (string, error) {
	return "", fmt.Errorf("PE metadata lookup is only available on Windows")
}
