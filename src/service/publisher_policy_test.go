package service

import (
	"encoding/base64"
	"errors"
	"testing"
)

func TestEmbeddedPublisherPolicyRejectsAbsentAndMalformedInput(t *testing.T) {
	previous := PublisherPolicyB64
	t.Cleanup(func() { PublisherPolicyB64 = previous })
	PublisherPolicyB64 = ""
	if _, err := EmbeddedPublisherPolicy(); !errors.Is(err, ErrPublisherPolicyUnavailable) {
		t.Fatalf("absent policy error = %v", err)
	}
	for _, raw := range []string{
		`{"publisher":"Azure Trusted Signing","ekus":["1.3.6.1.5.5.7.3.3"],"policyId":"release","extra":1}`,
		`{"publisher":"Azure Trusted Signing","ekus":["1.3.6.1.5.5.7.3.3"],"policyId":"release"} {}`,
		`{"publisher":"","ekus":[],"policyId":"release"}`,
	} {
		PublisherPolicyB64 = base64.StdEncoding.EncodeToString([]byte(raw))
		if _, err := EmbeddedPublisherPolicy(); err == nil {
			t.Fatalf("accepted invalid embedded policy %s", raw)
		}
	}
}

func TestEmbeddedPublisherPolicyAcceptsValidatedInput(t *testing.T) {
	previous := PublisherPolicyB64
	t.Cleanup(func() { PublisherPolicyB64 = previous })
	PublisherPolicyB64 = base64.StdEncoding.EncodeToString([]byte(`{"publisher":"Azure Trusted Signing","ekus":["1.3.6.1.5.5.7.3.3","1.3.6.1.4.1.311.84.1.1"],"policyId":"release"}`))
	policy, err := EmbeddedPublisherPolicy()
	if err != nil {
		t.Fatal(err)
	}
	if policy.Publisher != "Azure Trusted Signing" || policy.PolicyID != "release" {
		t.Fatalf("unexpected policy: %+v", policy)
	}
}
