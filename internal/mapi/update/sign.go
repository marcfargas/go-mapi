package update

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

// MachineTargetSpec contains only the release facts that cannot be derived
// from a package identity or the final, already-signed MSI bytes.
type MachineTargetSpec struct {
	SKU            SKU                  `json:"sku"`
	PackageRelease string               `json:"packageRelease"`
	Contained      []ContainedComponent `json:"contained"`
	Compatibility  []Requirement        `json:"compatibility"`
	Publisher      PublisherPolicy      `json:"publisher"`
	IssuedAt       string               `json:"issuedAt"`
	ExpiresAt      string               `json:"expiresAt"`
}

const maxMachineArtifactBytes int64 = 2 << 30

// SignMachineTargets creates deterministic envelope bytes for one immutable
// machine MSI. No caller-supplied URL, ProductCode, UpgradeCode, or sequence is
// accepted. Keys are supplied by the protected release environment, never by
// the repository or the installed service.
func SignMachineTargets(root Root, spec MachineTargetSpec, artifact io.Reader, keys map[string]ed25519.PrivateKey, now time.Time) ([]byte, error) {
	policy, err := NewMachinePolicy(spec.SKU, root)
	if err != nil {
		return nil, err
	}
	identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(spec.SKU), spec.PackageRelease)
	if err != nil {
		return nil, err
	}
	if artifact == nil {
		return nil, errors.New("machine MSI reader is nil")
	}
	hash := sha256.New()
	size, err := io.Copy(hash, io.LimitReader(artifact, maxMachineArtifactBytes+1))
	if err != nil {
		return nil, fmt.Errorf("hash final machine MSI: %w", err)
	}
	if size == 0 || size > maxMachineArtifactBytes {
		return nil, errors.New("machine MSI size is outside the permitted bound")
	}
	payload := Payload{
		Schema: MachineTargetsSchema, SKU: spec.SKU, ProductCode: identity.ProductCode,
		UpgradeCode: upgradeCode(spec.SKU), Version: identity.Release, QueueProtocol: "queue-v1",
		Contained: spec.Contained, Compatibility: spec.Compatibility, Sequence: identity.Sequence,
		IssuedAt: spec.IssuedAt, ExpiresAt: spec.ExpiresAt,
		Artifact:  Artifact{URL: MachineArtifactOrigin + identity.Tag + "/" + identity.AssetName, Size: size, SHA256: hex.EncodeToString(hash.Sum(nil))},
		Publisher: spec.Publisher,
	}
	signed, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(keys))
	for id := range keys {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	signatures := make([]Signature, 0, len(ids))
	for _, id := range ids {
		encoded, ok := root.Targets.Keys[id]
		if !ok || len(keys[id]) != ed25519.PrivateKeySize {
			return nil, errors.New("machine target signer is not trusted")
		}
		public, err := base64.RawURLEncoding.DecodeString(encoded)
		if err != nil || !ed25519.PublicKey(public).Equal(keys[id].Public()) {
			return nil, errors.New("machine target signer does not match trusted root")
		}
		signatures = append(signatures, Signature{KeyID: id, Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(keys[id], signed))})
	}
	if len(signatures) < root.Targets.Threshold {
		return nil, errors.New("machine target signature threshold not met")
	}
	envelope, err := json.Marshal(Envelope{Schema: EnvelopeSchema, Signed: base64.RawURLEncoding.EncodeToString(signed), Signatures: signatures})
	if err != nil {
		return nil, err
	}
	installed := make(map[string]string, len(spec.Contained))
	for _, component := range spec.Contained {
		installed[component.Component] = component.Version
	}
	if _, err := policy.Authorize(envelope, installed, now); err != nil {
		return nil, fmt.Errorf("verify generated machine targets: %w", err)
	}
	return envelope, nil
}
