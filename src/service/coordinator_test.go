package service

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

var coordinatorNow = time.Date(2026, 9, 23, 8, 0, 0, 0, time.UTC)

func TestCoordinatorPinsInstalledSKUAndRequiresExactlyOneProduct(t *testing.T) {
	for _, test := range []struct {
		name     string
		products []InstalledProduct
	}{
		{"no product", nil},
		{"two products", []InstalledProduct{{Snapshot: oldProduct(update.System)}, {Snapshot: oldProduct(update.System)}}},
		{"foreign SKU", []InstalledProduct{{Snapshot: oldProduct(update.Suite)}}},
	} {
		t.Run(test.name, func(t *testing.T) {
			deps := defaultDependencies(t)
			deps.Inventory = &fakeInventory{products: test.products}
			coordinator := mustCoordinator(t, update.System, deps)
			outcome, err := coordinator.CheckAndStart(context.Background())
			if err != nil || outcome != OutcomeRepairRequired {
				t.Fatalf("CheckAndStart() = %q, %v; want repair-required", outcome, err)
			}
			if deps.ReleaseSource.(*fakeReleaseSource).calls != 0 {
				t.Fatal("release discovery ran without exactly one installed product in the pinned SKU")
			}
		})
	}
}

func TestCoordinatorSerializesAndCancelsBeforeHandoff(t *testing.T) {
	deps := defaultDependencies(t)
	entered := make(chan struct{})
	releaseStage := make(chan struct{})
	deps.Artifacts = &fakeArtifactStore{entered: entered, release: releaseStage}
	coordinator := mustCoordinator(t, update.System, deps)

	firstDone := make(chan error, 1)
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		_, err := coordinator.CheckAndStart(ctx)
		firstDone <- err
	}()
	<-entered
	if _, err := coordinator.CheckAndStart(context.Background()); !errors.Is(err, ErrBusy) {
		t.Fatalf("concurrent CheckAndStart() error = %v; want ErrBusy", err)
	}
	cancel()
	close(releaseStage)
	if err := <-firstDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled CheckAndStart() error = %v", err)
	}
	if deps.Launcher.(*fakeLauncher).calls != 0 {
		t.Fatal("launcher was called after cancellation before handoff")
	}
}

func TestCoordinatorBacksOffOfflineWithoutPromptLoop(t *testing.T) {
	deps := defaultDependencies(t)
	source := deps.ReleaseSource.(*fakeReleaseSource)
	source.err = ErrOffline
	coordinator := mustCoordinator(t, update.System, deps)

	if outcome, err := coordinator.CheckAndStart(context.Background()); err != nil || outcome != OutcomeBackoff {
		t.Fatalf("first CheckAndStart() = %q, %v", outcome, err)
	}
	if outcome, err := coordinator.CheckAndStart(context.Background()); err != nil || outcome != OutcomeBackoff {
		t.Fatalf("second CheckAndStart() = %q, %v", outcome, err)
	}
	if source.calls != 1 {
		t.Fatalf("offline release checks = %d; want one bounded attempt", source.calls)
	}
	status := deps.Status.(*memoryStatusStore).status
	if status.NextCheckAt.IsZero() || status.LastCode != StatusOffline || strings.Contains(strings.ToLower(status.LastCode), "prompt") {
		t.Fatalf("offline status = %#v", status)
	}
}

func TestCoordinatorBacksOffWhenArtifactDownloadIsOffline(t *testing.T) {
	deps := defaultDependencies(t)
	deps.Artifacts = &fakeArtifactStore{err: ErrMachineProxyAuthentication}
	coordinator := mustCoordinator(t, update.System, deps)

	outcome, err := coordinator.CheckAndStart(context.Background())
	if err != nil || outcome != OutcomeBackoff {
		t.Fatalf("CheckAndStart() = %q, %v; want backoff", outcome, err)
	}
	status := deps.Status.(*memoryStatusStore).status
	if status.ConsecutiveFailures != 1 || status.NextCheckAt.IsZero() || status.LastCode != StatusOffline {
		t.Fatalf("offline artifact status = %#v", status)
	}
	if deps.Launcher.(*fakeLauncher).calls != 0 {
		t.Fatal("offline artifact reached installer handoff")
	}
}

func TestCoordinatorPersistsPreparedStateBeforeBoundedHandoff(t *testing.T) {
	deps := defaultDependencies(t)
	coordinator := mustCoordinator(t, update.System, deps)
	outcome, err := coordinator.CheckAndStart(context.Background())
	if err != nil || outcome != OutcomeHandedOff {
		t.Fatalf("CheckAndStart() = %q, %v", outcome, err)
	}
	store := deps.Pending.(*memoryPendingStore)
	if !reflect.DeepEqual(store.phases, []Phase{PhasePrepared, PhaseInstallerRunning}) {
		t.Fatalf("persisted phases = %v", store.phases)
	}
	launcher := deps.Launcher.(*fakeLauncher)
	if launcher.calls != 1 || launcher.request.TransactionID != "tx-123" || launcher.request.Artifact.Handle != "protected-artifact" {
		t.Fatalf("handoff = %#v after %d calls", launcher.request, launcher.calls)
	}
	if store.pending == nil || store.pending.Replay.Sequence == 0 || store.pending.Candidate.SKU != update.System {
		t.Fatalf("pending authorization was incomplete: %#v", store.pending)
	}
}

func TestCoordinatorRejectsCrossSKUReleaseBeforeStaging(t *testing.T) {
	deps := defaultDependencies(t)
	deps.ReleaseSource = &fakeReleaseSource{release: authorizedRelease(t, update.Suite, "4.0.1")}
	coordinator := mustCoordinator(t, update.System, deps)
	if _, err := coordinator.CheckAndStart(context.Background()); !errors.Is(err, ErrUnauthorizedCandidate) {
		t.Fatalf("CheckAndStart() error = %v; want ErrUnauthorizedCandidate", err)
	}
	if deps.Artifacts.(*fakeArtifactStore).calls != 0 || deps.Launcher.(*fakeLauncher).calls != 0 {
		t.Fatal("cross-SKU release reached privileged staging or launch")
	}
}

func TestReconcileUsesProcessCreationIdentityAndFullProductHealth(t *testing.T) {
	tests := []struct {
		name       string
		products   []InstalledProduct
		healthy    bool
		exit       *ExitEvidence
		reboot     bool
		alive      bool
		want       Outcome
		wantPhase  Phase
		wantReplay bool
	}{
		{"still running", []InstalledProduct{{Snapshot: oldProduct(update.System)}}, true, exitEvidence(0), false, true, OutcomeStillRunning, PhaseStillRunning, false},
		{"healthy candidate commits", []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}}, true, exitEvidence(0), false, false, OutcomeCommitted, PhaseCommitted, true},
		{"healthy old rolls back", []InstalledProduct{{Snapshot: oldProduct(update.System)}}, true, exitEvidence(1603), false, false, OutcomeRolledBack, PhaseRolledBack, false},
		{"reboot remains pending", []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}}, true, exitEvidence(3010), true, false, OutcomeRebootPending, PhaseRebootPending, false},
		{"missing exit evidence repairs", []InstalledProduct{{Snapshot: oldProduct(update.System)}}, true, nil, false, false, OutcomeRepairRequired, PhaseRepairRequired, false},
		{"partial candidate repairs", []InstalledProduct{{Snapshot: candidateProduct(t, update.System, "4.0.1")}}, false, exitEvidence(0), false, false, OutcomeRepairRequired, PhaseRepairRequired, false},
		{"zero products repairs", nil, false, exitEvidence(0), false, false, OutcomeRepairRequired, PhaseRepairRequired, false},
		{"two products repair", []InstalledProduct{{Snapshot: oldProduct(update.System)}, {Snapshot: candidateProduct(t, update.System, "4.0.1")}}, true, exitEvidence(0), false, false, OutcomeRepairRequired, PhaseRepairRequired, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			deps := defaultDependencies(t)
			pending := pendingForReconcile(t, test.exit)
			deps.Pending = &memoryPendingStore{pending: &pending}
			deps.Inventory = &fakeInventory{products: test.products}
			deps.Health = fakeHealthProbe{healthy: test.healthy}
			deps.Processes = &fakeProcessProbe{alive: test.alive}
			deps.Reboot = fakeRebootProbe(test.reboot)
			coordinator := mustCoordinator(t, update.System, deps)
			outcome, err := coordinator.Reconcile(context.Background())
			if err != nil || outcome != test.want {
				t.Fatalf("Reconcile() = %q, %v; want %q", outcome, err, test.want)
			}
			stored := deps.Pending.(*memoryPendingStore).pending
			if stored == nil || stored.Phase != test.wantPhase {
				t.Fatalf("stored phase = %#v; want %q", stored, test.wantPhase)
			}
			gotReplay := deps.Replay.(*memoryReplayStore).saves > 0
			if gotReplay != test.wantReplay {
				t.Fatalf("replay advanced = %v; want %v", gotReplay, test.wantReplay)
			}
			if test.alive {
				probe := deps.Processes.(*fakeProcessProbe)
				if len(probe.seen) == 0 || probe.seen[0].CreatedAtUnixNano == 0 {
					t.Fatal("process probe did not receive PID plus creation time")
				}
			}
		})
	}
}

func TestReconcileBoundsInstallerBusyRetries(t *testing.T) {
	for _, attempt := range []uint{1, 3} {
		deps := defaultDependencies(t)
		pending := pendingForReconcile(t, exitEvidence(1618))
		pending.Attempt = attempt
		deps.Pending = &memoryPendingStore{pending: &pending}
		deps.Inventory = &fakeInventory{products: []InstalledProduct{{Snapshot: oldProduct(update.System)}}}
		coordinator := mustCoordinator(t, update.System, deps)
		outcome, err := coordinator.Reconcile(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		stored := deps.Pending.(*memoryPendingStore).pending
		if attempt < 3 {
			if outcome != OutcomeBackoff || stored.Result != ResultRetryScheduled || stored.NextAttemptAt == nil {
				t.Fatalf("attempt %d was not scheduled: %q %#v", attempt, outcome, stored)
			}
		} else if outcome != OutcomeRolledBack || stored.NextAttemptAt != nil {
			t.Fatalf("attempt %d exceeded bound incorrectly: %q %#v", attempt, outcome, stored)
		}
	}
}

func TestReconcilePreservesInstallerBusyRetryDeadline(t *testing.T) {
	deps := defaultDependencies(t)
	pending := pendingForReconcile(t, exitEvidence(1618))
	pending.Phase = PhaseRolledBack
	pending.Result = ResultRetryScheduled
	deadline := coordinatorNow.Add(15 * time.Minute)
	pending.NextAttemptAt = &deadline
	deps.Pending = &memoryPendingStore{pending: &pending}
	coordinator := mustCoordinator(t, update.System, deps)

	outcome, err := coordinator.Reconcile(context.Background())
	if err != nil || outcome != OutcomeBackoff {
		t.Fatalf("Reconcile() = %q, %v", outcome, err)
	}
	stored := deps.Pending.(*memoryPendingStore).pending
	if stored == nil || stored.NextAttemptAt == nil || !stored.NextAttemptAt.Equal(deadline) {
		t.Fatalf("retry deadline slid from %v to %#v", deadline, stored)
	}
}

func defaultDependencies(t *testing.T) Dependencies {
	t.Helper()
	release := authorizedRelease(t, update.System, "4.0.1")
	pending := &memoryPendingStore{}
	return Dependencies{
		ReleaseSource: &fakeReleaseSource{release: release},
		Artifacts:     &fakeArtifactStore{},
		Inventory:     &fakeInventory{products: []InstalledProduct{{Snapshot: oldProduct(update.System)}}},
		Launcher:      &fakeLauncher{pending: pending, receipt: HandoffReceipt{Runner: ProcessIdentity{PID: 41, CreatedAtUnixNano: 1001}, Installer: ProcessIdentity{PID: 42, CreatedAtUnixNano: 1002}, Ready: true}},
		Health:        fakeHealthProbe{healthy: true},
		Processes:     &fakeProcessProbe{},
		Reboot:        fakeRebootProbe(false),
		Pending:       pending,
		Replay:        &memoryReplayStore{},
		Status:        &memoryStatusStore{},
		Events:        &memoryEventSink{},
		Clock:         fixedClock{coordinatorNow},
		Backoff:       fixedBackoff(time.Hour),
		IDs:           fixedIDs("tx-123"),
	}
}

func mustCoordinator(t *testing.T, sku update.SKU, deps Dependencies) *Coordinator {
	t.Helper()
	coordinator, err := NewCoordinator(Config{SKU: sku, MaxInstallerBusyRetries: 3}, deps)
	if err != nil {
		t.Fatal(err)
	}
	return coordinator
}

type fakeReleaseSource struct {
	release update.Release
	err     error
	calls   int
}

func (f *fakeReleaseSource) Discover(context.Context, DiscoveryRequest) (update.Release, error) {
	f.calls++
	return f.release, f.err
}

type fakeArtifactStore struct {
	calls   int
	entered chan struct{}
	release chan struct{}
	err     error
}

func (f *fakeArtifactStore) Stage(ctx context.Context, release update.Release) (StagedArtifact, error) {
	f.calls++
	if f.entered != nil {
		close(f.entered)
		<-f.release
	}
	if err := ctx.Err(); err != nil {
		return StagedArtifact{}, err
	}
	if f.err != nil {
		return StagedArtifact{}, f.err
	}
	return StagedArtifact{Handle: "protected-artifact", SHA256: release.Payload().Artifact.SHA256}, nil
}

type fakeInventory struct {
	products []InstalledProduct
	err      error
}

func (f *fakeInventory) Products(context.Context) ([]InstalledProduct, error) {
	return append([]InstalledProduct(nil), f.products...), f.err
}

type fakeLauncher struct {
	calls   int
	receipt HandoffReceipt
	request HandoffRequest
	pending *memoryPendingStore
}

func (f *fakeLauncher) Launch(_ context.Context, request HandoffRequest) (HandoffReceipt, error) {
	f.calls++
	f.request = request
	if f.pending != nil && f.pending.pending != nil && f.receipt.Ready {
		pending := *f.pending.pending
		pending.Runner = &f.receipt.Runner
		pending.Installer = &f.receipt.Installer
		pending.Phase = PhaseInstallerRunning
		_ = f.pending.Save(context.Background(), pending)
	}
	return f.receipt, nil
}

type fakeHealthProbe struct{ healthy bool }

func (f fakeHealthProbe) Healthy(context.Context, ProductSnapshot) (bool, error) {
	return f.healthy, nil
}

type fakeProcessProbe struct {
	alive bool
	seen  []ProcessIdentity
}

func (f *fakeProcessProbe) Alive(_ context.Context, identity ProcessIdentity) (bool, error) {
	f.seen = append(f.seen, identity)
	return f.alive, nil
}

type fakeRebootProbe bool

func (f fakeRebootProbe) Pending(context.Context) (bool, error) { return bool(f), nil }

type memoryPendingStore struct {
	pending *PendingV1
	phases  []Phase
}

func (m *memoryPendingStore) Load(context.Context) (*PendingV1, error) {
	if m.pending == nil {
		return nil, nil
	}
	p := *m.pending
	return &p, nil
}
func (m *memoryPendingStore) Save(_ context.Context, pending PendingV1) error {
	p := pending
	m.pending = &p
	m.phases = append(m.phases, pending.Phase)
	return nil
}
func (m *memoryPendingStore) Clear(context.Context) error { m.pending = nil; return nil }

type memoryReplayStore struct {
	state update.ReplayState
	saves int
}

func (m *memoryReplayStore) Load(context.Context, update.SKU) (update.ReplayState, error) {
	return m.state, nil
}
func (m *memoryReplayStore) Save(_ context.Context, state update.ReplayState) error {
	m.state = state
	m.saves++
	return nil
}

type memoryStatusStore struct{ status ServiceStatus }

func (m *memoryStatusStore) Load(context.Context) (ServiceStatus, error) { return m.status, nil }
func (m *memoryStatusStore) Save(_ context.Context, status ServiceStatus) error {
	m.status = status
	return nil
}

type memoryEventSink struct{ events []Event }

func (m *memoryEventSink) Record(_ context.Context, event Event) {
	m.events = append(m.events, event)
}

type fixedClock struct{ now time.Time }

func (f fixedClock) Now() time.Time { return f.now }

type fixedBackoff time.Duration

func (f fixedBackoff) Delay(uint) time.Duration { return time.Duration(f) }

type fixedIDs string

func (f fixedIDs) NewID() string { return string(f) }

func oldProduct(sku update.SKU) ProductSnapshot {
	return ProductSnapshot{SKU: sku, PackageVersion: "4.0.0", ProductVersion: "4.0.0", ProductCode: "OLD", Contained: map[string]string{"service": "4.0.0", "interceptor": "4.0.0"}}
}

func candidateProduct(t *testing.T, sku update.SKU, version string) ProductSnapshot {
	t.Helper()
	product, err := productFromRelease(authorizedRelease(t, sku, version))
	if err != nil {
		t.Fatal(err)
	}
	return product
}

func pendingForReconcile(t *testing.T, exit *ExitEvidence) PendingV1 {
	t.Helper()
	release := authorizedRelease(t, update.System, "4.0.1")
	replay, err := update.AcceptReplay(update.ReplayState{}, release)
	if err != nil {
		t.Fatal(err)
	}
	return PendingV1{
		Schema: PendingSchemaV1, TransactionID: "tx-123", SKU: update.System,
		Old: oldProduct(update.System), Candidate: mustProductFromRelease(t, release), Replay: replay,
		ArtifactSHA256: release.Payload().Artifact.SHA256, Phase: PhaseInstallerRunning,
		Runner: &ProcessIdentity{PID: 41, CreatedAtUnixNano: 1001}, Installer: &ProcessIdentity{PID: 42, CreatedAtUnixNano: 1002}, Exit: exit,
		PreparedAt: coordinatorNow.Add(-time.Minute), UpdatedAt: coordinatorNow, Attempt: 1,
	}
}

func mustProductFromRelease(t *testing.T, release update.Release) ProductSnapshot {
	t.Helper()
	product, err := productFromRelease(release)
	if err != nil {
		t.Fatal(err)
	}
	return product
}

func exitEvidence(code uint32) *ExitEvidence {
	return &ExitEvidence{Code: code, ObservedAt: coordinatorNow}
}

func authorizedRelease(t *testing.T, sku update.SKU, version string) update.Release {
	t.Helper()
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	root := update.Root{Schema: update.MachineRootSchema, Version: 1, AllowedOrigin: "https://github.com/marcfargas/go-mapi/releases/download/", Root: update.KeyRole{Keys: map[string]string{"root": base64.RawURLEncoding.EncodeToString(pub)}, Threshold: 1}, Targets: update.KeyRole{Keys: map[string]string{"targets": base64.RawURLEncoding.EncodeToString(pub)}, Threshold: 1}}
	policy, err := update.NewMachinePolicy(sku, root)
	if err != nil {
		t.Fatal(err)
	}
	body := []byte("verified installer")
	sum := sha256.Sum256(body)
	upgrade := "B3C97B33-3F10-47CA-9FA7-24EE3B75E325"
	contained := []update.ContainedComponent{{Component: "service", Version: version}, {Component: "interceptor", Version: version}}
	compatibility := []update.Requirement{{Component: "service", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}, {Component: "interceptor", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}}
	if sku == update.Suite {
		upgrade = "2E050A24-94A2-4FC9-B176-C5CCC1225FE6"
		contained = append(contained, update.ContainedComponent{Component: "app", Version: version})
		compatibility = append(compatibility, update.Requirement{Component: "app", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"})
	}
	payload := update.Payload{Schema: update.MachineTargetsSchema, SKU: sku, UpgradeCode: upgrade, Version: version, QueueProtocol: "queue-v1", Sequence: 4<<24 | 1, IssuedAt: coordinatorNow.Add(-time.Hour).Format(time.RFC3339), ExpiresAt: coordinatorNow.Add(time.Hour).Format(time.RFC3339), Contained: contained, Compatibility: compatibility, Artifact: update.Artifact{URL: "https://github.com/marcfargas/go-mapi/releases/download/" + string(sku) + "-v" + version + "/go-mapi-" + string(sku) + "-" + version + "-x64.msi", Size: int64(len(body)), SHA256: hex.EncodeToString(sum[:])}, Publisher: update.PublisherPolicy{Publisher: "Example", EKUs: []string{"1.3.6.1.5.5.7.3.3", "1.2.3.4"}, PolicyID: "release"}}
	signed, _ := json.Marshal(payload)
	envelope, _ := json.Marshal(update.Envelope{Schema: update.EnvelopeSchema, Signed: base64.RawURLEncoding.EncodeToString(signed), Signatures: []update.Signature{{KeyID: "targets", Signature: base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, signed))}}})
	installed := map[string]string{"service": "4.0.0", "interceptor": "4.0.0", "app": "4.0.0"}
	release, err := policy.Authorize(envelope, installed, coordinatorNow)
	if err != nil {
		t.Fatal(err)
	}
	return release
}

func TestHandoffRequestHasNoInstallerArgumentsOrReleaseURL(t *testing.T) {
	typeOf := reflect.TypeOf(HandoffRequest{})
	for i := 0; i < typeOf.NumField(); i++ {
		name := strings.ToLower(typeOf.Field(i).Name)
		if strings.Contains(name, "argument") || strings.Contains(name, "property") || strings.Contains(name, "url") {
			t.Fatalf("privileged handoff exposes caller-controlled field %q", typeOf.Field(i).Name)
		}
	}
}
