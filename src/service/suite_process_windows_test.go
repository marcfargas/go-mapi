//go:build windows

package service

import (
	"errors"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

func TestSuiteImageQueryFailureClassification(t *testing.T) {
	const handle windows.Handle = 123
	const pid uint32 = 456
	queryErr := windows.ERROR_GEN_FAILURE
	for _, tc := range []struct {
		name  string
		state uint32
		err   error
		allow bool
	}{
		{"confirmed exit", windows.WAIT_OBJECT_0, nil, true},
		{"still live", uint32(windows.WAIT_TIMEOUT), nil, false},
		{"wait error", windows.WAIT_FAILED, windows.ERROR_INVALID_HANDLE, false},
		{"signalled with error", windows.WAIT_OBJECT_0, windows.ERROR_ACCESS_DENIED, false},
		{"failed without error", windows.WAIT_FAILED, nil, false},
		{"abandoned", windows.WAIT_ABANDONED, nil, false},
		{"unexpected status", 42, nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			err := suiteImageQueryFailure(handle, pid, queryErr, func(got windows.Handle, timeout uint32) (uint32, error) {
				calls++
				if got != handle || timeout != 0 {
					t.Fatalf("wait handle=%d timeout=%d; want same handle %d and zero timeout", got, timeout, handle)
				}
				return tc.state, tc.err
			})
			if calls != 1 {
				t.Fatalf("wait calls=%d; want 1", calls)
			}
			if tc.allow {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			if !errors.Is(err, queryErr) || !strings.Contains(err.Error(), "456") {
				t.Fatalf("failure lost original query error or PID: %v", err)
			}
			if tc.err != nil && !errors.Is(err, tc.err) {
				t.Fatalf("failure lost wait error: %v", err)
			}
		})
	}
}

// Reproduce the native snapshot/open/query race without relying on scheduling:
// keep a child blocked on stdin, snapshot it, then let it exit before enumeration.
func TestSuiteImageQueryExitedSnapshotChild(t *testing.T) {
	systemDir, err := windows.GetSystemDirectory()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(filepath.Join(systemDir, "cmd.exe"), "/d", "/q")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer stdin.Close()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		if err := cmd.Wait(); err != nil {
			t.Errorf("child cleanup: %v", err)
		}
	})
	pid := uint32(cmd.Process.Pid)
	const rights = windows.PROCESS_QUERY_LIMITED_INFORMATION | windows.SYNCHRONIZE | windows.PROCESS_TERMINATE
	held, err := windows.OpenProcess(rights, false, pid)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(held)

	var image [32768]uint16
	imageLen := uint32(len(image))
	if err := windows.QueryFullProcessImageName(held, 0, &image[0], &imageLen); err != nil {
		t.Fatalf("live image query: %v", err)
	}
	if !equalWindowsPath(windows.UTF16ToString(image[:imageLen]), filepath.Join(systemDir, "cmd.exe")) {
		t.Fatalf("unexpected child image: %s", windows.UTF16ToString(image[:imageLen]))
	}
	if state, err := windows.WaitForSingleObject(held, 0); err != nil || state != uint32(windows.WAIT_TIMEOUT) {
		t.Fatalf("child must still be live: state=%#x err=%v", state, err)
	}
	// Even a generic image-query failure must remain fatal for this live handle.
	if err := suiteImageQueryFailure(held, pid, windows.ERROR_GEN_FAILURE, windows.WaitForSingleObject); !errors.Is(err, windows.ERROR_GEN_FAILURE) {
		t.Fatalf("live query failure was excused: %v", err)
	}
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(snapshot)
	if err := stdin.Close(); err != nil {
		t.Fatal(err)
	}
	if state, err := windows.WaitForSingleObject(held, 5000); err != nil || state != windows.WAIT_OBJECT_0 {
		t.Fatalf("child did not exit: state=%#x err=%v", state, err)
	}

	entry := windows.ProcessEntry32{Size: uint32(unsafe.Sizeof(windows.ProcessEntry32{}))}
	for err = windows.Process32First(snapshot, &entry); err == nil; err = windows.Process32Next(snapshot, &entry) {
		if entry.ProcessID == pid {
			break
		}
	}
	if err != nil {
		t.Fatalf("pre-exit snapshot lost child %d: %v", pid, err)
	}
	// Match the sweep: acquire a fresh handle with its exact access rights after exit.
	fresh, err := windows.OpenProcess(rights, false, entry.ProcessID)
	if err != nil {
		t.Fatalf("open exited snapshot child: %v", err)
	}
	defer windows.CloseHandle(fresh)
	imageLen = uint32(len(image))
	queryErr := windows.QueryFullProcessImageName(fresh, 0, &image[0], &imageLen)
	if !errors.Is(queryErr, windows.ERROR_GEN_FAILURE) {
		t.Fatalf("exited image query=%v; want native ERROR_GEN_FAILURE (31)", queryErr)
	}
	if err := suiteImageQueryFailure(fresh, pid, queryErr, windows.WaitForSingleObject); err != nil {
		t.Fatalf("confirmed exited candidate must not abort sweep: %v", err)
	}
	// Classification must leave the exact handle open for the caller to close.
	if state, err := windows.WaitForSingleObject(fresh, 0); err != nil || state != windows.WAIT_OBJECT_0 {
		t.Fatalf("classification consumed handle: state=%#x err=%v", state, err)
	}
}
