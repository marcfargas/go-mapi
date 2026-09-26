package mapi

import (
	"encoding/json"
	"testing"
	"time"
)

func TestPublicStatusV2OnlySuppressesWithCurrentAutomaticCapability(t *testing.T) {
	now := time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)
	s := PublicStatusV2{Schema: PublicStatusSchemaV2, SKU: "system", PackageVersion: "4.0.1", ServiceVersion: "4.0.1", InterceptorVersion: "4.0.1", Health: "healthy", Updates: "enabled", Code: "pending", Capability: "automatic", Checker: "no-update", LastAttemptAt: now.Add(-time.Hour), LastSuccessAt: now.Add(-time.Hour), NextAttemptAt: now.Add(5 * time.Hour), CandidateExpiresAt: now.Add(time.Hour), HealthObservedAt: now.Add(-time.Hour), UpdatedAt: now}
	id := InstalledStatusIdentity{SKU: "system", PackageVersion: "4.0.1", InterceptorVersion: "4.0.1"}
	if !ManagedSystemUpdateEffective(s, id, true, now) {
		t.Fatal("valid automatic status did not suppress")
	}
	for name, mutate := range map[string]func(*PublicStatusV2){
		"discovery only":          func(v *PublicStatusV2) { v.Capability = "discovery" },
		"disabled":                func(v *PublicStatusV2) { v.Updates = "disabled" },
		"unhealthy":               func(v *PublicStatusV2) { v.Health = "repair-required" },
		"reboot pending":          func(v *PublicStatusV2) { v.Code = "reboot-pending" },
		"stale publication":       func(v *PublicStatusV2) { v.UpdatedAt = now.Add(-6 * time.Minute) },
		"future publication":      func(v *PublicStatusV2) { v.UpdatedAt = now.Add(2 * time.Minute) },
		"stale health":            func(v *PublicStatusV2) { v.HealthObservedAt = now.Add(-7 * time.Hour) },
		"stale check":             func(v *PublicStatusV2) { v.LastSuccessAt = now.Add(-7 * time.Hour) },
		"late retry":              func(v *PublicStatusV2) { v.NextAttemptAt = now.Add(-6 * time.Minute) },
		"expired signed metadata": func(v *PublicStatusV2) { v.CandidateExpiresAt = now.Add(-time.Second) },
	} {
		t.Run(name, func(t *testing.T) {
			candidate := s
			mutate(&candidate)
			if ManagedSystemUpdateEffective(candidate, id, true, now) {
				t.Fatal("unsafe status suppressed system notice")
			}
		})
	}
	if ManagedSystemUpdateEffective(s, id, false, now) || ManagedSystemUpdateEffective(s, InstalledStatusIdentity{SKU: "suite", PackageVersion: "4.0.1", InterceptorVersion: "4.0.1"}, true, now) {
		t.Fatal("untrusted service or installed identity suppressed")
	}
}

func TestPublicStatusV2DecoderRequiresFieldsAndRejectsUnknown(t *testing.T) {
	now := time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)
	s := PublicStatusV2{Schema: PublicStatusSchemaV2, SKU: "system", Updates: "disabled", Code: "pending", Capability: "unavailable", Checker: "disabled", UpdatedAt: now}
	data, _ := json.Marshal(s)
	if _, err := DecodePublicStatusV2(data); err != nil {
		t.Fatal(err)
	}
	for _, raw := range [][]byte{[]byte(`{"schema":"go-mapi-public-status-v2","sku":"system","updates":"disabled","code":"pending","checker":"disabled","updatedAt":"2026-09-24T12:00:00Z"}`), []byte(`{"schema":"go-mapi-public-status-v1","sku":"system","updates":"disabled","code":"pending","capability":"unavailable","checker":"disabled","updatedAt":"2026-09-24T12:00:00Z"}`), append(append([]byte{}, data[:len(data)-1]...), []byte(`,"path":"C:\\secret"}`)...)} {
		if _, err := DecodePublicStatusV2(raw); err == nil {
			t.Fatalf("accepted invalid status %s", raw)
		}
	}
}
