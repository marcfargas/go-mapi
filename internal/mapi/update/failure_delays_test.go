package update

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"
)

func failingEngine(t *testing.T, now time.Time, config Config) *Engine {
	t.Helper()
	config.SKU = System
	config.MetadataOrigin = "https://go-mapi.app"
	config.Now = func() time.Time { return now }
	config.Client = &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("metadata offline")
	})}
	engine, err := NewEngine(config)
	if err != nil {
		t.Fatal(err)
	}
	return engine
}

// The production retry policy is 15 m, 30 m, 1 h and then 6 h, on both the
// failed-check path and the failed-install path, with no validation input.
func TestProductionFailureDelaysAreFixedWithoutConfiguration(t *testing.T) {
	want := []time.Duration{15 * time.Minute, 30 * time.Minute, time.Hour, 6 * time.Hour, 6 * time.Hour}
	if got := ProductionFailureDelays(); len(got) != 4 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] || got[3] != want[3] {
		t.Fatalf("production table = %v", got)
	}
	now := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	engine := failingEngine(t, now, Config{})
	checkState := CheckState{}
	installState := CheckState{}
	for i, delay := range want {
		request := checkRequest(System)
		request.State = checkState
		checked, err := engine.Check(context.Background(), request)
		if err == nil {
			t.Fatalf("check %d: offline metadata accepted", i)
		}
		checkState = checked.State
		if got := checkState.NextAttemptAt.Sub(now); got != delay || checkState.Failures != uint(i+1) {
			t.Fatalf("check failure %d: delay %s failures %d, want %s", i+1, got, checkState.Failures, delay)
		}
		installState = engine.InstallFailureState(installState)
		if got := installState.NextAttemptAt.Sub(now); got != delay || installState.Failures != uint(i+1) {
			t.Fatalf("install failure %d: delay %s failures %d, want %s", i+1, got, installState.Failures, delay)
		}
		checkState.NextAttemptAt = time.Time{}
	}
}

func TestProductionCadenceBoundsApplyWithoutConfiguration(t *testing.T) {
	now := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	for _, interval := range []time.Duration{59 * time.Second, 24*time.Hour + time.Second} {
		_, err := NewEngine(Config{SKU: System, MetadataOrigin: "https://go-mapi.app", Client: &http.Client{}, Now: func() time.Time { return now }, SuccessInterval: interval})
		if err == nil {
			t.Fatalf("interval %s accepted without validation configuration", interval)
		}
	}
}

func TestValidationFailureDelaysScaleTheProductionShape(t *testing.T) {
	delays, err := ScaledFailureDelays(15 * time.Second)
	if err != nil {
		t.Fatal(err)
	}
	want := []time.Duration{15 * time.Second, 30 * time.Second, time.Minute, 6 * time.Minute}
	for i := range want {
		if delays[i] != want[i] {
			t.Fatalf("scaled table = %v, want %v", delays, want)
		}
	}
	if full, err := ScaledFailureDelays(15 * time.Minute); err != nil || full[0] != 15*time.Minute || full[3] != 6*time.Hour {
		t.Fatalf("a 15-minute base must reproduce production: %v %v", full, err)
	}
	now := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	engine := failingEngine(t, now, Config{FailureDelays: delays, SuccessInterval: 5 * time.Second, MinSuccessInterval: time.Second})
	checkState := CheckState{}
	installState := CheckState{}
	for i, delay := range append(want, want[3]) {
		request := checkRequest(System)
		request.State = checkState
		checked, err := engine.Check(context.Background(), request)
		if err == nil {
			t.Fatalf("check %d: offline metadata accepted", i)
		}
		checkState = checked.State
		if got := checkState.NextAttemptAt.Sub(now); got != delay {
			t.Fatalf("scaled check failure %d delay %s, want %s", i+1, got, delay)
		}
		checkState.NextAttemptAt = time.Time{}
		installState = engine.InstallFailureState(installState)
		if got := installState.NextAttemptAt.Sub(now); got != delay {
			t.Fatalf("scaled install failure %d delay %s, want %s", i+1, got, delay)
		}
	}
}

func TestValidationInputsOnlyShortenProductionValues(t *testing.T) {
	if _, err := ScaledFailureDelays(0); err == nil {
		t.Fatal("zero base accepted")
	}
	if _, err := ScaledFailureDelays(-time.Second); err == nil {
		t.Fatal("negative base accepted")
	}
	if _, err := ScaledFailureDelays(999 * time.Millisecond); err == nil {
		t.Fatal("sub-second base accepted")
	}
	if _, err := ScaledFailureDelays(15*time.Minute + time.Second); err == nil {
		t.Fatal("base above the production value accepted")
	}
	now := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	for name, config := range map[string]Config{
		"short table":              {FailureDelays: []time.Duration{time.Second, time.Second, time.Second}},
		"long table":               {FailureDelays: []time.Duration{time.Second, time.Second, time.Second, time.Second, time.Second}},
		"empty table":              {FailureDelays: []time.Duration{}},
		"sub-second entry":         {FailureDelays: []time.Duration{time.Millisecond, time.Second, time.Second, time.Second}},
		"above production":         {FailureDelays: []time.Duration{16 * time.Minute, 30 * time.Minute, time.Hour, 6 * time.Hour}},
		"decreasing entries":       {FailureDelays: []time.Duration{10 * time.Second, 5 * time.Second, 10 * time.Second, 10 * time.Second}},
		"minimum above one minute": {MinSuccessInterval: time.Minute + time.Second},
		"minimum below one second": {MinSuccessInterval: -time.Second},
		"interval below minimum":   {MinSuccessInterval: 5 * time.Second, SuccessInterval: 4 * time.Second},
	} {
		config.SKU, config.MetadataOrigin, config.Client, config.Now = System, "https://go-mapi.app", &http.Client{}, func() time.Time { return now }
		if _, err := NewEngine(config); err == nil {
			t.Fatalf("%s accepted", name)
		}
	}
}

func TestEngineCopiesFailureDelays(t *testing.T) {
	now := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	delays, _ := ScaledFailureDelays(10 * time.Second)
	engine := failingEngine(t, now, Config{FailureDelays: delays})
	delays[0] = time.Hour
	if got := engine.InstallFailureState(CheckState{}).NextAttemptAt.Sub(now); got != 10*time.Second {
		t.Fatalf("caller mutation changed the engine table: %s", got)
	}
}
