package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// These release-only values are injected by the protected app-release build.
// Empty values deliberately leave repair unavailable; no legacy URL is used.
var AdminReleaseRootB64 string
var AdminReleaseMetadataURL string

func newProductionAdminRepairAttempt() adminRepairAttempt {
	rootBytes, err := base64.RawStdEncoding.DecodeString(AdminReleaseRootB64)
	if err != nil || AdminReleaseMetadataURL == "" {
		return nil
	}
	var root adminReleaseRoot
	if decodeAdminReleaseJSON(rootBytes, &root) != nil {
		return nil
	}
	client := &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return newAdminReleaseRepairAttempt(adminReleaseRepairConfig{
		Root: root, AppVersion: Version, Replay: adminReleaseReplayStore{Path: filepath.Join(appDataDir(), "admin-release-replay-v1.json")}, HTTPClient: client, Now: time.Now,
		Fetch: func(ctx context.Context) ([]byte, error) {
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, AdminReleaseMetadataURL, nil)
			if err != nil {
				return nil, err
			}
			resp, err := client.Do(req)
			if err != nil {
				return nil, err
			}
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				return nil, fmt.Errorf("admin metadata response %s", resp.Status)
			}
			return readBoundedAdminMetadata(resp.Body)
		},
		Stage:     stagePrivilegedAuthorizedAdminMSI,
		Inspector: productionAdminAuthenticodeInspector{},
		Handoff:   handoffAuthorizedAdminMSI,
	})
}

func newUnelevatedAdminRepairAttempt() adminRepairAttempt {
	if newProductionAdminRepairAttempt() == nil {
		return nil
	}
	return func(context.Context, ComponentHealthState) (bool, error) { return launchElevatedAdminHelper() }
}

func runElevatedAdminInstall(ctx context.Context) error {
	attempt := newProductionAdminRepairAttempt()
	if attempt == nil {
		return errAdminReleaseContractUnavailable
	}
	reboot, err := attempt(ctx, ComponentHealthState{})
	if reboot {
		return errAdminMSIRebootRequired
	}
	return err
}

func readBoundedAdminMetadata(body io.Reader) ([]byte, error) {
	const limit = 1 << 20
	buf, err := io.ReadAll(io.LimitReader(body, limit+1))
	if err != nil {
		return nil, err
	}
	if len(buf) > limit {
		return nil, fmt.Errorf("admin metadata is too large")
	}
	return buf, nil
}

func stageAuthorizedAdminMSI(_ context.Context, release authorizedAdminRelease, contents []byte) (string, func(), error) {
	dir, err := os.UserCacheDir()
	if err != nil {
		return "", nil, err
	}
	dir = filepath.Join(dir, "go-mapi", "cache", "admin-installer", release.Payload.Version)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", nil, err
	}
	sum := sha256.Sum256(contents)
	if hex.EncodeToString(sum[:]) != release.Payload.Artifact.SHA256 {
		return "", nil, fmt.Errorf("staging hash mismatch")
	}
	path := filepath.Join(dir, release.Payload.Artifact.SHA256+".msi")
	if err := os.WriteFile(path, contents, 0600); err != nil {
		return "", nil, err
	}
	return path, func() { _ = os.Remove(path) }, nil
}

func stageAdminMSIAt(_ context.Context, root string, release authorizedAdminRelease, contents []byte) (string, func(), error) {
	dir := filepath.Join(root, release.Payload.Version)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", nil, err
	}
	sum := sha256.Sum256(contents)
	if hex.EncodeToString(sum[:]) != release.Payload.Artifact.SHA256 {
		return "", nil, fmt.Errorf("staging hash mismatch")
	}
	path := filepath.Join(dir, release.Payload.Artifact.SHA256+".msi")
	if err := os.WriteFile(path, contents, 0600); err != nil {
		return "", nil, err
	}
	return path, func() { _ = os.Remove(path) }, nil
}
