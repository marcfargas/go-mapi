package update

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

var trustTestNow = time.Date(2026, 9, 22, 12, 0, 0, 0, time.UTC)

func TestMachinePoliciesKeepSystemAndSuiteNamespacesIsolated(t *testing.T) {
	_, systemKey, systemPolicy := trustTestPolicy(t, System)
	_, suiteKey, suitePolicy := trustTestPolicy(t, Suite)
	system := trustTestMachinePayload(System, "4.0.1")

	release, err := systemPolicy.Authorize(trustTestEnvelope(t, system, systemKey), map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}, trustTestNow)
	if err != nil {
		t.Fatal(err)
	}
	if release.Namespace() != "system" {
		t.Fatalf("namespace = %q, want system", release.Namespace())
	}
	if _, err := suitePolicy.Authorize(trustTestEnvelope(t, system, suiteKey), map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}, trustTestNow); err == nil {
		t.Fatal("suite policy accepted a system target")
	}
	if _, err := suitePolicy.Accept(ReplayState{Namespace: "suite", Sequence: 1, Digest: strings.Repeat("a", 64)}, release); err == nil {
		t.Fatal("suite replay namespace accepted a system release")
	}
}

func TestMachinePolicyRejectsAmbiguousAndCrossSKUFields(t *testing.T) {
	_, key, policy := trustTestPolicy(t, System)
	for name, mutate := range map[string]func(*Payload){
		"suite asset": func(payload *Payload) {
			payload.Artifact.URL = "https://github.com/marcfargas/go-mapi/releases/download/suite-v4.0.1/go-mapi-suite-4.0.1-x64.msi"
		},
		"legacy identity": func(payload *Payload) {
			payload.Component = "interceptor"
			payload.Requires = Requirement{Component: "app", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}
		},
		"missing contained compatibility": func(payload *Payload) {
			payload.Compatibility = payload.Compatibility[:1]
		},
	} {
		t.Run(name, func(t *testing.T) {
			payload := trustTestMachinePayload(System, "4.0.1")
			mutate(&payload)
			if _, err := policy.Authorize(trustTestEnvelope(t, payload, key), map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}, trustTestNow); err == nil {
				t.Fatal("accepted ambiguous or cross-SKU target")
			}
		})
	}
}

func TestPolicyRejectsExpiredDowngradedAndSubstitutedReleases(t *testing.T) {
	_, key, policy := trustTestPolicy(t, System)
	payload := trustTestMachinePayload(System, "4.0.1")
	payload.ExpiresAt = trustTestNow.Format(time.RFC3339)
	if _, err := policy.Authorize(trustTestEnvelope(t, payload, key), map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}, trustTestNow); err == nil {
		t.Fatal("accepted metadata at its expiry boundary")
	}

	payload = trustTestMachinePayload(System, "4.0.1")
	release, err := policy.Authorize(trustTestEnvelope(t, payload, key), map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}, trustTestNow)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := policy.Accept(ReplayState{Namespace: "system", Sequence: release.Sequence() + 1, Digest: strings.Repeat("b", 64)}, release); err == nil {
		t.Fatal("accepted sequence downgrade")
	}
	replayedPayload := payload
	replayedPayload.IssuedAt = trustTestNow.Add(-30 * time.Minute).Format(time.RFC3339)
	replayed, err := policy.Authorize(trustTestEnvelope(t, replayedPayload, key), map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}, trustTestNow)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := policy.Accept(ReplayState{Namespace: "system", Sequence: release.Sequence(), Digest: release.Digest()}, replayed); err == nil {
		t.Fatal("accepted changed payload at the same sequence")
	}
	if err := release.VerifyBytes([]byte("substituted MSI")); err == nil {
		t.Fatal("accepted substituted artifact bytes")
	}
	if err := release.VerifyReader(strings.NewReader("substituted MSI")); err == nil {
		t.Fatal("accepted substituted artifact after re-open")
	}
	if err := release.VerifyReader(strings.NewReader("verified machine installer")); err != nil {
		t.Fatalf("re-open/re-hash rejected authorized bytes: %v", err)
	}
}

func TestDownloadRejectsCrossOriginRedirectAndRehashesResponse(t *testing.T) {
	_, key, policy := trustTestPolicy(t, System)
	payload := trustTestMachinePayload(System, "4.0.1")
	release, err := policy.Authorize(trustTestEnvelope(t, payload, key), map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}, trustTestNow)
	if err != nil {
		t.Fatal(err)
	}

	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		redirect := *request
		redirect.URL, _ = request.URL.Parse("https://attacker.test/replacement.msi")
		return &http.Response{StatusCode: http.StatusFound, Header: http.Header{"Location": []string{redirect.URL.String()}}, Body: io.NopCloser(strings.NewReader("")), Request: request}, nil
	})}
	if _, err := policy.Download(context.Background(), client, release, trustTestNow); err == nil {
		t.Fatal("followed a cross-origin redirect")
	}

	body := []byte("verified machine installer")
	payload.Artifact.Size = int64(len(body))
	sum := sha256.Sum256(body)
	payload.Artifact.SHA256 = hex.EncodeToString(sum[:])
	release, err = policy.Authorize(trustTestEnvelope(t, payload, key), map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}, trustTestNow)
	if err != nil {
		t.Fatal(err)
	}
	client = &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), ContentLength: int64(len(body)), Body: io.NopCloser(strings.NewReader(string(body))), Request: request}, nil
	})}
	got, err := policy.Download(context.Background(), client, release, trustTestNow)
	if err != nil || string(got) != string(body) {
		t.Fatalf("download = %q, %v", got, err)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) { return f(request) }

func trustTestPolicy(t *testing.T, sku SKU) (ed25519.PublicKey, ed25519.PrivateKey, Policy) {
	t.Helper()
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	root := Root{Schema: MachineRootSchema, Version: 1, AllowedOrigin: "https://github.com/marcfargas/go-mapi/releases/download/", Root: KeyRole{Keys: map[string]string{"root": base64.RawURLEncoding.EncodeToString(pub)}, Threshold: 1}, Targets: KeyRole{Keys: map[string]string{"targets": base64.RawURLEncoding.EncodeToString(pub)}, Threshold: 1}}
	policy, err := NewMachinePolicy(sku, root)
	if err != nil {
		t.Fatal(err)
	}
	return pub, key, policy
}

func trustTestMachinePayload(sku SKU, release string) Payload {
	body := []byte("verified machine installer")
	sum := sha256.Sum256(body)
	upgradeCode := "B3C97B33-3F10-47CA-9FA7-24EE3B75E325"
	if sku == Suite {
		upgradeCode = "2E050A24-94A2-4FC9-B176-C5CCC1225FE6"
	}
	contained := []ContainedComponent{{Component: "service", Version: "4.0.1"}, {Component: "interceptor", Version: "4.0.1"}}
	compatibility := []Requirement{{Component: "service", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}, {Component: "interceptor", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}}
	if sku == Suite {
		contained = append(contained, ContainedComponent{Component: "app", Version: "4.0.1"})
		compatibility = append(compatibility, Requirement{Component: "app", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"})
	}
	return Payload{
		Schema: MachineTargetsSchema, SKU: sku, ProductCode: mustMachineProductCode(sku, release), UpgradeCode: upgradeCode, Version: release, QueueProtocol: "queue-v1", Sequence: 4<<24 | 1,
		IssuedAt: trustTestNow.Add(-time.Hour).Format(time.RFC3339), ExpiresAt: trustTestNow.Add(time.Hour).Format(time.RFC3339),
		Contained:     contained,
		Compatibility: compatibility,
		Artifact:      Artifact{URL: "https://github.com/marcfargas/go-mapi/releases/download/" + string(sku) + "-v" + release + "/go-mapi-" + string(sku) + "-" + release + "-x64.msi", Size: int64(len(body)), SHA256: hex.EncodeToString(sum[:])},
		Publisher:     PublisherPolicy{Publisher: "Example Publisher", EKUs: []string{"1.3.6.1.5.5.7.3.3", "1.2.3.4"}, PolicyID: "release"},
	}
}

func mustMachineProductCode(sku SKU, release string) string {
	identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(sku), release)
	if err != nil {
		panic(err)
	}
	return identity.ProductCode
}

func trustTestEnvelope(t *testing.T, payload Payload, key ed25519.PrivateKey) []byte {
	t.Helper()
	signed, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	envelope := Envelope{Schema: EnvelopeSchema, Signed: base64.RawURLEncoding.EncodeToString(signed), Signatures: []Signature{{KeyID: "targets", Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, signed))}}}
	data, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
