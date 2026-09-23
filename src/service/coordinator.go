package service

import (
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
)

type Outcome string

const (
	OutcomeNoUpdate       Outcome = "no-update"
	OutcomeHandedOff      Outcome = "handed-off"
	OutcomeStillRunning   Outcome = "still-running"
	OutcomeCommitted      Outcome = "committed"
	OutcomeRolledBack     Outcome = "rolled-back"
	OutcomeRebootPending  Outcome = "reboot-pending"
	OutcomeRepairRequired Outcome = "repair-required"
	OutcomeBackoff        Outcome = "backoff"
)

const (
	StatusOffline = "offline"
	StatusReady   = "ready"
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

type DiscoveryRequest struct {
	SKU       update.SKU
	Installed ProductSnapshot
	Replay    update.ReplayState
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
	Artifact      StagedArtifact
}

type HandoffReceipt struct {
	Runner    ProcessIdentity
	Installer ProcessIdentity
	Ready     bool
}

type ServiceStatus struct {
	ConsecutiveFailures uint
	NextCheckAt         time.Time
	LastCode            string
}

type ReleaseSource interface {
	Discover(context.Context, DiscoveryRequest) (update.Release, error)
}

type ArtifactStore interface {
	Stage(context.Context, update.Release) (StagedArtifact, error)
}

type ProductInventory interface {
	Products(context.Context) ([]InstalledProduct, error)
}

type RunnerLauncher interface {
	Launch(context.Context, HandoffRequest) (HandoffReceipt, error)
}

type HealthProbe interface {
	Healthy(context.Context, ProductSnapshot) (bool, error)
}

type ProcessProbe interface {
	Alive(context.Context, ProcessIdentity) (bool, error)
}

type RebootProbe interface {
	Pending(context.Context) (bool, error)
}

type PendingStore interface {
	Load(context.Context) (*PendingV1, error)
	Save(context.Context, PendingV1) error
	Clear(context.Context) error
}

type ReplayStore interface {
	Load(context.Context, update.SKU) (update.ReplayState, error)
	Save(context.Context, update.ReplayState) error
}

type StatusStore interface {
	Load(context.Context) (ServiceStatus, error)
	Save(context.Context, ServiceStatus) error
}

type EventSink interface {
	Record(context.Context, Event)
}

type Clock interface{ Now() time.Time }
type Backoff interface{ Delay(uint) time.Duration }
type IDGenerator interface{ NewID() string }

type Dependencies struct {
	ReleaseSource ReleaseSource
	Artifacts     ArtifactStore
	Inventory     ProductInventory
	Launcher      RunnerLauncher
	Health        HealthProbe
	Processes     ProcessProbe
	Reboot        RebootProbe
	Pending       PendingStore
	Replay        ReplayStore
	Status        StatusStore
	Events        EventSink
	Clock         Clock
	Backoff       Backoff
	IDs           IDGenerator
}

type Coordinator struct {
	config Config
	deps   Dependencies
	mu     sync.Mutex
}

func NewCoordinator(config Config, deps Dependencies) (*Coordinator, error) {
	if config.SKU != update.System && config.SKU != update.Suite {
		return nil, errors.New("coordinator requires a fixed machine SKU")
	}
	if config.MaxInstallerBusyRetries == 0 {
		return nil, errors.New("coordinator requires a bounded installer-busy retry count")
	}
	if anyNil(deps.ReleaseSource, deps.Artifacts, deps.Inventory, deps.Launcher, deps.Health, deps.Processes, deps.Reboot, deps.Pending, deps.Replay, deps.Status, deps.Events, deps.Clock, deps.Backoff, deps.IDs) {
		return nil, errors.New("coordinator dependencies are incomplete")
	}
	return &Coordinator{config: config, deps: deps}, nil
}

func (coordinator *Coordinator) CheckAndStart(ctx context.Context) (Outcome, error) {
	if !coordinator.mu.TryLock() {
		return "", ErrBusy
	}
	defer coordinator.mu.Unlock()

	now := coordinator.deps.Clock.Now()
	status, err := coordinator.deps.Status.Load(ctx)
	if err != nil {
		return "", fmt.Errorf("load service status: %w", err)
	}
	if !status.NextCheckAt.IsZero() && now.Before(status.NextCheckAt) {
		return OutcomeBackoff, nil
	}

	attempt := uint(1)
	pending, err := coordinator.deps.Pending.Load(ctx)
	if err != nil {
		return "", fmt.Errorf("load pending update: %w", err)
	}
	if pending != nil {
		if pending.Phase != PhaseRolledBack || pending.Result != ResultRetryScheduled || pending.NextAttemptAt == nil || now.Before(*pending.NextAttemptAt) {
			return OutcomeStillRunning, nil
		}
		attempt = pending.Attempt + 1
		if attempt > coordinator.config.MaxInstallerBusyRetries {
			return OutcomeRolledBack, nil
		}
		if err := coordinator.deps.Pending.Clear(ctx); err != nil {
			return "", fmt.Errorf("clear retried transaction: %w", err)
		}
	}

	products, err := coordinator.deps.Inventory.Products(ctx)
	if err != nil {
		return "", fmt.Errorf("enumerate installed product: %w", err)
	}
	if len(products) != 1 || products[0].Snapshot.SKU != coordinator.config.SKU {
		return OutcomeRepairRequired, nil
	}
	installed := products[0].Snapshot
	healthy, err := coordinator.deps.Health.Healthy(ctx, installed)
	if err != nil {
		return "", fmt.Errorf("check installed product health: %w", err)
	}
	if !healthy {
		return OutcomeRepairRequired, nil
	}
	previousReplay, err := coordinator.deps.Replay.Load(ctx, coordinator.config.SKU)
	if err != nil {
		return "", fmt.Errorf("load release replay state: %w", err)
	}
	release, err := coordinator.deps.ReleaseSource.Discover(ctx, DiscoveryRequest{SKU: coordinator.config.SKU, Installed: installed, Replay: previousReplay})
	if err != nil {
		if errors.Is(err, ErrOffline) {
			return coordinator.backoffOffline(ctx, status, now)
		}
		return "", fmt.Errorf("discover authorized release: %w", err)
	}
	candidate, err := productFromRelease(release)
	if err != nil || candidate.SKU != coordinator.config.SKU || release.Namespace() != string(coordinator.config.SKU) {
		return "", ErrUnauthorizedCandidate
	}
	nextReplay, err := update.AcceptReplay(previousReplay, release)
	if err != nil {
		return "", fmt.Errorf("authorize replay state: %w", err)
	}
	if installed.ProductCode == candidate.ProductCode {
		return OutcomeNoUpdate, nil
	}

	artifact, err := coordinator.deps.Artifacts.Stage(ctx, release)
	if err != nil {
		if errors.Is(err, ErrOffline) {
			return coordinator.backoffOffline(ctx, status, now)
		}
		return "", fmt.Errorf("stage authenticated artifact: %w", err)
	}
	if artifact.Handle == "" || artifact.SHA256 != release.Payload().Artifact.SHA256 {
		return "", errors.New("artifact store returned an unverified handle")
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	pending = &PendingV1{
		Schema: PendingSchemaV1, TransactionID: coordinator.deps.IDs.NewID(), SKU: coordinator.config.SKU,
		Old: installed, Candidate: candidate, Replay: nextReplay, ArtifactSHA256: artifact.SHA256,
		Phase: PhasePrepared, PreparedAt: now, UpdatedAt: now, Attempt: attempt,
	}
	if err := coordinator.deps.Pending.Save(ctx, *pending); err != nil {
		return "", fmt.Errorf("persist prepared transaction: %w", err)
	}
	coordinator.deps.Events.Record(ctx, Event{Code: EventPrepared, TransactionID: pending.TransactionID})
	if err := ctx.Err(); err != nil {
		return "", err
	}
	receipt, err := coordinator.deps.Launcher.Launch(ctx, HandoffRequest{TransactionID: pending.TransactionID, Artifact: artifact})
	if err != nil {
		return "", fmt.Errorf("launch detached update runner: %w", err)
	}
	if !receipt.Ready || validateProcessIdentity(&receipt.Runner) != nil || validateProcessIdentity(&receipt.Installer) != nil {
		return "", errors.New("detached runner did not provide durable ready evidence")
	}
	pending.Runner = &receipt.Runner
	pending.Installer = &receipt.Installer
	pending.Phase = PhaseInstallerRunning
	pending.UpdatedAt = coordinator.deps.Clock.Now()
	if err := coordinator.deps.Pending.Save(context.WithoutCancel(ctx), *pending); err != nil {
		return "", fmt.Errorf("persist handoff evidence: %w", err)
	}
	_ = coordinator.deps.Status.Save(context.WithoutCancel(ctx), ServiceStatus{LastCode: StatusReady})
	coordinator.deps.Events.Record(context.WithoutCancel(ctx), Event{Code: EventHandedOff, TransactionID: pending.TransactionID})
	return OutcomeHandedOff, nil
}

func (coordinator *Coordinator) backoffOffline(ctx context.Context, status ServiceStatus, now time.Time) (Outcome, error) {
	status.ConsecutiveFailures++
	status.NextCheckAt = now.Add(coordinator.deps.Backoff.Delay(status.ConsecutiveFailures))
	status.LastCode = StatusOffline
	if err := coordinator.deps.Status.Save(ctx, status); err != nil {
		return "", fmt.Errorf("persist offline backoff: %w", err)
	}
	coordinator.deps.Events.Record(ctx, Event{Code: EventOffline})
	return OutcomeBackoff, nil
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
	if err := pending.Validate(); err != nil {
		pending.Phase = PhaseRepairRequired
		pending.Result = ResultAmbiguous
		pending.UpdatedAt = coordinator.deps.Clock.Now()
		if saveErr := coordinator.deps.Pending.Save(ctx, *pending); saveErr != nil {
			return "", fmt.Errorf("persist invalid pending state: %w", saveErr)
		}
		return OutcomeRepairRequired, nil
	}
	// A scheduled 1618 retry is consumed only by CheckAndStart. Reconciliation
	// must not slide its durable deadline on every service poll.
	if pending.Phase == PhaseRolledBack && pending.Result == ResultRetryScheduled && pending.NextAttemptAt != nil {
		return OutcomeBackoff, nil
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
			pending.Phase = PhaseStillRunning
			pending.UpdatedAt = coordinator.deps.Clock.Now()
			if err := coordinator.deps.Pending.Save(ctx, *pending); err != nil {
				return "", err
			}
			coordinator.deps.Events.Record(ctx, Event{Code: EventStillRunning, TransactionID: pending.TransactionID})
			return OutcomeStillRunning, nil
		}
	}
	if pending.Exit == nil {
		return coordinator.requireRepair(ctx, pending)
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
	if sameProduct(installed, pending.Candidate) {
		rebootPending, err := coordinator.deps.Reboot.Pending(ctx)
		if err != nil {
			return "", fmt.Errorf("probe pending reboot: %w", err)
		}
		if rebootPending {
			pending.Phase = PhaseRebootPending
			pending.Result = ResultRebootRequired
			pending.UpdatedAt = coordinator.deps.Clock.Now()
			if err := coordinator.deps.Pending.Save(ctx, *pending); err != nil {
				return "", err
			}
			coordinator.deps.Events.Record(ctx, Event{Code: EventRebootPending, TransactionID: pending.TransactionID})
			return OutcomeRebootPending, nil
		}
		pending.Phase = PhaseCommitted
		pending.Result = ResultInstalled
		pending.NextAttemptAt = nil
		pending.UpdatedAt = coordinator.deps.Clock.Now()
		if err := coordinator.deps.Pending.Save(ctx, *pending); err != nil {
			return "", err
		}
		// Replay advances only after the complete candidate product is healthy.
		if err := coordinator.deps.Replay.Save(ctx, pending.Replay); err != nil {
			return "", fmt.Errorf("persist committed replay state: %w", err)
		}
		coordinator.deps.Events.Record(ctx, Event{Code: EventCommitted, TransactionID: pending.TransactionID})
		return OutcomeCommitted, nil
	}
	if sameProduct(installed, pending.Old) {
		pending.Phase = PhaseRolledBack
		pending.Result = ResultRolledBack
		pending.UpdatedAt = coordinator.deps.Clock.Now()
		pending.NextAttemptAt = nil
		outcome := OutcomeRolledBack
		if pending.Exit.Code == 1618 && pending.Attempt < coordinator.config.MaxInstallerBusyRetries {
			next := coordinator.deps.Clock.Now().Add(coordinator.deps.Backoff.Delay(pending.Attempt))
			pending.NextAttemptAt = &next
			pending.Result = ResultRetryScheduled
			outcome = OutcomeBackoff
		}
		if err := coordinator.deps.Pending.Save(ctx, *pending); err != nil {
			return "", err
		}
		coordinator.deps.Events.Record(ctx, Event{Code: EventRolledBack, TransactionID: pending.TransactionID})
		return outcome, nil
	}
	return coordinator.requireRepair(ctx, pending)
}

func (coordinator *Coordinator) requireRepair(ctx context.Context, pending *PendingV1) (Outcome, error) {
	pending.Phase = PhaseRepairRequired
	pending.Result = ResultAmbiguous
	pending.NextAttemptAt = nil
	pending.UpdatedAt = coordinator.deps.Clock.Now()
	if err := coordinator.deps.Pending.Save(ctx, *pending); err != nil {
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
