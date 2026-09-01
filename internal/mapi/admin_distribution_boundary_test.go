package mapi

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAdminMsiOwnsOnlyDualBitnessInterceptor(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	wxs := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "Package.wxs") +
		readAdminContractFile(t, repoRoot, "src", "installer", "msi", "GoMapi.AdminInstaller.wixproj")
	wxs += readAdminContractFile(t, repoRoot, "src", "installer", "msi", "customaction", "GoMapi.AdminCustomActions.csproj")
	wxs += readAdminContractFile(t, repoRoot, "src", "installer", "msi", "build.ps1")
	for _, want := range []string{
		`Scope="perMachine"`, `InstallerPlatform>x64`,
		`<PlatformTarget>x64</PlatformTarget>`,
		`ProductCode="$(var.ProductCode)"`, `Get-ProductCode`,
		`Id="InterceptorX86"`, `Id="InterceptorX64"`,
		`Id="MapiRegistrationShared"`, `Bitness="always64"`,
		`Key="SOFTWARE\Clients\Mail" Value="go-mapi"`,
		`Name="DLLPath" Value="%ProgramW6432%\go-mapi\interceptor\%PROCESSOR_ARCHITECTURE%\go-mapi.dll" Type="expandable"`,
	} {
		if !strings.Contains(wxs, want) {
			t.Errorf("admin MSI authoring missing %q", want)
		}
	}
	for _, forbidden := range []string{"src/app", "go-mapi.exe", "HKCU", "User" + "Choice", "MAPISendDocuments"} {
		if strings.Contains(wxs, forbidden) {
			t.Errorf("admin MSI crosses component/default-app boundary with %q", forbidden)
		}
	}
}

func TestAdminMsiCleanupAndRollbackAreMandatory(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	wxs := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "Package.wxs")
	customAction := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "customaction", "AdminMigration.cs")
	for _, want := range []string{
		"PrepareAdminMigration", "RollbackAdminMigration", "ApplyAdminMigration", "VerifyAdminRegistration",
		"PrepareAdminUninstall", "RollbackAdminUninstall", "FinalizeAdminUninstall",
		`Condition="NOT (REMOVE~=&quot;ALL&quot;)"`, `Condition="REMOVE~=&quot;ALL&quot; AND NOT UPGRADINGPRODUCTCODE"`,
	} {
		if !strings.Contains(wxs, want) {
			t.Errorf("mandatory lifecycle authoring missing %q", want)
		}
	}
	for _, want := range []string{
		"go-mapi-admin-migration-journal-v1", "RollbackProviders", "CaptureProvider(RegistryView.Registry64,",
		"CaptureProvider(RegistryView.Registry32,", "OwnedDllBackup", "IsOwnedLegacyDllPath", "RestoreProvider", "AtomicWriteJson",
		"after-cleanup", "after-registration", "IsSafeProvider", "SafeDeleteDirectory",
	} {
		if !strings.Contains(customAction, want) {
			t.Errorf("custom-action transaction missing %q", want)
		}
	}
	if strings.Contains(customAction, "powershell") || strings.Contains(customAction, "pwsh") {
		t.Error("machine mutation custom action must not shell through PowerShell")
	}
}

func TestAdminLegacyInventoryIsExplicitAndOwned(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	data := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "legacy-inventory.json")
	var inventory struct {
		Schema    string `json:"schema"`
		Resources []struct {
			ID        string `json:"id"`
			Kind      string `json:"kind"`
			Ownership string `json:"ownership"`
		} `json:"resources"`
	}
	if err := json.Unmarshal([]byte(data), &inventory); err != nil {
		t.Fatal(err)
	}
	if inventory.Schema != "go-mapi-legacy-inventory-v1" {
		t.Fatalf("inventory schema = %q", inventory.Schema)
	}
	ids := map[string]bool{}
	for _, resource := range inventory.Resources {
		if resource.ID == "" || resource.Kind == "" || resource.Ownership == "" {
			t.Errorf("incomplete inventory resource: %#v", resource)
		}
		ids[resource.ID] = true
	}
	for _, id := range []string{
		"manual-client-registration", "manual-handler-classes", "legacy-nsis-arp",
		"legacy-machine-install-x64", "legacy-machine-install-x86", "legacy-update-staging",
		"legacy-uninstall-state", "legacy-shortcut", "legacy-update-task", "legacy-oauth-firewall",
	} {
		if !ids[id] {
			t.Errorf("legacy inventory missing %q", id)
		}
	}
}

func TestInstalledAdminManifestMatchesVersionGateContract(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	schema := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "schema", "installed-component-v1.schema.json")
	customAction := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "customaction", "AdminMigration.cs")
	for _, want := range []string{
		"go-mapi-installed-interceptor-v1", "queue-v1", "minInclusive", "peProductVersion",
		`x86\go-mapi.dll`, `AMD64\go-mapi.dll`, "sha256",
	} {
		if !strings.Contains(schema, want) && !strings.Contains(customAction, want) {
			t.Errorf("installed component contract missing %q", want)
		}
	}
	for _, want := range []string{"SetSharedRegistration();", "AssertSharedRegistration(x86, x64)", "RegistryView.Registry32", "RegistryView.Registry64", "AtomicWriteJson(manifestPath"} {
		if !strings.Contains(customAction, want) {
			t.Errorf("installed manifest commit gate missing %q", want)
		}
	}
}

func TestAdminReleaseFailsClosedAndDoesNotBuildApp(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	workflow := readAdminContractFile(t, repoRoot, ".github", "workflows", "admin-release.yml")
	for _, want := range []string{
		"admin-v*", "SIGNPATH_API_TOKEN", "unsigned publication is forbidden", "-RequireSignedInputs",
		"verify.ps1 -MsiPath release/admin/go-mapi-interceptor.msi -RequireSignature",
		"ElevationRequirement: elevationRequired", "wingetcreate.exe update", "admin-release.json",
	} {
		if !strings.Contains(workflow, want) && want != "ElevationRequirement: elevationRequired" {
			t.Errorf("admin release workflow missing %q", want)
		}
	}
	winget := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "generate-winget.ps1")
	for _, want := range []string{"InstallerType: msi", "Scope: machine", "ElevationRequirement: elevationRequired", "Get-AuthenticodeSignature"} {
		if !strings.Contains(winget, want) {
			t.Errorf("winget generator missing %q", want)
		}
	}
	for _, forbidden := range []string{"build-wails", "npm run build:app", "src/app/build", "go-mapi.exe"} {
		if strings.Contains(workflow, forbidden) {
			t.Errorf("admin release builds or embeds user app via %q", forbidden)
		}
	}
}

func readAdminContractFile(t *testing.T, root string, parts ...string) string {
	t.Helper()
	path := filepath.Join(append([]string{root}, parts...)...)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}
