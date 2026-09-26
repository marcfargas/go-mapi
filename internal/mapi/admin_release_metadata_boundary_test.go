package mapi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The machine validation workflow generates plain first-party target metadata
// from the final signed MSI without reviving obsolete admin publication.
func TestMachineValidationWorkflowBindsPlainTargetToSignedMSI(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(repoRoot, ".github", "workflows", "admin-release.yml"))
	if err != nil {
		t.Fatal(err)
	}
	content := strings.ReplaceAll(string(raw), "\r\n", "\n")
	for _, required := range []string{"environment: artifact-signing", "azure/artifact-signing-action@c7ab2a863ab5f9a846ddb8265964877ef296ee82", "go-mapi-machine-signed-input-v1", "go-mapi-machine-validation-provenance-v1", "signedSha256", "Plain target does not bind exact final machine MSI", "go run ./internal/mapi/cmd/machine-targets --spec $specPath --msi $path --out $targetPath"} {
		if !strings.Contains(content, required) {
			t.Errorf("release workflow missing %q", required)
		}
	}
	for _, forbidden := range []string{"ADMIN_RELEASE_TARGETS_PRIVATE_KEY_PEM_B64", "ADMIN_RELEASE_ROOT_JSON", "MACHINE_RELEASE_ROOT_B64", "openssl pkeyutl -sign -rawin", "go-mapi-admin-envelope-v1", "admin-release-root.json"} {
		if strings.Contains(content, forbidden) {
			t.Errorf("obsolete custom metadata trust remains: %q", forbidden)
		}
	}
}
