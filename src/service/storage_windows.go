//go:build windows

package service

import (
	"errors"
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

const serviceAccountName = `NT SERVICE\` + ServiceName

type windowsStoragePlatform struct{}

func newStoragePlatform() storagePlatform { return windowsStoragePlatform{} }

func (windowsStoragePlatform) ensureRoot(root string, access storageAccess) error {
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
	// The shared parent must permit traversal to the public status child, but
	// no ordinary user may create or replace a child beneath it.
	base := filepath.Dir(root)
	baseSDDL := "O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;" + serviceSID.String() + ")(A;OICI;GRGX;;;BU)"
	baseDescriptor, err := windows.SecurityDescriptorFromString(baseSDDL)
	if err != nil {
		return errors.New("build protected storage parent ACL")
	}
	if err := rejectReparseAncestors(filepath.Dir(base)); err != nil {
		return err
	}
	if err := createOrVerifyProtectedDirectory(base, baseDescriptor, serviceSID.String()); err != nil {
		return err
	}
	if err := createOrVerifyProtectedDirectory(root, descriptor, serviceSID.String()); err != nil {
		return err
	}
	return nil
}

func rejectReparseAncestors(path string) error {
	for current := filepath.Clean(path); ; current = filepath.Dir(current) {
		name, err := windows.UTF16PtrFromString(current)
		if err != nil {
			return err
		}
		attributes, err := windows.GetFileAttributes(name)
		if err != nil {
			return err
		}
		if attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 || attributes&windows.FILE_ATTRIBUTE_DIRECTORY == 0 {
			return errors.New("protected storage ancestor is a reparse point or non-directory")
		}
		if parent := filepath.Dir(current); parent == current {
			return nil
		}
	}
}

func createOrVerifyProtectedDirectory(path string, descriptor *windows.SECURITY_DESCRIPTOR, serviceSID string) error {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	attributes, err := windows.GetFileAttributes(name)
	if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) || errors.Is(err, windows.ERROR_PATH_NOT_FOUND) {
		security := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: descriptor}
		if createErr := windows.CreateDirectory(name, &security); createErr != nil && !errors.Is(createErr, windows.ERROR_ALREADY_EXISTS) {
			return createErr
		}
	} else if err != nil {
		return err
	} else if attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 || attributes&windows.FILE_ATTRIBUTE_DIRECTORY == 0 {
		return errors.New("protected storage path is a reparse point or non-directory")
	}
	return verifyProtectedDirectoryACL(path, serviceSID)
}

func verifyProtectedDirectoryACL(path, serviceSID string) error {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	attributes, err := windows.GetFileAttributes(name)
	if err != nil || attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 || attributes&windows.FILE_ATTRIBUTE_DIRECTORY == 0 {
		return errors.New("protected storage directory changed during ACL check")
	}
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	owner, _, err := sd.Owner()
	if err != nil || owner == nil || (owner.String() != "S-1-5-18" && owner.String() != "S-1-5-32-544") {
		return errors.New("protected storage directory has untrusted owner")
	}
	dacl, _, err := sd.DACL()
	if err != nil || dacl == nil {
		return errors.New("protected storage directory lacks a DACL")
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
				return errors.New("protected storage directory has unsupported ACL entry")
			}
			continue
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()
		if ace.Mask&writeMask != 0 && sid != "S-1-5-18" && sid != "S-1-5-32-544" && sid != serviceSID {
			return errors.New("protected storage directory grants write access outside service administrators")
		}
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
	// replace uses MOVEFILE_WRITE_THROUGH, which does not return until the move
	// has reached disk. Unlike Unix, Windows does not offer a portable
	// FlushFileBuffers contract for directory handles.
	return nil
}
