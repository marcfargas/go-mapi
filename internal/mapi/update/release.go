package update

import (
	"bytes"
	"crypto/sha256"
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
	LegacyTargetsSchema  = "go-mapi-admin-targets-v1"
	MachineTargetsSchema = "go-mapi-machine-targets-v1"
)

var MachineArtifactOrigin = "https://github.com/marcfargas/go-mapi/releases/download/"

type SKU string

const (
	App         SKU = "app"
	LegacyAdmin SKU = "admin"
	System      SKU = "system"
	Suite       SKU = "suite"
)

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
type Payload struct {
	Schema        string               `json:"schema"`
	SKU           SKU                  `json:"sku,omitempty"`
	ProductCode   string               `json:"productCode,omitempty"`
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
}

type Release struct {
	payload   Payload
	digest    string
	ns        SKU
	engine    *Engine
	installed map[string]string
}

func (r Release) Namespace() string { return string(r.ns) }
func (r Release) Sequence() uint64  { return r.payload.Sequence }
func (r Release) Digest() string    { return r.digest }
func (r Release) Payload() Payload {
	p := r.payload
	p.Contained = append([]ContainedComponent(nil), p.Contained...)
	p.Compatibility = append([]Requirement(nil), p.Compatibility...)
	return p
}
func (r Release) VerifyBytes(b []byte) error {
	if int64(len(b)) != r.payload.Artifact.Size {
		return errors.New("artifact size mismatch")
	}
	sum := sha256.Sum256(b)
	if hex.EncodeToString(sum[:]) != r.payload.Artifact.SHA256 {
		return errors.New("artifact hash mismatch")
	}
	return nil
}
func (r Release) VerifyReader(reader io.Reader) error {
	if reader == nil || r.payload.Artifact.Size < 1 {
		return errors.New("invalid artifact reader")
	}
	h := sha256.New()
	if _, err := io.CopyN(h, reader, r.payload.Artifact.Size); err != nil {
		return err
	}
	var extra [1]byte
	if _, err := reader.Read(extra[:]); err != io.EOF {
		if err == nil {
			return errors.New("artifact size mismatch")
		}
		return err
	}
	if hex.EncodeToString(h.Sum(nil)) != r.payload.Artifact.SHA256 {
		return errors.New("artifact hash mismatch")
	}
	return nil
}

type ReplayState struct {
	Namespace string `json:"namespace,omitempty"`
	Sequence  uint64 `json:"sequence"`
	Digest    string `json:"digest"`
}

func AcceptReplay(previous ReplayState, candidate Release) (ReplayState, error) {
	if candidate.ns == "" || previous.Namespace != "" && previous.Namespace != string(candidate.ns) {
		return ReplayState{}, errors.New("release replay namespace mismatch")
	}
	if candidate.payload.Sequence < previous.Sequence {
		return ReplayState{}, errors.New("release downgrade rejected")
	}
	if candidate.payload.Sequence == previous.Sequence && previous.Sequence != 0 && previous.Digest != candidate.digest {
		return ReplayState{}, errors.New("release replay mismatch rejected")
	}
	ns := string(candidate.ns)
	if candidate.ns == LegacyAdmin {
		ns = ""
	}
	return ReplayState{Namespace: ns, Sequence: candidate.payload.Sequence, Digest: candidate.digest}, nil
}

func ParseTarget(sku SKU, raw []byte, installed map[string]string, now time.Time, artifactOrigin string) (Release, error) {
	if sku != LegacyAdmin && sku != System && sku != Suite {
		return Release{}, errors.New("invalid target SKU")
	}
	var payload Payload
	if err := DecodeJSON(raw, &payload); err != nil {
		return Release{}, fmt.Errorf("invalid target: %w", err)
	}
	if err := validatePayload(sku, payload, installed, now, artifactOrigin); err != nil {
		return Release{}, err
	}
	sum := sha256.Sum256(raw)
	copyInstalled := make(map[string]string, len(installed))
	for key, value := range installed {
		copyInstalled[key] = value
	}
	return Release{payload: payload, digest: hex.EncodeToString(sum[:]), ns: sku, installed: copyInstalled}, nil
}
func validatePayload(sku SKU, p Payload, installed map[string]string, now time.Time, origin string) error {
	if p.QueueProtocol != "queue-v1" || p.Sequence == 0 || !mapi.IsStrictReleaseVersion(p.Version) {
		return errors.New("invalid release identity")
	}
	if err := validateLifetime(p, now); err != nil {
		return err
	}
	if err := validateArtifact(p.Artifact); err != nil {
		return err
	}
	switch sku {
	case LegacyAdmin:
		if p.Schema != LegacyTargetsSchema || p.SKU != "" || p.ProductCode != "" || p.UpgradeCode != "" || p.Component != "interceptor" || len(p.Contained) != 0 || len(p.Compatibility) != 0 {
			return errors.New("invalid legacy admin target")
		}
		if err := validateRequirements([]Requirement{p.Requires}, installed); err != nil {
			return err
		}
		if !immutableURL(p.Artifact.URL, origin, "admin-v"+p.Version, "go-mapi-interceptor.msi") {
			return errors.New("unauthorized admin artifact URL")
		}
	case System, Suite:
		if p.Schema != MachineTargetsSchema || p.SKU != sku || p.Component != "" || p.Requires != (Requirement{}) {
			return errors.New("wrong machine release SKU")
		}
		id, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(sku), p.Version)
		if err != nil || p.Sequence != id.Sequence || p.ProductCode != id.ProductCode || p.UpgradeCode != upgradeCode(sku) {
			return errors.New("invalid machine release identity")
		}
		if !immutableURL(p.Artifact.URL, origin, id.Tag, id.AssetName) {
			return errors.New("unauthorized machine artifact URL")
		}
		if err := validateContained(sku, p.Contained); err != nil {
			return err
		}
		if err := validateCompatibilitySet(p.Contained, p.Compatibility); err != nil {
			return err
		}
		if err := validateRequirements(p.Compatibility, installed); err != nil {
			return err
		}
	default:
		return errors.New("invalid target SKU")
	}
	return nil
}
func validateLifetime(p Payload, now time.Time) error {
	issued, e := time.Parse(time.RFC3339, p.IssuedAt)
	if e != nil || !strings.HasSuffix(p.IssuedAt, "Z") {
		return errors.New("invalid issue time")
	}
	expires, e := time.Parse(time.RFC3339, p.ExpiresAt)
	if e != nil || !strings.HasSuffix(p.ExpiresAt, "Z") || !expires.After(issued) || expires.Sub(issued) > 31*24*time.Hour || !now.Before(expires) || issued.After(now.Add(5*time.Minute)) {
		return errors.New("expired or invalid release lifetime")
	}
	return nil
}
func validateArtifact(a Artifact) error {
	if a.Size < 1 || len(a.SHA256) != 64 || a.SHA256 != strings.ToLower(a.SHA256) {
		return errors.New("invalid release artifact")
	}
	if _, e := hex.DecodeString(a.SHA256); e != nil {
		return errors.New("invalid release artifact hash")
	}
	return nil
}
func validateRequirements(reqs []Requirement, installed map[string]string) error {
	if len(reqs) == 0 {
		return errors.New("missing compatibility requirements")
	}
	seen := map[string]bool{}
	for _, r := range reqs {
		if r.Component == "" || seen[r.Component] {
			return errors.New("invalid compatibility requirement")
		}
		seen[r.Component] = true
		min, e := semver.StrictNewVersion(r.MinInclusive)
		if e != nil {
			return errors.New("invalid compatibility range")
		}
		max, e := semver.StrictNewVersion(r.MaxExclusive)
		if e != nil || !min.LessThan(max) {
			return errors.New("invalid compatibility range")
		}
		current, e := semver.StrictNewVersion(installed[r.Component])
		if e != nil || current.LessThan(min) || !current.LessThan(max) {
			return fmt.Errorf("installed %s version is incompatible", r.Component)
		}
	}
	return nil
}
func validateCompatibilitySet(contained []ContainedComponent, reqs []Requirement) error {
	if len(contained) != len(reqs) {
		return errors.New("incomplete compatibility set")
	}
	want := map[string]bool{}
	for _, c := range contained {
		want[c.Component] = true
	}
	for _, r := range reqs {
		if !want[r.Component] {
			return errors.New("unknown compatibility component")
		}
	}
	return nil
}
func validateContained(sku SKU, cs []ContainedComponent) error {
	want := map[string]bool{"service": false, "interceptor": false}
	if sku == Suite {
		want["app"] = false
	}
	for _, c := range cs {
		used, ok := want[c.Component]
		if !ok || used || !mapi.IsStrictReleaseVersion(c.Version) {
			return errors.New("invalid contained component")
		}
		want[c.Component] = true
	}
	for _, present := range want {
		if !present {
			return errors.New("incomplete contained component set")
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
func immutableURL(raw, origin, tag, asset string) bool {
	u, e := url.Parse(raw)
	if e != nil || !AllowedArtifactURL(origin, u, false) {
		return false
	}
	base, _ := url.Parse(origin)
	return u.Path == path.Join(base.Path, tag, asset)
}
func validArtifactOrigin(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && u.Scheme == "https" && u.Host != "" && u.User == nil && u.Fragment == "" && u.RawQuery == "" && u.Opaque == "" && strings.HasSuffix(u.Path, "/") && !strings.Contains(u.Path, "..") && u.EscapedPath() == u.Path
}
func mustURL(raw string) *url.URL { u, _ := url.Parse(raw); return u }
func AllowedArtifactURL(origin string, u *url.URL, redirect bool) bool {
	base, err := url.Parse(origin)
	if err != nil || base.Scheme != "https" || base.Host == "" || base.User != nil || base.RawQuery != "" || base.Fragment != "" || u == nil || u.Scheme != "https" || u.User != nil || u.Fragment != "" {
		return false
	}
	if u.EscapedPath() != u.Path || strings.Contains(u.Path, "..") || strings.Contains(u.Path, "\\") || path.Clean(u.Path) != u.Path {
		return false
	}
	basePath := strings.TrimSuffix(base.Path, "/")
	if strings.EqualFold(u.Host, base.Host) && u.RawQuery == "" && (u.Path == basePath || strings.HasPrefix(u.Path, basePath+"/")) && !strings.Contains(strings.ToLower(u.Path), "/latest") {
		return true
	}
	if redirect && strings.EqualFold(base.Host, "github.com") && strings.EqualFold(u.Host, "release-assets.githubusercontent.com") && u.Port() == "" && strings.HasPrefix(u.Path, "/") {
		return true
	}
	return false
}
func DecodeJSON(b []byte, v any) error {
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if e := d.Decode(v); e != nil {
		return e
	}
	if e := d.Decode(&struct{}{}); e != io.EOF {
		return errors.New("trailing JSON value")
	}
	return nil
}
