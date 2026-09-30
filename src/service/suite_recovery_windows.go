//go:build windows

package service

import (
	"context"
	"fmt"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func markerMatchesSuite(snapshot ProductSnapshot, marker machineProductMarker) bool {
	return snapshot.SKU == update.Suite && marker.SKU == "suite" && marker.PackageRelease == snapshot.PackageVersion &&
		marker.ServiceVersion == snapshot.Contained["service"] && marker.InterceptorVersion == snapshot.Contained["interceptor"] && marker.AppVersion == snapshot.Contained["app"]
}

func retireProvedSuiteRepair(ctx context.Context, gate *SuiteAdmission, store *FileStateStore, last *FileLastResultStore, expected PendingV1, observed ProductSnapshot) error {
	return gate.withExclusive(ctx, func(lock *suiteAdmissionLock) error {
		if err := lock.write('C'); err != nil {
			return err
		}
		return store.CompareAndRetireRepair(ctx, expected, last, func() error {
			marker, err := readMachineProductMarker()
			if err != nil {
				return err
			}
			if !markerMatchesSuite(observed, marker) {
				return ErrStateConflict
			}
			return nil
		})
	})
}

// openHealthySuite is the only writer of O. It repeats full health with runner
// exclusion, then checks the cheap marker, empty state and an idle Windows
// Installer under admission -> state.lock before the flushed publication. A
// busy installer returns an error that wraps ErrSuiteInstallerBusy.
func openHealthySuite(ctx context.Context, gate *SuiteAdmission, store *FileStateStore, stateStorage *ProtectedStorage, inventory InstallerInventory, expected ProductSnapshot) error {
	return openHealthySuiteWithServer(ctx, gate, store, stateStorage, inventory, expected, WindowsInstallerServerProbe{})
}

func openHealthySuiteWithServer(ctx context.Context, gate *SuiteAdmission, store *FileStateStore, stateStorage *ProtectedStorage, inventory InstallerInventory, expected ProductSnapshot, server InstallerServerProbe) error {
	runner, err := tryOwnRunnerLock(stateStorage)
	if err != nil {
		return err
	}
	defer runner.Close()
	// The caller has just proved the installed suite healthy and observed no
	// pending transaction. O needs no new publication; an unrelated MSI may
	// keep msiserver running or own its execute mutex during this heartbeat.
	open, err := gate.IsOpen(ctx)
	if err != nil {
		return err
	}
	if open {
		return nil
	}
	idle, err := server.Idle(ctx, false)
	if err != nil {
		return err
	}
	if !idle {
		return fmt.Errorf("installer server is not idle: %w", ErrSuiteInstallerBusy)
	}
	registration, err := inventory.Installed(ctx)
	if err != nil {
		return err
	}
	marker, err := readMachineProductMarker()
	if err != nil {
		return err
	}
	observed, err := installedProductSnapshot(registration, marker)
	if err != nil {
		return err
	}
	if !sameProduct(observed, expected) {
		return ErrStateConflict
	}
	if err := verifyProductionInstalledHealth(ctx, observed, registration, marker); err != nil {
		return err
	}
	idle, err = server.Idle(ctx, false)
	if err != nil {
		return err
	}
	if !idle {
		return fmt.Errorf("installer server changed during health proof: %w", ErrSuiteInstallerBusy)
	}
	registration, err = inventory.Installed(ctx)
	if err != nil {
		return err
	}
	marker, err = readMachineProductMarker()
	if err != nil {
		return err
	}
	confirmed, err := installedProductSnapshot(registration, marker)
	if err != nil {
		return err
	}
	if !sameProduct(confirmed, observed) {
		return ErrStateConflict
	}
	return publishSuiteOpenWhenIdle(ctx, gate, store, server, func() error {
		marker, err := readMachineProductMarker()
		if err != nil {
			return err
		}
		if !markerMatchesSuite(observed, marker) {
			return ErrStateConflict
		}
		return nil
	})
}

// publishSuiteOpenWhenIdle repeats the installer idle check under the gate
// and state locks, immediately before O is written. A machine transaction
// writes C under the same gate lock after it owns the installer: one that
// owns the installer before this check makes it fail, and one that starts
// later writes its C after this O. Each idle probe briefly owns the MSI
// execute mutex, as every earlier probe does.
func publishSuiteOpenWhenIdle(ctx context.Context, gate *SuiteAdmission, store *FileStateStore, server InstallerServerProbe, checks ...func() error) error {
	return gate.withExclusive(ctx, func(lock *suiteAdmissionLock) error {
		idle := func() error {
			idle, err := server.Idle(ctx, false)
			if err != nil {
				return err
			}
			if !idle {
				return fmt.Errorf("installer server became busy before admission opened: %w", ErrSuiteInstallerBusy)
			}
			return nil
		}
		return store.PublishSuiteOpen(ctx, lock.write, append(append([]func() error{}, checks...), idle)...)
	})
}
