package main

import (
	"testing"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

func TestMachineStatusIdentityRequiresOneExactNativeRegistration(t *testing.T) {
	identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKUSystem, "4.0.0")
	if err != nil {
		t.Fatal(err)
	}
	status := mapi.PublicStatusV2{SKU: "system", PackageVersion: "4.0.0", InterceptorVersion: "4.0.0"}
	registration := machineProductRegistration{SKU: "system", ProductCode: identity.ProductCode, ProductVersion: identity.ProductVersion}
	if got, ok := corroborateMachineStatusIdentity(status, []machineProductRegistration{registration}, "4.0.0", ""); !ok || got.PackageVersion != "4.0.0" {
		t.Fatalf("valid machine registration rejected: %+v, %v", got, ok)
	}
	for name, registrations := range map[string][]machineProductRegistration{
		"missing":       nil,
		"multiple":      {registration, registration},
		"wrong SKU":     {{SKU: "suite", ProductCode: identity.ProductCode, ProductVersion: identity.ProductVersion}},
		"wrong product": {{SKU: "system", ProductCode: "OTHER", ProductVersion: identity.ProductVersion}},
		"wrong version": {{SKU: "system", ProductCode: identity.ProductCode, ProductVersion: "4.0.1"}},
	} {
		if _, ok := corroborateMachineStatusIdentity(status, registrations, "4.0.0", ""); ok {
			t.Fatalf("%s registration was trusted", name)
		}
	}
	if _, ok := corroborateMachineStatusIdentity(status, []machineProductRegistration{registration}, "4.0.1", ""); ok {
		t.Fatal("different local interceptor was trusted")
	}
}

func TestSystemRepairRequiresCorroboratedPackageNotComponentVersion(t *testing.T) {
	id, err := mapi.NewMachinePackageIdentity(mapi.MachineSKUSystem, "4.0.2")
	if err != nil {
		t.Fatal(err)
	}
	registration := machineProductRegistration{SKU: "system", ProductCode: id.ProductCode, ProductVersion: id.ProductVersion}
	marker := map[string]string{"SKU": "system", "PackageRelease": "4.0.2", "ServiceVersion": "4.0.0", "InterceptorVersion": "4.0.1"}
	installed, err := corroborateAdminSystemInstallation([]machineProductRegistration{registration}, marker)
	if err != nil || installed.PackageRelease != "4.0.2" || installed.Versions["interceptor"] != "4.0.1" {
		t.Fatalf("%+v %v", installed, err)
	}
	for name, registrations := range map[string][]machineProductRegistration{
		"absent with marker": nil,
		"multiple":           {registration, registration},
		"Suite":              {{SKU: "suite", ProductCode: id.ProductCode, ProductVersion: id.ProductVersion}},
		"wrong package":      {{SKU: "system", ProductCode: id.ProductCode, ProductVersion: "4.0.1"}},
	} {
		if _, err := corroborateAdminSystemInstallation(registrations, marker); err == nil {
			t.Fatalf("accepted %s", name)
		}
	}
	for _, field := range []string{"SKU", "PackageRelease", "ServiceVersion", "InterceptorVersion"} {
		value := marker[field]
		marker[field] = "unknown"
		if _, err := corroborateAdminSystemInstallation([]machineProductRegistration{registration}, marker); err == nil {
			t.Fatalf("accepted invalid %s", field)
		}
		marker[field] = value
	}
}
