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
		readAdminContractFile(t, repoRoot, "src", "installer", "msi", "SharedMachine.wxs") +
		readAdminContractFile(t, repoRoot, "src", "installer", "msi", "GoMapi.AdminInstaller.wixproj")
	wxs += readAdminContractFile(t, repoRoot, "src", "installer", "msi", "customaction", "GoMapi.AdminCustomActions.csproj")
	wxs += readAdminContractFile(t, repoRoot, "src", "installer", "msi", "build.ps1")
	for _, want := range []string{
		`Scope="perMachine"`, `InstallerPlatform>x64`,
		`<PlatformTarget>x64</PlatformTarget>`,
		`ProductCode="$(var.ProductCode)"`, `cmd/machine-package`,
		`Id="InterceptorX86"`, `Id="InterceptorX64"`,
		`Id="MapiRegistrationShared"`, `Bitness="always64"`,
		`Key="SOFTWARE\Clients\Mail" Value="go-mapi"`,
		`Name="DLLPath" Value="%ProgramW6432%\go-mapi\interceptor\%PROCESSOR_ARCHITECTURE%\go-mapi.dll" Type="expandable"`,
	} {
		if !strings.Contains(wxs, want) {
			t.Errorf("admin MSI authoring missing %q", want)
		}
	}
	for _, forbidden := range []string{"src/app", "go-mapi-user.exe", "HKCU", "User" + "Choice", "MAPISendDocuments"} {
		if strings.Contains(wxs, forbidden) {
			t.Errorf("admin MSI crosses component/default-app boundary with %q", forbidden)
		}
	}
}

func TestAdminMsiCleanupAndRollbackAreMandatory(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	wxs := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "Package.wxs") +
		readAdminContractFile(t, repoRoot, "src", "installer", "msi", "SharedMachine.wxs")
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

func TestSystemMsiOwnsExactlyOneResidentService(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	wxs := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "SharedMachine.wxs")
	wixproj := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "GoMapi.AdminInstaller.wixproj")
	for _, want := range []string{
		`Name="go-mapi" DisplayName="go-mapi system service"`, `Type="ownProcess"`, `Start="auto"`,
		`Account="LocalSystem"`, `Arguments="service"`, `DelayedAutoStart="yes"`, `ServiceSid="unrestricted"`,
		`Start="install" Stop="both" Remove="uninstall" Wait="yes"`,
		`xmlns:util="http://wixtoolset.org/schemas/v4/wxs/util"`,
		`util:ServiceConfig FirstFailureActionType="restart" SecondFailureActionType="restart" ThirdFailureActionType="none"`,
		`ResetPeriodInDays="1" RestartServiceDelayInSeconds="60"`,
	} {
		if !strings.Contains(wxs, want) {
			t.Errorf("resident service authoring missing %q", want)
		}
	}
	if !strings.Contains(wixproj, `<PackageReference Include="WixToolset.Util.wixext" Version="4.0.5" />`) {
		t.Error("system MSI project must pin the WiX Util extension alongside the WiX SDK")
	}
	if strings.Contains(wxs, "ServiceConfigFailureActions") {
		t.Error("system MSI must not author the broken native MsiServiceConfigFailureActions table")
	}
	if strings.Count(wxs, "<ServiceInstall ") != 1 {
		t.Errorf("ServiceInstall count = %d, want 1", strings.Count(wxs, "<ServiceInstall "))
	}
	for _, guid := range []string{"D56189EF-0DA1-4AA1-A764-D90610EC8441", "541217D4-4C8D-4D4C-83E5-9CD4CDCF7694", "1247251F-F476-4520-81A5-25985450B9F8"} {
		if !strings.Contains(wxs, guid) {
			t.Errorf("shared component GUID changed: %s", guid)
		}
	}
}

func TestSystemMsiBuildUsesTypedInputsAndProductionIdentity(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	build := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "build.ps1")
	verify := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "verify.ps1")
	for _, want := range []string{"go-mapi-machine-signed-input-v1", "cmd/machine-package", "packageRelease", "commit", "service", "interceptor", "Get-FileHash", "Get-PeMachine", "RequireSignedInputs", "identity.assetName"} {
		if !strings.Contains(build, want) {
			t.Errorf("typed system build missing %q", want)
		}
	}
	for _, want := range []string{"ServiceInstall", "ServiceControl", "MsiServiceConfig", "Wix4ServiceConfig", "Wix4SchedServiceConfig_X64", "production $SKU identity"} {
		if !strings.Contains(verify, want) {
			t.Errorf("compiled-table verifier missing %q", want)
		}
	}
	if !strings.Contains(verify, `Assert-TableAbsent 'MsiServiceConfigFailureActions'`) {
		t.Error("compiled-table verifier must reject the broken native failure-action table")
	}
}

func TestSuiteMsiUsesSharedMachineResourcesAndMachineApp(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	project := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "GoMapi.SuiteInstaller.wixproj")
	entry := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "SuitePackage.wxs")
	user := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "SuiteUser.wxs")
	shared := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "SharedMachine.wxs")
	build := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "build.ps1")
	verify := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "verify.ps1")
	for _, want := range []string{`<Compile Include="SharedMachine.wxs" />`, `<Compile Include="SuiteUser.wxs" />`, `SKU=suite;`, `HealthComponentGuid=299FDB55-B38D-5C25-8334-D45FA3CC3DDB;`} {
		if !strings.Contains(project, want) {
			t.Errorf("suite project missing %q", want)
		}
	}
	for _, want := range []string{`<ComponentGroupRef Id="ResidentServiceComponents" />`, `<ComponentGroupRef Id="SuiteUserComponents" />`, `RollbackServiceConfiguration`, `RemoveExistingProducts`} {
		if !strings.Contains(entry, want) {
			t.Errorf("suite entry missing %q", want)
		}
	}
	for _, want := range []string{`go-mapi.exe`, `CommonProgramsFolder`, `go-mapi-user-machine-v4`, `--startup --machine-install`, `Name="AppVersion"`} {
		if !strings.Contains(user, want) {
			t.Errorf("suite user payload missing %q", want)
		}
	}
	if strings.Count(shared, "<ServiceInstall ") != 1 || !strings.Contains(shared, `Guid="$(var.HealthComponentGuid)"`) || !strings.Contains(shared, `Value="$(var.SKU)"`) {
		t.Error("shared resources drift or SKU health marker is not separately owned")
	}
	for _, want := range []string{`ValidateSet('system','suite')`, `go-mapi-machine\.exe$`, `distribution`, `componentMap.app`, `GoMapi.SuiteInstaller.wixproj`} {
		if !strings.Contains(build, want) {
			t.Errorf("suite build contract missing %q", want)
		}
	}
	for _, want := range []string{`ValidateSet('system','suite')`, `SuiteUserExe`, `SuiteStartup`, `SuiteAppShortcut`, `expectedUpgradeCode`} {
		if !strings.Contains(verify, want) {
			t.Errorf("suite table verifier missing %q", want)
		}
	}
	for _, forbidden := range []string{`HKCU`, `UserChoice`, `Get-AppxPackage`, `Remove-AppxPackage`, `LOCALAPPDATA`} {
		if strings.Contains(entry+user+shared, forbidden) {
			t.Errorf("suite MSI touches per-user package/profile boundary: %q", forbidden)
		}
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
		"legacy-machine-install-x64", "legacy-machine-install-x86",
		"legacy-uninstall-state", "legacy-shortcut", "legacy-update-task", "legacy-oauth-firewall",
	} {
		if !ids[id] {
			t.Errorf("legacy inventory missing %q", id)
		}
	}
	if ids["legacy-update-staging"] {
		t.Error("service-owned update state must not remain in the destructive legacy inventory")
	}
}

func TestInstalledAdminManifestMatchesVersionGateContract(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	schema := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "schema", "installed-component-v1.schema.json")
	customAction := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "customaction", "AdminMigration.cs")
	for _, want := range []string{
		"go-mapi-installed-interceptor-v1", "queue-v1", "minInclusive", "peProductVersion",
		`x86\go-mapi.dll`, `AMD64\go-mapi.dll`, "sha256", "GOMAPI_COMPONENT_VERSION",
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
		"admin-v*", "AZURE_ARTIFACT_SIGNING_ENDPOINT", "azure/artifact-signing-action@c7ab2a863ab5f9a846ddb8265964877ef296ee82", "unsigned publication is forbidden", "-RequireSignedInputs",
		"environment: artifact-signing", "id-token: write",
		"verify.ps1 -MsiPath $path -RequireSignature",
		"ElevationRequirement: elevationRequired", "wingetcreate.exe update", "admin-release.json",
		"github.event_name == 'push' || inputs.publish || inputs.sign",
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
