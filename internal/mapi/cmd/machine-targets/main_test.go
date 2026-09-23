package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func TestRunSignsFinalMSIWithoutReplacingExistingTargets(t *testing.T) {
	now := time.Date(2026, 9, 23, 10, 0, 0, 0, time.UTC)
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	root := update.Root{Schema: update.MachineRootSchema, Version: 1, AllowedOrigin: update.MachineArtifactOrigin, Root: update.KeyRole{Keys: map[string]string{"root": base64.RawURLEncoding.EncodeToString(public)}, Threshold: 1}, Targets: update.KeyRole{Keys: map[string]string{"targets": base64.RawURLEncoding.EncodeToString(public)}, Threshold: 1}}
	spec := update.MachineTargetSpec{SKU: update.System, PackageRelease: "4.0.1", Contained: []update.ContainedComponent{{Component: "service", Version: "4.0.1"}, {Component: "interceptor", Version: "4.0.1"}}, Compatibility: []update.Requirement{{Component: "service", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}, {Component: "interceptor", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}}, Publisher: update.PublisherPolicy{Publisher: "Example Publisher", EKUs: []string{"1.3.6.1.5.5.7.3.3", "1.2.3.4"}, PolicyID: "release"}, IssuedAt: now.Add(-time.Hour).Format(time.RFC3339), ExpiresAt: now.Add(time.Hour).Format(time.RFC3339)}
	der, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	write := func(name string, data []byte) string {
		t.Helper()
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	rootJSON, _ := json.Marshal(root)
	specJSON, _ := json.Marshal(spec)
	rootPath := write("root.json", rootJSON)
	specPath := write("spec.json", specJSON)
	msiPath := write("final.msi", []byte("final signed MSI bytes"))
	keyPath := write("key.pem", pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	outPath := filepath.Join(dir, "targets.json")
	args := []string{"--root", rootPath, "--spec", specPath, "--msi", msiPath, "--key-pem", keyPath, "--key-id", "targets", "--out", outPath}
	if err := run(args, now); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatal(err)
	}
	policy, err := update.NewMachinePolicy(update.System, root)
	if err != nil {
		t.Fatal(err)
	}
	release, err := policy.Authorize(data, map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}, now)
	if err != nil {
		t.Fatal(err)
	}
	if err := release.VerifyBytes([]byte("final signed MSI bytes")); err != nil {
		t.Fatal(err)
	}
	if err := run(args, now); err == nil || !strings.Contains(err.Error(), "create new targets envelope") {
		t.Fatalf("allowed replacement of immutable output: %v", err)
	}
	unchanged, err := os.ReadFile(outPath)
	if err != nil || string(data) != string(unchanged) {
		t.Fatal("existing target envelope changed")
	}
}
