package service

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func TestMachineHTTPRequestBoundaryRejectsUserAndInteractiveInputs(t *testing.T) {
	valid, _ := http.NewRequest(http.MethodGet, "https://github.com/example/asset", nil)
	if err := validateMachineHTTPRequest(valid); err != nil {
		t.Fatalf("valid machine request: %v", err)
	}
	for _, test := range []struct {
		name    string
		request *http.Request
	}{
		{"http", &http.Request{Method: http.MethodGet, URL: &url.URL{Scheme: "http", Host: "example.test"}}},
		{"embedded credential", &http.Request{Method: http.MethodGet, URL: &url.URL{Scheme: "https", Host: "example.test", User: url.UserPassword("user", "secret")}}},
		{"write method", &http.Request{Method: http.MethodPost, URL: &url.URL{Scheme: "https", Host: "example.test"}}},
		{"request body", &http.Request{Method: http.MethodGet, URL: &url.URL{Scheme: "https", Host: "example.test"}, Body: io.NopCloser(bytes.NewReader([]byte("credentials")))}},
		{"authorization header", &http.Request{Method: http.MethodGet, URL: &url.URL{Scheme: "https", Host: "example.test"}, Header: http.Header{"Authorization": []string{"Bearer secret"}}}},
		{"proxy authorization header", &http.Request{Method: http.MethodGet, URL: &url.URL{Scheme: "https", Host: "example.test"}, Header: http.Header{"Proxy-Authorization": []string{"Basic secret"}}}},
		{"cookie header", &http.Request{Method: http.MethodGet, URL: &url.URL{Scheme: "https", Host: "example.test"}, Header: http.Header{"Cookie": []string{"secret=value"}}}},
		{"fragment", &http.Request{Method: http.MethodGet, URL: &url.URL{Scheme: "https", Host: "example.test", Fragment: "secret"}}},
	} {
		t.Run(test.name, func(t *testing.T) {
			if err := validateMachineHTTPRequest(test.request); !errors.Is(err, ErrMachineHTTPInvalidRequest) {
				t.Fatalf("error = %v", err)
			}
		})
	}
}

func TestMachineHTTPForwardsOnlyCanonicalRoutingHints(t *testing.T) {
	const origin = "https://updates.example.test"
	for _, sku := range []string{"system", "suite"} {
		for _, version := range []string{"", "4.0.1", "5.0.1-alpha.2"} {
			request, _ := http.NewRequest(http.MethodGet, origin+"/machine/"+sku+"/targets.json", nil)
			track := "stable"
			if version != "" {
				track = mapi.ReleaseTrack(version)
				request.Header.Set("X-Go-Mapi-Installed-Version", version)
			}
			request.Header.Set("X-Go-Mapi-Release-Track", track)
			want := "X-Go-Mapi-Release-Track: " + track + "\r\n"
			if version != "" {
				want += "X-Go-Mapi-Installed-Version: " + version + "\r\n"
			}
			header, err := machineHTTPForwardHeader(request, origin)
			if err != nil || header != want {
				t.Fatalf("%s version %q: header=%q error=%v", sku, version, header, err)
			}
		}
	}
	for _, values := range []http.Header{
		{"X-Go-Mapi-Installed-Version": {"4.0.0"}},
		{"X-Go-Mapi-Release-Track": {"stable"}, "X-Go-Mapi-Installed-Version": {"4.0.0\r\nAuthorization: secret"}},
		{"X-Go-Mapi-Release-Track": {"development"}, "X-Go-Mapi-Installed-Version": {"5.0.1-alpha.0"}},
		{"X-Go-Mapi-Release-Track": {"stable"}, "X-Go-Mapi-Installed-Version": {"4.0.0", "5.0.1-alpha.1"}},
		{"X-Go-Mapi-Release-Track": {"stable"}, "X-Go-Mapi-Installed-Version": {"4.0.0"}, "Cookie": {"secret=value"}},
		{"X-Go-Mapi-Release-Track": {"stable"}, "Cookie": {"secret=value"}},
		{"X-Go-Mapi-Release-Track": {"stable"}, "X-Go-Mapi-Installed-Version": {"5.0.1-alpha.2"}},
		{"X-Go-Mapi-Release-Track": {"alpha"}},
		{"X-Go-Mapi-Release-Track": {"Stable"}},
		{"X-Go-Mapi-Release-Track": {"stable\r\nCookie: secret"}},
		{"X-Go-Mapi-Release-Track": {"stable\x00"}},
		{"X-Go-Mapi-Release-Track": {"stable", "development"}},
		{"X-Go-Mapi-Release-Track": nil},
		{"X-Go-Mapi-Release-Track": {"stable"}, "x-go-mapi-release-track": {"stable"}},
		{"X-Go-Mapi-Installed-Version": {"4.0.0"}, "x-go-mapi-installed-version": {"4.0.0"}},
		{"Authorization": []string{"Bearer secret"}},
	} {
		request, _ := http.NewRequest(http.MethodGet, origin+"/machine/system/targets.json", nil)
		request.Header = values
		if _, err := machineHTTPForwardHeader(request, origin); !errors.Is(err, ErrMachineHTTPInvalidRequest) {
			t.Fatalf("accepted privileged header %#v: %v", values, err)
		}
	}
	for _, raw := range []string{
		"https://github.com/marcfargas/go-mapi/releases/download/v4.0.1/go-mapi-system-4.0.1-x64.msi",
		origin + "/machine/system/targets.json?track=stable",
		origin + "/machine/system/targets.json/extra",
		origin + "/machine/%73ystem/targets.json",
		origin + "/machine/system/targets.json?",
		"https://other.example.test/machine/system/targets.json",
	} {
		request, _ := http.NewRequest(http.MethodGet, raw, nil)
		request.Header.Set("X-Go-Mapi-Release-Track", "stable")
		if _, err := machineHTTPForwardHeader(request, origin); !errors.Is(err, ErrMachineHTTPInvalidRequest) {
			t.Fatalf("forwarded installed release to %s: %v", raw, err)
		}
	}
	request, _ := http.NewRequest(http.MethodHead, origin+"/machine/system/targets.json", nil)
	request.Header.Set("X-Go-Mapi-Release-Track", "stable")
	if _, err := machineHTTPForwardHeader(request, origin); !errors.Is(err, ErrMachineHTTPInvalidRequest) {
		t.Fatalf("forwarded installed release on HEAD: %v", err)
	}
}

type machineRoutingTransport func(*http.Request) (*http.Response, error)

func (f machineRoutingTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestUpdaterRequestsPassMachineHTTPBoundary(t *testing.T) {
	previousOrigin := MachineReleaseMetadataOrigin
	MachineReleaseMetadataOrigin = "https://updates.example.test"
	t.Cleanup(func() { MachineReleaseMetadataOrigin = previousOrigin })
	for _, version := range []string{"4.0.1", "5.0.1-alpha.2"} {
		for _, mode := range []string{"system", "suite", "bootstrap"} {
			t.Run(mode+"/"+version, func(t *testing.T) {
				sku := update.System
				if mode == "suite" {
					sku = update.Suite
				}
				// Stop after boundary admission: this checks the real producer's
				// request without requiring network or machine trust changes.
				reached := errors.New("routing boundary admitted updater request")
				calls := 0
				client := &http.Client{Transport: machineRoutingTransport(func(r *http.Request) (*http.Response, error) {
					calls++
					if r.URL.Path != "/machine/"+string(sku)+"/targets.json" || r.Header.Get("X-Go-Mapi-Release-Track") != mapi.ReleaseTrack(version) {
						t.Fatalf("unexpected updater routing: %s %#v", r.URL, r.Header)
					}
					wantVersion := version
					if mode == "bootstrap" {
						wantVersion = ""
					}
					if r.Header.Get("X-Go-Mapi-Installed-Version") != wantVersion {
						t.Fatalf("installed version hint = %q; want %q", r.Header.Get("X-Go-Mapi-Installed-Version"), wantVersion)
					}
					if err := validateMachineHTTPRequest(r); err != nil {
						return nil, err
					}
					return nil, reached
				})}
				engine, err := update.NewEngine(update.Config{SKU: sku, MetadataOrigin: MachineReleaseMetadataOrigin, Client: client, Now: time.Now})
				if err != nil {
					t.Fatal(err)
				}
				if mode == "bootstrap" {
					_, err = engine.Bootstrap(context.Background(), update.BootstrapRequest{AppVersion: version, Track: mapi.ReleaseTrack(version), RequiredInterceptor: mapi.CounterpartRequirement{Component: "interceptor"}})
				} else {
					_, err = engine.Check(context.Background(), update.CheckRequest{Enabled: true, InstalledVersion: version})
				}
				if !errors.Is(err, reached) || calls != 1 {
					t.Fatalf("updater boundary: calls=%d error=%v", calls, err)
				}
			})
		}
	}
}

func TestMachineHTTPErrorsAreBoundedAndRedacted(t *testing.T) {
	for _, err := range []error{ErrMachineHTTPUnavailable, ErrMachineHTTPFailure, ErrMachineProxyAuthentication, ErrMachineHTTPInvalidRequest} {
		text := strings.ToLower(err.Error())
		for _, forbidden := range []string{"http://", "https://", "@", "password", "credential=", "proxy="} {
			if strings.Contains(text, forbidden) {
				t.Fatalf("error %q leaks %q", text, forbidden)
			}
		}
		if len(text) > 80 {
			t.Fatalf("error is not bounded: %q", text)
		}
	}
	if !errors.Is(ErrMachineHTTPFailure, ErrOffline) || !errors.Is(ErrMachineProxyAuthentication, ErrOffline) {
		t.Fatal("machine network failures do not enter the coordinator's bounded offline backoff")
	}
	if errors.Is(ErrMachineHTTPInvalidRequest, ErrOffline) {
		t.Fatal("invalid privileged input was misclassified as a transient network failure")
	}
}
