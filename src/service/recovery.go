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

const recoverySchema = "go-mapi-recovery-v1"
const maxRecoveryLaunches = 3
const recoveryPrelaunchBound = 30 * time.Second
const recoveryGrantBound = 2 * time.Minute
const recoveryCleanupBound = 5 * time.Second

// RecoveryV1 is a monotonic per-SKU launch journal. Reservation is written
// before pending; a consumed launch is never replayed after reconstruction.
// Reservation contains only the exact protected product/transaction identity.
type RecoveryV1 struct {
	Schema         string               `json:"schema"`
	Reservation    PendingV1            `json:"reservation"`
	Marker         machineProductMarker `json:"marker"`
	Consumed       uint                 `json:"consumed"`
	Failures       uint                 `json:"failures"`
	ExpiresAt      time.Time            `json:"expiresAt"`
	LaunchDeadline time.Time            `json:"launchDeadline"`
	Stage          string               `json:"stage"`
	Reason         string               `json:"reason"`
	FailedAt       time.Time            `json:"failedAt,omitempty"`
	DueAt          time.Time            `json:"dueAt,omitempty"`
	UpdatedAt      time.Time            `json:"updatedAt"`
	Runner         *ProcessIdentity     `json:"runner,omitempty"`
}

func (r RecoveryV1) Validate() error {
	if r.Schema != recoverySchema || r.Reservation.Validate() != nil || r.Reservation.Phase != PhasePrepared || r.Reservation.Runner != nil || r.Reservation.Installer != nil || r.Reservation.InstallerThread != nil || r.Reservation.Exit != nil || r.Consumed < 1 || r.Consumed > maxRecoveryLaunches || r.Failures > r.Consumed || r.ExpiresAt.IsZero() || r.LaunchDeadline.IsZero() || r.LaunchDeadline.After(r.ExpiresAt) || r.LaunchDeadline.After(r.Reservation.UpdatedAt.Add(recoveryGrantBound)) || r.UpdatedAt.IsZero() || validateProcessIdentity(r.Runner) != nil {
		return errors.New("invalid recovery reservation")
	}
	switch r.Stage {
	case "reserved", "readiness-failed", "due", "safety-blocked", "retrying", "completed", "exhausted", "msi-terminal":
	default:
		return errors.New("invalid recovery stage")
	}
	switch r.Reason {
	case "", "handoff-failed", "abandoned-handoff", "runner-owned", "process-unknown", "process-alive", "installer-active", "product-changed", "health-unproved", "authorization-unavailable", "state-changed", "readiness-exhausted", "installed", "msi-failed":
	default:
		return errors.New("invalid recovery reason")
	}
	if !r.FailedAt.IsZero() && (r.Failures == 0 || r.DueAt.IsZero() || r.DueAt.Before(r.FailedAt)) {
		return errors.New("invalid recovery failure time")
	}
	if r.Stage == "exhausted" && (r.Consumed != maxRecoveryLaunches || r.Reason != "readiness-exhausted") {
		return errors.New("invalid recovery exhaustion")
	}
	return nil
}

type FileRecoveryStore struct{ storage *ProtectedStorage }

func NewFileRecoveryStore(storage *ProtectedStorage) (*FileRecoveryStore, error) {
	if storage == nil || storage.access != privateStorage {
		return nil, errors.New("recovery requires private storage")
	}
	return &FileRecoveryStore{storage: storage}, nil
}
func recoveryName(sku update.SKU) (string, error) {
	if sku != update.System && sku != update.Suite {
		return "", ErrUnauthorizedCandidate
	}
	return "recovery-" + string(sku) + "-v1.json", nil
}
func (s *FileRecoveryStore) Load(ctx context.Context, sku update.SKU) (*RecoveryV1, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	name, err := recoveryName(sku)
	if err != nil {
		return nil, err
	}
	data, err := s.storage.Read([]string{name}, maxStateBytes)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var r RecoveryV1
	if err := decodeStrict(data, &r); err != nil {
		return nil, err
	}
	if err := r.Validate(); err != nil {
		return nil, err
	}
	if r.Reservation.SKU != sku {
		return nil, ErrStateConflict
	}
	return &r, nil
}
func (s *FileRecoveryStore) saveLocked(ctx context.Context, r RecoveryV1) error {
	if err := r.Validate(); err != nil {
		return err
	}
	name, _ := recoveryName(r.Reservation.SKU)
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	_, err = s.storage.WriteAtomic(ctx, []string{name}, bytes.NewReader(data), maxStateBytes, int64(len(data)), "")
	return err
}
func sameRecoveryTarget(a, b PendingV1) bool {
	return a.SKU == b.SKU && a.Replay == b.Replay && a.ArtifactSHA256 == b.ArtifactSHA256 && sameProduct(a.Candidate, b.Candidate)
}
func (r RecoveryV1) busyGap(p PendingV1) bool {
	return p.Phase == PhaseRolledBack && p.Result == ResultRetryScheduled && p.Exit != nil && p.Exit.Code == 1618 && sameRecoveryTarget(r.Reservation, p) && r.Reservation.Attempt == p.Attempt+1 && r.Reservation.TransactionID != p.TransactionID
}
func (r RecoveryV1) matches(p PendingV1) bool {
	return sameRecoveryTarget(r.Reservation, p) && r.Reservation.TransactionID == p.TransactionID && r.Reservation.Attempt == p.Attempt && sameProduct(r.Reservation.Old, p.Old)
}
func (r RecoveryV1) allows(p PendingV1, now time.Time) bool {
	if p.Replay.Sequence < r.Reservation.Replay.Sequence || (p.Replay.Sequence == r.Reservation.Replay.Sequence && !sameRecoveryTarget(r.Reservation, p)) {
		return false
	}
	if p.Replay.Sequence > r.Reservation.Replay.Sequence {
		return p.Replay.Digest != r.Reservation.Replay.Digest
	}
	if r.Stage == "msi-terminal" {
		return !now.Before(r.UpdatedAt.Add(24 * time.Hour))
	}
	return r.Consumed < maxRecoveryLaunches && (r.Stage == "due" || r.Stage == "safety-blocked") && !r.DueAt.IsZero() && !now.Before(r.DueAt) && sameProduct(r.Reservation.Old, p.Old)
}

// reserveLocked and the following pending write use the SAME state lock.
// A failed second write leaves an orphan, not a renewable authorization.
func (s *FileRecoveryStore) reserveLocked(ctx context.Context, p PendingV1, marker machineProductMarker, expires, now time.Time, busy bool) error {
	old, err := s.Load(ctx, p.SKU)
	if err != nil {
		return err
	}
	consumed, failures := uint(1), uint(0)
	if old != nil {
		if old.Reservation.TransactionID == p.TransactionID {
			return ErrStateConflict
		}
		if busy {
			if !sameRecoveryTarget(old.Reservation, p) || old.Consumed >= maxRecoveryLaunches || old.Stage == "exhausted" || old.Reservation.TransactionID == p.TransactionID {
				return ErrStateConflict
			}
		} else if !old.allows(p, now) {
			return ErrStateConflict
		}
		if sameRecoveryTarget(old.Reservation, p) && old.Stage != "msi-terminal" {
			consumed, failures = old.Consumed+1, old.Failures
		}
	}
	deadline := p.UpdatedAt.Add(recoveryGrantBound)
	if expires.Before(deadline) {
		deadline = expires
	}
	stage := "reserved"
	if consumed > 1 {
		stage = "retrying"
	}
	return s.saveLocked(ctx, RecoveryV1{Schema: recoverySchema, Reservation: p, Marker: marker, Consumed: consumed, Failures: failures, ExpiresAt: expires, LaunchDeadline: deadline, Stage: stage, UpdatedAt: now})
}
func recoveryFailureBase() time.Duration {
	timers, present, err := loadMachineValidationTimers()
	if err == nil && present {
		return timers.FailureDelayBase
	}
	return productionFailureDelayBase
}
func (s *FileRecoveryStore) mutate(ctx context.Context, p PendingV1, fn func(*RecoveryV1)) error {
	unlock, err := lockStateStoreBounded(ctx, s.storage)
	if err != nil {
		return err
	}
	defer unlock()
	r, err := s.Load(ctx, p.SKU)
	if err != nil {
		return err
	}
	if r == nil || !r.matches(p) {
		return ErrStateConflict
	}
	fn(r)
	return s.saveLocked(ctx, *r)
}
func recordRecoveryFailure(r *RecoveryV1, now time.Time, reason string) {
	if r.FailedAt.IsZero() {
		r.Failures++
		r.FailedAt = now
		r.DueAt = now.Add(recoveryFailureBase() * time.Duration(1<<min(r.Failures-1, 1)))
	}
	r.Stage, r.Reason, r.UpdatedAt = "readiness-failed", reason, now
}
func (s *FileRecoveryStore) Failed(ctx context.Context, p PendingV1, receipt HandoffReceipt, now time.Time) error {
	return s.mutate(ctx, p, func(r *RecoveryV1) {
		// Do not overwrite a concurrently finalized terminal witness.
		if r.Stage == "completed" || r.Stage == "exhausted" || r.Stage == "msi-terminal" {
			return
		}
		recordRecoveryFailure(r, now, "handoff-failed")
		if validateProcessIdentity(&receipt.Runner) == nil {
			r.Runner = &receipt.Runner
		}
	})
}
func (s *FileRecoveryStore) Blocked(ctx context.Context, p PendingV1, reason string, now time.Time) error {
	return s.mutate(ctx, p, func(r *RecoveryV1) {
		if r.Stage != "completed" && r.Stage != "exhausted" && r.Stage != "msi-terminal" {
			r.Stage, r.Reason, r.UpdatedAt = "safety-blocked", reason, now
		}
	})
}

// retire requires runner ownership and proved no-install observations from the
// coordinator. The prepared->fenced write precedes the witness and exact clear.
func (s *FileRecoveryStore) retire(ctx context.Context, p *PendingV1, r RecoveryV1, now time.Time) error {
	unlock, err := lockStateStoreBounded(ctx, s.storage)
	if err != nil {
		return err
	}
	defer unlock()
	current, err := s.Load(ctx, r.Reservation.SKU)
	if err != nil {
		return err
	}
	if current == nil || !current.matches(r.Reservation) {
		return ErrStateConflict
	}
	r = *current
	state := &FileStateStore{storage: s.storage}
	raw, err := s.storage.Read([]string{"pending-v2.json"}, maxStateBytes)
	if p == nil {
		if !errors.Is(err, os.ErrNotExist) {
			return ErrStateConflict
		}
	} else {
		prior, e := MarshalPending(*p)
		if e != nil {
			return e
		}
		if err != nil || !bytes.Equal(raw, prior) {
			return ErrStateConflict
		}
		if p.Phase != PhasePrepared && p.Phase != PhaseHandoffFenced && !r.busyGap(*p) {
			return ErrStateConflict
		}
		fenced := *p
		if r.busyGap(*p) {
			fenced = r.Reservation
		}
		fenced.Phase = PhaseHandoffFenced
		fenced.UpdatedAt = now
		data, e := MarshalPending(fenced)
		if e != nil {
			return e
		}
		if p.Phase != PhaseHandoffFenced {
			if _, e = s.storage.WriteAtomic(ctx, []string{"pending-v2.json"}, bytes.NewReader(data), maxStateBytes, int64(len(data)), ""); e != nil {
				return e
			}
			raw = data
		}
	}
	if r.FailedAt.IsZero() {
		recordRecoveryFailure(&r, now, "abandoned-handoff")
	}
	r.Stage, r.UpdatedAt = "due", now
	if r.Consumed >= maxRecoveryLaunches {
		r.Stage, r.Reason = "exhausted", "readiness-exhausted"
	}
	if err := s.saveLocked(ctx, r); err != nil {
		return err
	}
	if p != nil {
		return state.compareAndClearLocked(raw)
	}
	return nil
}
func (s *FileRecoveryStore) Finalize(ctx context.Context, p PendingV1, now time.Time) error {
	r, err := s.Load(ctx, p.SKU)
	if err != nil || r == nil {
		return err
	}
	return s.mutate(ctx, p, func(r *RecoveryV1) {
		if p.Phase == PhaseCommitted {
			r.Stage, r.Reason = "completed", "installed"
		} else {
			r.Stage, r.Reason = "msi-terminal", "msi-failed"
		}
		r.UpdatedAt = now
	})
}

// validateGrantLocked runs in the pending CAS lock, immediately before the
// irrevocable resume-authorized write. Already authorized children do not call it.
func (s *FileRecoveryStore) validateGrantLocked(ctx context.Context, p PendingV1, read ReadMarkerAndSetting, now time.Time) error {
	r, err := s.Load(ctx, p.SKU)
	if err != nil {
		return err
	}
	if p.RetryDeadline != nil && !now.Before(*p.RetryDeadline) {
		return ErrUnauthorizedCandidate
	}
	if r == nil || !r.matches(p) || r.Stage == "exhausted" || r.Stage == "completed" || r.Stage == "msi-terminal" || !now.Before(r.ExpiresAt) || !now.Before(r.LaunchDeadline) {
		return ErrUnauthorizedCandidate
	}
	if _, err := s.storage.Read([]string{finalUninstallFenceName}, 64); !errors.Is(err, os.ErrNotExist) {
		return ErrFinalUninstallFenced
	}
	if read == nil {
		return ErrUnauthorizedCandidate
	}
	marker, enabled, err := read(ctx)
	if err != nil {
		return err
	}
	if !enabled || marker != r.Marker {
		return ErrUnauthorizedCandidate
	}
	discovery, err := readPreparationDiscovery(s.storage, p.SKU)
	if err != nil {
		return err
	}
	committed, err := readPreparationReplay(s.storage, p.SKU)
	if err != nil {
		return err
	}
	for _, floor := range []update.ReplayState{discovery.Accepted, committed} {
		if floor.Sequence > p.Replay.Sequence || floor.Sequence == p.Replay.Sequence && floor.Sequence != 0 && floor.Digest != p.Replay.Digest {
			return ErrUnauthorizedCandidate
		}
	}
	return ctx.Err()
}

func samePending(a, b PendingV1) bool {
	x, e := MarshalPending(a)
	y, f := MarshalPending(b)
	return e == nil && f == nil && bytes.Equal(x, y)
}
func writePendingLocked(ctx context.Context, s *ProtectedStorage, p PendingV1) error {
	data, err := MarshalPending(p)
	if err != nil {
		return err
	}
	_, err = s.WriteAtomic(ctx, []string{"pending-v2.json"}, bytes.NewReader(data), maxStateBytes, int64(len(data)), "")
	return err
}
