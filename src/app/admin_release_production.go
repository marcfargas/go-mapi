package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

// AdminReleaseMetadataURL is injected by the release build. It names the
// first-party legacy interceptor target; UI input never selects it.
var AdminReleaseMetadataURL string

func newProductionAdminRepairAttempt() adminRepairAttempt {
	if AdminReleaseMetadataURL == "" {
		return nil
	}
	client := &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	engine, err := update.NewEngine(update.Config{
		SKU: update.LegacyAdmin, MetadataOrigin: AdminReleaseMetadataURL,
		ArtifactOrigin: update.MachineArtifactOrigin, Client: client, Now: time.Now,
	})
	if err != nil {
		logError("admin release: initialise updater: %v", err)
		return nil
	}
	store := adminReleaseSequenceStore{Path: filepath.Join(appDataDir(), "admin-release-replay-v1.json")}
	return newAdminEngineRepairAttempt(engine, store, func() (string, map[string]string) {
		installed := installedInterceptorUpdateVersion()
		return installed, map[string]string{"app": Version, "interceptor": installed}
	}, update.InstallOptions{Stage: stagePrivilegedAdminMSI, Verify: verifyAdminMSI, Handoff: handoffAdminMSI})
}

func newAdminEngineRepairAttempt(engine *update.Engine, store adminReleaseSequenceStore, observe func() (string, map[string]string), options update.InstallOptions) adminRepairAttempt {
	return func(ctx context.Context, _ ComponentHealthState) (bool, error) {
		accepted, err := store.Load()
		if err != nil {
			return false, err
		}
		installed, versions := observe()
		result, err := engine.Check(ctx, update.CheckRequest{
			Enabled: true, Force: true, AllowSameVersion: true, InstalledVersion: installed,
			Installed: versions, Accepted: accepted,
		})
		if err != nil || !result.Available {
			return false, err
		}
		installOptions := options
		installOptions.Handoff = func(ctx context.Context, prepared update.Prepared) error {
			if err := store.Accept(prepared.Release()); err != nil {
				return fmt.Errorf("accept admin release sequence: %w", err)
			}
			// This handoff waits for msiexec; the app can release its staged MSI
			// as soon as the installer returns, including reboot-required exits.
			defer prepared.Cleanup()
			return options.Handoff(ctx, prepared)
		}
		_, err = engine.Install(ctx, result.Candidate, installOptions)
		if errors.Is(err, errAdminMSIRebootRequired) {
			return true, nil
		}
		return false, err
	}
}

func newUnelevatedAdminRepairAttempt() adminRepairAttempt {
	if newProductionAdminRepairAttempt() == nil {
		return nil
	}
	return func(context.Context, ComponentHealthState) (bool, error) { return launchElevatedAdminHelper() }
}

func runElevatedAdminInstall(ctx context.Context) error {
	attempt := newProductionAdminRepairAttempt()
	if attempt == nil {
		return errAdminReleaseContractUnavailable
	}
	reboot, err := attempt(ctx, ComponentHealthState{})
	if reboot {
		return errAdminMSIRebootRequired
	}
	return err
}

// stageAdminMSIAt gives the shared downloader a protected file writer. It
// performs no network fetch or second artifact verification.
func stageAdminMSIAt(ctx context.Context, root string, candidate update.Candidate, write func(io.Writer) error) (string, func(), error) {
	_ = ctx
	payload := candidate.Payload()
	dir := filepath.Join(root, payload.Version)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", nil, err
	}
	file, err := os.CreateTemp(dir, ".admin-msi-*.msi")
	if err != nil {
		return "", nil, err
	}
	path := file.Name()
	cleanup := func() { _ = os.Remove(path) }
	if err := file.Chmod(0600); err != nil {
		file.Close()
		cleanup()
		return "", nil, err
	}
	if err := write(file); err != nil {
		file.Close()
		cleanup()
		return "", nil, err
	}
	if err := file.Close(); err != nil {
		cleanup()
		return "", nil, err
	}
	return path, cleanup, nil
}
