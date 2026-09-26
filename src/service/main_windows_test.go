//go:build windows

package service

import (
	"errors"
	"fmt"
	"os"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

func TestMain(m *testing.M) {
	os.Exit(withWindowsTestService(ServiceName, func(_ windows.Handle, owned bool) int {
		fmt.Fprintf(os.Stderr, "Windows service fixture: %s %s; enabling process owner prerequisite\n", ServiceName, serviceOwnership(owned))
		return withRestorePrivilege(m.Run)
	}))
}

func serviceOwnership(owned bool) string {
	if owned {
		return "created disabled"
	}
	return "borrowed existing"
}

// withWindowsTestService owns only a service created by this call. The callback
// and all cleanup finish before TestMain calls os.Exit.
func withWindowsTestService(name string, body func(windows.Handle, bool) int) (result int) {
	scm, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT|windows.SC_MANAGER_CREATE_SERVICE)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Windows service fixture: open SCM (elevation required): %v\n", err)
		return 1
	}
	defer func() {
		if err := windows.CloseServiceHandle(scm); err != nil {
			fixtureCleanupError(&result, name, "close SCM", err)
		}
	}()

	serviceName, err := windows.UTF16PtrFromString(name)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Windows service fixture: invalid name %q: %v\n", name, err)
		return 1
	}
	const queryRights = windows.SERVICE_QUERY_STATUS | windows.SERVICE_QUERY_CONFIG
	service, err := windows.OpenService(scm, serviceName, queryRights)
	owned := false
	if errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
		exe, exeErr := os.Executable()
		if exeErr != nil {
			fmt.Fprintf(os.Stderr, "Windows service fixture: executable path: %v\n", exeErr)
			return 1
		}
		path, pathErr := windows.UTF16PtrFromString(`"` + exe + `"`)
		if pathErr != nil {
			fmt.Fprintf(os.Stderr, "Windows service fixture: quoted executable path: %v\n", pathErr)
			return 1
		}
		service, err = windows.CreateService(scm, serviceName, serviceName, windows.DELETE|queryRights,
			windows.SERVICE_WIN32_OWN_PROCESS, windows.SERVICE_DISABLED, windows.SERVICE_ERROR_NORMAL,
			path, nil, nil, nil, nil, nil)
		if err == nil {
			owned = true
		} else if errors.Is(err, windows.ERROR_SERVICE_EXISTS) {
			service, err = windows.OpenService(scm, serviceName, queryRights)
		}
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "Windows service fixture: open/create %s (elevation required): %v\n", name, err)
		return 1
	}
	defer func() {
		if owned {
			if err := windows.DeleteService(service); err != nil {
				fixtureCleanupError(&result, name, "delete owned service", err)
			}
		}
		if err := windows.CloseServiceHandle(service); err != nil {
			fixtureCleanupError(&result, name, "close service handle", err)
		}
		if owned {
			if err := waitForServiceAbsence(scm, serviceName); err != nil {
				fixtureCleanupError(&result, name, "confirm owned service absence", err)
			} else {
				fmt.Fprintf(os.Stderr, "Windows service fixture: %s owned entry absent after cleanup\n", name)
			}
		} else {
			fmt.Fprintf(os.Stderr, "Windows service fixture: %s borrowed entry left unchanged\n", name)
		}
	}()

	if _, _, _, err := windows.LookupSID("", `NT SERVICE\`+name); err != nil {
		fmt.Fprintf(os.Stderr, "Windows service fixture: lookup NT SERVICE\\%s: %v\n", name, err)
		return 1
	}
	fmt.Fprintf(os.Stderr, "Windows service fixture: %s %s; SID lookup succeeded\n", name, serviceOwnership(owned))
	return body(service, owned)
}

func fixtureCleanupError(result *int, name, operation string, err error) {
	fmt.Fprintf(os.Stderr, "Windows service fixture: %s %s: %v\n", name, operation, err)
	if *result == 0 {
		*result = 1
	}
}

func waitForServiceAbsence(scm windows.Handle, name *uint16) error {
	for attempt := 0; attempt < 10; attempt++ {
		service, err := windows.OpenService(scm, name, windows.SERVICE_QUERY_STATUS)
		if errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
			return nil
		}
		if err != nil && !errors.Is(err, windows.ERROR_SERVICE_MARKED_FOR_DELETE) {
			return err
		}
		if err == nil {
			if closeErr := windows.CloseServiceHandle(service); closeErr != nil {
				return closeErr
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("owned service remains registered or marked for deletion")
}

func withRestorePrivilege(body func() int) (result int) {
	var token windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY|windows.TOKEN_ADJUST_PRIVILEGES, &token); err != nil {
		fmt.Fprintf(os.Stderr, "Windows service fixture: open process token (elevation required): %v\n", err)
		return 1
	}
	defer func() {
		if err := token.Close(); err != nil {
			fixtureCleanupError(&result, "process token", "close", err)
		}
	}()
	user, err := token.GetTokenUser()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Windows service fixture: inspect process token user: %v\n", err)
		return 1
	}
	if user.User.Sid.String() == "S-1-5-18" {
		fmt.Fprintln(os.Stderr, "Windows service fixture: LocalSystem process; restore privilege change unnecessary")
		return body()
	}
	name, _ := windows.UTF16PtrFromString("SeRestorePrivilege")
	var luid windows.LUID
	if err := windows.LookupPrivilegeValue(nil, name, &luid); err != nil {
		fmt.Fprintf(os.Stderr, "Windows service fixture: resolve SeRestorePrivilege: %v\n", err)
		return 1
	}
	present, enabled, err := tokenPrivilegeState(token, luid)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Windows service fixture: inspect SeRestorePrivilege: %v\n", err)
		return 1
	}
	if !present {
		fmt.Fprintln(os.Stderr, "Windows service fixture: process token lacks SeRestorePrivilege (elevation required)")
		return 1
	}
	if enabled {
		fmt.Fprintln(os.Stderr, "Windows service fixture: SeRestorePrivilege already enabled; no change")
		return body()
	}
	newState := windows.Tokenprivileges{PrivilegeCount: 1}
	newState.Privileges[0] = windows.LUIDAndAttributes{Luid: luid, Attributes: windows.SE_PRIVILEGE_ENABLED}
	var previous windows.Tokenprivileges
	var previousLen uint32
	if err := windows.AdjustTokenPrivileges(token, false, &newState, uint32(unsafe.Sizeof(previous)), &previous, &previousLen); err != nil {
		fmt.Fprintf(os.Stderr, "Windows service fixture: enable SeRestorePrivilege: %v\n", err)
		return 1
	}
	defer func() {
		if previous.PrivilegeCount != 0 {
			if err := windows.AdjustTokenPrivileges(token, false, &previous, 0, nil, nil); err != nil {
				fixtureCleanupError(&result, "process token", "restore SeRestorePrivilege", err)
			}
		}
		present, restored, err := tokenPrivilegeState(token, luid)
		if err != nil {
			fixtureCleanupError(&result, "process token", "verify SeRestorePrivilege restoration", err)
		} else if !present || restored {
			fixtureCleanupError(&result, "process token", "verify SeRestorePrivilege restoration", fmt.Errorf("present=%t enabled=%t; want present and disabled", present, restored))
		} else {
			fmt.Fprintln(os.Stderr, "Windows service fixture: SeRestorePrivilege restored to disabled")
		}
	}()
	present, enabled, err = tokenPrivilegeState(token, luid)
	if err != nil || !present || !enabled {
		fmt.Fprintf(os.Stderr, "Windows service fixture: SeRestorePrivilege did not become enabled (elevation required): present=%t enabled=%t error=%v\n", present, enabled, err)
		return 1
	}
	fmt.Fprintln(os.Stderr, "Windows service fixture: SeRestorePrivilege enabled for test process")
	return body()
}

func tokenPrivilegeState(token windows.Token, luid windows.LUID) (bool, bool, error) {
	var size uint32
	err := windows.GetTokenInformation(token, windows.TokenPrivileges, nil, 0, &size)
	if !errors.Is(err, windows.ERROR_INSUFFICIENT_BUFFER) || size < uint32(unsafe.Sizeof(windows.Tokenprivileges{})) {
		return false, false, fmt.Errorf("size TokenPrivileges: %w", err)
	}
	buffer := make([]byte, size)
	if err := windows.GetTokenInformation(token, windows.TokenPrivileges, &buffer[0], size, &size); err != nil {
		return false, false, err
	}
	privileges := (*windows.Tokenprivileges)(unsafe.Pointer(&buffer[0]))
	needed := unsafe.Offsetof(windows.Tokenprivileges{}.Privileges) + uintptr(privileges.PrivilegeCount)*unsafe.Sizeof(windows.LUIDAndAttributes{})
	if needed > uintptr(size) || needed > uintptr(len(buffer)) {
		return false, false, errors.New("truncated TokenPrivileges result")
	}
	for _, privilege := range privileges.AllPrivileges() {
		if privilege.Luid == luid {
			return true, privilege.Attributes&windows.SE_PRIVILEGE_ENABLED != 0, nil
		}
	}
	return false, false, nil
}

func TestWindowsServiceFixtureLifecycle(t *testing.T) {
	uniqueName := func(label string) string {
		return fmt.Sprintf("go-mapi-fixture-%s-%d-%d", label, os.Getpid(), time.Now().UnixNano())
	}
	t.Run("owned normal cleanup", func(t *testing.T) {
		name := uniqueName("normal")
		if result := withWindowsTestService(name, func(service windows.Handle, owned bool) int {
			if !owned {
				t.Error("unique service was unexpectedly borrowed")
				return 1
			}
			var status windows.SERVICE_STATUS
			if err := windows.QueryServiceStatus(service, &status); err != nil || status.CurrentState != windows.SERVICE_STOPPED {
				t.Errorf("owned service status: state=%d error=%v", status.CurrentState, err)
				return 1
			}
			config, err := serviceConfig(service)
			if err != nil || config.startType != windows.SERVICE_DISABLED {
				t.Errorf("owned service configuration: %+v error=%v", config, err)
				return 1
			}
			return 0
		}); result != 0 {
			t.Errorf("owned service fixture result=%d", result)
		}
	})
	t.Run("failure still cleans owned entry", func(t *testing.T) {
		name := uniqueName("failure")
		if result := withWindowsTestService(name, func(_ windows.Handle, owned bool) int {
			if !owned {
				t.Error("unique service was unexpectedly borrowed")
			}
			return 23
		}); result != 23 {
			t.Errorf("callback failure result=%d; want 23", result)
		}
		assertServiceAbsent(t, name)
	})
	t.Run("borrowed registration stays unchanged", func(t *testing.T) {
		name := uniqueName("borrow")
		if result := withWindowsTestService(name, func(service windows.Handle, owned bool) int {
			if !owned {
				t.Error("outer fixture did not own unique service")
				return 1
			}
			before, err := serviceSnapshot(service)
			if err != nil {
				t.Errorf("query before borrow: %v", err)
				return 1
			}
			inner := withWindowsTestService(name, func(_ windows.Handle, innerOwned bool) int {
				if innerOwned {
					t.Error("existing service was unexpectedly owned")
					return 1
				}
				return 0
			})
			after, err := serviceSnapshot(service)
			if err != nil || before != after || inner != 0 {
				t.Errorf("borrow changed registration: before=%+v after=%+v inner=%d error=%v", before, after, inner, err)
				return 1
			}
			return 0
		}); result != 0 {
			t.Errorf("borrow fixture result=%d", result)
		}
	})
	t.Run("restore privilege scope", func(t *testing.T) {
		before, err := currentRestorePrivilegeState()
		if err != nil {
			t.Fatal(err)
		}
		result := withRestorePrivilege(func() int {
			inside, err := currentRestorePrivilegeState()
			if err != nil || inside != before {
				t.Errorf("nested privilege state: before=%+v inside=%+v error=%v", before, inside, err)
				return 1
			}
			return 0
		})
		after, err := currentRestorePrivilegeState()
		if err != nil || before != after || result != 0 {
			t.Errorf("privilege scope: before=%+v after=%+v result=%d error=%v", before, after, result, err)
		}
	})
}

func assertServiceAbsent(t *testing.T, name string) {
	t.Helper()
	scm, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		t.Fatalf("open SCM to confirm %s absence: %v", name, err)
	}
	defer windows.CloseServiceHandle(scm)
	serviceName, _ := windows.UTF16PtrFromString(name)
	if err := waitForServiceAbsence(scm, serviceName); err != nil {
		t.Errorf("service %s remains after fixture cleanup: %v", name, err)
	}
}

type fixtureServiceConfig struct {
	startType uint32
	path      string
	account   string
}

func serviceConfig(service windows.Handle) (fixtureServiceConfig, error) {
	var needed uint32
	err := windows.QueryServiceConfig(service, nil, 0, &needed)
	if !errors.Is(err, windows.ERROR_INSUFFICIENT_BUFFER) || needed < uint32(unsafe.Sizeof(windows.QUERY_SERVICE_CONFIG{})) {
		return fixtureServiceConfig{}, fmt.Errorf("size service config: %w", err)
	}
	buffer := make([]byte, needed)
	config := (*windows.QUERY_SERVICE_CONFIG)(unsafe.Pointer(&buffer[0]))
	if err := windows.QueryServiceConfig(service, config, needed, &needed); err != nil {
		return fixtureServiceConfig{}, err
	}
	return fixtureServiceConfig{config.StartType, windows.UTF16PtrToString(config.BinaryPathName), windows.UTF16PtrToString(config.ServiceStartName)}, nil
}

type fixtureServiceSnapshot struct {
	config fixtureServiceConfig
	state  uint32
}

func serviceSnapshot(service windows.Handle) (fixtureServiceSnapshot, error) {
	config, err := serviceConfig(service)
	if err != nil {
		return fixtureServiceSnapshot{}, err
	}
	var status windows.SERVICE_STATUS
	if err := windows.QueryServiceStatus(service, &status); err != nil {
		return fixtureServiceSnapshot{}, err
	}
	return fixtureServiceSnapshot{config, status.CurrentState}, nil
}

type fixturePrivilegeState struct {
	present bool
	enabled bool
}

func currentRestorePrivilegeState() (fixturePrivilegeState, error) {
	var token windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY, &token); err != nil {
		return fixturePrivilegeState{}, err
	}
	defer token.Close()
	name, _ := windows.UTF16PtrFromString("SeRestorePrivilege")
	var luid windows.LUID
	if err := windows.LookupPrivilegeValue(nil, name, &luid); err != nil {
		return fixturePrivilegeState{}, err
	}
	present, enabled, err := tokenPrivilegeState(token, luid)
	return fixturePrivilegeState{present, enabled}, err
}
