package mapi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// This is a source-contract guard. The authoritative runtime proof is the
// managed Windows command; this test ensures later edits cannot silently turn
// that proof into a combined-installer, MAPISendDocuments, or fixture-only job.
func TestComponentIntegrationGateContract(t *testing.T) {
	repoRoot := filepath.Clean(filepath.Join("..", ".."))
	script, err := os.ReadFile(filepath.Join(repoRoot, "scripts", "run-component-integration.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	content := string(script)
	for _, want := range []string{
		"[string]$X64Dll", "[string]$X86Dll", "[string]$X64Harness", "[string]$X86Harness",
		"[string]$InterceptorVersion", "[string]$AppVersion", "[string]$EvidenceDirectory",
		"Get-FileHash", "Get-PeMachine", "GO_MAPI_TEST_RETAIN_OUTPUT", "TestIntegrationQueueConsumerProbe",
		"component-integration.json", "component-integration.log", "no product registration",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("integration runner missing %q", want)
		}
	}
	for _, forbidden := range []string{"MAPISendDocuments", "makensis", "build-phase", "installer-release", "reg add", "New-AzVM"} {
		if strings.Contains(content, forbidden) {
			t.Errorf("integration runner crosses excluded boundary %q", forbidden)
		}
	}
	workflow, err := os.ReadFile(filepath.Join(repoRoot, ".github", "workflows", "component-integration.yml"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"workflow_dispatch:", "interceptor_version:", "app_version:", "actions/upload-artifact@v4", "authoritativeRuntimeProof = $false", "run-component-integration.ps1"} {
		if !strings.Contains(string(workflow), want) {
			t.Errorf("integration workflow missing %q", want)
		}
	}
}
