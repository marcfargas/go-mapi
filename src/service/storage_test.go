package service

import (
	"bytes"
	"context"
	"crypto/rand"
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

	"github.com/marcfargas/go-mapi/internal/mapi"
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
	storage := mustStorage(t, testStorageRoot(t, "protected"), privateStorage)
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

func TestFinalUninstallFenceSerializesWithNewPreparation(t *testing.T) {
	storage := mustStorage(t, testStorageRoot(t, "protected"), privateStorage)
	state, err := NewFileStateStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	if err := state.BeginFinalUninstall(context.Background()); err != nil {
		t.Fatal(err)
	}
	pending := pendingForReconcile(t, nil)
	if err := state.CompareAndSave(context.Background(), nil, pending); !errors.Is(err, ErrFinalUninstallFenced) {
		t.Fatalf("prepare during final uninstall = %v", err)
	}
	if err := state.RollbackFinalUninstall(); err != nil {
		t.Fatal(err)
	}
	if err := state.CompareAndSave(context.Background(), nil, pending); err != nil {
		t.Fatalf("prepare after rollback = %v", err)
	}
	if err := state.BeginFinalUninstall(context.Background()); err == nil {
		t.Fatal("final uninstall accepted active pending transaction")
	}
}

func TestProtectedStorageBoundsSyncReplaceAndRehash(t *testing.T) {
	storage := mustStorage(t, testStorageRoot(t, "protected"), privateStorage)
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
	storage := mustStorage(t, testStorageRoot(t, "service"), privateStorage)
	stateStore, _ := NewFileStateStore(storage)
	replayStore, _ := NewFileReplayStore(storage)
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

}

func TestFileTerminalStoresRejectReplayRollbackAndKeepLastResult(t *testing.T) {
	storage := mustStorage(t, testStorageRoot(t, "service"), privateStorage)
	replay, _ := NewFileReplayStore(storage)
	last, _ := NewFileLastResultStore(storage)
	ctx := context.Background()
	state := update.ReplayState{Namespace: "system", Sequence: 42, Digest: strings.Repeat("a", 64)}
	if err := replay.Save(ctx, state); err != nil {
		t.Fatal(err)
	}
	if err := replay.Save(ctx, state); err != nil {
		t.Fatal(err)
	}
	older := state
	older.Sequence--
	if err := replay.Save(ctx, older); !errors.Is(err, ErrStateConflict) {
		t.Fatalf("replay rollback = %v", err)
	}
	result := LastResultV1{Schema: LastResultSchemaV1, TransactionID: "tx-42", SKU: update.System,
		Result: ResultInstalled, Sequence: state.Sequence, Digest: state.Digest, FinishedAt: time.Now().UTC()}
	if err := last.Save(ctx, result); err != nil {
		t.Fatal(err)
	}
	if err := last.Save(ctx, result); err != nil {
		t.Fatal(err)
	}
	if got, err := last.Load(ctx); err != nil || !reflect.DeepEqual(got, &result) {
		t.Fatalf("last result = %#v, %v", got, err)
	}
	changed := result
	changed.Result = ResultRolledBack
	if err := last.Save(ctx, changed); !errors.Is(err, ErrStateConflict) {
		t.Fatalf("changed same transaction result = %v", err)
	}
}

func TestFileStateStoreRejectsStaleAuthorizationWrites(t *testing.T) {
	storage := mustStorage(t, testStorageRoot(t, "service"), privateStorage)
	store, err := NewFileStateStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	prepared := validPending(time.Now().UTC())
	prepared.Schema = PendingSchemaV2
	if err := store.CompareAndSave(context.Background(), nil, prepared); err != nil {
		t.Fatal(err)
	}
	if err := store.CompareAndSave(context.Background(), nil, prepared); !errors.Is(err, ErrStateConflict) {
		t.Fatalf("second prepare = %v, want state conflict", err)
	}
	stale := prepared
	current := prepared
	current.Runner = &ProcessIdentity{PID: 101, CreatedAtUnixNano: 202}
	if err := store.CompareAndSave(context.Background(), &prepared, current); err != nil {
		t.Fatal(err)
	}
	stale.UpdatedAt = stale.UpdatedAt.Add(time.Second)
	if err := store.CompareAndSave(context.Background(), &prepared, stale); !errors.Is(err, ErrStateConflict) {
		t.Fatalf("stale runner overwrite = %v, want state conflict", err)
	}
	if err := store.CompareAndClear(context.Background(), prepared); !errors.Is(err, ErrStateConflict) {
		t.Fatalf("stale retry clear = %v, want state conflict", err)
	}
	got, err := store.Load(context.Background())
	if err != nil || !reflect.DeepEqual(got, &current) {
		t.Fatalf("durable runner identity = %#v, %v", got, err)
	}
	if err := store.CompareAndClear(context.Background(), current); err != nil {
		t.Fatal(err)
	}
	if got, err := store.Load(context.Background()); err != nil || got != nil {
		t.Fatalf("retired pending = %#v, %v", got, err)
	}
}

func TestRunnerReadyStorePublishesStrictDurableIdentity(t *testing.T) {
	storage := mustStorage(t, testStorageRoot(t, "service"), privateStorage)
	store, err := NewFileRunnerReadyStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	ready := RunnerReadyV1{Schema: RunnerReadySchemaV1, TransactionID: "tx-42", Attempt: 1, Runner: ProcessIdentity{PID: 11, CreatedAtUnixNano: 101}, Installer: ProcessIdentity{PID: 12, CreatedAtUnixNano: 102}, ReadyAt: time.Now().UTC()}
	if err := store.Publish(context.Background(), ready); err != nil {
		t.Fatal(err)
	}
	loaded, err := store.Load(context.Background(), ready.TransactionID, ready.Attempt)
	if err != nil || !reflect.DeepEqual(loaded, &ready) {
		t.Fatalf("ready = %#v, %v", loaded, err)
	}
	if stale, err := store.Load(context.Background(), ready.TransactionID, 2); err != nil || stale != nil {
		t.Fatalf("previous attempt leaked into attempt two: %#v, %v", stale, err)
	}
	if _, err := store.Load(context.Background(), `..\\outside`, 1); err == nil {
		t.Fatal("accepted unsafe ready transaction")
	}
}

func TestPublicStatusAllowsOnlyBoundedRedactedCodes(t *testing.T) {
	storage := mustStorage(t, testStorageRoot(t, "status"), publicReadStorage)
	store, err := NewPublicStatusStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	status := mapi.PublicStatusV2{Schema: mapi.PublicStatusSchemaV2, SKU: "system", Updates: "unknown", Code: "offline", Capability: "unavailable", Checker: "unavailable", UpdatedAt: time.Now().UTC()}
	if err := store.Save(context.Background(), status); err != nil {
		t.Fatal(err)
	}
	data, err := storage.Read([]string{"status-v2.json"}, maxStatusBytes)
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := mapi.DecodePublicStatusV2(data)
	if err != nil || loaded != status {
		t.Fatalf("public status = %#v, %v", loaded, err)
	}
	text := string(data)
	for _, forbidden := range []string{"http://", "https://", "\\", "password", "proxy", "transactionId"} {
		if strings.Contains(strings.ToLower(text), strings.ToLower(forbidden)) {
			t.Fatalf("public status leaked %q: %s", forbidden, text)
		}
	}
	if err := store.Save(context.Background(), mapi.PublicStatusV2{Schema: mapi.PublicStatusSchemaV2, SKU: "system", Updates: "unknown", Code: "proxy-auth user:secret", Capability: "unavailable", Checker: "unavailable", UpdatedAt: time.Now()}); err == nil {
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
	root := testStorageRoot(t, "protected")
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
	storage := mustStorage(t, testStorageRoot(t, "updates"), privateStorage)
	store, err := NewProtectedArtifactStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	artifact, err := store.StageWith(context.Background(), release, func(destination io.Writer) error { _, err := destination.Write(body); return err })
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

func TestProtectedArtifactStoreRejectsBadDownloadWithoutReplacingArtifact(t *testing.T) {
	release := authorizedRelease(t, update.System, "4.0.1")
	good := []byte("verified installer")
	for _, test := range []struct {
		name     string
		download func(io.Writer) error
		wantErr  error
	}{
		{"short", func(destination io.Writer) error {
			_, err := destination.Write(good[:len(good)-1])
			return err
		}, nil},
		{"overlong", func(destination io.Writer) error {
			_, err := destination.Write(append(append([]byte(nil), good...), '!'))
			return err
		}, nil},
		{"wrong hash", func(destination io.Writer) error {
			_, err := destination.Write(bytes.Repeat([]byte("x"), len(good)))
			return err
		}, nil},
		{"download error", func(destination io.Writer) error {
			_, _ = destination.Write(good)
			return io.ErrUnexpectedEOF
		}, io.ErrUnexpectedEOF},
		{"ignored overlong write", func(destination io.Writer) error {
			_, _ = destination.Write(good)
			_, _ = destination.Write([]byte("extra"))
			return nil
		}, nil},
	} {
		t.Run(test.name, func(t *testing.T) {
			storage := mustStorage(t, testStorageRoot(t, "updates"), privateStorage)
			initial, err := NewProtectedArtifactStore(storage)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := initial.StageWith(context.Background(), release, func(destination io.Writer) error { _, err := destination.Write(good); return err }); err != nil {
				t.Fatal(err)
			}
			store, err := NewProtectedArtifactStore(storage)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := store.StageWith(context.Background(), release, test.download); err == nil || test.wantErr != nil && !errors.Is(err, test.wantErr) {
				t.Fatalf("Stage error = %v, want failure matching %v", err, test.wantErr)
			}
			components, err := StagingComponents(release)
			if err != nil {
				t.Fatal(err)
			}
			if body, err := storage.Read(components, release.Payload().Artifact.Size); err != nil || !bytes.Equal(body, good) {
				t.Fatalf("failed stage replaced prior artifact: %q, %v", body, err)
			}
		})
	}
}

func TestProtectedArtifactResolverDerivesPathAndReverifiesHash(t *testing.T) {
	storage := mustStorage(t, testStorageRoot(t, "updates"), privateStorage)
	pending := validPending(time.Now().UTC())
	identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(pending.SKU), pending.Candidate.PackageVersion)
	if err != nil {
		t.Fatal(err)
	}
	body := []byte("installer")
	sum := sha256.Sum256(body)
	pending.ArtifactSHA256 = hex.EncodeToString(sum[:])
	components := []string{string(pending.SKU), fmt.Sprint(pending.Replay.Sequence), identity.AssetName}
	if _, err := storage.WriteAtomic(context.Background(), components, bytes.NewReader(body), int64(len(body)), int64(len(body)), pending.ArtifactSHA256); err != nil {
		t.Fatal(err)
	}
	resolver, _ := NewProtectedArtifactResolver(storage)
	path, err := resolver.Resolve(context.Background(), pending)
	if err != nil {
		t.Fatal(err)
	}
	if err := (SHA256FileVerifier{}).VerifySHA256(context.Background(), path, pending.ArtifactSHA256); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("changed"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := (SHA256FileVerifier{}).VerifySHA256(context.Background(), path, pending.ArtifactSHA256); err == nil {
		t.Fatal("accepted installer changed before launch")
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

func testStorageRoot(t *testing.T, leaf string) string {
	t.Helper()
	if runtime.GOOS != "windows" {
		return filepath.Join(t.TempDir(), leaf)
	}
	programData := os.Getenv("ProgramData")
	if !filepath.IsAbs(programData) {
		t.Fatal("Windows ProgramData is not an absolute path")
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		t.Fatal(err)
	}
	base := filepath.Join(programData, "go-mapi-storage-test-"+hex.EncodeToString(nonce[:]))
	t.Cleanup(func() {
		if err := os.RemoveAll(base); err != nil {
			t.Errorf("remove protected test storage: %v", err)
		}
	})
	return filepath.Join(base, leaf)
}
