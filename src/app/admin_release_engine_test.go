package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

type adminEngineTransport func(*http.Request) (*http.Response, error)

func (f adminEngineTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestAdminRepairUsesSharedCheckPrepareInstallOnce(t *testing.T) {
	priorVersion, priorMin, priorMax := Version, RequiredInterceptorMin, RequiredInterceptorMax
	Version, RequiredInterceptorMin, RequiredInterceptorMax = "4.0.0", "4.0.0", "5.0.0"
	t.Cleanup(func() { Version, RequiredInterceptorMin, RequiredInterceptorMax = priorVersion, priorMin, priorMax })
	now := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	body := []byte("signed MSI fixture")
	sum := sha256.Sum256(body)
	id, err := mapi.NewMachinePackageIdentity(mapi.MachineSKUSystem, "4.0.2")
	if err != nil {
		t.Fatal(err)
	}
	payload := update.Payload{
		Schema: update.MachineTargetsSchema, SKU: update.System, ProductCode: id.ProductCode, UpgradeCode: mapi.SystemUpgradeCode, Version: id.Release,
		QueueProtocol: "queue-v1", Sequence: id.Sequence,
		IssuedAt: now.Add(-time.Hour).Format(time.RFC3339), ExpiresAt: now.Add(time.Hour).Format(time.RFC3339),
		Requires:      update.Requirement{Component: "app", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"},
		Contained:     []update.ContainedComponent{{Component: "service", Version: "4.0.1"}, {Component: "interceptor", Version: "4.0.1"}},
		Compatibility: []update.Requirement{{Component: "service", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}, {Component: "interceptor", MinInclusive: "4.0.0", MaxExclusive: "5.0.0"}},
		Artifact:      update.Artifact{URL: update.MachineArtifactOrigin + id.Tag + "/" + id.AssetName, Size: int64(len(body)), SHA256: hex.EncodeToString(sum[:])},
	}
	metadata, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	metadataCalls, artifactCalls, verifies, handoffs := 0, 0, 0, 0
	var stagedPath string
	client := &http.Client{Transport: adminEngineTransport(func(r *http.Request) (*http.Response, error) {
		var data []byte
		switch r.URL.String() {
		case "https://go-mapi.app/machine/system/targets.json":
			metadataCalls++
			data = metadata
		case payload.Artifact.URL:
			artifactCalls++
			data = body
		default:
			return nil, errors.New("unexpected URL: " + r.URL.String())
		}
		return &http.Response{StatusCode: 200, Status: "200 OK", Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(data))), ContentLength: int64(len(data)), Request: r}, nil
	})}
	engine, err := update.NewEngine(update.Config{SKU: update.System, MetadataOrigin: "https://go-mapi.app", ArtifactOrigin: update.MachineArtifactOrigin, Client: client, Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	store := adminReleaseSequenceStore{Path: filepath.Join(t.TempDir(), "sequence.json")}
	attempt := newAdminEngineRepairAttempt(engine, store, func() (adminSystemInstallation, error) {
		return adminSystemInstallation{}, nil
	}, update.InstallOptions{
		Stage: func(ctx context.Context, candidate update.Candidate, write func(io.Writer) error) (string, func(), error) {
			path, cleanup, err := stageAdminMSIAt(ctx, t.TempDir(), candidate, write)
			stagedPath = path
			return path, cleanup, err
		},
		Verify: func(_ context.Context, path string) error {
			verifies++
			got, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			if string(got) != string(body) {
				return errors.New("wrong staged bytes")
			}
			return nil
		},
		Handoff: func(_ context.Context, prepared update.Prepared) error {
			handoffs++
			if prepared.Path() == "" {
				return errors.New("missing prepared path")
			}
			return nil
		},
	})
	reboot, err := attempt(context.Background(), ComponentHealthState{})
	if err != nil || reboot {
		t.Fatalf("repair: reboot=%v err=%v", reboot, err)
	}
	if metadataCalls != 1 || artifactCalls != 1 || verifies != 1 || handoffs != 1 {
		t.Fatalf("shared path calls: metadata=%d artifact=%d verify=%d handoff=%d", metadataCalls, artifactCalls, verifies, handoffs)
	}
	if _, err := os.Stat(stagedPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("successful repair left staged MSI: %v", err)
	}
	// Explicit repair must reinstall a valid same-version release when files
	// or registration are damaged even though its manifest version is current.
	sameVersionAttempt := newAdminEngineRepairAttempt(engine, store, func() (adminSystemInstallation, error) {
		return adminSystemInstallation{PackageRelease: "4.0.2", Versions: map[string]string{"service": "4.0.1", "interceptor": "4.0.1"}}, nil
	}, update.InstallOptions{Stage: func(ctx context.Context, candidate update.Candidate, write func(io.Writer) error) (string, func(), error) {
		return stageAdminMSIAt(ctx, t.TempDir(), candidate, write)
	}, Verify: func(context.Context, string) error { verifies++; return nil }, Handoff: func(context.Context, update.Prepared) error { handoffs++; return nil }})
	if reboot, err := sameVersionAttempt(context.Background(), ComponentHealthState{}); err != nil || reboot {
		t.Fatalf("same-version repair: reboot=%v err=%v", reboot, err)
	}
	if metadataCalls != 2 || artifactCalls != 2 || verifies != 2 || handoffs != 2 {
		t.Fatalf("same-version repair skipped shared install: %d/%d/%d/%d", metadataCalls, artifactCalls, verifies, handoffs)
	}
	state, err := store.Load()
	if err != nil || state.Sequence != id.Sequence || state.Namespace != "system" {
		t.Fatalf("accepted sequence: %+v, %v", state, err)
	}
	// An existing System repair must check the real App too, rather than
	// treating installed machine inventory as proof of App compatibility.
	Version = "6.0.0"
	if _, err := sameVersionAttempt(context.Background(), ComponentHealthState{}); err == nil {
		t.Fatal("incompatible App accepted for existing System repair")
	}
	Version = "4.0.0"
	RequiredInterceptorMin, RequiredInterceptorMax = "6.0.0", "7.0.0"
	if _, err := sameVersionAttempt(context.Background(), ComponentHealthState{}); err == nil {
		t.Fatal("incompatible interceptor accepted for existing System repair")
	}
	RequiredInterceptorMin, RequiredInterceptorMax = "4.0.0", "5.0.0"
	if artifactCalls != 2 {
		t.Fatal("incompatible repair downloaded MSI")
	}

	for _, changed := range []bool{false, true} {
		observations := 0
		declined := errors.New("administrator declined elevation")
		handedOff := false
		attempt := newAdminEngineRepairAttempt(engine, store, func() (adminSystemInstallation, error) {
			observations++
			if changed && observations > 1 {
				return adminSystemInstallation{}, errors.New("Suite now installed")
			}
			return adminSystemInstallation{PackageRelease: "4.0.2", Versions: map[string]string{"service": "4.0.1", "interceptor": "4.0.1"}}, nil
		}, update.InstallOptions{
			Stage: func(ctx context.Context, c update.Candidate, write func(io.Writer) error) (string, func(), error) {
				path, cleanup, err := stageAdminMSIAt(ctx, t.TempDir(), c, write)
				stagedPath = path
				return path, cleanup, err
			},
			Verify:  func(context.Context, string) error { return nil },
			Handoff: func(context.Context, update.Prepared) error { handedOff = true; return declined },
		})
		if reboot, err := attempt(context.Background(), ComponentHealthState{}); err == nil || reboot {
			t.Fatalf("failed handoff accepted: reboot=%v err=%v", reboot, err)
		}
		if handedOff == changed {
			t.Fatalf("changed=%v handoff=%v", changed, handedOff)
		}
		if _, err := os.Stat(stagedPath); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("failed handoff retained staged MSI: %v", err)
		}
	}
}

func TestSystemRepairRefusesUncertainMachineBeforeDiscovery(t *testing.T) {
	attempt := newAdminEngineRepairAttempt(nil, adminReleaseSequenceStore{}, func() (adminSystemInstallation, error) {
		return adminSystemInstallation{}, errors.New("Suite, multiple registrations, or unreadable machine identity")
	}, update.InstallOptions{Handoff: func(context.Context, update.Prepared) error {
		t.Fatal("refused observation reached handoff")
		return nil
	}})
	if _, err := attempt(context.Background(), ComponentHealthState{}); err == nil {
		t.Fatal("uncertain observation accepted")
	}
}
