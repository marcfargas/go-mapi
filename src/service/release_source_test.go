package service

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

type releaseTransport func(*http.Request) (*http.Response, error)

func (transport releaseTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return transport(request)
}

func sourceFixture(t *testing.T, sku update.SKU, candidate string, responseStatus int) (*AuthenticatedReleaseSource, DiscoveryRequest, *string) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encoded := base64.RawURLEncoding.EncodeToString(public)
	root := update.Root{Schema: update.MachineRootSchema, Version: 1, AllowedOrigin: "https://github.com/marcfargas/go-mapi/releases/download/", Root: update.KeyRole{Keys: map[string]string{"root": encoded}, Threshold: 1}, Targets: update.KeyRole{Keys: map[string]string{"targets": encoded}, Threshold: 1}}
	release := authorizedRelease(t, sku, candidate)
	signed := release.SignedBytes()
	envelope, err := json.Marshal(update.Envelope{Schema: update.EnvelopeSchema, Signed: base64.RawURLEncoding.EncodeToString(signed), Signatures: []update.Signature{{KeyID: "targets", Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(private, signed))}}})
	if err != nil {
		t.Fatal(err)
	}
	responseBody := string(envelope)
	var fetched string
	client := &http.Client{Transport: releaseTransport(func(request *http.Request) (*http.Response, error) {
		fetched = request.URL.String()
		return &http.Response{StatusCode: responseStatus, Body: io.NopCloser(strings.NewReader(responseBody)), ContentLength: int64(len(responseBody)), Header: make(http.Header), Request: request}, nil
	})}
	source, err := NewAuthenticatedReleaseSource(sku, root, "https://updates.example.test", client, func() time.Time { return coordinatorNow })
	if err != nil {
		t.Fatal(err)
	}
	identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(sku), "4.0.0")
	if err != nil {
		t.Fatal(err)
	}
	contained := map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}
	if sku == update.Suite {
		contained["app"] = "4.0.0"
	}
	request := DiscoveryRequest{SKU: sku, Installed: ProductSnapshot{SKU: sku, PackageVersion: "4.0.0", ProductCode: identity.ProductCode, ProductVersion: identity.ProductVersion, Contained: contained}}
	return source, request, &fetched
}

func TestAuthenticatedSourceUsesOnlyFixedSKUTargetAndAcceptsSignedSuccessor(t *testing.T) {
	for _, sku := range []update.SKU{update.System, update.Suite} {
		t.Run(string(sku), func(t *testing.T) {
			source, request, fetched := sourceFixture(t, sku, "4.0.1", http.StatusOK)
			release, err := source.Discover(context.Background(), request)
			if err != nil || release.Namespace() != string(sku) {
				t.Fatalf("release=%v err=%v", release.Namespace(), err)
			}
			if want := "https://updates.example.test/machine/" + string(sku) + "/targets.json"; *fetched != want {
				t.Fatalf("fetched %q, want %q", *fetched, want)
			}
		})
	}
}

func TestAuthenticatedSourceRejectsWrongSKUAndForgedInstalledIdentityBeforeFetch(t *testing.T) {
	source, request, fetched := sourceFixture(t, update.System, "4.0.1", http.StatusOK)
	request.SKU = update.Suite
	if _, err := source.Discover(context.Background(), request); !errors.Is(err, ErrUnauthorizedCandidate) || *fetched != "" {
		t.Fatalf("wrong SKU err=%v fetched=%q", err, *fetched)
	}
	request.SKU = update.System
	request.Installed.ProductCode = "FORGED"
	if _, err := source.Discover(context.Background(), request); !errors.Is(err, ErrUnauthorizedCandidate) || *fetched != "" {
		t.Fatalf("forged installed product err=%v fetched=%q", err, *fetched)
	}
}

func TestAuthenticatedSourceRejectsInvalidMetadataOrigin(t *testing.T) {
	source, _, _ := sourceFixture(t, update.System, "4.0.1", http.StatusOK)
	for _, origin := range []string{"http://updates.example.test", "https://user:pass@updates.example.test", "https://updates.example.test/other", "https://updates.example.test?sku=suite"} {
		if _, err := NewAuthenticatedReleaseSource(update.System, source.policy.Root(), origin, source.client, source.now); err == nil {
			t.Fatalf("accepted metadata origin %q", origin)
		}
	}
}

func TestAuthenticatedSourceTreatsUnavailableMetadataAsOffline(t *testing.T) {
	source, request, _ := sourceFixture(t, update.System, "4.0.1", http.StatusServiceUnavailable)
	if _, err := source.Discover(context.Background(), request); !errors.Is(err, ErrOffline) {
		t.Fatalf("metadata error=%v", err)
	}
}

func TestAuthenticatedSourceRejectsReplayAndInvalidSignature(t *testing.T) {
	source, request, _ := sourceFixture(t, update.System, "4.0.1", http.StatusOK)
	request.Replay = update.ReplayState{Namespace: string(update.System), Sequence: 4<<24 | 2, Digest: strings.Repeat("a", 64)}
	if _, err := source.Discover(context.Background(), request); err == nil {
		t.Fatal("accepted replay downgrade")
	}
	source.client.Transport = releaseTransport(func(request *http.Request) (*http.Response, error) {
		body := `{"schema":"go-mapi-admin-envelope-v1","signed":"Zm9yZ2Vk","signatures":[]}`
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(body)), ContentLength: int64(len(body)), Header: make(http.Header), Request: request}, nil
	})
	request.Replay = update.ReplayState{}
	if _, err := source.Discover(context.Background(), request); err == nil || errors.Is(err, ErrOffline) {
		t.Fatalf("invalid signature err=%v", err)
	}
}

func TestAuthenticatedSourceBoundsEnvelope(t *testing.T) {
	source, request, _ := sourceFixture(t, update.System, "4.0.1", http.StatusOK)
	source.client.Transport = releaseTransport(func(request *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(strings.Repeat("x", maxMachineEnvelopeBytes+1))), ContentLength: -1, Header: make(http.Header), Request: request}, nil
	})
	if _, err := source.Discover(context.Background(), request); err == nil || !strings.Contains(err.Error(), "bound") {
		t.Fatalf("oversize envelope err=%v", err)
	}
}
