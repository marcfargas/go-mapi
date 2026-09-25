package update

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/Masterminds/semver/v3"
	"github.com/marcfargas/go-mapi/internal/mapi"
)

const maxMetadataBytes = 1 << 20
const appCheckSchema = "go-mapi-update-check-v1"

type appRequest struct {
	Schema              string `json:"schema"`
	AppVersion          string `json:"appVersion"`
	InterceptorVersion  string `json:"interceptorVersion"`
	DistributionChannel string `json:"distributionChannel"`
	ReleaseTrack        string `json:"releaseTrack"`
	OS                  string `json:"os"`
	Architecture        string `json:"architecture"`
}
type appComponent struct {
	InstalledVersion string `json:"installedVersion"`
	LatestVersion    string `json:"latestVersion"`
	UpdateAvailable  bool   `json:"updateAvailable"`
	MinAppVersion    string `json:"minAppVersion,omitempty"`
	MaxAppVersion    string `json:"maxAppVersion,omitempty"`
}
type appResponse struct {
	Schema        string       `json:"schema"`
	App           appComponent `json:"app"`
	Interceptor   appComponent `json:"interceptor"`
	Compatibility string       `json:"compatibility"`
}

func validMetadataOrigin(raw string) bool {
	u, e := url.Parse(raw)
	return e == nil && u.Scheme == "https" && u.Host != "" && u.User == nil && u.RawQuery == "" && u.Fragment == "" && u.Opaque == ""
}
func (e *Engine) fetch(ctx context.Context, method, urlString string, body io.Reader, header http.Header) ([]byte, http.Header, error) {
	req, err := http.NewRequestWithContext(ctx, method, urlString, body)
	if err != nil {
		return nil, nil, err
	}
	req.Header = header
	client := *e.config.Client
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	res, err := client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, nil, fmt.Errorf("metadata response %s", res.Status)
	}
	if res.ContentLength > maxMetadataBytes {
		return nil, nil, errors.New("metadata exceeds bound")
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, maxMetadataBytes+1))
	if err != nil || len(data) > maxMetadataBytes {
		return nil, nil, errors.New("invalid metadata body")
	}
	return data, res.Header.Clone(), nil
}
func (e *Engine) checkTarget(ctx context.Context, r CheckRequest) (Release, error) {
	endpoint := strings.TrimRight(e.config.MetadataOrigin, "/")
	if e.config.SKU == System || e.config.SKU == Suite {
		endpoint += "/machine/" + string(e.config.SKU) + "/targets.json"
	}
	header := make(http.Header)
	if e.config.SKU == System || e.config.SKU == Suite {
		header.Set("X-Go-Mapi-Installed-Version", r.InstalledVersion)
	}
	data, _, err := e.fetch(ctx, http.MethodGet, endpoint, nil, header)
	if err != nil {
		return Release{}, err
	}
	return ParseTarget(e.config.SKU, data, r.Installed, e.config.Now().UTC(), e.config.ArtifactOrigin)
}
func (e *Engine) checkApp(ctx context.Context, r CheckRequest) (AppOffer, error) {
	request := appRequest{Schema: appCheckSchema, AppVersion: r.InstalledVersion, InterceptorVersion: r.Installed["interceptor"], DistributionChannel: r.Channel, ReleaseTrack: r.Track, OS: "windows", Architecture: "x64"}
	body, err := json.Marshal(request)
	if err != nil {
		return AppOffer{}, err
	}
	endpoint := strings.TrimRight(e.config.MetadataOrigin, "/") + "/api/updates/v1/check"
	h := make(http.Header)
	h.Set("Content-Type", "application/json")
	h.Set("Accept", "application/json")
	data, responseHeaders, err := e.fetch(ctx, http.MethodPost, endpoint, bytes.NewReader(body), h)
	if err != nil {
		return AppOffer{}, err
	}
	if !hasNoStore(responseHeaders.Values("Cache-Control")) {
		return AppOffer{}, errors.New("invalid app update response")
	}
	var value appResponse
	if err := DecodeJSON(data, &value); err != nil {
		return AppOffer{}, err
	}
	if err := validateAppWire(data, value, request); err != nil {
		return AppOffer{}, err
	}
	available := value.Interceptor.UpdateAvailable && allowsApp(value.Interceptor, request.AppVersion)
	offer := AppOffer{Channel: r.Channel, InterceptorVersion: value.Interceptor.LatestVersion, InterceptorUpdateAvailable: available, Compatibility: value.Compatibility, Available: value.App.UpdateAvailable}
	if r.Channel == "store" {
		offer.Version = value.App.LatestVersion
		if value.App.UpdateAvailable {
			offer.ReleaseURL = "ms-windows-store://downloadsandupdates"
		}
		return offer, nil
	}
	if value.App.UpdateAvailable {
		offer.Version = value.App.LatestVersion
		offer.ReleaseURL = "https://go-mapi.app/downloads/app/" + value.App.LatestVersion + "/x64"
	}
	return offer, nil
}
func hasNoStore(values []string) bool {
	for _, v := range values {
		for _, d := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(d), "no-store") {
				return true
			}
		}
	}
	return false
}
func missing(m map[string]json.RawMessage, key string) bool {
	v, ok := m[key]
	return !ok || len(v) == 0 || bytes.Equal(v, []byte("null"))
}
func validateAppWire(data []byte, v appResponse, r appRequest) error {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return err
	}
	for _, k := range []string{"schema", "app", "interceptor", "compatibility"} {
		if missing(root, k) {
			return fmt.Errorf("missing %s", k)
		}
	}
	for _, k := range []string{"app", "interceptor"} {
		var c map[string]json.RawMessage
		if json.Unmarshal(root[k], &c) != nil || c == nil {
			return fmt.Errorf("invalid %s", k)
		}
		for _, f := range []string{"installedVersion", "latestVersion", "updateAvailable"} {
			if missing(c, f) {
				return fmt.Errorf("missing %s.%s", k, f)
			}
		}
	}
	if v.Schema != appCheckSchema || v.App.InstalledVersion != r.AppVersion || v.Interceptor.InstalledVersion != r.InterceptorVersion {
		return errors.New("app update response identity changed")
	}
	if v.Compatibility != "compatible" && v.Compatibility != "incompatible" && v.Compatibility != "unknown" {
		return errors.New("invalid compatibility result")
	}
	for _, c := range []appComponent{v.App, v.Interceptor} {
		if c.LatestVersion != "" && (!mapi.IsStrictReleaseVersion(c.LatestVersion) || mapi.ReleaseTrack(c.LatestVersion) != r.ReleaseTrack) {
			return errors.New("invalid app response version")
		}
		if c.UpdateAvailable && c.LatestVersion == "" {
			return errors.New("available update missing version")
		}
	}
	if v.App.UpdateAvailable {
		latest, _ := semver.StrictNewVersion(v.App.LatestVersion)
		current, err := semver.StrictNewVersion(r.AppVersion)
		if err == nil && !latest.GreaterThan(current) {
			return errors.New("app update is not newer")
		}
	} else if v.App.LatestVersion != "" && mapi.IsStrictReleaseVersion(r.AppVersion) {
		latest, _ := semver.StrictNewVersion(v.App.LatestVersion)
		current, _ := semver.StrictNewVersion(r.AppVersion)
		if latest.GreaterThan(current) {
			return errors.New("app availability contradicts latest version")
		}
	}
	if v.Interceptor.UpdateAvailable && mapi.IsStrictReleaseVersion(r.InterceptorVersion) {
		latest, _ := semver.StrictNewVersion(v.Interceptor.LatestVersion)
		current, _ := semver.StrictNewVersion(r.InterceptorVersion)
		if !latest.GreaterThan(current) {
			return errors.New("interceptor update is not newer")
		}
	}
	if err := validAppRange(v.Interceptor); err != nil {
		return err
	}
	return nil
}
func validAppRange(c appComponent) error {
	if c.MinAppVersion == "" && c.MaxAppVersion == "" {
		return nil
	}
	if !mapi.IsStrictReleaseVersion(c.MinAppVersion) {
		return errors.New("invalid interceptor app range")
	}
	if c.MaxAppVersion != "" {
		if !mapi.IsStrictReleaseVersion(c.MaxAppVersion) {
			return errors.New("invalid interceptor app range")
		}
		min, _ := semver.StrictNewVersion(c.MinAppVersion)
		max, _ := semver.StrictNewVersion(c.MaxAppVersion)
		if !min.LessThan(max) {
			return errors.New("invalid interceptor app range")
		}
	}
	return nil
}
func allowsApp(c appComponent, version string) bool {
	if c.MinAppVersion == "" {
		return true
	}
	current, err := semver.StrictNewVersion(version)
	if err != nil {
		return false
	}
	min, _ := semver.StrictNewVersion(c.MinAppVersion)
	if current.LessThan(min) {
		return false
	}
	if c.MaxAppVersion != "" {
		max, _ := semver.StrictNewVersion(c.MaxAppVersion)
		if !current.LessThan(max) {
			return false
		}
	}
	return true
}
