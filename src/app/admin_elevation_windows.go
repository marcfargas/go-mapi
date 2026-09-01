//go:build windows

package main

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

type productionAdminAuthenticodeInspector struct{}

func (productionAdminAuthenticodeInspector) InspectAdminMSI(_ context.Context, path string) (adminAuthenticodeIdentity, error) {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return adminAuthenticodeIdentity{}, err
	}
	file := windows.WinTrustFileInfo{Size: uint32(unsafe.Sizeof(windows.WinTrustFileInfo{})), FilePath: p}
	data := windows.WinTrustData{Size: uint32(unsafe.Sizeof(windows.WinTrustData{})), UIChoice: windows.WTD_UI_NONE, RevocationChecks: windows.WTD_REVOKE_WHOLECHAIN, UnionChoice: windows.WTD_CHOICE_FILE, FileOrCatalogOrBlobOrSgnrOrCert: unsafe.Pointer(&file), StateAction: windows.WTD_STATEACTION_VERIFY, ProvFlags: windows.WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT | windows.WTD_MOTW, UIContext: windows.WTD_UICONTEXT_INSTALL}
	err = windows.WinVerifyTrustEx(windows.InvalidHWND, &windows.WINTRUST_ACTION_GENERIC_VERIFY_V2, &data)
	if err != nil {
		return adminAuthenticodeIdentity{}, err
	}
	defer func() {
		data.StateAction = windows.WTD_STATEACTION_CLOSE
		_ = windows.WinVerifyTrustEx(windows.InvalidHWND, &windows.WINTRUST_ACTION_GENERIC_VERIFY_V2, &data)
	}()
	prov := procWTHelperProvDataFromStateData.Find()
	if prov != nil {
		return adminAuthenticodeIdentity{}, prov
	}
	providerData, _, _ := procWTHelperProvDataFromStateData.Call(uintptr(data.StateData))
	runtime.KeepAlive(&data)
	if providerData == 0 {
		return adminAuthenticodeIdentity{}, errors.New("missing WinTrust provider data")
	}
	signerProc := procWTHelperGetProvSignerFromChain.Find()
	if signerProc != nil {
		return adminAuthenticodeIdentity{}, signerProc
	}
	signer := winTrustProviderSignerFromChain(providerData)
	runtime.KeepAlive(&data)
	if signer == nil {
		return adminAuthenticodeIdentity{}, errors.New("missing WinTrust provider signer")
	}
	cert := signer.CertChain
	if cert == nil || cert.Cert == nil || cert.Cert.EncodedCert == nil || cert.Cert.Length == 0 {
		return adminAuthenticodeIdentity{}, errors.New("missing WinTrust signer certificate")
	}
	der := unsafe.Slice(cert.Cert.EncodedCert, cert.Cert.Length)
	parsed, err := x509.ParseCertificate(der)
	if err != nil {
		return adminAuthenticodeIdentity{}, err
	}
	ekus := make([]string, 0, len(parsed.ExtKeyUsage)+len(parsed.UnknownExtKeyUsage))
	for _, usage := range parsed.ExtKeyUsage {
		if usage == x509.ExtKeyUsageCodeSigning {
			ekus = append(ekus, "1.3.6.1.5.5.7.3.3")
		}
	}
	for _, oid := range parsed.UnknownExtKeyUsage {
		ekus = append(ekus, oid.String())
	}
	cn := canonicalWinTrustCN(cert.Cert)
	if cn == "" {
		return adminAuthenticodeIdentity{}, errors.New("signer publisher identity is empty")
	}
	return adminAuthenticodeIdentity{ChainValid: true, Publisher: cn, EKUs: ekus}, nil
}

type winTrustProviderCert struct {
	cbStruct uint32
	Cert     *windows.CertContext
}
type winTrustProviderSigner struct {
	cbStruct       uint32
	VerifyAsOf     windows.Filetime
	CertChainCount uint32
	CertChain      *winTrustProviderCert
}

var procWTHelperProvDataFromStateData = windows.NewLazySystemDLL("wintrust.dll").NewProc("WTHelperProvDataFromStateData")
var procWTHelperGetProvSignerFromChain = windows.NewLazySystemDLL("wintrust.dll").NewProc("WTHelperGetProvSignerFromChain")

// winTrustProviderSignerFromChain is the sole raw ABI boundary for the
// undocumented WinTrust helper. The native routine returns an in-state pointer;
// callers keep WinTrustData alive and close it only after consuming this value.
//
//go:nocheckptr
func winTrustProviderSignerFromChain(providerData uintptr) *winTrustProviderSigner {
	r, _, _ := procWTHelperGetProvSignerFromChain.Call(providerData, 0, 0, 0)
	if r == 0 {
		return nil
	}
	// The return word is a native pointer owned by WinTrust state, not a Go
	// allocation. Reinterpret the word through its address so vet does not see
	// a retained uintptr-to-pointer conversion.
	p := *(*unsafe.Pointer)(unsafe.Pointer(&r))
	return (*winTrustProviderSigner)(p)
}

func canonicalWinTrustCN(cert *windows.CertContext) string {
	n := windows.CertGetNameString(cert, windows.CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nil, nil, 0)
	if n == 0 {
		return ""
	}
	buf := make([]uint16, n)
	windows.CertGetNameString(cert, windows.CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nil, &buf[0], n)
	return strings.ToLower(strings.TrimSpace(windows.UTF16PtrToString(&buf[0])))
}

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

func handoffAuthorizedAdminMSI(_ context.Context, candidate authorizedAdminMSICandidate) error {
	msi, err := filepath.Abs(candidate.Path)
	if err != nil {
		return err
	}
	data, err := os.ReadFile(msi)
	if err != nil {
		return fmt.Errorf("reopen staged admin MSI: %w", err)
	}
	sum := sha256.Sum256(data)
	if hex.EncodeToString(sum[:]) != candidate.Release.Payload.Artifact.SHA256 {
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

func stagePrivilegedAuthorizedAdminMSI(ctx context.Context, release authorizedAdminRelease, contents []byte) (string, func(), error) {
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
	if _, err := secureAdminStageTree(base, "go-mapi", "admin-installer", release.Payload.Version); err != nil {
		return "", nil, err
	}
	return stageAdminMSIAt(ctx, root, release, contents)
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
