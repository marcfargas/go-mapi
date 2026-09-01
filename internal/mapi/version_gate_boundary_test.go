package mapi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVersionGateReleaseInputsRemainIndependent(t *testing.T) {
	root := filepath.Clean(filepath.Join("..", ".."))
	read := func(parts ...string) string {
		t.Helper()
		data, err := os.ReadFile(filepath.Join(append([]string{root}, parts...)...))
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	appBuild := read("scripts", "build-wails.ps1")
	interceptorBuild := read("src", "interceptor", "build.ps1")
	for _, want := range []string{"main.RequiredInterceptorMin", "main.RequiredInterceptorMax", "app-artifacts.json"} {
		if !strings.Contains(appBuild, want) {
			t.Errorf("app release metadata missing %q", want)
		}
	}
	if strings.Contains(appBuild, "interceptor-version.txt") {
		t.Error("app build must not read the interceptor version input")
	}
	for _, want := range []string{"GO_MAPI_REQUIRED_APP_MIN", "GO_MAPI_REQUIRED_APP_MAX", "components.interceptor.requires"} {
		if !strings.Contains(interceptorBuild, want) {
			t.Errorf("interceptor release metadata missing %q", want)
		}
	}
	if strings.Contains(interceptorBuild, "src/app/VERSION") {
		t.Error("interceptor build must not read the app version input")
	}
}

func TestVersionGateHasFixedQueryOnlyAdminProbe(t *testing.T) {
	root := filepath.Clean(filepath.Join("..", ".."))
	windowsProbe, err := os.ReadFile(filepath.Join(root, "src", "app", "component_health_windows.go"))
	if err != nil {
		t.Fatal(err)
	}
	probe := string(windowsProbe)
	for _, want := range []string{"FOLDERID_ProgramFiles", "go-mapi", "interceptor", "installedInterceptorName", "GetFileVersionInfoW", "ProductVersion"} {
		if !strings.Contains(probe, want) {
			t.Errorf("production admin probe missing %q", want)
		}
	}
	for _, forbidden := range []string{"os.Getenv", "registry.", "SetValue", "CreateKey", "DeleteKey", "ShellExecute", "CreateProcess"} {
		if strings.Contains(probe, forbidden) {
			t.Errorf("production admin probe is not query-only: %q", forbidden)
		}
	}
}

func TestVersionMismatchIsPrePublicationAndAppVisible(t *testing.T) {
	root := filepath.Clean(filepath.Join("..", ".."))
	read := func(parts ...string) string {
		t.Helper()
		data, err := os.ReadFile(filepath.Join(append([]string{root}, parts...)...))
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	impl := read("src", "interceptor", "mapi_impl.cpp")
	preflight := strings.Index(impl, "if (!AppCounterpartAllowsPublication())")
	copyAttachments := strings.Index(impl, "CopyAttachmentsForStem(msg, stem)")
	if preflight < 0 || copyAttachments < 0 || preflight > copyAttachments {
		t.Error("compatibility preflight must exist before attachment publication")
	}
	for _, want := range []string{"MAPI_E_FAILURE", "WriteComponentMismatchWarning", "RemoveComponentMismatchWarning"} {
		if !strings.Contains(impl, want) {
			t.Errorf("interceptor gate missing %q", want)
		}
	}
	for _, forbidden := range []string{"MessageBox", "ShellExecute", "CreateProcess", "RegSetValue", "download", "telemetry"} {
		if strings.Contains(impl, forbidden) {
			t.Errorf("interceptor gate gained forbidden behavior %q", forbidden)
		}
	}
	health := read("src", "app", "component_health.go")
	frontend := read("src", "app", "frontend", "src", "App.svelte")
	for _, want := range []string{"component-version-mismatch-v1.json", "diagnostic-invalid", "repair-interceptor", "update-app"} {
		if !strings.Contains(health, want) {
			t.Errorf("app health reader missing %q", want)
		}
	}
	if !strings.Contains(frontend, "componentHealth.issues") || !strings.Contains(frontend, "issue.action") {
		t.Error("frontend does not render persistent multi-issue component health")
	}
}
