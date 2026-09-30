//go:build windows

package mapi

import (
	"golang.org/x/sys/windows"
)

// GetFinalPathNameByHandle flags: FILE_NAME_NORMALIZED | VOLUME_NAME_NT.
const finalPathNormalizedNT = 0x0 | 0x2

// resolveFinalPath returns the NT path of the object that Windows opens for
// path, after it follows every symbolic link, junction and volume mount point.
//
// filepath.EvalSymlinks is not usable here: since Go 1.23 it reports a
// mount-point reparse point (IO_REPARSE_TAG_MOUNT_POINT, used by directory
// junctions and by volumes mounted in a folder, such as user profile disks on
// Remote Desktop Session Hosts) as a non-directory. A path that continues
// below such a component then fails with ERROR_PATH_NOT_FOUND.
//
// The NT volume form is used because a volume that is mounted only in a
// folder has no drive letter, and VOLUME_NAME_DOS can fail for it.
func resolveFinalPath(path string) (string, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return "", err
	}
	handle, err := windows.CreateFile(name, windows.FILE_READ_ATTRIBUTES,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		return "", err
	}
	defer windows.CloseHandle(handle)

	buf := make([]uint16, windows.MAX_PATH)
	for {
		n, err := windows.GetFinalPathNameByHandle(handle, &buf[0], uint32(len(buf)), finalPathNormalizedNT)
		if err != nil {
			return "", err
		}
		if int(n) < len(buf) {
			return windows.UTF16ToString(buf[:n]), nil
		}
		// n is the required size, including the terminating NUL.
		buf = make([]uint16, n)
	}
}
