//go:build windows

package main

import (
	"errors"
	"unsafe"

	"github.com/marcfargas/go-mapi/internal/mapi"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

var (
	appMSIDLL                     = windows.NewLazySystemDLL("msi.dll")
	appMSIEnumRelatedProductsProc = appMSIDLL.NewProc("MsiEnumRelatedProductsW")
	appMSIGetProductInfoProc      = appMSIDLL.NewProc("MsiGetProductInfoW")
)

const (
	appMSISuccess     = 0
	appMSIMoreData    = 234
	appMSINoMoreItems = 259
)

// installedMachineStatusIdentity uses read-only Windows Installer and SCM
// queries. It never opens a service or product with mutation rights.
func installedMachineStatusIdentity(status mapi.PublicStatusV2) (mapi.InstalledStatusIdentity, bool) {
	if !queryProtectedMachineMarkerMatches(status) {
		return mapi.InstalledStatusIdentity{}, false
	}
	registrations, err := queryMachineProducts()
	if err != nil {
		return mapi.InstalledStatusIdentity{}, false
	}
	installed, ok := corroborateMachineStatusIdentity(status, registrations, installedInterceptorUpdateVersion(), Version)
	if !ok {
		return mapi.InstalledStatusIdentity{}, false
	}
	return installed, queryResidentServiceRunning()
}

func queryProtectedMachineMarkerMatches(status mapi.PublicStatusV2) bool {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\go-mapi\MachineProduct`, registry.READ|registry.WOW64_64KEY)
	if err != nil {
		return false
	}
	defer key.Close()
	if !trustedMachineMarkerACL(windows.Handle(key)) {
		return false
	}
	values := map[string]string{
		"SKU":                status.SKU,
		"PackageRelease":     status.PackageVersion,
		"InterceptorVersion": status.InterceptorVersion,
	}
	if status.SKU == "suite" {
		values["AppVersion"] = status.AppVersion
	}
	for name, expected := range values {
		actual, _, err := key.GetStringValue(name)
		if err != nil || actual != expected {
			return false
		}
	}
	if status.SKU == "system" {
		if appVersion, _, err := key.GetStringValue("AppVersion"); err == nil && appVersion != "" || err != nil && !errors.Is(err, registry.ErrNotExist) {
			return false
		}
	}
	return true
}

func trustedMachineMarkerACL(handle windows.Handle) bool {
	sd, err := windows.GetSecurityInfo(handle, windows.SE_REGISTRY_KEY, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return false
	}
	owner, _, err := sd.Owner()
	if err != nil || owner == nil || owner.String() != "S-1-5-18" && owner.String() != "S-1-5-32-544" {
		return false
	}
	dacl, _, err := sd.DACL()
	if err != nil || dacl == nil {
		return false
	}
	const writeMask = windows.KEY_SET_VALUE | windows.KEY_CREATE_SUB_KEY | windows.DELETE | windows.WRITE_DAC | windows.WRITE_OWNER | windows.GENERIC_WRITE | windows.GENERIC_ALL
	for index := uint32(0); index < uint32(dacl.AceCount); index++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if windows.GetAce(dacl, index, &ace) != nil {
			return false
		}
		if ace.Header.AceType == windows.ACCESS_DENIED_ACE_TYPE {
			continue
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			return false
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()
		if ace.Mask&writeMask != 0 && sid != "S-1-5-18" && sid != "S-1-5-32-544" {
			return false
		}
	}
	return true
}

func queryMachineProducts() ([]machineProductRegistration, error) {
	families := []struct{ SKU, UpgradeCode string }{
		{"system", mapi.SystemUpgradeCode}, {"suite", mapi.SuiteUpgradeCode},
	}
	var products []machineProductRegistration
	for _, family := range families {
		upgrade, err := windows.UTF16PtrFromString("{" + family.UpgradeCode + "}")
		if err != nil {
			return nil, err
		}
		for index := uint32(0); ; index++ {
			var code [39]uint16
			result, _, _ := appMSIEnumRelatedProductsProc.Call(uintptr(unsafe.Pointer(upgrade)), 0, uintptr(index), uintptr(unsafe.Pointer(&code[0])))
			switch uint32(result) {
			case appMSINoMoreItems:
				goto nextFamily
			case appMSISuccess:
				productCode := windows.UTF16ToString(code[:])
				version, err := queryMSIProductVersion(productCode)
				if err != nil {
					return nil, err
				}
				products = append(products, machineProductRegistration{SKU: family.SKU, ProductCode: productCode, ProductVersion: version})
				if len(products) > 1 {
					return products, nil
				}
			default:
				return nil, windows.Errno(result)
			}
		}
	nextFamily:
	}
	return products, nil
}

func queryMSIProductVersion(code string) (string, error) {
	product, err := windows.UTF16PtrFromString(code)
	if err != nil {
		return "", err
	}
	property, _ := windows.UTF16PtrFromString("VersionString")
	for capacity := uint32(32); capacity <= 128; {
		buffer := make([]uint16, capacity)
		size := capacity
		result, _, _ := appMSIGetProductInfoProc.Call(uintptr(unsafe.Pointer(product)), uintptr(unsafe.Pointer(property)), uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&size)))
		switch uint32(result) {
		case appMSISuccess:
			version := windows.UTF16ToString(buffer)
			if version == "" {
				return "", errors.New("empty MSI product version")
			}
			return version, nil
		case appMSIMoreData:
			capacity = size + 1
		default:
			return "", windows.Errno(result)
		}
	}
	return "", errors.New("MSI product version exceeds bound")
}

func queryResidentServiceRunning() bool {
	manager, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return false
	}
	defer windows.CloseServiceHandle(manager)
	name, _ := windows.UTF16PtrFromString("go-mapi")
	service, err := windows.OpenService(manager, name, windows.SERVICE_QUERY_STATUS)
	if err != nil {
		return false
	}
	defer windows.CloseServiceHandle(service)
	var status windows.SERVICE_STATUS_PROCESS
	var needed uint32
	if err := windows.QueryServiceStatusEx(service, windows.SC_STATUS_PROCESS_INFO, (*byte)(unsafe.Pointer(&status)), uint32(unsafe.Sizeof(status)), &needed); err != nil {
		return false
	}
	return status.CurrentState == windows.SERVICE_RUNNING
}
