//go:build windows

package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

type updateCheckRoundTripper func(*http.Request) (*http.Response, error)

func (f updateCheckRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestUpdateCheckFetcherUsesFixedV1POSTContract(t *testing.T) {
	var got updateCheckRequest
	fetcher := newUpdateCheckFetcher("4.0.0")
	fetcher.request = updateCheckRequest{Schema: updateCheckSchema, AppVersion: "4.0.0", InterceptorVersion: "absent", DistributionChannel: "standalone", ReleaseTrack: "stable", OS: "windows", Architecture: "x64"}
	fetcher.client = &http.Client{Transport: updateCheckRoundTripper(func(req *http.Request) (*http.Response, error) {
		if req.Method != http.MethodPost || req.URL.String() != updateCheckEndpoint || req.Header.Get("Content-Type") != "application/json" {
			t.Fatalf("request = %s %s content-type=%q", req.Method, req.URL, req.Header.Get("Content-Type"))
		}
		if req.Header.Get("Cookie") != "" {
			t.Fatal("check request must not send cookies")
		}
		if err := json.NewDecoder(req.Body).Decode(&got); err != nil {
			t.Fatal(err)
		}
		body := `{"schema":"go-mapi-update-check-v1","app":{"latestVersion":"4.0.1","updateAvailable":true},"interceptor":{"latestVersion":"4.0.2","updateAvailable":true},"compatibility":"compatible"}`
		return &http.Response{StatusCode: http.StatusOK, Status: "200 OK", Header: http.Header{"Cache-Control": []string{"no-store"}}, Body: io.NopCloser(strings.NewReader(body)), Request: req}, nil
	})}

	release, err := fetcher.FetchLatestRelease(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got != fetcher.request {
		t.Fatalf("request = %#v, want %#v", got, fetcher.request)
	}
	if release == nil || release.Version != "4.0.1" || release.ReleaseURL != appUpdateDownloadURL("4.0.1") || !release.InterceptorUpdateAvailable || release.InterceptorVersion != "4.0.2" {
		t.Fatalf("release = %#v", release)
	}
}

func TestUpdateCheckFetcherRejectsInvalidSchemaAndRoute(t *testing.T) {
	for _, body := range []string{
		`{"schema":"other","compatibility":"compatible"}`,
		`{"schema":"go-mapi-update-check-v1","app":{"latestVersion":"not-semver","updateAvailable":true},"compatibility":"compatible"}`,
		`{"schema":"go-mapi-update-check-v1","compatibility":"compatible","unexpected":true}`,
		`{"schema":"go-mapi-update-check-v1","app":{"latestVersion":"4.0.0","updateAvailable":true},"compatibility":"compatible"}`,
		`{"schema":"go-mapi-update-check-v1","interceptor":{"latestVersion":"4.0.2","updateAvailable":true,"minAppVersion":"4.1.0","maxAppVersion":"4.0.0"},"compatibility":"incompatible"}`,
	} {
		t.Run(body, func(t *testing.T) {
			fetcher := newUpdateCheckFetcher("4.0.0")
			fetcher.request.ReleaseTrack = "stable"
			fetcher.client = &http.Client{Transport: updateCheckRoundTripper(func(req *http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: http.StatusOK, Status: "200 OK", Header: http.Header{"Cache-Control": []string{"no-store"}}, Body: io.NopCloser(strings.NewReader(body)), Request: req}, nil
			})}
			if _, err := fetcher.FetchLatestRelease(context.Background()); err == nil {
				t.Fatal("expected invalid response error")
			}
		})
	}
	if !allowedUpdateURL(appUpdateDownloadURL("4.0.1")) {
		t.Fatal("versioned first-party route was rejected")
	}
	for _, rawURL := range []string{
		"https://github.com/marcfargas/go-mapi/releases/latest",
		"https://go-mapi.app/downloads/app/not-semver/x64",
		"https://go-mapi.app/downloads/app/4.0.1/x64/extra",
		"https://go-mapi.app/downloads/app/4.0.1/x64?source=other",
		"https://go-mapi.app/downloads/app/4.0.1/x64#fragment",
		"https://user@go-mapi.app/downloads/app/4.0.1/x64",
	} {
		if allowedUpdateURL(rawURL) {
			t.Errorf("untrusted update route was accepted: %q", rawURL)
		}
	}
}

func TestUpdateCheckResponseAcceptsAbsentAndRejectsInterceptorDowngrade(t *testing.T) {
	request := updateCheckRequest{AppVersion: "4.0.0", InterceptorVersion: "absent"}
	if err := validUpdateCheckResponse(updateCheckResponse{Schema: updateCheckSchema, Compatibility: "compatible", Interceptor: updateCheckComponent{LatestVersion: "4.0.1", UpdateAvailable: true, MinAppVersion: "4.0.0"}}, request); err != nil {
		t.Fatalf("absent interceptor: %v", err)
	}
	request.InterceptorVersion = "4.0.1"
	if err := validUpdateCheckResponse(updateCheckResponse{Schema: updateCheckSchema, Compatibility: "compatible", Interceptor: updateCheckComponent{LatestVersion: "4.0.1", UpdateAvailable: true}}, request); err == nil {
		t.Fatal("expected interceptor downgrade/equal target rejection")
	}
	request.InterceptorVersion = "unknown"
	if err := validUpdateCheckResponse(updateCheckResponse{Schema: updateCheckSchema, Compatibility: "compatible", Interceptor: updateCheckComponent{LatestVersion: "4.0.2", UpdateAvailable: true}}, request); err != nil {
		t.Fatalf("unknown interceptor: %v", err)
	}
}

func TestUpdateCheckFetcherDoesNotCheckDevBuild(t *testing.T) {
	fetcher := newUpdateCheckFetcher("0.0.0-dev")
	if fetcher.request.ReleaseTrack != "unknown" {
		t.Fatalf("track = %q", fetcher.request.ReleaseTrack)
	}
	if release, err := fetcher.FetchLatestRelease(context.Background()); err != nil || release != nil {
		t.Fatalf("release=%#v err=%v", release, err)
	}
}
