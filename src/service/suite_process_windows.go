//go:build windows

package service

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

type suiteInstance struct {
	handle   windows.Handle
	identity ProcessIdentity
	session  uint32
}

type suiteProcesses struct {
	path      string
	instances map[ProcessIdentity]suiteInstance
}

func newSuiteProcesses() (*suiteProcesses, error) {
	programFiles, err := windows.KnownFolderPath(windows.FOLDERID_ProgramFilesX64, windows.KF_FLAG_DEFAULT)
	if err != nil {
		return nil, err
	}
	path := filepath.Join(programFiles, "go-mapi", "user", "go-mapi.exe")
	// The fixed app and ancestors must remain the protected installed unit.
	if err := verifyProtectedSuiteImage(programFiles, path); err != nil {
		return nil, err
	}
	return &suiteProcesses{path: path, instances: make(map[ProcessIdentity]suiteInstance)}, nil
}

func (processes *suiteProcesses) Close() {
	for id, instance := range processes.instances {
		windows.CloseHandle(instance.handle)
		delete(processes.instances, id)
	}
}

func (processes *suiteProcesses) sweep() error {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(snapshot)
	entry := windows.ProcessEntry32{Size: uint32(unsafe.Sizeof(windows.ProcessEntry32{}))}
	if err := windows.Process32First(snapshot, &entry); err != nil {
		return err
	}
	seen := make(map[ProcessIdentity]bool)
	for {
		if strings.EqualFold(windows.UTF16ToString(entry.ExeFile[:]), "go-mapi.exe") {
			pid := entry.ProcessID
			handle, openErr := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.SYNCHRONIZE|windows.PROCESS_TERMINATE, false, pid)
			if errors.Is(openErr, windows.ERROR_INVALID_PARAMETER) { // exited between snapshot and handle open
			} else if openErr != nil {
				return fmt.Errorf("cannot identify same-name suite process %d: %w", pid, openErr)
			} else {
				var image [32768]uint16
				imageLen := uint32(len(image))
				queryErr := windows.QueryFullProcessImageName(handle, 0, &image[0], &imageLen)
				if queryErr != nil {
					windows.CloseHandle(handle)
					return fmt.Errorf("cannot identify same-name suite image %d: %w", pid, queryErr)
				}
				if equalWindowsPath(windows.UTF16ToString(image[:imageLen]), processes.path) {
					identity, idErr := processIdentity(handle, pid)
					if idErr != nil {
						windows.CloseHandle(handle)
						return idErr
					}
					var session uint32
					if err := windows.ProcessIdToSessionId(pid, &session); err != nil {
						windows.CloseHandle(handle)
						return err
					}
					seen[identity] = true
					if _, already := processes.instances[identity]; !already {
						processes.instances[identity] = suiteInstance{handle: handle, identity: identity, session: session}
						handle = 0
					}
				}
				if handle != 0 {
					windows.CloseHandle(handle)
				}
			}
		}
		err = windows.Process32Next(snapshot, &entry)
		if errors.Is(err, windows.ERROR_NO_MORE_FILES) {
			break
		}
		if err != nil {
			return err
		}
	}
	// Retain every exact handle until it signals. A process that exits during
	// a sweep is still confirmed through that retained identity.
	for id, instance := range processes.instances {
		state, err := windows.WaitForSingleObject(instance.handle, 0)
		if err != nil {
			return err
		}
		if state == windows.WAIT_OBJECT_0 {
			windows.CloseHandle(instance.handle)
			delete(processes.instances, id)
			continue
		}
		if !seen[id] {
			return fmt.Errorf("exact suite process %d disappeared without signalled exit", id.PID)
		}
	}
	return nil
}

func (processes *suiteProcesses) terminate() error {
	for _, instance := range processes.instances {
		state, err := windows.WaitForSingleObject(instance.handle, 0)
		if err != nil {
			return err
		}
		if state == windows.WAIT_OBJECT_0 {
			continue
		}
		if err := windows.TerminateProcess(instance.handle, 1); err != nil {
			state, waitErr := windows.WaitForSingleObject(instance.handle, 0)
			if waitErr != nil || state != windows.WAIT_OBJECT_0 {
				return fmt.Errorf("terminate exact suite process %d: %w", instance.identity.PID, err)
			}
		}
	}
	return nil
}

// drainSuiteProcesses uses one wall/monotonic bound for all sessions. It
// refuses MSI whenever a final sweep cannot prove every exact image exited.
func drainSuiteProcesses(ctx context.Context, graceEnd, forceEnd time.Time) error {
	processes, err := newSuiteProcesses()
	if err != nil {
		return err
	}
	defer processes.Close()
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := processes.sweep(); err != nil {
			return err
		}
		if len(processes.instances) == 0 {
			// A second sweep catches a process scheduled across the first.
			if err := processes.sweep(); err != nil {
				return err
			}
			if len(processes.instances) == 0 {
				return nil
			}
		}
		if !time.Now().Before(forceEnd) {
			return errors.New("suite processes did not exit within force-confirmation bound")
		}
		if !time.Now().Before(graceEnd) {
			if err := processes.terminate(); err != nil {
				return err
			}
		}
		wait := 50 * time.Millisecond
		if remaining := time.Until(forceEnd); remaining < wait {
			wait = remaining
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}
