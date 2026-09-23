// Package update authenticates immutable go-mapi release metadata and artifact
// bytes. It deliberately does not choose an installation path, inspect a
// platform signature, persist state, or launch an installer.
package update

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
	"github.com/marcfargas/go-mapi/internal/mapi"
)

const (
	EnvelopeSchema       = "go-mapi-admin-envelope-v1"
	LegacyRootSchema     = "go-mapi-admin-root-v1"
	LegacyTargetsSchema  = "go-mapi-admin-targets-v1"
	MachineRootSchema    = "go-mapi-machine-root-v1"
	MachineTargetsSchema = "go-mapi-machine-targets-v1"
)

// SKU closes release authorization over the three supported namespaces.
type SKU string

const (
	LegacyAdmin SKU = "admin"
	System      SKU = "system"
	Suite       SKU = "suite"
)

type KeyRole struct {
	Keys      map[string]string `json:"keys"`
	Threshold int               `json:"threshold"`
}

// Root is trusted bootstrap data embedded in a signed executable.
type Root struct {
	Schema        string  `json:"schema"`
	Version       int     `json:"version"`
	AllowedOrigin string  `json:"allowedOrigin"`
	Root          KeyRole `json:"root"`
	Targets       KeyRole `json:"targets"`
}

type Signature struct {
	KeyID     string `json:"keyId"`
	Signature string `json:"signature"`
}

type Envelope struct {
	Schema     string      `json:"schema"`
	Signed     string      `json:"signed"`
	Signatures []Signature `json:"signatures"`
}

type Requirement struct {
	Component    string `json:"component"`
	MinInclusive string `json:"minInclusive"`
	MaxExclusive string `json:"maxExclusive"`
}

type ContainedComponent struct {
	Component string `json:"component"`
	Version   string `json:"version"`
}

type Artifact struct {
	URL    string `json:"url"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

type PublisherPolicy struct {
	Publisher string   `json:"publisher"`
	EKUs      []string `json:"ekus"`
	PolicyID  string   `json:"policyId"`
}

// Payload supports the shipped legacy bootstrap schema and the two fixed
// machine-package schemas. Fields unused by a schema must remain empty.
type Payload struct {
	Schema        string               `json:"schema"`
	SKU           SKU                  `json:"sku,omitempty"`
	UpgradeCode   string               `json:"upgradeCode,omitempty"`
	Component     string               `json:"component,omitempty"`
	Version       string               `json:"version"`
	QueueProtocol string               `json:"queueProtocol"`
	Requires      Requirement          `json:"requires,omitempty"`
	Contained     []ContainedComponent `json:"contained,omitempty"`
	Compatibility []Requirement        `json:"compatibility,omitempty"`
	Sequence      uint64               `json:"sequence"`
	IssuedAt      string               `json:"issuedAt"`
	ExpiresAt     string               `json:"expiresAt"`
	Artifact      Artifact             `json:"artifact"`
	Publisher     PublisherPolicy      `json:"publisher"`
}

// Release is metadata authorized by one Policy. Its URL and signer policy are
// signed data; callers cannot replace either through this API.
type Release struct {
	payload Payload
	bytes   []byte
	digest  string
	ns      SKU
}

func (r Release) Namespace() string { return string(r.ns) }
func (r Release) Sequence() uint64  { return r.payload.Sequence }
func (r Release) Digest() string    { return r.digest }

func (r Release) Payload() Payload {
	payload := r.payload
	payload.Contained = append([]ContainedComponent(nil), payload.Contained...)
	payload.Compatibility = append([]Requirement(nil), payload.Compatibility...)
	payload.Publisher.EKUs = append([]string(nil), payload.Publisher.EKUs...)
	return payload
}

func (r Release) SignedBytes() []byte { return append([]byte(nil), r.bytes...) }

// VerifyBytes revalidates bytes after download or after re-opening a staged
// artifact, closing the substitution window at adapter boundaries.
func (r Release) VerifyBytes(contents []byte) error {
	if int64(len(contents)) != r.payload.Artifact.Size {
		return errors.New("artifact size does not match signed metadata")
	}
	sum := sha256.Sum256(contents)
	if hex.EncodeToString(sum[:]) != r.payload.Artifact.SHA256 {
		return errors.New("artifact hash does not match signed metadata")
	}
	return nil
}

// VerifyReader provides the same check for a freshly re-opened artifact.
func (r Release) VerifyReader(reader io.Reader) error {
	if reader == nil {
		return errors.New("artifact reader is nil")
	}
	contents, err := io.ReadAll(io.LimitReader(reader, r.payload.Artifact.Size+1))
	if err != nil {
		return fmt.Errorf("read artifact for verification: %w", err)
	}
	return r.VerifyBytes(contents)
}

type ReplayState struct {
	Namespace string `json:"namespace,omitempty"`
	Sequence  uint64 `json:"sequence"`
	Digest    string `json:"digest"`
}

// Policy is created only for a fixed release namespace. Its fields are
// intentionally private so an adapter cannot replace URL or identity rules.
type Policy struct {
	sku  SKU
	root Root
}

func NewLegacyAdminPolicy(root Root) (Policy, error) {
	return newPolicy(LegacyAdmin, root)
}

func NewMachinePolicy(sku SKU, root Root) (Policy, error) {
	if sku != System && sku != Suite {
		return Policy{}, fmt.Errorf("unsupported machine release SKU %q", sku)
	}
	return newPolicy(sku, root)
}

func newPolicy(sku SKU, root Root) (Policy, error) {
	wantSchema := MachineRootSchema
	if sku == LegacyAdmin {
		wantSchema = LegacyRootSchema
	}
	if root.Schema != wantSchema || root.Version < 1 || !validOrigin(root.AllowedOrigin) {
		return Policy{}, errors.New("invalid trusted release root")
	}
	if err := validRole(root.Root); err != nil {
		return Policy{}, fmt.Errorf("invalid root role: %w", err)
	}
	if err := validRole(root.Targets); err != nil {
		return Policy{}, fmt.Errorf("invalid targets role: %w", err)
	}
	return Policy{sku: sku, root: root}, nil
}

func ParseLegacyAdminPolicy(rootBytes []byte) (Policy, error) {
	var root Root
	if err := decodeJSON(rootBytes, &root); err != nil {
		return Policy{}, fmt.Errorf("decode trusted release root: %w", err)
	}
	return NewLegacyAdminPolicy(root)
}

func (p Policy) Root() Root { return p.root }

func (p Policy) Authorize(envelopeBytes []byte, installed map[string]string, now time.Time) (Release, error) {
	if p.sku == "" {
		return Release{}, errors.New("release policy is not initialized")
	}
	var envelope Envelope
	if err := decodeJSON(envelopeBytes, &envelope); err != nil {
		return Release{}, fmt.Errorf("invalid release envelope: %w", err)
	}
	if envelope.Schema != EnvelopeSchema {
		return Release{}, errors.New("unsupported release envelope")
	}
	signed, err := base64.RawURLEncoding.DecodeString(envelope.Signed)
	if err != nil || len(signed) == 0 {
		return Release{}, errors.New("invalid signed release payload")
	}
	if err := verifySignatures(p.root.Targets, signed, envelope.Signatures); err != nil {
		return Release{}, err
	}
	var payload Payload
	if err := decodeJSON(signed, &payload); err != nil {
		return Release{}, fmt.Errorf("invalid signed release payload: %w", err)
	}
	if err := p.validatePayload(payload, installed, now); err != nil {
		return Release{}, err
	}
	digest := sha256.Sum256(signed)
	return Release{payload: payload, bytes: append([]byte(nil), signed...), digest: hex.EncodeToString(digest[:]), ns: p.sku}, nil
}

func (p Policy) Accept(previous ReplayState, candidate Release) (ReplayState, error) {
	if candidate.ns != p.sku || (previous.Namespace != "" && previous.Namespace != string(p.sku)) {
		return ReplayState{}, errors.New("release replay namespace mismatch")
	}
	return AcceptReplay(previous, candidate)
}

// AcceptReplay is storage-independent. Adapters persist its result only after
// every verification step required at their boundary has succeeded.
func AcceptReplay(previous ReplayState, candidate Release) (ReplayState, error) {
	if candidate.ns == "" || (previous.Namespace != "" && previous.Namespace != string(candidate.ns)) {
		return ReplayState{}, errors.New("release replay namespace mismatch")
	}
	if candidate.payload.Sequence < previous.Sequence {
		return ReplayState{}, errors.New("release downgrade rejected")
	}
	if candidate.payload.Sequence == previous.Sequence && previous.Sequence != 0 && previous.Digest != candidate.digest {
		return ReplayState{}, errors.New("release replay mismatch rejected")
	}
	namespace := string(candidate.ns)
	if candidate.ns == LegacyAdmin {
		namespace = ""
	}
	return ReplayState{Namespace: namespace, Sequence: candidate.payload.Sequence, Digest: candidate.digest}, nil
}

// VerifyRootUpdate accepts a rotated root only when both the currently trusted
// and incoming root roles meet their thresholds.
func VerifyRootUpdate(current Root, envelopeBytes []byte) (Root, error) {
	if err := validRole(current.Root); err != nil {
		return Root{}, err
	}
	var envelope Envelope
	if err := decodeJSON(envelopeBytes, &envelope); err != nil || envelope.Schema != EnvelopeSchema {
		return Root{}, errors.New("invalid root update envelope")
	}
	signed, err := base64.RawURLEncoding.DecodeString(envelope.Signed)
	if err != nil || len(signed) == 0 {
		return Root{}, errors.New("invalid signed root update")
	}
	if err := verifySignatures(current.Root, signed, envelope.Signatures); err != nil {
		return Root{}, err
	}
	var incoming Root
	if err := decodeJSON(signed, &incoming); err != nil || incoming.Schema != current.Schema || incoming.Version <= current.Version || incoming.AllowedOrigin != current.AllowedOrigin {
		return Root{}, errors.New("invalid incoming root")
	}
	if err := validRole(incoming.Root); err != nil {
		return Root{}, err
	}
	if err := validRole(incoming.Targets); err != nil {
		return Root{}, err
	}
	if err := verifySignatures(incoming.Root, signed, envelope.Signatures); err != nil {
		return Root{}, err
	}
	return incoming, nil
}

func (p Policy) validatePayload(payload Payload, installed map[string]string, now time.Time) error {
	if payload.QueueProtocol != "queue-v1" || payload.Sequence == 0 {
		return errors.New("invalid release identity")
	}
	if _, err := semver.StrictNewVersion(payload.Version); err != nil || strings.Contains(payload.Version, "+") {
		return errors.New("invalid release version")
	}
	if err := validateLifetime(payload, now); err != nil {
		return err
	}
	if err := validateArtifact(payload.Artifact); err != nil {
		return err
	}
	if err := validatePublisher(payload.Publisher); err != nil {
		return err
	}

	switch p.sku {
	case LegacyAdmin:
		if payload.Schema != LegacyTargetsSchema || payload.SKU != "" || payload.UpgradeCode != "" || payload.Component != "interceptor" || len(payload.Contained) != 0 || len(payload.Compatibility) != 0 {
			return errors.New("invalid legacy admin release identity")
		}
		if err := validateRequirements([]Requirement{payload.Requires}, installed); err != nil {
			return err
		}
		if !p.isImmutableArtifactURL(payload.Artifact.URL, "admin-v"+payload.Version, "go-mapi-interceptor.msi") {
			return errors.New("unauthorized admin artifact URL")
		}
	case System, Suite:
		if payload.Schema != MachineTargetsSchema || payload.SKU != p.sku || payload.Component != "" || payload.Requires != (Requirement{}) {
			return errors.New("wrong machine release SKU")
		}
		identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(p.sku), payload.Version)
		if err != nil || payload.Sequence != identity.Sequence || payload.UpgradeCode != upgradeCode(p.sku) {
			return errors.New("invalid machine release identity")
		}
		if !p.isImmutableArtifactURL(payload.Artifact.URL, identity.Tag, identity.AssetName) {
			return errors.New("unauthorized machine artifact URL")
		}
		if err := validateContained(p.sku, payload.Contained); err != nil {
			return err
		}
		if err := validateCompatibilitySet(payload.Contained, payload.Compatibility); err != nil {
			return err
		}
		if err := validateRequirements(payload.Compatibility, installed); err != nil {
			return err
		}
	default:
		return errors.New("invalid release policy")
	}
	return nil
}

func validateCompatibilitySet(contained []ContainedComponent, requirements []Requirement) error {
	if len(contained) != len(requirements) {
		return errors.New("contained compatibility set is incomplete")
	}
	want := make(map[string]struct{}, len(contained))
	for _, component := range contained {
		want[component.Component] = struct{}{}
	}
	for _, requirement := range requirements {
		if _, ok := want[requirement.Component]; !ok {
			return errors.New("contained compatibility set has an unknown component")
		}
	}
	return nil
}

func upgradeCode(sku SKU) string {
	if sku == System {
		return "B3C97B33-3F10-47CA-9FA7-24EE3B75E325"
	}
	return "2E050A24-94A2-4FC9-B176-C5CCC1225FE6"
}

func validateContained(sku SKU, components []ContainedComponent) error {
	want := map[string]bool{"service": false, "interceptor": false}
	if sku == Suite {
		want["app"] = false
	}
	for _, component := range components {
		if _, ok := want[component.Component]; !ok || want[component.Component] {
			return errors.New("invalid contained component set")
		}
		if _, err := semver.StrictNewVersion(component.Version); err != nil {
			return errors.New("invalid contained component version")
		}
		want[component.Component] = true
	}
	for _, present := range want {
		if !present {
			return errors.New("incomplete contained component set")
		}
	}
	return nil
}

func validateRequirements(requirements []Requirement, installed map[string]string) error {
	if len(requirements) == 0 {
		return errors.New("missing compatibility requirements")
	}
	seen := make(map[string]struct{}, len(requirements))
	for _, requirement := range requirements {
		if requirement.Component == "" {
			return errors.New("invalid compatibility requirement")
		}
		if _, duplicate := seen[requirement.Component]; duplicate {
			return errors.New("duplicate compatibility requirement")
		}
		seen[requirement.Component] = struct{}{}
		minimum, err := semver.StrictNewVersion(requirement.MinInclusive)
		if err != nil {
			return errors.New("invalid compatibility range")
		}
		maximum, err := semver.StrictNewVersion(requirement.MaxExclusive)
		if err != nil || !minimum.LessThan(maximum) {
			return errors.New("invalid compatibility range")
		}
		current, err := semver.StrictNewVersion(installed[requirement.Component])
		if err != nil || current.LessThan(minimum) || !current.LessThan(maximum) {
			return fmt.Errorf("installed %s version is incompatible", requirement.Component)
		}
	}
	return nil
}

func validateLifetime(payload Payload, now time.Time) error {
	issued, err := time.Parse(time.RFC3339, payload.IssuedAt)
	if err != nil || !strings.HasSuffix(payload.IssuedAt, "Z") {
		return errors.New("invalid issue time")
	}
	expires, err := time.Parse(time.RFC3339, payload.ExpiresAt)
	if err != nil || !strings.HasSuffix(payload.ExpiresAt, "Z") || !expires.After(issued) || expires.Sub(issued) > 31*24*time.Hour || !now.Before(expires) || issued.After(now.Add(5*time.Minute)) {
		return errors.New("expired or invalid release lifetime")
	}
	return nil
}

func validateArtifact(artifact Artifact) error {
	if artifact.Size < 1 || len(artifact.SHA256) != sha256.Size*2 || artifact.SHA256 != strings.ToLower(artifact.SHA256) {
		return errors.New("invalid release artifact")
	}
	if _, err := hex.DecodeString(artifact.SHA256); err != nil {
		return errors.New("invalid release artifact hash")
	}
	return nil
}

func validatePublisher(policy PublisherPolicy) error {
	if policy.Publisher == "" || policy.PolicyID == "" || len(policy.EKUs) < 2 || !contains(policy.EKUs, "1.3.6.1.5.5.7.3.3") {
		return errors.New("invalid publisher policy")
	}
	seen := make(map[string]struct{}, len(policy.EKUs))
	for _, eku := range policy.EKUs {
		if eku == "" {
			return errors.New("invalid publisher policy")
		}
		if _, duplicate := seen[eku]; duplicate {
			return errors.New("invalid publisher policy")
		}
		seen[eku] = struct{}{}
	}
	return nil
}

func (p Policy) isImmutableArtifactURL(raw, tag, asset string) bool {
	candidate, err := url.Parse(raw)
	if err != nil || !p.isAllowedURL(candidate) {
		return false
	}
	origin, _ := url.Parse(p.root.AllowedOrigin)
	base := path.Clean(origin.Path)
	if base == "." || base == "/" {
		base = ""
	}
	return candidate.Path == path.Join(base, tag, asset)
}

func validOrigin(raw string) bool {
	origin, err := url.Parse(raw)
	return err == nil && origin.Scheme == "https" && origin.Host != "" && origin.User == nil && origin.RawQuery == "" && origin.Fragment == ""
}

func (p Policy) isAllowedURL(candidate *url.URL) bool {
	origin, err := url.Parse(p.root.AllowedOrigin)
	if err != nil || candidate == nil || candidate.Scheme != origin.Scheme || !strings.EqualFold(candidate.Host, origin.Host) || candidate.User != nil || candidate.RawQuery != "" || candidate.Fragment != "" {
		return false
	}
	base, item := path.Clean(origin.Path), path.Clean(candidate.Path)
	if base == "." {
		base = "/"
	}
	lowerItem := strings.ToLower(item)
	return strings.HasPrefix(item, "/") && (base == "/" || item == base || strings.HasPrefix(item, base+"/")) && item != "/latest" && !strings.Contains(lowerItem, "/latest/") && !strings.HasSuffix(lowerItem, "/latest")
}

func validRole(role KeyRole) error {
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

func verifySignatures(role KeyRole, signed []byte, signatures []Signature) error {
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
		return errors.New("release signature threshold not met")
	}
	return nil
}

func decodeJSON(data []byte, value any) error {
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

// DecodeJSON is the strict decoder used by adapters for trusted bootstrap and
// persisted replay-state documents.
func DecodeJSON(data []byte, value any) error { return decodeJSON(data, value) }

// IsAllowedURL exposes the origin-bound redirect predicate without exposing a
// way to change a Policy's immutable artifact identity.
func IsAllowedURL(allowedOrigin string, candidate *url.URL) bool {
	policy := Policy{root: Root{AllowedOrigin: allowedOrigin}}
	return validOrigin(allowedOrigin) && policy.isAllowedURL(candidate)
}

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}
