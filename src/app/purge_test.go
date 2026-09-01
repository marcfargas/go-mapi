package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/zalando/go-keyring"
)

type purgeKeyring struct {
	deleted bool
	err     error
}

func (p *purgeKeyring) Get(string, string) (string, error) { return "", keyring.ErrNotFound }
func (p *purgeKeyring) Set(string, string, string) error   { return nil }
func (p *purgeKeyring) Delete(service, user string) error {
	p.deleted = service == keyringService && user == keyringUser
	return p.err
}

func TestPurgeUserDataRemovesCanonicalStateAndCredential(t *testing.T) {
	appData := filepath.Join(t.TempDir(), "app")
	queue := filepath.Join(t.TempDir(), "queue")
	t.Setenv("GOMAPI_APPDATA_DIR", appData)
	t.Setenv("GOMAPI_WATCH_DIR", queue)
	for _, path := range []string{filepath.Join(appData, "settings.json"), filepath.Join(queue, "queued.json")} {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("test"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	store := &purgeKeyring{}
	if err := purgeUserDataWithStore(store); err != nil {
		t.Fatal(err)
	}
	if !store.deleted {
		t.Error("credential was not deleted")
	}
	for _, path := range []string{appData, queue} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("%s still exists: %v", path, err)
		}
	}
}

func TestPurgeUserDataTreatsMissingCredentialAsSuccess(t *testing.T) {
	t.Setenv("GOMAPI_APPDATA_DIR", filepath.Join(t.TempDir(), "app"))
	t.Setenv("GOMAPI_WATCH_DIR", filepath.Join(t.TempDir(), "queue"))
	store := &purgeKeyring{err: keyring.ErrNotFound}
	if err := purgeUserDataWithStore(store); err != nil {
		t.Fatal(err)
	}
}

func TestPurgeUserDataReportsCredentialFailure(t *testing.T) {
	t.Setenv("GOMAPI_APPDATA_DIR", filepath.Join(t.TempDir(), "app"))
	t.Setenv("GOMAPI_WATCH_DIR", filepath.Join(t.TempDir(), "queue"))
	want := errors.New("credential manager unavailable")
	err := purgeUserDataWithStore(&purgeKeyring{err: want})
	if !errors.Is(err, want) {
		t.Fatalf("purge error = %v, want wrapped %v", err, want)
	}
}
