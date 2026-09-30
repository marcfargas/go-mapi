//go:build windows

package mapi

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

// createJunction creates a directory junction (reparse tag
// IO_REPARSE_TAG_MOUNT_POINT, the same tag as a volume mounted in a folder).
// Creating a junction needs no privilege.
func createJunction(t *testing.T, link, target string) {
	t.Helper()
	out, err := exec.Command("cmd", "/c", "mklink", "/J", link, target).CombinedOutput()
	if err != nil {
		t.Fatalf("mklink /J %s %s: %v: %s", link, target, err, out)
	}
	t.Cleanup(func() { _ = os.Remove(link) })
}

// requireMountPointTag fails unless path is a mount-point reparse point, so a
// test cannot pass on a plain folder by accident.
func requireMountPointTag(t *testing.T, path string) {
	t.Helper()
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		t.Fatal(err)
	}
	var data windows.Win32finddata
	handle, err := windows.FindFirstFile(name, &data)
	if err != nil {
		t.Fatalf("FindFirstFile(%s): %v", path, err)
	}
	windows.FindClose(handle)
	if data.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT == 0 || data.Reserved0 != windows.IO_REPARSE_TAG_MOUNT_POINT {
		t.Fatalf("%s is not a mount-point reparse point (attributes %#x, tag %#x)", path, data.FileAttributes, data.Reserved0)
	}
}

// The user profile folder is a junction, as on the reported host where
// C:\Users\<user> is a mount point. Before the fix EvalSymlinks failed with
// "The system cannot find the path specified" and the mail went to errors.
func TestEmailWatcher_AcceptsAttachmentBelowJunctionProfile(t *testing.T) {
	tmpDir := t.TempDir()
	realProfile := filepath.Join(tmpDir, "profile-disk")
	if err := os.MkdirAll(realProfile, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	profile := filepath.Join(tmpDir, "profile")
	createJunction(t, profile, realProfile)
	requireMountPointTag(t, profile)

	watchDir := filepath.Join(profile, "AppData", "Local", "go-mapi", "queue")
	if err := os.MkdirAll(watchDir, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	accepted, err := attachmentOutcome(t, watchDir,
		stageAttachment(t, watchDir, "report.pdf"), stageAttachment(t, watchDir, "notes.txt"))
	if !accepted {
		t.Fatalf("attachment below a junction profile was rejected: %v", err)
	}
}

func TestEmailWatcher_RejectsAttachmentThroughEscapingJunction(t *testing.T) {
	tmpDir := t.TempDir()
	realProfile := filepath.Join(tmpDir, "profile-disk")
	outside := filepath.Join(tmpDir, "outside")
	for _, dir := range []string{realProfile, outside} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			t.Fatalf("MkdirAll: %v", err)
		}
	}
	writeFile(t, filepath.Join(outside, "secret.txt"), []byte("secret"))
	profile := filepath.Join(tmpDir, "profile")
	createJunction(t, profile, realProfile)
	watchDir := filepath.Join(profile, "AppData", "Local", "go-mapi", "queue")
	stageAttachment(t, watchDir, "inside.txt")
	escape := filepath.Join(watchDir, "message", "escape")
	createJunction(t, escape, outside)

	accepted, err := attachmentOutcome(t, watchDir, filepath.Join(escape, "secret.txt"))
	if accepted || err == nil {
		t.Fatal("junction escaping the attachment folder was accepted")
	}
	if !strings.Contains(err.Error(), "is outside") {
		t.Fatalf("junction escape was rejected for the wrong reason: %v", err)
	}
}

func TestResolveFinalPathFollowsJunction(t *testing.T) {
	tmpDir := t.TempDir()
	target := filepath.Join(tmpDir, "target")
	if err := os.MkdirAll(target, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	writeFile(t, filepath.Join(target, "f.txt"), []byte("f"))
	link := filepath.Join(tmpDir, "link")
	createJunction(t, link, target)

	viaLink, err := resolveFinalPath(filepath.Join(link, "f.txt"))
	if err != nil {
		t.Fatalf("resolveFinalPath through junction: %v", err)
	}
	direct, err := resolveFinalPath(filepath.Join(target, "f.txt"))
	if err != nil {
		t.Fatalf("resolveFinalPath direct: %v", err)
	}
	if viaLink != direct {
		t.Fatalf("junction path resolved to %q, direct path to %q", viaLink, direct)
	}
}

// vhdMountEnv enables the test that mounts a real VHD volume in a folder. It
// needs an elevated token and changes disk configuration while it runs, so it
// runs only on disposable machines that set the variable. When the variable is
// set, every setup failure is a test failure.
const vhdMountEnv = "GO_MAPI_TEST_VHD_MOUNT"

func runDiskpart(t *testing.T, dir, script string) {
	t.Helper()
	scriptPath := filepath.Join(dir, fmt.Sprintf("diskpart-%d.txt", len(script)))
	writeFile(t, scriptPath, []byte(script))
	out, err := exec.Command("diskpart", "/s", scriptPath).CombinedOutput()
	if err != nil {
		t.Fatalf("diskpart %q: %v: %s", script, err, out)
	}
}

// The user profile folder is a real NTFS volume mounted in a folder, as with
// user profile disks on a Remote Desktop Session Host.
func TestEmailWatcher_AcceptsAttachmentBelowVolumeMountPointProfile(t *testing.T) {
	if os.Getenv(vhdMountEnv) != "1" {
		t.Skipf("set %s=1 on a disposable elevated machine to mount a real VHD volume", vhdMountEnv)
	}
	tmpDir := t.TempDir()
	vhd := filepath.Join(tmpDir, "profile.vhdx")
	profile := filepath.Join(tmpDir, "profile")
	if err := os.MkdirAll(profile, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	runDiskpart(t, tmpDir, fmt.Sprintf("create vdisk file=\"%s\" maximum=64 type=expandable\nselect vdisk file=\"%s\"\nattach vdisk\ncreate partition primary\nformat fs=ntfs quick label=gmprofile\nassign mount=\"%s\"\n", vhd, vhd, profile))
	t.Cleanup(func() {
		script := filepath.Join(os.TempDir(), "gm-detach-vhd.txt")
		_ = os.WriteFile(script, []byte(fmt.Sprintf("select vdisk file=\"%s\"\ndetach vdisk\n", vhd)), 0644)
		_ = exec.Command("diskpart", "/s", script).Run()
		_ = os.Remove(script)
	})
	requireMountPointTag(t, profile)

	watchDir := filepath.Join(profile, "AppData", "Local", "go-mapi", "queue")
	if err := os.MkdirAll(watchDir, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	accepted, err := attachmentOutcome(t, watchDir, stageAttachment(t, watchDir, "report.pdf"))
	if !accepted {
		t.Fatalf("attachment below a volume mount-point profile was rejected: %v", err)
	}

	// The boundary still holds on the mounted volume: a junction from the
	// attachment folder to the system volume is rejected.
	outside := filepath.Join(tmpDir, "outside")
	if err := os.MkdirAll(outside, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	writeFile(t, filepath.Join(outside, "secret.txt"), []byte("secret"))
	escape := filepath.Join(watchDir, "message", "escape")
	createJunction(t, escape, outside)
	accepted, err = attachmentOutcome(t, watchDir, filepath.Join(escape, "secret.txt"))
	if accepted || err == nil {
		t.Fatal("junction escaping the attachment folder on a mounted volume was accepted")
	}
}
