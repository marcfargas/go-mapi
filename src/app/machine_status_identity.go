package main

import (
	"strings"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

type machineProductRegistration struct {
	SKU, ProductCode, ProductVersion string
}

// corroborateMachineStatusIdentity treats the protected status as a claim,
// then requires one independent Windows Installer registration to match its
// deterministic SKU/release identity. The interceptor and suite app versions
// are independently read from this installation.
func corroborateMachineStatusIdentity(status mapi.PublicStatusV2, registrations []machineProductRegistration, interceptorVersion, appVersion string) (mapi.InstalledStatusIdentity, bool) {
	if len(registrations) != 1 || !mapi.IsStrictReleaseVersion(interceptorVersion) || status.InterceptorVersion != interceptorVersion {
		return mapi.InstalledStatusIdentity{}, false
	}
	sku := mapi.MachineSKU(status.SKU)
	identity, err := mapi.NewMachinePackageIdentity(sku, status.PackageVersion)
	if err != nil || registrations[0].SKU != status.SKU ||
		!strings.EqualFold(strings.Trim(registrations[0].ProductCode, "{}"), identity.ProductCode) ||
		registrations[0].ProductVersion != identity.ProductVersion {
		return mapi.InstalledStatusIdentity{}, false
	}
	if sku == mapi.MachineSKUSuite && (status.AppVersion == "" || status.AppVersion != appVersion) ||
		sku == mapi.MachineSKUSystem && status.AppVersion != "" {
		return mapi.InstalledStatusIdentity{}, false
	}
	return mapi.InstalledStatusIdentity{SKU: status.SKU, PackageVersion: identity.Release, InterceptorVersion: interceptorVersion}, true
}
