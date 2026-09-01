//go:build windows

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type fakeHandoffPlatform struct {
	current     installChannel
	installed   map[installChannel]bool
	removeErr   error
	verifyErr   error
	removeCalls int
	verifyCalls int
}

func (f *fakeHandoffPlatform) CurrentChannel() (installChannel, error) { return f.current, nil }
func (f *fakeHandoffPlatform) IsInstalled(_ context.Context, c installChannel) (bool, error) {
	return f.installed[c], nil
}
func (f *fakeHandoffPlatform) RemoveSource(_ context.Context, source installChannel) error {
	f.removeCalls++
	if f.removeErr == nil {
		f.installed[source] = false
	}
	return f.removeErr
}
func (f *fakeHandoffPlatform) VerifyTargetOnly(_ context.Context, target installChannel) error {
	f.verifyCalls++
	if f.verifyErr != nil {
		return f.verifyErr
	}
	if !f.installed[target] {
		return errors.New("target missing")
	}
	return nil
}
func (f *fakeHandoffPlatform) Activate(context.Context, installChannel) error { return nil }

func handoffTestEnv(t *testing.T) {
	t.Helper()
	t.Setenv("GOMAPI_APPDATA_DIR", t.TempDir())
}

func TestHandoffResumeCompletesAndDeletesJournal(t *testing.T) {
	handoffTestEnv(t)
	platform := &fakeHandoffPlatform{current: channelStore, installed: map[installChannel]bool{channelStandalone: true, channelStore: true}}
	coordinator := &handoffCoordinator{platform: platform}
	first, err := coordinator.Begin(channelStandalone, channelStore)
	if err != nil {
		t.Fatal(err)
	}
	second, err := coordinator.Begin(channelStandalone, channelStore)
	if err != nil || first.Token != second.Token {
		t.Fatalf("begin is not idempotent: %+v %+v %v", first, second, err)
	}
	if err := coordinator.Resume(context.Background()); err != nil {
		t.Fatal(err)
	}
	if platform.removeCalls != 1 || platform.verifyCalls != 1 {
		t.Fatalf("calls remove=%d verify=%d", platform.removeCalls, platform.verifyCalls)
	}
	if _, err := os.Stat(handoffJournalPath()); !os.IsNotExist(err) {
		t.Fatalf("journal remains: %v", err)
	}
}

func TestHandoffRetryDoesNotRepeatCompletedRemoval(t *testing.T) {
	handoffTestEnv(t)
	want := errors.New("verification interrupted")
	platform := &fakeHandoffPlatform{current: channelStore, installed: map[installChannel]bool{channelStandalone: true, channelStore: true}, verifyErr: want}
	coordinator := &handoffCoordinator{platform: platform}
	if _, err := coordinator.Begin(channelStandalone, channelStore); err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Resume(context.Background()); !errors.Is(err, want) {
		t.Fatalf("resume error = %v", err)
	}
	journal, err := loadHandoffJournal()
	if err != nil || journal.Phase != handoffSourceRemoved {
		t.Fatalf("journal = %+v, %v", journal, err)
	}
	platform.verifyErr = nil
	if err := coordinator.Resume(context.Background()); err != nil {
		t.Fatal(err)
	}
	if platform.removeCalls != 1 || platform.verifyCalls != 2 {
		t.Fatalf("calls remove=%d verify=%d", platform.removeCalls, platform.verifyCalls)
	}
}

func TestHandoffRemovalFailureStaysRequestedAndRetries(t *testing.T) {
	handoffTestEnv(t)
	want := errors.New("uninstaller busy")
	platform := &fakeHandoffPlatform{current: channelStore, installed: map[installChannel]bool{channelStandalone: true, channelStore: true}, removeErr: want}
	coordinator := &handoffCoordinator{platform: platform}
	if _, err := coordinator.Begin(channelStandalone, channelStore); err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Resume(context.Background()); !errors.Is(err, want) {
		t.Fatalf("resume error = %v", err)
	}
	journal, _ := loadHandoffJournal()
	if journal.Phase != handoffRequested {
		t.Fatalf("phase = %s", journal.Phase)
	}
	platform.removeErr = nil
	if err := coordinator.Resume(context.Background()); err != nil {
		t.Fatal(err)
	}
	if platform.removeCalls != 2 {
		t.Fatalf("remove calls = %d", platform.removeCalls)
	}
}

func TestHandoffWrongChannelFailsClosed(t *testing.T) {
	handoffTestEnv(t)
	platform := &fakeHandoffPlatform{current: channelStandalone, installed: map[installChannel]bool{channelStandalone: true, channelStore: true}}
	coordinator := &handoffCoordinator{platform: platform}
	if _, err := coordinator.Begin(channelStandalone, channelStore); err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Resume(context.Background()); err == nil {
		t.Fatal("expected target mismatch")
	}
}

func TestStandaloneUninstallerMustStayInsidePerUserInstallRoot(t *testing.T) {
	local := t.TempDir()
	t.Setenv("LOCALAPPDATA", local)
	good := filepath.Join(local, "Programs", "go-mapi", "uninstall.exe")
	if err := validateStandaloneUninstaller(good); err != nil {
		t.Fatalf("valid uninstaller: %v", err)
	}
	for _, bad := range []string{filepath.Join(local, "Programs", "other", "uninstall.exe"), filepath.Join(local, "Programs", "go-mapi", "go-mapi.exe")} {
		if err := validateStandaloneUninstaller(bad); err == nil {
			t.Errorf("accepted unsafe uninstaller %q", bad)
		}
	}
}

func TestPowerShellBooleanOutputAcceptsCLIXMLProgress(t *testing.T) {
	output := []byte("true\r\n#< CLIXML\r\n<Objs><Obj S=\"progress\" /></Objs>")
	if !powershellBooleanOutput(output) {
		t.Fatal("expected true token to survive CLIXML progress output")
	}
	if powershellBooleanOutput([]byte("false\r\n#< CLIXML")) {
		t.Fatal("false output must remain false")
	}
}
