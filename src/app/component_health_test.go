package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

func TestInstalledInterceptorProbeAndMismatchMerge(t *testing.T) {
	root := t.TempDir()
	manifestPath := filepath.Join(root, installedInterceptorName)
	artifacts := []installedInterceptorArtifact{}
	for _, arch := range []string{"x86", "x64"} {
		rel := filepath.Join(arch, "go-mapi.dll")
		full := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0700); err != nil {
			t.Fatal(err)
		}
		contents := []byte("fixture-" + arch)
		if err := os.WriteFile(full, contents, 0600); err != nil {
			t.Fatal(err)
		}
		hash := sha256.Sum256(contents)
		artifacts = append(artifacts, installedInterceptorArtifact{Architecture: arch, Path: rel, PEProductVersion: "4.1.0", SHA256: hex.EncodeToString(hash[:])})
	}
	manifest := installedInterceptorManifest{Schema: installedInterceptorSchema, Component: "interceptor", Version: "4.1.0", QueueProtocol: componentQueueProtocol, Requires: mapi.CounterpartRequirement{Component: "app", MinInclusive: "4.2.0"}, Artifacts: artifacts}
	writeJSONFixture(t, manifestPath, manifest)
	warningPath := filepath.Join(root, "warnings", componentMismatchWarningName)
	warning := componentMismatchWarning{Schema: componentMismatchWarningSchema, Action: "update-app", CreatedAt: time.Now().UTC()}
	warning.Interceptor.Version = "4.1.0"
	warning.Interceptor.Architecture = "x86"
	warning.Interceptor.Requires = mapi.CounterpartRequirement{Component: "app", MinInclusive: "4.2.0"}
	warning.App.ObservedStatus = "below-minimum"
	warning.App.ObservedVersion = "4.0.0"
	writeJSONFixture(t, warningPath, warning)

	probe := componentHealthProbe{appVersion: "4.0.0", interceptorRequirement: mapi.CounterpartRequirement{Component: "interceptor", MinInclusive: "4.0.0"}, manifestPath: func() (string, error) { return manifestPath, nil }, peProductVersion: func(string) (string, error) { return "4.1.0", nil }, warningPath: warningPath, now: time.Now}
	state := probe.probe()
	if state.Healthy || len(state.Issues) != 1 {
		t.Fatalf("state = %#v", state)
	}
	if state.Issues[0].Action != "update-app" {
		t.Fatalf("issues = %#v", state.Issues)
	}
	if len(state.Issues[0].Architectures) != 1 || state.Issues[0].Architectures[0] != "x86" {
		t.Fatalf("warning issue = %#v", state.Issues[0])
	}
}

func TestMismatchWarningResolvesAfterAppUpgrade(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, componentMismatchWarningName)
	warning := componentMismatchWarning{Schema: componentMismatchWarningSchema, Action: "update-app", CreatedAt: time.Now().UTC()}
	warning.Interceptor.Version = "4.1.0"
	warning.Interceptor.Architecture = "x64"
	warning.Interceptor.Requires = mapi.CounterpartRequirement{Component: "app", MinInclusive: "4.2.0"}
	warning.App.ObservedStatus = "below-minimum"
	writeJSONFixture(t, path, warning)
	probe := componentHealthProbe{appVersion: "4.2.0", warningPath: path}
	if issue := probe.probeMismatchWarning(); issue != nil {
		t.Fatalf("issue = %#v", issue)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("warning not removed: %v", err)
	}
}

func TestInstalledManifestRejectsTraversalAndArchitectureDivergence(t *testing.T) {
	base := t.TempDir()
	manifest := installedInterceptorManifest{Schema: installedInterceptorSchema, Component: "interceptor", Version: "4.0.0", QueueProtocol: componentQueueProtocol, Requires: mapi.CounterpartRequirement{Component: "app", MinInclusive: "4.0.0"}, Artifacts: []installedInterceptorArtifact{
		{Architecture: "x86", Path: filepath.Join("..", "escape.dll"), PEProductVersion: "4.0.0", SHA256: string(make([]byte, 64))},
		{Architecture: "x64", Path: "x64\\go-mapi.dll", PEProductVersion: "4.1.0", SHA256: string(make([]byte, 64))},
	}}
	if err := validateInstalledManifest(filepath.Join(base, installedInterceptorName), manifest, func(string) (string, error) { return "4.0.0", nil }); err == nil {
		t.Fatal("expected invalid manifest")
	}
}

func TestMalformedWarningIsPersistentRepairIssue(t *testing.T) {
	path := filepath.Join(t.TempDir(), componentMismatchWarningName)
	if err := os.WriteFile(path, []byte(`{"schema":"unknown"}`), 0600); err != nil {
		t.Fatal(err)
	}
	probe := componentHealthProbe{appVersion: "4.0.0", warningPath: path}
	issue := probe.probeMismatchWarning()
	if issue == nil || issue.Code != "diagnostic-invalid" || issue.Action != "repair-interceptor" {
		t.Fatalf("issue = %#v", issue)
	}
}

func writeJSONFixture(t *testing.T, path string, value any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
}
