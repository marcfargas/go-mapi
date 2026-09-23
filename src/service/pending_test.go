package service

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func TestPendingV1RoundTripsEveryRecoveryIdentity(t *testing.T) {
	now := time.Date(2026, 9, 23, 7, 0, 0, 123, time.UTC)
	pending := validPending(now)
	pending.Phase = PhaseInstallerRunning
	pending.Runner = &ProcessIdentity{PID: 41, CreatedAtUnixNano: 1001}
	pending.Installer = &ProcessIdentity{PID: 42, CreatedAtUnixNano: 1002}
	pending.Exit = &ExitEvidence{Code: 3010, ObservedAt: now.Add(time.Minute)}
	pending.Result = ResultRebootRequired

	encoded, err := MarshalPending(pending)
	if err != nil {
		t.Fatalf("MarshalPending() error = %v", err)
	}
	decoded, err := UnmarshalPending(encoded)
	if err != nil {
		t.Fatalf("UnmarshalPending() error = %v", err)
	}
	if !reflect.DeepEqual(decoded, pending) {
		t.Fatalf("round trip mismatch\n got: %#v\nwant: %#v", decoded, pending)
	}
}

func TestPendingV1RejectsUnknownOrInvalidRecoveryData(t *testing.T) {
	now := time.Date(2026, 9, 23, 7, 0, 0, 0, time.UTC)
	tests := []struct {
		name   string
		mutate func(*PendingV1)
	}{
		{"unknown schema", func(p *PendingV1) { p.Schema = "pending-v2" }},
		{"unsafe transaction id", func(p *PendingV1) { p.TransactionID = `..\\outside` }},
		{"wrong namespace", func(p *PendingV1) { p.Replay.Namespace = string(update.Suite) }},
		{"hash is not sha256", func(p *PendingV1) { p.ArtifactSHA256 = "abcd" }},
		{"pid lacks creation identity", func(p *PendingV1) { p.Runner = &ProcessIdentity{PID: 41} }},
		{"running without installer identity", func(p *PendingV1) {
			p.Phase = PhaseInstallerRunning
			p.Runner = &ProcessIdentity{PID: 41, CreatedAtUnixNano: 1001}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			pending := validPending(now)
			test.mutate(&pending)
			if _, err := MarshalPending(pending); err == nil {
				t.Fatal("MarshalPending() unexpectedly accepted invalid recovery data")
			}
		})
	}

	encoded, err := MarshalPending(validPending(now))
	if err != nil {
		t.Fatal(err)
	}
	withUnknown := strings.TrimSuffix(string(encoded), "}") + `,"installerArguments":["arbitrary"]}`
	if _, err := UnmarshalPending([]byte(withUnknown)); err == nil {
		t.Fatal("UnmarshalPending() accepted an unknown privileged-input field")
	}
}

func validPending(now time.Time) PendingV1 {
	return PendingV1{
		Schema:         PendingSchemaV1,
		TransactionID:  "tx-123",
		SKU:            update.System,
		Old:            ProductSnapshot{SKU: update.System, PackageVersion: "4.0.1", ProductVersion: "4.0.1", ProductCode: "OLD", Contained: map[string]string{"service": "4.0.1"}},
		Candidate:      ProductSnapshot{SKU: update.System, PackageVersion: "4.0.2", ProductVersion: "4.0.2", ProductCode: "NEW", Contained: map[string]string{"service": "4.0.2"}},
		Replay:         update.ReplayState{Namespace: string(update.System), Sequence: 4, Digest: strings.Repeat("b", 64)},
		ArtifactSHA256: strings.Repeat("a", 64),
		Phase:          PhasePrepared,
		PreparedAt:     now,
		UpdatedAt:      now,
		Attempt:        1,
	}
}
