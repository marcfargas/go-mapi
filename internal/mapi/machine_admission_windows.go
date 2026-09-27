//go:build windows

package mapi

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const machineAdmissionWait = 250 * time.Millisecond

func machineAdmissionPath() (string, error) {
	root, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, windows.KF_FLAG_DEFAULT)
	if err != nil || !filepath.IsAbs(root) {
		return "", ErrMachineAdmissionClosed
	}
	return filepath.Join(root, "go-mapi", "status", MachineAdmissionFileName), nil
}

func withMachineAdmission(ctx context.Context, fn func() error) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	path, err := machineAdmissionPath()
	if err != nil {
		return false, err
	}
	if err := verifyAdmissionPath(path); err != nil {
		return false, fmt.Errorf("unsafe machine admission path: %w", err)
	}
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return false, ErrMachineAdmissionClosed
	}
	handle, err := windows.CreateFile(name, windows.GENERIC_READ, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return false, fmt.Errorf("open machine admission: %w", err)
	}
	file := os.NewFile(uintptr(handle), path)
	defer file.Close()
	if err := verifyAdmissionFile(path, file); err != nil {
		return false, err
	}
	var overlap windows.Overlapped
	deadline := time.Now().Add(machineAdmissionWait)
	for {
		if err := ctx.Err(); err != nil {
			return false, err
		}
		err = windows.LockFileEx(handle, windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlap)
		if err == nil {
			break
		}
		if !errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
			return false, fmt.Errorf("lock machine admission: %w", err)
		}
		if !time.Now().Before(deadline) {
			return false, ErrMachineAdmissionClosed
		}
		pause := 10 * time.Millisecond
		if left := time.Until(deadline); left < pause {
			pause = left
		}
		timer := time.NewTimer(pause)
		select {
		case <-ctx.Done():
			timer.Stop()
			return false, ctx.Err()
		case <-timer.C:
		}
	}
	defer windows.UnlockFileEx(handle, 0, 1, 0, &overlap)
	if err := verifyAdmissionFile(path, file); err != nil {
		return false, err
	}
	info, err := file.Stat()
	if err != nil || info.Size() != 1 {
		return false, ErrMachineAdmissionClosed
	}
	var data [1]byte
	if _, err = file.ReadAt(data[:], 0); err != nil {
		return false, fmt.Errorf("read machine admission: %w", err)
	}
	open, err := validMachineAdmissionByte(data[:])
	if err != nil || !open || fn == nil {
		return open, err
	}
	return true, fn()
}

func verifyAdmissionPath(path string) error {
	root, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, windows.KF_FLAG_DEFAULT)
	if err != nil {
		return err
	}
	expected := filepath.Join(root, "go-mapi", "status", MachineAdmissionFileName)
	if !strings.EqualFold(filepath.Clean(path), filepath.Clean(expected)) {
		return ErrMachineAdmissionClosed
	}
	for _, dir := range []string{root, filepath.Join(root, "go-mapi"), filepath.Join(root, "go-mapi", "status")} {
		pointer, err := windows.UTF16PtrFromString(dir)
		if err != nil {
			return err
		}
		attr, err := windows.GetFileAttributes(pointer)
		if err != nil {
			return err
		}
		if attr&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 || attr&windows.FILE_ATTRIBUTE_DIRECTORY == 0 {
			return ErrMachineAdmissionClosed
		}
		if dir != root {
			if err := verifyAdmissionACL(dir); err != nil {
				return err
			}
		}
	}
	return verifyAdmissionACL(path)
}

func verifyAdmissionFile(path string, file *os.File) error {
	if err := verifyAdmissionPath(path); err != nil {
		return err
	}
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() {
		return ErrMachineAdmissionClosed
	}
	named, err := os.Lstat(path)
	if err != nil || !os.SameFile(opened, named) {
		return ErrMachineAdmissionClosed
	}
	return nil
}

func verifyAdmissionACL(path string) error {
	pointer, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	attr, err := windows.GetFileAttributes(pointer)
	if err != nil || attr&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return ErrMachineAdmissionClosed
	}
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	owner, _, err := sd.Owner()
	if err != nil || owner == nil {
		return ErrMachineAdmissionClosed
	}
	ownerID := owner.String()
	if ownerID != "S-1-5-18" && ownerID != "S-1-5-32-544" {
		return ErrMachineAdmissionClosed
	}
	dacl, _, err := sd.DACL()
	if err != nil || dacl == nil {
		return ErrMachineAdmissionClosed
	}
	const fileDeleteChild = 0x00000040
	const writeMask = windows.FILE_WRITE_DATA | windows.FILE_APPEND_DATA | windows.FILE_WRITE_EA | windows.FILE_WRITE_ATTRIBUTES | fileDeleteChild | windows.DELETE | windows.WRITE_DAC | windows.WRITE_OWNER | windows.GENERIC_WRITE | windows.GENERIC_ALL
	for i := uint32(0); i < uint32(dacl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(dacl, i, &ace); err != nil {
			return err
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			if ace.Header.AceType != windows.ACCESS_DENIED_ACE_TYPE {
				return ErrMachineAdmissionClosed
			}
			continue
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()
		if ace.Mask&writeMask != 0 && sid != "S-1-5-18" && sid != "S-1-5-32-544" && !strings.HasPrefix(sid, "S-1-5-80-") {
			return ErrMachineAdmissionClosed
		}
	}
	return nil
}
