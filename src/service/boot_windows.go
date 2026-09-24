//go:build windows

package service

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const volatileBootKey = `SOFTWARE\go-mapi\MachineProduct\ServiceBoot`

var regCreateKeyExW = windows.NewLazySystemDLL("advapi32.dll").NewProc("RegCreateKeyExW")

// WindowsBootIdentity is a machine-protected, volatile HKLM key. Windows
// discards the key at reboot, while a service replacement observes the same ID.
type WindowsBootIdentity struct{}

func (WindowsBootIdentity) CurrentBootID(ctx context.Context) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	name, err := windows.UTF16PtrFromString(volatileBootKey)
	if err != nil {
		return "", err
	}
	descriptor, err := windows.SecurityDescriptorFromString("O:SYG:SYD:P(A;;KA;;;SY)(A;;KA;;;BA)")
	if err != nil {
		return "", errors.New("build volatile service boot key ACL")
	}
	security := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: descriptor}
	var key windows.Handle
	var disposition uint32
	const regOptionVolatile = 1
	rc, _, _ := regCreateKeyExW.Call(uintptr(registry.LOCAL_MACHINE), uintptr(unsafe.Pointer(name)), 0, 0,
		regOptionVolatile, uintptr(registry.QUERY_VALUE|registry.SET_VALUE|windows.READ_CONTROL|registry.WOW64_64KEY), uintptr(unsafe.Pointer(&security)),
		uintptr(unsafe.Pointer(&key)), uintptr(unsafe.Pointer(&disposition)))
	if rc != 0 {
		return "", fmt.Errorf("open volatile service boot key: %w", windows.Errno(rc))
	}
	defer windows.RegCloseKey(key)
	if err := verifyVolatileBootKeyACL(key); err != nil {
		return "", err
	}
	boot := registry.Key(key)
	if disposition == 1 {
		var value [16]byte
		if _, err := rand.Read(value[:]); err != nil {
			return "", err
		}
		id := hex.EncodeToString(value[:])
		if err := boot.SetStringValue("ID", id); err != nil {
			return "", err
		}
		return id, nil
	}
	id, _, err := boot.GetStringValue("ID")
	if err != nil {
		return "", err
	}
	decoded, err := hex.DecodeString(id)
	if err != nil || len(decoded) != 16 {
		return "", errors.New("invalid volatile service boot identity")
	}
	return id, nil
}

func verifyVolatileBootKeyACL(key windows.Handle) error {
	sd, err := windows.GetSecurityInfo(key, windows.SE_REGISTRY_KEY, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	owner, _, err := sd.Owner()
	if err != nil || owner == nil || (owner.String() != "S-1-5-18" && owner.String() != "S-1-5-32-544") {
		return errors.New("volatile service boot key has untrusted owner")
	}
	dacl, _, err := sd.DACL()
	if err != nil || dacl == nil {
		return errors.New("volatile service boot key lacks a DACL")
	}
	const writeMask = windows.KEY_SET_VALUE | windows.KEY_CREATE_SUB_KEY | windows.DELETE | windows.WRITE_DAC | windows.WRITE_OWNER | windows.GENERIC_WRITE | windows.GENERIC_ALL
	for i := uint32(0); i < uint32(dacl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(dacl, i, &ace); err != nil {
			return err
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			if ace.Header.AceType != windows.ACCESS_DENIED_ACE_TYPE {
				return errors.New("volatile service boot key has unsupported ACL entry")
			}
			continue
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()
		if ace.Mask&writeMask != 0 && sid != "S-1-5-18" && sid != "S-1-5-32-544" {
			return errors.New("volatile service boot key grants untrusted write access")
		}
	}
	return nil
}
