package service

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

const (
	SystemUpgradeCode = "B3C97B33-3F10-47CA-9FA7-24EE3B75E325"
	SuiteUpgradeCode  = "2E050A24-94A2-4FC9-B176-C5CCC1225FE6"
)

var (
	ErrNoMachineProduct        = errors.New("no go-mapi machine product is installed")
	ErrMultipleMachineProducts = errors.New("multiple go-mapi machine products are installed")
	ErrDuplicateMachineProduct = errors.New("duplicate go-mapi machine product registration")
)

type ProductRegistration struct {
	SKU            update.SKU
	UpgradeCode    string
	ProductCode    string
	ProductVersion string
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
