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

// Immediate custom actions impersonate the installer caller, which under
// UAC/RDSH can be a filtered, non-elevated token. Protected journal writes must
// therefore be deferred SYSTEM work protected by an earlier-queued rollback.
func TestMachineMigrationPreparationIsDeferredAndTransactionOwned(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	shared := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "SharedMachine.wxs")
	sequence := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "MachinePackage.wxi")
	project := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "customaction", "GoMapi.AdminCustomActions.csproj")
	verify := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "verify.ps1")
	actions := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "customaction", "AdminMigration.cs")
	lifecycle := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "tests", "CrossSkuLifecycle.Tests.ps1")

	for _, want := range []string{"'before-prepare', 'after-partial-snapshot', 'after-snapshot'", "AssertJournal $suiteJournalBeforeUpgrade", "AssertJournal $systemJournalBeforeMigration"} {
		if !strings.Contains(lifecycle, want) {
			t.Errorf("native lifecycle test missing preparation fault coverage %q", want)
		}
	}
	for _, want := range []string{
		`<CustomAction Id="PrepareAdminMigration" BinaryRef="AdminCustomActions" DllEntry="PrepareAdminMigration" Execute="immediate" Return="check" />`,
		`<CustomAction Id="SnapshotAdminMigration" BinaryRef="AdminCustomActions" DllEntry="SnapshotAdminMigration" Execute="deferred" Impersonate="no" Return="check" HideTarget="yes" />`,
	} {
		if !strings.Contains(shared, want) {
			t.Errorf("migration action authoring missing %q", want)
		}
	}
	for _, want := range []string{
		`<CustomActionRef Id="SnapshotAdminMigration" />`,
		`<Custom Action="PrepareAdminMigration" Before="RollbackAdminMigration" Condition="NOT (REMOVE~=&quot;ALL&quot;)" />`,
		`<Custom Action="RollbackAdminMigration" Before="SnapshotAdminMigration" Condition="NOT (REMOVE~=&quot;ALL&quot;)" />`,
		`<Custom Action="SnapshotAdminMigration" Before="ApplyAdminMigration" Condition="NOT (REMOVE~=&quot;ALL&quot;)" />`,
		`<Custom Action="ApplyAdminMigration" After="RemoveExistingProducts" Condition="NOT (REMOVE~=&quot;ALL&quot;)" />`,
		`<Custom Action="VerifyAdminRegistration" After="WriteRegistryValues" Condition="NOT (REMOVE~=&quot;ALL&quot;)" />`,
	} {
		if !strings.Contains(sequence, want) {
			t.Errorf("migration sequence missing %q", want)
		}
	}
	if !strings.Contains(project, `<PackageReference Include="WixToolset.Dtf.CustomAction" Version="5.0.2" />`) {
		t.Error("custom actions must use the DTF SfxCA that extracts to user temp when not elevated")
	}
	for _, want := range []string{"SnapshotAdminMigration", "0x0C00", "0x0D00", "0x0E00", "rollback queued before the snapshot it protects", "WriteRegistryValues"} {
		if !strings.Contains(verify, want) {
			t.Errorf("compiled MSI verifier missing migration execution check %q", want)
		}
	}

	prepare := customActionBody(t, actions, "PrepareAdminMigration")
	for _, forbidden := range []string{"EnsureProtectedJournalDirectory", "SaveJournal", "CaptureProvider", "File.Copy", "ProtectJournalFile", "Delete"} {
		if strings.Contains(prepare, forbidden) {
			t.Errorf("immediate PrepareAdminMigration must stay read-only; found %q", forbidden)
		}
	}
	for _, want := range []string{`["TransactionId"] = Guid.NewGuid().ToString("D")`, `session["SnapshotAdminMigration"] = data;`, `session["RollbackAdminMigration"] = data;`} {
		if !strings.Contains(prepare, want) {
			t.Errorf("immediate PrepareAdminMigration missing marshaling %q", want)
		}
	}
	snapshot := customActionBody(t, actions, "SnapshotAdminMigration")
	for _, want := range []string{
		"RequireFixedPaths(data)", `MaybeFail(data, "before-prepare")`, "EnsureProtectedJournalDirectory",
		`MaybeFail(data, "after-partial-snapshot")`, "previous-journal.json", "SaveJournal(paths.JournalPath, journal)",
		`MaybeFail(data, "after-snapshot")`, "PruneTransactionBackups",
	} {
		if !strings.Contains(snapshot, want) {
			t.Errorf("deferred snapshot missing %q", want)
		}
	}
	if strings.Index(snapshot, "SaveJournal(") < strings.Index(snapshot, "after-partial-snapshot") {
		t.Error("previous journal must remain until the replacement snapshot is complete")
	}
	if strings.Contains(snapshot, `session["`) {
		t.Error("deferred snapshot must not read or propagate Session properties")
	}
	for name, want := range map[string]string{
		"ApplyAdminMigration":     "RequireTransactionJournal(paths.JournalPath, data[\"TransactionId\"])",
		"VerifyAdminRegistration": "RequireTransactionJournal(paths.JournalPath, data[\"TransactionId\"])",
		"RollbackAdminMigration":  "RemoveTransactionResidue(paths, transactionDirectory, data)",
	} {
		if !strings.Contains(customActionBody(t, actions, name), want) {
			t.Errorf("%s is not bound to its own transaction: missing %q", name, want)
		}
	}
	rollback := customActionBody(t, actions, "RollbackAdminMigration")
	for _, want := range []string{"journal.PreviousJournalSha256", "AtomicWriteBytes(paths.JournalPath", "ProtectJournalFile(paths.JournalPath)"} {
		if !strings.Contains(rollback, want) {
			t.Errorf("migration rollback does not restore the previous journal: missing %q", want)
		}
	}
	for _, want := range []string{
		`"go-mapi", "installer-journal"),`, `SafeDeleteDirectory(Path.Combine(machineRoot, "installer-journal"));`,
		"OwnedDllBackupSha256", "RequireBoundedRegularFile(path, \"Migration journal\")",
		"session.Message(InstallMessage.Error", "SetupBlockedException", "DisableRollback", "GOMAPI_MIGRATE_SKU=1", "/l*vx",
	} {
		if !strings.Contains(actions, want) {
			t.Errorf("custom actions missing %q", want)
		}
	}
	for _, forbidden := range []string{"MessageBox", "UILevel"} {
		if strings.Contains(actions, forbidden) {
			t.Errorf("custom actions must let Windows Installer govern UI; found %q", forbidden)
		}
	}
}

func customActionBody(t *testing.T, source, name string) string {
	t.Helper()
	start := strings.Index(source, "public static ActionResult "+name+"(Session session)")
	if start < 0 {
		t.Fatalf("custom action %s not found", name)
	}
	end := strings.Index(source[start+1:], "[CustomAction]")
	if end < 0 {
		return source[start:]
	}
	return source[start : start+1+end]
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
			`Schedule="afterInstallExecute"`,
			// Covers the old product's removal inside an upgrade or migration.
			`Before="DeleteServices" Condition="REMOVE~=&quot;ALL&quot;"`,
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

// Every machine transaction stops the installed suite app in all sessions
// before the old product is removed or any file is replaced (Ticket 529).
// Windows Installer permits an early RemoveExistingProducts only directly
// after InstallInitialize or after InstallExecute, so the stop is executed by
// an early InstallExecute that RemoveExistingProducts directly follows.
func TestMachineMsiStopsInstalledSuiteAppsBeforeRemoval(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	shared := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "SharedMachine.wxs")
	verify := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "verify.ps1")
	lifecycle := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "tests", "CrossSkuLifecycle.Tests.ps1")
	stop := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "customaction", "SuiteAppStop.cs")
	for _, filename := range []string{"Package.wxs", "SuitePackage.wxs"} {
		entry := readMachinePackageAuthoring(t, repoRoot, filename)
		for _, want := range []string{
			`<MajorUpgrade Schedule="afterInstallExecute"`,
			`<CustomActionRef Id="StopSuiteApps" />`,
			`<Custom Action="StopSuiteApps" After="InstallInitialize" Condition="NOT UPGRADINGPRODUCTCODE" />`,
			`<InstallExecute After="StopSuiteApps" />`,
			`<CustomActionRef Id="PreStopSuiteApps" />`,
			// WiX 4 rejects After together with Before; verify.ps1 checks the
			// compiled LaunchConditions < PreStopSuiteApps < CostInitialize order.
			`<Custom Action="PreStopSuiteApps" After="LaunchConditions" Condition="NOT UPGRADINGPRODUCTCODE" />`,
			// A rolled-back final uninstall must restore the service's SCM
			// settings too, or its health proof keeps suite admission closed.
			`<Custom Action="RollbackServiceConfiguration" Before="DeleteServices" Condition="REMOVE~=&quot;ALL&quot;" />`,
		} {
			if !strings.Contains(entry, want) {
				t.Errorf("%s missing suite app stop contract %q", filename, want)
			}
		}
	}
	suite := readAdminContractFile(t, repoRoot, "src", "installer", "msi", "SuitePackage.wxs")
	if !strings.Contains(suite, `<Property Id="MSIRESTARTMANAGERCONTROL" Value="Disable" />`) {
		t.Error("suite must not let Restart Manager close programs that hold the interceptor")
	}
	for _, want := range []string{
		`<CustomAction Id="StopSuiteApps" BinaryRef="AdminCustomActions" DllEntry="StopSuiteApps" Execute="deferred" Impersonate="no" Return="check" HideTarget="yes" />`,
		`<SetProperty Id="StopSuiteApps" Before="InstallInitialize" Sequence="execute"`,
		`Value="FailurePoint=[GOMAPI_TEST_FAILURE_POINT];ProgramFiles64=[ProgramFiles64Folder];CommonAppData=[CommonAppDataFolder]"`,
		`<CustomAction Id="PreStopSuiteApps" BinaryRef="AdminCustomActions" DllEntry="PreStopSuiteApps" Execute="immediate" Return="ignore" />`,
	} {
		if !strings.Contains(shared, want) {
			t.Errorf("suite app stop authoring missing %q", want)
		}
	}
	if strings.Contains(shared, `Id="PreStopSuiteApps" BinaryRef="AdminCustomActions" DllEntry="PreStopSuiteApps" Execute="immediate" Return="ignore" Impersonate`) {
		t.Error("the immediate pre-stop always runs as the caller and must not declare Impersonate")
	}
	for _, want := range []string{
		"'StopSuiteApps,InstallExecute'", "exactly one InstallExecute", "StopSuiteApps must precede $later", "'SetStopSuiteApps'",
		"'PreStopSuiteApps'", "PreStopSuiteApps must run after LaunchConditions and before CostInitialize",
		"PreStopSuiteApps must not be sequenced in $table", "'InstallUISequence','AdminUISequence','AdminExecuteSequence','AdvtExecuteSequence'",
	} {
		if !strings.Contains(verify, want) {
			t.Errorf("compiled MSI verifier missing suite app stop check %q", want)
		}
	}
	body := customActionBody(t, stop, "StopSuiteApps")
	for _, want := range []string{"CloseSuiteAdmission", "DrainSuiteApps", `MaybeFail(data, "after-suite-stop")`, `"suite-stop-bound"`} {
		if !strings.Contains(body, want) {
			t.Errorf("StopSuiteApps missing %q", want)
		}
	}
	for _, want := range []string{
		`@"go-mapi\user\go-mapi.exe"`, `@"go-mapi\status\suite-admission-v1"`,
		"QueryFullProcessImageName", "TerminateProcess", "NumberOfLinks != 1", `"S-1-5-80-"`,
		"TimeSpan.FromSeconds(30)", "SetupBlockedException",
	} {
		if !strings.Contains(stop, want) {
			t.Errorf("suite app stop implementation missing %q", want)
		}
	}
	// The resident service is the only writer of O; the installer only closes.
	// The service reopens the gate as soon as Windows Installer is idle, with
	// its one-minute heartbeat as the backstop.
	if strings.Contains(stop, "(byte)'O'") {
		t.Error("installer custom action must never reopen suite admission")
	}
	// The pre-stop runs as the caller before costing. It never touches the
	// admission gate, never reports a setup error and never fails setup.
	preStop := customActionBody(t, stop, "PreStopSuiteApps")
	for _, forbidden := range []string{"CloseSuiteAdmission", "SuiteAdmissionRelativePath", "suite-admission-v1", "Guard(", "ReportFailure", "SetupBlockedException", "WaitForMultipleObjects"} {
		if strings.Contains(preStop, forbidden) {
			t.Errorf("PreStopSuiteApps must not use %q", forbidden)
		}
	}
	for _, want := range []string{
		`session["ProgramFiles64Folder"]`, "SeDebugPrivilege", "SweepSuiteApps", "ReapExited", "TerminateProcess",
		`"pre-stop-throw"`, "catch (Exception", "return ActionResult.Success", "go-mapi suite app pre-stop: terminated={0} skipped={1}",
	} {
		if !strings.Contains(preStop, want) {
			t.Errorf("PreStopSuiteApps missing %q", want)
		}
	}
	for _, want := range []string{
		"Invoke-RunningAppTransaction '/fa' $suitePath",
		"Invoke-RunningAppTransaction '/i' $newerSuitePath 'suite-upgrade'",
		"Invoke-RunningAppTransaction '/x' $newerSuitePath 'suite-final-uninstall'",
		"Invoke-RunningAppTransaction '/i' $systemPath 'system-migration'",
		"GOMAPI_TEST_FAILURE_POINT=after-suite-stop", "GOMAPI_TEST_FAILURE_POINT=suite-stop-bound",
		"GOMAPI_TEST_FAILURE_POINT=after-uninstall-finalize') -Expected 1603",
		"Assert-LaunchRestored", "Start-Decoy", "RequireOtherSession",
		"GOMAPI_TEST_FAILURE_POINT=pre-stop-throw", "'go-mapi suite app pre-stop ignored an error'",
		"Invoke-RunningAppTransaction '/i' $newerAppSuitePath 'suite-upgrade-app'",
		"Invoke-RunningAppTransaction '/x' $newerAppSuitePath 'suite-app-upgrade-uninstall'",
		"'suite app pre-stop did not finish before the outer CostInitialize'",
		"Assert-ServiceConfiguration 'suite final uninstall rollback'",
		// Admission reopens within 15 s of the msiexec exit after every
		// successful suite transaction (Ticket 529 V1).
		"$script:LastMsiExitTime = Get-Date", "Wait-GateOpen $Name 15 -FromMsiExit", "GateOpenSeconds",
	} {
		if !strings.Contains(lifecycle, want) {
			t.Errorf("native lifecycle missing running suite app coverage %q", want)
		}
	}
	// A Windows checkout can convert the script to CRLF; the check below
	// spans lines.
	machineUpdate := strings.ReplaceAll(readAdminContractFile(t, repoRoot, "scripts", "run-machine-update-integration.ps1"), "\r\n", "\n")
	for _, want := range []string{
		// The administrator repair keeps its unchanged health assertion and
		// must also reopen admission promptly.
		"        $disabled = AssertHealthy $caseC\n        if ($disabled.marker.autoUpdateEnabled -ne 0) { throw 'Administrator disable did not persist' }\n        AssertAdmissionReopened 'administrator-disable' 15\n",
		"$script:lastAdministratorMsiUtc = [DateTime]::UtcNow",
	} {
		if !strings.Contains(machineUpdate, want) {
			t.Errorf("machine update integration missing suite admission reopen check %q", want)
		}
	}
	// Hosted CI must run an upgrade that replaces the running app file.
	hosted := readAdminContractFile(t, repoRoot, "scripts", "run-hosted-machine-integration.ps1")
	if !strings.Contains(hosted, "-NewerAppSuiteMsi $fixture.packages.suiteC.msi") {
		t.Error("hosted machine integration must pass the app-changing suite fixture to the lifecycle test")
	}
	// The interceptor starts the resident app as the sender's child, and
	// Start-Process -Wait waits for descendants: the launch probe sender must
	// be waited for alone and with a bound (Ticket 529 V2).
	senderStarts := 0
	for _, line := range strings.Split(lifecycle, "\n") {
		if !strings.Contains(line, "Start-Process -FilePath $powerShell") {
			continue
		}
		senderStarts++
		if !strings.Contains(line, "-PassThru") || strings.Contains(line, "-Wait") {
			t.Errorf("launch probe sender must start with -PassThru and without -Wait: %s", strings.TrimSpace(line))
		}
	}
	if senderStarts != 1 {
		t.Errorf("launch probe sender starts = %d, want 1", senderStarts)
	}
	for _, want := range []string{"$senderProcess.WaitForExit(30000)", "Stop-Process -Id $senderProcess.Id", "SenderExited = $senderExited"} {
		if !strings.Contains(lifecycle, want) {
			t.Errorf("launch probe sender lacks its bounded wait %q", want)
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
		"tags: ['admin-v*']", "reject-retired-admin-release:", "github.event_name == 'push' || inputs.sku == 'admin'",
		"This checkout no longer builds the legacy interceptor-only admin release", "exit 1",
		"environment: artifact-signing", "id-token: write", "AZURE_ARTIFACT_SIGNING_ENDPOINT",
		"azure/artifact-signing-action@c7ab2a863ab5f9a846ddb8265964877ef296ee82", "-RequireSignedInputs",
	} {
		if !strings.Contains(workflow, want) {
			t.Errorf("admin release workflow missing %q", want)
		}
	}
	for _, forbidden := range []string{"build-wails", "npm run build:app", "src/app/build", "go-mapi.exe", "softprops/action-gh-release", "wingetcreate.exe", "release/admin/", "build.ps1 -Version"} {
		if strings.Contains(legacyWorkflow, forbidden) {
			t.Errorf("retired admin release can build or publish via %q", forbidden)
		}
	}
}

func TestMachineValidationRetiresLegacyPublicationAndFailsClosed(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	workflow := readAdminContractFile(t, repoRoot, ".github", "workflows", "admin-release.yml")
	parts := strings.Split(workflow, "\n  validate-machine-package:")
	if len(parts) != 2 {
		t.Fatal("expected one separate machine build and validation job")
	}
	publishing := strings.Split(parts[1], "\n  publish-machine-release:")
	if len(publishing) != 2 {
		t.Fatal("expected one separate machine publication job")
	}
	legacy, machine, publisher := parts[0], publishing[0], publishing[1]
	for _, want := range []string{
		"tags: ['admin-v*']", "if: github.event_name == 'push' || inputs.sku == 'admin'",
		"exit 1",
	} {
		if !strings.Contains(legacy, want) {
			t.Errorf("retired admin release refusal lost %q", want)
		}
	}
	for _, want := range []string{
		"inputs.sku != 'admin'", "inputs.publish", "Public machine release requires the exact signed 3.2 development tag",
		"go run ./internal/mapi/cmd/machine-package", "go-mapi-machine-signed-input-v1",
		"src/service/VERSION", "src/interceptor/interceptor-version.txt",
		"src/app/VERSION", "inputs.sku == 'suite'", "just build-user-machine",
		"azure/artifact-signing-action@c7ab2a863ab5f9a846ddb8265964877ef296ee82",
		"-RequireSignedInputs", "just $verifyRecipe -MsiPath $path",
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
			t.Errorf("machine builder must not contain %q", forbidden)
		}
	}
	for _, want := range []string{"contents: write", "actions/download-artifact@v4", "already exists; immutable assets cannot be replaced", "--verify-tag", "gh release create", "cmp \"$file\""} {
		if !strings.Contains(strings.ToLower(publisher), strings.ToLower(want)) {
			t.Errorf("separate machine publisher is missing %q", want)
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
