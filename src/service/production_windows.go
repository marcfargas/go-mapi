//go:build windows

package service

import (
	"context"
	"debug/pe"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

func NewProductionResidentSchedule() (Schedule, error) {
	programData, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, windows.KF_FLAG_DEFAULT)
	if err != nil {
		return nil, err
	}
	paths, err := NewProgramDataPaths(programData)
	if err != nil {
		return nil, err
	}
	stateStorage, err := NewProtectedStorage(paths.Service)
	if err != nil {
		return nil, err
	}
	updateStorage, err := NewProtectedStorage(paths.Updates)
	if err != nil {
		return nil, err
	}
	statusStorage, err := NewPublicStatusStorage(paths.Status)
	if err != nil {
		return nil, err
	}
	statusStore, err := NewPublicStatusStore(statusStorage)
	if err != nil {
		return nil, err
	}
	pendingStore, err := NewFileStateStore(stateStorage)
	if err != nil {
		return nil, err
	}
	replayStore, err := NewFileReplayStore(stateStorage)
	if err != nil {
		return nil, err
	}
	lastResultStore, err := NewFileLastResultStore(stateStorage)
	if err != nil {
		return nil, err
	}
	inventory := NewWindowsInstallerInventory()
	return residentHealthSchedule(func(ctx context.Context) (checkErr error) {
		status := PublicStatusV1{Schema: PublicStatusSchemaV1, Updates: "unknown", Code: EventRepairNeeded, Health: "repair-required", UpdatedAt: time.Now().UTC()}
		defer func() {
			if err := statusStore.Save(context.WithoutCancel(ctx), status); err != nil {
				checkErr = errors.Join(checkErr, fmt.Errorf("publish resident status: %w", err))
			}
		}()
		// A replacement service may inherit a durably authorized suspended
		// installer. Finish that exact thread before observing product health.
		if err := RecoverAuthorizedInstaller(stateStorage); err != nil {
			return fmt.Errorf("recover authorized installer: %w", err)
		}
		if enabled, settingErr := readMachineAutoUpdate(); settingErr == nil {
			if enabled {
				status.Updates = "enabled"
			} else {
				status.Updates = "disabled"
			}
		}
		last, err := lastResultStore.Load(ctx)
		if err != nil {
			return fmt.Errorf("load last transaction result: %w", err)
		}
		if last != nil {
			status.LastResult, status.LastResultAt = last.Result, last.FinishedAt
		}
		pending, err := pendingStore.Load(ctx)
		if err != nil {
			return fmt.Errorf("load pending transaction: %w", err)
		}
		if pending != nil {
			status.SKU = pending.SKU
			outcome, retired, err := reconcileResidentTerminal(ctx, *pending, pendingStore.Load,
				func(ctx context.Context, transaction PendingV1) (Outcome, error) {
					return reconcileProductionPending(ctx, inventory, pendingStore, replayStore, lastResultStore, stateStorage, updateStorage, transaction)
				})
			if errors.Is(err, ErrVerificationUnavailable) {
				status.Code = EventUnverified
				status.Health = ""
				status.Signature = "unavailable"
				return nil
			}
			if err != nil {
				return fmt.Errorf("reconcile resident transaction: %w", err)
			}
			if !retired {
				applyActiveOutcomeStatus(&status, *pending, outcome)
				return nil
			}
			status.Code = publicEventForOutcome(outcome)
			last, err = lastResultStore.Load(ctx)
			if err != nil {
				return fmt.Errorf("load retired transaction result: %w", err)
			}
			if last != nil {
				status.LastResult, status.LastResultAt = last.Result, last.FinishedAt
			}
		}
		registration, err := awaitMachineProductRegistration(ctx, inventory, 30*time.Second)
		if err != nil {
			return err
		}
		status.SKU = registration.SKU
		marker, err := readMachineProductMarker()
		if err != nil {
			return err
		}
		snapshot, err := installedProductSnapshot(registration, marker)
		if err != nil {
			return err
		}
		status.PackageVersion = snapshot.PackageVersion
		if err := verifyProductionInstalledHealth(ctx, snapshot, registration, marker); err != nil {
			return err
		}
		status.ServiceVersion = marker.ServiceVersion
		status.InterceptorVersion = marker.InterceptorVersion
		status.AppVersion = marker.AppVersion
		status.Health = "healthy"
		if err := verifyProductionSignatures(ctx, snapshot); err != nil {
			if errors.Is(err, ErrVerificationUnavailable) {
				status.Code = EventUnverified
				status.Signature = "unavailable"
				return nil
			}
			status.Signature = "invalid"
			return err
		}
		status.Signature = "verified"
		if status.Code != EventCommitted && status.Code != EventRolledBack {
			status.Code = EventPending
		}
		return nil
	}), nil
}

func reconcileProductionPending(ctx context.Context, inventory InstallerInventory, pending PendingStore, replay ReplayStore, lastResult LastResultStore, stateStorage, updateStorage *ProtectedStorage, transaction PendingV1) (Outcome, error) {
	products := productInventoryFunc(func(ctx context.Context) ([]InstalledProduct, error) {
		reg, err := inventory.Installed(ctx)
		if err != nil {
			return nil, err
		}
		marker, err := readMachineProductMarker()
		if err != nil {
			return nil, err
		}
		product, err := installedProductSnapshot(reg, marker)
		if err != nil {
			return nil, err
		}
		return []InstalledProduct{{Snapshot: product}}, nil
	})
	health := healthProbeFunc(func(ctx context.Context, product ProductSnapshot) (bool, error) {
		reg, err := inventory.Installed(ctx)
		if err != nil {
			return false, err
		}
		marker, err := readMachineProductMarker()
		if err != nil {
			return false, err
		}
		actual, err := installedProductSnapshot(reg, marker)
		if err != nil || !sameProduct(actual, product) {
			return false, err
		}
		if err := verifyProductionInstalledHealth(ctx, actual, reg, marker); err != nil {
			return false, err
		}
		if err := verifyProductionSignatures(ctx, actual); err != nil {
			return false, err
		}
		return true, nil
	})
	deps := Dependencies{
		Inventory: products, Health: health, Processes: WindowsProcessProbe{},
		InstallerServer: WindowsInstallerServerProbe{}, Pending: pending,
		Replay: replay, LastResult: lastResult, Events: discardEvents{}, Clock: wallClock{},
		Boot: WindowsBootIdentity{},
	}
	if transaction.Schema == PendingSchemaV2 && transaction.Phase == PhasePrepared && transaction.Attempt > 1 && transaction.RetryDeadline != nil && time.Now().UTC().Before(*transaction.RetryDeadline) {
		launcher, err := NewProductionDetachedRunnerLauncher(stateStorage, updateStorage)
		if err != nil {
			return "", err
		}
		deps.Launcher, deps.RetryGate = launcher, productionRetryGate{}
	}
	reconciler, err := NewReconciler(Config{SKU: transaction.SKU, MaxInstallerBusyRetries: 3}, deps)
	if err != nil {
		return "", err
	}
	if deps.Launcher != nil {
		return reconciler.ResumePreparedRetry(ctx)
	}
	return reconciler.Reconcile(ctx)
}

func verifyProductionInstalledHealth(ctx context.Context, snapshot ProductSnapshot, registration ProductRegistration, marker machineProductMarker) error {
	if registration.SKU != update.System && registration.SKU != update.Suite || snapshot.SKU != registration.SKU {
		return errors.New("installed machine identity changed")
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	programFiles, err := windows.KnownFolderPath(windows.FOLDERID_ProgramFilesX64, windows.KF_FLAG_DEFAULT)
	if err != nil {
		return err
	}
	expected := filepath.Join(programFiles, "go-mapi", "service", "go-mapi-service.exe")
	if !equalWindowsPath(executable, expected) {
		return errors.New("resident service is not running from its fixed installed path")
	}
	if err := newStoragePlatform().checkPath(programFiles, expected, true); err != nil {
		return err
	}
	if err := verifyInstalledPEMachine(expected, pe.IMAGE_FILE_MACHINE_AMD64); err != nil {
		return err
	}
	serviceVersion, err := installedPEProductVersion(expected)
	if err != nil || serviceVersion != marker.ServiceVersion || serviceVersion != Version {
		return errors.New("resident service PE version does not match installed product")
	}
	interceptor := filepath.Join(programFiles, "go-mapi", "interceptor")
	for _, path := range []string{
		filepath.Join(interceptor, "installed-component-v1.json"),
		filepath.Join(interceptor, "x86", "go-mapi.dll"),
		filepath.Join(interceptor, "AMD64", "go-mapi.dll"),
	} {
		if err := newStoragePlatform().checkPath(programFiles, path, true); err != nil {
			return err
		}
	}
	if err := verifyInstalledInterceptor(ctx, interceptor, marker.InterceptorVersion, marker.AppVersion); err != nil {
		return err
	}
	for _, binary := range []struct {
		path    string
		machine uint16
	}{
		{filepath.Join(interceptor, "x86", "go-mapi.dll"), pe.IMAGE_FILE_MACHINE_I386},
		{filepath.Join(interceptor, "AMD64", "go-mapi.dll"), pe.IMAGE_FILE_MACHINE_AMD64},
	} {
		path := binary.path
		if err := verifyInstalledPEMachine(path, binary.machine); err != nil {
			return err
		}
		actual, err := installedPEProductVersion(path)
		if err != nil || actual != marker.InterceptorVersion {
			return errors.New("installed interceptor PE version does not match installed product")
		}
	}
	if err := verifyMachineMapiRegistrations(); err != nil {
		return err
	}
	if err := verifyResidentServiceConfiguration(expected); err != nil {
		return err
	}
	if snapshot.SKU == update.Suite {
		if err := verifyInstalledSuite(programFiles, marker.AppVersion); err != nil {
			return err
		}
	}
	return nil
}

// Windows checks the installed binaries' Authenticode signatures. Structural
// health stays separately observable even when Windows cannot verify trust.
func verifyProductionSignatures(ctx context.Context, snapshot ProductSnapshot) error {
	programFiles, err := windows.KnownFolderPath(windows.FOLDERID_ProgramFilesX64, windows.KF_FLAG_DEFAULT)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrVerificationUnavailable, err)
	}
	paths := []string{
		filepath.Join(programFiles, "go-mapi", "service", "go-mapi-service.exe"),
		filepath.Join(programFiles, "go-mapi", "interceptor", "x86", "go-mapi.dll"),
		filepath.Join(programFiles, "go-mapi", "interceptor", "AMD64", "go-mapi.dll"),
	}
	if snapshot.SKU == update.Suite {
		paths = append(paths, filepath.Join(programFiles, "go-mapi", "user", "go-mapi.exe"))
	}
	verifier := WindowsAuthenticodeVerifier{}
	for _, path := range paths {
		if err := verifier.VerifyAuthenticode(ctx, path); err != nil {
			if windowsTrustUnavailable(err) {
				return fmt.Errorf("%w: Windows could not check signature revocation: %v", ErrVerificationUnavailable, err)
			}
			return fmt.Errorf("installed component signature: %w", err)
		}
	}
	return nil
}

// These WinVerifyTrust results mean Windows could not complete its own
// revocation check. They do not establish an invalid signature. Every other
// nonzero result remains a failed trust decision.
func windowsTrustUnavailable(err error) bool {
	for _, code := range []syscall.Errno{
		0x80092011, // CRYPT_E_NO_REVOCATION_DLL
		0x80092012, // CRYPT_E_NO_REVOCATION_CHECK
		0x80092013, // CRYPT_E_REVOCATION_OFFLINE
		0x800B010E, // CERT_E_REVOCATION_FAILURE
	} {
		if errors.Is(err, code) {
			return true
		}
	}
	return false
}

func verifyResidentServiceConfiguration(executable string) error {
	manager, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer manager.Disconnect()
	service, err := manager.OpenService(ServiceName)
	if err != nil {
		return err
	}
	defer service.Close()
	configuration, err := service.Config()
	if err != nil {
		return err
	}
	// WiX quotes the executable path and appends one fixed service verb.
	command := `"` + executable + `" service`
	if !strings.EqualFold(strings.TrimSpace(configuration.BinaryPathName), command) ||
		configuration.ServiceType != windows.SERVICE_WIN32_OWN_PROCESS ||
		configuration.StartType != windows.SERVICE_AUTO_START ||
		!strings.EqualFold(configuration.ServiceStartName, "LocalSystem") ||
		configuration.SidType != windows.SERVICE_SID_TYPE_UNRESTRICTED ||
		!configuration.DelayedAutoStart {
		return errors.New("resident SCM configuration does not match machine package")
	}
	actions, err := service.RecoveryActions()
	if err != nil {
		return err
	}
	if len(actions) != 3 || actions[0].Type != mgr.ServiceRestart || actions[1].Type != mgr.ServiceRestart || actions[2].Type != mgr.NoAction ||
		actions[0].Delay != time.Minute || actions[1].Delay != time.Minute {
		return errors.New("resident SCM recovery actions do not match machine package")
	}
	state, err := service.Query()
	if err != nil {
		return err
	}
	if state.State != svc.Running {
		return errors.New("resident SCM service is not running")
	}
	return nil
}

func verifyInstalledSuite(programFiles, appVersion string) error {
	app := filepath.Join(programFiles, "go-mapi", "user", "go-mapi.exe")
	if err := newStoragePlatform().checkPath(programFiles, app, true); err != nil {
		return err
	}
	if err := verifyInstalledPEMachine(app, pe.IMAGE_FILE_MACHINE_AMD64); err != nil {
		return err
	}
	version, err := installedPEProductVersion(app)
	if err != nil || version != appVersion {
		return errors.New("installed suite app PE version does not match machine product")
	}
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows\CurrentVersion\Run`, registry.QUERY_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return err
	}
	startup, valueType, startupErr := key.GetStringValue("go-mapi-user-machine-v4")
	key.Close()
	if startupErr != nil || valueType != registry.SZ || !strings.EqualFold(startup, `"`+app+`" --startup --machine-install`) {
		return errors.New("suite machine startup registration does not match installed app")
	}
	commonData, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, windows.KF_FLAG_DEFAULT)
	if err != nil {
		return err
	}
	shortcut := filepath.Join(commonData, "Microsoft", "Windows", "Start Menu", "Programs", "go-mapi", "go-mapi.lnk")
	if err := newStoragePlatform().checkPath(commonData, shortcut, true); err != nil {
		return err
	}
	return nil
}

func readMachineAutoUpdate() (bool, error) {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\go-mapi\MachineProduct`, registry.QUERY_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return false, err
	}
	defer key.Close()
	value, valueType, err := key.GetIntegerValue("AutoUpdateEnabled")
	if err != nil || valueType != registry.DWORD || value > 1 {
		return false, errors.New("machine automatic update setting is missing or invalid")
	}
	return value == 1, nil
}

func authorizeMachineInstaller(context.Context) error {
	enabled, err := readMachineAutoUpdate()
	if err != nil || !enabled {
		return errors.New("machine automatic update setting does not authorize installation")
	}
	return nil
}

type productionRetryGate struct{}

func (productionRetryGate) AllowRetry(ctx context.Context, _ PendingV1) (bool, error) {
	if err := authorizeMachineInstaller(ctx); err != nil {
		return false, nil
	}
	return true, nil
}

func verifyMachineMapiRegistrations() error {
	const mailKey = `SOFTWARE\Clients\Mail`
	const expectedDLLPath = `%ProgramW6432%\go-mapi\interceptor\%PROCESSOR_ARCHITECTURE%\go-mapi.dll`
	for _, view := range []uint32{registry.WOW64_32KEY, registry.WOW64_64KEY} {
		mail, err := registry.OpenKey(registry.LOCAL_MACHINE, mailKey, registry.QUERY_VALUE|view)
		if err != nil {
			return err
		}
		provider, _, providerErr := mail.GetStringValue("")
		mail.Close()
		client, err := registry.OpenKey(registry.LOCAL_MACHINE, mailKey+`\go-mapi`, registry.QUERY_VALUE|view)
		if err != nil {
			return err
		}
		dllPath, valueType, pathErr := client.GetStringValue("DLLPath")
		client.Close()
		if providerErr != nil || pathErr != nil || !strings.EqualFold(provider, "go-mapi") ||
			valueType != registry.EXPAND_SZ || !strings.EqualFold(dllPath, expectedDLLPath) {
			return errors.New("machine MAPI registration does not match installed interceptor")
		}
	}
	return nil
}

func readMachineProductMarker() (machineProductMarker, error) {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\go-mapi\MachineProduct`, registry.QUERY_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return machineProductMarker{}, err
	}
	defer key.Close()
	read := func(name string) (string, error) {
		value, _, err := key.GetStringValue(name)
		return value, err
	}
	var marker machineProductMarker
	if marker.SKU, err = read("SKU"); err != nil {
		return marker, err
	}
	if marker.PackageRelease, err = read("PackageRelease"); err != nil {
		return marker, err
	}
	if marker.ServiceVersion, err = read("ServiceVersion"); err != nil {
		return marker, err
	}
	if marker.InterceptorVersion, err = read("InterceptorVersion"); err != nil {
		return marker, err
	}
	if marker.SKU == "suite" {
		if marker.AppVersion, err = read("AppVersion"); err != nil {
			return marker, err
		}
	} else if marker.AppVersion, _, err = key.GetStringValue("AppVersion"); err != nil && !errors.Is(err, registry.ErrNotExist) {
		return marker, err
	}
	return marker, nil
}

func equalWindowsPath(left, right string) bool {
	return strings.EqualFold(filepath.Clean(left), filepath.Clean(right))
}
