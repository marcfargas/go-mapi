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

	"github.com/marcfargas/go-mapi/internal/mapi/update"
	"golang.org/x/sys/windows"
)

const runnerProcessAccess = windows.PROCESS_QUERY_LIMITED_INFORMATION | windows.SYNCHRONIZE

type WindowsAuthenticodeVerifier struct{}

func (WindowsAuthenticodeVerifier) VerifyAuthenticode(_ context.Context, path string) error {
	return update.VerifyAuthenticode(path)
}

// ProductionInstallerVerifier requires both the authenticated target digest
// and Windows' built-in signature check before handing bytes to Installer.
type ProductionInstallerVerifier struct{}

func (ProductionInstallerVerifier) VerifySHA256(ctx context.Context, path, digest string) error {
	if err := (SHA256FileVerifier{}).VerifySHA256(ctx, path, digest); err != nil {
		return err
	}
	return (WindowsAuthenticodeVerifier{}).VerifyAuthenticode(ctx, path)
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
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, fmt.Errorf("create private installer job: %w", err)
	}
	jobOwned := true
	defer func() {
		if jobOwned {
			windows.CloseHandle(job)
		}
	}()
	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits))); err != nil {
		return nil, fmt.Errorf("arm installer job: %w", err)
	}
	attributes, err := windows.NewProcThreadAttributeList(1)
	if err != nil {
		return nil, fmt.Errorf("allocate installer job attribute: %w", err)
	}
	defer attributes.Delete()
	const procThreadAttributeJobList = uintptr(0x0002000d)
	if err := attributes.Update(procThreadAttributeJobList, unsafe.Pointer(&job), unsafe.Sizeof(job)); err != nil {
		return nil, fmt.Errorf("associate installer job at creation: %w", err)
	}
	startup := windows.StartupInfoEx{StartupInfo: windows.StartupInfo{Cb: uint32(unsafe.Sizeof(windows.StartupInfoEx{}))}, ProcThreadAttributeList: attributes.List()}
	var process windows.ProcessInformation
	flags := uint32(windows.CREATE_NO_WINDOW | windows.CREATE_UNICODE_ENVIRONMENT | windows.CREATE_SUSPENDED | windows.EXTENDED_STARTUPINFO_PRESENT | windows.CREATE_BREAKAWAY_FROM_JOB)
	if err := windows.CreateProcess(application, commandLine, nil, nil, false, flags, nil, nil, &startup.StartupInfo, &process); err != nil {
		return nil, err
	}
	identity, err := processIdentity(process.Process, process.ProcessId)
	if err != nil {
		windows.CloseHandle(process.Thread)
		windows.CloseHandle(process.Process)
		return nil, err
	}
	threadIdentity, err := threadIdentity(process.Thread, process.ThreadId)
	if err != nil {
		windows.CloseHandle(process.Thread)
		windows.CloseHandle(process.Process)
		return nil, err
	}
	jobOwned = false
	return &windowsInstallerProcess{handle: process.Process, thread: process.Thread, job: job, identity: identity, initialThread: threadIdentity}, nil
}

type windowsInstallerProcess struct {
	handle        windows.Handle
	thread        windows.Handle
	job           windows.Handle
	identity      ProcessIdentity
	initialThread ProcessIdentity
}

func (process *windowsInstallerProcess) Identity() ProcessIdentity      { return process.identity }
func (process *windowsInstallerProcess) InitialThread() ProcessIdentity { return process.initialThread }

func (process *windowsInstallerProcess) Abort() error {
	// The only handle to the armed private job belongs to this runner.
	// Closing it terminates the still-suspended child on every error path.
	var err error
	if process.job != 0 {
		err = windows.CloseHandle(process.job)
		process.job = 0
	}
	if process.thread != 0 {
		err = errors.Join(err, windows.CloseHandle(process.thread))
		process.thread = 0
	}
	if process.handle != 0 {
		err = errors.Join(err, windows.CloseHandle(process.handle))
		process.handle = 0
	}
	return err
}

func (process *windowsInstallerProcess) Resume() error {
	if process.job == 0 || process.thread == 0 {
		return errors.New("installer is not owned by this runner")
	}
	var limits windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	if err := windows.QueryInformationJobObject(process.job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits)), nil); err != nil {
		_ = process.Abort()
		return fmt.Errorf("read installer job limits: %w", err)
	}
	limits.BasicLimitInformation.LimitFlags &^= windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(process.job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits))); err != nil {
		_ = process.Abort()
		return fmt.Errorf("disarm installer job after durable identity: %w", err)
	}
	if err := windows.QueryInformationJobObject(process.job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits)), nil); err != nil || limits.BasicLimitInformation.LimitFlags&windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE != 0 {
		return errors.New("installer job disarm could not be verified")
	}
	previous, err := windows.ResumeThread(process.thread)
	if err != nil {
		return fmt.Errorf("resume installer initial thread: %w", err)
	}
	if previous != 1 {
		return fmt.Errorf("resume installer initial thread: unexpected prior suspend count %d", previous)
	}
	windows.CloseHandle(process.thread)
	process.thread = 0
	windows.CloseHandle(process.job)
	process.job = 0
	return nil
}

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

var getThreadTimes = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetThreadTimes")
var getProcessIDOfThread = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetProcessIdOfThread")

func threadIdentity(handle windows.Handle, tid uint32) (ProcessIdentity, error) {
	var created, exited, kernel, user windows.Filetime
	result, _, err := getThreadTimes.Call(uintptr(handle), uintptr(unsafe.Pointer(&created)), uintptr(unsafe.Pointer(&exited)), uintptr(unsafe.Pointer(&kernel)), uintptr(unsafe.Pointer(&user)))
	if result == 0 {
		return ProcessIdentity{}, fmt.Errorf("read installer thread creation time: %w", err)
	}
	return ProcessIdentity{PID: tid, CreatedAtUnixNano: created.Nanoseconds()}, nil
}

// RecoverAuthorizedInstaller completes only a previously durable resume
// authorization. It never creates a replacement installer or grants a new
// update attempt. The runner lock makes a live owner win over recovery.
func RecoverAuthorizedInstaller(stateStorage *ProtectedStorage) error {
	lock, err := tryOwnRunnerLock(stateStorage)
	if errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("claim installer recovery: %w", err)
	}
	defer lock.Close()
	store, err := NewFileStateStore(stateStorage)
	if err != nil {
		return err
	}
	pending, err := store.Load(context.Background())
	if err != nil || pending == nil {
		return err
	}
	if pending.Schema != PendingSchemaV2 || pending.Phase != PhaseResumeAuthorized {
		return nil
	}
	if pending.Installer == nil || pending.InstallerThread == nil {
		return errors.New("authorized installer lacks durable process and thread identity")
	}
	process, err := windows.OpenProcess(runnerProcessAccess, false, pending.Installer.PID)
	if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
		return nil // Dead child is classified by the later MSI-server barrier.
	}
	if err != nil {
		return err
	}
	defer windows.CloseHandle(process)
	actualProcess, err := processIdentity(process, pending.Installer.PID)
	if err != nil || actualProcess != *pending.Installer {
		return errors.New("authorized installer process identity changed")
	}
	var image [windows.MAX_PATH]uint16
	imageLength := uint32(len(image))
	if err := windows.QueryFullProcessImageName(process, 0, &image[0], &imageLength); err != nil {
		return fmt.Errorf("read authorized installer image: %w", err)
	}
	system32, err := windows.GetSystemDirectory()
	if err != nil {
		return err
	}
	if !equalWindowsPath(windows.UTF16ToString(image[:imageLength]), filepath.Join(system32, "msiexec.exe")) {
		return errors.New("authorized installer image changed")
	}
	thread, err := windows.OpenThread(windows.THREAD_QUERY_LIMITED_INFORMATION|windows.THREAD_SUSPEND_RESUME|windows.SYNCHRONIZE, false, pending.InstallerThread.PID)
	if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
		// The exact process is still open, but its initial thread has exited.
		// It cannot be suspended at the launch boundary any longer.
		previousPending := *pending
		pending.Phase = PhaseRunning
		pending.UpdatedAt = time.Now().UTC()
		return store.CompareAndSave(context.Background(), &previousPending, *pending)
	}
	if err != nil {
		return err
	}
	defer windows.CloseHandle(thread)
	actualThread, err := threadIdentity(thread, pending.InstallerThread.PID)
	if err != nil || actualThread != *pending.InstallerThread {
		return errors.New("authorized installer thread identity changed")
	}
	ownerPID, _, callErr := getProcessIDOfThread.Call(uintptr(thread))
	if ownerPID == 0 || uint32(ownerPID) != pending.Installer.PID {
		return fmt.Errorf("authorized installer thread owner mismatch: %w", callErr)
	}
	previous, err := windows.ResumeThread(thread)
	if err != nil {
		return fmt.Errorf("resume authorized installer thread: %w", err)
	}
	if previous > 1 {
		previousPending := *pending
		pending.Phase = PhaseRepairRequired
		pending.Result = ResultAmbiguous
		pending.UpdatedAt = time.Now().UTC()
		if saveErr := store.CompareAndSave(context.Background(), &previousPending, *pending); saveErr != nil {
			return errors.Join(fmt.Errorf("authorized installer has abnormal prior suspend count %d", previous), saveErr)
		}
		return fmt.Errorf("resume authorized installer thread: unexpected prior suspend count %d", previous)
	}
	previousPending := *pending
	pending.Phase = PhaseRunning
	pending.UpdatedAt = time.Now().UTC()
	return store.CompareAndSave(context.Background(), &previousPending, *pending)
}

func quoteWindowsArgument(value string) string { return `"` + value + `"` }

func RunProductionUpdateRunner(transactionID string) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	if err := (WindowsAuthenticodeVerifier{}).VerifyAuthenticode(context.Background(), self); err != nil {
		return fmt.Errorf("verify update runner signature: %w", err)
	}
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
	lock, err := tryOwnRunnerLock(stateStorage)
	if err != nil {
		return fmt.Errorf("claim exclusive installer runner: %w", err)
	}
	defer lock.Close()
	updateStorage, err := NewProtectedStorage(paths.Updates)
	if err != nil {
		return err
	}
	pending, err := NewFileStateStore(stateStorage)
	if err != nil {
		return err
	}
	ready, err := NewFileRunnerReadyStore(stateStorage)
	if err != nil {
		return err
	}
	artifacts, err := NewProtectedArtifactResolver(updateStorage)
	if err != nil {
		return err
	}
	return (UpdateRunner{Pending: pending, Ready: ready, Artifacts: artifacts, Integrity: ProductionInstallerVerifier{}, VerifyIdentity: verifyStagedMSIIdentity, Runtime: WindowsRunnerRuntime{storage: updateStorage}, Clock: systemClock{}, Authorize: authorizeMachineInstaller}).Run(context.Background(), transactionID)
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
	launcher, err := NewDetachedRunnerLauncher(updateStorage, ready, WindowsAuthenticodeVerifier{}, WindowsDetachedProcessSpawner{}, PollReadyAwaiter{Interval: 100 * time.Millisecond, Timeout: 30 * time.Second}, executable)
	if err != nil {
		return nil, err
	}
	// The handoff checks the digest and Windows signature before spawning; the
	// runner repeats the check before invoking Windows Installer.
	launcher.integrity = ProductionInstallerVerifier{}
	return launcher, nil
}

type systemClock struct{}

func (systemClock) Now() time.Time { return time.Now().UTC() }
