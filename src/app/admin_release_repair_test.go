package main

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fakeAdminAuthenticodeInspector struct {
	identity adminAuthenticodeIdentity
	err      error
	called   bool
}

func (f *fakeAdminAuthenticodeInspector) InspectAdminMSI(_ context.Context, path string) (adminAuthenticodeIdentity, error) {
	f.called = true
	if path == "" {
		return adminAuthenticodeIdentity{}, io.ErrUnexpectedEOF
	}
	return f.identity, f.err
}

func TestAdminReleaseRepairIsVerifiedBeforePreUACHandOff(t *testing.T) {
	rootPub, _ := adminTestKey(t)
	targetPub, targetKey := adminTestKey(t)
	root := adminTestRoot(t, 1, rootPub, targetPub)
	body := []byte("verified MSI fixture")
	digest := sha256.Sum256(body)
	payload := adminTestPayload()
	payload.Artifact.Size = int64(len(body))
	payload.Artifact.SHA256 = hex.EncodeToString(digest[:])
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	inspector := &fakeAdminAuthenticodeInspector{identity: adminAuthenticodeIdentity{ChainValid: true, Publisher: payload.Publisher.Publisher, EKUs: append([]string(nil), payload.Publisher.EKUs...)}}
	order := []string{}
	installed := false
	client := &http.Client{Transport: adminReleaseRoundTripper(func(request *http.Request) (*http.Response, error) {
		order = append(order, "download")
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), ContentLength: int64(len(body)), Body: io.NopCloser(strings.NewReader(string(body))), Request: request}, nil
	})}
	attempt := newAdminReleaseRepairAttempt(adminReleaseRepairConfig{
		Root: root, AppVersion: "4.0.0", Now: func() time.Time { return now }, HTTPClient: client,
		Replay: adminReleaseReplayStore{Path: t.TempDir() + "/replay.json"},
		Fetch: func(context.Context) ([]byte, error) {
			order = append(order, "metadata")
			return adminTestEnvelope(t, payload, "targets", targetKey), nil
		},
		Stage: func(_ context.Context, _ authorizedAdminRelease, got []byte) (string, func(), error) {
			order = append(order, "stage")
			if string(got) != string(body) {
				t.Fatalf("staged bytes = %q", got)
			}
			return "fixture.msi", func() { order = append(order, "cleanup") }, nil
		},
		Inspector: inspector,
		Handoff: func(_ context.Context, candidate authorizedAdminMSICandidate) error {
			order = append(order, "handoff")
			if !inspector.called || candidate.Path != "fixture.msi" || candidate.Release.Digest == "" {
				t.Fatalf("pre-UAC handoff ran before verification")
			}
			installed = true
			return nil
		},
	})
	health := func() ComponentHealthState {
		if installed {
			return testAdminHealth("", "")
		}
		return testAdminHealth("interceptor", "install-interceptor")
	}
	coordinator := newAdminInstallCoordinator(health, attempt, nil)
	if err := coordinator.start(context.Background()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for coordinator.snapshot().Phase == AdminInstallPreparing || coordinator.snapshot().Phase == AdminInstallRechecking {
		if time.Now().After(deadline) {
			t.Fatal("repair did not finish")
		}
		time.Sleep(time.Millisecond)
	}
	if got := coordinator.snapshot(); got.Phase != AdminInstallHealthy {
		t.Fatalf("repair = %#v", got)
	}
	if strings.Join(order, ",") != "metadata,download,stage,handoff,cleanup" {
		t.Fatalf("repair order = %v", order)
	}
}

func TestAdminAuthenticodePolicyRejectsInvalidPublisherAndSubscriberEKU(t *testing.T) {
	policy := adminReleasePublisherPolicy{Publisher: "Example Publisher", EKUs: []string{"1.3.6.1.5.5.7.3.3", "1.2.3.4"}}
	for name, identity := range map[string]adminAuthenticodeIdentity{
		"invalid chain":      {ChainValid: false, Publisher: policy.Publisher, EKUs: policy.EKUs},
		"wrong publisher":    {ChainValid: true, Publisher: "Other", EKUs: policy.EKUs},
		"missing subscriber": {ChainValid: true, Publisher: policy.Publisher, EKUs: []string{"1.3.6.1.5.5.7.3.3"}},
	} {
		t.Run(name, func(t *testing.T) {
			if err := verifyAdminAuthenticodePolicy(policy, identity); err == nil {
				t.Fatal("accepted invalid signer identity")
			}
		})
	}
}

func TestAdminAuthenticodePolicyRequiresEverySignedEKU(t *testing.T) {
	policy := adminReleasePublisherPolicy{Publisher: "Example Publisher", EKUs: []string{"1.3.6.1.5.5.7.3.3", "1.2.3.4", "1.2.3.5"}}
	if err := verifyAdminAuthenticodePolicy(policy, adminAuthenticodeIdentity{ChainValid: true, Publisher: policy.Publisher, EKUs: policy.EKUs[:2]}); err == nil {
		t.Fatal("accepted signer missing a required policy EKU")
	}
	if err := verifyAdminAuthenticodePolicy(policy, adminAuthenticodeIdentity{ChainValid: true, Publisher: policy.Publisher, EKUs: policy.EKUs}); err != nil {
		t.Fatalf("rejected matching signer policy: %v", err)
	}
}

func TestAdminReleaseRepairDoesNotAdvanceReplayUntilVerifiedCandidateIsStaged(t *testing.T) {
	rootPub, _ := adminTestKey(t)
	targetPub, targetKey := adminTestKey(t)
	root := adminTestRoot(t, 1, rootPub, targetPub)
	body := []byte("verified MSI fixture")
	digest := sha256.Sum256(body)
	payload := adminTestPayload()
	payload.Artifact.Size = int64(len(body))
	payload.Artifact.SHA256 = hex.EncodeToString(digest[:])
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)

	tests := []struct {
		name       string
		download   bool
		stageErr   error
		identity   adminAuthenticodeIdentity
		inspectErr error
	}{
		{name: "download failure", identity: adminAuthenticodeIdentity{ChainValid: true, Publisher: payload.Publisher.Publisher, EKUs: payload.Publisher.EKUs}},
		{name: "stage failure", download: true, stageErr: errors.New("disk full"), identity: adminAuthenticodeIdentity{ChainValid: true, Publisher: payload.Publisher.Publisher, EKUs: payload.Publisher.EKUs}},
		{name: "signature inspection failure", download: true, inspectErr: errors.New("malformed signature")},
		{name: "signer policy failure", download: true, identity: adminAuthenticodeIdentity{ChainValid: true, Publisher: "other publisher", EKUs: payload.Publisher.EKUs}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			store := adminReleaseReplayStore{Path: filepath.Join(t.TempDir(), "replay.json")}
			attempt := adminReleaseRepairFixture(t, root, payload, targetKey, body, now, store, test.download, test.stageErr, test.identity, test.inspectErr, func(context.Context, authorizedAdminMSICandidate) error {
				t.Fatal("handoff must not receive an unverified candidate")
				return nil
			})
			if _, err := attempt(context.Background(), ComponentHealthState{}); err == nil {
				t.Fatal("repair unexpectedly succeeded")
			}
			if state, err := store.Load(); err != nil || state != (adminReleaseReplayState{}) {
				t.Fatalf("failed attempt advanced replay state: %#v, %v", state, err)
			}

			// The same valid release is retryable after the transient/adversarial
			// failure because no earlier step consumed its replay sequence.
			retried := adminReleaseRepairFixture(t, root, payload, targetKey, body, now, store, true, nil,
				adminAuthenticodeIdentity{ChainValid: true, Publisher: payload.Publisher.Publisher, EKUs: payload.Publisher.EKUs}, nil,
				func(context.Context, authorizedAdminMSICandidate) error { return nil })
			if _, err := retried(context.Background(), ComponentHealthState{}); err != nil {
				t.Fatalf("valid retry failed: %v", err)
			}
			if state, err := store.Load(); err != nil || state.Sequence != payload.Sequence {
				t.Fatalf("successful retry did not commit replay state: %#v, %v", state, err)
			}
		})
	}
}

func TestAdminReleaseRepairCommitsBeforeElevationAndAllowsIdenticalRetry(t *testing.T) {
	rootPub, _ := adminTestKey(t)
	targetPub, targetKey := adminTestKey(t)
	root := adminTestRoot(t, 1, rootPub, targetPub)
	body := []byte("verified MSI fixture")
	digest := sha256.Sum256(body)
	payload := adminTestPayload()
	payload.Artifact.Size = int64(len(body))
	payload.Artifact.SHA256 = hex.EncodeToString(digest[:])
	now := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	store := adminReleaseReplayStore{Path: filepath.Join(t.TempDir(), "replay.json")}

	failedHandoff := adminReleaseRepairFixture(t, root, payload, targetKey, body, now, store, true, nil,
		adminAuthenticodeIdentity{ChainValid: true, Publisher: payload.Publisher.Publisher, EKUs: payload.Publisher.EKUs}, nil,
		func(context.Context, authorizedAdminMSICandidate) error { return errors.New("UAC cancelled") })
	if _, err := failedHandoff(context.Background(), ComponentHealthState{}); err == nil {
		t.Fatal("handoff failure unexpectedly succeeded")
	}
	if state, err := store.Load(); err != nil || state.Sequence != payload.Sequence {
		t.Fatalf("verified pre-UAC candidate was not committed: %#v, %v", state, err)
	}

	retried := adminReleaseRepairFixture(t, root, payload, targetKey, body, now, store, true, nil,
		adminAuthenticodeIdentity{ChainValid: true, Publisher: payload.Publisher.Publisher, EKUs: payload.Publisher.EKUs}, nil,
		func(context.Context, authorizedAdminMSICandidate) error { return nil })
	if _, err := retried(context.Background(), ComponentHealthState{}); err != nil {
		t.Fatalf("identical release retry after cancelled UAC failed: %v", err)
	}
}

func adminReleaseRepairFixture(t *testing.T, root adminReleaseRoot, payload adminReleasePayload, targetKey ed25519.PrivateKey, body []byte, now time.Time, store adminReleaseReplayStore, downloadOK bool, stageErr error, identity adminAuthenticodeIdentity, inspectErr error, handoff adminReleaseCandidateHandoff) adminRepairAttempt {
	t.Helper()
	return newAdminReleaseRepairAttempt(adminReleaseRepairConfig{
		Root: root, AppVersion: "4.0.0", Now: func() time.Time { return now }, Replay: store,
		Fetch: func(context.Context) ([]byte, error) { return adminTestEnvelope(t, payload, "targets", targetKey), nil },
		HTTPClient: &http.Client{Transport: adminReleaseRoundTripper(func(request *http.Request) (*http.Response, error) {
			if !downloadOK {
				return nil, errors.New("network unavailable")
			}
			return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), ContentLength: int64(len(body)), Body: io.NopCloser(strings.NewReader(string(body))), Request: request}, nil
		})},
		Stage: func(context.Context, authorizedAdminRelease, []byte) (string, func(), error) {
			if stageErr != nil {
				return "", nil, stageErr
			}
			return "fixture.msi", func() {}, nil
		},
		Inspector: &fakeAdminAuthenticodeInspector{identity: identity, err: inspectErr},
		Handoff:   handoff,
	})
}
