//go:build windows

package service

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
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
	if _, err = NewProtectedStorage(paths.Service); err != nil {
		return nil, err
	}
	if _, err = NewProtectedStorage(paths.Updates); err != nil {
		return nil, err
	}
	if _, err = NewPublicStatusStorage(paths.Status); err != nil {
		return nil, err
	}
	inventory := NewWindowsInstallerInventory()
	return residentHealthSchedule(func(ctx context.Context) error {
		registration, err := inventory.Installed(ctx)
		if err != nil {
			return err
		}
		marker, err := readMachineProductMarker()
		if err != nil {
			return err
		}
		if _, err := installedProductSnapshot(registration, marker); err != nil {
			return err
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
		if err := verifyMachineMapiRegistrations(); err != nil {
			return err
		}
		return nil
	}), nil
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
