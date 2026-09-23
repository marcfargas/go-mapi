package update

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestSignMachineTargetsRoundTripAndDeterminism(t *testing.T) {
	for _, sku := range []SKU{System, Suite} {
		t.Run(string(sku), func(t *testing.T) {
			_, key, policy := trustTestPolicy(t, sku)
			original := trustTestMachinePayload(sku, "4.0.1")
			spec := MachineTargetSpec{SKU: sku, PackageRelease: original.Version, Contained: original.Contained, Compatibility: original.Compatibility, Publisher: original.Publisher, IssuedAt: original.IssuedAt, ExpiresAt: original.ExpiresAt}
			body := []byte("verified machine installer")
			first, err := SignMachineTargets(policy.Root(), spec, bytes.NewReader(body), map[string]ed25519.PrivateKey{"targets": key}, trustTestNow)
			if err != nil {
				t.Fatal(err)
			}
			second, err := SignMachineTargets(policy.Root(), spec, bytes.NewReader(body), map[string]ed25519.PrivateKey{"targets": key}, trustTestNow)
			if err != nil || !bytes.Equal(first, second) {
				t.Fatalf("nondeterministic machine targets: %v", err)
			}
			installed := map[string]string{"service": "4.0.0", "interceptor": "4.0.0", "app": "4.0.0"}
			release, err := policy.Authorize(first, installed, trustTestNow)
			if err != nil {
				t.Fatal(err)
			}
			got := release.Payload()
			if got.ProductCode != original.ProductCode || got.UpgradeCode != original.UpgradeCode || got.Artifact.URL != original.Artifact.URL || got.Artifact.SHA256 != original.Artifact.SHA256 || got.Artifact.Size != original.Artifact.Size || got.Sequence != original.Sequence {
				t.Fatalf("generated identity/artifact mismatch: %+v", got)
			}
			if err := release.VerifyBytes(body); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSignMachineTargetsRejectsUntrustedOrIncompleteInputs(t *testing.T) {
	_, key, policy := trustTestPolicy(t, System)
	payload := trustTestMachinePayload(System, "4.0.1")
	spec := MachineTargetSpec{SKU: System, PackageRelease: payload.Version, Contained: payload.Contained, Compatibility: payload.Compatibility, Publisher: payload.Publisher, IssuedAt: payload.IssuedAt, ExpiresAt: payload.ExpiresAt}
	goodKeys := map[string]ed25519.PrivateKey{"targets": key}
	for name, mutate := range map[string]func(*Root, *MachineTargetSpec, *map[string]ed25519.PrivateKey){
		"foreign origin": func(root *Root, _ *MachineTargetSpec, _ *map[string]ed25519.PrivateKey) {
			root.AllowedOrigin = "https://example.com/releases/download/"
		},
		"wrong SKU": func(_ *Root, spec *MachineTargetSpec, _ *map[string]ed25519.PrivateKey) { spec.SKU = LegacyAdmin },
		"missing contained app": func(_ *Root, spec *MachineTargetSpec, _ *map[string]ed25519.PrivateKey) {
			spec.Contained = spec.Contained[:1]
		},
		"bad compatibility": func(_ *Root, spec *MachineTargetSpec, _ *map[string]ed25519.PrivateKey) {
			spec.Compatibility[0].MaxExclusive = "4.0.0"
		},
		"expired": func(_ *Root, spec *MachineTargetSpec, _ *map[string]ed25519.PrivateKey) {
			spec.ExpiresAt = trustTestNow.Add(-time.Second).Format(time.RFC3339)
		},
		"wrong key": func(_ *Root, _ *MachineTargetSpec, keys *map[string]ed25519.PrivateKey) {
			_, private, _ := ed25519.GenerateKey(rand.Reader)
			*keys = map[string]ed25519.PrivateKey{"targets": private}
		},
		"unknown key": func(_ *Root, _ *MachineTargetSpec, keys *map[string]ed25519.PrivateKey) {
			*keys = map[string]ed25519.PrivateKey{"other": key}
		},
		"no key": func(_ *Root, _ *MachineTargetSpec, keys *map[string]ed25519.PrivateKey) { *keys = nil },
	} {
		t.Run(name, func(t *testing.T) {
			root := policy.Root()
			candidate := spec
			candidate.Contained = append([]ContainedComponent(nil), spec.Contained...)
			candidate.Compatibility = append([]Requirement(nil), spec.Compatibility...)
			keys := goodKeys
			mutate(&root, &candidate, &keys)
			if _, err := SignMachineTargets(root, candidate, strings.NewReader("verified machine installer"), keys, trustTestNow); err == nil {
				t.Fatal("accepted invalid machine target input")
			}
		})
	}
	if _, err := SignMachineTargets(policy.Root(), spec, strings.NewReader(""), goodKeys, trustTestNow); err == nil {
		t.Fatal("accepted empty MSI")
	}
}

func TestMachinePolicyRejectsForgedProductCodeEvenWithValidSignature(t *testing.T) {
	_, key, policy := trustTestPolicy(t, System)
	payload := trustTestMachinePayload(System, "4.0.1")
	payload.ProductCode = "00000000-0000-0000-0000-000000000000"
	if _, err := policy.Authorize(trustTestEnvelope(t, payload, key), map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}, trustTestNow); err == nil {
		t.Fatal("accepted forged ProductCode")
	}
	payload.ProductCode = ""
	if _, err := policy.Authorize(trustTestEnvelope(t, payload, key), map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}, trustTestNow); err == nil {
		t.Fatal("accepted missing ProductCode")
	}
}

func TestSignMachineTargetsMeetsTwoKeyThreshold(t *testing.T) {
	_, first, policy := trustTestPolicy(t, System)
	public, second, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	root := policy.Root()
	root.Targets.Keys["second"] = base64.RawURLEncoding.EncodeToString(public)
	root.Targets.Threshold = 2
	payload := trustTestMachinePayload(System, "4.0.1")
	spec := MachineTargetSpec{SKU: System, PackageRelease: payload.Version, Contained: payload.Contained, Compatibility: payload.Compatibility, Publisher: payload.Publisher, IssuedAt: payload.IssuedAt, ExpiresAt: payload.ExpiresAt}
	if _, err := SignMachineTargets(root, spec, strings.NewReader("verified machine installer"), map[string]ed25519.PrivateKey{"targets": first}, trustTestNow); err == nil {
		t.Fatal("accepted one signer for two-key threshold")
	}
	data, err := SignMachineTargets(root, spec, strings.NewReader("verified machine installer"), map[string]ed25519.PrivateKey{"targets": first, "second": second}, trustTestNow)
	if err != nil {
		t.Fatal(err)
	}
	var envelope Envelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		t.Fatal(err)
	}
	if len(envelope.Signatures) != 2 || envelope.Signatures[0].KeyID != "second" || envelope.Signatures[1].KeyID != "targets" {
		t.Fatalf("noncanonical signer order: %+v", envelope.Signatures)
	}
}
