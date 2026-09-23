package service

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func TestInstallerInventoryEnumeratesBothFixedProductFamilies(t *testing.T) {
	api := &fakeInstallerAPI{
		related: map[string][]string{
			SystemUpgradeCode: {"{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}"},
			SuiteUpgradeCode:  nil,
		},
		versions: map[string]string{"{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}": "4.0.12"},
	}
	inventory := NewInstallerInventory(api)
	got, err := inventory.Registrations(context.Background())
	if err != nil {
		t.Fatalf("Registrations: %v", err)
	}
	want := []ProductRegistration{{
		SKU: update.System, UpgradeCode: SystemUpgradeCode,
		ProductCode: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", ProductVersion: "4.0.12",
	}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("registrations = %#v, want %#v", got, want)
	}
	if !reflect.DeepEqual(api.upgrades, []string{SystemUpgradeCode, SuiteUpgradeCode}) {
		t.Fatalf("enumerated UpgradeCodes = %q", api.upgrades)
	}
}

func TestInstallerInventoryRejectsZeroTwoAndDuplicateProducts(t *testing.T) {
	tests := []struct {
		name    string
		related map[string][]string
		wantErr error
	}{
		{name: "zero", related: map[string][]string{}, wantErr: ErrNoMachineProduct},
		{name: "two SKUs", related: map[string][]string{
			SystemUpgradeCode: {"{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}"},
			SuiteUpgradeCode:  {"{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}"},
		}, wantErr: ErrMultipleMachineProducts},
		{name: "duplicate registration", related: map[string][]string{
			SystemUpgradeCode: {"{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}", "{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}"},
		}, wantErr: ErrDuplicateMachineProduct},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			api := &fakeInstallerAPI{related: tt.related, versions: map[string]string{
				"{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}": "4.0.1",
				"{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}": "4.0.2",
			}}
			inventory := NewInstallerInventory(api)
			if tt.wantErr == ErrDuplicateMachineProduct {
				_, err := inventory.Registrations(context.Background())
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("Registrations error = %v", err)
				}
				return
			}
			if _, err := inventory.Installed(context.Background()); !errors.Is(err, tt.wantErr) {
				t.Fatalf("Installed error = %v", err)
			}
		})
	}
}

func TestInstallerInventoryHonorsCancellationBetweenNativeCalls(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	api := &fakeInstallerAPI{related: map[string][]string{
		SystemUpgradeCode: {"{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}"},
	}}
	api.afterRelated = cancel
	_, err := NewInstallerInventory(api).Registrations(ctx)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Registrations error = %v", err)
	}
}

type fakeInstallerAPI struct {
	related      map[string][]string
	versions     map[string]string
	upgrades     []string
	afterRelated func()
}

func (api *fakeInstallerAPI) RelatedProducts(upgradeCode string) ([]string, error) {
	api.upgrades = append(api.upgrades, upgradeCode)
	products := append([]string(nil), api.related[upgradeCode]...)
	if api.afterRelated != nil {
		api.afterRelated()
		api.afterRelated = nil
	}
	return products, nil
}

func (api *fakeInstallerAPI) ProductVersion(productCode string) (string, error) {
	return api.versions[productCode], nil
}
