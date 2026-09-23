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
	Runner        ProcessIdentity `json:"runner"`
	Installer     ProcessIdentity `json:"installer"`
	ReadyAt       time.Time       `json:"readyAt"`
}

func (ready RunnerReadyV1) Validate() error {
	if ready.Schema != RunnerReadySchemaV1 || !transactionIDPattern.MatchString(ready.TransactionID) || ready.ReadyAt.IsZero() {
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
	Load(context.Context, string) (*RunnerReadyV1, error)
}

type RunnerArtifactResolver interface {
	Resolve(context.Context, PendingV1) (string, error)
}

type FileIntegrityVerifier interface {
	VerifySHA256(context.Context, string, string) error
}

type InstallerProcess interface {
	Identity() ProcessIdentity
	Wait() (uint32, error)
}

// RunnerRuntime is the closed platform process boundary. StartInstaller owns
// the absolute System32 msiexec path and its fixed silent argument vector.
type RunnerRuntime interface {
	SelfIdentity() (ProcessIdentity, error)
	StartInstaller(string) (InstallerProcess, error)
}

type UpdateRunner struct {
	Pending   PendingStore
	Ready     RunnerReadyStore
	Artifacts RunnerArtifactResolver
	Integrity FileIntegrityVerifier
	Runtime   RunnerRuntime
	Clock     Clock
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
	if pending == nil || pending.TransactionID != transactionID || pending.Phase != PhasePrepared || pending.Runner != nil || pending.Installer != nil || pending.Exit != nil {
		return errors.New("update runner transaction is not exclusively prepared")
	}
	artifact, err := runner.Artifacts.Resolve(ctx, *pending)
	if err != nil {
		return fmt.Errorf("resolve protected installer: %w", err)
	}
	if err := runner.Integrity.VerifySHA256(ctx, artifact, pending.ArtifactSHA256); err != nil {
		return fmt.Errorf("reverify protected installer: %w", err)
	}
	self, err := runner.Runtime.SelfIdentity()
	if err != nil || validateProcessIdentity(&self) != nil {
		return errors.New("capture update runner process identity")
	}
	pending.Runner = &self
	pending.UpdatedAt = runner.Clock.Now()
	if err := runner.Pending.Save(ctx, *pending); err != nil {
		return fmt.Errorf("persist runner identity: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	installer, err := runner.Runtime.StartInstaller(artifact)
	if err != nil {
		return fmt.Errorf("start fixed Windows Installer command: %w", err)
	}
	installerIdentity := installer.Identity()
	if err := validateProcessIdentity(&installerIdentity); err != nil {
		return fmt.Errorf("capture installer identity: %w", err)
	}
	pending.Installer = &installerIdentity
	pending.Phase = PhaseInstallerRunning
	pending.UpdatedAt = runner.Clock.Now()
	if err := runner.Pending.Save(context.WithoutCancel(ctx), *pending); err != nil {
		return fmt.Errorf("persist installer identity: %w", err)
	}
	ready := RunnerReadyV1{Schema: RunnerReadySchemaV1, TransactionID: transactionID, Runner: self, Installer: installerIdentity, ReadyAt: runner.Clock.Now()}
	if err := runner.Ready.Publish(context.WithoutCancel(ctx), ready); err != nil {
		return fmt.Errorf("publish durable runner readiness: %w", err)
	}

	// Point of no return: never propagate service cancellation into msiexec.
	exitCode, err := installer.Wait()
	if err != nil {
		// Missing numeric exit evidence is intentionally reconciled as repair.
		return fmt.Errorf("wait for Windows Installer exit: %w", err)
	}
	latest, err := runner.Pending.Load(context.Background())
	if err != nil {
		return fmt.Errorf("reload transaction after installer exit: %w", err)
	}
	if latest == nil || latest.TransactionID != transactionID || latest.Runner == nil || latest.Installer == nil || *latest.Runner != self || *latest.Installer != installerIdentity {
		return errors.New("transaction identity changed while installer was running")
	}
	latest.Exit = &ExitEvidence{Code: exitCode, ObservedAt: runner.Clock.Now()}
	latest.UpdatedAt = runner.Clock.Now()
	if err := runner.Pending.Save(context.Background(), *latest); err != nil {
		return fmt.Errorf("persist installer exit evidence: %w", err)
	}
	return nil
}
