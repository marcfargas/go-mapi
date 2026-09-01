//go:build windows

package main

import (
	"fmt"
	"path/filepath"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	shell32                     = windows.NewLazySystemDLL("shell32.dll")
	ole32                       = windows.NewLazySystemDLL("ole32.dll")
	versionDLL                  = windows.NewLazySystemDLL("version.dll")
	procSHGetKnownFolderPath    = shell32.NewProc("SHGetKnownFolderPath")
	procCoTaskMemFree           = ole32.NewProc("CoTaskMemFree")
	procGetFileVersionInfoSizeW = versionDLL.NewProc("GetFileVersionInfoSizeW")
	procGetFileVersionInfoW     = versionDLL.NewProc("GetFileVersionInfoW")
	procVerQueryValueW          = versionDLL.NewProc("VerQueryValueW")
)

var folderIDProgramFiles = windows.GUID{Data1: 0x905e63b6, Data2: 0xc1bf, Data3: 0x494e, Data4: [8]byte{0xb2, 0x9c, 0x65, 0xb7, 0x32, 0xd3, 0xd2, 0x1a}}

func installedInterceptorManifestPath() (string, error) {
	var raw *uint16
	hr, _, _ := procSHGetKnownFolderPath.Call(uintptr(unsafe.Pointer(&folderIDProgramFiles)), 0, 0, uintptr(unsafe.Pointer(&raw)))
	if int32(hr) < 0 || raw == nil {
		return "", fmt.Errorf("resolve FOLDERID_ProgramFiles: HRESULT 0x%x", uint32(hr))
	}
	defer procCoTaskMemFree.Call(uintptr(unsafe.Pointer(raw)))
	return filepath.Join(windows.UTF16PtrToString(raw), "go-mapi", "interceptor", installedInterceptorName), nil
}

func readPEProductVersion(path string) (string, error) {
	pathPtr, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return "", err
	}
	size, _, callErr := procGetFileVersionInfoSizeW.Call(uintptr(unsafe.Pointer(pathPtr)), 0)
	if size == 0 {
		return "", fmt.Errorf("GetFileVersionInfoSizeW: %w", callErr)
	}
	data := make([]byte, size)
	ok, _, callErr := procGetFileVersionInfoW.Call(uintptr(unsafe.Pointer(pathPtr)), 0, size, uintptr(unsafe.Pointer(&data[0])))
	if ok == 0 {
		return "", fmt.Errorf("GetFileVersionInfoW: %w", callErr)
	}
	productVersion, _ := syscall.UTF16PtrFromString("\\StringFileInfo\\040904b0\\ProductVersion")
	var value unsafe.Pointer
	var valueLen uint32
	ok, _, callErr = procVerQueryValueW.Call(uintptr(unsafe.Pointer(&data[0])), uintptr(unsafe.Pointer(productVersion)), uintptr(unsafe.Pointer(&value)), uintptr(unsafe.Pointer(&valueLen)))
	if ok == 0 || value == nil || valueLen == 0 {
		return "", fmt.Errorf("VerQueryValueW: %w", callErr)
	}
	return windows.UTF16PtrToString((*uint16)(value)), nil
}
