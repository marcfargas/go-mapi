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

	"github.com/marcfargas/go-mapi/internal/mapi"
	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

// AdminReleaseMetadataURL is injected by the release build. It names the
// first-party System metadata origin; UI input never selects it.
var AdminReleaseMetadataURL string

func newProductionAdminRepairAttempt() adminRepairAttempt {
	if AdminReleaseMetadataURL == "" {
		return nil
	}
	client := &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	engine, err := update.NewEngine(update.Config{
		SKU: update.System, MetadataOrigin: AdminReleaseMetadataURL,
		ArtifactOrigin: update.MachineArtifactOrigin, Client: client, Now: time.Now,
	})
	if err != nil {
		logError("admin release: initialise updater: %v", err)
		return nil
	}
	store := adminReleaseSequenceStore{Path: filepath.Join(appDataDir(), "system-release-replay-v1.json")}
	return newAdminEngineRepairAttempt(engine, store, observeAdminSystemInstallation, update.InstallOptions{Stage: stagePrivilegedAdminMSI, Verify: verifyAdminMSI, Handoff: handoffAdminMSI})
}

type adminSystemInstallation struct {
	PackageRelease string
	Versions       map[string]string
}

func newAdminEngineRepairAttempt(engine *update.Engine, store adminReleaseSequenceStore, observe func() (adminSystemInstallation, error), options update.InstallOptions) adminRepairAttempt {
	return func(ctx context.Context, _ ComponentHealthState) (bool, error) {
		installed, err := observe()
		if err != nil {
			return false, err
		}
		accepted, err := store.Load()
		if err != nil {
			return false, err
		}
		var result update.CheckResult
		if installed.PackageRelease == "" {
			result, err = engine.Bootstrap(ctx, update.BootstrapRequest{AppVersion: Version, Track: mapi.ReleaseTrack(Version), Accepted: accepted,
				RequiredInterceptor: mapi.CounterpartRequirement{Component: "interceptor", MinInclusive: RequiredInterceptorMin, MaxExclusive: RequiredInterceptorMax}})
		} else {
			result, err = engine.Check(ctx, update.CheckRequest{
				Enabled: true, Force: true, AllowSameVersion: true, InstalledVersion: installed.PackageRelease,
				Installed: installed.Versions, Accepted: accepted,
			})
		}
		if err != nil || !result.Available {
			return false, err
		}
		payload := result.Candidate.Payload()
		if payload.Requires.Component != "app" || mapi.EvaluateCompatibility(Version,
			mapi.CounterpartRequirement{Component: "app", MinInclusive: payload.Requires.MinInclusive, MaxExclusive: payload.Requires.MaxExclusive}, "update-app").Status != mapi.CompatibilityCompatible {
			return false, errors.New("this System release does not support the installed App")
		}
		for _, component := range payload.Contained {
			if component.Component == "interceptor" && mapi.EvaluateCompatibility(component.Version,
				mapi.CounterpartRequirement{Component: "interceptor", MinInclusive: RequiredInterceptorMin, MaxExclusive: RequiredInterceptorMax}, "update-interceptor").Status != mapi.CompatibilityCompatible {
				return false, errors.New("this App does not support the selected System interceptor")
			}
		}
		installOptions := options
		installOptions.Handoff = func(ctx context.Context, prepared update.Prepared) error {
			current, err := observe()
			if err != nil || current.PackageRelease != installed.PackageRelease {
				prepared.Cleanup()
				return errors.New("machine installation changed while preparing System")
			}
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
	return func(context.Context, ComponentHealthState) (bool, error) {
		if _, err := observeAdminSystemInstallation(); err != nil {
			return false, err
		}
		return launchElevatedAdminHelper()
	}
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
