package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The per-user executable may query the WebView2 runtime registry, but must
// never regain machine registration, elevation, or installer behavior.
func TestUserComponentHasNoMachineScopeOperations(t *testing.T) {
	forbidden := []string{
		"--update-check-silent", "updatesStagingDir", "ProgramData", "RunAs", "MAPIRegister", "src/interceptor/", "src/installer/",
		// The user app may use HKLM only for WebView2 detection, and that
		// probe must stay query-only. Any registry mutation or generic write
		// capability belongs to the elevated interceptor installer.
		"registry.CreateKey", "registry.SetStringValue", "registry.SetExpandStringValue", "registry.SetDWordValue", "registry.SetQWordValue", "registry.DeleteKey", ".DeleteValue",
		"registry.SET_VALUE", "registry.WRITE", "registry.ALL_ACCESS", "registry.KEY_WRITE", "syscall.KEY_WRITE", "windows.KEY_WRITE",
	}
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	webViewCheck, err := os.ReadFile("webview2_check.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(webViewCheck), "registry.OpenKey(p.root, p.path, registry.QUERY_VALUE)") {
		t.Error("WebView2 registry probing must remain query-only")
	}
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") {
			continue
		}
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		for _, token := range forbidden {
			// The standalone app owns exactly one current-user Startup Apps
			// registration. Keep the generic registry-write ban for every other
			// app file; the focused assertion below constrains this exception.
			if file == "startup_windows.go" && (token == "registry.CreateKey" || token == "registry.SET_VALUE" || token == ".DeleteValue") {
				continue
			}
			if strings.Contains(string(data), token) {
				t.Errorf("%s contains forbidden component-boundary token %q", file, token)
			}
		}
	}
	commands, err := os.ReadFile(filepath.Join("..", "..", "package.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(commands), "\n") {
		if !strings.Contains(line, ":app") {
			continue
		}
		// The scoped standalone installer is part of this component. Reject
		// only coupling to the admin/interceptor graph or the legacy combined
		// installer entrypoint.
		for _, token := range []string{"interceptor", "build:installer", "src/installer", "build:admin", "elevation"} {
			if strings.Contains(strings.ToLower(line), token) {
				t.Errorf("app command couples to admin component: %s", line)
			}
		}
	}
}

func TestStandaloneStartupRegistrationStaysPerUserAndLimited(t *testing.T) {
	data, err := os.ReadFile("startup_windows.go")
	if err != nil {
		t.Fatal(err)
	}
	content := string(data)
	for _, want := range []string{
		"standaloneStartupKey", `Software\Microsoft\Windows\CurrentVersion\Run`,
		"registry.CURRENT_USER", "registry.SET_VALUE", "userStartupTaskID",
		`fmt.Sprintf(` + "`" + `"%s" --startup` + "`" + `, filepath.Clean(s.exePath))`,
	} {
		if !strings.Contains(content, want) {
			t.Errorf("startup registration missing %q", want)
		}
	}
	for _, forbidden := range []string{"schtasks.exe", "TASK_RUNLEVEL_HIGHEST", "registry.LOCAL_MACHINE", "HKEY_LOCAL_MACHINE"} {
		if strings.Contains(content, forbidden) {
			t.Errorf("startup registration contains machine/elevated token %q", forbidden)
		}
	}
}
