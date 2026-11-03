package update

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

func TestSystemBootstrapValidatesActualAppAndImmutableCandidate(t *testing.T) {
	now := time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)
	raw, body := fixture(t, System, now)
	var payload Payload
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatal(err)
	}
	payload.Requires = Requirement{Component: "app", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}
	raw, _ = json.Marshal(payload)
	request := BootstrapRequest{AppVersion: "4.0.1", Track: "stable", RequiredInterceptor: mapi.CounterpartRequirement{Component: "interceptor", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}}
	for _, tc := range []struct {
		name    string
		sku     SKU
		mutate  func(*Payload, *BootstrapRequest)
		wantErr bool
	}{
		{name: "valid", sku: System},
		{name: "Suite engine", sku: Suite, wantErr: true},
		{name: "missing App range", sku: System, wantErr: true, mutate: func(p *Payload, _ *BootstrapRequest) { p.Requires = Requirement{} }},
		{name: "incompatible App", sku: System, wantErr: true, mutate: func(_ *Payload, r *BootstrapRequest) { r.AppVersion = "6.0.0" }},
		{name: "incompatible interceptor", sku: System, wantErr: true, mutate: func(_ *Payload, r *BootstrapRequest) {
			r.RequiredInterceptor.MinInclusive = "6.0.0"
			r.RequiredInterceptor.MaxExclusive = "7.0.0"
		}},
		{name: "track", sku: System, wantErr: true, mutate: func(_ *Payload, r *BootstrapRequest) { r.Track = "development" }},
		{name: "expired", sku: System, wantErr: true, mutate: func(p *Payload, _ *BootstrapRequest) { p.ExpiresAt = now.Add(-time.Minute).Format(time.RFC3339) }},
		{name: "old SKU URL", sku: System, wantErr: true, mutate: func(p *Payload, _ *BootstrapRequest) {
			p.Artifact.URL = MachineArtifactOrigin + "system-v4.0.2/go-mapi-system-4.0.2-x64.msi"
		}},
		{name: "replay", sku: System, wantErr: true, mutate: func(_ *Payload, r *BootstrapRequest) {
			r.Accepted = ReplayState{Namespace: "system", Sequence: 1 << 40, Digest: "old"}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p, req := payload, request
			if tc.mutate != nil {
				tc.mutate(&p, &req)
			}
			metadata, _ := json.Marshal(p)
			fetches := 0
			engine, err := NewEngine(Config{SKU: tc.sku, MetadataOrigin: "https://go-mapi.app", Client: &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
				fetches++
				if r.URL.Path == "/machine/system/targets.json" {
					if r.Header.Get("X-Go-Mapi-Installed-Version") != "" {
						t.Fatal("bootstrap invented installed version")
					}
					if r.Header.Get("X-Go-Mapi-Release-Track") != "stable" {
						t.Fatal("bootstrap did not request its App release track")
					}
					return response(r, metadata), nil
				}
				return response(r, body), nil
			})}, Now: func() time.Time { return now }})
			if err != nil {
				t.Fatal(err)
			}
			result, err := engine.Bootstrap(context.Background(), req)
			if tc.wantErr {
				if err == nil || result.Available {
					t.Fatal("invalid bootstrap accepted")
				}
				return
			}
			if err != nil || !result.Available || result.Accepted.Namespace != "system" {
				t.Fatalf("%+v %v", result, err)
			}
			_, err = engine.Install(context.Background(), result.Candidate, InstallOptions{Stage: stageIn(t), Verify: func(context.Context, string) error { return nil }, Handoff: func(_ context.Context, p Prepared) error { p.Cleanup(); return nil }})
			if err != nil || fetches != 2 {
				t.Fatalf("fetches=%d err=%v", fetches, err)
			}
		})
	}
	// Refreshing or transferring a candidate never bypasses expiry or ownership.
	engine, _ := NewEngine(Config{SKU: System, MetadataOrigin: "https://go-mapi.app", Client: &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) { return response(r, raw), nil })}, Now: func() time.Time { return now }})
	result, err := engine.Bootstrap(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(2 * time.Hour)
	if _, err := engine.Prepare(context.Background(), result.Candidate, InstallOptions{Stage: stageIn(t), Verify: func(context.Context, string) error { return nil }}); err == nil {
		t.Fatal("expired bootstrap prepared")
	}
}

func TestSameVersionRepairIsExplicitAndOrdinaryAbsenceRefuses(t *testing.T) {
	now := time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)
	raw, _ := fixture(t, System, now)
	engine, _ := NewEngine(Config{SKU: System, MetadataOrigin: "https://go-mapi.app", Client: &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) { return response(r, raw), nil })}, Now: func() time.Time { return now }})
	r := checkRequest(System)
	r.InstalledVersion = "4.0.2"
	result, err := engine.Check(context.Background(), r)
	if err != nil || result.Available {
		t.Fatalf("ordinary same version: %+v %v", result, err)
	}
	r.AllowSameVersion = true
	result, err = engine.Check(context.Background(), r)
	if err != nil || !result.Available {
		t.Fatalf("explicit repair: %+v %v", result, err)
	}
	r.InstalledVersion = "absent"
	if _, err := engine.Check(context.Background(), r); err == nil {
		t.Fatal("ordinary check accepted absent package")
	}
}

func TestSystemAppRequirementProducerRoundTrip(t *testing.T) {
	now := time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)
	spec := MachineTargetSpec{SKU: System, PackageRelease: "3.2.0-alpha.12", Contained: []ContainedComponent{{Component: "service", Version: "3.2.0-alpha.11"}, {Component: "interceptor", Version: "3.2.0-alpha.11"}}, Compatibility: []Requirement{{Component: "service", MinInclusive: "3.2.0-alpha.1", MaxExclusive: "4.0.0"}, {Component: "interceptor", MinInclusive: "3.2.0-alpha.1", MaxExclusive: "4.0.0"}}, Requires: Requirement{Component: "app", MinInclusive: "4.0.0", MaxExclusive: "7.0.0"}, IssuedAt: now.Add(-time.Hour).Format(time.RFC3339), ExpiresAt: now.Add(time.Hour).Format(time.RFC3339)}
	raw, err := BuildMachineTarget(spec, bytes.NewReader([]byte("MSI")), now)
	if err != nil {
		t.Fatal(err)
	}
	var p Payload
	if err := json.Unmarshal(raw, &p); err != nil {
		t.Fatal(err)
	}
	r := BootstrapRequest{AppVersion: "3.2.0-alpha.12", Track: "development", RequiredInterceptor: mapi.CounterpartRequirement{Component: "interceptor", MinInclusive: "4.0.0", MaxExclusive: "7.0.0"}}
	if err := validateBootstrapPayload(p, r, now, MachineArtifactOrigin); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(raw, []byte(`"requires"`)) {
		t.Fatal("counterpart requirement lost")
	}
	p.Requires = Requirement{Component: "app", MinInclusive: "7.0.0", MaxExclusive: "4.0.0"}
	if err := validateBootstrapPayload(p, r, now, MachineArtifactOrigin); err == nil {
		t.Fatal("invalid range accepted")
	}
}

func TestMachineMetadataRefreshPreservesImmutableReplayIdentity(t *testing.T) {
	now := time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)
	raw, _ := fixture(t, System, now)
	installed := checkRequest(System).Installed
	original, err := ParseTarget(System, raw, installed, now, MachineArtifactOrigin)
	if err != nil {
		t.Fatal(err)
	}
	accepted, err := AcceptReplay(ReplayState{}, original)
	if err != nil {
		t.Fatal(err)
	}
	var p Payload
	if err := json.Unmarshal(raw, &p); err != nil {
		t.Fatal(err)
	}
	later := now.Add(60 * 24 * time.Hour)
	p.IssuedAt, p.ExpiresAt = later.Add(-time.Minute).Format(time.RFC3339), later.Add(time.Hour).Format(time.RFC3339)
	refreshed, _ := json.MarshalIndent(p, "", "  ")
	release, err := ParseTarget(System, refreshed, installed, later, MachineArtifactOrigin)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := AcceptReplay(accepted, release); err != nil {
		t.Fatalf("same payload refresh: %v", err)
	}
	if _, err := ParseTarget(System, raw, installed, later, MachineArtifactOrigin); err == nil {
		t.Fatal("old metadata expiry bypassed")
	}
	for _, mutate := range []func(*Payload){
		func(p *Payload) {
			p.Artifact.SHA256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		},
		func(p *Payload) { p.Compatibility[0].MinInclusive = "4.0.1" },
	} {
		var changed Payload
		if err := json.Unmarshal(refreshed, &changed); err != nil {
			t.Fatal(err)
		}
		mutate(&changed)
		changedRaw, _ := json.Marshal(changed)
		replacement, err := ParseTarget(System, changedRaw, installed, later, MachineArtifactOrigin)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := AcceptReplay(accepted, replacement); err == nil {
			t.Fatal("same-sequence payload replacement accepted")
		}
	}
}
