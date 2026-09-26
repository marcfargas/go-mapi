package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

const (
	SystemUpgradeCode = mapi.SystemUpgradeCode
	SuiteUpgradeCode  = mapi.SuiteUpgradeCode
)

var (
	ErrNoMachineProduct            = errors.New("no go-mapi machine product is installed")
	ErrMultipleMachineProducts     = errors.New("multiple go-mapi machine products are installed")
	ErrDuplicateMachineProduct     = errors.New("duplicate go-mapi machine product registration")
	ErrWindowsInstallerUnavailable = errors.New("Windows Installer inventory is unavailable")
)

type ProductRegistration struct {
	SKU            update.SKU
	UpgradeCode    string
	ProductCode    string
	ProductVersion string
}

// machineProductMarker corroborates MSI registration; registry values alone
// can never select the installed SKU or authorize an update.
type machineProductMarker struct {
	SKU, PackageRelease, ServiceVersion, InterceptorVersion, AppVersion string
}

func installedProductSnapshot(reg ProductRegistration, marker machineProductMarker) (ProductSnapshot, error) {
	if marker.SKU != string(reg.SKU) || marker.ServiceVersion == "" || marker.InterceptorVersion == "" {
		return ProductSnapshot{}, errors.New("installed machine marker does not match MSI registration")
	}
	identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(reg.SKU), marker.PackageRelease)
	if err != nil || reg.UpgradeCode != machineUpgradeCode(reg.SKU) || normalizeProductCode(reg.ProductCode) != identity.ProductCode || reg.ProductVersion != identity.ProductVersion {
		return ProductSnapshot{}, errors.New("installed machine identity does not match MSI registration")
	}
	contained := map[string]string{"service": marker.ServiceVersion, "interceptor": marker.InterceptorVersion}
	if reg.SKU == update.Suite {
		if marker.AppVersion == "" {
			return ProductSnapshot{}, errors.New("suite machine app version is missing")
		}
		contained["app"] = marker.AppVersion
	} else if marker.AppVersion != "" {
		return ProductSnapshot{}, errors.New("system-only machine has a suite app marker")
	}
	return ProductSnapshot{SKU: reg.SKU, PackageVersion: identity.Release, ProductVersion: identity.ProductVersion, ProductCode: identity.ProductCode, Contained: contained}, nil
}

func machineUpgradeCode(sku update.SKU) string {
	if sku == update.System {
		return SystemUpgradeCode
	}
	if sku == update.Suite {
		return SuiteUpgradeCode
	}
	return ""
}

// InstallerAPI is the narrow native Windows Installer seam. Its Windows
// implementation calls MsiEnumRelatedProductsW and MsiGetProductInfoW.
type InstallerAPI interface {
	RelatedProducts(upgradeCode string) ([]string, error)
	ProductVersion(productCode string) (string, error)
}

type InstallerInventory struct {
	api InstallerAPI
}

func NewInstallerInventory(api InstallerAPI) InstallerInventory {
	return InstallerInventory{api: api}
}

// Installed returns the single authoritative machine product registration.
// Zero or multiple system/suite products are an explicit repair condition,
// never a SKU-selection rule.
func (inventory InstallerInventory) Installed(ctx context.Context) (ProductRegistration, error) {
	registrations, err := inventory.Registrations(ctx)
	if err != nil {
		return ProductRegistration{}, err
	}
	return RequireSingleMachineProduct(registrations)
}

// The service can start before Windows Installer publishes its registration.
// Wait briefly for that one transient state before reporting repair required;
// any other inventory failure is reported immediately.
func awaitMachineProductRegistration(ctx context.Context, inventory InstallerInventory, grace time.Duration) (ProductRegistration, error) {
	if grace <= 0 {
		return inventory.Installed(ctx)
	}
	deadline := time.NewTimer(grace)
	defer deadline.Stop()
	retry := time.NewTicker(500 * time.Millisecond)
	defer retry.Stop()
	for {
		registration, err := inventory.Installed(ctx)
		if !errors.Is(err, ErrNoMachineProduct) {
			return registration, err
		}
		select {
		case <-ctx.Done():
			return ProductRegistration{}, ctx.Err()
		case <-deadline.C:
			return ProductRegistration{}, err
		case <-retry.C:
		}
	}
}

func (inventory InstallerInventory) Registrations(ctx context.Context) ([]ProductRegistration, error) {
	if inventory.api == nil {
		return nil, errors.New("Windows Installer API is required")
	}
	families := []struct {
		sku     update.SKU
		upgrade string
	}{
		{sku: update.System, upgrade: SystemUpgradeCode},
		{sku: update.Suite, upgrade: SuiteUpgradeCode},
	}
	var registrations []ProductRegistration
	seen := make(map[string]struct{})
	for _, family := range families {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		products, err := inventory.api.RelatedProducts(family.upgrade)
		if err != nil {
			return nil, fmt.Errorf("enumerate %s products: %w", family.sku, err)
		}
		for _, nativeProductCode := range products {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			productCode := normalizeProductCode(nativeProductCode)
			if productCode == "" {
				return nil, errors.New("Windows Installer returned an empty ProductCode")
			}
			if _, duplicate := seen[productCode]; duplicate {
				return nil, fmt.Errorf("%w: %s", ErrDuplicateMachineProduct, productCode)
			}
			seen[productCode] = struct{}{}
			version, err := inventory.api.ProductVersion(nativeProductCode)
			if err != nil {
				return nil, fmt.Errorf("read ProductVersion for %s: %w", productCode, err)
			}
			if version == "" {
				return nil, fmt.Errorf("empty ProductVersion for %s", productCode)
			}
			registrations = append(registrations, ProductRegistration{
				SKU: family.sku, UpgradeCode: family.upgrade,
				ProductCode: productCode, ProductVersion: version,
			})
		}
	}
	return registrations, nil
}

func RequireSingleMachineProduct(registrations []ProductRegistration) (ProductRegistration, error) {
	switch len(registrations) {
	case 0:
		return ProductRegistration{}, ErrNoMachineProduct
	case 1:
		return registrations[0], nil
	default:
		return ProductRegistration{}, ErrMultipleMachineProducts
	}
}

func normalizeProductCode(value string) string {
	return strings.ToUpper(strings.Trim(strings.TrimSpace(value), "{}"))
}
