//go:build windows

package service

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/marcfargas/go-mapi/internal/mapi"
	"golang.org/x/sys/windows"
)

// SuiteAdmission owns the service-only writer side of the public byte. Its
// file identity is stable: opening or updating it never replaces the file.
type SuiteAdmission struct{ storage *ProtectedStorage }

var retainedUnsafeSuiteLocks struct {
	sync.Mutex
	locks []*suiteAdmissionLock
}

func NewSuiteAdmission(storage *ProtectedStorage) (*SuiteAdmission, error) {
	if storage == nil || storage.access != publicReadStorage {
		return nil, errors.New("suite admission requires public-read protected storage")
	}
	if _, err := storage.child(mapi.MachineAdmissionFileName); err != nil {
		return nil, err
	}
	return &SuiteAdmission{storage: storage}, nil
}

func (gate *SuiteAdmission) path() (string, error) {
	if gate == nil || gate.storage == nil {
		return "", errors.New("suite admission unavailable")
	}
	return gate.storage.child(mapi.MachineAdmissionFileName)
}

func (gate *SuiteAdmission) withExclusive(ctx context.Context, action func(*suiteAdmissionLock) error) error {
	path, err := gate.path()
	if err != nil {
		return err
	}
	if err = gate.storage.platform.checkPath(gate.storage.root, path, false); err != nil {
		return err
	}
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	handle, err := windows.CreateFile(name, windows.GENERIC_READ|windows.GENERIC_WRITE, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.CREATE_NEW, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	created := err == nil
	if errors.Is(err, windows.ERROR_FILE_EXISTS) || errors.Is(err, windows.ERROR_ALREADY_EXISTS) {
		handle, err = windows.CreateFile(name, windows.GENERIC_READ|windows.GENERIC_WRITE, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	}
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(handle), path)
	lock := &suiteAdmissionLock{file: file}
	defer func() {
		if lock.unsafe {
			retainedUnsafeSuiteLocks.Lock()
			retainedUnsafeSuiteLocks.locks = append(retainedUnsafeSuiteLocks.locks, lock)
			retainedUnsafeSuiteLocks.Unlock()
		} else {
			_ = file.Close()
		}
	}()
	if err = gate.validateFile(path, file); err != nil {
		return err
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		if err = ctx.Err(); err != nil {
			return err
		}
		err = windows.LockFileEx(handle, windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &lock.overlapped)
		if err == nil {
			break
		}
		if !errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
			return err
		}
		if !time.Now().Before(deadline) {
			return errors.New("suite admission lock busy")
		}
		pause := 25 * time.Millisecond
		if remaining := time.Until(deadline); remaining < pause {
			pause = remaining
		}
		timer := time.NewTimer(pause)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
	defer func() {
		if !lock.unsafe {
			_ = windows.UnlockFileEx(handle, 0, 1, 0, &lock.overlapped)
		}
	}()
	if err = gate.validateFile(path, file); err != nil {
		return err
	}
	if created {
		if err = lock.write('C'); err != nil {
			return fmt.Errorf("initialize closed suite admission: %w", err)
		}
	} else if _, readErr := lock.read(); readErr != nil {
		if err = lock.write('C'); err != nil {
			return fmt.Errorf("repair closed suite admission: %w", err)
		}
	}
	return action(lock)
}

func (gate *SuiteAdmission) validateFile(path string, file *os.File) error {
	if err := gate.storage.platform.checkPath(gate.storage.root, path, true); err != nil {
		return err
	}
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() {
		return errors.New("suite admission is not a regular protected file")
	}
	named, err := os.Lstat(path)
	if err != nil || !os.SameFile(opened, named) {
		return errors.New("suite admission file identity changed")
	}
	if filepath.Clean(path) != filepath.Join(gate.storage.root, mapi.MachineAdmissionFileName) {
		return errors.New("suite admission path changed")
	}
	return verifySuiteAdmissionACL(path)
}

type suiteAdmissionLock struct {
	file       *os.File
	overlapped windows.Overlapped
	unsafe     bool
}

func (lock *suiteAdmissionLock) read() (byte, error) {
	info, err := lock.file.Stat()
	if err != nil {
		return 0, err
	}
	if info.Size() != 1 {
		return 0, errors.New("malformed suite admission byte")
	}
	var b [1]byte
	_, err = lock.file.ReadAt(b[:], 0)
	if err != nil {
		return 0, err
	}
	if b[0] != 'O' && b[0] != 'C' {
		return 0, errors.New("invalid suite admission byte")
	}
	return b[0], nil
}

func (lock *suiteAdmissionLock) write(value byte) error {
	unsafe, err := writeSuiteByte(lock.file, value)
	lock.unsafe = lock.unsafe || unsafe
	return err
}

func (gate *SuiteAdmission) Close(ctx context.Context) error {
	return gate.withExclusive(ctx, func(lock *suiteAdmissionLock) error { return lock.write('C') })
}

func (gate *SuiteAdmission) IsOpen(ctx context.Context) (bool, error) {
	var open bool
	err := gate.withExclusive(ctx, func(lock *suiteAdmissionLock) error { b, err := lock.read(); open = b == 'O'; return err })
	return open, err
}

func verifySuiteAdmissionACL(path string) error {
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	owner, _, err := sd.Owner()
	if err != nil || owner == nil {
		return errors.New("suite admission has no trusted owner")
	}
	ownerID := owner.String()
	if ownerID != "S-1-5-18" && ownerID != "S-1-5-32-544" {
		return errors.New("suite admission has untrusted owner")
	}
	dacl, _, err := sd.DACL()
	if err != nil || dacl == nil {
		return errors.New("suite admission lacks DACL")
	}
	const writeMask = windows.FILE_WRITE_DATA | windows.FILE_APPEND_DATA | windows.FILE_WRITE_EA | windows.FILE_WRITE_ATTRIBUTES | windows.DELETE | windows.WRITE_DAC | windows.WRITE_OWNER | windows.GENERIC_WRITE | windows.GENERIC_ALL
	for i := uint32(0); i < uint32(dacl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(dacl, i, &ace); err != nil {
			return err
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			if ace.Header.AceType != windows.ACCESS_DENIED_ACE_TYPE {
				return errors.New("suite admission has unsupported ACL entry")
			}
			continue
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()
		if ace.Mask&writeMask != 0 && sid != "S-1-5-18" && sid != "S-1-5-32-544" && !strings.HasPrefix(sid, "S-1-5-80-") {
			return errors.New("suite admission grants untrusted write access")
		}
	}
	return nil
}
