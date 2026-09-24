//go:build windows

package service

import (
	"errors"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// pinVerifiedFile prevents replacement or modification of the named bytes
// while a verifier and the process creation boundary use that same path.
func pinVerifiedFile(path string) (func(), error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("verified file path must be absolute")
	}
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateFile(name, windows.GENERIC_READ, windows.FILE_SHARE_READ, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, err
	}
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil || info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 || info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY != 0 {
		windows.CloseHandle(handle)
		if err != nil {
			return nil, err
		}
		return nil, errors.New("verified file is a reparse point or directory")
	}
	return func() { windows.CloseHandle(handle) }, nil
}
