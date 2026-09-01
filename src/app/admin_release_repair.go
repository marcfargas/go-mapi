package main

// This file connects the authorization components without embedding any trust
// material or elevation mechanism. The concrete metadata source, file staging,
// and Authenticode inspection are injected at composition time.
// That keeps the non-elevated verification boundary testable and prevents a UI
// action from ever supplying a URL, MSI path, publisher, or command line. The
// parent app-install ticket owns the separate consent/elevation invocation.

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
)

type adminReleaseEnvelopeFetcher func(context.Context) ([]byte, error)

// adminAuthenticodeIdentity is the minimal result needed to enforce the
// signed publisher policy. It intentionally has no certificate thumbprint:
// policy is durable publisher identity plus required EKUs, not a leaf pin.
type adminAuthenticodeIdentity struct {
	ChainValid bool
	Publisher  string
	EKUs       []string
}

// adminAuthenticodeInspector is implemented by the Windows trust boundary.
// It must validate the Authenticode chain before returning ChainValid=true and
// extract EKUs from the signer/subscriber identity certificates.
type adminAuthenticodeInspector interface {
	InspectAdminMSI(context.Context, string) (adminAuthenticodeIdentity, error)
}

type adminReleaseStager func(context.Context, authorizedAdminRelease, []byte) (path string, cleanup func(), err error)

// authorizedAdminMSICandidate is a staged, byte- and signer-verified MSI.
// It is a pre-UAC handoff only; it contains neither an elevation command nor
// any ability to invoke Windows Installer.
type authorizedAdminMSICandidate struct {
	Release authorizedAdminRelease
	Path    string
}

type adminReleaseCandidateHandoff func(context.Context, authorizedAdminMSICandidate) error

var errAdminMSIRebootRequired = errors.New("admin MSI requires reboot")

type adminReleaseRepairConfig struct {
	Root       adminReleaseRoot
	AppVersion string
	Fetch      adminReleaseEnvelopeFetcher
	Replay     adminReleaseReplayStore
	HTTPClient *http.Client
	Now        func() time.Time
	Stage      adminReleaseStager
	Inspector  adminAuthenticodeInspector
	Handoff    adminReleaseCandidateHandoff
}

// newAdminReleaseRepairAttempt creates the post-consent, pre-UAC
// authorization sequence. Handoff is deliberately the final operation:
// invalid metadata, stale replay, wrong bytes, or a signer-policy failure
// cannot reach the parent-owned elevation path.
func newAdminReleaseRepairAttempt(config adminReleaseRepairConfig) adminRepairAttempt {
	return func(ctx context.Context, _ ComponentHealthState) (bool, error) {
		if config.Fetch == nil || config.Stage == nil || config.Inspector == nil || config.Handoff == nil || config.Replay.Path == "" || config.Now == nil {
			return false, errAdminReleaseContractUnavailable
		}
		envelope, err := config.Fetch(ctx)
		if err != nil {
			return false, fmt.Errorf("fetch admin release metadata: %w", err)
		}
		release, err := verifyAdminRelease(config.Root, envelope, config.AppVersion, config.Now())
		if err != nil {
			return false, fmt.Errorf("verify admin release metadata: %w", err)
		}
		if err := config.Replay.Accept(release); err != nil {
			return false, fmt.Errorf("accept admin release metadata: %w", err)
		}
		bytes, err := downloadAuthorizedAdminRelease(ctx, config.HTTPClient, config.Root, release, config.Now())
		if err != nil {
			return false, err
		}
		msiPath, cleanup, err := config.Stage(ctx, release, bytes)
		if err != nil {
			return false, fmt.Errorf("stage verified admin MSI: %w", err)
		}
		if cleanup != nil {
			defer cleanup()
		}
		identity, err := config.Inspector.InspectAdminMSI(ctx, msiPath)
		if err != nil {
			return false, fmt.Errorf("inspect admin MSI signature: %w", err)
		}
		if err := verifyAdminAuthenticodePolicy(release.Payload.Publisher, identity); err != nil {
			return false, err
		}
		if err := config.Handoff(ctx, authorizedAdminMSICandidate{Release: release, Path: msiPath}); err != nil {
			if errors.Is(err, errAdminMSIRebootRequired) {
				return true, nil
			}
			return false, fmt.Errorf("handoff verified admin MSI: %w", err)
		}
		return false, nil
	}
}

func verifyAdminAuthenticodePolicy(policy adminReleasePublisherPolicy, identity adminAuthenticodeIdentity) error {
	if !identity.ChainValid {
		return errors.New("admin MSI Authenticode chain is not valid")
	}
	if canonicalPublisher(identity.Publisher) != canonicalPublisher(policy.Publisher) {
		return errors.New("admin MSI publisher does not match signed policy")
	}
	for _, required := range policy.EKUs {
		if !containsString(identity.EKUs, required) {
			return fmt.Errorf("admin MSI is missing required signer EKU %q", required)
		}
	}
	return nil
}

func canonicalPublisher(value string) string { return strings.ToLower(strings.TrimSpace(value)) }
