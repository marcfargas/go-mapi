//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
	"golang.org/x/sys/windows"
)

func verifyAdminMSI(_ context.Context, path string) error { return update.VerifyAuthenticode(path) }

type shellExecuteInfo struct {
	cbSize                                    uint32
	fMask                                     uint32
	hwnd                                      windows.Handle
	lpVerb, lpFile, lpParameters, lpDirectory *uint16
	nShow                                     int32
	hInstApp                                  windows.Handle
	lpIDList                                  unsafe.Pointer
	lpClass                                   *uint16
	hkeyClass                                 windows.Handle
	dwHotKey                                  uint32
	hIconOrMonitor                            windows.Handle
	hProcess                                  windows.Handle
}

var procShellExecuteExW = windows.NewLazySystemDLL("shell32.dll").NewProc("ShellExecuteExW")
var procGetSystemDirectoryW = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetSystemDirectoryW")
var procSetLastError = windows.NewLazySystemDLL("kernel32.dll").NewProc("SetLastError")
var folderIDProgramData = windows.GUID{Data1: 0x62ab5d82, Data2: 0xfdc1, Data3: 0x4dc3, Data4: [8]byte{0xa9, 0xdd, 0x07, 0x0d, 0x1d, 0x49, 0x5d, 0x97}}

func trustedMSIExecPath() (string, error) {
	buf := make([]uint16, windows.MAX_PATH)
	n, _, err := procGetSystemDirectoryW.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 || int(n) >= len(buf) {
		return "", fmt.Errorf("GetSystemDirectoryW: %w", err)
	}
	path := filepath.Join(windows.UTF16PtrToString(&buf[0]), "msiexec.exe")
	if !filepath.IsAbs(path) {
		return "", errors.New("System32 msiexec path is not absolute")
	}
	if _, err := os.Stat(path); err != nil {
		return "", fmt.Errorf("validate System32 msiexec: %w", err)
	}
	return path, nil
}

func handoffAdminMSI(_ context.Context, candidate update.Prepared) error {
	msi, err := filepath.Abs(candidate.Path())
	if err != nil {
		return err
	}
	file, err := os.Open(msi)
	if err != nil {
		return fmt.Errorf("reopen staged admin MSI: %w", err)
	}
	defer file.Close()
	if err := candidate.Release().VerifyReader(file); err != nil {
		return errors.New("staged admin MSI changed before elevation")
	}
	msiexec, err := trustedMSIExecPath()
	if err != nil {
		return err
	}
	code, err := shellExecuteRunAs(msiexec, `/i "`+msi+`" /norestart`)
	if err != nil {
		return err
	}
	if code == 3010 || code == 1641 {
		return errAdminMSIRebootRequired
	}
	if code != 0 {
		return fmt.Errorf("admin MSI exited with %d", code)
	}
	return nil
}

func shellExecuteRunAs(path, arguments string) (uint32, error) {
	verb, _ := syscall.UTF16PtrFromString("runas")
	file, _ := syscall.UTF16PtrFromString(path)
	params, _ := syscall.UTF16PtrFromString(arguments)
	info := shellExecuteInfo{cbSize: uint32(unsafe.Sizeof(shellExecuteInfo{})), fMask: 0x40, lpVerb: verb, lpFile: file, lpParameters: params, nShow: 1}
	ok, _, callErr := procShellExecuteExW.Call(uintptr(unsafe.Pointer(&info)))
	if ok == 0 {
		return 0, fmt.Errorf("Windows elevation failed: %w", callErr)
	}
	if info.hProcess == 0 {
		return 0, errors.New("Windows elevation returned no process")
	}
	defer windows.CloseHandle(info.hProcess)
	if _, err := windows.WaitForSingleObject(info.hProcess, windows.INFINITE); err != nil {
		return 0, err
	}
	var code uint32
	if err := windows.GetExitCodeProcess(info.hProcess, &code); err != nil {
		return 0, err
	}
	return code, nil
}

func launchElevatedAdminHelper() (bool, error) {
	exe, err := os.Executable()
	if err != nil {
		return false, err
	}
	code, err := shellExecuteRunAs(exe, "--install-admin-component")
	if err != nil {
		return false, err
	}
	return code == 3010 || code == 1641, func() error {
		if code != 0 && code != 3010 && code != 1641 {
			return fmt.Errorf("elevated admin helper exited with %d", code)
		}
		return nil
	}()
}

func stagePrivilegedAdminMSI(ctx context.Context, candidate update.Candidate, write func(io.Writer) error) (string, func(), error) {
	var raw *uint16
	hr, _, _ := procSHGetKnownFolderPath.Call(uintptr(unsafe.Pointer(&folderIDProgramData)), 0, 0, uintptr(unsafe.Pointer(&raw)))
	if int32(hr) < 0 || raw == nil {
		return "", nil, errors.New("ProgramData is unavailable")
	}
	defer procCoTaskMemFree.Call(uintptr(unsafe.Pointer(raw)))
	base := windows.UTF16PtrToString(raw)
	root, err := secureAdminStageTree(base, "go-mapi", "admin-installer")
	if err != nil {
		return "", nil, err
	}
	if _, err := secureAdminStageTree(base, "go-mapi", "admin-installer", candidate.Payload().Version); err != nil {
		return "", nil, err
	}
	return stageAdminMSIAt(ctx, root, candidate, write)
}

func secureAdminStageTree(base string, components ...string) (string, error) {
	name, err := windows.NewNTUnicodeString("\\??\\" + base)
	if err != nil {
		return "", err
	}
	oa := &windows.OBJECT_ATTRIBUTES{Length: uint32(unsafe.Sizeof(windows.OBJECT_ATTRIBUTES{})), ObjectName: name, Attributes: windows.OBJ_DONT_REPARSE}
	var iosb windows.IO_STATUS_BLOCK
	var allocation int64
	var parent windows.Handle
	if err := windows.NtCreateFile(&parent, windows.FILE_GENERIC_READ|windows.FILE_GENERIC_WRITE|windows.READ_CONTROL|windows.WRITE_DAC|windows.WRITE_OWNER, oa, &iosb, &allocation, 0, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE, windows.FILE_OPEN, windows.FILE_DIRECTORY_FILE|windows.FILE_OPEN_REPARSE_POINT, 0, 0); err != nil {
		return "", err
	}
	// parent is replaced while descending. Capture it at return time, rather
	// than capturing the initial ProgramData handle in a deferred argument.
	defer func() { _ = windows.CloseHandle(parent) }()
	current := base
	for _, component := range components {
		if component == "" || component == "." || component == ".." || filepath.Base(component) != component {
			return "", errors.New("invalid admin staging path component")
		}
		current = filepath.Join(current, component)
		childName, err := windows.NewNTUnicodeString(component)
		if err != nil {
			return "", err
		}
		oa.RootDirectory = parent
		oa.ObjectName = childName
		var child windows.Handle
		// Do not share DELETE while this untrusted legacy component is being
		// inspected and protected. A replacement must not race the relative
		// descent below.
		if err := windows.NtCreateFile(&child, windows.FILE_GENERIC_READ|windows.FILE_GENERIC_WRITE|windows.READ_CONTROL|windows.WRITE_DAC|windows.WRITE_OWNER, oa, &iosb, &allocation, 0, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, windows.FILE_OPEN_IF, windows.FILE_DIRECTORY_FILE|windows.FILE_OPEN_REPARSE_POINT, 0, 0); err != nil {
			return "", err
		}
		var info windows.ByHandleFileInformation
		if err := windows.GetFileInformationByHandle(child, &info); err != nil {
			windows.CloseHandle(child)
			return "", err
		}
		if info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			windows.CloseHandle(child)
			return "", errors.New("admin staging path contains reparse point")
		}
		// Apply ownership and the protected DACL before this component becomes
		// the parent for the next relative open. Otherwise a standard user who
		// owned an older directory could replace its descendant between opens.
		if err := protectAdminStageDirectory(child); err != nil {
			windows.CloseHandle(child)
			return "", err
		}
		windows.CloseHandle(parent)
		parent = child
	}
	return current, nil
}

func protectAdminStageDirectory(handle windows.Handle) error {
	// The directory owns the candidate. Its protected DACL is explicit,
	// inherited by its MSI file, and never assumed from POSIX mode bits.
	sd, err := windows.SecurityDescriptorFromString("O:SYG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
	if err != nil {
		return err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	owner, _, err := sd.Owner()
	if err != nil {
		return err
	}
	return withSeRestorePrivilege(func() error {
		return windows.SetSecurityInfo(handle, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, owner, nil, dacl, nil)
	})
}

// withSeRestorePrivilege enables SeRestorePrivilege only for a SYSTEM-owner
// assignment and restores the previous token state before returning. WRITE_OWNER
// alone permits assigning only a SID already held by the caller; SYSTEM needs
// this explicitly enabled privilege even from an elevated administrator.
func withSeRestorePrivilege(action func() error) error {
	var token windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_ADJUST_PRIVILEGES|windows.TOKEN_QUERY, &token); err != nil {
		return fmt.Errorf("open token for SeRestorePrivilege: %w", err)
	}
	defer token.Close()
	name, err := windows.UTF16PtrFromString("SeRestorePrivilege")
	if err != nil {
		return err
	}
	var luid windows.LUID
	if err := windows.LookupPrivilegeValue(nil, name, &luid); err != nil {
		return fmt.Errorf("lookup SeRestorePrivilege: %w", err)
	}
	desired := windows.Tokenprivileges{PrivilegeCount: 1, Privileges: [1]windows.LUIDAndAttributes{{Luid: luid, Attributes: windows.SE_PRIVILEGE_ENABLED}}}
	var previous windows.Tokenprivileges
	var returned uint32
	procSetLastError.Call(0)
	if err := windows.AdjustTokenPrivileges(token, false, &desired, uint32(unsafe.Sizeof(previous)), &previous, &returned); err != nil {
		return fmt.Errorf("enable SeRestorePrivilege: %w", err)
	}
	if err := windows.GetLastError(); err == windows.ERROR_NOT_ALL_ASSIGNED {
		return errors.New("SeRestorePrivilege is not assigned to elevated token")
	}
	setErr := action()
	if err := windows.AdjustTokenPrivileges(token, false, &previous, 0, nil, nil); err != nil {
		if setErr != nil {
			return fmt.Errorf("%v; restore SeRestorePrivilege: %w", setErr, err)
		}
		return fmt.Errorf("restore SeRestorePrivilege: %w", err)
	}
	return setErr
}

func rejectAdminStageReparse(path string) error {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	attrs, err := windows.GetFileAttributes(p)
	if err != nil {
		return err
	}
	if attrs&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return errors.New("admin staging path contains reparse point")
	}
	return nil
}
