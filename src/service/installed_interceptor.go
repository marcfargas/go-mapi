package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

const maxInstalledManifestBytes = 64 << 10

type installedInterceptorManifest struct {
	Schema        string                      `json:"schema"`
	Component     string                      `json:"component"`
	Version       string                      `json:"version"`
	QueueProtocol string                      `json:"queueProtocol"`
	Requires      mapi.CounterpartRequirement `json:"requires"`
	Artifacts     []struct {
		Architecture     string `json:"architecture"`
		Path             string `json:"path"`
		PEProductVersion string `json:"peProductVersion"`
		SHA256           string `json:"sha256"`
	} `json:"artifacts"`
}

// verifyInstalledInterceptor checks the installer's committed manifest against
// the two fixed installed DLLs. The caller checks Windows path/reparse and
// registry facts; manifest paths never become filesystem inputs.
func verifyInstalledInterceptor(ctx context.Context, root, version, appVersion string) error {
	manifestPath := filepath.Join(root, "installed-component-v1.json")
	manifestFile, err := os.Open(manifestPath)
	if err != nil {
		return err
	}
	defer manifestFile.Close()
	info, err := manifestFile.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maxInstalledManifestBytes {
		return errors.New("invalid installed interceptor manifest file")
	}
	data, err := io.ReadAll(io.LimitReader(manifestFile, maxInstalledManifestBytes+1))
	if err != nil || len(data) > maxInstalledManifestBytes {
		return errors.New("invalid installed interceptor manifest size")
	}
	var manifest installedInterceptorManifest
	if err := decodeStrict(data, &manifest); err != nil {
		return fmt.Errorf("decode installed interceptor manifest: %w", err)
	}
	if manifest.Schema != "go-mapi-installed-interceptor-v1" || manifest.Component != "interceptor" ||
		manifest.Version != version || manifest.QueueProtocol != "queue-v1" || len(manifest.Artifacts) != 2 ||
		manifest.Requires.Component != "app" || !mapi.IsStrictReleaseVersion(manifest.Requires.MinInclusive) ||
		manifest.Requires.MaxExclusive != "" {
		return errors.New("installed interceptor manifest facts do not match machine product")
	}
	if appVersion != "" && mapi.EvaluateCompatibility(appVersion, manifest.Requires, "").Status != mapi.CompatibilityCompatible {
		return errors.New("installed suite app is incompatible with interceptor")
	}
	seen := map[string]bool{}
	for _, artifact := range manifest.Artifacts {
		relative := ""
		switch artifact.Architecture {
		case "x86":
			relative = `x86\go-mapi.dll`
		case "x64":
			relative = `AMD64\go-mapi.dll`
		default:
			return errors.New("unknown interceptor architecture")
		}
		if seen[artifact.Architecture] || artifact.Path != relative || artifact.PEProductVersion != version ||
			len(artifact.SHA256) != 64 || strings.ToLower(artifact.SHA256) != artifact.SHA256 {
			return errors.New("invalid installed interceptor artifact facts")
		}
		seen[artifact.Architecture] = true
		path := filepath.Join(root, filepath.FromSlash(strings.ReplaceAll(relative, `\`, "/")))
		file, err := os.Open(path)
		if err != nil {
			return err
		}
		info, statErr := file.Stat()
		if statErr != nil || !info.Mode().IsRegular() || info.Size() <= 0 {
			file.Close()
			return errors.New("invalid installed interceptor DLL")
		}
		hash := sha256.New()
		_, copyErr := copyContext(ctx, hash, file)
		closeErr := file.Close()
		if copyErr != nil || closeErr != nil {
			return errors.New("cannot hash installed interceptor DLL")
		}
		if hex.EncodeToString(hash.Sum(nil)) != artifact.SHA256 {
			return errors.New("installed interceptor DLL hash differs from manifest")
		}
	}
	if !seen["x86"] || !seen["x64"] {
		return errors.New("installed interceptor architectures are incomplete")
	}
	return nil
}
