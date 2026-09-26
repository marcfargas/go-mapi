//go:build windows

package service

import (
	"context"
	"crypto/rand"
	"debug/pe"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
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
	admission, err := NewSuiteAdmission(statusStorage)
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
	discoveryStore, err := NewFileDiscoveryStore(stateStorage)
	if err != nil {
		return nil, err
	}
	var statusMu sync.Mutex
	currentStatus := residentStatus{Updates: "unknown", Code: EventRepairNeeded, Health: "repair-required", UpdatedAt: time.Now().UTC()}
	var discoveryState DiscoveryState
	var healthObservedAt time.Time
	engines := make(map[update.SKU]*update.Engine, 2)
	coordinators := make(map[update.SKU]*Coordinator, 2)
	origin, originErr := EmbeddedMachineMetadataOrigin()
	if originErr != nil && !errors.Is(originErr, ErrMachineTrustUnavailable) {
		return nil, originErr
	}
	if originErr == nil {
		checkInterval, err := machineCheckInterval()
		if err != nil {
			return nil, err
		}
		client, err := NewMachineHTTPClient()
		if err != nil {
			return nil, err
		}
		for _, sku := range []update.SKU{update.System, update.Suite} {
			engine, err := update.NewEngine(update.Config{SKU: sku, MetadataOrigin: origin, ArtifactOrigin: update.MachineArtifactOrigin, Client: client, Now: time.Now, SuccessInterval: checkInterval})
			if err != nil {
				return nil, err
			}
			coordinator, err := newProductionMachineCoordinator(sku, stateStorage, updateStorage, pendingStore, replayStore, lastResultStore, inventory)
			if err != nil {
				return nil, err
			}
			engines[sku], coordinators[sku] = engine, coordinator
		}
	}
	publish := func(ctx context.Context) error {
		statusMu.Lock()
		defer statusMu.Unlock()
		currentStatus.UpdatedAt = time.Now().UTC()
		checkerResult := "unavailable"
		if currentStatus.Updates == "disabled" {
			checkerResult = "disabled"
		} else if len(engines) != 0 && discoveryState.SKU == currentStatus.SKU {
			checkerResult = discoveryState.Result
			if (checkerResult == "available" || checkerResult == "no-update") && !discoveryState.Effective(currentStatus.UpdatedAt, currentStatus.PackageVersion) {
				checkerResult = "unavailable"
			}
		}
		statusV2 := mapi.PublicStatusV2{
			Schema: mapi.PublicStatusSchemaV2, SKU: string(currentStatus.SKU), PackageVersion: currentStatus.PackageVersion,
			ServiceVersion: currentStatus.ServiceVersion, InterceptorVersion: currentStatus.InterceptorVersion, AppVersion: currentStatus.AppVersion,
			Health: currentStatus.Health, Updates: currentStatus.Updates, Code: string(currentStatus.Code),
			LastResult: string(currentStatus.LastResult), LastResultAt: currentStatus.LastResultAt,
			Capability: "unavailable", Checker: checkerResult, UpdatedAt: currentStatus.UpdatedAt, HealthObservedAt: healthObservedAt,
		}
		if len(engines) != 0 && currentStatus.Health == "healthy" &&
			(currentStatus.Code == EventPending || currentStatus.Code == EventCommitted || currentStatus.Code == EventRolledBack) {
			statusV2.Capability = "discovery"
			if coordinators[currentStatus.SKU] != nil {
				statusV2.Capability = "automatic"
			}
		}
		if discoveryState.SKU == currentStatus.SKU {
			statusV2.LastAttemptAt, statusV2.LastSuccessAt, statusV2.NextAttemptAt = discoveryState.LastAttemptAt, discoveryState.LastSuccessAt, discoveryState.NextAttemptAt
			if checkerResult == "available" || checkerResult == "no-update" {
				statusV2.CandidateExpiresAt = discoveryState.CandidateExpiresAt
			}
			if checkerResult == "available" {
				statusV2.CandidateVersion = discoveryState.CandidateVersion
			}
		}
		return statusStore.Save(context.WithoutCancel(ctx), statusV2)
	}
	healthCheck := func(ctx context.Context) (checkErr error) {
		status := residentStatus{Updates: "unknown", Code: EventRepairNeeded, Health: "repair-required", UpdatedAt: time.Now().UTC()}
		preparedOnly := false
		defer func() {
			if err := closeUnhealthySuiteAdmission(ctx, admission, preparedOnly, status.Health); err != nil {
				checkErr = errors.Join(checkErr, err)
			}
			statusMu.Lock()
			currentStatus = status
			if status.Health == "healthy" {
				healthObservedAt = time.Now().UTC()
			}
			statusMu.Unlock()
			if err := publish(ctx); err != nil {
				checkErr = errors.Join(checkErr, fmt.Errorf("publish resident status: %w", err))
			}
		}()
		// Classify the merely-prepared exception even if recovery fails before
		// the normal pending read. Unreadable state must close an earlier O.
		initialPending, err := pendingStore.LoadBounded(ctx)
		if err != nil {
			return fmt.Errorf("load pending transaction: %w", err)
		}
		preparedOnly = merelyPreparedSuitePending(initialPending)
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
		pending, err := pendingStore.LoadBounded(ctx)
		if err != nil {
			preparedOnly = false
			return fmt.Errorf("load pending transaction: %w", err)
		}
		preparedOnly = merelyPreparedSuitePending(pending)
		if pending != nil {
			status.SKU = pending.SKU
			outcome, retired, currentPrepared, err := reconcileResidentSuitePending(ctx, *pending, pendingStore.Load, pendingStore.LoadBounded,
				func(ctx context.Context, transaction PendingV1) (Outcome, error) {
					return reconcileProductionPending(ctx, inventory, pendingStore, replayStore, lastResultStore, stateStorage, updateStorage, admission, transaction)
				}, admission.Close)
			preparedOnly = currentPrepared
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
		if snapshot.SKU == update.Suite {
			if err := openHealthySuite(ctx, admission, pendingStore, stateStorage, inventory, snapshot); err != nil {
				return err
			}
		}
		status.ServiceVersion = marker.ServiceVersion
		status.InterceptorVersion = marker.InterceptorVersion
		status.AppVersion = marker.AppVersion
		status.Health = "healthy"
		if status.Code != EventCommitted && status.Code != EventRolledBack {
			status.Code = EventPending
		}
		return nil
	}
	heartbeat := func(ctx context.Context) error {
		// A repair, independent MSI upgrade or pending recovery can change the
		// installed identity between six-hour full probes. Reverify it before
		// carrying a fresh publication timestamp forward.
		registration, observeErr := inventory.Installed(ctx)
		var marker machineProductMarker
		var snapshot ProductSnapshot
		if observeErr == nil {
			marker, observeErr = readMachineProductMarker()
		}
		if observeErr == nil {
			snapshot, observeErr = installedProductSnapshot(registration, marker)
		}
		pending, pendingErr := pendingStore.LoadBounded(ctx)
		admissionOpen := true
		if snapshot.SKU == update.Suite {
			var gateErr error
			admissionOpen, gateErr = admission.IsOpen(ctx)
			if gateErr != nil {
				admissionOpen = false
			}
		}
		statusMu.Lock()
		changed := observeErr != nil || pendingErr != nil || pending != nil || !admissionOpen || currentStatus.Health != "healthy" || currentStatus.SKU != snapshot.SKU ||
			currentStatus.PackageVersion != snapshot.PackageVersion || currentStatus.ServiceVersion != marker.ServiceVersion ||
			currentStatus.InterceptorVersion != marker.InterceptorVersion || currentStatus.AppVersion != marker.AppVersion
		statusMu.Unlock()
		if changed {
			return healthCheck(ctx)
		}
		statusMu.Lock()
		if enabled, err := readMachineAutoUpdate(); err == nil {
			if enabled {
				currentStatus.Updates = "enabled"
			} else {
				currentStatus.Updates = "disabled"
			}
		} else {
			currentStatus.Updates = "unknown"
		}
		statusMu.Unlock()
		return publish(ctx)
	}
	var attemptMu sync.Mutex
	var checkedCandidate update.Candidate
	var checkedSKU update.SKU
	var discoveryCheck func(context.Context) (bool, error)
	if len(engines) != 0 {
		discoveryCheck = func(ctx context.Context) (bool, error) {
			attemptMu.Lock()
			defer attemptMu.Unlock()
			checkedCandidate = update.Candidate{}
			enabled, err := readMachineAutoUpdate()
			if err != nil {
				return false, err
			}
			registration, err := inventory.Installed(ctx)
			if err != nil {
				return false, err
			}
			marker, err := readMachineProductMarker()
			if err != nil {
				return false, err
			}
			installed, err := installedProductSnapshot(registration, marker)
			if err != nil {
				return false, err
			}
			engine := engines[installed.SKU]
			if engine == nil {
				return false, ErrUnauthorizedCandidate
			}
			state, err := discoveryStore.Load(ctx, installed.SKU)
			if err != nil {
				return false, err
			}
			committed, err := replayStore.Load(ctx, installed.SKU)
			if err != nil {
				return false, err
			}
			result, checkErr := engine.Check(ctx, update.CheckRequest{
				Enabled:          enabled,
				State:            update.CheckState{LastAttemptAt: state.LastAttemptAt, LastSuccessAt: state.LastSuccessAt, NextAttemptAt: state.NextAttemptAt, Failures: state.Failures},
				InstalledVersion: installed.PackageVersion, Installed: installed.Contained,
				Accepted: state.Accepted, Committed: committed,
				OnAttempt: func(attempt update.CheckState) error {
					state.InstalledVersion = installed.PackageVersion
					state.LastAttemptAt, state.NextAttemptAt = attempt.LastAttemptAt, attempt.NextAttemptAt
					state.Result, state.CandidateVersion, state.CandidateExpiresAt = "checking", "", time.Time{}
					return discoveryStore.Save(context.WithoutCancel(ctx), state)
				},
			})
			if result.Checked {
				state.InstalledVersion = installed.PackageVersion
				state.LastAttemptAt, state.LastSuccessAt, state.NextAttemptAt, state.Failures = result.State.LastAttemptAt, result.State.LastSuccessAt, result.State.NextAttemptAt, result.State.Failures
				state.CandidateVersion = ""
				state.CandidateExpiresAt = time.Time{}
				if checkErr != nil {
					state.Result = "rejected"
				} else {
					state.Accepted, state.CandidateExpiresAt = result.Accepted, result.ExpiresAt
					state.Result = "no-update"
					if result.Available {
						state.Result = "available"
						state.CandidateVersion = result.Candidate.Payload().Version
					}
				}
				if saveErr := discoveryStore.Save(context.WithoutCancel(ctx), state); saveErr != nil {
					return false, errors.Join(checkErr, saveErr)
				}
				statusMu.Lock()
				discoveryState = state
				statusMu.Unlock()
			}
			if err := publish(ctx); err != nil {
				return false, errors.Join(checkErr, err)
			}
			if checkErr != nil || !result.Checked || !result.Available {
				return false, checkErr
			}
			current, stillEnabled, observeErr := observeMachineForUpdate(ctx, inventory)
			if observeErr != nil || !stillEnabled || !sameProduct(current, installed) {
				return false, errors.Join(ErrStateConflict, observeErr)
			}
			checkedCandidate, checkedSKU = result.Candidate, installed.SKU
			return true, nil
		}
	}
	var installCheck func(context.Context) error
	if len(coordinators) != 0 {
		installCheck = func(ctx context.Context) error {
			attemptMu.Lock()
			defer attemptMu.Unlock()
			engine, coordinator := engines[checkedSKU], coordinators[checkedSKU]
			if engine == nil || coordinator == nil || checkedCandidate.Release().Namespace() != string(checkedSKU) {
				return ErrUnauthorizedCandidate
			}
			candidate := checkedCandidate
			checkedCandidate = update.Candidate{}
			artifacts, err := NewProtectedArtifactStore(updateStorage, stateStorage)
			if err != nil {
				return err
			}
			var staged StagedArtifact
			_, err = engine.Install(ctx, candidate, update.InstallOptions{
				BeforePrepare: func(ctx context.Context, c update.Candidate) error {
					if err := authorizeMachineInstaller(ctx); err != nil {
						return err
					}
					eligible, err := coordinator.Eligible(ctx, c.Release())
					if err != nil {
						return err
					}
					if !eligible {
						return ErrUnauthorizedCandidate
					}
					return nil
				},
				Stage: func(ctx context.Context, c update.Candidate, write func(io.Writer) error) (string, func(), error) {
					var err error
					staged, err = artifacts.StageWith(ctx, c.Release(), write)
					if err != nil {
						return "", nil, err
					}
					components := strings.Split(staged.Handle, "/")
					path, err := updateStorage.resolve(components...)
					if err != nil {
						return "", func() { _ = artifacts.Discard(context.Background(), staged) }, err
					}
					return path, func() { _ = artifacts.Discard(context.Background(), staged) }, nil
				},
				Verify: (WindowsAuthenticodeVerifier{}).VerifyAuthenticode,
				Handoff: func(ctx context.Context, prepared update.Prepared) error {
					_, err := coordinator.InstallPrepared(ctx, prepared.Release(), staged)
					return err
				},
			})
			var next func(update.CheckState) update.CheckState
			if err == nil {
				next = engine.InstallSuccessState
			} else if !errors.Is(err, ErrUnauthorizedCandidate) {
				next = engine.InstallFailureState
			}
			if next != nil {
				state, stateErr := persistMachineInstallCheckState(context.WithoutCancel(ctx), discoveryStore, checkedSKU, next)
				if stateErr != nil {
					return errors.Join(err, stateErr)
				}
				statusMu.Lock()
				discoveryState = state
				statusMu.Unlock()
				if publishErr := publish(ctx); publishErr != nil {
					return errors.Join(err, publishErr)
				}
			}
			return err
		}
	}
	return residentManagedSchedule(healthCheck, discoveryCheck, installCheck, heartbeat), nil
}

func closeUnhealthySuiteAdmission(ctx context.Context, admission *SuiteAdmission, merelyPrepared bool, health string) error {
	if health == "healthy" || merelyPrepared {
		return nil
	}
	if err := admission.Close(context.WithoutCancel(ctx)); err != nil {
		return fmt.Errorf("close unhealthy suite admission: %w", err)
	}
	return nil
}

func observeMachineForUpdate(ctx context.Context, inventory InstallerInventory) (ProductSnapshot, bool, error) {
	enabled, err := readMachineAutoUpdate()
	if err != nil {
		return ProductSnapshot{}, false, err
	}
	registration, err := inventory.Installed(ctx)
	if err != nil {
		return ProductSnapshot{}, false, err
	}
	marker, err := readMachineProductMarker()
	if err != nil {
		return ProductSnapshot{}, false, err
	}
	product, err := installedProductSnapshot(registration, marker)
	return product, enabled, err
}

type productionTransactionIDs struct{}

func (productionTransactionIDs) NewID() string {
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return ""
	}
	return hex.EncodeToString(bytes[:])
}

// Both machine SKUs use the same protected installation and recovery path.
func newProductionMachineCoordinator(sku update.SKU, stateStorage, updateStorage *ProtectedStorage,
	pending *FileStateStore, replay *FileReplayStore, lastResult *FileLastResultStore,
	inventory InstallerInventory) (*Coordinator, error) {
	launcher, err := NewProductionDetachedRunnerLauncher(sku, stateStorage, updateStorage)
	if err != nil {
		return nil, err
	}
	prepare, err := NewFilePreparationAuthorizer(stateStorage, func(context.Context) (machineProductMarker, bool, error) {
		marker, err := readMachineProductMarker()
		if err != nil {
			return machineProductMarker{}, false, err
		}
		enabled, err := readMachineAutoUpdate()
		return marker, enabled, err
	})
	if err != nil {
		return nil, err
	}
	observe := func(ctx context.Context) (PreparationObservation, error) {
		enabled, err := readMachineAutoUpdate()
		if err != nil || !enabled {
			return PreparationObservation{}, errors.New("automatic machine update is disabled or unavailable")
		}
		registration, err := inventory.Installed(ctx)
		if err != nil {
			return PreparationObservation{}, err
		}
		marker, err := readMachineProductMarker()
		if err != nil {
			return PreparationObservation{}, err
		}
		product, err := installedProductSnapshot(registration, marker)
		if err != nil || product.SKU != sku {
			return PreparationObservation{}, errors.New("installed product SKU changed")
		}
		if err := verifyProductionInstalledHealth(ctx, product, registration, marker); err != nil {
			return PreparationObservation{}, err
		}
		return PreparationObservation{Product: product, Marker: marker, Enabled: true}, nil
	}
	products := productInventoryFunc(func(ctx context.Context) ([]InstalledProduct, error) {
		registration, err := inventory.Installed(ctx)
		if err != nil {
			return nil, err
		}
		marker, err := readMachineProductMarker()
		if err != nil {
			return nil, err
		}
		product, err := installedProductSnapshot(registration, marker)
		if err != nil {
			return nil, err
		}
		return []InstalledProduct{{Snapshot: product}}, nil
	})
	health := healthProbeFunc(func(ctx context.Context, product ProductSnapshot) (bool, error) {
		observation, err := observe(ctx)
		return err == nil && sameProduct(observation.Product, product), err
	})
	return NewCoordinator(Config{SKU: sku, MaxInstallerBusyRetries: 3}, Dependencies{
		Inventory: products,
		Launcher:  launcher, RetryGate: productionRetryGate{}, Health: health,
		Processes: WindowsProcessProbe{}, InstallerServer: WindowsInstallerServerProbe{},
		Pending: pending, Replay: replay, LastResult: lastResult,
		Events: discardEvents{}, Clock: wallClock{}, Boot: WindowsBootIdentity{},
		IDs:                productionTransactionIDs{},
		PreparationEnabled: func(context.Context) (bool, error) { return readMachineAutoUpdate() },
		ObservePreparation: observe, PrepareAuthorization: prepare,
	})
}

func reconcileProductionPending(ctx context.Context, inventory InstallerInventory, pending PendingStore, replay ReplayStore, lastResult LastResultStore, stateStorage, updateStorage *ProtectedStorage, admission *SuiteAdmission, transaction PendingV1) (Outcome, error) {
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
		return true, nil
	})
	deps := Dependencies{
		Inventory: products, Health: health, Processes: WindowsProcessProbe{},
		InstallerServer: WindowsInstallerServerProbe{}, Pending: pending,
		Replay: replay, LastResult: lastResult, Events: discardEvents{}, Clock: wallClock{},
		Boot: WindowsBootIdentity{},
	}
	if transaction.SKU == update.Suite {
		stateFile, ok := pending.(*FileStateStore)
		resultFile, okResult := lastResult.(*FileLastResultStore)
		if ok && okResult {
			deps.RecoveryLock = func() (func(), error) {
				lock, err := tryOwnRunnerLock(stateStorage)
				if err != nil {
					return nil, err
				}
				return func() { _ = lock.Close() }, nil
			}
			deps.RetireRepair = func(ctx context.Context, expected PendingV1, observed ProductSnapshot) error {
				return retireProvedSuiteRepair(ctx, admission, stateFile, resultFile, expected, observed)
			}
		}
	}
	if transaction.Schema == PendingSchemaV2 && transaction.Phase == PhasePrepared && transaction.Attempt > 1 && transaction.RetryDeadline != nil && time.Now().UTC().Before(*transaction.RetryDeadline) {
		launcher, err := NewProductionDetachedRunnerLauncher(transaction.SKU, stateStorage, updateStorage)
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

// The detached runner makes this final observation after creating msiexec
// suspended. A changed installation or disabled setting cannot resume that
// child, even if the coordinator's earlier pending write was valid.
func authorizePendingMachineInstaller(ctx context.Context, pending PendingV1) error {
	if err := authorizeMachineInstaller(ctx); err != nil {
		return err
	}
	registration, err := NewWindowsInstallerInventory().Installed(ctx)
	if err != nil {
		return err
	}
	marker, err := readMachineProductMarker()
	if err != nil {
		return err
	}
	installed, err := installedProductSnapshot(registration, marker)
	if err != nil {
		return err
	}
	if err := authorizePendingProductSnapshot(pending, installed); err != nil {
		return err
	}
	return authorizeMachineInstaller(ctx)
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
