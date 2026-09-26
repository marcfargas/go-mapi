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
	MachinePackages map[string]struct {
		UpgradeCode          string   `json:"upgradeCode"`
		ProductCodeNamespace string   `json:"productCodeNamespace"`
		ProductCodeName      string   `json:"productCodeName"`
		TagPrefix            string   `json:"tagPrefix"`
		TargetPath           string   `json:"targetPath"`
		AssetPattern         string   `json:"assetPattern"`
		ManifestPattern      string   `json:"manifestPattern"`
		IncludedComponents   []string `json:"includedComponents"`
		ReleaseCadence       string   `json:"releaseCadence"`
		Service              struct {
			Name        string `json:"name"`
			DisplayName string `json:"displayName"`
			Executable  string `json:"executable"`
			Arguments   string `json:"arguments"`
		} `json:"service"`
	} `json:"machinePackages"`
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

func TestComponentManifestDeclaresDistinctMachinePackageFamilies(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	data, err := os.ReadFile(filepath.Join(repoRoot, "components.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest componentManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}

	system, systemOK := manifest.MachinePackages["system"]
	suite, suiteOK := manifest.MachinePackages["suite"]
	if !systemOK || !suiteOK || len(manifest.MachinePackages) != 2 {
		t.Fatalf("machinePackages keys = %v, want exactly system and suite", manifest.MachinePackages)
	}
	if system.UpgradeCode != "B3C97B33-3F10-47CA-9FA7-24EE3B75E325" {
		t.Errorf("system UpgradeCode = %q", system.UpgradeCode)
	}
	if suite.UpgradeCode != "2E050A24-94A2-4FC9-B176-C5CCC1225FE6" {
		t.Errorf("suite UpgradeCode = %q", suite.UpgradeCode)
	}
	if system.UpgradeCode == suite.UpgradeCode || system.TargetPath == suite.TargetPath || system.TagPrefix == suite.TagPrefix {
		t.Error("system and suite package namespaces must be distinct")
	}
	for sku, contract := range manifest.MachinePackages {
		if contract.ProductCodeNamespace != machineProductCodeNamespace || contract.ProductCodeName != "go-mapi/msi/<sku>/<package-release>" {
			t.Errorf("%s ProductCode contract = %q/%q", sku, contract.ProductCodeNamespace, contract.ProductCodeName)
		}
		if contract.Service.Name != "go-mapi" || contract.Service.DisplayName != "go-mapi system service" || contract.Service.Executable != `%ProgramFiles%\go-mapi\service\go-mapi-service.exe` || contract.Service.Arguments != "service" {
			t.Errorf("%s service identity = %#v", sku, contract.Service)
		}
		if contract.AssetPattern != "go-mapi-<sku>-<package-release>-x64.msi" || contract.ManifestPattern != "go-mapi-<sku>-<package-release>.manifest.json" {
			t.Errorf("%s publication patterns = %q/%q", sku, contract.AssetPattern, contract.ManifestPattern)
		}
	}
	if strings.Join(system.IncludedComponents, ",") != "service,interceptor" {
		t.Errorf("system components = %v", system.IncludedComponents)
	}
	if strings.Join(suite.IncludedComponents, ",") != "service,interceptor,app" {
		t.Errorf("suite components = %v", suite.IncludedComponents)
	}
}
