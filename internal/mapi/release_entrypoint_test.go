package mapi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// These checks keep the distributor workflow on the component release
// entrypoints. They deliberately inspect the checked-in workflow and scripts:
// a release must not silently regain a direct build command that bypasses the
// independent component-version files' development-version guards.
func TestInstallerReleaseUsesComponentReleaseEntrypoints(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	workflow, err := os.ReadFile(filepath.Join(repoRoot, ".github", "workflows", "installer-release.yml"))
	if err != nil {
		t.Fatalf("read installer release workflow: %v", err)
	}
	content := string(workflow)
	for _, want := range []string{
		"src/app/VERSION', 'src/interceptor/interceptor-version.txt",
		"npm run build:interceptor:release",
		"scripts/build-wails.ps1 -Release -UseEnvironmentCredentials -Aumid com.marcfargas.gomapi",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("installer release workflow is missing %q", want)
		}
	}

	packageJSON, err := os.ReadFile(filepath.Join(repoRoot, "package.json"))
	if err != nil {
		t.Fatalf("read package.json: %v", err)
	}
	for _, want := range []string{
		`"build:interceptor:release"`,
		`-Arch x64 -Config Release -Release`,
		`-Arch x86 -Config Release -Release`,
	} {
		if !strings.Contains(string(packageJSON), want) {
			t.Errorf("package release entrypoint is missing %q", want)
		}
	}
}

func TestAppScopedCommandsRemainIndependent(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	packageJSON, err := os.ReadFile(filepath.Join(repoRoot, "package.json"))
	if err != nil {
		t.Fatal(err)
	}
	content := string(packageJSON)
	for _, want := range []string{
		`"build:app:frontend"`, `"build:app"`, `"build:app:release"`, `"test:app"`, `"check:app"`,
		`"build:app": "powershell -ExecutionPolicy Bypass -File scripts/build-wails.ps1 -UseEnvironmentCredentials"`,
		`"build:app:release": "powershell -ExecutionPolicy Bypass -File scripts/build-wails.ps1 -Release -UseEnvironmentCredentials"`,
		`"build": "npm run build:interceptor`, `"test": "npm run -w @marcfargas/go-mapi-app-frontend build`,
		`"check": "npm run -w @marcfargas/go-mapi-app-frontend build`,
	} {
		if !strings.Contains(content, want) {
			t.Errorf("package command contract missing %q", want)
		}
	}
	for _, line := range strings.Split(content, "\n") {
		if !strings.Contains(line, `:app`) {
			continue
		}
		// A user-scoped standalone installer is still an app distribution
		// command. Reject only admin/interceptor coupling here; the app workflow
		// test below separately rejects the legacy combined installer entrypoint.
		if strings.Contains(line, "interceptor") || strings.Contains(line, "build:installer") || strings.Contains(line, "makensis") {
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

func TestAppWorkflowUsesGuardedReleaseArtifactEntrypoint(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	workflow, err := os.ReadFile(filepath.Join(repoRoot, ".github", "workflows", "app.yml"))
	if err != nil {
		t.Fatal(err)
	}
	content := string(workflow)
	for _, want := range []string{
		"workflow_dispatch:", "app_version:", "GOMAPI_OAUTH_CLIENT_ID", "GOMAPI_OAUTH_CLIENT_SECRET",
		"src/app/VERSION", "npm run build:app:release", "scripts/verify-app-artifact.ps1", "github.event_name == 'workflow_dispatch'",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("app release workflow is missing %q", want)
		}
	}
	for _, forbidden := range []string{"build:interceptor", "build:installer", "makensis"} {
		if strings.Contains(content, forbidden) {
			t.Errorf("app workflow must not invoke an admin component command: %q", forbidden)
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
