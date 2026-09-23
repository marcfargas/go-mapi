//go:build windows

package service

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
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
		executable, err := os.Executable()
		if err != nil {
			return err
		}
		expected := filepath.Clean(filepath.Join(os.Getenv("ProgramFiles"), "go-mapi", "service", "go-mapi-service.exe"))
		if expected == "." || !filepath.IsAbs(expected) || !equalWindowsPath(executable, expected) {
			return errors.New("resident service is not running from its fixed installed path")
		}
		if registration.UpgradeCode == "" || registration.ProductCode == "" || registration.ProductVersion == "" {
			return errors.New("installed machine product health is incomplete")
		}
		return nil
	}), nil
}

func equalWindowsPath(left, right string) bool {
	return strings.EqualFold(filepath.Clean(left), filepath.Clean(right))
}
