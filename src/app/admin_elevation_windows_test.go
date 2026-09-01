//go:build windows

package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func TestSecureAdminStageTreeAppliesProtectedSystemAdministratorsDACL(t *testing.T) {
	root := t.TempDir()
	// Windows can briefly retain a handle after security-descriptor queries.
	// Remove the protected test tree first (before TempDir's own cleanup) with
	// a bounded retry so a successful access-control assertion is not hidden by
	// that transient filesystem behavior.
	t.Cleanup(func() {
		var err error
		for attempt := 0; attempt != 20; attempt++ {
			err = os.RemoveAll(root)
			if err == nil {
				return
			}
			time.Sleep(50 * time.Millisecond)
		}
		t.Errorf("remove protected admin staging test tree: %v", err)
	})
	stage, err := secureAdminStageTree(root, "go-mapi", "admin-installer", "4.0.0-test")
	if err != nil {
		t.Fatalf("secureAdminStageTree: %v", err)
	}

	for _, protected := range []string{
		filepath.Join(root, "go-mapi"),
		filepath.Join(root, "go-mapi", "admin-installer"),
		stage,
	} {
		assertAdminStageDirectoryProtected(t, protected)
	}

	// A standard (non-Administrators) token has no matching allow ACE above, so
	// Windows must deny its write attempt. This process may itself be elevated;
	// in that case the DACL assertion above remains the deterministic evidence
	// and an actual write is legitimately allowed through the BA ACE.
	probe := filepath.Join(stage, "standard-user-write-probe")
	err = os.WriteFile(probe, []byte("must not be writable by standard users"), 0o600)
	if err == nil {
		_ = os.Remove(probe)
		return
	}
	if !errors.Is(err, windows.ERROR_ACCESS_DENIED) {
		t.Fatalf("normal-token stage write error = %v, want access denied", err)
	}
}

func assertAdminStageDirectoryProtected(t *testing.T, path string) {
	t.Helper()
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		// A standard user loses READ_CONTROL as soon as the final protected
		// DACL is applied. Confirm that it also cannot add a candidate file.
		if !errors.Is(err, windows.ERROR_ACCESS_DENIED) {
			t.Fatalf("GetNamedSecurityInfo(%q): %v", path, err)
		}
		return
	}
	owner, _, err := sd.Owner()
	if err != nil {
		t.Fatalf("Owner(%q): %v", path, err)
	}
	if got := owner.String(); got != "S-1-5-18" {
		t.Fatalf("owner(%q) = %s, want SYSTEM (S-1-5-18)", path, got)
	}
	sddl := strings.ToUpper(sd.String())
	if !strings.Contains(sddl, "D:PAI") || !strings.Contains(sddl, ";;;SY)") || !strings.Contains(sddl, ";;;BA)") {
		t.Fatalf("staging DACL(%q) = %q, want protected SYSTEM and Administrators-only ACL", path, sddl)
	}
	for _, forbidden := range []string{";;;BU)", ";;;WD)", ";;;AU)"} {
		if strings.Contains(sddl, forbidden) {
			t.Fatalf("staging DACL unexpectedly grants a standard-user principal: %q", sddl)
		}
	}
}
