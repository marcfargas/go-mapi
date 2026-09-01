package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sync"
	"time"
)

// AdminInstallPhase is the app-visible state of a consented admin-component
// repair. It deliberately says nothing about how compatibility is evaluated:
// ComponentHealthState remains the version-gate authority.
type AdminInstallPhase string

const (
	AdminInstallHealthy        AdminInstallPhase = "healthy"
	AdminInstallOffer          AdminInstallPhase = "offer"
	AdminInstallPreparing      AdminInstallPhase = "preparing"
	AdminInstallRechecking     AdminInstallPhase = "rechecking"
	AdminInstallRebootRequired AdminInstallPhase = "reboot-required"
	AdminInstallFailed         AdminInstallPhase = "failed"
)

// AdminInstallState is a safe Wails snapshot. It contains no URL, installer
// path, command line, credential, or signing material supplied by the UI.
type AdminInstallState struct {
	Phase       AdminInstallPhase    `json:"phase"`
	Health      ComponentHealthState `json:"health"`
	Fingerprint string               `json:"fingerprint,omitempty"`
	ErrorCode   string               `json:"errorCode,omitempty"`
	Message     string               `json:"message,omitempty"`
	Retryable   bool                 `json:"retryable"`
	UpdatedAt   time.Time            `json:"updatedAt"`
}

// adminRepairAttempt is intentionally an injected seam. The production
// signed-metadata, verified-download and elevated-MSI implementation cannot be
// selected until the update-infrastructure contract supplies its trusted roots,
// metadata envelope and publisher identity. A nil attempt fails closed.
type adminRepairAttempt func(context.Context, ComponentHealthState) (rebootRequired bool, err error)

var errAdminReleaseContractUnavailable = errors.New("trusted admin release metadata is not configured")

type adminInstallCoordinator struct {
	mu      sync.RWMutex
	state   AdminInstallState
	busy    bool
	health  func() ComponentHealthState
	attempt adminRepairAttempt
	emit    func(AdminInstallState)
	now     func() time.Time
}

func newAdminInstallCoordinator(health func() ComponentHealthState, attempt adminRepairAttempt, emit func(AdminInstallState)) *adminInstallCoordinator {
	return &adminInstallCoordinator{health: health, attempt: attempt, emit: emit, now: time.Now}
}

func (c *adminInstallCoordinator) snapshot() AdminInstallState {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.state
}

func (c *adminInstallCoordinator) observe(health ComponentHealthState) AdminInstallState {
	c.mu.Lock()
	if c.busy {
		state := c.state
		c.mu.Unlock()
		return state
	}
	state := adminInstallStateForHealth(health, c.now)
	c.state = state
	c.mu.Unlock()
	c.emitState(state)
	return state
}

func (c *adminInstallCoordinator) start(ctx context.Context) error {
	health := c.health()
	c.mu.Lock()
	if c.busy {
		c.mu.Unlock()
		return errors.New("an admin component repair is already in progress")
	}
	if !adminRepairNeeded(health) {
		state := adminInstallStateForHealth(health, c.now)
		c.state = state
		c.mu.Unlock()
		c.emitState(state)
		return errors.New("the installed admin component does not need repair")
	}
	c.busy = true
	state := AdminInstallState{Phase: AdminInstallPreparing, Health: health, Fingerprint: componentHealthFingerprint(health), UpdatedAt: c.now().UTC()}
	c.state = state
	c.mu.Unlock()
	c.emitState(state)

	go c.run(ctx, health)
	return nil
}

func (c *adminInstallCoordinator) run(ctx context.Context, health ComponentHealthState) {
	attempt := c.attempt
	if attempt == nil {
		attempt = func(context.Context, ComponentHealthState) (bool, error) {
			return false, errAdminReleaseContractUnavailable
		}
	}
	rebootRequired, err := attempt(ctx, health)
	if rebootRequired {
		c.finish(AdminInstallState{Phase: AdminInstallRebootRequired, Health: health, Fingerprint: componentHealthFingerprint(health), ErrorCode: "reboot-required", Message: "Windows must restart before the interceptor can be verified.", Retryable: false, UpdatedAt: c.now().UTC()})
		return
	}
	if err != nil {
		c.finish(AdminInstallState{Phase: AdminInstallFailed, Health: health, Fingerprint: componentHealthFingerprint(health), ErrorCode: adminInstallErrorCode(err), Message: err.Error(), Retryable: true, UpdatedAt: c.now().UTC()})
		return
	}

	c.publish(AdminInstallState{Phase: AdminInstallRechecking, Health: health, Fingerprint: componentHealthFingerprint(health), UpdatedAt: c.now().UTC()})
	postcheck := c.health()
	if adminRepairNeeded(postcheck) {
		c.finish(AdminInstallState{Phase: AdminInstallFailed, Health: postcheck, Fingerprint: componentHealthFingerprint(postcheck), ErrorCode: "post-install-health-failed", Message: "The interceptor is still unhealthy after installation.", Retryable: true, UpdatedAt: c.now().UTC()})
		return
	}
	c.finish(adminInstallStateForHealth(postcheck, c.now))
}

func (c *adminInstallCoordinator) publish(state AdminInstallState) {
	c.mu.Lock()
	c.state = state
	c.mu.Unlock()
	c.emitState(state)
}

func (c *adminInstallCoordinator) finish(state AdminInstallState) {
	c.mu.Lock()
	c.busy = false
	c.state = state
	c.mu.Unlock()
	c.emitState(state)
}

func (c *adminInstallCoordinator) emitState(state AdminInstallState) {
	if c.emit != nil {
		c.emit(state)
	}
}

func adminInstallStateForHealth(health ComponentHealthState, now func() time.Time) AdminInstallState {
	phase := AdminInstallHealthy
	if adminRepairNeeded(health) {
		phase = AdminInstallOffer
	}
	return AdminInstallState{Phase: phase, Health: health, Fingerprint: componentHealthFingerprint(health), UpdatedAt: now().UTC()}
}

func adminRepairNeeded(health ComponentHealthState) bool {
	for _, issue := range health.Issues {
		// App-version compatibility failures require an app update; they must
		// never be misrepresented as an interceptor repair offer.
		if issue.Component == "interceptor" && (issue.Action == "install-interceptor" || issue.Action == "repair-interceptor" || issue.Action == "update-interceptor") {
			return true
		}
	}
	return false
}

func componentHealthFingerprint(health ComponentHealthState) string {
	encoded, err := json.Marshal(struct {
		Healthy bool                   `json:"healthy"`
		Issues  []ComponentHealthIssue `json:"issues"`
	}{Healthy: health.Healthy, Issues: health.Issues})
	if err != nil {
		return ""
	}
	digest := sha256.Sum256(encoded)
	return hex.EncodeToString(digest[:])
}

func adminInstallErrorCode(err error) string {
	if errors.Is(err, errAdminReleaseContractUnavailable) {
		return "release-contract-unavailable"
	}
	return "repair-failed"
}
