//go:build windows

package service

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const runnerProcessAccess = windows.PROCESS_QUERY_LIMITED_INFORMATION | windows.SYNCHRONIZE

type WindowsAuthenticodeVerifier struct{}

func (WindowsAuthenticodeVerifier) VerifyAuthenticode(_ context.Context, path string) error {
	pointer, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	file := windows.WinTrustFileInfo{Size: uint32(unsafe.Sizeof(windows.WinTrustFileInfo{})), FilePath: pointer}
	data := windows.WinTrustData{Size: uint32(unsafe.Sizeof(windows.WinTrustData{})), UIChoice: windows.WTD_UI_NONE, RevocationChecks: windows.WTD_REVOKE_WHOLECHAIN, UnionChoice: windows.WTD_CHOICE_FILE, FileOrCatalogOrBlobOrSgnrOrCert: unsafe.Pointer(&file), StateAction: windows.WTD_STATEACTION_VERIFY, ProvFlags: windows.WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT, UIContext: windows.WTD_UICONTEXT_INSTALL}
	if err := windows.WinVerifyTrustEx(windows.InvalidHWND, &windows.WINTRUST_ACTION_GENERIC_VERIFY_V2, &data); err != nil {
		return err
	}
	data.StateAction = windows.WTD_STATEACTION_CLOSE
	return windows.WinVerifyTrustEx(windows.InvalidHWND, &windows.WINTRUST_ACTION_GENERIC_VERIFY_V2, &data)
}

type WindowsDetachedProcessSpawner struct{}

func (WindowsDetachedProcessSpawner) SpawnDetached(path, transactionID string) (ProcessIdentity, error) {
	if !filepath.IsAbs(path) || !transactionIDPattern.MatchString(transactionID) {
		return ProcessIdentity{}, errors.New("invalid detached runner invocation")
	}
	application, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return ProcessIdentity{}, err
	}
	commandLine, err := windows.UTF16PtrFromString(quoteWindowsArgument(path) + " --update-runner " + transactionID)
	if err != nil {
		return ProcessIdentity{}, err
	}
	startup := windows.StartupInfo{Cb: uint32(unsafe.Sizeof(windows.StartupInfo{}))}
	var process windows.ProcessInformation
	flags := uint32(windows.DETACHED_PROCESS | windows.CREATE_NEW_PROCESS_GROUP | windows.CREATE_BREAKAWAY_FROM_JOB | windows.CREATE_UNICODE_ENVIRONMENT)
	if err := windows.CreateProcess(application, commandLine, nil, nil, false, flags, nil, nil, &startup, &process); err != nil {
		return ProcessIdentity{}, err
	}
	defer windows.CloseHandle(process.Thread)
	defer windows.CloseHandle(process.Process)
	return processIdentity(process.Process, process.ProcessId)
}

type WindowsRunnerRuntime struct {
	storage *ProtectedStorage
}

func (WindowsRunnerRuntime) SelfIdentity() (ProcessIdentity, error) {
	pid := uint32(os.Getpid())
	handle, err := windows.OpenProcess(runnerProcessAccess, false, pid)
	if err != nil {
		return ProcessIdentity{}, err
	}
	defer windows.CloseHandle(handle)
	return processIdentity(handle, pid)
}

func (runtime WindowsRunnerRuntime) StartInstaller(msi, transactionID string) (InstallerProcess, error) {
	if !filepath.IsAbs(msi) || !transactionIDPattern.MatchString(transactionID) || runtime.storage == nil || runtime.storage.access != privateStorage {
		return nil, errors.New("invalid protected installer invocation")
	}
	if _, err := runtime.storage.ensureDirectory("logs", transactionID); err != nil {
		return nil, fmt.Errorf("prepare protected installer log: %w", err)
	}
	logPath, err := runtime.storage.child("logs", transactionID, "msiexec.log")
	if err != nil {
		return nil, err
	}
	system32, err := windows.GetSystemDirectory()
	if err != nil {
		return nil, err
	}
	msiexec := filepath.Join(system32, "msiexec.exe")
	application, err := windows.UTF16PtrFromString(msiexec)
	if err != nil {
		return nil, err
	}
	// This is the complete privileged argument surface. Neither release
	// metadata nor a caller can add properties, URLs, transforms, or paths.
	arguments, err := fixedInstallerArguments(msi, logPath, transactionID)
	if err != nil {
		return nil, err
	}
	command := quoteWindowsArgument(msiexec) + " " + arguments[0] + " " + quoteWindowsArgument(arguments[1]) + " " + arguments[2] + " " + arguments[3] + " " + arguments[4] + " " + quoteWindowsArgument(arguments[5]) + " " + arguments[6] + " " + arguments[7] + " " + arguments[8]
	commandLine, err := windows.UTF16PtrFromString(command)
	if err != nil {
		return nil, err
	}
	startup := windows.StartupInfo{Cb: uint32(unsafe.Sizeof(windows.StartupInfo{}))}
	var process windows.ProcessInformation
	if err := windows.CreateProcess(application, commandLine, nil, nil, false, windows.CREATE_NO_WINDOW|windows.CREATE_UNICODE_ENVIRONMENT, nil, nil, &startup, &process); err != nil {
		return nil, err
	}
	windows.CloseHandle(process.Thread)
	identity, err := processIdentity(process.Process, process.ProcessId)
	if err != nil {
		windows.CloseHandle(process.Process)
		return nil, err
	}
	return &windowsInstallerProcess{handle: process.Process, identity: identity}, nil
}

type windowsInstallerProcess struct {
	handle   windows.Handle
	identity ProcessIdentity
}

func (process *windowsInstallerProcess) Identity() ProcessIdentity { return process.identity }

func (process *windowsInstallerProcess) Wait() (uint32, error) {
	defer windows.CloseHandle(process.handle)
	status, err := windows.WaitForSingleObject(process.handle, windows.INFINITE)
	if err != nil || status != windows.WAIT_OBJECT_0 {
		return 0, fmt.Errorf("wait for msiexec: status=%d: %w", status, err)
	}
	var code uint32
	if err := windows.GetExitCodeProcess(process.handle, &code); err != nil {
		return 0, err
	}
	return code, nil
}

type WindowsProcessProbe struct{}

func (WindowsProcessProbe) Alive(_ context.Context, identity ProcessIdentity) (bool, error) {
	if err := validateProcessIdentity(&identity); err != nil {
		return false, err
	}
	handle, err := windows.OpenProcess(runnerProcessAccess, false, identity.PID)
	if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer windows.CloseHandle(handle)
	actual, err := processIdentity(handle, identity.PID)
	if err != nil || actual != identity {
		return false, err
	}
	status, err := windows.WaitForSingleObject(handle, 0)
	if err != nil {
		return false, err
	}
	switch status {
	case uint32(windows.WAIT_TIMEOUT):
		return true, nil
	case windows.WAIT_OBJECT_0:
		return false, nil
	default:
		return false, fmt.Errorf("unexpected process wait status %d", status)
	}
}

func processIdentity(handle windows.Handle, pid uint32) (ProcessIdentity, error) {
	var created, exited, kernel, user windows.Filetime
	if err := windows.GetProcessTimes(handle, &created, &exited, &kernel, &user); err != nil {
		return ProcessIdentity{}, err
	}
	return ProcessIdentity{PID: pid, CreatedAtUnixNano: created.Nanoseconds()}, nil
}

func quoteWindowsArgument(value string) string { return `"` + value + `"` }

func RunProductionUpdateRunner(transactionID string) error {
	programData, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, windows.KF_FLAG_DEFAULT)
	if err != nil {
		return err
	}
	paths, err := NewProgramDataPaths(programData)
	if err != nil {
		return err
	}
	stateStorage, err := NewProtectedStorage(paths.Service)
	if err != nil {
		return err
	}
	updateStorage, err := NewProtectedStorage(paths.Updates)
	if err != nil {
		return err
	}
	pending, _ := NewFileStateStore(stateStorage)
	ready, _ := NewFileRunnerReadyStore(stateStorage)
	artifacts, _ := NewProtectedArtifactResolver(updateStorage)
	return (UpdateRunner{Pending: pending, Ready: ready, Artifacts: artifacts, Integrity: SHA256FileVerifier{}, Runtime: WindowsRunnerRuntime{storage: updateStorage}, Clock: systemClock{}}).Run(context.Background(), transactionID)
}

func NewProductionDetachedRunnerLauncher(stateStorage, updateStorage *ProtectedStorage) (*DetachedRunnerLauncher, error) {
	ready, err := NewFileRunnerReadyStore(stateStorage)
	if err != nil {
		return nil, err
	}
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	return NewDetachedRunnerLauncher(updateStorage, ready, WindowsAuthenticodeVerifier{}, WindowsDetachedProcessSpawner{}, PollReadyAwaiter{Interval: 100 * time.Millisecond, Timeout: 30 * time.Second}, executable)
}

type systemClock struct{}

func (systemClock) Now() time.Time { return time.Now().UTC() }
