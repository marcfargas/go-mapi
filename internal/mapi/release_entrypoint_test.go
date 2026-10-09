package mapi

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
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
		"ci.yml":                true,
		"app-release.yml":       true,
		"admin-release.yml":     true,
		"hosted-capability.yml": true,
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
		if entry.Name() == "hosted-capability.yml" {
			for _, required := range []string{
				"push:", "'t3code/569-msi-free-preflight-20261009'", "github.sha",
				"if: github.event.created == true",
			} {
				if !strings.Contains(content, required) {
					t.Errorf("one-shot hosted capability workflow is missing %q", required)
				}
			}
			if strings.Contains(content, "workflow_dispatch:") || strings.Contains(content, "branches: ['**']") {
				t.Error("hosted capability must remain branch-scoped and non-manual")
			}
		}
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
		"scripts/build-wails.ps1 -UseEnvironmentCredentials",
		"scripts/build-wails.ps1 -Release -UseEnvironmentCredentials",
		"verify-user-artifact *args:", "scripts/verify-app-artifact.ps1",
		"verify-user-distribution *args:", "scripts/verify-app-distribution.ps1",
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
	buildScript, err := os.ReadFile(filepath.Join(repoRoot, "scripts", "build-wails.ps1"))
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
	verifier, err := os.ReadFile(filepath.Join(repoRoot, "scripts", "verify-app-artifact.ps1"))
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
	producer := regexp.MustCompile(`(?m)name: go-mapi-machine-app\s+path: (ci-input/[^/\s]+)/`).FindStringSubmatch(content)
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
	consumer := regexp.MustCompile(`(?m)name: go-mapi-machine-app\s+path: (ci-input/[^/\s]+)`).FindStringSubmatch(fixtures)
	if len(producer) != 2 || len(consumer) != 2 || producer[1] != consumer[1] ||
		!strings.Contains(fixtures, "-MachineApp "+consumer[1]+"/go-mapi-machine.exe") ||
		!strings.Contains(fixtures, "-AppBuildManifest "+consumer[1]+"/app-artifacts.json") {
		t.Errorf("machine A upload, download, and fixture input paths disagree: producer=%v consumer=%v", producer, consumer)
	}
	if strings.Count(content, "just build-machine-test-packages") != 1 || strings.Contains(scenarios, "build-machine-test-packages") {
		t.Error("machine MSI fixtures must be built once, in the fixture job, and reused by the scenario jobs")
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
		"-Scenario ${{ matrix.scenario }} -CleanupOnly",
		"name: go-mapi-machine-native-validation-${{ matrix.scenario }}-${{ github.run_id }}",
		"signerPublicCertificate", "Import-Certificate",
	} {
		if !strings.Contains(scenarios, want) {
			t.Errorf("machine scenario job is missing %q", want)
		}
	}
	// The aggregate is the gate: it keeps the original job name and fails unless
	// the fixture build and every scenario passed.
	for _, want := range []string{
		"name: Validate machine MSI lifecycle and installed updater",
		"needs: [admin-msi-fixtures, admin-msi-scenario]",
		"always()", "needs.admin-msi-fixtures.result", "needs.admin-msi-scenario.result", `!= "success"`, "exit 1",
	} {
		if !strings.Contains(aggregate, want) {
			t.Errorf("machine MSI aggregate job is missing %q", want)
		}
	}
	for _, want := range []string{
		"workflow_call:", "workflow_dispatch:", "cron: '0 3 * * *'", "contents: read",
		"Build interceptor", "Package and verify the same odd-major standalone bytes", "Validate machine MSI lifecycle and installed updater",
		"just machine-hosted-integration", "just check-portable", "just test-windows", "just build-frontend", "go test -race -v ./internal/mapi/... ./src/app/...",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("CI workflow is missing %q", want)
		}
	}
	sequence, err := os.ReadFile(filepath.Join(repoRoot, "scripts", "run-hosted-machine-integration.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"CrossSkuLifecycle.Tests.ps1", "Invoke-Phase 'update' 'system' 'Hosted'", "Invoke-Phase 'suite-update' 'suite' 'Hosted'", "Invoke-Phase 'update-interruption' 'system' 'InterruptSameBoot' 22",
		"[ValidateSet('all','cross-sku','update','suite-update','update-interruption','readiness-recovery','suite-readiness-recovery')][string]$Scenario = 'all'",
		"if (InScenario 'cross-sku')", "if (InScenario 'update')", "if (InScenario 'suite-update')", "if (InScenario 'update-interruption')",
		"Invoke-Phase 'suite-update' 'suite' 'Cleanup'", "Invoke-Phase 'readiness-recovery' 'system' 'ReadinessRecovery'", "Invoke-Phase 'suite-readiness-recovery' 'suite' 'ReadinessRecovery'", "InScenario $_"} {
		if !strings.Contains(string(sequence), want) {
			t.Errorf("hosted machine sequence is missing %q", want)
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
	if !strings.Contains(read(".github", "workflows", "ci.yml"), "-ValidationTimers") {
		t.Error("the CI fixture build must pass the validation timers")
	}
}

// Every per-wait limit of the machine update driver must tolerate a slow hosted
// runner (three times the worst wait measured on hosted runners under the CI
// timers) and still fail in minutes, not inside the phase deadline. Run
// 36940474780 failed the liveness wait at 142.65 s, 1 s over its 142 s limit, on a
// wait that normally ends within 5 s; the margin was 60 s.
func TestMachineUpdateWaitLimitsTolerateSlowRunners(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	read := func(parts ...string) string {
		t.Helper()
		raw, err := os.ReadFile(filepath.Join(append([]string{repoRoot}, parts...)...))
		if err != nil {
			t.Fatal(err)
		}
		return strings.ReplaceAll(string(raw), "\r\n", "\n")
	}
	script := read("scripts", "run-machine-update-integration.ps1")
	ci := read(".github", "workflows", "ci.yml")
	number := func(text, pattern string) int {
		t.Helper()
		match := regexp.MustCompile(pattern).FindStringSubmatch(text)
		if len(match) != 2 {
			t.Fatalf("pattern %q not found", pattern)
		}
		value, err := strconv.Atoi(match[1])
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	startup := number(ci, `-ValidationStartupDelaySeconds (\d+)`)
	heartbeat := number(ci, `-ValidationHeartbeatSeconds (\d+)`)
	check := number(ci, `-ValidationCheckIntervalSeconds (\d+)`)
	failureBase := number(ci, `-ValidationFailureBaseSeconds (\d+)`)
	install := number(script, `(?m)^\$installWorkSeconds = (\d+)`)
	margin := number(script, `(?m)^\$waitMarginSeconds = (\d+)`)

	// Health publication after private recovery retirement is a new observer
	// boundary (debug702), not another historically measured install/refusal.
	// It reuses the base wait without installer work or failure backoff, and
	// Until clamps it to the phase deadline. The PowerShell evidence test drives
	// absent-health -> healthy and permanent failure through the actual helper.
	// Do not invent a historical measurement or shift the five measurements below.
	healthWait := `Until "published healthy $Key" { AssertHealthy $Key } -PollMilliseconds 500 -Seconds (WaitLimit)`
	if strings.Count(script, healthWait) != 1 || strings.Count(script, "AwaitHealthy $caseB | Out-Null") != 2 {
		t.Fatal("both recovery health observations must use the single bounded strict-health helper")
	}
	if limit := startup + heartbeat + check + margin; limit >= 360 {
		t.Errorf("health publication wait %d s reaches six minutes", limit)
	}
	measuredScript := strings.Replace(script, healthWait, "", 1)

	// Worst wait measured per site, in script order: wrong-SKU refusal, automatic
	// B commit, untrusted-C refusal, automatic C commit (from the trust restore),
	// runner/installer liveness (CI runs 36931761969, 36938262552, 36940474780).
	measured := []float64{5.6, 41.3, 7.3, 99.7, 4.9}
	sites := regexp.MustCompile(`-Seconds \(WaitLimit((?:[^()\n]|\([^()\n]*\))*)\)`).FindAllStringSubmatch(measuredScript, -1)
	if len(sites) != len(measured) {
		t.Fatalf("WaitLimit sites = %d, want %d: a new or removed wait needs a measured worst case here", len(sites), len(measured))
	}
	for i, site := range sites {
		args := site[1]
		owed := 0
		switch {
		case strings.Contains(args, "(2 * $failureBaseSeconds)"):
			owed = 2 * failureBase
		case strings.Contains(args, "$failureBaseSeconds"):
			owed = failureBase
		}
		limit := startup + heartbeat + check + owed + margin
		if strings.Contains(args, "-Install") {
			limit += install
		}
		if float64(limit) < 3*measured[i] {
			t.Errorf("wait %d limit %d s is under three times its worst measured wait %.1f s", i+1, limit, measured[i])
		}
		if limit >= 360 {
			t.Errorf("wait %d limit %d s reaches six minutes; a stall must fail in minutes", i+1, limit)
		}
	}
	if margin < 180 {
		t.Errorf("slow-runner margin %d s is below 180 s", margin)
	}
	// Readiness cases include real Installer idle shutdown and up to three
	// missing-ready observations. They have a separate declared bounded budget.
	for _, required := range []string{"function ReadinessWaitLimit", "-Seconds (ReadinessWaitLimit)", "-Seconds (ReadinessWaitLimit -Install)", "-Seconds (ReadinessWaitLimit -Persistent)", "AssertRecoveryProcessHistory", "Expected five physical runners (B2+C3)"} {
		if !strings.Contains(script, required) {
			t.Errorf("readiness proof lacks %q", required)
		}
	}
	// No wait carries a literal limit, so none escapes the formula above.
	if regexp.MustCompile(`-Seconds \d`).MatchString(script) {
		t.Error("a wait passes a literal -Seconds limit instead of WaitLimit")
	}
	// Evidence for a liveness wait that expires without any runner record.
	for _, want := range []string{
		"} catch { CollectHandoffStallEvidence $livenessWaitStartedUtc; throw }",
		"Record 'handoff-stall-evidence'",
	} {
		if !strings.Contains(script, want) {
			t.Errorf("machine update driver lacks %q", want)
		}
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
