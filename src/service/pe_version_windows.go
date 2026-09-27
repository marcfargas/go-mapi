//go:build windows

package service

import (
	"debug/pe"
	"errors"
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

func verifyInstalledPEMachine(path string, machine uint16) error {
	file, err := pe.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	if file.FileHeader.Machine != machine {
		return errors.New("installed PE architecture does not match machine package")
	}
	return nil
}

var (
	versionLibrary  = windows.NewLazySystemDLL("version.dll")
	versionInfoSize = versionLibrary.NewProc("GetFileVersionInfoSizeW")
	versionInfoRead = versionLibrary.NewProc("GetFileVersionInfoW")
	versionQuery    = versionLibrary.NewProc("VerQueryValueW")
)

// installedPEProductVersion reads the version resource of fixed installed
// bytes; registry markers and executing a candidate are not version proof.
func installedPEProductVersion(path string) (string, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return "", err
	}
	size, _, callErr := versionInfoSize.Call(uintptr(unsafe.Pointer(name)), 0)
	if size == 0 || size > 4<<20 {
		return "", fmt.Errorf("read PE version size: %w", callErr)
	}
	data := make([]byte, size)
	ok, _, callErr := versionInfoRead.Call(uintptr(unsafe.Pointer(name)), 0, size, uintptr(unsafe.Pointer(&data[0])))
	if ok == 0 {
		return "", fmt.Errorf("read PE version: %w", callErr)
	}
	translationKey, _ := windows.UTF16PtrFromString(`\VarFileInfo\Translation`)
	var value *uint16
	var length uint32
	ok, _, callErr = versionQuery.Call(uintptr(unsafe.Pointer(&data[0])), uintptr(unsafe.Pointer(translationKey)), uintptr(unsafe.Pointer(&value)), uintptr(unsafe.Pointer(&length)))
	if ok == 0 || value == nil || length == 0 || length > 256 || length%4 != 0 {
		return "", fmt.Errorf("query PE version translations: %w", callErr)
	}
	keys, err := productVersionQueryKeys(unsafe.Slice((*byte)(unsafe.Pointer(value)), int(length)))
	if err != nil {
		return "", err
	}
	var version string
	for _, key := range keys {
		query, _ := windows.UTF16PtrFromString(key)
		value = nil
		length = 0
		ok, _, callErr = versionQuery.Call(uintptr(unsafe.Pointer(&data[0])), uintptr(unsafe.Pointer(query)), uintptr(unsafe.Pointer(&value)), uintptr(unsafe.Pointer(&length)))
		if ok == 0 || value == nil || length == 0 || length > 256 {
			return "", fmt.Errorf("query PE ProductVersion for %s: %w", key, callErr)
		}
		chars := unsafe.Slice(value, int(length))
		if chars[len(chars)-1] != 0 {
			return "", errors.New("PE ProductVersion is not terminated")
		}
		for _, ch := range chars[:len(chars)-1] {
			if ch == 0 {
				return "", errors.New("PE ProductVersion has an embedded terminator")
			}
		}
		found := windows.UTF16ToString(chars)
		if found == "" {
			return "", errors.New("PE ProductVersion is empty")
		}
		if version != "" && found != version {
			return "", errors.New("PE ProductVersion differs across declared translations")
		}
		version = found
	}
	return version, nil
}
