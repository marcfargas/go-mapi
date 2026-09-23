package service

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

const maxMachineEnvelopeBytes = 256 << 10

// AuthenticatedReleaseSource fetches a fixed SKU's envelope from the trusted
// metadata origin. Neither the coordinator nor release metadata can choose
// the discovery URL. The root and origin must be supplied by the signed
// service build, never by a writable machine setting.
type AuthenticatedReleaseSource struct {
	sku       update.SKU
	policy    update.Policy
	publisher update.PublisherPolicy
	url       string
	client    *http.Client
	now       func() time.Time
}

func NewAuthenticatedReleaseSource(sku update.SKU, root update.Root, metadataOrigin string, publisher update.PublisherPolicy, client *http.Client, now func() time.Time) (*AuthenticatedReleaseSource, error) {
	policy, err := update.NewMachinePolicy(sku, root)
	if err != nil {
		return nil, err
	}
	if err := update.ValidatePublisherPolicy(publisher); err != nil {
		return nil, fmt.Errorf("invalid protected publisher policy: %w", err)
	}
	publisher.EKUs = append([]string(nil), publisher.EKUs...)
	origin, err := url.Parse(metadataOrigin)
	if err != nil || origin.Scheme != "https" || origin.Host == "" || origin.User != nil || origin.RawQuery != "" || origin.Fragment != "" || origin.Opaque != "" || origin.Path != "" && origin.Path != "/" || client == nil || now == nil {
		return nil, errors.New("machine release source requires a fixed HTTPS metadata origin and machine client")
	}
	origin.Path = "/machine/" + string(sku) + "/targets.json"
	return &AuthenticatedReleaseSource{sku: sku, policy: policy, publisher: publisher, url: origin.String(), client: client, now: now}, nil
}

func (source *AuthenticatedReleaseSource) Discover(ctx context.Context, request DiscoveryRequest) (update.Release, error) {
	if source == nil || request.SKU != source.sku || request.Installed.SKU != source.sku {
		return update.Release{}, ErrUnauthorizedCandidate
	}
	installed, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(source.sku), request.Installed.PackageVersion)
	if err != nil || request.Installed.ProductCode != installed.ProductCode || request.Installed.ProductVersion != installed.ProductVersion {
		return update.Release{}, ErrUnauthorizedCandidate
	}
	if request.Replay.Namespace != "" && request.Replay.Namespace != string(source.sku) {
		return update.Release{}, ErrUnauthorizedCandidate
	}
	fetch, err := http.NewRequestWithContext(ctx, http.MethodGet, source.url, nil)
	if err != nil {
		return update.Release{}, err
	}
	client := *source.client
	client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }
	response, err := client.Do(fetch)
	if err != nil {
		return update.Release{}, fmt.Errorf("%w: metadata request failed", ErrOffline)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return update.Release{}, fmt.Errorf("%w: metadata unavailable", ErrOffline)
	}
	if response.ContentLength > maxMachineEnvelopeBytes {
		return update.Release{}, errors.New("machine release envelope exceeds bound")
	}
	envelope, err := io.ReadAll(io.LimitReader(response.Body, maxMachineEnvelopeBytes+1))
	if err != nil {
		return update.Release{}, fmt.Errorf("%w: metadata response failed", ErrOffline)
	}
	if len(envelope) > maxMachineEnvelopeBytes {
		return update.Release{}, errors.New("machine release envelope exceeds bound")
	}
	versions := make(map[string]string, len(request.Installed.Contained))
	for component, version := range request.Installed.Contained {
		versions[component] = version
	}
	release, err := source.policy.Authorize(envelope, versions, source.now())
	if err != nil {
		return update.Release{}, fmt.Errorf("authorize machine release: %w", err)
	}
	if err := update.MatchPublisherPolicy(source.publisher, release.Payload().Publisher); err != nil {
		return update.Release{}, fmt.Errorf("authorize machine publisher: %w", err)
	}
	if _, err := source.policy.Accept(request.Replay, release); err != nil {
		return update.Release{}, fmt.Errorf("reject machine release replay: %w", err)
	}
	candidate, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(source.sku), release.Payload().Version)
	if err != nil {
		return update.Release{}, ErrUnauthorizedCandidate
	}
	if candidate.ProductCode != installed.ProductCode {
		if err := mapi.ValidateMachinePackageSuccessor(installed, candidate); err != nil {
			return update.Release{}, ErrUnauthorizedCandidate
		}
	}
	return release, nil
}
