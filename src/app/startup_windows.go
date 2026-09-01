//go:build windows

package main

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"

	ole "github.com/go-ole/go-ole"
	"github.com/pkg/browser"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const (
	appModelErrorNoPackage  = 15700
	errorInsufficientBuffer = 122
	standaloneStartupKey    = `Software\Microsoft\Windows\CurrentVersion\Run`
)

type windowsStartupService struct {
	registration startupRegistrationStore
	msix         msixStartupTaskAPI
	packaged     bool
	identityErr  error
	exePath      string
}

type startupRegistrationStore interface {
	Read() (string, error)
	Write(string) error
	Delete() error
}

type windowsStartupRegistrationStore struct{}

func (windowsStartupRegistrationStore) Read() (string, error) {
	key, err := registry.OpenKey(registry.CURRENT_USER, standaloneStartupKey, registry.QUERY_VALUE)
	if err != nil {
		return "", err
	}
	defer key.Close()
	value, _, err := key.GetStringValue(userStartupTaskID)
	return value, err
}

func (windowsStartupRegistrationStore) Write(command string) error {
	key, _, err := registry.CreateKey(registry.CURRENT_USER, standaloneStartupKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	return key.SetStringValue(userStartupTaskID, command)
}

func (windowsStartupRegistrationStore) Delete() error {
	key, err := registry.OpenKey(registry.CURRENT_USER, standaloneStartupKey, registry.SET_VALUE)
	if errors.Is(err, registry.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer key.Close()
	if err := key.DeleteValue(userStartupTaskID); err != nil && !errors.Is(err, registry.ErrNotExist) {
		return err
	}
	return nil
}

func newStartupService() startupService {
	_, packaged, err := currentPackageFullName()
	exePath, exeErr := os.Executable()
	if exeErr != nil && err == nil {
		err = exeErr
	}
	return &windowsStartupService{
		msix: nativeMSIXStartupTaskAPI{}, packaged: packaged,
		registration: windowsStartupRegistrationStore{},
		identityErr:  err, exePath: exePath,
	}
}

func (s *windowsStartupService) State(ctx context.Context, requested bool) StartupState {
	if s.identityErr != nil {
		return startupFailure("unknown", requested, fmt.Sprintf("Cannot determine app channel: %v", s.identityErr))
	}
	if s.packaged {
		return s.msixState(ctx, requested, "query")
	}
	return s.standaloneState(ctx, requested)
}

func (s *windowsStartupService) Set(ctx context.Context, enabled bool) StartupState {
	if s.identityErr != nil {
		return startupFailure("unknown", enabled, fmt.Sprintf("Cannot determine app channel: %v", s.identityErr))
	}
	if s.packaged {
		action := "disable"
		if enabled {
			action = "enable"
		}
		return s.msixState(ctx, enabled, action)
	}
	if enabled {
		state := s.standaloneState(ctx, true)
		if state.Registered && state.Effective == "enabled" && state.Warning == "" {
			return state
		}
		if err := s.registration.Write(s.standaloneCommand()); err != nil {
			return startupFailure("standalone", true, fmt.Sprintf("Windows could not register startup: %v", err))
		}
		return s.standaloneState(ctx, true)
	}
	state := s.standaloneState(ctx, false)
	if !state.Registered {
		return state
	}
	if err := s.registration.Delete(); err != nil {
		return startupFailure("standalone", false, fmt.Sprintf("Windows could not disable startup: %v", err))
	}
	return s.standaloneState(ctx, false)
}

func (s *windowsStartupService) OpenSettings() error {
	return browser.OpenURL("ms-settings:startupapps")
}

func startupFailure(backend string, requested bool, warning string) StartupState {
	return StartupState{Backend: backend, Requested: requested, Effective: "error", Warning: warning}
}

func (s *windowsStartupService) standaloneState(ctx context.Context, requested bool) StartupState {
	state := StartupState{Backend: "standalone", Requested: requested, Effective: "missing"}
	registeredCommand, err := s.registration.Read()
	if err != nil {
		if errors.Is(err, registry.ErrNotExist) {
			if requested {
				state.Warning = "Startup is requested but not registered. Choose Fix startup to register it."
			}
			return state
		}
		return startupFailure("standalone", requested, fmt.Sprintf("Cannot read startup registration: %v", err))
	}
	state.Registered = true
	state.Effective = "enabled"
	if !strings.EqualFold(strings.TrimSpace(registeredCommand), s.standaloneCommand()) {
		state.Effective = "mismatched"
		state.Warning = "The startup registration points outside this go-mapi installation. Choose Fix startup to replace it."
		return state
	}
	if requested && state.Effective != "enabled" {
		state.Warning = "Startup is requested but Windows has disabled it."
	} else if !requested && state.Effective == "enabled" {
		state.Warning = "Startup is disabled in go-mapi but remains enabled in Windows."
	}
	return state
}

func (s *windowsStartupService) standaloneCommand() string {
	return fmt.Sprintf(`"%s" --startup`, filepath.Clean(s.exePath))
}

type msixStartupTaskAPI interface {
	State(context.Context, string) (string, error)
}

func (s *windowsStartupService) msixState(ctx context.Context, requested bool, action string) StartupState {
	api := s.msix
	if api == nil {
		api = nativeMSIXStartupTaskAPI{}
	}
	stateName, err := api.State(ctx, action)
	if err != nil {
		return startupFailure("msix", requested, fmt.Sprintf("Windows StartupTask API failed: %v", err))
	}
	state := StartupState{Backend: "msix", Requested: requested, Registered: true, Effective: strings.ToLower(stateName)}
	switch stateName {
	case "Enabled":
		if !requested {
			state.Warning = "Startup is disabled in go-mapi but remains enabled in Windows."
		}
	case "Disabled":
		if requested {
			state.Warning = "Startup is requested but is disabled. Choose Fix startup to ask Windows to enable it."
		}
	case "DisabledByUser":
		state.Warning = "Windows has disabled go-mapi startup at the user's request. Re-enable it in Startup Apps."
	case "DisabledByPolicy":
		state.Warning = "Windows policy has disabled go-mapi startup. Review Startup Apps or contact your administrator."
	case "EnabledByPolicy":
		state.Warning = "Windows policy controls go-mapi startup. Review Startup Apps or contact your administrator."
	default:
		state.Warning = "Windows returned an unknown startup state. Review Startup Apps."
	}
	return state
}

// nativeMSIXStartupTaskAPI keeps the packaged process's identity. StartupTask
// resolves its task from the calling package, so launching PowerShell would
// make GetAsync run as an unpackaged process and return E_NOTFOUND.
type nativeMSIXStartupTaskAPI struct{}

const (
	guidIStartupTask        = "{F75C23C8-B5F2-4F6C-88DD-36CB1D599D17}"
	guidIStartupTaskStatics = "{EE5B60BD-A148-41A7-B26E-E8B88A1E62F8}"
	guidIAsyncInfo          = "{00000036-0000-0000-C000-000000000046}"
	startupTaskRuntimeClass = "Windows.ApplicationModel.StartupTask"

	asyncStarted    = 0
	asyncCompleted  = 1
	asyncCanceled   = 2
	asyncError      = 3
	rpcEChangedMode = 0x80010106
)

type iStartupTaskStatics struct{ ole.IInspectable }
type iStartupTaskStaticsVtbl struct {
	ole.IInspectableVtbl
	GetForCurrentPackageAsync uintptr
	GetAsync                  uintptr
}

func (v *iStartupTaskStatics) VTable() *iStartupTaskStaticsVtbl {
	return (*iStartupTaskStaticsVtbl)(unsafe.Pointer(v.RawVTable))
}

type iStartupTask struct{ ole.IInspectable }
type iStartupTaskVtbl struct {
	ole.IInspectableVtbl
	RequestEnableAsync uintptr
	Disable            uintptr
	State              uintptr
	TaskID             uintptr
}

func (v *iStartupTask) VTable() *iStartupTaskVtbl {
	return (*iStartupTaskVtbl)(unsafe.Pointer(v.RawVTable))
}

type iAsyncInfo struct{ ole.IInspectable }
type iAsyncInfoVtbl struct {
	ole.IInspectableVtbl
	ID        uintptr
	Status    uintptr
	ErrorCode uintptr
	Cancel    uintptr
	Close     uintptr
}

func (v *iAsyncInfo) VTable() *iAsyncInfoVtbl {
	return (*iAsyncInfoVtbl)(unsafe.Pointer(v.RawVTable))
}

// IAsyncOperation<TResult> has the IInspectable methods followed by
// put_Completed, get_Completed, and GetResults. We only need GetResults after
// IAsyncInfo reports completion, so its ABI slot is the same for both result
// types used here.
type iAsyncOperationVtbl struct {
	ole.IInspectableVtbl
	PutCompleted uintptr
	GetCompleted uintptr
	GetResults   uintptr
}

func (nativeMSIXStartupTaskAPI) State(ctx context.Context, action string) (string, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	roInitialized := true
	if err := ole.RoInitialize(1); err != nil {
		if oleErr, ok := err.(*ole.OleError); ok && oleErr.Code() == rpcEChangedMode {
			// Wails may have initialized this UI thread as STA. WinRT remains
			// callable there; we just must not uninitialize its COM apartment.
			roInitialized = false
		} else if !ok || oleErr.Code() != 1 {
			return "", fmt.Errorf("initialize WinRT: %w", err)
		}
	}
	if roInitialized {
		defer windows.NewLazySystemDLL("combase.dll").NewProc("RoUninitialize").Call()
	}

	factoryInspectable, err := ole.RoGetActivationFactory(startupTaskRuntimeClass, ole.NewGUID(guidIStartupTaskStatics))
	if err != nil {
		return "", fmt.Errorf("get StartupTask activation factory: %w", err)
	}
	defer factoryInspectable.Release()
	factory := (*iStartupTaskStatics)(unsafe.Pointer(factoryInspectable))

	taskID, err := ole.NewHString(userStartupTaskID)
	if err != nil {
		return "", fmt.Errorf("create StartupTask id: %w", err)
	}
	defer ole.DeleteHString(taskID)

	var taskOperation *ole.IInspectable
	hr, _, _ := syscall.SyscallN(factory.VTable().GetAsync,
		uintptr(unsafe.Pointer(factory)), uintptr(taskID), uintptr(unsafe.Pointer(&taskOperation)))
	if failedHRESULT(hr) {
		return "", hresultError("get StartupTask", hr)
	}
	defer taskOperation.Release()

	taskInspectable, err := waitAsyncObject(ctx, taskOperation)
	if err != nil {
		return "", fmt.Errorf("get StartupTask result: %w", err)
	}
	defer taskInspectable.Release()
	task := (*iStartupTask)(unsafe.Pointer(taskInspectable))

	state, err := startupTaskState(task)
	if err != nil {
		return "", err
	}
	if action == "enable" && state == 0 { // Disabled is the only enableable state.
		var enableOperation *ole.IInspectable
		hr, _, _ = syscall.SyscallN(task.VTable().RequestEnableAsync,
			uintptr(unsafe.Pointer(task)), uintptr(unsafe.Pointer(&enableOperation)))
		if failedHRESULT(hr) {
			return "", hresultError("request StartupTask enable", hr)
		}
		defer enableOperation.Release()
		if _, err := waitAsyncInt32(ctx, enableOperation); err != nil {
			return "", fmt.Errorf("get StartupTask enable result: %w", err)
		}
		state, err = startupTaskState(task)
		if err != nil {
			return "", err
		}
	} else if action == "disable" {
		hr, _, _ = syscall.SyscallN(task.VTable().Disable, uintptr(unsafe.Pointer(task)))
		if failedHRESULT(hr) {
			return "", hresultError("disable StartupTask", hr)
		}
		state, err = startupTaskState(task)
		if err != nil {
			return "", err
		}
	}
	return startupTaskStateName(state), nil
}

func startupTaskState(task *iStartupTask) (int32, error) {
	var state int32
	hr, _, _ := syscall.SyscallN(task.VTable().State, uintptr(unsafe.Pointer(task)), uintptr(unsafe.Pointer(&state)))
	if failedHRESULT(hr) {
		return 0, hresultError("read StartupTask state", hr)
	}
	return state, nil
}

func waitAsyncObject(ctx context.Context, operation *ole.IInspectable) (*ole.IInspectable, error) {
	if err := waitAsync(ctx, operation); err != nil {
		return nil, err
	}
	vtable := (*iAsyncOperationVtbl)(unsafe.Pointer(operation.RawVTable))
	var result *ole.IInspectable
	hr, _, _ := syscall.SyscallN(vtable.GetResults, uintptr(unsafe.Pointer(operation)), uintptr(unsafe.Pointer(&result)))
	if failedHRESULT(hr) {
		return nil, hresultError("read async object result", hr)
	}
	return result, nil
}

func waitAsyncInt32(ctx context.Context, operation *ole.IInspectable) (int32, error) {
	if err := waitAsync(ctx, operation); err != nil {
		return 0, err
	}
	vtable := (*iAsyncOperationVtbl)(unsafe.Pointer(operation.RawVTable))
	var result int32
	hr, _, _ := syscall.SyscallN(vtable.GetResults, uintptr(unsafe.Pointer(operation)), uintptr(unsafe.Pointer(&result)))
	if failedHRESULT(hr) {
		return 0, hresultError("read async integer result", hr)
	}
	return result, nil
}

func waitAsync(ctx context.Context, operation *ole.IInspectable) error {
	var info *iAsyncInfo
	if err := operation.PutQueryInterface(ole.NewGUID(guidIAsyncInfo), &info); err != nil {
		return fmt.Errorf("query async status: %w", err)
	}
	defer info.Release()

	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		var status int32
		hr, _, _ := syscall.SyscallN(info.VTable().Status, uintptr(unsafe.Pointer(info)), uintptr(unsafe.Pointer(&status)))
		if failedHRESULT(hr) {
			return hresultError("read async status", hr)
		}
		switch status {
		case asyncCompleted:
			return nil
		case asyncCanceled:
			return errors.New("Windows canceled the StartupTask operation")
		case asyncError:
			var operationError int32
			_, _, _ = syscall.SyscallN(info.VTable().ErrorCode, uintptr(unsafe.Pointer(info)), uintptr(unsafe.Pointer(&operationError)))
			return hresultError("StartupTask operation", uintptr(uint32(operationError)))
		case asyncStarted:
		default:
			return fmt.Errorf("unknown StartupTask async status %d", status)
		}
		select {
		case <-ctx.Done():
			_, _, _ = syscall.SyscallN(info.VTable().Cancel, uintptr(unsafe.Pointer(info)))
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func failedHRESULT(hr uintptr) bool { return int32(hr) < 0 }

func hresultError(operation string, hr uintptr) error {
	return fmt.Errorf("%s: 0x%08X", operation, uint32(hr))
}

func encodePowerShell(script string) string {
	encoded := utf16.Encode([]rune(script))
	bytes := make([]byte, len(encoded)*2)
	for i, value := range encoded {
		bytes[i*2] = byte(value)
		bytes[i*2+1] = byte(value >> 8)
	}
	return base64.StdEncoding.EncodeToString(bytes)
}

func startupTaskStateName(state int32) string {
	switch state {
	case 0:
		return "Disabled"
	case 1:
		return "DisabledByUser"
	case 2:
		return "Enabled"
	case 3:
		return "DisabledByPolicy"
	case 4:
		return "EnabledByPolicy"
	default:
		return fmt.Sprintf("Unknown(%d)", state)
	}
}

func currentPackageFullName() (string, bool, error) {
	proc := windows.NewLazySystemDLL("kernel32.dll").NewProc("GetCurrentPackageFullName")
	var length uint32
	result, _, _ := proc.Call(uintptr(unsafe.Pointer(&length)), 0)
	if result == appModelErrorNoPackage {
		return "", false, nil
	}
	if result != errorInsufficientBuffer || length == 0 {
		return "", false, fmt.Errorf("GetCurrentPackageFullName size returned %d", result)
	}
	buffer := make([]uint16, length)
	result, _, _ = proc.Call(uintptr(unsafe.Pointer(&length)), uintptr(unsafe.Pointer(&buffer[0])))
	if result != 0 {
		return "", false, fmt.Errorf("GetCurrentPackageFullName returned %d", result)
	}
	return windows.UTF16ToString(buffer), true, nil
}

// commandRunner and encodePowerShell are also used by the Store-to-standalone
// handoff. StartupTask deliberately does not use them because child processes
// do not inherit MSIX package identity.
type commandRunner interface {
	Run(context.Context, string, ...string) ([]byte, error)
}

type processCommandRunner struct{}

func (processCommandRunner) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}
