package service

import (
	"context"
	"errors"
	"fmt"
	"time"
)

const RunnerReadySchemaV1 = "go-mapi-runner-ready-v1"

// RunnerReadyV1 is the protected, durable point-of-no-return signal. The
// resident service may stop only after this document has been flushed.
type RunnerReadyV1 struct {
	Schema        string          `json:"schema"`
	TransactionID string          `json:"transactionId"`
	Attempt       uint            `json:"attempt"`
	Runner        ProcessIdentity `json:"runner"`
	Installer     ProcessIdentity `json:"installer"`
	ReadyAt       time.Time       `json:"readyAt"`
}

func (ready RunnerReadyV1) Validate() error {
	if ready.Schema != RunnerReadySchemaV1 || !transactionIDPattern.MatchString(ready.TransactionID) || ready.Attempt == 0 || ready.ReadyAt.IsZero() {
		return errors.New("invalid runner ready signal")
	}
	if err := validateProcessIdentity(&ready.Runner); err != nil {
		return fmt.Errorf("invalid ready runner identity: %w", err)
	}
	if err := validateProcessIdentity(&ready.Installer); err != nil {
		return fmt.Errorf("invalid ready installer identity: %w", err)
	}
	return nil
}

type RunnerReadyStore interface {
	Publish(context.Context, RunnerReadyV1) error
	Load(context.Context, string, uint) (*RunnerReadyV1, error)
}

type RunnerArtifactResolver interface {
	Resolve(context.Context, PendingV1) (string, error)
}

type FileIntegrityVerifier interface {
	VerifySHA256(context.Context, string, string) error
}

type InstallerProcess interface {
	Identity() ProcessIdentity
	InitialThread() ProcessIdentity
	// Resume releases a child created suspended only after its identity has
	// been durably recorded. Abort closes its kill-on-close job before resume.
	Resume() error
	Abort() error
	Wait() (uint32, error)
}

// RunnerRuntime is the closed platform process boundary. StartInstaller owns
// the absolute System32 msiexec path and its fixed silent argument vector.
type RunnerRuntime interface {
	SelfIdentity() (ProcessIdentity, error)
	StartInstaller(string, string) (InstallerProcess, error)
}

func fixedInstallerArguments(msiPath, logPath, transactionID string) ([]string, error) {
	if msiPath == "" || logPath == "" || !transactionIDPattern.MatchString(transactionID) {
		return nil, errors.New("invalid fixed installer invocation")
	}
	return []string{"/i", msiPath, "/qn", "/norestart", "/L*V", logPath, "MSIRMSHUTDOWN=0", "GOMAPI_UPDATE_ORIGIN=SERVICE", "GOMAPI_UPDATE_TRANSACTION=" + transactionID}, nil
}

type UpdateRunner struct {
	Pending   PendingStore
	Ready     RunnerReadyStore
	Artifacts RunnerArtifactResolver
	Integrity FileIntegrityVerifier
	// VerifyIdentity checks the signed MSI's own identity against the exact
	// protected pending candidate before any installer process is created.
	VerifyIdentity func(context.Context, string, PendingV1) error
	Runtime        RunnerRuntime
	Clock          Clock
	Authorize      func(context.Context) error
}

// Run executes one already-authorized transaction. Cancellation is honored
// until the ready signal is durably published. After that point the detached
// runner must outlive SCM cancellation and record Windows Installer's exit.
func (runner UpdateRunner) Run(ctx context.Context, transactionID string) error {
	if runner.Pending == nil || runner.Ready == nil || runner.Artifacts == nil || runner.Integrity == nil || runner.Runtime == nil || runner.Clock == nil {
		return errors.New("update runner dependencies are incomplete")
	}
	if !transactionIDPattern.MatchString(transactionID) {
		return errors.New("invalid update runner transaction")
	}
	pending, err := runner.Pending.Load(ctx)
	if err != nil {
		return fmt.Errorf("load prepared transaction: %w", err)
	}
	if pending == nil || pending.Schema != PendingSchemaV2 || pending.TransactionID != transactionID || pending.Phase != PhasePrepared || pending.Runner != nil || pending.Installer != nil || pending.InstallerThread != nil || pending.Exit != nil {
		return errors.New("update runner transaction is not exclusively prepared")
	}
	artifact, err := runner.Artifacts.Resolve(ctx, *pending)
	if err != nil {
		return fmt.Errorf("resolve protected installer: %w", err)
	}
	releaseArtifact, err := pinVerifiedFile(artifact)
	if err != nil {
		return fmt.Errorf("pin protected installer: %w", err)
	}
	defer releaseArtifact()
	if err := runner.Integrity.VerifySHA256(ctx, artifact, pending.ArtifactSHA256); err != nil {
		return fmt.Errorf("reverify protected installer: %w", err)
	}
	if runner.VerifyIdentity != nil {
		if err := runner.VerifyIdentity(ctx, artifact, *pending); err != nil {
			return fmt.Errorf("verify protected installer identity: %w", err)
		}
	}
	self, err := runner.Runtime.SelfIdentity()
	if err != nil || validateProcessIdentity(&self) != nil {
		return errors.New("capture update runner process identity")
	}
	previous := *pending
	pending.Runner = &self
	pending.UpdatedAt = runner.Clock.Now()
	if err := runner.Pending.CompareAndSave(ctx, &previous, *pending); err != nil {
		return fmt.Errorf("persist runner identity: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	installer, err := runner.Runtime.StartInstaller(artifact, transactionID)
	if err != nil {
		return fmt.Errorf("start fixed Windows Installer command: %w", err)
	}
	installerIdentity := installer.Identity()
	threadIdentity := installer.InitialThread()
	if err := validateProcessIdentity(&installerIdentity); err != nil {
		_ = installer.Abort()
		return fmt.Errorf("capture installer identity: %w", err)
	}
	if err := validateProcessIdentity(&threadIdentity); err != nil {
		_ = installer.Abort()
		return fmt.Errorf("capture installer initial thread identity: %w", err)
	}
	previous = *pending
	pending.Installer = &installerIdentity
	pending.InstallerThread = &threadIdentity
	pending.Phase = PhaseChildRecorded
	pending.UpdatedAt = runner.Clock.Now()
	if err := runner.Pending.CompareAndSave(context.WithoutCancel(ctx), &previous, *pending); err != nil {
		_ = installer.Abort()
		return fmt.Errorf("persist installer identity: %w", err)
	}
	previous = *pending
	pending.Phase = PhaseResumeAuthorized
	pending.UpdatedAt = runner.Clock.Now()
	if runner.Authorize != nil {
		if err := runner.Authorize(context.WithoutCancel(ctx)); err != nil {
			_ = installer.Abort()
			return fmt.Errorf("authorize installer resume: %w", err)
		}
	}
	if err := runner.Pending.CompareAndSave(context.WithoutCancel(ctx), &previous, *pending); err != nil {
		_ = installer.Abort()
		return fmt.Errorf("persist installer resume authorization: %w", err)
	}
	if err := installer.Resume(); err != nil {
		previous = *pending
		pending.Phase = PhaseRepairRequired
		pending.Result = ResultAmbiguous
		pending.UpdatedAt = runner.Clock.Now()
		if saveErr := runner.Pending.CompareAndSave(context.Background(), &previous, *pending); saveErr != nil {
			return errors.Join(fmt.Errorf("resume recorded installer: %w", err), fmt.Errorf("persist abnormal resume state: %w", saveErr))
		}
		return fmt.Errorf("resume recorded installer: %w", err)
	}
	previous = *pending
	pending.Phase = PhaseRunning
	pending.UpdatedAt = runner.Clock.Now()
	if err := runner.Pending.CompareAndSave(context.WithoutCancel(ctx), &previous, *pending); err != nil {
		return fmt.Errorf("persist running installer: %w", err)
	}
	ready := RunnerReadyV1{Schema: RunnerReadySchemaV1, TransactionID: transactionID, Attempt: pending.Attempt, Runner: self, Installer: installerIdentity, ReadyAt: runner.Clock.Now()}
	readyErr := runner.Ready.Publish(context.WithoutCancel(ctx), ready)

	// Resume authorization was durably written before disarming the private
	// job. Service cancellation cannot revoke this installer attempt.
	exitCode, err := installer.Wait()
	if err != nil {
		// Missing numeric exit evidence is intentionally reconciled as repair.
		return fmt.Errorf("wait for Windows Installer exit: %w", err)
	}
	latest, err := runner.Pending.Load(context.Background())
	if err != nil {
		return fmt.Errorf("reload transaction after installer exit: %w", err)
	}
	if latest == nil || latest.TransactionID != transactionID || latest.Runner == nil || latest.Installer == nil || latest.InstallerThread == nil || *latest.Runner != self || *latest.Installer != installerIdentity || *latest.InstallerThread != threadIdentity {
		return errors.New("transaction identity changed while installer was running")
	}
	previous = *latest
	latest.Exit = &ExitEvidence{Code: exitCode, ObservedAt: runner.Clock.Now()}
	latest.UpdatedAt = runner.Clock.Now()
	if err := runner.Pending.CompareAndSave(context.Background(), &previous, *latest); err != nil {
		return fmt.Errorf("persist installer exit evidence: %w", err)
	}
	if readyErr != nil {
		return fmt.Errorf("publish durable runner readiness: %w", readyErr)
	}
	return nil
}
