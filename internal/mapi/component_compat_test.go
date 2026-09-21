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

func TestReleaseTrack(t *testing.T) {
	tests := map[string]string{
		"3.0.0":                  "stable",
		"3.1.0-alpha.1":          "development",
		"3.1.0-beta.2":           "development",
		"3.1.0-nightly.20260921": "development",
		"4.1.0":                  "stable",
		"4.1.0+build.1":          "stable",
		"3.1.0":                  "",
		"4.1.0-beta.1":           "",
		"3.0.1-beta.1":           "",
		"5.1.0-rc.1":             "",
		"0.0.0-dev":              "",
		"not-semver":             "",
	}
	for version, want := range tests {
		t.Run(version, func(t *testing.T) {
			if got := ReleaseTrack(version); got != want {
				t.Fatalf("ReleaseTrack(%q) = %q, want %q", version, got, want)
			}
		})
	}
}
