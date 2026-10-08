package service

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func TestReadinessFixtureIsExplicitTargetBoundAndPreInstaller(t *testing.T) {
	oldFlag := MachineValidationReadinessFault
	oldStart, oldHeartbeat, oldBase := MachineValidationStartupDelaySeconds, MachineValidationHeartbeatSeconds, MachineValidationFailureBaseSeconds
	defer func() {
		MachineValidationReadinessFault = oldFlag
		MachineValidationStartupDelaySeconds, MachineValidationHeartbeatSeconds, MachineValidationFailureBaseSeconds = oldStart, oldHeartbeat, oldBase
	}()
	MachineValidationReadinessFault = ""
	// A production build must not inspect even an inaccessible marker/storage.
	if hit, err := validationReadinessObstruction(context.Background(), nil, PendingV1{}, ProcessIdentity{}, coordinatorNow); hit || err != nil {
		t.Fatal("production consulted fixture")
	}
	MachineValidationReadinessFault = "enabled"
	MachineValidationStartupDelaySeconds, MachineValidationHeartbeatSeconds, MachineValidationFailureBaseSeconds = "1", "1", "1"
	h := newRecoveryHarness(t, update.System)
	_ = h.install(t, "4.0.1")
	p, _ := h.state.Load(context.Background())
	self := ProcessIdentity{PID: 99, CreatedAtUnixNano: 999}
	marker := readinessObstruction{Schema: "go-mapi-readiness-obstruction-v1", SKU: p.SKU, Digest: p.Replay.Digest, ArtifactSHA256: p.ArtifactSHA256}
	data, _ := json.Marshal(marker)
	_, _ = h.storage.WriteAtomic(context.Background(), []string{readinessObstructionName}, strings.NewReader(string(data)), maxStatusBytes, int64(len(data)), "")
	hit, err := validationReadinessObstruction(context.Background(), h.storage, *p, self, coordinatorNow)
	if !hit || err != nil {
		t.Fatalf("fixture missed %v %v", hit, err)
	}
	raw, err := os.ReadFile(filepath.Join(h.storage.root, "readiness-hit-"+p.TransactionID+".json"))
	if err != nil {
		t.Fatal(err)
	}
	var evidence readinessFixtureHit
	if err := decodeStrict(raw, &evidence); err != nil || evidence.Runner != self || evidence.TransactionID != p.TransactionID {
		t.Fatal("hit identity lost")
	}
	p.ArtifactSHA256 = strings.Repeat("a", 64)
	if hit, err := validationReadinessObstruction(context.Background(), h.storage, *p, self, coordinatorNow); hit || err != nil {
		t.Fatal("foreign target obstructed")
	}
	_, _ = h.storage.WriteAtomic(context.Background(), []string{readinessObstructionName}, strings.NewReader("{}"), maxStatusBytes, 2, "")
	if _, err := validationReadinessObstruction(context.Background(), h.storage, *p, self, coordinatorNow); err == nil {
		t.Fatal("malformed marker silently ignored")
	}
	// Source ordering complements the Windows tagged executable test: the seam
	// must stay before Run, which owns suite drain and StartInstaller.
	source, err := os.ReadFile("runner_windows.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(source[strings.Index(string(source), "func RunProductionUpdateRunner"):])
	if strings.Index(body, "validationReadinessObstruction(") > strings.Index(body, "}).Run(") {
		t.Fatal("fixture moved after MSI entrypoint")
	}
}
