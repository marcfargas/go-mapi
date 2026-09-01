package main

// This file deliberately contains authorization only.  It never launches an
// installer, prompts for elevation, writes HKLM, or treats GitHub transport as
// a trust decision; those responsibilities stay with their respective tickets.

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"path"
	"strings"
	"time"

	"github.com/Masterminds/semver/v3"
)

const adminReleaseEnvelopeSchema = "go-mapi-admin-envelope-v1"

type adminReleaseKeyRole struct {
	Keys      map[string]string `json:"keys"`
	Threshold int               `json:"threshold"`
}

// adminReleaseRoot is public bootstrap data shipped with the user app.
type adminReleaseRoot struct {
	Schema        string              `json:"schema"`
	Version       int                 `json:"version"`
	AllowedOrigin string              `json:"allowedOrigin"`
	Root          adminReleaseKeyRole `json:"root"`
	Targets       adminReleaseKeyRole `json:"targets"`
}

type adminReleaseSignature struct {
	KeyID     string `json:"keyId"`
	Signature string `json:"signature"`
}

type adminReleaseEnvelope struct {
	Schema     string                  `json:"schema"`
	Signed     string                  `json:"signed"`
	Signatures []adminReleaseSignature `json:"signatures"`
}

type adminReleaseRequires struct {
	Component    string `json:"component"`
	MinInclusive string `json:"minInclusive"`
	MaxExclusive string `json:"maxExclusive"`
}

type adminReleaseArtifact struct {
	URL    string `json:"url"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

type adminReleasePublisherPolicy struct {
	Publisher string   `json:"publisher"`
	EKUs      []string `json:"ekus"`
	PolicyID  string   `json:"policyId"`
}

type adminReleasePayload struct {
	Schema        string                      `json:"schema"`
	Component     string                      `json:"component"`
	Version       string                      `json:"version"`
	QueueProtocol string                      `json:"queueProtocol"`
	Requires      adminReleaseRequires        `json:"requires"`
	Sequence      uint64                      `json:"sequence"`
	IssuedAt      string                      `json:"issuedAt"`
	ExpiresAt     string                      `json:"expiresAt"`
	Artifact      adminReleaseArtifact        `json:"artifact"`
	Publisher     adminReleasePublisherPolicy `json:"publisher"`
}

type authorizedAdminRelease struct {
	Payload adminReleasePayload
	Bytes   []byte
	Digest  string
}

type adminReleaseReplayState struct {
	Sequence uint64 `json:"sequence"`
	Digest   string `json:"digest"`
}

// acceptAdminReleaseSequence is storage-independent so callers can atomically
// persist the returned state only after all verification has succeeded.
func acceptAdminReleaseSequence(previous adminReleaseReplayState, candidate authorizedAdminRelease) (adminReleaseReplayState, error) {
	if candidate.Payload.Sequence < previous.Sequence {
		return adminReleaseReplayState{}, errors.New("admin release downgrade rejected")
	}
	if candidate.Payload.Sequence == previous.Sequence && previous.Sequence != 0 && previous.Digest != candidate.Digest {
		return adminReleaseReplayState{}, errors.New("admin release replay mismatch rejected")
	}
	return adminReleaseReplayState{Sequence: candidate.Payload.Sequence, Digest: candidate.Digest}, nil
}

func verifyAdminRelease(root adminReleaseRoot, envelopeBytes []byte, appVersion string, now time.Time) (authorizedAdminRelease, error) {
	if root.Schema != "go-mapi-admin-root-v1" || root.Version < 1 || root.AllowedOrigin == "" {
		return authorizedAdminRelease{}, errors.New("invalid trusted admin release root")
	}
	if err := validAdminReleaseRole(root.Targets); err != nil {
		return authorizedAdminRelease{}, fmt.Errorf("invalid targets role: %w", err)
	}
	var envelope adminReleaseEnvelope
	if err := decodeAdminReleaseJSON(envelopeBytes, &envelope); err != nil {
		return authorizedAdminRelease{}, fmt.Errorf("invalid admin release envelope: %w", err)
	}
	if envelope.Schema != adminReleaseEnvelopeSchema {
		return authorizedAdminRelease{}, errors.New("unsupported admin release envelope")
	}
	signed, err := base64.RawURLEncoding.DecodeString(envelope.Signed)
	if err != nil || len(signed) == 0 {
		return authorizedAdminRelease{}, errors.New("invalid signed admin release payload")
	}
	if err := verifyAdminReleaseSignatures(root.Targets, signed, envelope.Signatures); err != nil {
		return authorizedAdminRelease{}, err
	}
	var payload adminReleasePayload
	if err := decodeAdminReleaseJSON(signed, &payload); err != nil {
		return authorizedAdminRelease{}, fmt.Errorf("invalid signed admin release payload: %w", err)
	}
	if err := validateAdminReleasePayload(root, payload, appVersion, now); err != nil {
		return authorizedAdminRelease{}, err
	}
	digest := sha256.Sum256(signed)
	return authorizedAdminRelease{Payload: payload, Bytes: signed, Digest: hex.EncodeToString(digest[:])}, nil
}

func decodeAdminReleaseJSON(data []byte, value any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return errors.New("trailing JSON value")
	}
	return nil
}

// verifyAdminReleaseRootUpdate accepts a new root only when the old and new
// root roles both meet their thresholds. This is the deliberate key-rotation
// overlap; merely adding a new key to an untrusted document never works.
func verifyAdminReleaseRootUpdate(current adminReleaseRoot, envelopeBytes []byte) (adminReleaseRoot, error) {
	if err := validAdminReleaseRole(current.Root); err != nil {
		return adminReleaseRoot{}, err
	}
	var envelope adminReleaseEnvelope
	if err := decodeAdminReleaseJSON(envelopeBytes, &envelope); err != nil || envelope.Schema != adminReleaseEnvelopeSchema {
		return adminReleaseRoot{}, errors.New("invalid admin root update envelope")
	}
	signed, err := base64.RawURLEncoding.DecodeString(envelope.Signed)
	if err != nil || len(signed) == 0 {
		return adminReleaseRoot{}, errors.New("invalid signed root update")
	}
	if err := verifyAdminReleaseSignatures(current.Root, signed, envelope.Signatures); err != nil {
		return adminReleaseRoot{}, err
	}
	var incoming adminReleaseRoot
	if err := decodeAdminReleaseJSON(signed, &incoming); err != nil || incoming.Schema != current.Schema || incoming.Version <= current.Version || incoming.AllowedOrigin != current.AllowedOrigin {
		return adminReleaseRoot{}, errors.New("invalid incoming admin root")
	}
	if err := validAdminReleaseRole(incoming.Root); err != nil {
		return adminReleaseRoot{}, err
	}
	if err := validAdminReleaseRole(incoming.Targets); err != nil {
		return adminReleaseRoot{}, err
	}
	if err := verifyAdminReleaseSignatures(incoming.Root, signed, envelope.Signatures); err != nil {
		return adminReleaseRoot{}, err
	}
	return incoming, nil
}

func validAdminReleaseRole(role adminReleaseKeyRole) error {
	if role.Threshold < 1 || len(role.Keys) < role.Threshold {
		return errors.New("invalid threshold")
	}
	for id, encoded := range role.Keys {
		key, err := base64.RawURLEncoding.DecodeString(encoded)
		if id == "" || err != nil || len(key) != ed25519.PublicKeySize {
			return errors.New("invalid public key")
		}
	}
	return nil
}

func verifyAdminReleaseSignatures(role adminReleaseKeyRole, signed []byte, signatures []adminReleaseSignature) error {
	seen, good := map[string]bool{}, 0
	for _, signature := range signatures {
		if seen[signature.KeyID] {
			continue
		}
		seen[signature.KeyID] = true
		encoded, ok := role.Keys[signature.KeyID]
		if !ok {
			continue
		}
		key, _ := base64.RawURLEncoding.DecodeString(encoded)
		sig, err := base64.RawURLEncoding.DecodeString(signature.Signature)
		if err == nil && ed25519.Verify(ed25519.PublicKey(key), signed, sig) {
			good++
		}
	}
	if good < role.Threshold {
		return errors.New("admin release signature threshold not met")
	}
	return nil
}

func validateAdminReleasePayload(root adminReleaseRoot, payload adminReleasePayload, appVersion string, now time.Time) error {
	if payload.Schema != "go-mapi-admin-targets-v1" || payload.Component != "interceptor" || payload.QueueProtocol != "queue-v1" || payload.Sequence == 0 {
		return errors.New("invalid admin release identity")
	}
	if _, err := semver.StrictNewVersion(payload.Version); err != nil || strings.Contains(payload.Version, "+") {
		return errors.New("invalid admin release version")
	}
	app, err := semver.StrictNewVersion(appVersion)
	if err != nil {
		return errors.New("invalid installed app version")
	}
	if payload.Requires.Component != "app" {
		return errors.New("invalid counterpart component")
	}
	min, err := semver.StrictNewVersion(payload.Requires.MinInclusive)
	if err != nil {
		return errors.New("invalid app compatibility range")
	}
	max, err := semver.StrictNewVersion(payload.Requires.MaxExclusive)
	if err != nil || !min.LessThan(max) {
		return errors.New("invalid app compatibility range")
	}
	if app.LessThan(min) || !app.LessThan(max) {
		return errors.New("app version is incompatible")
	}
	issued, err := time.Parse(time.RFC3339, payload.IssuedAt)
	if err != nil || !strings.HasSuffix(payload.IssuedAt, "Z") {
		return errors.New("invalid issue time")
	}
	expires, err := time.Parse(time.RFC3339, payload.ExpiresAt)
	if err != nil || !strings.HasSuffix(payload.ExpiresAt, "Z") || !expires.After(issued) || expires.Sub(issued) > 31*24*time.Hour || !now.Before(expires) || issued.After(now.Add(5*time.Minute)) {
		return errors.New("expired or invalid admin release lifetime")
	}
	u, err := url.Parse(payload.Artifact.URL)
	if err != nil || !isImmutableAdminMSIURL(root.AllowedOrigin, payload.Version, u) {
		return errors.New("unauthorized admin artifact URL")
	}
	if payload.Artifact.Size < 1 || len(payload.Artifact.SHA256) != 64 || payload.Artifact.SHA256 != strings.ToLower(payload.Artifact.SHA256) {
		return errors.New("invalid admin artifact")
	}
	if _, err := hex.DecodeString(payload.Artifact.SHA256); err != nil {
		return errors.New("invalid admin artifact hash")
	}
	if payload.Publisher.Publisher == "" || payload.Publisher.PolicyID == "" || len(payload.Publisher.EKUs) < 2 || !containsString(payload.Publisher.EKUs, "1.3.6.1.5.5.7.3.3") {
		return errors.New("invalid publisher policy")
	}
	seenEKU := make(map[string]struct{}, len(payload.Publisher.EKUs))
	for _, eku := range payload.Publisher.EKUs {
		if eku == "" {
			return errors.New("invalid publisher policy")
		}
		if _, duplicate := seenEKU[eku]; duplicate {
			return errors.New("invalid publisher policy")
		}
		seenEKU[eku] = struct{}{}
	}
	return nil
}

// isImmutableAdminMSIURL is the metadata-time constraint. In contrast to the
// redirect predicate below, an authorized artifact must name the canonical,
// versioned MSI itself: neither an origin/root URL nor an alias can become an
// authorization handle.
func isImmutableAdminMSIURL(allowedOrigin, version string, candidate *url.URL) bool {
	if !isAllowedAdminArtifactURL(allowedOrigin, candidate) || candidate == nil {
		return false
	}
	origin, err := url.Parse(allowedOrigin)
	if err != nil {
		return false
	}
	base := path.Clean(origin.Path)
	if base == "." || base == "/" {
		base = ""
	}
	want := path.Join(base, "admin-v"+version, "go-mapi-interceptor.msi")
	return candidate.Path == want
}

func containsString(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

// isAllowedAdminArtifactURL validates both a metadata URL and every redirect
// destination. Paths must remain below the configured path boundary; a string
// prefix alone would accept /releases-evil or /releases/../outside.
func isAllowedAdminArtifactURL(allowedOrigin string, candidate *url.URL) bool {
	origin, err := url.Parse(allowedOrigin)
	if err != nil || candidate == nil || origin.Scheme != "https" || origin.Host == "" || origin.User != nil || origin.RawQuery != "" || origin.Fragment != "" {
		return false
	}
	if candidate.Scheme != origin.Scheme || !strings.EqualFold(candidate.Host, origin.Host) || candidate.User != nil || candidate.RawQuery != "" || candidate.Fragment != "" {
		return false
	}
	base := path.Clean(origin.Path)
	if base == "." {
		base = "/"
	}
	item := path.Clean(candidate.Path)
	lowerItem := strings.ToLower(item)
	if !strings.HasPrefix(item, "/") || (base != "/" && item != base && !strings.HasPrefix(item, base+"/")) || item == "/latest" || strings.Contains(lowerItem, "/latest/") || strings.HasSuffix(lowerItem, "/latest") {
		return false
	}
	return true
}
