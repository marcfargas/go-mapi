//go:build windows

package service

import (
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	msiErrorSuccess     = 0
	msiErrorMoreData    = 234
	msiErrorNoMoreItems = 259
	msiVersionString    = "VersionString"
)

var (
	msiDLL                     = windows.NewLazySystemDLL("msi.dll")
	msiEnumRelatedProductsProc = msiDLL.NewProc("MsiEnumRelatedProductsW")
	msiGetProductInfoProc      = msiDLL.NewProc("MsiGetProductInfoW")
)

// NewWindowsInstallerInventory uses only Windows Installer's native product
// registration API. It does not enumerate profiles, Store packages, or the
// standalone per-user installer.
func NewWindowsInstallerInventory() InstallerInventory {
	return NewInstallerInventory(nativeInstallerAPI{})
}

type nativeInstallerAPI struct{}

func (nativeInstallerAPI) RelatedProducts(upgradeCode string) ([]string, error) {
	nativeUpgradeCode, err := windows.UTF16PtrFromString("{" + normalizeProductCode(upgradeCode) + "}")
	if err != nil {
		return nil, fmt.Errorf("encode UpgradeCode: %w", err)
	}
	var products []string
	for index := uint32(0); ; index++ {
		var productCode [39]uint16
		result, _, _ := msiEnumRelatedProductsProc.Call(
			uintptr(unsafe.Pointer(nativeUpgradeCode)),
			0,
			uintptr(index),
			uintptr(unsafe.Pointer(&productCode[0])),
		)
		switch uint32(result) {
		case msiErrorSuccess:
			products = append(products, windows.UTF16ToString(productCode[:]))
		case msiErrorNoMoreItems:
			return products, nil
		default:
			return nil, fmt.Errorf("MsiEnumRelatedProductsW(%s, %d): %w", upgradeCode, index, windows.Errno(result))
		}
	}
}

func (nativeInstallerAPI) ProductVersion(productCode string) (string, error) {
	nativeProductCode, err := windows.UTF16PtrFromString("{" + normalizeProductCode(productCode) + "}")
	if err != nil {
		return "", fmt.Errorf("encode ProductCode: %w", err)
	}
	property, _ := windows.UTF16PtrFromString(msiVersionString)
	capacity := uint32(32)
	for {
		buffer := make([]uint16, capacity)
		size := capacity
		result, _, _ := msiGetProductInfoProc.Call(
			uintptr(unsafe.Pointer(nativeProductCode)),
			uintptr(unsafe.Pointer(property)),
			uintptr(unsafe.Pointer(&buffer[0])),
			uintptr(unsafe.Pointer(&size)),
		)
		switch uint32(result) {
		case msiErrorSuccess:
			return windows.UTF16ToString(buffer), nil
		case msiErrorMoreData:
			capacity = size + 1
		default:
			return "", fmt.Errorf("MsiGetProductInfoW(%s, %s): %w", productCode, msiVersionString, windows.Errno(result))
		}
	}
}
