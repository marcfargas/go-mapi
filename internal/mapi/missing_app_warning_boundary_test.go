package mapi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMissingAppWarningStaysDiagnosticAndPerUser(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	read := func(parts ...string) string {
		t.Helper()
		b, err := os.ReadFile(filepath.Join(append([]string{repoRoot}, parts...)...))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	fs := read("src", "interceptor", "fs_utils.cpp")
	impl := read("src", "interceptor", "mapi_impl.cpp")
	app := read("src", "app", "app_presence.go")

	for _, want := range []string{"CSIDL_APPDATA", "app-presence-v1", "warnings\\\\missing-wails-app.warning"} {
		if !strings.Contains(fs, want) {
			t.Errorf("interceptor presence/warning implementation missing %q", want)
		}
	}
	for _, forbidden := range []string{"MessageBox", "RegSetValue", "ShellExecute", "CreateProcess", "RunAs", "makensis"} {
		if strings.Contains(fs, forbidden) || strings.Contains(impl, forbidden) {
			t.Errorf("missing-app warning must remain non-modal and non-installing; found %q", forbidden)
		}
	}
	if !strings.Contains(impl, "return SUCCESS_SUCCESS") || !strings.Contains(impl, "WarnIfWailsAppUnavailable") {
		t.Error("warning must remain a best-effort post-publication MAPI-success side effect")
	}
	for _, want := range []string{"app-presence-v1", "go-mapi-app-presence-v1", "moveFileAtomic"} {
		if !strings.Contains(app, want) {
			t.Errorf("app must own versioned atomic presence marker; missing %q", want)
		}
	}
}
