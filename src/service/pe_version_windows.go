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
	key, _ := windows.UTF16PtrFromString(`\StringFileInfo\040904b0\ProductVersion`)
	var value *uint16
	var length uint32
	ok, _, callErr = versionQuery.Call(uintptr(unsafe.Pointer(&data[0])), uintptr(unsafe.Pointer(key)), uintptr(unsafe.Pointer(&value)), uintptr(unsafe.Pointer(&length)))
	if ok == 0 || value == nil || length == 0 || length > 256 {
		return "", fmt.Errorf("query PE ProductVersion: %w", callErr)
	}
	version := windows.UTF16PtrToString(value)
	if version == "" {
		return "", errors.New("PE ProductVersion is empty")
	}
	return version, nil
}
