//go:build windows

package service

import (
	"errors"
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// verifyProtectedSuiteImage rejects a replaceable fixed EXE or ancestor. The
// ordinary installed-health checks still prove MSI/PE/registration identity.
func verifyProtectedSuiteImage(programFiles, path string) error {
	if err := newStoragePlatform().checkPath(programFiles, path, true); err != nil {
		return err
	}
	for _, candidate := range []string{programFiles, filepath.Join(programFiles, "go-mapi"), filepath.Join(programFiles, "go-mapi", "user"), path} {
		sd, err := windows.GetNamedSecurityInfo(candidate, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
		if err != nil {
			return err
		}
		owner, _, err := sd.Owner()
		if err != nil || owner == nil {
			return errors.New("suite image path lacks trusted owner")
		}
		ownerID := owner.String()
		if ownerID != "S-1-5-18" && ownerID != "S-1-5-32-544" && !strings.HasPrefix(ownerID, "S-1-5-80-") {
			return errors.New("suite image path has untrusted owner")
		}
		dacl, _, err := sd.DACL()
		if err != nil || dacl == nil {
			return errors.New("suite image path lacks DACL")
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
					return errors.New("suite image path has unsupported ACL entry")
				}
				continue
			}
			// An inherit-only CREATOR OWNER ACE does not grant write to this object.
			if ace.Header.AceFlags&windows.INHERIT_ONLY_ACE != 0 {
				continue
			}
			sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()
			if ace.Mask&writeMask != 0 && sid != "S-1-5-18" && sid != "S-1-5-32-544" && !strings.HasPrefix(sid, "S-1-5-80-") {
				return errors.New("suite image path grants untrusted write access")
			}
		}
	}
	return nil
}
