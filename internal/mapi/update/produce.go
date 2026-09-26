package update

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

type MachineTargetSpec struct {
	SKU            SKU                  `json:"sku"`
	PackageRelease string               `json:"packageRelease"`
	Contained      []ContainedComponent `json:"contained"`
	Compatibility  []Requirement        `json:"compatibility"`
	IssuedAt       string               `json:"issuedAt"`
	ExpiresAt      string               `json:"expiresAt"`
}

const maxMachineArtifactBytes int64 = 2 << 30

func BuildMachineTarget(spec MachineTargetSpec, artifact io.Reader, now time.Time) ([]byte, error) {
	return BuildMachineTargetForOrigin(spec, artifact, now, MachineArtifactOrigin)
}

// BuildMachineTargetForOrigin binds a target to the release builder's fixed
// artifact endpoint. Production uses the canonical default; controlled tests
// can build targets for their separately configured HTTPS artifact endpoint.
func BuildMachineTargetForOrigin(spec MachineTargetSpec, artifact io.Reader, now time.Time, origin string) ([]byte, error) {
	if spec.SKU != System && spec.SKU != Suite || artifact == nil {
		return nil, errors.New("invalid machine target input")
	}
	if !validArtifactOrigin(origin) {
		return nil, errors.New("invalid machine artifact origin")
	}
	id, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(spec.SKU), spec.PackageRelease)
	if err != nil {
		return nil, err
	}
	h := sha256.New()
	size, err := io.Copy(h, io.LimitReader(artifact, maxMachineArtifactBytes+1))
	if err != nil {
		return nil, err
	}
	if size < 1 || size > maxMachineArtifactBytes {
		return nil, errors.New("machine MSI outside size bound")
	}
	p := Payload{Schema: MachineTargetsSchema, SKU: spec.SKU, ProductCode: id.ProductCode, UpgradeCode: upgradeCode(spec.SKU), Version: id.Release, QueueProtocol: "queue-v1", Contained: spec.Contained, Compatibility: spec.Compatibility, Sequence: id.Sequence, IssuedAt: spec.IssuedAt, ExpiresAt: spec.ExpiresAt, Artifact: Artifact{URL: origin + id.Tag + "/" + id.AssetName, Size: size, SHA256: hex.EncodeToString(h.Sum(nil))}}
	raw, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	// A value-typed zero Requirement is not omitted by encoding/json. Machine
	// targets have no legacy-admin requirement field on the wire.
	var document map[string]json.RawMessage
	if err := json.Unmarshal(raw, &document); err != nil {
		return nil, err
	}
	delete(document, "requires")
	raw, err = json.Marshal(document)
	if err != nil {
		return nil, err
	}
	installed := map[string]string{}
	for _, c := range spec.Contained {
		installed[c.Component] = c.Version
	}
	if _, err := ParseTarget(spec.SKU, raw, installed, now, origin); err != nil {
		return nil, fmt.Errorf("validate machine target: %w", err)
	}
	return raw, nil
}
