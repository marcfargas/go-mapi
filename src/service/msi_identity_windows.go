//go:build windows

package service

import (
	"context"
	"errors"
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	msiDatabaseDLL      = windows.NewLazySystemDLL("msi.dll")
	msiOpenDatabaseW    = msiDatabaseDLL.NewProc("MsiOpenDatabaseW")
	msiDatabaseOpenView = msiDatabaseDLL.NewProc("MsiDatabaseOpenViewW")
	msiViewExecute      = msiDatabaseDLL.NewProc("MsiViewExecute")
	msiViewFetch        = msiDatabaseDLL.NewProc("MsiViewFetch")
	msiRecordGetString  = msiDatabaseDLL.NewProc("MsiRecordGetStringW")
	msiCloseHandle      = msiDatabaseDLL.NewProc("MsiCloseHandle")
)

// The signed file, already pinned against writes/deletion by the runner, must
// name the exact product authorized in protected pending state. MSI signatures
// alone do not bind a package to its intended SKU or release.
func verifyStagedMSIIdentity(ctx context.Context, path string, pending PendingV1) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	product, err := msiProperty(path, "ProductCode")
	if err != nil {
		return err
	}
	version, err := msiProperty(path, "ProductVersion")
	if err != nil {
		return err
	}
	upgrade, err := msiProperty(path, "UpgradeCode")
	if err != nil {
		return err
	}
	if normalizeProductCode(product) != normalizeProductCode(pending.Candidate.ProductCode) ||
		version != pending.Candidate.ProductVersion ||
		normalizeProductCode(upgrade) != machineUpgradeCode(pending.SKU) {
		return errors.New("staged MSI identity differs from protected candidate")
	}
	return nil
}

func msiProperty(path, property string) (string, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return "", err
	}
	var database uintptr
	result, _, _ := msiOpenDatabaseW.Call(uintptr(unsafe.Pointer(name)), 0, uintptr(unsafe.Pointer(&database)))
	if result != 0 {
		return "", fmt.Errorf("open staged MSI database: %w", windows.Errno(result))
	}
	defer msiCloseHandle.Call(database)
	// property is a fixed internal name, never caller or metadata text.
	query, err := windows.UTF16PtrFromString("SELECT `Value` FROM `Property` WHERE `Property`='" + property + "'")
	if err != nil {
		return "", err
	}
	var view uintptr
	result, _, _ = msiDatabaseOpenView.Call(database, uintptr(unsafe.Pointer(query)), uintptr(unsafe.Pointer(&view)))
	if result != 0 {
		return "", fmt.Errorf("open staged MSI property view: %w", windows.Errno(result))
	}
	defer msiCloseHandle.Call(view)
	result, _, _ = msiViewExecute.Call(view, 0)
	if result != 0 {
		return "", fmt.Errorf("execute staged MSI property view: %w", windows.Errno(result))
	}
	var record uintptr
	result, _, _ = msiViewFetch.Call(view, uintptr(unsafe.Pointer(&record)))
	if result != 0 {
		return "", fmt.Errorf("read staged MSI property: %w", windows.Errno(result))
	}
	defer msiCloseHandle.Call(record)
	buffer := make([]uint16, 256)
	size := uint32(len(buffer))
	result, _, _ = msiRecordGetString.Call(record, 1, uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&size)))
	if result != 0 || size == 0 || size >= uint32(len(buffer)) {
		return "", errors.New("staged MSI property is absent or exceeds bound")
	}
	return windows.UTF16ToString(buffer[:size]), nil
}
