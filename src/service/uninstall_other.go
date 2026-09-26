//go:build !windows

package service

import "errors"

func RunFinalUninstallFence(ExecutableMode) error {
	return errors.New("machine uninstall fence requires Windows")
}
