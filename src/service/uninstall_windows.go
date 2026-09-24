//go:build windows

package service

import (
	"context"
	"errors"

	"golang.org/x/sys/windows"
)

func RunFinalUninstallFence(mode ExecutableMode) error {
	programData, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, windows.KF_FLAG_DEFAULT)
	if err != nil {
		return err
	}
	paths, err := NewProgramDataPaths(programData)
	if err != nil {
		return err
	}
	storage, err := NewProtectedStorage(paths.Service)
	if err != nil {
		return err
	}
	state, err := NewFileStateStore(storage)
	if err != nil {
		return err
	}
	switch mode {
	case ModeBeginFinalUninstall:
		// MSI already owns installer serialization. Refuse promptly if a runner
		// owns its transaction instead of waiting for that runner inside MSI.
		runnerLock, err := tryOwnRunnerLock(storage)
		if err != nil {
			return err
		}
		defer runnerLock.Close()
		return state.BeginFinalUninstall(context.Background())
	case ModeRollbackFinalUninstall:
		return state.RollbackFinalUninstall()
	default:
		return errors.New("invalid final uninstall fence mode")
	}
}
