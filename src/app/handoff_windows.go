//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"golang.org/x/sys/windows/registry"
)

const standaloneUninstallKey = `Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi-user-v4`

// StorePackageFamilyName is injected from the single protected Partner Center
// identity source. An empty value disables automatic Store handoff in local
// development builds.
var StorePackageFamilyName = ""

type windowsHandoffPlatform struct{ runner commandRunner }

func newHandoffPlatform() handoffPlatform {
	return &windowsHandoffPlatform{runner: processCommandRunner{}}
}

func (p *windowsHandoffPlatform) CurrentChannel() (installChannel, error) {
	_, packaged, err := currentPackageFullName()
	if err != nil {
		return "", err
	}
	if packaged {
		return channelStore, nil
	}
	return channelStandalone, nil
}

func (p *windowsHandoffPlatform) IsInstalled(ctx context.Context, channel installChannel) (bool, error) {
	switch channel {
	case channelStandalone:
		key, err := registry.OpenKey(registry.CURRENT_USER, standaloneUninstallKey, registry.QUERY_VALUE)
		if errors.Is(err, registry.ErrNotExist) {
			return false, nil
		}
		if err != nil {
			return false, err
		}
		key.Close()
		return true, nil
	case channelStore:
		if StorePackageFamilyName == "" {
			return false, nil
		}
		if err := validatePackageFamilyName(StorePackageFamilyName); err != nil {
			return false, err
		}
		script := fmt.Sprintf(`$p = Get-AppxPackage | Where-Object { $_.PackageFamilyName -eq '%s' } | Select-Object -First 1; if ($null -eq $p) { 'false' } else { 'true' }`, StorePackageFamilyName)
		out, err := p.runner.Run(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encodePowerShell(script))
		if err != nil {
			return false, fmt.Errorf("query Store package: %w (%s)", err, strings.TrimSpace(string(out)))
		}
		return powershellBooleanOutput(out), nil
	default:
		return false, fmt.Errorf("unknown channel %q", channel)
	}
}

// powershellBooleanOutput tolerates PowerShell's CLIXML progress records. In
// non-interactive sessions those records can share stderr with the actual
// stdout boolean, while processCommandRunner captures both streams so callers
// retain failure diagnostics.
func powershellBooleanOutput(out []byte) bool {
	for _, field := range strings.Fields(string(out)) {
		if strings.EqualFold(field, "true") {
			return true
		}
	}
	return false
}

func (p *windowsHandoffPlatform) RemoveSource(ctx context.Context, source installChannel) error {
	switch source {
	case channelStandalone:
		key, err := registry.OpenKey(registry.CURRENT_USER, standaloneUninstallKey, registry.QUERY_VALUE)
		if errors.Is(err, registry.ErrNotExist) {
			return deleteStandaloneStartupRegistration()
		}
		if err != nil {
			return err
		}
		uninstall, _, valueErr := key.GetStringValue("UninstallString")
		key.Close()
		if valueErr != nil {
			return valueErr
		}
		uninstaller := strings.Trim(strings.TrimSpace(uninstall), `"`)
		if err := validateStandaloneUninstaller(uninstaller); err != nil {
			return err
		}
		out, err := p.runner.Run(ctx, uninstaller, "/S")
		if err != nil {
			return fmt.Errorf("standalone preserve-data uninstall: %w (%s)", err, strings.TrimSpace(string(out)))
		}
		// The standalone uninstaller owns removal of its per-user startup
		// registration. Verification below confirms it is absent.
		return nil
	case channelStore:
		installed, err := p.IsInstalled(ctx, channelStore)
		if err != nil || !installed {
			return err
		}
		script := fmt.Sprintf(`Get-AppxPackage | Where-Object { $_.PackageFamilyName -eq '%s' } | Remove-AppxPackage -ErrorAction Stop`, StorePackageFamilyName)
		out, err := p.runner.Run(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encodePowerShell(script))
		if err != nil {
			return fmt.Errorf("remove Store package: %w (%s)", err, strings.TrimSpace(string(out)))
		}
		return nil
	default:
		return fmt.Errorf("unknown source channel %q", source)
	}
}

func deleteStandaloneStartupRegistration() error {
	return (windowsStartupRegistrationStore{}).Delete()
}

func (p *windowsHandoffPlatform) VerifyTargetOnly(ctx context.Context, target installChannel) error {
	source := channelStandalone
	if target == channelStandalone {
		source = channelStore
	}
	sourceInstalled, err := p.IsInstalled(ctx, source)
	if err != nil {
		return err
	}
	if sourceInstalled {
		return fmt.Errorf("source channel %s is still installed", source)
	}
	targetInstalled, err := p.IsInstalled(ctx, target)
	if err != nil {
		return err
	}
	if !targetInstalled {
		return fmt.Errorf("target channel %s is not installed", target)
	}
	if target == channelStore {
		if _, err := (windowsStartupRegistrationStore{}).Read(); err == nil {
			return errors.New("standalone startup registration remains after Store handoff")
		} else if !errors.Is(err, registry.ErrNotExist) {
			return fmt.Errorf("verify standalone startup registration: %w", err)
		}
	}
	return nil
}

func (p *windowsHandoffPlatform) Activate(ctx context.Context, channel installChannel) error {
	switch channel {
	case channelStore:
		if err := validatePackageFamilyName(StorePackageFamilyName); err != nil {
			return err
		}
		return exec.CommandContext(ctx, "explorer.exe", `shell:AppsFolder\`+StorePackageFamilyName+`!App`).Start()
	case channelStandalone:
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		return exec.CommandContext(ctx, exe).Start()
	default:
		return fmt.Errorf("unknown target channel %q", channel)
	}
}

func validatePackageFamilyName(value string) error {
	if !regexp.MustCompile(`^[A-Za-z0-9._-]+$`).MatchString(value) {
		return errors.New("invalid Store package family name")
	}
	return nil
}

func validateStandaloneUninstaller(path string) error {
	localAppData := os.Getenv("LOCALAPPDATA")
	if localAppData == "" {
		return errors.New("LOCALAPPDATA is unavailable")
	}
	root := filepath.Clean(filepath.Join(localAppData, "Programs", "go-mapi"))
	clean := filepath.Clean(path)
	rel, err := filepath.Rel(root, clean)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") || !strings.EqualFold(filepath.Base(clean), "uninstall.exe") {
		return fmt.Errorf("refusing unexpected standalone uninstaller %q", path)
	}
	return nil
}

// startupHandoffAction runs after the session mutex is acquired and before
// settings or the queue watcher. A non-empty activation target means the
// caller must release its mutex, activate the target, and exit.
func startupHandoffAction(ctx context.Context) (installChannel, error) {
	platform := newHandoffPlatform()
	coordinator := &handoffCoordinator{platform: platform}
	current, err := platform.CurrentChannel()
	if err != nil {
		return "", err
	}
	journal, journalErr := loadHandoffJournal()
	if journalErr == nil {
		if current == journal.Source {
			return journal.Target, nil
		}
		if current != journal.Target {
			return "", errors.New("handoff journal does not match the running channel")
		}
		return "", coordinator.Resume(ctx)
	}
	if !errors.Is(journalErr, os.ErrNotExist) {
		return "", journalErr
	}
	if current == channelStandalone {
		storeInstalled, err := platform.IsInstalled(ctx, channelStore)
		if err != nil {
			return "", err
		}
		if storeInstalled {
			if _, err := coordinator.Begin(channelStandalone, channelStore); err != nil {
				return "", err
			}
			return channelStore, nil
		}
	}
	return "", nil
}

func runStoreToStandaloneHandoff(ctx context.Context) error {
	platform := newHandoffPlatform()
	storeInstalled, err := platform.IsInstalled(ctx, channelStore)
	if err != nil || !storeInstalled {
		return err
	}
	coordinator := &handoffCoordinator{platform: platform}
	if _, err := coordinator.Begin(channelStore, channelStandalone); err != nil {
		return err
	}
	// An absent event means the Store app is not running; the journal still
	// authorizes the operation. If it is running, it validates the journal.
	_ = requestExistingInstanceShutdown()
	if err := waitForExistingInstanceExit(20 * time.Second); err != nil {
		return err
	}
	raised, err := acquireSingleInstance()
	if err != nil {
		return err
	}
	if raised {
		return errors.New("another go-mapi instance remained active during handoff")
	}
	defer releaseSingleInstance()
	return coordinator.Resume(ctx)
}

// prepareStoreTargetHandoff runs before normal mutex acquisition so the first
// Store launch can shut down a currently running standalone source instead of
// being mistaken for an ordinary second instance and exiting.
func prepareStoreTargetHandoff(ctx context.Context) error {
	platform := newHandoffPlatform()
	current, err := platform.CurrentChannel()
	if err != nil || current != channelStore {
		return err
	}
	standaloneInstalled, err := platform.IsInstalled(ctx, channelStandalone)
	if err != nil || !standaloneInstalled {
		return err
	}
	coordinator := &handoffCoordinator{platform: platform}
	if _, err := coordinator.Begin(channelStandalone, channelStore); err != nil {
		return err
	}
	_ = requestExistingInstanceShutdown()
	return waitForExistingInstanceExit(20 * time.Second)
}
