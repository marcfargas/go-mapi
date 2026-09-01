package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

const (
	installedInterceptorSchema     = "go-mapi-installed-interceptor-v1"
	installedInterceptorName       = "installed-component-v1.json"
	componentMismatchWarningSchema = "go-mapi-component-version-mismatch-v1"
	componentMismatchWarningName   = "component-version-mismatch-v1.json"
	componentHealthRefreshInterval = time.Minute
)

type installedInterceptorArtifact struct {
	Architecture     string `json:"architecture"`
	Path             string `json:"path"`
	PEProductVersion string `json:"peProductVersion"`
	SHA256           string `json:"sha256"`
}

type installedInterceptorManifest struct {
	Schema        string                         `json:"schema"`
	Component     string                         `json:"component"`
	Version       string                         `json:"version"`
	QueueProtocol string                         `json:"queueProtocol"`
	Requires      mapi.CounterpartRequirement    `json:"requires"`
	Artifacts     []installedInterceptorArtifact `json:"artifacts"`
}

type componentMismatchWarning struct {
	Schema      string `json:"schema"`
	Interceptor struct {
		Version      string                      `json:"version"`
		Architecture string                      `json:"architecture"`
		Requires     mapi.CounterpartRequirement `json:"requires"`
	} `json:"interceptor"`
	App struct {
		ObservedStatus  string `json:"observedStatus"`
		ObservedVersion string `json:"observedVersion,omitempty"`
	} `json:"app"`
	Action    string    `json:"action"`
	CreatedAt time.Time `json:"createdAt"`
}

type ComponentHealthIssue struct {
	Code             string                      `json:"code"`
	Component        string                      `json:"component"`
	InstalledVersion string                      `json:"installedVersion,omitempty"`
	Required         mapi.CounterpartRequirement `json:"required"`
	Architectures    []string                    `json:"architectures,omitempty"`
	Action           string                      `json:"action"`
	Message          string                      `json:"message"`
}

type ComponentHealthState struct {
	Healthy   bool                   `json:"healthy"`
	Issues    []ComponentHealthIssue `json:"issues"`
	CheckedAt time.Time              `json:"checkedAt"`
}

type componentHealthProbe struct {
	appVersion             string
	interceptorRequirement mapi.CounterpartRequirement
	manifestPath           func() (string, error)
	peProductVersion       func(string) (string, error)
	warningPath            string
	now                    func() time.Time
}

func newProductionComponentHealthProbe(appVersion, queueDir string) componentHealthProbe {
	return componentHealthProbe{
		appVersion:             appVersion,
		interceptorRequirement: mapi.CounterpartRequirement{Component: "interceptor", MinInclusive: RequiredInterceptorMin, MaxExclusive: RequiredInterceptorMax},
		manifestPath:           installedInterceptorManifestPath,
		peProductVersion:       readPEProductVersion,
		warningPath:            filepath.Join(queueDir, "warnings", componentMismatchWarningName),
		now:                    time.Now,
	}
}

func (p componentHealthProbe) probe() ComponentHealthState {
	state := ComponentHealthState{CheckedAt: p.now().UTC(), Issues: []ComponentHealthIssue{}}
	state.Issues = append(state.Issues, p.probeInstalledInterceptor()...)
	if warningIssue := p.probeMismatchWarning(); warningIssue != nil {
		state.Issues = append(state.Issues, *warningIssue)
	}
	state.Issues = dedupeHealthIssues(state.Issues)
	state.Healthy = len(state.Issues) == 0
	return state
}

func (p componentHealthProbe) probeInstalledInterceptor() []ComponentHealthIssue {
	manifestPath, err := p.manifestPath()
	if err != nil {
		return []ComponentHealthIssue{healthIssue("unreadable", "interceptor", "repair-interceptor", err.Error(), p.interceptorRequirement)}
	}
	data, err := os.ReadFile(manifestPath)
	if errors.Is(err, os.ErrNotExist) {
		return []ComponentHealthIssue{healthIssue("missing", "interceptor", "install-interceptor", "The machine-wide interceptor is not installed.", p.interceptorRequirement)}
	}
	if err != nil {
		return []ComponentHealthIssue{healthIssue("unreadable", "interceptor", "repair-interceptor", "The installed interceptor manifest cannot be read.", p.interceptorRequirement)}
	}
	var manifest installedInterceptorManifest
	if err := decodeExactJSON(data, &manifest); err != nil {
		return []ComponentHealthIssue{healthIssue("invalid", "interceptor", "repair-interceptor", "The installed interceptor manifest is invalid.", p.interceptorRequirement)}
	}
	if err := validateInstalledManifest(manifestPath, manifest, p.peProductVersion); err != nil {
		code := "invalid"
		if strings.Contains(err.Error(), "unreadable") {
			code = "unreadable"
		}
		if strings.Contains(err.Error(), "missing architecture") {
			code = "architecture-missing"
		}
		if strings.Contains(err.Error(), "divergent") {
			code = "architecture-divergent"
		}
		return []ComponentHealthIssue{healthIssue(code, "interceptor", "repair-interceptor", err.Error(), p.interceptorRequirement)}
	}
	issues := []ComponentHealthIssue{}
	installed := mapi.EvaluateCompatibility(manifest.Version, p.interceptorRequirement, "update-interceptor")
	if installed.Status != mapi.CompatibilityCompatible {
		issue := healthIssue(string(installed.Status), "interceptor", installed.Action, "The installed interceptor is not compatible with this app.", p.interceptorRequirement)
		issue.InstalledVersion = manifest.Version
		issues = append(issues, issue)
	}
	appResult := mapi.EvaluateCompatibility(p.appVersion, manifest.Requires, "update-app")
	if appResult.Status != mapi.CompatibilityCompatible {
		issue := healthIssue(string(appResult.Status), "app", appResult.Action, "This app is not compatible with the installed interceptor.", manifest.Requires)
		issue.InstalledVersion = p.appVersion
		issues = append(issues, issue)
	}
	return issues
}

func validateInstalledManifest(manifestPath string, manifest installedInterceptorManifest, peVersion func(string) (string, error)) error {
	if manifest.Schema != installedInterceptorSchema || manifest.Component != "interceptor" || manifest.QueueProtocol != componentQueueProtocol || !mapi.IsStrictReleaseVersion(manifest.Version) {
		return fmt.Errorf("installed interceptor identity or version is invalid")
	}
	if manifest.Requires.Component != "app" || mapi.EvaluateCompatibility(manifest.Version, manifest.Requires, "update-app").Status == mapi.CompatibilityInvalid {
		return fmt.Errorf("installed interceptor requirement is invalid")
	}
	if len(manifest.Artifacts) != 2 {
		return fmt.Errorf("missing architecture: expected x86 and x64")
	}
	base := filepath.Dir(filepath.Clean(manifestPath))
	seen := map[string]bool{}
	for _, artifact := range manifest.Artifacts {
		if artifact.Architecture != "x86" && artifact.Architecture != "x64" {
			return fmt.Errorf("unknown architecture %q", artifact.Architecture)
		}
		if seen[artifact.Architecture] {
			return fmt.Errorf("duplicate architecture %q", artifact.Architecture)
		}
		seen[artifact.Architecture] = true
		if filepath.IsAbs(artifact.Path) || artifact.Path == "" {
			return fmt.Errorf("artifact path must be relative")
		}
		clean := filepath.Clean(artifact.Path)
		if clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
			return fmt.Errorf("artifact path escapes install directory")
		}
		full := filepath.Join(base, clean)
		rel, err := filepath.Rel(base, full)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return fmt.Errorf("artifact path escapes install directory")
		}
		if artifact.PEProductVersion != manifest.Version {
			return fmt.Errorf("architecture-divergent: %s manifest version", artifact.Architecture)
		}
		if len(artifact.SHA256) != 64 {
			return fmt.Errorf("invalid %s SHA-256", artifact.Architecture)
		}
		if _, err := hex.DecodeString(artifact.SHA256); err != nil {
			return fmt.Errorf("invalid %s SHA-256", artifact.Architecture)
		}
		actualPE, err := peVersion(full)
		if err != nil {
			return fmt.Errorf("unreadable %s PE metadata: %w", artifact.Architecture, err)
		}
		if actualPE != manifest.Version {
			return fmt.Errorf("architecture-divergent: %s PE ProductVersion %q", artifact.Architecture, actualPE)
		}
		contents, err := os.ReadFile(full)
		if err != nil {
			return fmt.Errorf("unreadable %s DLL: %w", artifact.Architecture, err)
		}
		hash := sha256.Sum256(contents)
		if hex.EncodeToString(hash[:]) != strings.ToLower(artifact.SHA256) {
			return fmt.Errorf("invalid %s artifact hash", artifact.Architecture)
		}
	}
	if !seen["x86"] || !seen["x64"] {
		return fmt.Errorf("missing architecture: expected x86 and x64")
	}
	return nil
}

func (p componentHealthProbe) probeMismatchWarning() *ComponentHealthIssue {
	data, err := os.ReadFile(p.warningPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		issue := healthIssue("diagnostic-invalid", "interceptor", "repair-interceptor", "The interceptor diagnostic cannot be read.", mapi.CounterpartRequirement{Component: "app"})
		return &issue
	}
	var warning componentMismatchWarning
	if err := decodeExactJSON(data, &warning); err != nil || warning.Schema != componentMismatchWarningSchema || warning.Action != "update-app" || warning.Interceptor.Architecture != "x86" && warning.Interceptor.Architecture != "x64" || !mapi.IsStrictReleaseVersion(warning.Interceptor.Version) || warning.Interceptor.Requires.Component != "app" || warning.CreatedAt.IsZero() || !validObservedStatus(warning.App.ObservedStatus) || warning.App.ObservedVersion != "" && !mapi.IsStrictReleaseVersion(warning.App.ObservedVersion) {
		issue := healthIssue("diagnostic-invalid", "interceptor", "repair-interceptor", "The interceptor diagnostic is invalid.", mapi.CounterpartRequirement{Component: "app"})
		return &issue
	}
	if p.manifestPath != nil {
		manifestPath, err := p.manifestPath()
		if err == nil {
			if manifestData, err := os.ReadFile(manifestPath); err == nil {
				var installed installedInterceptorManifest
				if decodeExactJSON(manifestData, &installed) == nil && installed.Schema == installedInterceptorSchema &&
					(installed.Version != warning.Interceptor.Version || installed.Requires != warning.Interceptor.Requires) {
					issue := healthIssue("diagnostic-invalid", "interceptor", "repair-interceptor", "The interceptor diagnostic conflicts with installed release metadata.", warning.Interceptor.Requires)
					return &issue
				}
			}
		}
	}
	result := mapi.EvaluateCompatibility(p.appVersion, warning.Interceptor.Requires, "update-app")
	if result.Status == mapi.CompatibilityCompatible {
		_ = os.Remove(p.warningPath)
		return nil
	}
	if result.Status == mapi.CompatibilityInvalid {
		issue := healthIssue("diagnostic-invalid", "interceptor", "repair-interceptor", "The interceptor diagnostic contains an invalid version range.", warning.Interceptor.Requires)
		return &issue
	}
	issue := healthIssue(string(result.Status), "app", "update-app", "Update go-mapi to restore MAPI compatibility.", warning.Interceptor.Requires)
	issue.InstalledVersion = p.appVersion
	issue.Architectures = []string{warning.Interceptor.Architecture}
	return &issue
}

func healthIssue(code, component, action, message string, required mapi.CounterpartRequirement) ComponentHealthIssue {
	return ComponentHealthIssue{Code: code, Component: component, Action: action, Message: message, Required: required}
}

func validObservedStatus(status string) bool {
	switch status {
	case "missing", "unreadable", "malformed", "stale", "future", "invalid", "below-minimum", "above-maximum":
		return true
	default:
		return false
	}
}

func dedupeHealthIssues(issues []ComponentHealthIssue) []ComponentHealthIssue {
	result := make([]ComponentHealthIssue, 0, len(issues))
	for _, issue := range issues {
		merged := false
		for i := range result {
			if result[i].Code == issue.Code && result[i].Component == issue.Component && result[i].Action == issue.Action && result[i].Required == issue.Required {
				for _, arch := range issue.Architectures {
					found := false
					for _, existing := range result[i].Architectures {
						if existing == arch {
							found = true
							break
						}
					}
					if !found {
						result[i].Architectures = append(result[i].Architectures, arch)
					}
				}
				merged = true
				break
			}
		}
		if !merged {
			result = append(result, issue)
		}
	}
	return result
}

func decodeExactJSON(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return fmt.Errorf("trailing JSON data")
	}
	return nil
}

func mapiVersionIsRuntimeValid(version string) bool {
	return mapi.IsStrictReleaseVersion(version) || version == "0.0.0-dev"
}

type componentHealthStore struct {
	mu    sync.RWMutex
	state ComponentHealthState
}

func (s *componentHealthStore) load() ComponentHealthState {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state
}
func (s *componentHealthStore) store(state ComponentHealthState) {
	s.mu.Lock()
	s.state = state
	s.mu.Unlock()
}
