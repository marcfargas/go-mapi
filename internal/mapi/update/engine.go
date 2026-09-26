package update

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/Masterminds/semver/v3"
	"github.com/marcfargas/go-mapi/internal/mapi"
)

type Config struct {
	SKU             SKU
	MetadataOrigin  string
	ArtifactOrigin  string
	Client          *http.Client
	Now             func() time.Time
	SuccessInterval time.Duration
}
type Engine struct {
	config Config
	mu     sync.Mutex
}

func NewEngine(config Config) (*Engine, error) {
	if config.SKU != App && config.SKU != LegacyAdmin && config.SKU != System && config.SKU != Suite || config.Client == nil || config.Now == nil || !validMetadataOrigin(config.MetadataOrigin) {
		return nil, errors.New("invalid updater configuration")
	}
	if config.SKU != App && config.ArtifactOrigin == "" {
		config.ArtifactOrigin = MachineArtifactOrigin
	}
	if config.SKU != App && !validArtifactOrigin(config.ArtifactOrigin) {
		return nil, errors.New("invalid updater artifact origin")
	}
	metadataURL, _ := url.Parse(config.MetadataOrigin)
	if config.SKU != LegacyAdmin && metadataURL.Path != "" && metadataURL.Path != "/" {
		return nil, errors.New("metadata origin must not include a path")
	}
	if config.SKU == LegacyAdmin && (metadataURL.Path == "" || metadataURL.Path == "/") {
		return nil, errors.New("admin metadata URL is incomplete")
	}
	if config.SuccessInterval == 0 {
		if config.SKU == App {
			config.SuccessInterval = 24 * time.Hour
		} else {
			config.SuccessInterval = 6 * time.Hour
		}
	}
	if config.SuccessInterval < time.Minute || config.SuccessInterval > 24*time.Hour {
		return nil, errors.New("invalid updater cadence")
	}
	return &Engine{config: config}, nil
}

type CheckState struct {
	LastAttemptAt time.Time
	LastSuccessAt time.Time
	NextAttemptAt time.Time
	Failures      uint
}
type CheckRequest struct {
	Enabled          bool
	Force            bool
	State            CheckState
	InstalledVersion string
	Installed        map[string]string
	Channel          string
	Track            string
	Accepted         ReplayState
	Committed        ReplayState
	OnAttempt        func(CheckState) error
	AllowSameVersion bool
}
type AppOffer struct {
	Version                    string
	ReleaseURL                 string
	Channel                    string
	InterceptorVersion         string
	InterceptorUpdateAvailable bool
	Compatibility              string
	Available                  bool
}
type Candidate struct {
	engine     *Engine
	release    Release
	actionURL  string
	actionKind string
}

func (c Candidate) Release() Release   { return c.release }
func (c Candidate) Payload() Payload   { return c.release.Payload() }
func (c Candidate) ActionURL() string  { return c.actionURL }
func (c Candidate) ActionKind() string { return c.actionKind }

type CheckResult struct {
	State     CheckState
	Checked   bool
	Available bool
	Candidate Candidate
	App       AppOffer
	Accepted  ReplayState
	ExpiresAt time.Time
}

func (e *Engine) Check(ctx context.Context, r CheckRequest) (CheckResult, error) {
	if e == nil {
		return CheckResult{}, errors.New("updater unavailable")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	result := CheckResult{State: r.State}
	now := e.config.Now().UTC()
	if !r.Enabled && !r.Force {
		return result, nil
	}
	if !r.Force && !r.State.NextAttemptAt.IsZero() && now.Before(r.State.NextAttemptAt) {
		return result, nil
	}
	if !r.Force && !r.State.LastAttemptAt.IsZero() && now.Before(r.State.LastAttemptAt.Add(-time.Minute)) {
		return result, errors.New("updater clock moved backward")
	}
	result.Checked = true
	result.State.LastAttemptAt = now
	result.State.NextAttemptAt = now.Add(15 * time.Minute)
	if r.OnAttempt != nil {
		if err := r.OnAttempt(result.State); err != nil {
			return CheckResult{State: r.State}, err
		}
	}
	if e.config.SKU == App {
		if r.Channel != "standalone" && r.Channel != "store" || r.Track != "stable" && r.Track != "development" {
			result.Checked = false
			result.State = r.State
			return result, nil
		}
		offer, err := e.checkApp(ctx, r)
		if err != nil {
			result.State.Failures++
			result.State.NextAttemptAt = now.Add(e.config.SuccessInterval)
			return result, err
		}
		result.App = offer
		result.Available = offer.Available
		result.State.LastSuccessAt = now
		result.State.Failures = 0
		result.State.NextAttemptAt = now.Add(e.config.SuccessInterval)
		if offer.Available {
			result.Candidate = Candidate{engine: e, actionURL: offer.ReleaseURL, actionKind: r.Channel}
		}
		return result, nil
	}
	release, err := e.checkTarget(ctx, r)
	if err == nil {
		_, err = AcceptReplay(r.Accepted, release)
	}
	if err == nil {
		_, err = AcceptReplay(r.Committed, release)
	}
	if err == nil && (e.config.SKU == System || e.config.SKU == Suite) {
		var id mapi.MachinePackageIdentity
		id, err = mapi.NewMachinePackageIdentity(mapi.MachineSKU(e.config.SKU), r.InstalledVersion)
		if err == nil && (release.Sequence() < id.Sequence || mapi.ReleaseTrack(release.Payload().Version) != mapi.ReleaseTrack(r.InstalledVersion)) {
			err = errors.New("wrong machine release track or downgrade")
		}
	}
	if err == nil && e.config.SKU == LegacyAdmin && mapi.IsStrictReleaseVersion(r.InstalledVersion) {
		current, _ := semver.StrictNewVersion(r.InstalledVersion)
		target, _ := semver.StrictNewVersion(release.Payload().Version)
		if target.LessThan(current) {
			err = errors.New("admin repair downgrade rejected")
		}
	}
	if err != nil {
		result.State.Failures++
		delays := []time.Duration{15 * time.Minute, 30 * time.Minute, time.Hour, 6 * time.Hour}
		i := int(result.State.Failures) - 1
		if i >= len(delays) {
			i = len(delays) - 1
		}
		result.State.NextAttemptAt = now.Add(delays[i])
		return result, err
	}
	result.State.LastSuccessAt = now
	result.State.NextAttemptAt = now.Add(e.config.SuccessInterval)
	result.Accepted, _ = AcceptReplay(r.Accepted, release)
	result.ExpiresAt, _ = time.Parse(time.RFC3339, release.Payload().ExpiresAt)
	result.Available = release.Payload().Version != r.InstalledVersion || e.config.SKU == LegacyAdmin && r.AllowSameVersion
	if !result.Available {
		result.State.Failures = 0
	}
	if result.Available {
		release.engine = e
		result.Candidate = Candidate{engine: e, release: release}
	}
	return result, nil
}

type Prepared struct {
	engine    *Engine
	candidate Candidate
	path      string
	cleanup   func()
}

func (p Prepared) Path() string     { return p.path }
func (p Prepared) Release() Release { return p.candidate.release }
func (p Prepared) Cleanup() {
	if p.cleanup != nil {
		p.cleanup()
	}
}

type InstallOptions struct {
	BeforePrepare func(context.Context, Candidate) error
	Stage         func(context.Context, Candidate, func(io.Writer) error) (string, func(), error)
	Verify        func(context.Context, string) error
	Handoff       func(context.Context, Prepared) error
	OpenURL       func(context.Context, string) error
}
type InstallResult struct {
	Prepared  bool
	ActionURL string
}

func (e *Engine) Prepare(ctx context.Context, c Candidate, o InstallOptions) (Prepared, error) {
	if e == nil || c.engine != e || c.actionKind != "" || c.release.engine != e {
		return Prepared{}, errors.New("candidate does not belong to updater")
	}
	if o.BeforePrepare != nil {
		if err := o.BeforePrepare(ctx, c); err != nil {
			return Prepared{}, err
		}
	}
	if o.Stage == nil || o.Verify == nil {
		return Prepared{}, errors.New("updater preparation unavailable")
	}
	if err := validatePayload(e.config.SKU, c.release.payload, c.release.installed, e.config.Now().UTC(), e.config.ArtifactOrigin); err != nil {
		return Prepared{}, err
	}
	called := false
	write := func(w io.Writer) error {
		if called {
			return errors.New("artifact download already attempted")
		}
		called = true
		return e.downloadTo(ctx, c.release, w)
	}
	path, cleanup, err := o.Stage(ctx, c, write)
	if err != nil {
		if cleanup != nil {
			cleanup()
		}
		return Prepared{}, err
	}
	if !called || path == "" {
		if cleanup != nil {
			cleanup()
		}
		return Prepared{}, errors.New("artifact was not staged")
	}
	if err := validateLifetime(c.release.payload, e.config.Now().UTC()); err != nil {
		if cleanup != nil {
			cleanup()
		}
		return Prepared{}, err
	}
	if err := o.Verify(ctx, path); err != nil {
		if cleanup != nil {
			cleanup()
		}
		return Prepared{}, fmt.Errorf("verify Windows artifact signature: %w", err)
	}
	return Prepared{engine: e, candidate: c, path: path, cleanup: cleanup}, nil
}

// InstallFailureState keeps artifact and handoff retries in the target's one
// check-state record. The caller persists this state through its existing owner.
func (e *Engine) InstallFailureState(state CheckState) CheckState {
	if e == nil {
		return state
	}
	now := e.config.Now().UTC()
	state.Failures++
	delays := []time.Duration{15 * time.Minute, 30 * time.Minute, time.Hour, 6 * time.Hour}
	i := int(state.Failures) - 1
	if i >= len(delays) {
		i = len(delays) - 1
	}
	state.NextAttemptAt = now.Add(delays[i])
	return state
}
func (e *Engine) InstallSuccessState(state CheckState) CheckState {
	state.Failures = 0
	return state
}
func (e *Engine) Install(ctx context.Context, c Candidate, o InstallOptions) (InstallResult, error) {
	if e == nil || c.engine != e {
		return InstallResult{}, errors.New("candidate does not belong to updater")
	}
	if c.actionKind != "" {
		if o.OpenURL == nil || c.actionURL == "" {
			return InstallResult{}, errors.New("update action unavailable")
		}
		return InstallResult{ActionURL: c.actionURL}, o.OpenURL(ctx, c.actionURL)
	}
	p, err := e.Prepare(ctx, c, o)
	if err != nil {
		return InstallResult{}, err
	}
	if o.Handoff == nil {
		p.Cleanup()
		return InstallResult{}, errors.New("installer handoff unavailable")
	}
	if err := o.Handoff(ctx, p); err != nil {
		p.Cleanup()
		return InstallResult{}, err
	}
	return InstallResult{Prepared: true}, nil
}
func compatibilityVersions(p Payload) map[string]string {
	m := map[string]string{}
	for _, c := range p.Contained {
		m[c.Component] = c.Version
	}
	if p.Component != "" {
		m["app"] = p.Requires.MinInclusive
	}
	return m
}
