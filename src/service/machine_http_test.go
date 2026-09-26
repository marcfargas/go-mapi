package service

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
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

func TestMachineHTTPForwardsOnlyCanonicalInstalledVersionHint(t *testing.T) {
	const origin = "https://updates.example.test"
	for _, version := range []string{"4.0.1", "5.0.1-alpha.2"} {
		request, _ := http.NewRequest(http.MethodGet, origin+"/machine/system/targets.json", nil)
		request.Header.Set("X-Go-Mapi-Installed-Version", version)
		header, err := machineHTTPForwardHeader(request, origin)
		if err != nil || header != "X-Go-Mapi-Installed-Version: "+version+"\r\n" {
			t.Fatalf("version %q: header=%q error=%v", version, header, err)
		}
	}
	for _, values := range []http.Header{
		{"X-Go-Mapi-Installed-Version": []string{"4.0.0\r\nAuthorization: secret"}},
		{"X-Go-Mapi-Installed-Version": []string{"5.0.1-alpha.0"}},
		{"X-Go-Mapi-Installed-Version": []string{"4.0.0", "5.0.1-alpha.1"}},
		{"X-Go-Mapi-Installed-Version": []string{"4.0.0"}, "Cookie": []string{"secret=value"}},
		{"Authorization": []string{"Bearer secret"}},
	} {
		request, _ := http.NewRequest(http.MethodGet, origin+"/machine/system/targets.json", nil)
		request.Header = values
		if _, err := machineHTTPForwardHeader(request, origin); !errors.Is(err, ErrMachineHTTPInvalidRequest) {
			t.Fatalf("accepted privileged header %#v: %v", values, err)
		}
	}
	for _, raw := range []string{
		"https://github.com/marcfargas/go-mapi/releases/download/system-v4.0.1/go-mapi-system-4.0.1-x64.msi",
		origin + "/machine/system/targets.json?track=stable",
		origin + "/machine/system/targets.json/extra",
		"https://other.example.test/machine/system/targets.json",
	} {
		request, _ := http.NewRequest(http.MethodGet, raw, nil)
		request.Header.Set("X-Go-Mapi-Installed-Version", "4.0.0")
		if _, err := machineHTTPForwardHeader(request, origin); !errors.Is(err, ErrMachineHTTPInvalidRequest) {
			t.Fatalf("forwarded installed release to %s: %v", raw, err)
		}
	}
	request, _ := http.NewRequest(http.MethodHead, origin+"/machine/system/targets.json", nil)
	request.Header.Set("X-Go-Mapi-Installed-Version", "4.0.0")
	if _, err := machineHTTPForwardHeader(request, origin); !errors.Is(err, ErrMachineHTTPInvalidRequest) {
		t.Fatalf("forwarded installed release on HEAD: %v", err)
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
