package update

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (f transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func response(r *http.Request, body []byte) *http.Response {
	return &http.Response{StatusCode: 200, Body: io.NopCloser(bytes.NewReader(body)), ContentLength: int64(len(body)), Header: make(http.Header), Request: r}
}
func fixture(t *testing.T, sku SKU, now time.Time) ([]byte, []byte) {
	t.Helper()
	body := []byte("final signed MSI bytes")
	names := []string{"service", "interceptor"}
	if sku == Suite {
		names = append(names, "app")
	}
	contained := make([]ContainedComponent, 0, len(names))
	reqs := make([]Requirement, 0, len(names))
	for _, name := range names {
		contained = append(contained, ContainedComponent{Component: name, Version: "4.0.1"})
		reqs = append(reqs, Requirement{Component: name, MinInclusive: "4.0.0", MaxExclusive: "5.0.0"})
	}
	raw, err := BuildMachineTarget(MachineTargetSpec{SKU: sku, PackageRelease: "4.0.2", Contained: contained, Compatibility: reqs, IssuedAt: now.Add(-time.Hour).Format(time.RFC3339), ExpiresAt: now.Add(time.Hour).Format(time.RFC3339)}, bytes.NewReader(body), now)
	if err != nil {
		t.Fatal(err)
	}
	return raw, body
}
func checkRequest(sku SKU) CheckRequest {
	installed := map[string]string{"service": "4.0.1", "interceptor": "4.0.1"}
	if sku == Suite {
		installed["app"] = "4.0.1"
	}
	return CheckRequest{Enabled: true, InstalledVersion: "4.0.1", Installed: installed}
}
func stageIn(t *testing.T) func(context.Context, Candidate, func(io.Writer) error) (string, func(), error) {
	t.Helper()
	return func(_ context.Context, _ Candidate, write func(io.Writer) error) (string, func(), error) {
		path := filepath.Join(t.TempDir(), "candidate.msi")
		file, err := os.Create(path)
		if err != nil {
			return "", nil, err
		}
		err = write(file)
		closeErr := file.Close()
		if err == nil {
			err = closeErr
		}
		if err != nil {
			return "", nil, err
		}
		return path, func() { _ = os.Remove(path) }, nil
	}
}
func TestManagedEngineOneFetchOneSignatureAndOwnership(t *testing.T) {
	for _, sku := range []SKU{System, Suite} {
		t.Run(string(sku), func(t *testing.T) {
			now := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
			raw, body := fixture(t, sku, now)
			metadata, artifact, verified, handed := 0, 0, 0, 0
			client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
				if strings.Contains(r.URL.Path, "/machine/") {
					metadata++
					if r.Header.Get("X-Go-Mapi-Installed-Version") != "4.0.1" {
						t.Fatal("missing installed version")
					}
					return response(r, raw), nil
				}
				artifact++
				return response(r, body), nil
			})}
			engine, err := NewEngine(Config{SKU: sku, MetadataOrigin: "https://go-mapi.app", Client: client, Now: func() time.Time { return now }})
			if err != nil {
				t.Fatal(err)
			}
			result, err := engine.Check(context.Background(), checkRequest(sku))
			if err != nil || !result.Checked || !result.Available || metadata != 1 {
				t.Fatalf("check=%+v err=%v metadata=%d", result, err, metadata)
			}
			_, err = engine.Install(context.Background(), result.Candidate, InstallOptions{Stage: stageIn(t), Verify: func(_ context.Context, path string) error {
				verified++
				data, e := os.ReadFile(path)
				if e != nil || !bytes.Equal(data, body) {
					t.Fatal("staged bytes mismatch")
				}
				return nil
			}, Handoff: func(_ context.Context, p Prepared) error {
				handed++
				if _, e := os.Stat(p.Path()); e != nil {
					t.Fatal(e)
				}
				p.Cleanup()
				return nil
			}})
			if err != nil || artifact != 1 || verified != 1 || handed != 1 {
				t.Fatalf("install err=%v counts=%d/%d/%d", err, artifact, verified, handed)
			}
		})
	}
}
func TestManagedEngineRejectsBeforeArtifactAndSignature(t *testing.T) {
	now := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	raw, body := fixture(t, System, now)
	for _, tc := range []struct {
		name      string
		raw       []byte
		sku       SKU
		enabled   bool
		installed map[string]string
	}{{"disabled", raw, System, false, nil}, {"malformed", []byte("{}"), System, true, nil}, {"wrong SKU", raw, Suite, true, nil}, {"incompatible", raw, System, true, map[string]string{"service": "3.0.0", "interceptor": "4.0.1"}}} {
		t.Run(tc.name, func(t *testing.T) {
			metadata, artifact, verified := 0, 0, 0
			client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
				if strings.Contains(r.URL.Path, "/machine/") {
					metadata++
					return response(r, tc.raw), nil
				}
				artifact++
				return response(r, body), nil
			})}
			e, err := NewEngine(Config{SKU: tc.sku, MetadataOrigin: "https://go-mapi.app", Client: client, Now: func() time.Time { return now }})
			if err != nil {
				t.Fatal(err)
			}
			req := checkRequest(tc.sku)
			req.Enabled = tc.enabled
			if tc.installed != nil {
				req.Installed = tc.installed
			}
			result, err := e.Check(context.Background(), req)
			if tc.enabled && err == nil {
				t.Fatal("bad target accepted")
			}
			if !tc.enabled && result.Checked {
				t.Fatal("disabled check fetched")
			}
			if result.Available {
				_, _ = e.Install(context.Background(), result.Candidate, InstallOptions{Stage: stageIn(t), Verify: func(context.Context, string) error { verified++; return nil }})
			}
			if artifact != 0 || verified != 0 {
				t.Fatalf("artifact=%d verifier=%d", artifact, verified)
			}
		})
	}
}
func TestSignatureFailureNeverHandsOff(t *testing.T) {
	now := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	raw, body := fixture(t, System, now)
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		if strings.Contains(r.URL.Path, "/machine/") {
			return response(r, raw), nil
		}
		return response(r, body), nil
	})}
	e, _ := NewEngine(Config{SKU: System, MetadataOrigin: "https://go-mapi.app", Client: client, Now: func() time.Time { return now }})
	r, err := e.Check(context.Background(), checkRequest(System))
	if err != nil {
		t.Fatal(err)
	}
	called := false
	_, err = e.Install(context.Background(), r.Candidate, InstallOptions{Stage: stageIn(t), Verify: func(context.Context, string) error { return errors.New("Windows rejected signer") }, Handoff: func(context.Context, Prepared) error { called = true; return nil }})
	if err == nil || called {
		t.Fatal("signature failure handed off")
	}
}
func TestActionCandidateNeverDownloadsOrVerifies(t *testing.T) {
	now := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	requests := 0
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		requests++
		body := []byte(`{"schema":"go-mapi-update-check-v1","app":{"installedVersion":"4.0.1","latestVersion":"4.0.2","updateAvailable":true},"interceptor":{"installedVersion":"absent","latestVersion":"","updateAvailable":false},"compatibility":"compatible"}`)
		res := response(r, body)
		res.Header.Set("Cache-Control", "no-store")
		return res, nil
	})}
	e, _ := NewEngine(Config{SKU: App, MetadataOrigin: "https://go-mapi.app", Client: client, Now: func() time.Time { return now }})
	r, err := e.Check(context.Background(), CheckRequest{Enabled: true, InstalledVersion: "4.0.1", Installed: map[string]string{"interceptor": "absent"}, Channel: "standalone", Track: "stable"})
	if err != nil || !r.Available {
		t.Fatalf("check %v %+v", err, r)
	}
	opened := ""
	_, err = e.Install(context.Background(), r.Candidate, InstallOptions{OpenURL: func(_ context.Context, u string) error { opened = u; return nil }, Verify: func(context.Context, string) error { t.Fatal("action verified artifact"); return nil }})
	if err != nil || opened != "https://go-mapi.app/downloads/app/4.0.2/x64" || requests != 1 {
		t.Fatalf("action err=%v url=%q requests=%d", err, opened, requests)
	}
}
func TestRedirectAllowlist(t *testing.T) {
	origin := MachineArtifactOrigin
	for _, raw := range []string{"https://github.com/marcfargas/go-mapi/releases/download/system-v4.0.2/go-mapi-system-4.0.2-x64.msi", "https://release-assets.githubusercontent.com/opaque?token=abc"} {
		if !AllowedArtifactURL(origin, mustURL(raw), true) {
			t.Fatalf("rejected %s", raw)
		}
	}
	for _, raw := range []string{"https://evil.example/file", "https://github.com/other/repo/releases/download/system-v4.0.2/a.msi", "https://release-assets.githubusercontent.com:444/opaque", "https://github.com/marcfargas/go-mapi/releases/download/../private", "https://github.com/marcfargas/go-mapi/releases/download/a?token=x"} {
		if AllowedArtifactURL(origin, mustURL(raw), true) {
			t.Fatalf("allowed %s", raw)
		}
	}
}

func TestAppWireRejectsPartialAndContradictoryResponses(t *testing.T) {
	request := appRequest{Schema: appCheckSchema, AppVersion: "4.0.1", InterceptorVersion: "4.0.1", DistributionChannel: "standalone", ReleaseTrack: "stable", OS: "windows", Architecture: "x64"}
	good := `{"schema":"go-mapi-update-check-v1","app":{"installedVersion":"4.0.1","latestVersion":"4.0.2","updateAvailable":true},"interceptor":{"installedVersion":"4.0.1","latestVersion":"4.0.2","updateAvailable":true,"minAppVersion":"4.0.0","maxAppVersion":"5.0.0"},"compatibility":"compatible"}`
	var parsed appResponse
	if err := DecodeJSON([]byte(good), &parsed); err != nil {
		t.Fatal(err)
	}
	if err := validateAppWire([]byte(good), parsed, request); err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"missing interceptor":               `{"schema":"go-mapi-update-check-v1","app":{"installedVersion":"4.0.1","latestVersion":"4.0.2","updateAvailable":true},"compatibility":"compatible"}`,
		"null availability":                 strings.Replace(good, `"updateAvailable":true`, `"updateAvailable":null`, 1),
		"wrong installed identity":          strings.Replace(good, `"installedVersion":"4.0.1"`, `"installedVersion":"4.0.0"`, 1),
		"wrong release track":               strings.Replace(good, `"latestVersion":"4.0.2"`, `"latestVersion":"5.0.1-alpha.1"`, 1),
		"invalid interceptor range":         strings.Replace(good, `"maxAppVersion":"5.0.0"`, `"maxAppVersion":"3.0.0"`, 1),
		"false app flag with newer version": strings.Replace(good, `"updateAvailable":true`, `"updateAvailable":false`, 1),
		"interceptor downgrade flag":        strings.Replace(good, `"latestVersion":"4.0.2","updateAvailable":true,"minAppVersion"`, `"latestVersion":"4.0.1","updateAvailable":true,"minAppVersion"`, 1),
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			var v appResponse
			err := DecodeJSON([]byte(body), &v)
			if err == nil {
				err = validateAppWire([]byte(body), v, request)
			}
			if err == nil {
				t.Fatal("invalid response accepted")
			}
		})
	}
}
func TestManualCheckBypassesFutureCadenceAndPersistsAttemptBeforeNetwork(t *testing.T) {
	now := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	raw, _ := fixture(t, System, now)
	requested := 0
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) { requested++; return response(r, raw), nil })}
	e, _ := NewEngine(Config{SKU: System, MetadataOrigin: "https://go-mapi.app", Client: client, Now: func() time.Time { return now }})
	prior := CheckState{LastAttemptAt: now.Add(time.Hour), NextAttemptAt: now.Add(time.Hour)}
	persisted := false
	r := checkRequest(System)
	r.State = prior
	r.Force = true
	r.OnAttempt = func(s CheckState) error {
		persisted = true
		if !s.LastAttemptAt.Equal(now) || requested != 0 {
			t.Fatal("attempt not persisted before fetch")
		}
		return nil
	}
	result, err := e.Check(context.Background(), r)
	if err != nil || !result.Checked || !persisted || requested != 1 {
		t.Fatalf("check err=%v result=%+v persisted=%v requests=%d", err, result, persisted, requested)
	}
}

func TestArtifactFailureStreakSurvivesSuccessfulMetadataChecks(t *testing.T) {
	now := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	raw, _ := fixture(t, System, now)
	metadata, artifacts := 0, 0
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		if strings.Contains(r.URL.Path, "/machine/") {
			metadata++
			return response(r, raw), nil
		}
		artifacts++
		return nil, errors.New("artifact offline")
	})}
	engine, err := NewEngine(Config{SKU: System, MetadataOrigin: "https://go-mapi.app", Client: client, Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	state := CheckState{}
	for attempt, wantDelay := range []time.Duration{15 * time.Minute, 30 * time.Minute} {
		request := checkRequest(System)
		request.State = state
		checked, err := engine.Check(context.Background(), request)
		if err != nil || !checked.Available {
			t.Fatalf("check %d: %v %+v", attempt, err, checked)
		}
		if attempt > 0 && checked.State.Failures != state.Failures {
			t.Fatalf("successful metadata erased artifact failures: %d to %d", state.Failures, checked.State.Failures)
		}
		_, err = engine.Install(context.Background(), checked.Candidate, InstallOptions{Stage: stageIn(t), Verify: func(context.Context, string) error { t.Fatal("artifact failure reached verifier"); return nil }})
		if err == nil {
			t.Fatal("offline artifact accepted")
		}
		state = engine.InstallFailureState(checked.State)
		if got := state.NextAttemptAt.Sub(now); got != wantDelay {
			t.Fatalf("attempt %d backoff=%s want %s", attempt, got, wantDelay)
		}
		now = state.NextAttemptAt
	}
	if metadata != 2 || artifacts != 2 {
		t.Fatalf("request counts %d/%d", metadata, artifacts)
	}
}

func TestControlledHTTPSArtifactOriginIsExact(t *testing.T) {
	now := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	origin := "https://127.0.0.1:10000/releases/download/"
	spec := MachineTargetSpec{SKU: System, PackageRelease: "4.0.2", Contained: []ContainedComponent{{Component: "service", Version: "4.0.1"}, {Component: "interceptor", Version: "4.0.1"}}, Compatibility: []Requirement{{Component: "service", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}, {Component: "interceptor", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}}, IssuedAt: now.Add(-time.Minute).Format(time.RFC3339), ExpiresAt: now.Add(time.Hour).Format(time.RFC3339)}
	target, err := BuildMachineTargetForOrigin(spec, bytes.NewReader([]byte("MSI")), now, origin)
	if err != nil {
		t.Fatal(err)
	}
	installed := map[string]string{"service": "4.0.1", "interceptor": "4.0.1"}
	if _, err := ParseTarget(System, target, installed, now, origin); err != nil {
		t.Fatal(err)
	}
	if _, err := ParseTarget(System, target, installed, now, "https://127.0.0.1:10001/releases/download/"); err == nil {
		t.Fatal("accepted changed artifact port")
	}
}
