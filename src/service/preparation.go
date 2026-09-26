package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

// PreparationObservation is captured with bounded Installer and service
// checks before taking the shared protected-state lock.
type PreparationObservation struct {
	Product ProductSnapshot
	Marker  machineProductMarker
	Enabled bool
}

type PreparationDecision struct {
	Observation PreparationObservation
	Release     update.Release
	Pending     PendingV1
	CurrentTime func() time.Time
}

type PreparationAuthorizer interface {
	AuthorizeAndSave(context.Context, PreparationDecision) error
}

// ReadMarkerAndSetting must only read the simple machine registry values. It
// must never perform Installer, service, process, network or trust checks.
type ReadMarkerAndSetting func(context.Context) (machineProductMarker, bool, error)

// The runner uses the SKU recorded in its protected pending transaction when
// checking the installed product immediately before resuming Windows Installer.
func authorizePendingProductSnapshot(pending PendingV1, installed ProductSnapshot) error {
	if (pending.SKU != update.System && pending.SKU != update.Suite) ||
		installed.SKU != pending.SKU || !sameProduct(installed, pending.Old) {
		return errors.New("installed machine product changed before installer resume")
	}
	return nil
}

type FilePreparationAuthorizer struct {
	storage *ProtectedStorage
	read    ReadMarkerAndSetting
}

func NewFilePreparationAuthorizer(storage *ProtectedStorage, read ReadMarkerAndSetting) (*FilePreparationAuthorizer, error) {
	if storage == nil || storage.access != privateStorage || read == nil {
		return nil, errors.New("preparation requires private state and machine registry reader")
	}
	return &FilePreparationAuthorizer{storage: storage, read: read}, nil
}

// AuthorizeAndSave uses the same state.lock as discovery, committed replay,
// final uninstall and pending transitions. All expensive health work precedes
// it; only protected files, simple registry identity and the pending CAS occur
// while held. The runner checks Installer registration again before resume.
func (authorizer *FilePreparationAuthorizer) AuthorizeAndSave(ctx context.Context, decision PreparationDecision) error {
	if (decision.Pending.SKU != update.System && decision.Pending.SKU != update.Suite) ||
		decision.Observation.Product.SKU != decision.Pending.SKU ||
		decision.CurrentTime == nil ||
		!decision.Observation.Enabled || !sameProduct(decision.Observation.Product, decision.Pending.Old) ||
		decision.Pending.Replay.Sequence != decision.Release.Sequence() ||
		decision.Pending.Replay.Digest != decision.Release.Digest() ||
		decision.Pending.ArtifactSHA256 != decision.Release.Payload().Artifact.SHA256 {
		return ErrUnauthorizedCandidate
	}
	candidate, err := productFromRelease(decision.Release)
	if err != nil || !sameProduct(candidate, decision.Pending.Candidate) {
		return ErrUnauthorizedCandidate
	}
	if err := decision.Pending.Validate(); err != nil {
		return err
	}
	unlock, err := lockStateStoreBounded(ctx, authorizer.storage)
	if err != nil {
		return err
	}
	defer unlock()
	if _, err := authorizer.storage.Read([]string{finalUninstallFenceName}, 64); err == nil {
		return ErrFinalUninstallFenced
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if _, err := authorizer.storage.Read([]string{"pending-v2.json"}, maxStateBytes); err == nil {
		return ErrStateConflict
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	discovery, err := readPreparationDiscovery(authorizer.storage, decision.Pending.SKU)
	if err != nil {
		return err
	}
	committed, err := readPreparationReplay(authorizer.storage, decision.Pending.SKU)
	if err != nil {
		return err
	}
	if _, err := update.AcceptReplay(discovery.Accepted, decision.Release); err != nil {
		return fmt.Errorf("discovery high-water changed: %w", err)
	}
	if _, err := update.AcceptReplay(committed, decision.Release); err != nil {
		return fmt.Errorf("committed replay floor changed: %w", err)
	}
	expires, err := time.Parse(time.RFC3339, decision.Release.Payload().ExpiresAt)
	if err != nil {
		return ErrUnauthorizedCandidate
	}
	marker, enabled, err := authorizer.read(ctx)
	if err != nil {
		return err
	}
	if !enabled || marker != decision.Observation.Marker || marker.SKU != string(decision.Pending.SKU) {
		return ErrStateConflict
	}
	if !decision.CurrentTime().Before(expires) {
		return ErrUnauthorizedCandidate
	}
	encoded, err := MarshalPending(decision.Pending)
	if err != nil {
		return err
	}
	_, err = authorizer.storage.WriteAtomic(ctx, []string{"pending-v2.json"}, bytes.NewReader(encoded), maxStateBytes, int64(len(encoded)), "")
	return err
}

func readPreparationDiscovery(storage *ProtectedStorage, sku update.SKU) (DiscoveryState, error) {
	name, err := discoveryName(sku)
	if err != nil {
		return DiscoveryState{}, err
	}
	data, err := storage.Read([]string{name}, maxStatusBytes)
	if errors.Is(err, os.ErrNotExist) {
		return DiscoveryState{Schema: discoverySchema, SKU: sku, Result: "unavailable"}, nil
	}
	if err != nil {
		return DiscoveryState{}, err
	}
	var state DiscoveryState
	if err := decodeStrict(data, &state); err != nil || !validDiscoveryState(state) || state.SKU != sku {
		return DiscoveryState{}, errors.New("invalid protected discovery state")
	}
	return state, nil
}

func readPreparationReplay(storage *ProtectedStorage, sku update.SKU) (update.ReplayState, error) {
	name, err := replayFileName(sku)
	if err != nil {
		return update.ReplayState{}, err
	}
	data, err := storage.Read([]string{name}, maxStateBytes)
	if errors.Is(err, os.ErrNotExist) {
		return update.ReplayState{}, nil
	}
	if err != nil {
		return update.ReplayState{}, err
	}
	var state update.ReplayState
	if err := decodeStrict(data, &state); err != nil || state.Namespace != string(sku) || state.Sequence == 0 || !validSHA256(state.Digest) {
		return update.ReplayState{}, errors.New("invalid committed replay state")
	}
	return state, nil
}
