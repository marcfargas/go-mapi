package service

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestReadinessWaitObservesExactRunnerExit(t *testing.T) {
	runner := ProcessIdentity{PID: 80, CreatedAtUnixNano: 8000}
	ready := RunnerReadyV1{Schema: RunnerReadySchemaV1, TransactionID: "tx-ready", Attempt: 1, Runner: runner,
		Installer: ProcessIdentity{PID: 81, CreatedAtUnixNano: 8001}, ReadyAt: time.Now().UTC()}
	storageErr := errors.New("ready storage unavailable")
	for _, tc := range []struct {
		name        string
		initial     *RunnerReadyV1
		duringProbe *RunnerReadyV1
		readErr     error
		wantErr     string
		wantReads   int
		wantProbes  int
	}{
		{name: "already ready", initial: &ready, wantReads: 1},
		{name: "exited without readiness", wantErr: "runner exited", wantReads: 2, wantProbes: 1},
		{name: "published before exit observation", duringProbe: &ready, wantReads: 2, wantProbes: 1},
		{name: "storage failure after exit", readErr: storageErr, wantErr: storageErr.Error(), wantReads: 2, wantProbes: 1},
		{name: "different runner on first read", initial: func() *RunnerReadyV1 { r := ready; r.Runner.CreatedAtUnixNano++; return &r }(), wantErr: "different runner", wantReads: 1},
		{name: "different runner on final read", duringProbe: func() *RunnerReadyV1 { r := ready; r.Runner.CreatedAtUnixNano++; return &r }(), wantErr: "different runner", wantReads: 2, wantProbes: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			current := tc.initial
			reads, probes := 0, 0
			store := readyLoadFunc(func(_ context.Context, tx string, attempt uint) (*RunnerReadyV1, error) {
				reads++
				if tx != ready.TransactionID || attempt != ready.Attempt {
					t.Fatal("readiness lookup changed transaction/attempt")
				}
				if reads == 2 && tc.readErr != nil {
					return nil, tc.readErr
				}
				return current, nil
			})
			probe := processProbeFunc(func(_ context.Context, identity ProcessIdentity) (bool, error) {
				probes++
				if identity != runner {
					t.Fatalf("probed %v instead of exact runner %v", identity, runner)
				}
				current = tc.duringProbe
				return false, nil
			})
			// A confirmed exit must complete before another poll, without spending
			// the readiness timeout. This bound also makes a missing exit check fail.
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			got, err := (PollReadyAwaiter{Interval: time.Hour, Timeout: time.Hour, Processes: probe}).Await(ctx, store, ready.TransactionID, ready.Attempt, runner)
			if tc.wantErr == "" {
				if err != nil || got != ready {
					t.Fatalf("ready=%+v err=%v", got, err)
				}
			} else if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("want %q, got %v", tc.wantErr, err)
			}
			if reads != tc.wantReads || probes != tc.wantProbes {
				t.Fatalf("reads=%d probes=%d", reads, probes)
			}
		})
	}
}

func TestReadinessWaitRetainsAllowanceForLiveOrUnknownRunner(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
	}{{name: "live"}, {name: "unknown", err: errors.New("process access denied")}} {
		t.Run(tc.name, func(t *testing.T) {
			probed := false
			probe := processProbeFunc(func(context.Context, ProcessIdentity) (bool, error) {
				probed = true
				return tc.err == nil, tc.err
			})
			_, err := (PollReadyAwaiter{Interval: time.Millisecond, Timeout: 20 * time.Millisecond, Processes: probe}).Await(
				context.Background(), readyLoadFunc(func(context.Context, string, uint) (*RunnerReadyV1, error) { return nil, nil }),
				"tx-ready", 1, ProcessIdentity{PID: 80, CreatedAtUnixNano: 8000})
			if !errors.Is(err, context.DeadlineExceeded) || !probed {
				t.Fatalf("probed=%v err=%v", probed, err)
			}
		})
	}
}

func TestReadinessWaitRequiresProcessObservation(t *testing.T) {
	_, err := (PollReadyAwaiter{Interval: time.Millisecond, Timeout: time.Second}).Await(context.Background(),
		readyLoadFunc(func(context.Context, string, uint) (*RunnerReadyV1, error) {
			t.Fatal("invalid awaiter read storage")
			return nil, nil
		}),
		"tx-ready", 1, ProcessIdentity{PID: 80, CreatedAtUnixNano: 8000})
	if err == nil || !strings.Contains(err.Error(), "invalid ready awaiter") {
		t.Fatalf("err=%v", err)
	}
}

type readyLoadFunc func(context.Context, string, uint) (*RunnerReadyV1, error)

func (f readyLoadFunc) Load(ctx context.Context, tx string, attempt uint) (*RunnerReadyV1, error) {
	return f(ctx, tx, attempt)
}
func (readyLoadFunc) Publish(context.Context, RunnerReadyV1) error { panic("unexpected publish") }

type processProbeFunc func(context.Context, ProcessIdentity) (bool, error)

func (f processProbeFunc) Alive(ctx context.Context, identity ProcessIdentity) (bool, error) {
	return f(ctx, identity)
}
