package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestVerifyInstalledInterceptor(t *testing.T) {
	root := t.TempDir()
	artifacts := make([]map[string]string, 0, 2)
	for _, artifact := range []struct{ architecture, directory, content string }{
		{"x86", "x86", "x86 DLL"}, {"x64", "AMD64", "x64 DLL"},
	} {
		path := filepath.Join(root, artifact.directory, "go-mapi.dll")
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(artifact.content), 0600); err != nil {
			t.Fatal(err)
		}
		hash := sha256.Sum256([]byte(artifact.content))
		artifacts = append(artifacts, map[string]string{
			"architecture":     artifact.architecture,
			"path":             artifact.directory + `\go-mapi.dll`,
			"peProductVersion": "4.0.2",
			"sha256":           hex.EncodeToString(hash[:]),
		})
	}
	manifest := map[string]any{
		"schema": "go-mapi-installed-interceptor-v1", "component": "interceptor",
		"version": "4.0.2", "queueProtocol": "queue-v1",
		"requires":  map[string]string{"component": "app", "minInclusive": "4.0.0"},
		"artifacts": artifacts,
	}
	writeManifest := func() {
		t.Helper()
		data, err := json.Marshal(manifest)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "installed-component-v1.json"), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	check := func(wantError bool) {
		t.Helper()
		writeManifest()
		err := verifyInstalledInterceptor(context.Background(), root, "4.0.2", "4.0.1")
		if (err != nil) != wantError {
			t.Fatalf("health error=%v, want error=%v", err, wantError)
		}
	}
	check(false)

	manifest["version"] = "4.0.3"
	check(true)
	manifest["version"] = "4.0.2"
	manifest["queueProtocol"] = "other"
	check(true)
	manifest["queueProtocol"] = "queue-v1"
	artifacts[0]["path"] = `..\other.dll`
	check(true)
	artifacts[0]["path"] = `x86\go-mapi.dll`
	artifacts[0]["peProductVersion"] = "4.0.3"
	check(true)
	artifacts[0]["peProductVersion"] = "4.0.2"
	artifacts[1]["architecture"] = "x86"
	check(true)
	artifacts[1]["architecture"] = "x64"
	manifest["requires"] = map[string]string{"component": "app", "minInclusive": "4.0.2"}
	check(true)
	manifest["requires"] = map[string]string{"component": "app", "minInclusive": "4.0.0"}
	if err := os.WriteFile(filepath.Join(root, "x86", "go-mapi.dll"), []byte("tampered"), 0600); err != nil {
		t.Fatal(err)
	}
	check(true)
}
