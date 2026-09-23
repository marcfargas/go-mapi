package main

// The app keeps only compatibility aliases and adapters for the shared release
// trust core. LocalAppData persistence, staging, UI and elevation remain owned
// by this package.

import (
	"net/url"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

const adminReleaseEnvelopeSchema = update.EnvelopeSchema

type adminReleaseKeyRole = update.KeyRole
type adminReleaseRoot = update.Root
type adminReleaseSignature = update.Signature
type adminReleaseEnvelope = update.Envelope
type adminReleaseRequires = update.Requirement
type adminReleaseArtifact = update.Artifact
type adminReleasePublisherPolicy = update.PublisherPolicy
type adminReleasePayload = update.Payload
type adminReleaseReplayState = update.ReplayState

type authorizedAdminRelease struct {
	Payload adminReleasePayload
	Bytes   []byte
	Digest  string
	trusted update.Release
}

func acceptAdminReleaseSequence(previous adminReleaseReplayState, candidate authorizedAdminRelease) (adminReleaseReplayState, error) {
	return update.AcceptReplay(previous, candidate.trusted)
}

func verifyAdminRelease(root adminReleaseRoot, envelopeBytes []byte, appVersion string, now time.Time) (authorizedAdminRelease, error) {
	policy, err := update.NewLegacyAdminPolicy(root)
	if err != nil {
		return authorizedAdminRelease{}, err
	}
	release, err := policy.Authorize(envelopeBytes, map[string]string{"app": appVersion}, now)
	if err != nil {
		return authorizedAdminRelease{}, err
	}
	return authorizedAdminRelease{Payload: release.Payload(), Bytes: release.SignedBytes(), Digest: release.Digest(), trusted: release}, nil
}

func verifyAdminReleaseRootUpdate(current adminReleaseRoot, envelopeBytes []byte) (adminReleaseRoot, error) {
	return update.VerifyRootUpdate(current, envelopeBytes)
}

func decodeAdminReleaseJSON(data []byte, value any) error {
	return update.DecodeJSON(data, value)
}

func isAllowedAdminArtifactURL(allowedOrigin string, candidate *url.URL) bool {
	return update.IsAllowedURL(allowedOrigin, candidate)
}
