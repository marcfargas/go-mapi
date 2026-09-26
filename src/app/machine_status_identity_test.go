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
