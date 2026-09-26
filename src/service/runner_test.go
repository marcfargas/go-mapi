package service

import (
	"context"
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func TestSuiteRunnerAuthorizesPendingSKUBeforeResume(t *testing.T) {
	now := time.Date(2026, 9, 23, 9, 0, 0, 0, time.UTC)
	release := authorizedRelease(t, update.Suite, "4.0.1")
	pending := validPending(now)
	pending.SKU = update.Suite
	pending.Old = oldProduct(update.Suite)
	pending.Old.Contained["app"] = "4.0.0"
	pending.Candidate = mustProductFromRelease(t, release)
	pending.Replay, _ = update.AcceptReplay(update.ReplayState{}, release)
	pending.ArtifactSHA256 = release.Payload().Artifact.SHA256
	store := &orderedPendingStore{pending: &pending}
	process := &fakeInstallerProcess{identity: ProcessIdentity{PID: 152, CreatedAtUnixNano: 2002}, thread: ProcessIdentity{PID: 153, CreatedAtUnixNano: 2003}, order: &store.order}
	runtime := &fakeRunnerRuntime{self: ProcessIdentity{PID: 151, CreatedAtUnixNano: 2001}, process: process, order: &store.order}
	runner := UpdateRunner{Pending: store, Ready: &memoryReadyStore{order: &store.order}, Artifacts: fixedArtifactResolver(runnerFixtureArtifact(t)), Integrity: &fakeIntegrityVerifier{order: &store.order}, Runtime: runtime, Clock: fixedRunnerClock(now),
		AuthorizePending: func(_ context.Context, observed PendingV1) error {
			return authorizePendingProductSnapshot(observed, pending.Old)
		},
		SuiteQuiesce: func(ctx context.Context, observed PendingV1) (PendingV1, error) {
			if observed.Runner == nil || containsAction(store.order, "start-installer") {
				t.Fatal("suite quiescence did not precede installer creation")
			}
			next := observed
			deadline := now.Add(30 * time.Second)
			next.AppDrainDeadline = &deadline
			if err := store.CompareAndSave(ctx, &observed, next); err != nil {
				return PendingV1{}, err
			}
			store.order = append(store.order, "suite-drained")
			return next, nil
		}}
	if err := runner.Run(context.Background(), pending.TransactionID); err != nil {
		t.Fatalf("suite runner rejected matching installed SKU: %v", err)
	}
	if !containsAction(store.order, "suite-drained") || !containsAction(store.order, "resume") || !containsAction(store.order, "ready") {
		t.Fatalf("suite runner did not resume and publish readiness: %v", store.order)
	}
}

func containsAction(actions []string, wanted string) bool {
	for _, action := range actions {
		if action == wanted {
			return true
		}
	}
	return false
}

func TestUpdateRunnerPersistsIdentityBeforeReadyThenRecordsExit(t *testing.T) {
	now := time.Date(2026, 9, 23, 9, 0, 0, 0, time.UTC)
	pending := validPending(now)
	pending.Schema = PendingSchemaV2
	store := &orderedPendingStore{pending: &pending}
	ready := &memoryReadyStore{order: &store.order}
	process := &fakeInstallerProcess{identity: ProcessIdentity{PID: 52, CreatedAtUnixNano: 2002}, thread: ProcessIdentity{PID: 53, CreatedAtUnixNano: 2003}, code: 3010, order: &store.order}
	runtime := &fakeRunnerRuntime{self: ProcessIdentity{PID: 51, CreatedAtUnixNano: 2001}, process: process, order: &store.order}
	runner := UpdateRunner{Pending: store, Ready: ready, Artifacts: fixedArtifactResolver(runnerFixtureArtifact(t)), Integrity: &fakeIntegrityVerifier{order: &store.order}, Runtime: runtime, Clock: fixedRunnerClock(now)}

	if err := runner.Run(context.Background(), pending.TransactionID); err != nil {
		t.Fatal(err)
	}
	wantOrder := []string{"verify", "save-runner", "start-installer", "save-child-recorded", "save-resume-authorized", "resume", "save-running", "ready", "wait", "save-exit"}
	if !reflect.DeepEqual(store.order, wantOrder) {
		t.Fatalf("runner order = %v, want %v", store.order, wantOrder)
	}
	if store.pending.Exit == nil || store.pending.Exit.Code != 3010 {
		t.Fatalf("exit evidence = %#v", store.pending.Exit)
	}
	if ready.ready == nil || ready.ready.Installer != process.identity {
		t.Fatalf("ready evidence = %#v", ready.ready)
	}
}

func TestUpdateRunnerCancellationCannotCancelInstallerAfterReady(t *testing.T) {
	now := time.Date(2026, 9, 23, 9, 0, 0, 0, time.UTC)
	pending := validPending(now)
	pending.Schema = PendingSchemaV2
	store := &orderedPendingStore{pending: &pending}
	ctx, cancel := context.WithCancel(context.Background())
	process := &fakeInstallerProcess{identity: ProcessIdentity{PID: 62, CreatedAtUnixNano: 3002}, thread: ProcessIdentity{PID: 63, CreatedAtUnixNano: 3003}, code: 0, wait: func() { cancel() }, order: &store.order}
	runner := UpdateRunner{Pending: store, Ready: &memoryReadyStore{order: &store.order}, Artifacts: fixedArtifactResolver(runnerFixtureArtifact(t)), Integrity: &fakeIntegrityVerifier{order: &store.order}, Runtime: &fakeRunnerRuntime{self: ProcessIdentity{PID: 61, CreatedAtUnixNano: 3001}, process: process, order: &store.order}, Clock: fixedRunnerClock(now)}

	if err := runner.Run(ctx, pending.TransactionID); err != nil {
		t.Fatalf("post-ready cancellation reached runner: %v", err)
	}
	if store.pending.Exit == nil || store.pending.Exit.Code != 0 {
		t.Fatalf("exit evidence = %#v", store.pending.Exit)
	}
}

func TestUpdateRunnerFailureBoundariesLeaveNoFalseReadyOrExit(t *testing.T) {
	now := time.Date(2026, 9, 23, 9, 0, 0, 0, time.UTC)
	for _, test := range []struct {
		name      string
		integrity error
		start     error
		wait      error
		wantReady bool
	}{
		{name: "changed artifact", integrity: errors.New("hash mismatch")},
		{name: "installer start", start: errors.New("create process")},
		{name: "missing numeric exit", wait: errors.New("lost process handle"), wantReady: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			pending := validPending(now)
			pending.Schema = PendingSchemaV2
			store := &orderedPendingStore{pending: &pending}
			ready := &memoryReadyStore{order: &store.order}
			process := &fakeInstallerProcess{identity: ProcessIdentity{PID: 72, CreatedAtUnixNano: 4002}, thread: ProcessIdentity{PID: 73, CreatedAtUnixNano: 4003}, err: test.wait, order: &store.order}
			runner := UpdateRunner{Pending: store, Ready: ready, Artifacts: fixedArtifactResolver(runnerFixtureArtifact(t)), Integrity: &fakeIntegrityVerifier{err: test.integrity, order: &store.order}, Runtime: &fakeRunnerRuntime{self: ProcessIdentity{PID: 71, CreatedAtUnixNano: 4001}, process: process, err: test.start, order: &store.order}, Clock: fixedRunnerClock(now)}
			if err := runner.Run(context.Background(), pending.TransactionID); err == nil {
				t.Fatal("Run unexpectedly succeeded")
			}
			if (ready.ready != nil) != test.wantReady {
				t.Fatalf("ready = %#v, want published %v", ready.ready, test.wantReady)
			}
			if store.pending.Exit != nil {
				t.Fatalf("false exit evidence = %#v", store.pending.Exit)
			}
		})
	}
}

func TestUpdateRunnerDoesNotReleaseSuspendedChildWhenDurableWriteFails(t *testing.T) {
	now := time.Date(2026, 9, 23, 9, 0, 0, 0, time.UTC)
	for _, phase := range []Phase{PhaseChildRecorded, PhaseResumeAuthorized} {
		t.Run(string(phase), func(t *testing.T) {
			pending := validPending(now)
			pending.Schema = PendingSchemaV2
			store := &orderedPendingStore{pending: &pending, failPhase: phase}
			process := &fakeInstallerProcess{identity: ProcessIdentity{PID: 82, CreatedAtUnixNano: 5002}, thread: ProcessIdentity{PID: 83, CreatedAtUnixNano: 5003}, order: &store.order}
			runner := UpdateRunner{Pending: store, Ready: &memoryReadyStore{order: &store.order}, Artifacts: fixedArtifactResolver(runnerFixtureArtifact(t)), Integrity: &fakeIntegrityVerifier{order: &store.order}, Runtime: &fakeRunnerRuntime{self: ProcessIdentity{PID: 81, CreatedAtUnixNano: 5001}, process: process, order: &store.order}, Clock: fixedRunnerClock(now)}
			if err := runner.Run(context.Background(), pending.TransactionID); err == nil {
				t.Fatal("runner accepted failed durable write")
			}
			for _, action := range store.order {
				if action == "resume" || action == "ready" || action == "wait" {
					t.Fatalf("executed %s after failed durable write: %v", action, store.order)
				}
			}
			if got := store.order[len(store.order)-1]; got != "abort" {
				t.Fatalf("last action = %s, want abort: %v", got, store.order)
			}
		})
	}
}

func TestUpdateRunnerRechecksPendingBeforeInstallerResume(t *testing.T) {
	now := time.Date(2026, 9, 23, 9, 0, 0, 0, time.UTC)
	pending := validPending(now)
	pending.Schema = PendingSchemaV2
	store := &orderedPendingStore{pending: &pending}
	process := &fakeInstallerProcess{identity: ProcessIdentity{PID: 92, CreatedAtUnixNano: 7002}, thread: ProcessIdentity{PID: 93, CreatedAtUnixNano: 7003}, order: &store.order}
	runner := UpdateRunner{Pending: store, Ready: &memoryReadyStore{order: &store.order},
		Artifacts: fixedArtifactResolver(runnerFixtureArtifact(t)), Integrity: &fakeIntegrityVerifier{order: &store.order},
		Runtime: &fakeRunnerRuntime{self: ProcessIdentity{PID: 91, CreatedAtUnixNano: 7001}, process: process, order: &store.order},
		Clock:   fixedRunnerClock(now), AuthorizePending: func(_ context.Context, observed PendingV1) error {
			if observed.TransactionID != pending.TransactionID || observed.Old.ProductCode != pending.Old.ProductCode {
				t.Fatalf("runner authorization lost pending identity: %#v", observed)
			}
			return errors.New("setting disabled after preparation")
		}}
	if err := runner.Run(context.Background(), pending.TransactionID); err == nil {
		t.Fatal("runner resumed installer after failed final authorization")
	}
	for _, action := range store.order {
		if action == "resume" || action == "ready" || action == "wait" {
			t.Fatalf("runner performed %s after failed final authorization: %v", action, store.order)
		}
	}
	if got := store.order[len(store.order)-1]; got != "abort" {
		t.Fatalf("last action = %s, want abort", got)
	}
}

func TestFixedInstallerArgumentsExposeNoCallerSelectedProperties(t *testing.T) {
	artifact := filepath.Join(testStorageRoot(t, "updates"), "update.msi")
	log := filepath.Join(testStorageRoot(t, "updates"), "msiexec.log")
	args, err := fixedInstallerArguments(artifact, log, "tx-42")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"/i", artifact, "/qn", "/norestart", "/L*V", log, "MSIRMSHUTDOWN=0", "GOMAPI_UPDATE_ORIGIN=SERVICE", "GOMAPI_UPDATE_TRANSACTION=tx-42"}
	if !reflect.DeepEqual(args, want) {
		t.Fatalf("installer arguments = %q, want %q", args, want)
	}
	suiteArgs, err := fixedSuiteInstallerArguments(artifact, log, "tx-42")
	if err != nil || len(suiteArgs) != len(want) || containsInstallerArgument(suiteArgs, "MSIRMSHUTDOWN=0") || !containsInstallerArgument(suiteArgs, "MSIRESTARTMANAGERCONTROL=Disable") {
		t.Fatalf("suite arguments=%q err=%v", suiteArgs, err)
	}
	if _, err := fixedInstallerArguments("msi", "log", `..\\outside`); err == nil {
		t.Fatal("accepted unsafe transaction property")
	}
}

type orderedPendingStore struct {
	pending   *PendingV1
	order     []string
	failPhase Phase
}

func (store *orderedPendingStore) Load(context.Context) (*PendingV1, error) {
	if store.pending == nil {
		return nil, nil
	}
	copy := *store.pending
	return &copy, nil
}
func (store *orderedPendingStore) Save(_ context.Context, pending PendingV1) error {
	if pending.Phase == store.failPhase {
		return errors.New("forced durable write failure")
	}
	copy := pending
	store.pending = &copy
	switch {
	case pending.Exit != nil:
		store.order = append(store.order, "save-exit")
	case pending.Phase == PhaseChildRecorded:
		store.order = append(store.order, "save-child-recorded")
	case pending.Phase == PhaseResumeAuthorized:
		store.order = append(store.order, "save-resume-authorized")
	case pending.Phase == PhaseRunning:
		store.order = append(store.order, "save-running")
	case pending.Installer != nil:
		store.order = append(store.order, "save-installer-running")
	case pending.Runner != nil:
		store.order = append(store.order, "save-runner")
	}
	return nil
}
func (store *orderedPendingStore) CompareAndSave(ctx context.Context, expected *PendingV1, pending PendingV1) error {
	if expected == nil || store.pending == nil || !reflect.DeepEqual(*store.pending, *expected) {
		return ErrStateConflict
	}
	return store.Save(ctx, pending)
}
func (store *orderedPendingStore) CompareAndClear(_ context.Context, expected PendingV1) error {
	if store.pending == nil || !reflect.DeepEqual(*store.pending, expected) {
		return ErrStateConflict
	}
	store.pending = nil
	return nil
}

type memoryReadyStore struct {
	ready *RunnerReadyV1
	order *[]string
}

func (store *memoryReadyStore) Publish(_ context.Context, ready RunnerReadyV1) error {
	if err := ready.Validate(); err != nil {
		return err
	}
	copy := ready
	store.ready = &copy
	*store.order = append(*store.order, "ready")
	return nil
}
func (store *memoryReadyStore) Load(_ context.Context, transactionID string, attempt uint) (*RunnerReadyV1, error) {
	if store.ready == nil || store.ready.TransactionID != transactionID || store.ready.Attempt != attempt {
		return nil, nil
	}
	copy := *store.ready
	return &copy, nil
}

type fixedArtifactResolver string

func runnerFixtureArtifact(t *testing.T) string {
	t.Helper()
	storage := mustStorage(t, testStorageRoot(t, "updates"), privateStorage)
	components := []string{"system", "42", "fixture.msi"}
	if _, err := storage.WriteAtomic(context.Background(), components, strings.NewReader("fixture"), 7, 7, ""); err != nil {
		t.Fatal(err)
	}
	path, err := storage.resolve(components...)
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func (resolver fixedArtifactResolver) Resolve(context.Context, PendingV1) (string, error) {
	return string(resolver), nil
}

type fakeIntegrityVerifier struct {
	err   error
	order *[]string
}

func (verifier *fakeIntegrityVerifier) VerifySHA256(_ context.Context, path, hash string) error {
	if path == "" || !validSHA256(hash) {
		return errors.New("invalid verification request")
	}
	*verifier.order = append(*verifier.order, "verify")
	return verifier.err
}

type fakeRunnerRuntime struct {
	self    ProcessIdentity
	process InstallerProcess
	err     error
	order   *[]string
}

func (runtime *fakeRunnerRuntime) SelfIdentity() (ProcessIdentity, error) { return runtime.self, nil }
func (runtime *fakeRunnerRuntime) StartInstaller(path, transactionID string) (InstallerProcess, error) {
	if !strings.HasSuffix(path, ".msi") || !transactionIDPattern.MatchString(transactionID) {
		return nil, errors.New("not MSI")
	}
	*runtime.order = append(*runtime.order, "start-installer")
	return runtime.process, runtime.err
}

type fakeInstallerProcess struct {
	identity ProcessIdentity
	thread   ProcessIdentity
	code     uint32
	err      error
	wait     func()
	order    *[]string
}

func (process *fakeInstallerProcess) Identity() ProcessIdentity      { return process.identity }
func (process *fakeInstallerProcess) InitialThread() ProcessIdentity { return process.thread }
func (process *fakeInstallerProcess) Resume() error {
	*process.order = append(*process.order, "resume")
	return nil
}
func (process *fakeInstallerProcess) Abort() error {
	*process.order = append(*process.order, "abort")
	return nil
}
func (process *fakeInstallerProcess) Wait() (uint32, error) {
	*process.order = append(*process.order, "wait")
	if process.wait != nil {
		process.wait()
	}
	return process.code, process.err
}

type fixedRunnerClock time.Time

func (clock fixedRunnerClock) Now() time.Time { return time.Time(clock) }

func containsInstallerArgument(args []string, want string) bool {
	for _, arg := range args {
		if arg == want {
			return true
		}
	}
	return false
}
