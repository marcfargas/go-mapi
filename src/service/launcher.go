package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

const stagedRunnerName = "go-mapi-update-runner.exe"

type DetachedProcessSpawner interface {
	SpawnDetached(string, string) (ProcessIdentity, error)
}

type ReadyAwaiter interface {
	Await(context.Context, RunnerReadyStore, string, uint, ProcessIdentity) (RunnerReadyV1, error)
}

type PollReadyAwaiter struct {
	Interval time.Duration
	Timeout  time.Duration
}

func (awaiter PollReadyAwaiter) Await(ctx context.Context, store RunnerReadyStore, transactionID string, attempt uint, runner ProcessIdentity) (RunnerReadyV1, error) {
	if awaiter.Interval <= 0 || awaiter.Timeout <= 0 || store == nil {
		return RunnerReadyV1{}, errors.New("invalid ready awaiter")
	}
	ctx, cancel := context.WithTimeout(ctx, awaiter.Timeout)
	defer cancel()
	ticker := time.NewTicker(awaiter.Interval)
	defer ticker.Stop()
	for {
		ready, err := store.Load(ctx, transactionID, attempt)
		if err != nil {
			return RunnerReadyV1{}, err
		}
		if ready != nil {
			if ready.Runner != runner {
				return RunnerReadyV1{}, errors.New("ready signal belongs to a different runner process")
			}
			return *ready, nil
		}
		select {
		case <-ctx.Done():
			return RunnerReadyV1{}, ctx.Err()
		case <-ticker.C:
		}
	}
}

// DetachedRunnerLauncher copies the installed service executable into a unique
// protected transaction directory, checks its bytes, then starts the runner.
type DetachedRunnerLauncher struct {
	storage   *ProtectedStorage
	ready     RunnerReadyStore
	integrity FileIntegrityVerifier
	spawner   DetachedProcessSpawner
	awaiter   ReadyAwaiter
	source    string
}

func NewDetachedRunnerLauncher(storage *ProtectedStorage, ready RunnerReadyStore, spawner DetachedProcessSpawner, awaiter ReadyAwaiter, source string) (*DetachedRunnerLauncher, error) {
	if storage == nil || storage.access != privateStorage || ready == nil || spawner == nil || awaiter == nil || source == "" {
		return nil, errors.New("detached runner launcher dependencies are incomplete")
	}
	return &DetachedRunnerLauncher{storage: storage, ready: ready, integrity: SHA256FileVerifier{}, spawner: spawner, awaiter: awaiter, source: source}, nil
}

func (launcher *DetachedRunnerLauncher) Launch(ctx context.Context, request HandoffRequest) (HandoffReceipt, error) {
	if !transactionIDPattern.MatchString(request.TransactionID) || request.Attempt == 0 || !validSHA256(request.Artifact.SHA256) {
		return HandoffReceipt{}, errors.New("invalid detached runner handoff")
	}
	artifactPath, err := launcher.resolveArtifactHandle(request.Artifact.Handle)
	if err != nil {
		return HandoffReceipt{}, err
	}
	releaseArtifact, err := pinVerifiedFile(artifactPath)
	if err != nil {
		return HandoffReceipt{}, err
	}
	defer releaseArtifact()
	if err := launcher.integrity.VerifySHA256(ctx, artifactPath, request.Artifact.SHA256); err != nil {
		return HandoffReceipt{}, fmt.Errorf("reverify handoff artifact: %w", err)
	}
	runnerPath, releaseRunner, err := launcher.stageRunner(ctx, request.TransactionID)
	if err != nil {
		return HandoffReceipt{}, err
	}
	defer releaseRunner()
	identity, err := launcher.spawner.SpawnDetached(runnerPath, request.TransactionID)
	if err != nil || validateProcessIdentity(&identity) != nil {
		return HandoffReceipt{}, errors.New("spawn detached update runner")
	}
	ready, err := launcher.awaiter.Await(ctx, launcher.ready, request.TransactionID, request.Attempt, identity)
	if err != nil {
		return HandoffReceipt{}, fmt.Errorf("await durable runner readiness: %w", err)
	}
	return HandoffReceipt{Runner: ready.Runner, Installer: ready.Installer, Ready: true}, nil
}

func (launcher *DetachedRunnerLauncher) resolveArtifactHandle(handle string) (string, error) {
	components := strings.Split(handle, "/")
	if len(components) != 3 {
		return "", errors.New("invalid protected artifact handle")
	}
	return launcher.storage.resolve(components...)
}

func (launcher *DetachedRunnerLauncher) stageRunner(ctx context.Context, transactionID string) (string, func(), error) {
	releaseSource, err := pinVerifiedFile(launcher.source)
	if err != nil {
		return "", nil, err
	}
	defer releaseSource()
	source, err := os.Open(launcher.source)
	if err != nil {
		return "", nil, err
	}
	info, err := source.Stat()
	if err != nil {
		source.Close()
		return "", nil, err
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maxRunnerBytes {
		source.Close()
		return "", nil, errors.New("installed service executable exceeds runner bound")
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, source); err != nil {
		source.Close()
		return "", nil, err
	}
	if err := source.Close(); err != nil {
		return "", nil, err
	}
	digest := hex.EncodeToString(hash.Sum(nil))
	source, err = os.Open(launcher.source)
	if err != nil {
		return "", nil, err
	}
	defer source.Close()
	components := []string{"runners", transactionID, stagedRunnerName}
	if _, err := launcher.storage.WriteAtomic(ctx, components, source, maxRunnerBytes, info.Size(), digest); err != nil {
		return "", nil, fmt.Errorf("copy protected update runner: %w", err)
	}
	path, err := launcher.storage.resolve(components...)
	if err != nil {
		return "", nil, err
	}
	releaseRunner, err := pinVerifiedFile(path)
	if err != nil {
		return "", nil, err
	}
	if err := launcher.integrity.VerifySHA256(ctx, path, digest); err != nil {
		releaseRunner()
		return "", nil, fmt.Errorf("reverify staged runner hash: %w", err)
	}
	return path, releaseRunner, nil
}
