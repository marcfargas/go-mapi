package mapi

import "testing"

func TestMachinePackageIdentity(t *testing.T) {
	tests := []struct {
		name           string
		sku            MachineSKU
		release        string
		productVersion string
		productCode    string
		tag            string
		asset          string
		manifest       string
		targetPath     string
		sequence       uint64
	}{
		{
			name:           "stable system package",
			sku:            MachineSKUSystem,
			release:        "4.0.1",
			productVersion: "4.0.1",
			productCode:    "84780A03-2506-5D8F-80CA-C7DCE5B9A350",
			tag:            "system-v4.0.1",
			asset:          "go-mapi-system-4.0.1-x64.msi",
			manifest:       "go-mapi-system-4.0.1.manifest.json",
			targetPath:     "/machine/system/targets.json",
			sequence:       1<<26 | 1,
		},
		{
			name:           "development suite package",
			sku:            MachineSKUSuite,
			release:        "3.1.2-beta.7",
			productVersion: "3.1.2207",
			productCode:    "B765DBC6-0BB3-5628-B994-CBE5AE8EA761",
			tag:            "suite-v3.1.2-beta.7",
			asset:          "go-mapi-suite-3.1.2-beta.7-x64.msi",
			manifest:       "go-mapi-suite-3.1.2-beta.7.manifest.json",
			targetPath:     "/machine/suite/targets.json",
			sequence:       3<<24 | 1<<16 | 2207,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NewMachinePackageIdentity(tt.sku, tt.release)
			if err != nil {
				t.Fatalf("NewMachinePackageIdentity() error = %v", err)
			}
			if got.ProductVersion != tt.productVersion || got.ProductCode != tt.productCode {
				t.Errorf("MSI identity = %s/%s, want %s/%s", got.ProductVersion, got.ProductCode, tt.productVersion, tt.productCode)
			}
			if got.Tag != tt.tag || got.AssetName != tt.asset || got.ManifestName != tt.manifest {
				t.Errorf("publication identity = %s/%s/%s, want %s/%s/%s", got.Tag, got.AssetName, got.ManifestName, tt.tag, tt.asset, tt.manifest)
			}
			if got.TargetPath != tt.targetPath || got.Sequence != tt.sequence {
				t.Errorf("target identity = %s/%d, want %s/%d", got.TargetPath, got.Sequence, tt.targetPath, tt.sequence)
			}
		})
	}
}

func TestMachinePackageIdentityRejectsInvalidReleaseContracts(t *testing.T) {
	tests := []struct {
		name    string
		sku     MachineSKU
		release string
	}{
		{name: "unknown SKU", sku: "admin", release: "4.0.1"},
		{name: "build metadata", sku: MachineSKUSystem, release: "4.0.1+rebuilt"},
		{name: "odd stable major", sku: MachineSKUSystem, release: "3.1.1"},
		{name: "even development major", sku: MachineSKUSystem, release: "4.1.1-beta.1"},
		{name: "unsupported development stage", sku: MachineSKUSystem, release: "3.1.1-rc.1"},
		{name: "development patch overflow", sku: MachineSKUSystem, release: "3.1.66-beta.1"},
		{name: "development counter overflow", sku: MachineSKUSystem, release: "3.1.1-beta.100"},
		{name: "MSI stable build overflow", sku: MachineSKUSystem, release: "4.1.65536"},
		{name: "noncanonical leading zero", sku: MachineSKUSystem, release: "4.01.1"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := NewMachinePackageIdentity(tt.sku, tt.release); err == nil {
				t.Fatalf("NewMachinePackageIdentity(%q, %q) unexpectedly succeeded", tt.sku, tt.release)
			}
		})
	}
}

func TestMachinePackageFamiliesCannotCollide(t *testing.T) {
	system, err := NewMachinePackageIdentity(MachineSKUSystem, "4.2.0")
	if err != nil {
		t.Fatal(err)
	}
	suite, err := NewMachinePackageIdentity(MachineSKUSuite, "4.2.0")
	if err != nil {
		t.Fatal(err)
	}
	if system.ProductCode == suite.ProductCode || system.Tag == suite.Tag || system.AssetName == suite.AssetName || system.TargetPath == suite.TargetPath {
		t.Fatalf("machine package namespaces collide: system=%#v suite=%#v", system, suite)
	}
}

func TestMachinePackageSuccessorIsMonotonicWithinSKU(t *testing.T) {
	previous, err := NewMachinePackageIdentity(MachineSKUSuite, "3.1.2-beta.7")
	if err != nil {
		t.Fatal(err)
	}
	for _, release := range []string{"3.1.2-beta.8", "3.1.2-nightly.1", "3.1.3-alpha.1"} {
		next, err := NewMachinePackageIdentity(MachineSKUSuite, release)
		if err != nil {
			t.Fatal(err)
		}
		if err := ValidateMachinePackageSuccessor(previous, next); err != nil {
			t.Errorf("%s should succeed %s: %v", release, previous.Release, err)
		}
	}
	for _, test := range []struct {
		sku     MachineSKU
		release string
	}{
		{sku: MachineSKUSuite, release: "3.1.2-beta.7"},
		{sku: MachineSKUSuite, release: "3.1.2-alpha.99"},
		{sku: MachineSKUSystem, release: "4.0.2"},
	} {
		next, err := NewMachinePackageIdentity(test.sku, test.release)
		if err != nil {
			t.Fatal(err)
		}
		if err := ValidateMachinePackageSuccessor(previous, next); err == nil {
			t.Errorf("%s/%s unexpectedly accepted after %s/%s", next.SKU, next.Release, previous.SKU, previous.Release)
		}
	}
}
