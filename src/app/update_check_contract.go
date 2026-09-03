//go:build windows

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

const (
	updateCheckSchema   = "go-mapi-update-check-v1"
	updateCheckEndpoint = "https://go-mapi.app/api/updates/v1/check"
	updateCheckMaxBody  = 1 << 20
)

type updateCheckRequest struct {
	Schema              string `json:"schema"`
	AppVersion          string `json:"appVersion"`
	InterceptorVersion  string `json:"interceptorVersion"`
	DistributionChannel string `json:"distributionChannel"`
	ReleaseTrack        string `json:"releaseTrack"`
	OS                  string `json:"os"`
	Architecture        string `json:"architecture"`
}

type updateCheckComponent struct {
	InstalledVersion string `json:"installedVersion"`
	LatestVersion    string `json:"latestVersion"`
	UpdateAvailable  bool   `json:"updateAvailable"`
	MinAppVersion    string `json:"minAppVersion,omitempty"`
	MaxAppVersion    string `json:"maxAppVersion,omitempty"`
}

type updateCheckResponse struct {
	Schema        string               `json:"schema"`
	App           updateCheckComponent `json:"app"`
	Interceptor   updateCheckComponent `json:"interceptor"`
	Compatibility string               `json:"compatibility"`
}

// updateCheckFetcher is deliberately restricted to the fixed application
// origin. The service never accepts a response-supplied host or artifact URL.
type updateCheckFetcher struct {
	client  *http.Client
	request updateCheckRequest
}

func newUpdateCheckFetcher(appVersion string) *updateCheckFetcher {
	return &updateCheckFetcher{
		client:  &http.Client{Timeout: 15 * time.Second},
		request: updateCheckRequest{Schema: updateCheckSchema, AppVersion: appVersion, InterceptorVersion: installedInterceptorUpdateVersion(), DistributionChannel: updateDistributionChannel(), ReleaseTrack: updateReleaseTrack(appVersion), OS: "windows", Architecture: "x64"},
	}
}

func updateDistributionChannel() string {
	channel, err := newHandoffPlatform().CurrentChannel()
	if err != nil {
		return "unknown"
	}
	if channel == channelStore || channel == channelStandalone {
		return string(channel)
	}
	return "unknown"
}

func updateReleaseTrack(version string) string {
	if mapi.IsStrictReleaseVersion(version) {
		return "stable"
	}
	return "unknown"
}

func installedInterceptorUpdateVersion() string {
	path, err := installedInterceptorManifestPath()
	if err != nil {
		return "unknown"
	}
	data, err := osReadFile(path)
	if errors.Is(err, osErrNotExist) {
		return "absent"
	}
	if err != nil {
		return "unknown"
	}
	var manifest installedInterceptorManifest
	if decodeExactJSON(data, &manifest) != nil || !mapi.IsStrictReleaseVersion(manifest.Version) {
		return "unknown"
	}
	return manifest.Version
}

// These indirections keep platform/path cases testable without reading a real
// Program Files installation.
var osReadFile = func(path string) ([]byte, error) { return os.ReadFile(path) }
var osErrNotExist = os.ErrNotExist

func (f *updateCheckFetcher) FetchLatestRelease(ctx context.Context) (*latestRelease, error) {
	if f == nil || f.client == nil {
		return nil, errors.New("updates: check client not initialised")
	}
	if f.request.ReleaseTrack != "stable" {
		return nil, nil
	}
	body, err := json.Marshal(f.request)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, updateCheckEndpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	resp, err := f.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !strings.Contains(resp.Header.Get("Cache-Control"), "no-store") {
		return nil, fmt.Errorf("updates: invalid check response %s", resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, updateCheckMaxBody+1))
	if err != nil || len(data) > updateCheckMaxBody {
		return nil, errors.New("updates: invalid check response body")
	}
	var result updateCheckResponse
	if err := decodeExactJSON(data, &result); err != nil {
		return nil, fmt.Errorf("updates: decode check response: %w", err)
	}
	if err := validUpdateCheckResponse(result, f.request); err != nil {
		return nil, err
	}
	if !result.App.UpdateAvailable {
		return &latestRelease{InterceptorVersion: result.Interceptor.LatestVersion, InterceptorUpdateAvailable: result.Interceptor.UpdateAvailable, Compatibility: result.Compatibility}, nil
	}
	return &latestRelease{Version: result.App.LatestVersion, ReleaseURL: appUpdateDownloadURL(result.App.LatestVersion), InterceptorVersion: result.Interceptor.LatestVersion, InterceptorUpdateAvailable: result.Interceptor.UpdateAvailable, Compatibility: result.Compatibility}, nil
}

func validUpdateCheckResponse(result updateCheckResponse, request updateCheckRequest) error {
	if result.Schema != updateCheckSchema || (result.Compatibility != "compatible" && result.Compatibility != "incompatible" && result.Compatibility != "unknown") {
		return errors.New("updates: unsupported check schema")
	}
	for _, component := range []updateCheckComponent{result.App, result.Interceptor} {
		if component.LatestVersion != "" && !mapi.IsStrictReleaseVersion(component.LatestVersion) {
			return errors.New("updates: invalid response version")
		}
		if component.UpdateAvailable && component.LatestVersion == "" {
			return errors.New("updates: update is missing a version")
		}
	}
	if result.App.UpdateAvailable && (!mapi.IsStrictReleaseVersion(request.AppVersion) || compareSemver(result.App.LatestVersion, request.AppVersion) <= 0) {
		return errors.New("updates: app update is not newer")
	}
	installed := request.InterceptorVersion
	if result.Interceptor.UpdateAvailable && mapi.IsStrictReleaseVersion(installed) && compareSemver(result.Interceptor.LatestVersion, installed) <= 0 {
		return errors.New("updates: interceptor update is not newer")
	}
	if err := validInterceptorAppRange(result.Interceptor, request.AppVersion); err != nil {
		return err
	}
	return nil
}

func validInterceptorAppRange(component updateCheckComponent, appVersion string) error {
	if component.MinAppVersion == "" && component.MaxAppVersion == "" {
		return nil
	}
	if component.MinAppVersion == "" || !mapi.IsStrictReleaseVersion(component.MinAppVersion) || (component.MaxAppVersion != "" && (!mapi.IsStrictReleaseVersion(component.MaxAppVersion) || compareSemver(component.MinAppVersion, component.MaxAppVersion) >= 0)) {
		return errors.New("updates: invalid interceptor app range")
	}
	if !mapi.IsStrictReleaseVersion(appVersion) {
		return errors.New("updates: invalid app version for interceptor range")
	}
	if compareSemver(appVersion, component.MinAppVersion) < 0 || (component.MaxAppVersion != "" && compareSemver(appVersion, component.MaxAppVersion) >= 0) {
		return errors.New("updates: interceptor update is incompatible with app")
	}
	return nil
}

func appUpdateDownloadURL(version string) string {
	return "https://go-mapi.app/downloads/app/" + version + "/x64"
}

func allowedUpdateURL(value string) bool {
	u, err := url.Parse(value)
	return err == nil && u.Scheme == "https" && u.Host == "go-mapi.app" && strings.HasPrefix(u.Path, "/downloads/app/")
}
