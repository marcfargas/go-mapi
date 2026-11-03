package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func TestReplayDigestOutputUsesValidatedReleaseIdentity(t *testing.T) {
	now := time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)
	for _, sku := range []update.SKU{update.System, update.Suite} {
		t.Run(string(sku), func(t *testing.T) {
			root := t.TempDir()
			spec := update.MachineTargetSpec{SKU: sku, PackageRelease: "4.0.2", IssuedAt: now.Add(-time.Hour).Format(time.RFC3339), ExpiresAt: now.Add(time.Hour).Format(time.RFC3339)}
			installed := map[string]string{"service": "4.0.1", "interceptor": "4.0.1"}
			if sku == update.Suite {
				installed["app"] = "4.0.1"
			}
			for _, name := range []string{"service", "interceptor", "app"} {
				if version, ok := installed[name]; ok {
					spec.Contained = append(spec.Contained, update.ContainedComponent{Component: name, Version: version})
					spec.Compatibility = append(spec.Compatibility, update.Requirement{Component: name, MinInclusive: "4.0.0", MaxExclusive: "5.0.0"})
				}
			}
			var original string
			for _, mode := range []string{"initial", "refresh", "changed", "expired"} {
				caseRoot := filepath.Join(root, mode)
				if err := os.Mkdir(caseRoot, 0700); err != nil {
					t.Fatal(err)
				}
				body := "fixture MSI bytes"
				if mode == "refresh" {
					spec.ExpiresAt = now.Add(2 * time.Hour).Format(time.RFC3339)
				} else if mode == "changed" {
					body = "different MSI bytes"
				} else if mode == "expired" {
					spec.ExpiresAt = now.Add(-time.Minute).Format(time.RFC3339)
				}
				specPath, msiPath := filepath.Join(caseRoot, "spec.json"), filepath.Join(caseRoot, "fixture.msi")
				targetPath, digestPath := filepath.Join(caseRoot, "target.json"), filepath.Join(caseRoot, "digest.txt")
				encoded, _ := json.Marshal(spec)
				for path, content := range map[string][]byte{specPath: encoded, msiPath: []byte(body)} {
					if err := os.WriteFile(path, content, 0600); err != nil {
						t.Fatal(err)
					}
				}
				args := []string{"--spec", specPath, "--msi", msiPath, "--out", targetPath, "--replay-digest-out", digestPath}
				err := run(args, now)
				if mode == "expired" {
					if _, statErr := os.Stat(digestPath); err == nil || !os.IsNotExist(statErr) {
						t.Fatal("expired target emitted a replay digest")
					}
					continue
				}
				if err != nil {
					t.Fatal(err)
				}
				raw, err := os.ReadFile(targetPath)
				if err != nil {
					t.Fatal(err)
				}
				release, err := update.ParseTarget(sku, raw, installed, now, update.MachineArtifactOrigin)
				if err != nil {
					t.Fatal(err)
				}
				digest, err := os.ReadFile(digestPath)
				sum := sha256.Sum256(raw)
				if err != nil || string(digest) != release.Digest() || string(digest) == hex.EncodeToString(sum[:]) {
					t.Fatalf("%s: producer digest differs from replay identity: %s, %v", mode, digest, err)
				}
				if mode == "initial" {
					original = string(digest)
				} else if (string(digest) == original) != (mode == "refresh") {
					t.Fatalf("%s: incorrect immutable identity", mode)
				}
				if err := run(args, now); err == nil {
					t.Fatal("overwrote existing target outputs")
				}
			}
		})
	}
}
