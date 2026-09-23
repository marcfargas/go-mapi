//go:build windows

package service

import (
	"errors"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

const serviceAccountName = `NT SERVICE\` + ServiceName

type windowsStoragePlatform struct{}

func newStoragePlatform() storagePlatform { return windowsStoragePlatform{} }

func (windowsStoragePlatform) ensureRoot(root string, access storageAccess) error {
	if err := os.MkdirAll(root, 0700); err != nil {
		return err
	}
	serviceSID, _, _, err := windows.LookupSID("", serviceAccountName)
	if err != nil {
		return errors.New("resolve resident service identity")
	}
	sddl, err := storageSDDL(serviceSID.String(), access)
	if err != nil {
		return err
	}
	descriptor, err := windows.SecurityDescriptorFromString(sddl)
	if err != nil {
		return errors.New("build protected storage ACL")
	}
	dacl, _, err := descriptor.DACL()
	if err != nil {
		return errors.New("read protected storage ACL")
	}
	systemSID, err := windows.CreateWellKnownSid(windows.WinLocalSystemSid)
	if err != nil {
		return errors.New("resolve LocalSystem identity")
	}
	if err := windows.SetNamedSecurityInfo(root, windows.SE_FILE_OBJECT,
		windows.OWNER_SECURITY_INFORMATION|windows.GROUP_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		systemSID, systemSID, dacl, nil); err != nil {
		return errors.New("apply protected storage ACL")
	}
	return nil
}

func (windowsStoragePlatform) checkPath(root, path string, mustExist bool) error {
	relative, err := filepath.Rel(root, path)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return errors.New("protected path escapes root")
	}
	current := root
	parts := []string{}
	if relative != "." {
		parts = splitWindowsPath(relative)
	}
	paths := append([]string{root}, parts...)
	for index, part := range paths {
		if index > 0 {
			current = filepath.Join(current, part)
		}
		pointer, err := windows.UTF16PtrFromString(current)
		if err != nil {
			return err
		}
		attributes, err := windows.GetFileAttributes(pointer)
		if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) || errors.Is(err, windows.ERROR_PATH_NOT_FOUND) {
			if !mustExist && index == len(paths)-1 {
				return nil
			}
			return err
		}
		if err != nil {
			return err
		}
		if attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return errors.New("protected path traverses a reparse point")
		}
	}
	return nil
}

func splitWindowsPath(path string) []string {
	return strings.FieldsFunc(path, func(character rune) bool { return character == '\\' || character == '/' })
}

func (windowsStoragePlatform) replace(source, destination string) error {
	sourcePointer, err := windows.UTF16PtrFromString(source)
	if err != nil {
		return err
	}
	destinationPointer, err := windows.UTF16PtrFromString(destination)
	if err != nil {
		return err
	}
	return windows.MoveFileEx(sourcePointer, destinationPointer, windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH)
}

func (windowsStoragePlatform) syncDirectory(path string) error {
	pointer, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	handle, err := windows.CreateFile(pointer, windows.GENERIC_READ, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(handle)
	if err := windows.FlushFileBuffers(handle); err != nil && !errors.Is(err, windows.ERROR_INVALID_FUNCTION) {
		return err
	}
	return nil
}
