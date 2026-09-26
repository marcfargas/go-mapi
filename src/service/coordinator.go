package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"reflect"
	"sync"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

var (
	ErrBusy                  = errors.New("service update coordinator is busy")
	ErrOffline               = errors.New("release source is offline")
	ErrUnauthorizedCandidate = errors.New("release candidate does not belong to installed SKU")
	ErrStateConflict         = errors.New("pending update state changed concurrently")
)

type Outcome string

const (
	OutcomeNoUpdate           Outcome = "no-update"
	OutcomeHandedOff          Outcome = "handed-off"
	OutcomeStillRunning       Outcome = "still-running"
	OutcomeCommitted          Outcome = "committed"
	OutcomeRolledBack         Outcome = "rolled-back"
	OutcomeRebootPending      Outcome = "reboot-pending"
	OutcomeRepairRequired     Outcome = "repair-required"
	OutcomeRepairRetired      Outcome = "repair-retired"
	OutcomeBackoff            Outcome = "backoff"
	OutcomeOutcomeUnconfirmed Outcome = "outcome-unconfirmed"
)

type EventCode string

const (
	EventOffline       EventCode = "offline"
	EventPrepared      EventCode = "prepared"
	EventHandedOff     EventCode = "handed-off"
	EventStillRunning  EventCode = "still-running"
	EventCommitted     EventCode = "committed"
	EventRolledBack    EventCode = "rolled-back"
	EventRebootPending EventCode = "reboot-pending"
	EventRepairNeeded  EventCode = "repair-required"
	EventPending       EventCode = "pending"
)

// Event is deliberately bounded and redacted. Platform log adapters receive
// no URL, filesystem path, installer command line, profile data, or raw error.
type Event struct {
	Code          EventCode
	TransactionID string
}

type Config struct {
	SKU                     update.SKU
	MaxInstallerBusyRetries uint
}

type InstalledProduct struct {
	Snapshot ProductSnapshot
}

// StagedArtifact is an opaque handle issued by the protected artifact store.
// It is never populated from release metadata or a public coordinator input.
type StagedArtifact struct {
	Handle string
	SHA256 string
}

// HandoffRequest intentionally contains neither an installer command line nor
// URLs/properties. The fixed Windows adapter owns the one permitted invocation.
type HandoffRequest struct {
	TransactionID string
	Attempt       uint
	Artifact      StagedArtifact
}

type HandoffReceipt struct {
	Runner    ProcessIdentity
	Installer ProcessIdentity
	Ready     bool
}

type ProductInventory interface {
	Products(context.Context) ([]InstalledProduct, error)
}

type RunnerLauncher interface {
	Launch(context.Context, HandoffRequest) (HandoffReceipt, error)
}

type RetryGate interface {
	AllowRetry(context.Context, PendingV1) (bool, error)
}

type HealthProbe interface {
	Healthy(context.Context, ProductSnapshot) (bool, error)
}

type ProcessProbe interface {
	Alive(context.Context, ProcessIdentity) (bool, error)
}

// InstallerServerProbe checks the system-wide Windows Installer execution
// boundary. A dead msiexec client alone cannot prove that the MSI server has
// finished committing or rolling back its transaction.
type InstallerServerProbe interface {
	Idle(context.Context, bool) (bool, error)
}

type PendingStore interface {
	Load(context.Context) (*PendingV1, error)
	Save(context.Context, PendingV1) error
	CompareAndSave(context.Context, *PendingV1, PendingV1) error
	CompareAndClear(context.Context, PendingV1) error
}

type ReplayStore interface {
	Load(context.Context, update.SKU) (update.ReplayState, error)
	Save(context.Context, update.ReplayState) error
}

type LastResultStore interface {
	Load(context.Context) (*LastResultV1, error)
	Save(context.Context, LastResultV1) error
}

type EventSink interface {
	Record(context.Context, Event)
}

type Clock interface{ Now() time.Time }

// BootIdentity is volatile across a Windows reboot and stable across service
// restarts within that boot.
type BootIdentity interface {
	CurrentBootID(context.Context) (string, error)
}
type IDGenerator interface{ NewID() string }

type Dependencies struct {
	PreparationEnabled   func(context.Context) (bool, error)
	ObservePreparation   func(context.Context) (PreparationObservation, error)
	PrepareAuthorization PreparationAuthorizer
	Inventory            ProductInventory
	Launcher             RunnerLauncher
	RetryGate            RetryGate
	Health               HealthProbe
	Processes            ProcessProbe
	InstallerServer      InstallerServerProbe
	Pending              PendingStore
	Replay               ReplayStore
	LastResult           LastResultStore
	Events               EventSink
	Clock                Clock
	Boot                 BootIdentity
	IDs                  IDGenerator
	RecoveryLock         func() (func(), error)
	RetireRepair         func(context.Context, PendingV1, ProductSnapshot) error
}

type Coordinator struct {
	config Config
	deps   Dependencies
	mu     sync.Mutex
}

func NewCoordinator(config Config, deps Dependencies) (*Coordinator, error) {
	if err := validateReconcileDependencies(config, deps); err != nil {
		return nil, err
	}
	if anyNil(deps.Launcher, deps.IDs) {
		return nil, errors.New("coordinator installation dependencies are incomplete")
	}
	return &Coordinator{config: config, deps: deps}, nil
}

// NewReconciler composes the recovery-only resident caller. It cannot start
// an installation without a prepared artifact and launcher.
func NewReconciler(config Config, deps Dependencies) (*Coordinator, error) {
	if err := validateReconcileDependencies(config, deps); err != nil {
		return nil, err
	}
	return &Coordinator{config: config, deps: deps}, nil
}

func validateReconcileDependencies(config Config, deps Dependencies) error {
	if config.SKU != update.System && config.SKU != update.Suite {
		return errors.New("coordinator requires a fixed machine SKU")
	}
	if config.MaxInstallerBusyRetries == 0 {
		return errors.New("coordinator requires a bounded installer-busy retry count")
	}
	if anyNil(deps.Inventory, deps.Health, deps.Processes, deps.InstallerServer, deps.Pending, deps.Replay, deps.LastResult, deps.Events, deps.Clock, deps.Boot) {
		return errors.New("coordinator reconciliation dependencies are incomplete")
	}
	return nil
}

// Eligible checks local installation gates before the shared engine downloads
// an offered artifact. The same gates are repeated immediately before the
// pending transaction is recorded.
func (coordinator *Coordinator) Eligible(ctx context.Context, release update.Release) (bool, error) {
	if !coordinator.mu.TryLock() {
		return false, ErrBusy
	}
	defer coordinator.mu.Unlock()
	_, _, _, eligible, err := coordinator.installationEligibility(ctx, release)
	return eligible, err
}

func (coordinator *Coordinator) installationEligibility(ctx context.Context, release update.Release) (ProductSnapshot, ProductSnapshot, update.ReplayState, bool, error) {
	if release.Namespace() != string(coordinator.config.SKU) {
		return ProductSnapshot{}, ProductSnapshot{}, update.ReplayState{}, false, ErrUnauthorizedCandidate
	}
	if coordinator.deps.PreparationEnabled != nil {
		enabled, err := coordinator.deps.PreparationEnabled(ctx)
		if err != nil || !enabled {
			return ProductSnapshot{}, ProductSnapshot{}, update.ReplayState{}, false, err
		}
	}
	pending, err := coordinator.deps.Pending.Load(ctx)
	if err != nil || pending != nil {
		return ProductSnapshot{}, ProductSnapshot{}, update.ReplayState{}, false, err
	}
	products, err := coordinator.deps.Inventory.Products(ctx)
	if err != nil {
		return ProductSnapshot{}, ProductSnapshot{}, update.ReplayState{}, false, err
	}
	if len(products) != 1 || products[0].Snapshot.SKU != coordinator.config.SKU {
		return ProductSnapshot{}, ProductSnapshot{}, update.ReplayState{}, false, ErrUnauthorizedCandidate
	}
	installed := products[0].Snapshot
	healthy, err := coordinator.deps.Health.Healthy(ctx, installed)
	if err != nil || !healthy {
		return ProductSnapshot{}, ProductSnapshot{}, update.ReplayState{}, false, err
	}
	candidate, err := productFromRelease(release)
	if err != nil || candidate.SKU != coordinator.config.SKU {
		return ProductSnapshot{}, ProductSnapshot{}, update.ReplayState{}, false, ErrUnauthorizedCandidate
	}
	committed, err := coordinator.deps.Replay.Load(ctx, coordinator.config.SKU)
	if err != nil {
		return ProductSnapshot{}, ProductSnapshot{}, update.ReplayState{}, false, err
	}
	next, err := update.AcceptReplay(committed, release)
	if err != nil {
		return ProductSnapshot{}, ProductSnapshot{}, update.ReplayState{}, false, err
	}
	last, err := coordinator.deps.LastResult.Load(ctx)
	if err != nil {
		return ProductSnapshot{}, ProductSnapshot{}, update.ReplayState{}, false, err
	}
	now := coordinator.deps.Clock.Now()
	if last != nil && (last.Result == ResultRolledBack || last.Result == ResultBusyExhausted) && last.SKU == coordinator.config.SKU && last.Digest == next.Digest &&
		(now.Before(last.FinishedAt) || now.Sub(last.FinishedAt) < 24*time.Hour) {
		return installed, candidate, next, false, nil
	}
	return installed, candidate, next, installed.ProductCode != candidate.ProductCode, nil
}

// InstallPrepared records the durable transaction and starts the detached
// installer for bytes already downloaded and verified by the shared engine.
func (coordinator *Coordinator) InstallPrepared(ctx context.Context, release update.Release, artifact StagedArtifact) (Outcome, error) {
	if !coordinator.mu.TryLock() {
		return "", ErrBusy
	}
	defer coordinator.mu.Unlock()
	installed, candidate, nextReplay, eligible, err := coordinator.installationEligibility(ctx, release)
	if err != nil {
		return "", err
	}
	if !eligible {
		return OutcomeNoUpdate, ErrStateConflict
	}
	if artifact.Handle == "" || artifact.SHA256 != release.Payload().Artifact.SHA256 {
		return "", errors.New("prepared artifact does not match candidate")
	}
	now := coordinator.deps.Clock.Now()
	retryDeadline := now.Add(10 * time.Minute)
	pending := PendingV1{
		Schema: PendingSchemaV2, TransactionID: coordinator.deps.IDs.NewID(), SKU: coordinator.config.SKU,
		Old: installed, Candidate: candidate, Replay: nextReplay, ArtifactSHA256: artifact.SHA256,
		Phase: PhasePrepared, PreparedAt: now, UpdatedAt: now, Attempt: 1, RetryDeadline: &retryDeadline,
	}
	handoffCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	pending.LaunchBootID, err = coordinator.deps.Boot.CurrentBootID(handoffCtx)
	if err != nil || pending.LaunchBootID == "" {
		return "", fmt.Errorf("read launch boot identity: %w", err)
	}
	if coordinator.deps.PrepareAuthorization != nil {
		if coordinator.deps.ObservePreparation == nil {
			return "", errors.New("preparation observation is unavailable")
		}
		observation, observeErr := coordinator.deps.ObservePreparation(handoffCtx)
		if observeErr != nil || !observation.Enabled || !sameProduct(observation.Product, installed) {
			return "", fmt.Errorf("installed product changed before preparation: %w", errors.Join(ErrStateConflict, observeErr))
		}
		err = coordinator.deps.PrepareAuthorization.AuthorizeAndSave(handoffCtx, PreparationDecision{Observation: observation, Release: release, Pending: pending, CurrentTime: coordinator.deps.Clock.Now})
	} else {
		err = coordinator.deps.Pending.CompareAndSave(handoffCtx, nil, pending)
	}
	if err != nil {
		return "", fmt.Errorf("persist prepared transaction: %w", err)
	}
	coordinator.deps.Events.Record(ctx, Event{Code: EventPrepared, TransactionID: pending.TransactionID})
	receipt, err := coordinator.deps.Launcher.Launch(handoffCtx, HandoffRequest{TransactionID: pending.TransactionID, Attempt: pending.Attempt, Artifact: artifact})
	if err != nil {
		return "", fmt.Errorf("launch detached update runner: %w", err)
	}
	if !receipt.Ready || validateProcessIdentity(&receipt.Runner) != nil || validateProcessIdentity(&receipt.Installer) != nil {
		return "", errors.New("detached runner did not provide durable ready evidence")
	}
	durable, err := coordinator.deps.Pending.Load(context.WithoutCancel(ctx))
	if err != nil || durable == nil || durable.TransactionID != pending.TransactionID || (durable.Phase != PhaseRunning && durable.Phase != PhaseInstallerRunning) ||
		durable.Runner == nil || durable.Installer == nil || *durable.Runner != receipt.Runner || *durable.Installer != receipt.Installer {
		return "", errors.New("runner readiness does not match durable transaction evidence")
	}
	coordinator.deps.Events.Record(context.WithoutCancel(ctx), Event{Code: EventHandedOff, TransactionID: pending.TransactionID})
	return OutcomeHandedOff, nil
}

// ResumePreparedRetry is the resident recovery-only entry point for an
// already persisted retry authorization. It never performs release discovery
// or creates a new transaction.
func (coordinator *Coordinator) ResumePreparedRetry(ctx context.Context) (Outcome, error) {
	if coordinator.deps.Launcher == nil || coordinator.deps.RetryGate == nil {
		return "", errors.New("prepared retry launcher is not configured")
	}
	if !coordinator.mu.TryLock() {
		return "", ErrBusy
	}
	defer coordinator.mu.Unlock()
	pending, err := coordinator.deps.Pending.Load(ctx)
	if err != nil {
		return "", err
	}
	if pending == nil || pending.Schema != PendingSchemaV2 || pending.Phase != PhasePrepared || pending.Attempt <= 1 || pending.SKU != coordinator.config.SKU {
		return OutcomeNoUpdate, nil
	}
	return coordinator.resumePreparedRetry(ctx, *pending, coordinator.deps.Clock.Now())
}

func (coordinator *Coordinator) Reconcile(ctx context.Context) (Outcome, error) {
	if !coordinator.mu.TryLock() {
		return "", ErrBusy
	}
	defer coordinator.mu.Unlock()

	pending, err := coordinator.deps.Pending.Load(ctx)
	if err != nil {
		return "", fmt.Errorf("load pending update: %w", err)
	}
	if pending == nil {
		return OutcomeNoUpdate, nil
	}
	bootID, err := coordinator.deps.Boot.CurrentBootID(ctx)
	if err != nil {
		return "", fmt.Errorf("read current boot identity: %w", err)
	}
	if bootID == "" {
		return "", errors.New("current boot identity is empty")
	}
	if err := pending.Validate(); err != nil {
		pending.Phase = PhaseRepairRequired
		pending.Result = ResultAmbiguous
		pending.UpdatedAt = coordinator.deps.Clock.Now()
		if saveErr := coordinator.deps.Pending.Save(ctx, *pending); saveErr != nil {
			return "", fmt.Errorf("persist invalid pending state: %w", saveErr)
		}
		return OutcomeRepairRequired, nil
	}
	observed := *pending
	savePending := func() error { return coordinator.deps.Pending.CompareAndSave(ctx, &observed, *pending) }
	// A scheduled 1618 retry is consumed by the explicit recovery entrypoint. Reconciliation
	// must not slide its durable deadline on every service poll.
	if pending.Phase == PhaseRolledBack && pending.Result == ResultRetryScheduled && pending.NextAttemptAt != nil {
		if pending.RetryDeadline != nil && !coordinator.deps.Clock.Now().Before(*pending.RetryDeadline) {
			pending.Result, pending.NextAttemptAt, pending.UpdatedAt = ResultBusyExhausted, nil, coordinator.deps.Clock.Now()
			if err := savePending(); err != nil {
				return "", err
			}
			return coordinator.retireTerminal(ctx, *pending, OutcomeRolledBack)
		}
		return OutcomeBackoff, nil
	}
	// Terminal records remain authoritative until ordered retirement. In
	// particular, never turn a committed record back into a live transaction
	// just because its former installer PID is still observable.
	switch pending.Phase {
	case PhaseCommitted:
		// A crash may have happened after the terminal write and before replay
		// persistence. With pending still present no newer transaction can
		// advance replay, so retrying this exact state is idempotent.
		if err := coordinator.deps.Replay.Save(ctx, pending.Replay); err != nil {
			return "", fmt.Errorf("resume committed replay state: %w", err)
		}
		return coordinator.retireTerminal(ctx, *pending, OutcomeCommitted)
	case PhaseRolledBack:
		return coordinator.retireTerminal(ctx, *pending, OutcomeRolledBack)
	case PhaseRepairRequired:
		return coordinator.retireProvedRepair(ctx, *pending, bootID)
	case PhaseOutcomeUnconfirmed:
		// A missing exit can leave a healthy candidate waiting for a full
		// restart. Once the volatile boot identity changes, re-observe the
		// installer server and installed product before finalizing it.
		if pending.LaunchBootID == "" || pending.LaunchBootID == bootID {
			return OutcomeOutcomeUnconfirmed, nil
		}
	}
	// A retry CAS may have committed just before service termination. Its
	// prepared record is still the same protected authorization; no MSI exit
	// can be inferred merely because the detached runner was not yet created.
	if pending.Schema == PendingSchemaV2 && pending.Phase == PhasePrepared && pending.Attempt > 1 {
		if pending.RetryDeadline != nil && coordinator.deps.Clock.Now().Before(*pending.RetryDeadline) {
			return OutcomeBackoff, nil
		}
	}
	for _, identity := range []*ProcessIdentity{pending.Runner, pending.Installer} {
		if identity == nil {
			continue
		}
		alive, probeErr := coordinator.deps.Processes.Alive(ctx, *identity)
		if probeErr != nil {
			return "", fmt.Errorf("probe transaction process identity: %w", probeErr)
		}
		if alive {
			// The runner owns the launch phases. Reconciliation must not rewrite
			// an authorized record while the runner may be advancing it by CAS.
			coordinator.deps.Events.Record(ctx, Event{Code: EventStillRunning, TransactionID: pending.TransactionID})
			return OutcomeStillRunning, nil
		}
	}
	// Missing exit evidence needs a stronger server STOPPED barrier and
	// cannot establish that a healthy candidate needs no reboot.
	idle, err := coordinator.deps.InstallerServer.Idle(ctx, pending.Exit == nil)
	if err != nil {
		return "", fmt.Errorf("probe Windows Installer server: %w", err)
	}
	if !idle {
		return OutcomeStillRunning, nil
	}
	products, err := coordinator.deps.Inventory.Products(ctx)
	if err != nil {
		return "", fmt.Errorf("enumerate installed product during reconciliation: %w", err)
	}
	if len(products) != 1 || products[0].Snapshot.SKU != coordinator.config.SKU {
		return coordinator.requireRepair(ctx, pending)
	}
	installed := products[0].Snapshot
	healthy, err := coordinator.deps.Health.Healthy(ctx, installed)
	if err != nil {
		return "", fmt.Errorf("probe installed product health: %w", err)
	}
	if !healthy {
		return coordinator.requireRepair(ctx, pending)
	}
	// Recheck the server after the installed-state observation. A concurrent
	// MSI can begin while inventory and health are being read.
	idle, err = coordinator.deps.InstallerServer.Idle(ctx, pending.Exit == nil)
	if err != nil {
		return "", fmt.Errorf("reprobe Windows Installer server: %w", err)
	}
	if !idle {
		return OutcomeStillRunning, nil
	}
	confirmed, err := coordinator.deps.Inventory.Products(ctx)
	if err != nil {
		return "", fmt.Errorf("reprobe installed product during reconciliation: %w", err)
	}
	if len(confirmed) != 1 || !sameProduct(confirmed[0].Snapshot, installed) {
		return OutcomeStillRunning, nil
	}
	if pending.Exit == nil {
		if sameProduct(installed, pending.Candidate) {
			if pending.LaunchBootID != "" && pending.LaunchBootID != bootID {
				return coordinator.commitCandidate(ctx, pending, savePending)
			}
			pending.Phase = PhaseOutcomeUnconfirmed
			pending.Result = ResultOutcomeUnconfirmed
			pending.UpdatedAt = coordinator.deps.Clock.Now()
			if err := savePending(); err != nil {
				return "", err
			}
			return OutcomeOutcomeUnconfirmed, nil
		}
		if sameProduct(installed, pending.Old) {
			pending.Phase = PhaseRolledBack
			pending.Result = ResultRolledBack
			if pending.Schema == PendingSchemaV2 && pending.Attempt > 1 && pending.RetryDeadline != nil && !coordinator.deps.Clock.Now().Before(*pending.RetryDeadline) {
				pending.Result = ResultBusyExhausted
			}
			pending.UpdatedAt = coordinator.deps.Clock.Now()
			if err := savePending(); err != nil {
				return "", err
			}
			if pending.Result == ResultBusyExhausted {
				return coordinator.retireTerminal(ctx, *pending, OutcomeRolledBack)
			}
			return OutcomeRolledBack, nil
		}
		return coordinator.requireRepair(ctx, pending)
	}
	if sameProduct(installed, pending.Candidate) {
		// A healthy candidate does not turn a failed MSI exit into success.
		// Reboot evidence belongs to this attempt only when msiexec returned a
		// reboot code; an unrelated system reboot flag is not sufficient.
		if pending.Exit.Code == 3010 || pending.Exit.Code == 1641 {
			if pending.LaunchBootID == "" {
				pending.Phase = PhaseOutcomeUnconfirmed
				pending.Result = ResultOutcomeUnconfirmed
				pending.UpdatedAt = coordinator.deps.Clock.Now()
				if err := savePending(); err != nil {
					return "", err
				}
				return OutcomeOutcomeUnconfirmed, nil
			}
			if pending.LaunchBootID != bootID {
				return coordinator.commitCandidate(ctx, pending, savePending)
			}
			pending.Phase = PhaseRebootPending
			pending.Result = ResultRebootRequired
			pending.UpdatedAt = coordinator.deps.Clock.Now()
			if err := savePending(); err != nil {
				return "", err
			}
			coordinator.deps.Events.Record(ctx, Event{Code: EventRebootPending, TransactionID: pending.TransactionID})
			return OutcomeRebootPending, nil
		}
		if pending.Exit.Code != 0 {
			return coordinator.requireRepair(ctx, pending)
		}
		return coordinator.commitCandidate(ctx, pending, savePending)
	}
	if sameProduct(installed, pending.Old) {
		pending.Phase = PhaseRolledBack
		pending.Result = ResultRolledBack
		pending.UpdatedAt = coordinator.deps.Clock.Now()
		pending.NextAttemptAt = nil
		outcome := OutcomeRolledBack
		if pending.Exit.Code == 1618 {
			pending.Result = ResultBusyExhausted
			if pending.Schema == PendingSchemaV2 && pending.RetryDeadline != nil && pending.Attempt < coordinator.config.MaxInstallerBusyRetries {
				delay := 30 * time.Second
				if pending.Attempt > 1 {
					delay = 120 * time.Second
				}
				next := coordinator.deps.Clock.Now().Add(delay)
				if !coordinator.deps.Clock.Now().Before(pending.PreparedAt) && next.Before(*pending.RetryDeadline) {
					pending.NextAttemptAt = &next
					pending.Result = ResultRetryScheduled
					outcome = OutcomeBackoff
				}
			}
		}
		if err := savePending(); err != nil {
			return "", err
		}
		coordinator.deps.Events.Record(ctx, Event{Code: EventRolledBack, TransactionID: pending.TransactionID})
		return outcome, nil
	}
	return coordinator.requireRepair(ctx, pending)
}

// retireProvedRepair records the historical ambiguity without replaying or
// converting a failed MSI exit into installation success.
func (coordinator *Coordinator) retireProvedRepair(ctx context.Context, pending PendingV1, bootID string) (Outcome, error) {
	if coordinator.config.SKU != update.Suite || pending.SKU != update.Suite || pending.Result != ResultAmbiguous ||
		coordinator.deps.RecoveryLock == nil || coordinator.deps.RetireRepair == nil {
		return OutcomeRepairRequired, nil
	}
	unlock, err := coordinator.deps.RecoveryLock()
	if err != nil {
		return OutcomeRepairRequired, nil
	}
	defer unlock()
	latest, err := coordinator.deps.Pending.Load(ctx)
	if err != nil {
		return "", err
	}
	if latest == nil {
		return OutcomeRepairRequired, nil
	}
	expected, err := MarshalPending(pending)
	if err != nil {
		return "", err
	}
	actual, err := MarshalPending(*latest)
	if err != nil {
		return "", err
	}
	if !bytes.Equal(expected, actual) {
		return OutcomeRepairRequired, nil
	}
	for _, identity := range []*ProcessIdentity{pending.Runner, pending.Installer} {
		if identity == nil {
			continue
		}
		alive, err := coordinator.deps.Processes.Alive(ctx, *identity)
		if err != nil {
			return "", err
		}
		if alive {
			return OutcomeRepairRequired, nil
		}
	}
	if pending.Exit != nil && (pending.Exit.Code == 3010 || pending.Exit.Code == 1641) &&
		(pending.LaunchBootID == "" || pending.LaunchBootID == bootID) {
		return OutcomeRepairRequired, nil
	}
	idle, err := coordinator.deps.InstallerServer.Idle(ctx, true)
	if err != nil {
		return "", err
	}
	if !idle {
		return OutcomeRepairRequired, nil
	}
	products, err := coordinator.deps.Inventory.Products(ctx)
	if err != nil {
		return "", err
	}
	if len(products) != 1 || products[0].Snapshot.SKU != pending.SKU {
		return OutcomeRepairRequired, nil
	}
	installed := products[0].Snapshot
	old := sameProduct(installed, pending.Old)
	candidate := sameProduct(installed, pending.Candidate)
	if !old && !candidate {
		return OutcomeRepairRequired, nil
	}
	if pending.Exit == nil && candidate && (pending.LaunchBootID == "" || pending.LaunchBootID == bootID) {
		return OutcomeRepairRequired, nil
	}
	healthy, err := coordinator.deps.Health.Healthy(ctx, installed)
	if err != nil {
		return "", err
	}
	if !healthy {
		return OutcomeRepairRequired, nil
	}
	idle, err = coordinator.deps.InstallerServer.Idle(ctx, true)
	if err != nil {
		return "", err
	}
	if !idle {
		return OutcomeRepairRequired, nil
	}
	confirmed, err := coordinator.deps.Inventory.Products(ctx)
	if err != nil {
		return "", err
	}
	if len(confirmed) != 1 || !sameProduct(confirmed[0].Snapshot, installed) {
		return OutcomeRepairRequired, nil
	}
	if err := coordinator.deps.RetireRepair(ctx, pending, installed); err != nil {
		return "", err
	}
	return OutcomeRepairRetired, nil
}

func (coordinator *Coordinator) retryInstaller(ctx context.Context, pending PendingV1, now time.Time) (Outcome, error) {
	if pending.Schema != PendingSchemaV2 || pending.Exit == nil || pending.Exit.Code != 1618 || pending.NextAttemptAt == nil || pending.RetryDeadline == nil {
		return OutcomeBackoff, nil
	}
	if now.Before(pending.PreparedAt) || !now.Before(*pending.RetryDeadline) || pending.Attempt >= coordinator.config.MaxInstallerBusyRetries {
		previous := pending
		pending.Result, pending.NextAttemptAt, pending.UpdatedAt = ResultBusyExhausted, nil, now
		if err := coordinator.deps.Pending.CompareAndSave(ctx, &previous, pending); err != nil {
			return "", err
		}
		return coordinator.retireTerminal(ctx, pending, OutcomeRolledBack)
	}
	if now.Before(*pending.NextAttemptAt) || coordinator.deps.RetryGate == nil {
		return OutcomeBackoff, nil
	}
	for _, identity := range []*ProcessIdentity{pending.Runner, pending.Installer} {
		if identity == nil {
			continue
		}
		alive, err := coordinator.deps.Processes.Alive(ctx, *identity)
		if err != nil || alive {
			return OutcomeBackoff, err
		}
	}
	idle, err := coordinator.deps.InstallerServer.Idle(ctx, true)
	if err != nil || !idle {
		return OutcomeBackoff, err
	}
	products, err := coordinator.deps.Inventory.Products(ctx)
	if err != nil {
		return OutcomeBackoff, err
	}
	if len(products) != 1 || !sameProduct(products[0].Snapshot, pending.Old) {
		return coordinator.requireRepair(ctx, &pending)
	}
	healthy, err := coordinator.deps.Health.Healthy(ctx, pending.Old)
	if err != nil || !healthy {
		return OutcomeBackoff, err
	}
	allowed, err := coordinator.deps.RetryGate.AllowRetry(ctx, pending)
	if err != nil || !allowed {
		return OutcomeBackoff, err
	}
	idle, err = coordinator.deps.InstallerServer.Idle(ctx, true)
	if err != nil || !idle {
		return OutcomeBackoff, err
	}
	confirmed, err := coordinator.deps.Inventory.Products(ctx)
	if err != nil || len(confirmed) != 1 || !sameProduct(confirmed[0].Snapshot, pending.Old) {
		return OutcomeBackoff, err
	}
	identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(pending.SKU), pending.Candidate.PackageVersion)
	if err != nil {
		return "", err
	}
	artifact := StagedArtifact{Handle: fmt.Sprintf("%s/%d/%s", pending.SKU, pending.Replay.Sequence, identity.AssetName), SHA256: pending.ArtifactSHA256}
	previous := pending
	pending.Attempt++
	pending.Phase, pending.Result = PhasePrepared, ResultNone
	pending.Runner, pending.Installer, pending.InstallerThread, pending.Exit, pending.NextAttemptAt = nil, nil, nil, nil, nil
	pending.UpdatedAt = now
	if err := coordinator.deps.Pending.CompareAndSave(ctx, &previous, pending); err != nil {
		return "", err
	}
	return coordinator.launchPreparedRetry(ctx, pending, artifact)
}

func (coordinator *Coordinator) resumePreparedRetry(ctx context.Context, pending PendingV1, now time.Time) (Outcome, error) {
	if err := pending.Validate(); err != nil || pending.Phase != PhasePrepared || pending.Installer != nil || pending.InstallerThread != nil || pending.Exit != nil {
		return OutcomeRepairRequired, errors.New("prepared retry has inconsistent installer evidence")
	}
	if pending.RetryDeadline == nil || pending.Attempt > coordinator.config.MaxInstallerBusyRetries || now.Before(pending.PreparedAt) || !now.Before(*pending.RetryDeadline) {
		return OutcomeBackoff, nil
	}
	if coordinator.deps.RetryGate == nil {
		return OutcomeBackoff, nil
	}
	if pending.Runner != nil {
		alive, err := coordinator.deps.Processes.Alive(ctx, *pending.Runner)
		if err != nil || alive {
			return OutcomeStillRunning, err
		}
		previous := pending
		pending.Runner = nil
		pending.UpdatedAt = now
		if err := coordinator.deps.Pending.CompareAndSave(ctx, &previous, pending); err != nil {
			return "", err
		}
	}
	idle, err := coordinator.deps.InstallerServer.Idle(ctx, true)
	if err != nil || !idle {
		return OutcomeBackoff, err
	}
	products, err := coordinator.deps.Inventory.Products(ctx)
	if err != nil || len(products) != 1 || !sameProduct(products[0].Snapshot, pending.Old) {
		return OutcomeBackoff, err
	}
	healthy, err := coordinator.deps.Health.Healthy(ctx, pending.Old)
	if err != nil || !healthy {
		return OutcomeBackoff, err
	}
	allowed, err := coordinator.deps.RetryGate.AllowRetry(ctx, pending)
	if err != nil || !allowed {
		return OutcomeBackoff, err
	}
	idle, err = coordinator.deps.InstallerServer.Idle(ctx, true)
	if err != nil || !idle {
		return OutcomeBackoff, err
	}
	confirmed, err := coordinator.deps.Inventory.Products(ctx)
	if err != nil || len(confirmed) != 1 || !sameProduct(confirmed[0].Snapshot, pending.Old) {
		return OutcomeBackoff, err
	}
	identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(pending.SKU), pending.Candidate.PackageVersion)
	if err != nil {
		return "", err
	}
	artifact := StagedArtifact{Handle: fmt.Sprintf("%s/%d/%s", pending.SKU, pending.Replay.Sequence, identity.AssetName), SHA256: pending.ArtifactSHA256}
	return coordinator.launchPreparedRetry(ctx, pending, artifact)
}

func (coordinator *Coordinator) launchPreparedRetry(ctx context.Context, pending PendingV1, artifact StagedArtifact) (Outcome, error) {
	receipt, err := coordinator.deps.Launcher.Launch(ctx, HandoffRequest{TransactionID: pending.TransactionID, Attempt: pending.Attempt, Artifact: artifact})
	if err != nil {
		return "", err
	}
	if !receipt.Ready || validateProcessIdentity(&receipt.Runner) != nil || validateProcessIdentity(&receipt.Installer) != nil {
		return "", errors.New("retry runner has no durable ready evidence")
	}
	durable, err := coordinator.deps.Pending.Load(context.WithoutCancel(ctx))
	if err != nil {
		return "", err
	}
	if durable == nil || durable.TransactionID != pending.TransactionID || durable.Attempt != pending.Attempt || (durable.Phase != PhaseRunning && durable.Phase != PhaseInstallerRunning) || durable.Runner == nil || durable.Installer == nil || *durable.Runner != receipt.Runner || *durable.Installer != receipt.Installer {
		return "", errors.New("retry readiness does not match durable transaction")
	}
	return OutcomeHandedOff, nil
}

func (coordinator *Coordinator) retireTerminal(ctx context.Context, pending PendingV1, outcome Outcome) (Outcome, error) {
	result := lastResultFromPending(pending)
	if err := result.Validate(); err != nil {
		return "", err
	}
	if err := coordinator.deps.LastResult.Save(ctx, result); err != nil {
		return "", fmt.Errorf("persist last transaction result: %w", err)
	}
	if err := coordinator.deps.Pending.CompareAndClear(ctx, pending); err != nil {
		return "", fmt.Errorf("retire terminal transaction: %w", err)
	}
	return outcome, nil
}

func (coordinator *Coordinator) commitCandidate(ctx context.Context, pending *PendingV1, savePending func() error) (Outcome, error) {
	pending.Phase = PhaseCommitted
	pending.Result = ResultInstalled
	pending.NextAttemptAt = nil
	pending.UpdatedAt = coordinator.deps.Clock.Now()
	if err := savePending(); err != nil {
		return "", err
	}
	// Replay advances only after the complete candidate product is healthy.
	if err := coordinator.deps.Replay.Save(ctx, pending.Replay); err != nil {
		return "", fmt.Errorf("persist committed replay state: %w", err)
	}
	coordinator.deps.Events.Record(ctx, Event{Code: EventCommitted, TransactionID: pending.TransactionID})
	return OutcomeCommitted, nil
}

func (coordinator *Coordinator) requireRepair(ctx context.Context, pending *PendingV1) (Outcome, error) {
	observed := *pending
	pending.Phase = PhaseRepairRequired
	pending.Result = ResultAmbiguous
	pending.NextAttemptAt = nil
	pending.UpdatedAt = coordinator.deps.Clock.Now()
	if err := coordinator.deps.Pending.CompareAndSave(ctx, &observed, *pending); err != nil {
		return "", fmt.Errorf("persist repair-required state: %w", err)
	}
	coordinator.deps.Events.Record(ctx, Event{Code: EventRepairNeeded, TransactionID: pending.TransactionID})
	return OutcomeRepairRequired, nil
}

func productFromRelease(release update.Release) (ProductSnapshot, error) {
	payload := release.Payload()
	var sku mapi.MachineSKU
	switch payload.SKU {
	case update.System:
		sku = mapi.MachineSKUSystem
	case update.Suite:
		sku = mapi.MachineSKUSuite
	default:
		return ProductSnapshot{}, ErrUnauthorizedCandidate
	}
	identity, err := mapi.NewMachinePackageIdentity(sku, payload.Version)
	if err != nil || identity.Sequence != payload.Sequence {
		return ProductSnapshot{}, ErrUnauthorizedCandidate
	}
	contained := make(map[string]string, len(payload.Contained))
	for _, component := range payload.Contained {
		if _, duplicate := contained[component.Component]; component.Component == "" || component.Version == "" || duplicate {
			return ProductSnapshot{}, ErrUnauthorizedCandidate
		}
		contained[component.Component] = component.Version
	}
	return ProductSnapshot{SKU: payload.SKU, PackageVersion: payload.Version, ProductVersion: identity.ProductVersion, ProductCode: identity.ProductCode, Contained: contained}, nil
}

func sameProduct(left, right ProductSnapshot) bool {
	return left.SKU == right.SKU && left.PackageVersion == right.PackageVersion && left.ProductVersion == right.ProductVersion && left.ProductCode == right.ProductCode && reflect.DeepEqual(left.Contained, right.Contained)
}

func anyNil(values ...any) bool {
	for _, value := range values {
		if value == nil || (reflect.ValueOf(value).Kind() == reflect.Ptr && reflect.ValueOf(value).IsNil()) {
			return true
		}
	}
	return false
}
