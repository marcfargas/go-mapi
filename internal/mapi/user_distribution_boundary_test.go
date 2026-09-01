package mapi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readDistributionFile(t *testing.T, relative string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", filepath.FromSlash(relative)))
	if err != nil {
		t.Fatalf("read %s: %v", relative, err)
	}
	return string(data)
}

func TestUserMSIXIsX64AppOnlyAndNonElevated(t *testing.T) {
	manifest := readDistributionFile(t, "src/app/packaging/msix/AppxManifest.xml.in")
	for _, want := range []string{
		`ProcessorArchitecture="x64"`, `Windows.FullTrustApplication`,
		`desktop6:FileSystemWriteVirtualization>disabled`, `Name="unvirtualizedResources"`,
		`TaskId="go-mapi-user-startup-v4"`, `Enabled="true"`, `MinVersion="10.0.18362.0"`,
	} {
		if !strings.Contains(manifest, want) {
			t.Errorf("MSIX contract missing %q", want)
		}
	}
	for _, forbidden := range []string{"allowElevation", "UserChoice", "go-mapi.dll", ".msi", "HKEY_LOCAL_MACHINE"} {
		if strings.Contains(manifest, forbidden) {
			t.Errorf("MSIX contains forbidden admin/default-app content %q", forbidden)
		}
	}
}

func TestStandaloneInstallerIsCurrentUserAppOnly(t *testing.T) {
	nsis := readDistributionFile(t, "src/app/packaging/standalone/go-mapi-user.nsi")
	startup := readDistributionFile(t, "src/app/startup_windows.go")
	contract := nsis + startup
	for _, want := range []string{
		"RequestExecutionLevel user", `$LOCALAPPDATA\Programs\go-mapi`,
		"go-mapi-user-startup-v4", `Software\Microsoft\Windows\CurrentVersion\Run`, "registry.CURRENT_USER", "--startup", "--purge-user-data", "--handoff-from-store",
		"Function .onInit", "IfSilent silentInstall interactiveInstall", `IfFileExists "$APPDATA\go-mapi\settings.json" preserveSilentPreference`, "StrCpy $AutostartEnabled ${BST_CHECKED}",
		"IfSilent +2", "Windows did not register startup. You can fix this from the app.",
		`FileWrite $0 "cd /d $\"$TEMP$\"$\r$\n"`, `FileWrite $0 ":retry$\r$\n"`, `rmdir /s /q $\"$INSTDIR$\"`,
		`if exist $\"$INSTDIR$\" (ping 127.0.0.1 -n 2 > NUL & goto retry)`,
		`del $\"%~f0$\"`, `Exec '"$SYSDIR\cmd.exe" /c start "" /b "$SYSDIR\cmd.exe" /c call "$TEMP\go-mapi-user-v4-cleanup.cmd"'`,
	} {
		if !strings.Contains(contract, want) {
			t.Errorf("standalone contract missing %q", want)
		}
	}
	if strings.Contains(nsis, `ExecShell "open" "$TEMP\go-mapi-user-v4-cleanup.cmd"`) {
		t.Error("standalone cleanup helper must detach instead of becoming an uninstaller child")
	}
	for _, forbidden := range []string{"RequestExecutionLevel admin", "HKLM", "go-mapi.dll", ".msi", "MAPIRegister", "SYSTEM"} {
		if strings.Contains(nsis, forbidden) {
			t.Errorf("standalone contains forbidden admin payload/operation %q", forbidden)
		}
	}
}

func TestUserReleaseFailsClosedAndPublishesVerifiedArtifacts(t *testing.T) {
	workflow := readDistributionFile(t, ".github/workflows/app-release.yml")
	for _, want := range []string{
		"unsigned publication is forbidden", "signpath/github-action-submit-signing-request@v2",
		"verify-app-distribution.ps1", "-RequireSignature", "app-distribution.json",
		"microsoft/microsoft-store-apppublisher@v1.1", "winget-create/releases/download/v1.10.3.0/wingetcreate.exe",
		"WINGET_CREATE_GITHUB_TOKEN", "environment: app-release",
	} {
		if !strings.Contains(workflow, want) {
			t.Errorf("app release contract missing %q", want)
		}
	}
	for _, forbidden := range []string{"build:interceptor", "build:admin:msi", "src/installer/msi", "unsigned fallback"} {
		if strings.Contains(workflow, forbidden) {
			t.Errorf("app release couples to forbidden graph/path %q", forbidden)
		}
	}
}

func TestDefaultAppsGuidanceNeverWritesUserChoice(t *testing.T) {
	source := readDistributionFile(t, "src/app/default_apps_windows.go")
	if !strings.Contains(source, `browser.OpenURL("ms-settings:defaultapps")`) {
		t.Error("app must open the Windows-owned Default Apps page")
	}
	if strings.Contains(source, "registry.") || strings.Contains(source, "SetStringValue") {
		t.Error("default-app guidance must not write or impersonate Windows UserChoice")
	}
}

func TestChannelHandoffRunsBeforeAnyQueueConsumer(t *testing.T) {
	mainSource := readDistributionFile(t, "src/app/main.go")
	handoffAt := strings.Index(mainSource, "startupHandoffAction(context.Background())")
	appAt := strings.Index(mainSource, "app := NewApp()")
	if handoffAt < 0 || appAt < 0 || handoffAt > appAt {
		t.Fatal("channel handoff must complete before App startup can create a queue consumer")
	}
	handoff := readDistributionFile(t, "src/app/handoff.go")
	for _, want := range []string{"channel-handoff-v1.json", "handoffRequested", "handoffSourceRemoved", "handoffVerified", "moveFileAtomic"} {
		if !strings.Contains(handoff, want) {
			t.Errorf("handoff journal contract missing %q", want)
		}
	}
}

func TestStoreIdentityIsInjectedNotDuplicated(t *testing.T) {
	build := readDistributionFile(t, "scripts/build-wails.ps1")
	workflow := readDistributionFile(t, ".github/workflows/app-release.yml")
	manifest := readDistributionFile(t, "src/app/packaging/msix/AppxManifest.xml.in")
	for _, pair := range []struct{ content, want string }{
		{build, "main.StorePackageFamilyName=$StorePackageFamilyName"},
		{workflow, "GOMAPI_STORE_PACKAGE_FAMILY_NAME: ${{ vars.STORE_PACKAGE_FAMILY_NAME }}"},
		{manifest, "@@IDENTITY_NAME@@"},
	} {
		if !strings.Contains(pair.content, pair.want) {
			t.Errorf("Store identity contract missing %q", pair.want)
		}
	}
}
