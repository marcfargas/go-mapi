package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

// Linked only by the explicit disposable validation build flag. Release build
// scripts reject the flag. Production never reads the obstruction marker.
var MachineValidationReadinessFault string

const readinessObstructionName = "readiness-obstruction-v1.json"

type readinessObstruction struct {
	Schema         string     `json:"schema"`
	SKU            update.SKU `json:"sku"`
	Digest         string     `json:"digest"`
	ArtifactSHA256 string     `json:"artifactSha256"`
}
type readinessFixtureHit struct {
	Schema         string          `json:"schema"`
	SKU            update.SKU      `json:"sku"`
	Digest         string          `json:"digest"`
	ArtifactSHA256 string          `json:"artifactSha256"`
	TransactionID  string          `json:"transactionId"`
	Attempt        uint            `json:"attempt"`
	Runner         ProcessIdentity `json:"runner"`
	At             time.Time       `json:"at"`
}

func validationReadinessObstruction(ctx context.Context, storage *ProtectedStorage, p PendingV1, self ProcessIdentity, now time.Time) (bool, error) {
	if MachineValidationReadinessFault == "" {
		return false, nil
	}
	if _, present, err := loadMachineValidationTimers(); err != nil || !present || MachineValidationReadinessFault != "enabled" {
		return false, errors.New("invalid readiness validation build")
	}
	if storage == nil || storage.access != privateStorage || p.Phase != PhasePrepared || validateProcessIdentity(&self) != nil {
		return false, ErrStateConflict
	}
	data, err := storage.Read([]string{readinessObstructionName}, maxStatusBytes)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var marker readinessObstruction
	if err := decodeStrict(data, &marker); err != nil {
		return false, err
	}
	if marker.Schema != "go-mapi-readiness-obstruction-v1" || (marker.SKU != update.System && marker.SKU != update.Suite) || !validSHA256(marker.Digest) || !validSHA256(marker.ArtifactSHA256) {
		return false, errors.New("malformed readiness obstruction")
	}
	if marker.SKU != p.SKU || marker.Digest != p.Replay.Digest || marker.ArtifactSHA256 != p.ArtifactSHA256 {
		return false, nil
	}
	hit := readinessFixtureHit{Schema: "go-mapi-readiness-hit-v1", SKU: p.SKU, Digest: p.Replay.Digest, ArtifactSHA256: p.ArtifactSHA256, TransactionID: p.TransactionID, Attempt: p.Attempt, Runner: self, At: now}
	encoded, err := json.Marshal(hit)
	if err != nil {
		return false, err
	}
	_, err = storage.WriteAtomic(ctx, []string{"readiness-hit-" + p.TransactionID + ".json"}, bytes.NewReader(encoded), maxStatusBytes, int64(len(encoded)), "")
	return err == nil, err
}
