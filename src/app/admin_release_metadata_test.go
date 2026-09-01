package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func adminTestKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

func adminTestRoot(t *testing.T, version int, rootPub, targetPub ed25519.PublicKey) adminReleaseRoot {
	t.Helper()
	return adminReleaseRoot{Schema: "go-mapi-admin-root-v1", Version: version, AllowedOrigin: "https://example.test/releases/", Root: adminReleaseKeyRole{Keys: map[string]string{"root": base64.RawURLEncoding.EncodeToString(rootPub)}, Threshold: 1}, Targets: adminReleaseKeyRole{Keys: map[string]string{"targets": base64.RawURLEncoding.EncodeToString(targetPub)}, Threshold: 1}}
}

func adminTestEnvelope(t *testing.T, payload any, id string, key ed25519.PrivateKey) []byte {
	t.Helper()
	signed, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	envelope := adminReleaseEnvelope{Schema: adminReleaseEnvelopeSchema, Signed: base64.RawURLEncoding.EncodeToString(signed), Signatures: []adminReleaseSignature{{KeyID: id, Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, signed))}}}
	data, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func adminTestPayload() adminReleasePayload {
	return adminReleasePayload{Schema: "go-mapi-admin-targets-v1", Component: "interceptor", Version: "4.0.1", QueueProtocol: "queue-v1", Requires: adminReleaseRequires{Component: "app", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}, Sequence: 7, IssuedAt: "2026-08-31T10:00:00Z", ExpiresAt: "2026-09-01T10:00:00Z", Artifact: adminReleaseArtifact{URL: "https://example.test/releases/admin-v4.0.1/go-mapi-interceptor.msi", Size: 42, SHA256: strings.Repeat("a", 64)}, Publisher: adminReleasePublisherPolicy{Publisher: "Example Publisher", EKUs: []string{"1.3.6.1.5.5.7.3.3", "1.2.3.4"}, PolicyID: "release"}}
}

func TestVerifyAdminReleaseAcceptsSignedCompatiblePayload(t *testing.T) {
	rootPub, rootKey := adminTestKey(t)
	targetPub, targetKey := adminTestKey(t)
	root := adminTestRoot(t, 1, rootPub, targetPub)
	got, err := verifyAdminRelease(root, adminTestEnvelope(t, adminTestPayload(), "targets", targetKey), "4.0.0", time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if got.Payload.Sequence != 7 || len(got.Digest) != 64 {
		t.Fatalf("unexpected authorized release: %#v", got)
	}
	_ = rootKey
}

func TestVerifyAdminReleaseRejectsAdversarialPayloads(t *testing.T) {
	rootPub, _ := adminTestKey(t)
	targetPub, targetKey := adminTestKey(t)
	root := adminTestRoot(t, 1, rootPub, targetPub)
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	for name, mutate := range map[string]func(*adminReleasePayload){
		"expired":               func(p *adminReleasePayload) { p.ExpiresAt = "2026-08-31T09:00:00Z" },
		"expiry boundary":       func(p *adminReleasePayload) { p.ExpiresAt = "2026-08-31T12:00:00Z" },
		"non UTC lifetime":      func(p *adminReleasePayload) { p.IssuedAt = "2026-08-31T12:00:00+02:00" },
		"incompatible range":    func(p *adminReleasePayload) { p.Requires.MinInclusive = "4.1.0" },
		"missing maximum range": func(p *adminReleasePayload) { p.Requires.MaxExclusive = "" },
		"inverted range":        func(p *adminReleasePayload) { p.Requires.MaxExclusive = "4.0.0" },
		"latest URL": func(p *adminReleasePayload) {
			p.Artifact.URL = "https://example.test/releases/latest/go-mapi-interceptor.msi"
		},
		"origin root URL": func(p *adminReleasePayload) {
			p.Artifact.URL = "https://example.test/releases/"
		},
		"unversioned MSI URL": func(p *adminReleasePayload) {
			p.Artifact.URL = "https://example.test/releases/go-mapi-interceptor.msi"
		},
		"wrong origin": func(p *adminReleasePayload) {
			p.Artifact.URL = "https://attacker.test/releases/admin-v4.0.1/go-mapi-interceptor.msi"
		},
		"invalid hash": func(p *adminReleasePayload) { p.Artifact.SHA256 = "nope" },
	} {
		t.Run(name, func(t *testing.T) {
			p := adminTestPayload()
			mutate(&p)
			if _, err := verifyAdminRelease(root, adminTestEnvelope(t, p, "targets", targetKey), "4.0.0", now); err == nil {
				t.Fatal("accepted invalid release")
			}
		})
	}
}

func TestVerifyAdminReleaseRejectsUnknownKeyAndTamper(t *testing.T) {
	rootPub, _ := adminTestKey(t)
	targetPub, targetKey := adminTestKey(t)
	root := adminTestRoot(t, 1, rootPub, targetPub)
	data := adminTestEnvelope(t, adminTestPayload(), "targets", targetKey)
	if _, err := verifyAdminRelease(root, data, "4.0.0", time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	var env adminReleaseEnvelope
	_ = json.Unmarshal(data, &env)
	env.Signatures[0].KeyID = "unknown"
	bad, _ := json.Marshal(env)
	if _, err := verifyAdminRelease(root, bad, "4.0.0", time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)); err == nil {
		t.Fatal("accepted unknown signing key")
	}
}

func TestVerifyAdminReleaseRootUpdateRequiresOldAndNewThreshold(t *testing.T) {
	oldPub, oldKey := adminTestKey(t)
	targetPub, _ := adminTestKey(t)
	current := adminTestRoot(t, 1, oldPub, targetPub)
	newPub, newKey := adminTestKey(t)
	incoming := adminTestRoot(t, 2, oldPub, targetPub)
	incoming.Root.Keys["new"] = base64.RawURLEncoding.EncodeToString(newPub)
	incoming.Root.Threshold = 2
	signed, _ := json.Marshal(incoming)
	env := adminReleaseEnvelope{Schema: adminReleaseEnvelopeSchema, Signed: base64.RawURLEncoding.EncodeToString(signed), Signatures: []adminReleaseSignature{{KeyID: "root", Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(oldKey, signed))}, {KeyID: "new", Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(newKey, signed))}}}
	data, _ := json.Marshal(env)
	if got, err := verifyAdminReleaseRootUpdate(current, data); err != nil || got.Version != 2 {
		t.Fatalf("rotation = %#v, %v", got, err)
	}
	env.Signatures = env.Signatures[:1]
	data, _ = json.Marshal(env)
	if _, err := verifyAdminReleaseRootUpdate(current, data); err == nil {
		t.Fatal("accepted rotation without incoming threshold")
	}
}

func TestAdminReleaseSequenceRejectsDowngradeAndChangedReplay(t *testing.T) {
	candidate := authorizedAdminRelease{Payload: adminReleasePayload{Sequence: 7}, Digest: strings.Repeat("a", 64)}
	if _, err := acceptAdminReleaseSequence(adminReleaseReplayState{Sequence: 8, Digest: strings.Repeat("b", 64)}, candidate); err == nil {
		t.Fatal("accepted downgrade")
	}
	if _, err := acceptAdminReleaseSequence(adminReleaseReplayState{Sequence: 7, Digest: strings.Repeat("b", 64)}, candidate); err == nil {
		t.Fatal("accepted changed same-sequence replay")
	}
	if got, err := acceptAdminReleaseSequence(adminReleaseReplayState{Sequence: 7, Digest: candidate.Digest}, candidate); err != nil || got.Sequence != 7 {
		t.Fatalf("idempotent replay = %#v, %v", got, err)
	}
}

func TestAdminReleaseRequiresCodeSigningEKU(t *testing.T) {
	rootPub, _ := adminTestKey(t)
	targetPub, targetKey := adminTestKey(t)
	root := adminTestRoot(t, 1, rootPub, targetPub)
	payload := adminTestPayload()
	payload.Publisher.EKUs = []string{"1.3.6.1.5.5.7.3.3"}
	if _, err := verifyAdminRelease(root, adminTestEnvelope(t, payload, "targets", targetKey), "4.0.0", time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)); err == nil {
		t.Fatal("accepted publisher policy without a distinct subscriber EKU")
	}
}
