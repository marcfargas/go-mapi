package service

import (
	"context"
	"errors"
	"time"
)

func (c *Coordinator) handoffFailure(p PendingV1, receipt HandoffReceipt, cause error) error {
	if c.deps.Recovery == nil {
		return cause
	}
	ctx, cancel := context.WithTimeout(context.Background(), recoveryCleanupBound)
	defer cancel()
	return errors.Join(cause, c.deps.Recovery.Failed(ctx, p, receipt, c.deps.Clock.Now()))
}

// reconcileHandoff never launches. Ownership spans observations and the exact
// prepared fence, including a runner delayed before its first pending load.
func (c *Coordinator) reconcileHandoff(ctx context.Context, p *PendingV1) (Outcome, error) {
	s := c.deps.Recovery
	r, err := s.Load(ctx, c.config.SKU)
	if err != nil {
		return OutcomeBackoff, err
	}
	if r == nil {
		if p == nil {
			return OutcomeNoUpdate, nil
		}
		// Legacy prepared state has no count witness. Conservatively consume the
		// full cap; do not manufacture a new budget or falsely report MSI rollback.
		reservation := *p
		reservation.Runner = nil
		reservation.AppDrainDeadline = nil
		deadline := reservation.UpdatedAt.Add(recoveryGrantBound)
		r = &RecoveryV1{Schema: recoverySchema, Reservation: reservation, Consumed: maxRecoveryLaunches, ExpiresAt: deadline, LaunchDeadline: deadline, Stage: "reserved", UpdatedAt: c.deps.Clock.Now(), Runner: p.Runner}
		unlock, e := lockStateStoreBounded(ctx, s.storage)
		if e != nil {
			return OutcomeBackoff, e
		}
		existing, e := s.Load(ctx, c.config.SKU)
		if e == nil && existing == nil {
			e = s.saveLocked(ctx, *r)
		} else if e == nil {
			r = existing
		}
		unlock()
		if e != nil {
			return OutcomeBackoff, e
		}
	}
	if p == nil && (r.Stage == "due" || r.Stage == "completed" || r.Stage == "exhausted" || r.Stage == "msi-terminal" || r.Stage == "safety-blocked" && !r.DueAt.IsZero()) {
		return OutcomeNoUpdate, nil
	}
	if p != nil && !r.matches(*p) && !r.busyGap(*p) {
		return OutcomeBackoff, ErrStateConflict
	}
	now := c.deps.Clock.Now()
	if r.FailedAt.IsZero() && now.Before(r.LaunchDeadline) {
		return OutcomeBackoff, nil
	}
	block := func(reason string, cause error) (Outcome, error) {
		bounded, cancel := context.WithTimeout(context.Background(), recoveryCleanupBound)
		defer cancel()
		return OutcomeBackoff, errors.Join(cause, s.Blocked(bounded, r.Reservation, reason, now))
	}
	if c.deps.RecoveryLock == nil {
		return block("runner-owned", nil)
	}
	unlock, err := c.deps.RecoveryLock()
	if err != nil {
		return block("runner-owned", nil)
	}
	defer unlock()
	identities := []*ProcessIdentity{r.Runner}
	if p != nil {
		if !r.busyGap(*p) && (p.Installer != nil || p.InstallerThread != nil || p.Exit != nil || (p.Phase != PhasePrepared && p.Phase != PhaseHandoffFenced)) {
			return block("installer-active", nil)
		}
		identities = append(identities, p.Runner, p.Installer)
	}
	for _, identity := range identities {
		if identity != nil {
			alive, e := c.deps.Processes.Alive(ctx, *identity)
			if e != nil {
				return block("process-unknown", e)
			}
			if alive {
				return block("process-alive", nil)
			}
		}
	}
	idle, err := c.deps.InstallerServer.Idle(ctx, true)
	if err != nil || !idle {
		return block("installer-active", err)
	}
	products, err := c.deps.Inventory.Products(ctx)
	if err != nil || len(products) != 1 || !sameProduct(products[0].Snapshot, r.Reservation.Old) {
		return block("product-changed", err)
	}
	healthy, err := c.deps.Health.Healthy(ctx, r.Reservation.Old)
	if err != nil || !healthy {
		return block("health-unproved", err)
	}
	if c.deps.RetryGate != nil {
		allowed, e := c.deps.RetryGate.AllowRetry(ctx, r.Reservation)
		if e != nil || !allowed {
			return block("authorization-unavailable", e)
		}
	}
	idle, err = c.deps.InstallerServer.Idle(ctx, true)
	if err != nil || !idle {
		return block("installer-active", err)
	}
	products, err = c.deps.Inventory.Products(ctx)
	if err != nil || len(products) != 1 || !sameProduct(products[0].Snapshot, r.Reservation.Old) {
		return block("product-changed", err)
	}
	if err := s.retire(ctx, p, *r, now); err != nil {
		return OutcomeBackoff, err
	}
	return OutcomeNoUpdate, nil
}

// reserveBusy consumes the SAME launch budget as initial and readiness work.
// The preceding genuine1618 result remains pending if this reservation cannot
// be written. A new transaction ID also fences late initial-load entrants.
func (s *FileRecoveryStore) reserveBusy(ctx context.Context, previous, next PendingV1, now time.Time) error {
	unlock, err := lockStateStoreBounded(ctx, s.storage)
	if err != nil {
		return err
	}
	defer unlock()
	state := &FileStateStore{storage: s.storage}
	current, err := state.loadLocked()
	if err != nil {
		return err
	}
	if current == nil || !samePending(*current, previous) {
		return ErrStateConflict
	}
	r, err := s.Load(ctx, next.SKU)
	if err != nil {
		return err
	}
	if r == nil || !r.matches(previous) {
		return ErrStateConflict
	}
	if err := s.reserveLocked(ctx, next, r.Marker, r.ExpiresAt, now, true); err != nil {
		return err
	}
	return writePendingLocked(ctx, s.storage, next)
}
