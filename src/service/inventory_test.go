package service

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
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

func TestInstalledProductSnapshotRequiresMSIAndCorroboratingMarker(t *testing.T) {
	for _, sku := range []update.SKU{update.System, update.Suite} {
		identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(sku), "4.0.1")
		if err != nil {
			t.Fatal(err)
		}
		reg := ProductRegistration{SKU: sku, UpgradeCode: machineUpgradeCode(sku), ProductCode: identity.ProductCode, ProductVersion: identity.ProductVersion}
		marker := machineProductMarker{SKU: string(sku), PackageRelease: identity.Release, ServiceVersion: "4.0.2", InterceptorVersion: "4.0.3"}
		if sku == update.Suite {
			marker.AppVersion = "4.0.4"
		}
		got, err := installedProductSnapshot(reg, marker)
		if err != nil || got.PackageVersion != identity.Release || got.Contained["service"] != marker.ServiceVersion || got.Contained["interceptor"] != marker.InterceptorVersion || got.Contained["app"] != marker.AppVersion {
			t.Fatalf("%s: snapshot=%+v error=%v", sku, got, err)
		}
		cases := []struct {
			name   string
			reg    ProductRegistration
			marker machineProductMarker
		}{
			{"wrong sku marker", reg, machineProductMarker{SKU: "other", PackageRelease: marker.PackageRelease, ServiceVersion: marker.ServiceVersion, InterceptorVersion: marker.InterceptorVersion, AppVersion: marker.AppVersion}},
			{"wrong product code", ProductRegistration{SKU: sku, UpgradeCode: reg.UpgradeCode, ProductCode: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", ProductVersion: reg.ProductVersion}, marker},
			{"wrong upgrade code", ProductRegistration{SKU: sku, UpgradeCode: "other", ProductCode: reg.ProductCode, ProductVersion: reg.ProductVersion}, marker},
			{"wrong product version", ProductRegistration{SKU: sku, UpgradeCode: reg.UpgradeCode, ProductCode: reg.ProductCode, ProductVersion: "0.0.0"}, marker},
			{"missing service", reg, machineProductMarker{SKU: marker.SKU, PackageRelease: marker.PackageRelease, InterceptorVersion: marker.InterceptorVersion, AppVersion: marker.AppVersion}},
		}
		if sku == update.Suite {
			cases = append(cases, struct {
				name   string
				reg    ProductRegistration
				marker machineProductMarker
			}{"missing app", reg, machineProductMarker{SKU: marker.SKU, PackageRelease: marker.PackageRelease, ServiceVersion: marker.ServiceVersion, InterceptorVersion: marker.InterceptorVersion}})
		}
		for _, tc := range cases {
			t.Run(string(sku)+"/"+tc.name, func(t *testing.T) {
				if _, err := installedProductSnapshot(tc.reg, tc.marker); err == nil {
					t.Fatal("accepted inconsistent machine product")
				}
			})
		}
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

func TestAwaitMachineProductRegistrationCoversMSIRegistrationGap(t *testing.T) {
	const code = "{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}"
	api := &fakeInstallerAPI{related: map[string][]string{}, versions: map[string]string{code: "4.0.1"}}
	api.afterRelated = func() { api.related[SystemUpgradeCode] = []string{code} }
	registration, err := awaitMachineProductRegistration(context.Background(), NewInstallerInventory(api), time.Second)
	if err != nil || registration.ProductVersion != "4.0.1" || registration.SKU != update.System {
		t.Fatalf("registration after transient MSI gap = %+v, %v", registration, err)
	}

	missing := NewInstallerInventory(&fakeInstallerAPI{related: map[string][]string{}})
	if _, err := awaitMachineProductRegistration(context.Background(), missing, 20*time.Millisecond); !errors.Is(err, ErrNoMachineProduct) {
		t.Fatalf("persistent missing registration error = %v, want repair condition", err)
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
