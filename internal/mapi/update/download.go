package update

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

const maxRedirects = 3

func (e *Engine) downloadTo(ctx context.Context, release Release, destination io.Writer) error {
	if e == nil || release.engine != e || release.ns != e.config.SKU || destination == nil {
		return errors.New("unauthorized artifact download")
	}
	if !AllowedArtifactURL(e.config.ArtifactOrigin, mustURL(release.payload.Artifact.URL), false) {
		return errors.New("unauthorized artifact URL")
	}
	client := *e.config.Client
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) > maxRedirects || !AllowedArtifactURL(e.config.ArtifactOrigin, req.URL, true) {
			return errors.New("unauthorized artifact redirect")
		}
		req.Header = make(http.Header)
		return nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, release.payload.Artifact.URL, nil)
	if err != nil {
		return err
	}
	res, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("download artifact: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK || !AllowedArtifactURL(e.config.ArtifactOrigin, res.Request.URL, true) {
		return errors.New("unauthorized artifact response")
	}
	if res.ContentLength >= 0 && res.ContentLength != release.payload.Artifact.Size {
		return errors.New("artifact content length mismatch")
	}
	hash := sha256.New()
	count, err := io.Copy(io.MultiWriter(destination, hash), io.LimitReader(res.Body, release.payload.Artifact.Size+1))
	if err != nil {
		return err
	}
	if count != release.payload.Artifact.Size {
		return errors.New("artifact size mismatch")
	}
	if !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), release.payload.Artifact.SHA256) {
		return errors.New("artifact hash mismatch")
	}
	return nil
}
