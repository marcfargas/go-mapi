package mapi

import (
	"encoding/json"
	"encoding/xml"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAdminMsiOwnsOnlyDualBitnessInterceptor(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	wxs := readMachinePackageAuthoring(t, repoRoot, "Package.wxs") +
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
	wxs := readMachinePackageAuthoring(t, repoRoot, "Package.wxs") +
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
		"HadInstalledManifest", "ManifestBackupSha256", "rollback-installed-component-v1.json",
		"EnsureProtectedJournalDirectory", "ProtectJournalFile", "FileSystemRights.FullControl",
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

func TestMachineMsiOwnsAndPreservesAutomaticUpdateChoice(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	shared := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "SharedMachine.wxs")
	actions := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "customaction", "AdminMigration.cs")
	verify := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "verify.ps1")
	if !strings.Contains(shared, `Name="AutoUpdateEnabled" Value="[GOMAPI_AUTO_UPDATE]" Type="integer"`) {
		t.Fatal("machine MSI does not own the 64-bit DWORD update choice")
	}
	for _, filename := range []string{"Package.wxs", "SuitePackage.wxs"} {
		entry := readMachinePackageAuthoring(t, repoRoot, filename)
		if !strings.Contains(entry, `<Property Id="GOMAPI_AUTO_UPDATE" Secure="yes" />`) {
			t.Errorf("%s does not accept the administrator update choice", filename)
		}
	}
	for _, want := range []string{"ResolveAutoUpdate(session);", "RegistryView.Registry64", "RegistryValueKind.DWord", "Existing machine product has no automatic update setting", `session["GOMAPI_AUTO_UPDATE"] = choice;`} {
		if !strings.Contains(actions, want) {
			t.Errorf("machine migration does not preserve/update setting: %q", want)
		}
	}
	if !strings.Contains(verify, "AutoUpdateEnabled") || !strings.Contains(verify, "GOMAPI_AUTO_UPDATE") {
		t.Fatal("compiled machine MSI verifier does not inspect the update choice")
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
	entry := readMachinePackageAuthoring(t, repoRoot, "SuitePackage.wxs")
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
	for _, want := range []string{`go-mapi.exe`, `CommonAppDataFolder`, `Start Menu\Programs\go-mapi`, `go-mapi-user-machine-v4`, `--startup --machine-install`, `Name="AppVersion"`} {
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

func TestMachineMsiCrossSkuMigrationIsExplicitAndTransactional(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	shared := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "SharedMachine.wxs")
	build := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "build.ps1")
	verify := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "verify.ps1")
	for _, filename := range []string{"Package.wxs", "SuitePackage.wxs"} {
		entry := readMachinePackageAuthoring(t, repoRoot, filename)
		for _, want := range []string{
			`<Upgrade Id="$(var.ForeignUpgradeCode)">`,
			`Minimum="0.0.0" IncludeMinimum="yes"`,
			`Property="GOMAPI_FOREIGN_PRODUCT"`,
			`<Property Id="GOMAPI_MIGRATE_SKU" Secure="yes" />`,
			`Installed OR NOT GOMAPI_FOREIGN_PRODUCT OR GOMAPI_MIGRATE_SKU = &quot;1&quot;`,
			`<FindRelatedProducts Before="LaunchConditions" />`,
			`Schedule="afterInstallInitialize"`,
			`Before="DeleteServices" Condition="REMOVE~=&quot;ALL&quot; AND UPGRADINGPRODUCTCODE"`,
		} {
			if !strings.Contains(entry, want) {
				t.Errorf("%s missing migration contract %q", filename, want)
			}
		}
		for _, forbidden := range []string{`GOMAPI_MIGRATE_SKU" Value=`, `OnlyDetect="yes"`, `RemoveFeatures=`, `Maximum=`} {
			if strings.Contains(entry, forbidden) {
				t.Errorf("%s weakens foreign-product removal with %q", filename, forbidden)
			}
		}
	}
	if !strings.Contains(build, `-p:ForeignUpgradeCode=$($foreignContract.upgradeCode)`) {
		t.Error("machine build does not bind the foreign UpgradeCode from the validated package contract")
	}
	for _, want := range []string{"GOMAPI_FOREIGN_PRODUCT", "GOMAPI_MIGRATE_SKU", "SecureCustomProperties", "LaunchCondition", "FindRelatedProducts", "RemoveExistingProducts"} {
		if !strings.Contains(verify, want) {
			t.Errorf("compiled MSI verifier missing migration check %q", want)
		}
	}
	for _, guid := range []string{"D56189EF-0DA1-4AA1-A764-D90610EC8441", "541217D4-4C8D-4D4C-83E5-9CD4CDCF7694", "1247251F-F476-4520-81A5-25985450B9F8", "1E335EC1-0CCC-54A2-ACC2-96EB8FB2E134"} {
		if !strings.Contains(shared, guid) {
			t.Errorf("cross-SKU shared component identity drifted: %s", guid)
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
        `x86\go-mapi.dll`, `AMD64\go-mapi.dll`, "sha256", "GoMapiComponentVersion",
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
	legacyWorkflow := strings.Split(workflow, "\n  validate-machine-package:")[0]
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
		if strings.Contains(legacyWorkflow, forbidden) {
			t.Errorf("admin release builds or embeds user app via %q", forbidden)
		}
	}
}

func TestMachineValidationKeepsLegacyPublicationAndFailsClosed(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	workflow := readAdminContractFile(t, repoRoot, ".github", "workflows", "admin-release.yml")
	parts := strings.Split(workflow, "\n  validate-machine-package:")
	if len(parts) != 2 {
		t.Fatal("expected one separate non-publishing machine validation job")
	}
	legacy, machine := parts[0], parts[1]
	for _, want := range []string{
		"tags: ['admin-v*']", "if: github.event_name == 'push' || inputs.sku == 'admin'",
		"admin-targets.json", "Publish GitHub admin release",
	} {
		if !strings.Contains(legacy, want) {
			t.Errorf("legacy explicit-repair release lost %q", want)
		}
	}
	for _, want := range []string{
		"inputs.sku != 'admin'", "inputs.publish", "Machine publication remains gated",
		"go run ./internal/mapi/cmd/machine-package", "go-mapi-machine-signed-input-v1",
		"src/service/VERSION", "src/interceptor/interceptor-version.txt",
		"src/app/VERSION", "inputs.sku == 'suite'", "-MachineDistribution",
		"azure/artifact-signing-action@c7ab2a863ab5f9a846ddb8265964877ef296ee82",
		"-RequireSignedInputs", "verify.ps1 -MsiPath $path -SKU $sku",
		"go-mapi-machine-validation-provenance-v1", "publishable=$false",
		"unsignedSha256", "signedSha256", "productCode=$identity.productCode",
		"productVersion=$identity.productVersion", "upgradeCode=$contract.upgradeCode",
	} {
		if !strings.Contains(machine, want) {
			t.Errorf("machine validation path is missing %q", want)
		}
	}
	for _, forbidden := range []string{"softprops/action-gh-release", "wingetcreate.exe", "ADMIN_RELEASE_TARGETS_PRIVATE_KEY_PEM_B64"} {
		if strings.Contains(machine, forbidden) {
			t.Errorf("non-publishing machine validation must not contain %q", forbidden)
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

// WiX expands this one shared include inside each SKU Package. Inspecting the
// effective source keeps contract checks anchored to the authoring WiX compiles.
func readMachinePackageAuthoring(t *testing.T, root, entryName string) string {
	t.Helper()
	entry := readAdminContractFile(t, root, "src", "installer", "msi", entryName)
	const include = "<?include MachinePackage.wxi ?>"
	if strings.Count(entry, include) != 1 {
		t.Fatalf("%s must expand exactly one shared machine package include", entryName)
	}
	shared := readAdminContractFile(t, root, "src", "installer", "msi", "MachinePackage.wxi")
	for name, source := range map[string]string{entryName: entry, "MachinePackage.wxi": shared} {
		var document struct{ XMLName xml.Name }
		if err := xml.Unmarshal([]byte(source), &document); err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		want := "Wix"
		if name == "MachinePackage.wxi" {
			want = "Include"
		}
		if document.XMLName.Local != want {
			t.Fatalf("%s root = %s, want %s", name, document.XMLName.Local, want)
		}
	}
	return strings.Replace(entry, include, shared, 1)
}
