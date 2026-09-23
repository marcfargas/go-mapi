package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func TestProgramDataPathsAreFixedMachineSurfaces(t *testing.T) {
	root := filepath.Join(t.TempDir(), "ProgramData")
	paths, err := NewProgramDataPaths(root)
	if err != nil {
		t.Fatal(err)
	}
	if paths.Service != filepath.Join(root, "go-mapi", "service") || paths.Updates != filepath.Join(root, "go-mapi", "updates") || paths.Status != filepath.Join(root, "go-mapi", "status") {
		t.Fatalf("paths = %#v", paths)
	}
	if _, err := NewProgramDataPaths("relative"); err == nil {
		t.Fatal("accepted relative ProgramData")
	}
}

func TestProtectedStorageRejectsTraversalAndSymlinks(t *testing.T) {
	storage := mustStorage(t, filepath.Join(t.TempDir(), "protected"), privateStorage)
	for _, components := range [][]string{{"..", "escape"}, {"nested/path"}, {`nested\\path`}, {"file:stream"}, {""}} {
		if _, err := storage.WriteAtomic(context.Background(), components, strings.NewReader("x"), 1, 1, ""); err == nil {
			t.Fatalf("accepted hostile components %#v", components)
		}
	}

	if runtime.GOOS != "windows" {
		outside := t.TempDir()
		if err := os.Symlink(outside, filepath.Join(storage.root, "link")); err != nil {
			t.Fatal(err)
		}
		if _, err := storage.WriteAtomic(context.Background(), []string{"link", "escaped"}, strings.NewReader("x"), 1, 1, ""); err == nil {
			t.Fatal("followed a symlink inside protected storage")
		}
	}
}

func TestProtectedStorageBoundsSyncReplaceAndRehash(t *testing.T) {
	storage := mustStorage(t, filepath.Join(t.TempDir(), "protected"), privateStorage)
	body := []byte("authenticated MSI bytes")
	sum := sha256.Sum256(body)
	digest := hex.EncodeToString(sum[:])

	got, err := storage.WriteAtomic(context.Background(), []string{"system", "42", "artifact.msi"}, bytes.NewReader(body), int64(len(body)), int64(len(body)), digest)
	if err != nil || got != digest {
		t.Fatalf("WriteAtomic() = %q, %v", got, err)
	}
	data, err := storage.Read([]string{"system", "42", "artifact.msi"}, int64(len(body)))
	if err != nil || !bytes.Equal(data, body) {
		t.Fatalf("Read() = %q, %v", data, err)
	}

	replacement := []byte("replacement")
	replacementSum := sha256.Sum256(replacement)
	if _, err := storage.WriteAtomic(context.Background(), []string{"system", "42", "artifact.msi"}, bytes.NewReader(replacement), int64(len(replacement)), int64(len(replacement)), hex.EncodeToString(replacementSum[:])); err != nil {
		t.Fatal(err)
	}
	data, _ = storage.Read([]string{"system", "42", "artifact.msi"}, 100)
	if string(data) != string(replacement) {
		t.Fatalf("atomic replacement = %q", data)
	}

	if _, err := storage.WriteAtomic(context.Background(), []string{"too-large"}, strings.NewReader("12"), 1, -1, ""); err == nil {
		t.Fatal("accepted over-bound write")
	}
	if _, err := storage.WriteAtomic(context.Background(), []string{"wrong-hash"}, strings.NewReader("x"), 1, 1, strings.Repeat("0", 64)); err == nil {
		t.Fatal("accepted wrong hash")
	}
	matches, err := filepath.Glob(filepath.Join(storage.root, "*.tmp"))
	if err != nil || len(matches) != 0 {
		t.Fatalf("temporary files after failure = %v, %v", matches, err)
	}
}

func TestFileStoresRoundTripStrictBoundedState(t *testing.T) {
	storage := mustStorage(t, filepath.Join(t.TempDir(), "service"), privateStorage)
	stateStore, _ := NewFileStateStore(storage)
	replayStore, _ := NewFileReplayStore(storage)
	statusStore, _ := NewFileStatusStore(storage)
	pending := validPending(time.Date(2026, 9, 23, 9, 0, 0, 0, time.UTC))
	if err := stateStore.Save(context.Background(), pending); err != nil {
		t.Fatal(err)
	}
	loaded, err := stateStore.Load(context.Background())
	if err != nil || !reflect.DeepEqual(loaded, &pending) {
		t.Fatalf("pending = %#v, %v", loaded, err)
	}
	replay := update.ReplayState{Namespace: "system", Sequence: 42, Digest: strings.Repeat("a", 64)}
	if err := replayStore.Save(context.Background(), replay); err != nil {
		t.Fatal(err)
	}
	if got, err := replayStore.Load(context.Background(), update.System); err != nil || got != replay {
		t.Fatalf("replay = %#v, %v", got, err)
	}
	status := ServiceStatus{ConsecutiveFailures: 2, NextCheckAt: time.Now().UTC(), LastCode: StatusOffline}
	if err := statusStore.Save(context.Background(), status); err != nil {
		t.Fatal(err)
	}
	if got, err := statusStore.Load(context.Background()); err != nil || !reflect.DeepEqual(got, status) {
		t.Fatalf("status = %#v, %v", got, err)
	}
	if err := statusStore.Save(context.Background(), ServiceStatus{LastCode: `proxy http://user:secret@example.test`}); err == nil {
		t.Fatal("accepted unbounded public detail in internal status code")
	}
}

func TestPublicStatusAllowsOnlyBoundedRedactedCodes(t *testing.T) {
	storage := mustStorage(t, filepath.Join(t.TempDir(), "status"), publicReadStorage)
	store, err := NewPublicStatusStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	status := PublicStatusV1{Schema: PublicStatusSchemaV1, Code: EventOffline, UpdatedAt: time.Now().UTC()}
	if err := store.Save(context.Background(), status); err != nil {
		t.Fatal(err)
	}
	data, err := storage.Read([]string{"status-v1.json"}, maxStatusBytes)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, forbidden := range []string{"http://", "https://", "\\", "password", "proxy", "transactionId"} {
		if strings.Contains(strings.ToLower(text), strings.ToLower(forbidden)) {
			t.Fatalf("public status leaked %q: %s", forbidden, text)
		}
	}
	if err := store.Save(context.Background(), PublicStatusV1{Schema: PublicStatusSchemaV1, Code: EventCode("proxy-auth user:secret"), UpdatedAt: time.Now()}); err == nil {
		t.Fatal("accepted arbitrary public status detail")
	}
}

func TestStorageACLContractSeparatesPrivateAndPublicStatus(t *testing.T) {
	serviceSID := "S-1-5-80-1-2-3-4-5"
	private, err := storageSDDL(serviceSID, privateStorage)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(private, ";;;SY)") || !strings.Contains(private, ";;;BA)") || !strings.Contains(private, ";;;"+serviceSID+")") || strings.Contains(private, ";;;BU)") {
		t.Fatalf("private ACL = %q", private)
	}
	public, err := storageSDDL(serviceSID, publicReadStorage)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(public, "(A;OICI;GRGX;;;BU)") {
		t.Fatalf("public status ACL = %q", public)
	}
	if _, err := storageSDDL("BU);(A;OICI;FA;;;WD", privateStorage); err == nil {
		t.Fatal("accepted injected service SID")
	}
}

func TestProtectedStorageDetectsReplacementAfterAtomicMove(t *testing.T) {
	root := filepath.Join(t.TempDir(), "protected")
	platform := &substitutingPlatform{storagePlatform: newStoragePlatform()}
	storage, err := newProtectedStorage(root, privateStorage, platform)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := storage.WriteAtomic(context.Background(), []string{"state.json"}, strings.NewReader("trusted"), 7, 7, ""); err == nil || !strings.Contains(err.Error(), "changed after atomic replacement") {
		t.Fatalf("substitution error = %v", err)
	}
}

type substitutingPlatform struct{ storagePlatform }

func (platform *substitutingPlatform) replace(source, destination string) error {
	if err := platform.storagePlatform.replace(source, destination); err != nil {
		return err
	}
	return os.WriteFile(destination, []byte("hostile"), 0600)
}

func TestProtectedArtifactStoreStreamsToFixedReleasePath(t *testing.T) {
	release := authorizedRelease(t, update.System, "4.0.1")
	payload := release.Payload()
	body := []byte("verified installer")
	storage := mustStorage(t, filepath.Join(t.TempDir(), "updates"), privateStorage)
	store, err := NewProtectedArtifactStore(storage, func(_ context.Context, got update.Release, destination io.Writer) error {
		if got.Digest() != release.Digest() {
			return errors.New("wrong release")
		}
		_, err := destination.Write(body)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	artifact, err := store.Stage(context.Background(), release)
	if err != nil {
		t.Fatal(err)
	}
	wantHandle := "system/" + fmt.Sprint(release.Sequence()) + "/go-mapi-system-4.0.1-x64.msi"
	if artifact.Handle != wantHandle || artifact.SHA256 != payload.Artifact.SHA256 {
		t.Fatalf("artifact = %#v, want handle %q", artifact, wantHandle)
	}
	data, err := storage.Read(strings.Split(wantHandle, "/"), payload.Artifact.Size)
	if err != nil || !bytes.Equal(data, body) {
		t.Fatalf("staged bytes = %q, %v", data, err)
	}
}

func mustStorage(t *testing.T, root string, access storageAccess) *ProtectedStorage {
	t.Helper()
	storage, err := newProtectedStorage(root, access, newStoragePlatform())
	if err != nil {
		t.Fatal(err)
	}
	return storage
}
