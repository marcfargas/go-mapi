package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

const discoverySchema = "go-mapi-discovery-v1"

// DiscoveryState is private service state. Its accepted replay floor is
// independent of the committed-install replay file. Candidate expiry is the
// signed expiry, so a heartbeat cannot renew authorization without a fetch.
type DiscoveryState struct {
	Schema             string             `json:"schema"`
	SKU                update.SKU         `json:"sku"`
	Accepted           update.ReplayState `json:"accepted"`
	InstalledVersion   string             `json:"installedVersion,omitempty"`
	CandidateVersion   string             `json:"candidateVersion,omitempty"`
	CandidateExpiresAt time.Time          `json:"candidateExpiresAt,omitempty"`
	Result             string             `json:"result"`
	LastAttemptAt      time.Time          `json:"lastAttemptAt,omitempty"`
	LastSuccessAt      time.Time          `json:"lastSuccessAt,omitempty"`
	NextAttemptAt      time.Time          `json:"nextAttemptAt,omitempty"`
	Failures           uint               `json:"failures"`
}

func validDiscoveryState(state DiscoveryState) bool {
	if state.Schema != discoverySchema || state.SKU != update.System && state.SKU != update.Suite || state.Failures > 1000 ||
		state.Result != "unavailable" && state.Result != "checking" && state.Result != "available" && state.Result != "no-update" && state.Result != "offline" && state.Result != "rejected" {
		return false
	}
	if state.Accepted.Sequence != 0 && (state.Accepted.Namespace != string(state.SKU) || !validSHA256(state.Accepted.Digest)) ||
		state.Accepted.Sequence == 0 && (state.Accepted.Namespace != "" || state.Accepted.Digest != "") {
		return false
	}
	if state.InstalledVersion != "" && !mapi.IsStrictReleaseVersion(state.InstalledVersion) ||
		state.CandidateVersion != "" && !mapi.IsStrictReleaseVersion(state.CandidateVersion) {
		return false
	}
	if state.Result == "available" && (state.CandidateVersion == "" || state.CandidateExpiresAt.IsZero() || state.Accepted.Sequence == 0) ||
		state.Result != "available" && state.CandidateVersion != "" {
		return false
	}
	if !state.LastSuccessAt.IsZero() && state.LastAttemptAt.IsZero() ||
		!state.NextAttemptAt.IsZero() && state.LastAttemptAt.IsZero() {
		return false
	}
	return true
}

func (state DiscoveryState) Effective(now time.Time, installedVersion string) bool {
	return validDiscoveryState(state) && state.InstalledVersion == installedVersion &&
		(state.Result == "available" || state.Result == "no-update") &&
		!state.CandidateExpiresAt.IsZero() && now.Before(state.CandidateExpiresAt) &&
		!now.Before(state.LastSuccessAt.Add(-time.Minute))
}

type DiscoveryStore interface {
	Load(context.Context, update.SKU) (DiscoveryState, error)
	Save(context.Context, DiscoveryState) error
}

type FileDiscoveryStore struct{ storage *ProtectedStorage }

// Persist the shared engine's install retry state through the service's one
// per-SKU check record. Installer-busy deadlines stay in pending state.
func persistMachineInstallCheckState(ctx context.Context, store DiscoveryStore, sku update.SKU, next func(update.CheckState) update.CheckState) (DiscoveryState, error) {
	state, err := store.Load(ctx, sku)
	if err != nil {
		return DiscoveryState{}, err
	}
	check := next(update.CheckState{LastAttemptAt: state.LastAttemptAt, LastSuccessAt: state.LastSuccessAt, NextAttemptAt: state.NextAttemptAt, Failures: state.Failures})
	state.LastAttemptAt, state.LastSuccessAt, state.NextAttemptAt, state.Failures = check.LastAttemptAt, check.LastSuccessAt, check.NextAttemptAt, check.Failures
	if err := store.Save(context.WithoutCancel(ctx), state); err != nil {
		return DiscoveryState{}, err
	}
	return state, nil
}

func NewFileDiscoveryStore(storage *ProtectedStorage) (*FileDiscoveryStore, error) {
	if storage == nil || storage.access != privateStorage {
		return nil, errors.New("discovery requires private protected storage")
	}
	return &FileDiscoveryStore{storage: storage}, nil
}

func discoveryName(sku update.SKU) (string, error) {
	if sku != update.System && sku != update.Suite {
		return "", errors.New("invalid discovery SKU")
	}
	return "discovery-" + string(sku) + "-v1.json", nil
}

func (store *FileDiscoveryStore) Load(_ context.Context, sku update.SKU) (DiscoveryState, error) {
	name, err := discoveryName(sku)
	if err != nil {
		return DiscoveryState{}, err
	}
	data, err := store.storage.Read([]string{name}, maxStatusBytes)
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

func (store *FileDiscoveryStore) Save(ctx context.Context, state DiscoveryState) error {
	if !validDiscoveryState(state) {
		return errors.New("invalid discovery state")
	}
	name, _ := discoveryName(state.SKU)
	unlock, err := lockStateStore(store.storage)
	if err != nil {
		return err
	}
	defer unlock()
	prior, err := store.Load(ctx, state.SKU)
	if err != nil {
		return err
	}
	if prior.Accepted.Sequence > state.Accepted.Sequence || prior.Accepted.Sequence == state.Accepted.Sequence && prior.Accepted.Sequence != 0 && prior.Accepted.Digest != state.Accepted.Digest {
		return ErrStateConflict
	}
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if len(data) > int(maxStatusBytes) {
		return errors.New("discovery state exceeds bound")
	}
	_, err = store.storage.WriteAtomic(ctx, []string{name}, bytes.NewReader(data), maxStatusBytes, int64(len(data)), "")
	return err
}
