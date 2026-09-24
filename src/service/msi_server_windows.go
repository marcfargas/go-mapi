//go:build windows

package service

import (
	"context"
	"errors"
	"fmt"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

// WindowsInstallerServerProbe combines the documented MSI execute mutex with
// msiserver's status. It observes but never creates or retains the MSI mutex.
type WindowsInstallerServerProbe struct{}

func (WindowsInstallerServerProbe) Idle(ctx context.Context, requireStopped bool) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	manager, err := mgr.Connect()
	if err != nil {
		return false, err
	}
	defer manager.Disconnect()
	server, err := manager.OpenService("msiserver")
	if err != nil {
		return false, err
	}
	defer server.Close()
	status, err := server.Query()
	if err != nil {
		return false, err
	}
	if status.State != svc.Stopped {
		if requireStopped || status.State != svc.Running || status.Accepts&svc.AcceptShutdown == 0 {
			return false, nil
		}
	}
	name, err := windows.UTF16PtrFromString(`Global\_MSIExecute`)
	if err != nil {
		return false, err
	}
	const mutexModifyState = 0x0001
	mutex, err := windows.OpenMutex(windows.SYNCHRONIZE|mutexModifyState, false, name)
	if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) {
		return true, nil
	}
	if err != nil {
		return false, fmt.Errorf("open MSI execute mutex: %w", err)
	}
	defer windows.CloseHandle(mutex)
	wait, err := windows.WaitForSingleObject(mutex, 0)
	if err != nil {
		return false, err
	}
	switch wait {
	case uint32(windows.WAIT_TIMEOUT):
		return false, nil
	case windows.WAIT_OBJECT_0, windows.WAIT_ABANDONED:
		if err := windows.ReleaseMutex(mutex); err != nil {
			return false, err
		}
		return true, nil
	default:
		return false, fmt.Errorf("unexpected MSI mutex status %d", wait)
	}
}
