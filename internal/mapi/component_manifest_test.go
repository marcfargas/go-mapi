package mapi

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type componentManifest struct {
	SchemaVersion int `json:"schemaVersion"`
	Components    map[string]struct {
		VersionFile   string                 `json:"versionFile"`
		Artifact      string                 `json:"artifact"`
		Architectures []string               `json:"architectures"`
		QueueProtocol string                 `json:"queueProtocol"`
		Scope         string                 `json:"scope"`
		Requires      CounterpartRequirement `json:"requires"`
	} `json:"components"`
}

func TestComponentManifestMatchesCheckedInVersionInputs(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	data, err := os.ReadFile(filepath.Join(repoRoot, "components.json"))
	if err != nil {
		t.Fatalf("read components manifest: %v", err)
	}

	var manifest componentManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatalf("parse components manifest: %v", err)
	}
	if manifest.SchemaVersion != 2 {
		t.Fatalf("schemaVersion = %d, want 2", manifest.SchemaVersion)
	}

	for name, wantScope := range map[string]string{"app": "per-user", "interceptor": "machine-wide"} {
		component, ok := manifest.Components[name]
		if !ok {
			t.Fatalf("missing %q component", name)
		}
		if component.Scope != wantScope {
			t.Errorf("%s scope = %q, want %q", name, component.Scope, wantScope)
		}
		if component.QueueProtocol != "queue-v1" {
			t.Errorf("%s queueProtocol = %q, want queue-v1", name, component.QueueProtocol)
		}
		if component.Artifact == "" {
			t.Errorf("%s artifact is empty", name)
		}
		if len(component.Architectures) == 0 {
			t.Errorf("%s declares no architectures", name)
		}
		wantCounterpart := "app"
		if name == "app" {
			wantCounterpart = "interceptor"
		}
		if component.Requires.Component != wantCounterpart || !IsStrictReleaseVersion(component.Requires.MinInclusive) {
			t.Errorf("%s requires = %#v, want strict %s requirement", name, component.Requires, wantCounterpart)
		}
		version, err := os.ReadFile(filepath.Join(repoRoot, component.VersionFile))
		if err != nil {
			t.Errorf("read %s version input: %v", name, err)
			continue
		}
		if strings.TrimSpace(string(version)) == "" {
			t.Errorf("%s version input is empty", name)
		}
	}
	if got := manifest.Components["interceptor"].Architectures; len(got) != 2 || got[0] != "x86" || got[1] != "x64" {
		t.Errorf("interceptor architectures = %v, want [x86 x64]", got)
	}
	app := manifest.Components["app"]
	if app.Artifact != "go-mapi.exe" || len(app.Architectures) != 1 || app.Architectures[0] != "amd64" {
		t.Errorf("app artifact contract = %#v, want go-mapi.exe/amd64", app)
	}
}
