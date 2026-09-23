package update

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

const maxRedirects = 3

// Download fetches only the immutable URL already authorized into release.
// Every redirect and the final response remain inside the same trusted origin.
func (p Policy) Download(ctx context.Context, client *http.Client, release Release, now time.Time) ([]byte, error) {
	if release.ns != p.sku {
		return nil, errors.New("release policy namespace mismatch")
	}
	if err := p.validatePayload(release.payload, compatibilityVersions(release.payload), now); err != nil {
		return nil, fmt.Errorf("revalidate authorized release: %w", err)
	}
	if client == nil {
		client = http.DefaultClient
	}
	copyClient := *client
	previousRedirect := copyClient.CheckRedirect
	copyClient.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if len(via) > maxRedirects || !p.isAllowedURL(request.URL) {
			return errors.New("unauthorized artifact redirect")
		}
		if previousRedirect != nil {
			return previousRedirect(request, via)
		}
		return nil
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, release.payload.Artifact.URL, nil)
	if err != nil {
		return nil, err
	}
	response, err := copyClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("download authorized artifact: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || !p.isAllowedURL(response.Request.URL) {
		return nil, errors.New("unauthorized artifact response")
	}
	if response.ContentLength >= 0 && response.ContentLength != release.payload.Artifact.Size {
		return nil, errors.New("artifact content length does not match metadata")
	}
	contents, err := io.ReadAll(io.LimitReader(response.Body, release.payload.Artifact.Size+1))
	if err != nil {
		return nil, fmt.Errorf("read authorized artifact: %w", err)
	}
	if err := release.VerifyBytes(contents); err != nil {
		return nil, err
	}
	return contents, nil
}

// Revalidation only needs versions already signed into an authorized payload;
// it must not consult a new caller-controlled compatibility set.
func compatibilityVersions(payload Payload) map[string]string {
	versions := make(map[string]string, len(payload.Compatibility)+1)
	if payload.Requires.Component != "" {
		versions[payload.Requires.Component] = payload.Requires.MinInclusive
	}
	for _, requirement := range payload.Compatibility {
		versions[requirement.Component] = requirement.MinInclusive
	}
	return versions
}
