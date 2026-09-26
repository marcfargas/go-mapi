//go:build !windows

package service

import (
	"context"
	"errors"
	"testing"
)

func TestWindowsInstallerInventoryFailsExplicitlyOffWindows(t *testing.T) {
	_, err := NewWindowsInstallerInventory().Installed(context.Background())
	if !errors.Is(err, ErrWindowsInstallerUnavailable) {
		t.Fatalf("Installed error = %v", err)
	}
}
