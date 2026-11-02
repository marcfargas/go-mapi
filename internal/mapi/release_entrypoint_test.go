package mapi

import (
	"os"
	"path/filepath"
	"regexp"

	"strings"
	"testing"
)

// These checked-in workflow checks make the component split a release
// authorization boundary. Only the app-v* push and explicit system/suite
// dispatch paths publish; retired admin-v* still fails closed.
func TestOnlySplitReleaseContractsCanPublish(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	for _, release := range []struct {
		path string
		tag  string
	}{
		{"app-release.yml", "tags: ['app-v*']"},
		{"admin-release.yml", "tags: ['admin-v*']"},
	} {
		workflow, err := os.ReadFile(filepath.Join(repoRoot, ".github", "workflows", release.path))
		if err != nil {
			t.Fatalf("read %s: %v", release.path, err)
		}
		content := string(workflow)
		for _, want := range []string{release.tag, "azure/artifact-signing-action@c7ab2a863ab5f9a846ddb8265964877ef296ee82"} {
			if !strings.Contains(content, want) {
				t.Errorf("authoritative workflow %s is missing %q", release.path, want)
			}
		}
		if release.path == "app-release.yml" {
			jobs := strings.Split(content, "\n  publish-app-release:")
			if len(jobs) != 2 || strings.Contains(jobs[0], "contents: write") || !strings.Contains(jobs[1], "contents: write") || !strings.Contains(jobs[1], "gh release create") {
				t.Error("app release must isolate contents: write in its publication job")
			}
		} else {
			jobs := strings.Split(content, "\n  publish-machine-release:")
			if len(jobs) != 2 || strings.Contains(jobs[0], "contents: write") || !strings.Contains(jobs[1], "contents: write") || !strings.Contains(jobs[1], "gh release create") {
				t.Error("machine release must isolate contents: write in its publication job")
			}
		}
	}

	workflowDir := filepath.Join(repoRoot, ".github", "workflows")
	entries, err := os.ReadDir(workflowDir)
	if err != nil {
		t.Fatalf("read workflow directory: %v", err)
	}
	expectedWorkflows := map[string]bool{
		"ci.yml":            true,
		"app-release.yml":   true,
		"admin-release.yml": true,
	}
	seenWorkflows := make(map[string]bool, len(expectedWorkflows))
	for _, entry := range entries {
		if entry.IsDir() || (filepath.Ext(entry.Name()) != ".yml" && filepath.Ext(entry.Name()) != ".yaml") {
			continue
		}
		if !expectedWorkflows[entry.Name()] {
			t.Errorf("unexpected workflow %s; keep the repository workflow topology to CI and the two release contracts", entry.Name())
		}
		seenWorkflows[entry.Name()] = true
		if entry.Name() == "app-release.yml" || entry.Name() == "admin-release.yml" {
			continue
		}
		workflow, err := os.ReadFile(filepath.Join(workflowDir, entry.Name()))
		if err != nil {
			t.Fatalf("read %s: %v", entry.Name(), err)
		}
		content := string(workflow)
		for _, forbidden := range []string{
			"contents: write", "softprops/action-gh-release", "azure/artifact-signing-action",
			"microsoft/microsoft-store-apppublisher", "wingetcreate.exe", "tags: ['app-v*']", "tags: ['admin-v*']",
		} {
			if strings.Contains(content, forbidden) {
				t.Errorf("non-release workflow %s must not contain %q", entry.Name(), forbidden)
			}
		}
	}
	for workflow := range expectedWorkflows {
		if !seenWorkflows[workflow] {
			t.Errorf("required workflow %s is missing", workflow)
		}
	}
}

func TestAppScopedCommandsRemainIndependent(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	justfile, err := os.ReadFile(filepath.Join(repoRoot, "Justfile"))
	if err != nil {
		t.Fatal(err)
	}
	content := string(justfile)
	for _, want := range []string{
		"build-frontend:", "build-user *args:", "build-user-release *args:", "test-user:", "check-user:", "e2e-user:",
		"src/app/build.ps1 -UseEnvironmentCredentials",
		"src/app/build.ps1 -Release -UseEnvironmentCredentials",
		"verify-user-artifact *args:", "src/app/verify-artifact.ps1",
		"verify-user-distribution *args:", "src/app/packaging/verify.ps1",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("Just command contract missing %q", want)
		}
	}
	for _, line := range strings.Split(content, "\n") {
		if !strings.Contains(line, `-user`) {
			continue
		}
		// A user-scoped standalone installer is still an app distribution
		// command. Reject only admin/interceptor coupling here; the app workflow
		// test below separately rejects the legacy combined installer entrypoint.
		if strings.Contains(line, "interceptor") || strings.Contains(line, "package-system") || strings.Contains(line, "makensis") {
			t.Errorf("app command must be component-independent: %s", line)
		}
	}
	buildScript, err := os.ReadFile(filepath.Join(repoRoot, "src", "app", "build.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"components.json", "src/app/VERSION", "build\\windows", "info.json", "FileVersion", "ProductVersion", "-X `\"main.Version=$AppVersion`\"", "finally"} {
		if !strings.Contains(string(buildScript), want) {
			t.Errorf("guarded app entrypoint missing %q", want)
		}
	}
}

func TestAppArtifactVerifierUsesPEMetadataForGuiArtifact(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	verifier, err := os.ReadFile(filepath.Join(repoRoot, "src", "app", "verify-artifact.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	content := string(verifier)
	for _, want := range []string{".VersionInfo", "ProductVersion", "FileVersion", "PE version mismatch"} {
		if !strings.Contains(content, want) {
			t.Errorf("app artifact verifier must validate PE metadata: missing %q", want)
		}
	}
	for _, forbidden := range []string{"(& $ArtifactPath --version)", "--version mismatch"} {
		if strings.Contains(content, forbidden) {
			t.Errorf("GUI artifact verifier must not depend on PowerShell stdout capture: found %q", forbidden)
		}
	}

	mainSource, err := os.ReadFile(filepath.Join(repoRoot, "src", "app", "main.go"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"os.Args[1] == \"--version\"", "println(Version)"} {
		if !strings.Contains(string(mainSource), want) {
			t.Errorf("app runtime must retain its --version intent: missing %q", want)
		}
	}
}

func TestAppReleaseUsesGuardedArtifactEntrypoint(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	workflow, err := os.ReadFile(filepath.Join(repoRoot, ".github", "workflows", "app-release.yml"))
	if err != nil {
		t.Fatal(err)
	}
	content := string(workflow)
	for _, want := range []string{
		"workflow_dispatch:", "version:", "GOMAPI_OAUTH_CLIENT_ID", "GOMAPI_OAUTH_CLIENT_SECRET",
		"src/app/VERSION", "just build-user-release", "just verify-user-artifact", "just verify-user-distribution",
		"github.event_name == 'push' || inputs.publish || inputs.sign",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("app release workflow is missing %q", want)
		}
	}
	for _, forbidden := range []string{
		"build:interceptor", "build:installer", "src/installer/msi",
		"-tags e2e", "GOMAPI_DEBUG_BROWSER_ARGS", "GOMAPI_E2E_",
	} {
		if strings.Contains(content, forbidden) {
			t.Errorf("app release contains forbidden release content %q", forbidden)
		}
	}
}

func TestCIWorkflowRetainsValidationContracts(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	workflow, err := os.ReadFile(filepath.Join(repoRoot, ".github", "workflows", "ci.yml"))
	if err != nil {
		t.Fatal(err)
	}
	content := strings.ReplaceAll(string(workflow), "\r\n", "\n")
	recipes, err := os.ReadFile(filepath.Join(repoRoot, "Justfile"))
	if err != nil {
		t.Fatal(err)
	}
	commands := string(recipes)
	// The machine lifecycle validation is split into a fixture job that builds
	// and signs the packages once, one scenario job per scenario (each on its own
	// runner: the scenarios share machine-global state), and the aggregate gate
	// that keeps the original job name.
	jobText := func(id, next string) string {
		t.Helper()
		start := strings.Index(content, "\n  "+id+":\n")
		end := strings.Index(content, "\n  "+next+":\n")
		if start < 0 || end < start {
			t.Fatalf("CI workflow lacks job %s before %s", id, next)
		}
		return content[start:end]
	}
	fixtures := jobText("admin-msi-fixtures", "admin-msi-scenario")
	scenarios := jobText("admin-msi-scenario", "admin-msi")
	aggregate := jobText("admin-msi", "go-race")
	apps := jobText("app-packages", "user-windows-shell")
	for _, role := range []struct{ name, artifact, appArg, manifestArg string }{
		{"appA", "go-mapi-machine-app", "-MachineApp", "-AppBuildManifest"},
		{"appC", "go-mapi-machine-app-suiteC", "-SuiteCApp", "-SuiteCAppBuildManifest"},
	} {
		producer := regexp.MustCompile(`(?s)- role: ` + role.name + `\s+.*?output: (ci-input/[^\s]+)\s+artifact: ` + role.artifact + `(?:\s|$)`).FindStringSubmatch(apps)
		consumer := regexp.MustCompile(`name: ` + role.artifact + `\s+path: (ci-input/[^\s]+)`).FindStringSubmatch(fixtures)
		if len(producer) != 2 || len(consumer) != 2 || producer[1] != consumer[1] ||
			!strings.Contains(fixtures, role.appArg+" "+consumer[1]+"/go-mapi-machine.exe") ||
			!strings.Contains(fixtures, role.manifestArg+" "+consumer[1]+"/app-artifacts.json") {
			t.Errorf("%s upload, download, and fixture input paths disagree: producer=%v consumer=%v", role.name, producer, consumer)
		}
	}
	if strings.Count(fixtures, "just build-machine-test-packages") != 1 || strings.Contains(scenarios, "build-machine-test-packages") {
		t.Error("machine MSI fixtures must be built once, in the fixture job, and reused by the scenario jobs")
	}
	for _, removed := range []string{"build-ci-apps", "build-ci-fixtures", "trust-ci-fixtures"} {
		if strings.Contains(commands, removed) || strings.Contains(content, removed) {
			t.Errorf("CI orchestration still routes through removed Just recipe %q", removed)
		}
	}
	for _, required := range []string{"role: standalone", "version: baseline", "version: appUpgrade", "uses: ./.github/actions/package-user", "name: ${{ matrix.artifact }}", "path: ${{ matrix.output }}/"} {
		if !strings.Contains(apps, required) {
			t.Errorf("app matrix is missing %q", required)
		}
	}
	if !strings.Contains(fixtures, "name: go-mapi-machine-fixtures-${{ github.run_id }}") ||
		!strings.Contains(scenarios, "name: go-mapi-machine-fixtures-${{ github.run_id }}") {
		t.Error("the scenario jobs must download the fixture job's artifact")
	}
	// Every scenario keeps its own runner, result and artifact; none is dropped.
	for _, want := range []string{
		"scenario: [cross-sku, update, suite-update, update-interruption, readiness-recovery, suite-readiness-recovery]",
		"fail-fast: false",
		"needs: [admin-msi-fixtures]",
		"-Scenario ${{ matrix.scenario }}\n",
		"name: go-mapi-machine-native-validation-${{ matrix.scenario }}-${{ github.run_id }}",
		"$certificate.Thumbprint -cne [string]$manifest.fixture.signerThumbprint",
		"$certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow",
		"Import-Certificate", "if ($env:ACT) { throw",
	} {
		if !strings.Contains(scenarios, want) {
			t.Errorf("machine scenario job is missing %q", want)
		}
	}
	// The aggregate is the gate: it keeps the original job name and fails unless
	// independent Windows checks, fixture build and every scenario passed.
	for _, want := range []string{
		"name: Validate machine MSI lifecycle and installed updater",
		"needs: [windows-check, user-windows-shell, admin-msi-fixtures, admin-msi-scenario]",
		"always()", "needs.windows-check.result", "needs.user-windows-shell.result",
		"needs.admin-msi-fixtures.result", "needs.admin-msi-scenario.result", `!= "success"`, "exit 1",
	} {
		if !strings.Contains(aggregate, want) {
			t.Errorf("machine MSI aggregate job is missing %q", want)
		}
	}
	for _, want := range []string{
		"workflow_call:", "workflow_dispatch:", "cron: '0 3 * * *'", "contents: read",
		"Build interceptor", "app-packages:", "Validate machine MSI lifecycle and installed updater",
		"just machine-hosted-integration", "just check-portable", "just test-service", "just test-windows-race",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("CI workflow is missing %q", want)
		}
	}
	for _, forbidden := range []string{"softprops/action-gh-release", "azure/artifact-signing-action", "environment: artifact-signing", "environment: user-component-release", "environment: system-component-release"} {
		if strings.Contains(content, forbidden) {
			t.Errorf("CI workflow must not have release authority %q", forbidden)
		}
	}
}

// Validation timers exist only in the disposable CI fixture build. No release
// path passes them, the service build refuses them under the release trust
// switch, and the public provenance check requires their absence.
func TestReleasePathsCarryNoValidationTimers(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	read := func(parts ...string) string {
		t.Helper()
		raw, err := os.ReadFile(filepath.Join(append([]string{repoRoot}, parts...)...))
		if err != nil {
			t.Fatal(err)
		}
		return strings.ReplaceAll(string(raw), "\r\n", "\n")
	}
	release := read(".github", "workflows", "admin-release.yml")
	for _, forbidden := range []string{"ValidationTimers", "ValidationStartupDelaySeconds", "ValidationHeartbeatSeconds", "ValidationFailureBaseSeconds", "ValidationCheckIntervalSeconds"} {
		if strings.Contains(release, forbidden) {
			t.Errorf("release workflow must not pass validation timers: %q", forbidden)
		}
	}
	if !strings.Contains(release, "$derivative.Contains('timers')") {
		t.Error("public machine provenance check must require the absence of validation timers")
	}
	for _, derivative := range regexp.MustCompile(`(?m)^\s*\[ordered\]@\{ kind='[^']+';[^\n]*$`).FindAllString(release, -1) {
		if strings.Contains(derivative, "timers") {
			t.Errorf("a machine derivative record carries validation timers: %s", strings.TrimSpace(derivative))
		}
	}
	build := read("src", "service", "build.ps1")
	if !strings.Contains(build, "if ($RequireMachineReleaseTrust -and $validationSet.Count -gt 0) { throw 'Release service must not carry validation timers' }") {
		t.Error("service build must reject validation timers under -RequireMachineReleaseTrust")
	}
	ci := read(".github", "workflows", "ci.yml")
	if !strings.Contains(ci, "just build-machine-test-packages -FixtureSpecification src/installer/msi/tests/fixtures/machine.json") || !strings.Contains(ci, "-ValidationTimers") {
		t.Error("the CI fixture build must select the single fixture specification and validation timers")
	}
}

func TestInterceptorReleaseUsesWindowsSafeVersionInput(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	componentManifest, err := os.ReadFile(filepath.Join(repoRoot, "components.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(componentManifest), "src/interceptor/VERSION") || !strings.Contains(string(componentManifest), "src/interceptor/interceptor-version.txt") {
		t.Error("interceptor version input must not collide with libc++ <version> on Windows")
	}

	verifier, err := os.ReadFile(filepath.Join(repoRoot, "src", "interceptor", "verify-release.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	content := string(verifier)
	if strings.Contains(content, "[string]$OutputDirectory =") || !strings.Contains(content, "$OutputDirectory = Join-Path $repoRoot") {
		t.Error("interceptor verifier must calculate its output default after script-root initialization")
	}
	for _, forbidden := range []string{"-Encoding utf8NoBOM", "-Encoding utf8BOM"} {
		if strings.Contains(content, forbidden) {
			t.Errorf("interceptor verifier must remain Windows PowerShell 5.1 compatible; found %q", forbidden)
		}
	}
	for _, want := range []string{"[IO.File]::WriteAllText(", "New-Object System.Text.UTF8Encoding($false)"} {
		if !strings.Contains(content, want) {
			t.Errorf("interceptor verifier must write its artifact manifest as UTF-8 without a BOM: missing %q", want)
		}
	}
}
