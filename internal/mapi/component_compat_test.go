package mapi

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestCompatibilityFixtures(t *testing.T) {
	var fixtures struct {
		Schema string `json:"schema"`
		Cases  []struct {
			Name, Installed, MinInclusive, MaxExclusive string
			Status                                      CompatibilityStatus `json:"status"`
		} `json:"cases"`
	}
	data, err := os.ReadFile(filepath.Join("..", "..", "tests", "component-compatibility", "compatibility-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &fixtures); err != nil {
		t.Fatal(err)
	}
	if fixtures.Schema != "go-mapi-component-compatibility-fixtures-v1" {
		t.Fatalf("schema = %q", fixtures.Schema)
	}
	for _, fixture := range fixtures.Cases {
		t.Run(fixture.Name, func(t *testing.T) {
			got := EvaluateCompatibility(fixture.Installed, CounterpartRequirement{
				Component: "app", MinInclusive: fixture.MinInclusive, MaxExclusive: fixture.MaxExclusive,
			}, "update-app")
			if got.Status != fixture.Status {
				t.Fatalf("status = %q, want %q", got.Status, fixture.Status)
			}
		})
	}
}

func TestStrictReleaseVersion(t *testing.T) {
	for _, valid := range []string{"4.0.0", "4.0.0-rc.2", "4.0.0+build.1"} {
		if !IsStrictReleaseVersion(valid) {
			t.Errorf("%q should be valid", valid)
		}
	}
	for _, invalid := range []string{"", "v4.0.0", "4.0", "04.0.0", "0.0.0-dev"} {
		if IsStrictReleaseVersion(invalid) {
			t.Errorf("%q should be invalid", invalid)
		}
	}
}
