package mapi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The release workflow is part of the authorization boundary: an unsigned
// metadata object must not be publishable merely because an MSI is signed.
func TestAdminReleaseWorkflowRequiresProtectedSignedMetadata(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	workflow, err := os.ReadFile(filepath.Join(repoRoot, ".github", "workflows", "admin-release.yml"))
	if err != nil {
		t.Fatal(err)
	}
	content := string(workflow)
	for _, required := range []string{
		"environment: admin-release",
		"ADMIN_RELEASE_TARGETS_PRIVATE_KEY_PEM_B64",
		"Require protected admin metadata signing inputs",
		"go-mapi-admin-root-v1",
		"go-mapi-admin-targets-v1",
		"go-mapi-admin-envelope-v1",
		"openssl pkeyutl -sign -rawin",
		"does not match the trusted root target key",
		"admin-targets.json",
		"admin-release-root.json",
		"maxExclusive = $requires.maxExclusive",
		"interceptor compatibility requires an explicit maxExclusive app version",
		"code-signing and a distinct subscriber-identity EKU",
	} {
		if !strings.Contains(content, required) {
			t.Errorf("admin metadata release guard missing %q", required)
		}
	}
	for _, forbidden := range []string{
		"BEGIN PRIVATE KEY",
		"PRIVATE KEY-----",
		"ADMIN_RELEASE_TARGETS_PRIVATE_KEY_PEM_B64: test",
	} {
		if strings.Contains(content, forbidden) {
			t.Errorf("workflow must not embed a metadata private key: found %q", forbidden)
		}
	}
}
