package service

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

const (
	maxStateBytes  = int64(256 << 10)
	maxStatusBytes = int64(4 << 10)
	maxRunnerBytes = int64(128 << 20)

	serviceStateDirectory = "service"
	updateDirectory       = "updates"
	publicStatusDirectory = "status"
)

var storageNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

var ErrFinalUninstallFenced = errors.New("final machine uninstall has fenced update preparation")

const finalUninstallFenceName = "final-uninstall-fence-v1"

type storageAccess uint8

const (
	privateStorage storageAccess = iota + 1
	publicReadStorage
)

type storagePlatform interface {
	ensureRoot(string, storageAccess) error
	checkPath(string, string, bool) error
	replace(string, string) error
	syncDirectory(string) error
}

func storageSDDL(serviceSID string, access storageAccess) (string, error) {
	if !strings.HasPrefix(serviceSID, "S-1-5-80-") || strings.ContainsAny(serviceSID, "();") {
		return "", errors.New("invalid resident service SID")
	}
	sddl := "O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;" + serviceSID + ")"
	if access == publicReadStorage {
		sddl += "(A;OICI;GRGX;;;BU)"
	} else if access != privateStorage {
		return "", errors.New("invalid storage access class")
	}
	return sddl, nil
}

// ProgramDataPaths is the complete machine-owned storage surface. Callers
// supply ProgramData explicitly so tests never depend on a user environment.
type ProgramDataPaths struct {
	Service string
	Updates string
	Status  string
}

func NewProgramDataPaths(programData string) (ProgramDataPaths, error) {
	if programData == "" || !filepath.IsAbs(programData) {
		return ProgramDataPaths{}, errors.New("ProgramData must be an absolute path")
	}
	base := filepath.Join(filepath.Clean(programData), "go-mapi")
	return ProgramDataPaths{
		Service: filepath.Join(base, serviceStateDirectory),
		Updates: filepath.Join(base, updateDirectory),
		Status:  filepath.Join(base, publicStatusDirectory),
	}, nil
}

// ProtectedStorage writes one rooted machine-owned tree. Relative names are
// closed over simple components; absolute paths, traversal, alternate data
// streams and caller-selected separators are rejected.
type ProtectedStorage struct {
	root     string
	access   storageAccess
	platform storagePlatform
}

func NewProtectedStorage(root string) (*ProtectedStorage, error) {
	return newProtectedStorage(root, privateStorage, newStoragePlatform())
}

func NewPublicStatusStorage(root string) (*ProtectedStorage, error) {
	return newProtectedStorage(root, publicReadStorage, newStoragePlatform())
}

func newProtectedStorage(root string, access storageAccess, platform storagePlatform) (*ProtectedStorage, error) {
	if root == "" || !filepath.IsAbs(root) || platform == nil {
		return nil, errors.New("protected storage requires an absolute root")
	}
	root = filepath.Clean(root)
	if err := platform.ensureRoot(root, access); err != nil {
		return nil, fmt.Errorf("prepare protected storage: %w", err)
	}
	if err := platform.checkPath(root, root, true); err != nil {
		return nil, fmt.Errorf("verify protected storage root: %w", err)
	}
	return &ProtectedStorage{root: root, access: access, platform: platform}, nil
}

func (storage *ProtectedStorage) child(components ...string) (string, error) {
	if storage == nil || storage.platform == nil {
		return "", errors.New("protected storage is not initialized")
	}
	path := storage.root
	for _, component := range components {
		if !storageNamePattern.MatchString(component) || component == "." || component == ".." || strings.ContainsAny(component, `\\/:`) {
			return "", errors.New("invalid protected storage component")
		}
		path = filepath.Join(path, component)
	}
	if relative, err := filepath.Rel(storage.root, path); err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", errors.New("protected storage path escapes its root")
	}
	return path, nil
}

func (storage *ProtectedStorage) ensureDirectory(components ...string) (string, error) {
	path, err := storage.child(components...)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(path, 0700); err != nil {
		return "", fmt.Errorf("create protected directory: %w", err)
	}
	if err := storage.platform.checkPath(storage.root, path, true); err != nil {
		return "", err
	}
	return path, nil
}

// WriteAtomic creates a unique file, streams at most maxBytes, syncs and
// closes it, atomically replaces the destination, then reopens and re-hashes
// the installed bytes. expectedSize may be -1; expectedHash may be empty.
func (storage *ProtectedStorage) WriteAtomic(ctx context.Context, components []string, source io.Reader, maxBytes, expectedSize int64, expectedHash string) (string, error) {
	if source == nil {
		return "", errors.New("invalid bounded write")
	}
	return storage.writeAtomic(ctx, components, maxBytes, expectedSize, expectedHash, func(destination io.Writer) error {
		_, err := copyContext(ctx, destination, io.LimitReader(source, maxBytes+1))
		return err
	})
}

// writeAtomic accepts a producer only after it has created a protected,
// create-new temporary file. The writer enforces the signed bound even if a
// producer ignores a short write or its own size checks.
func (storage *ProtectedStorage) writeAtomic(ctx context.Context, components []string, maxBytes, expectedSize int64, expectedHash string, produce func(io.Writer) error) (string, error) {
	if len(components) == 0 || produce == nil || maxBytes <= 0 || expectedSize > maxBytes || expectedSize < -1 {
		return "", errors.New("invalid bounded write")
	}
	if expectedHash != "" {
		decoded, err := hex.DecodeString(expectedHash)
		if err != nil || len(decoded) != sha256.Size || expectedHash != strings.ToLower(expectedHash) {
			return "", errors.New("invalid expected SHA-256")
		}
	}
	destination, err := storage.child(components...)
	if err != nil {
		return "", err
	}
	directory, err := storage.ensureDirectory(components[:len(components)-1]...)
	if err != nil {
		return "", err
	}
	if err := storage.platform.checkPath(storage.root, destination, false); err != nil {
		return "", err
	}

	token := make([]byte, 16)
	if _, err := rand.Read(token); err != nil {
		return "", fmt.Errorf("create protected temporary identity: %w", err)
	}
	temporary := destination + "." + hex.EncodeToString(token) + ".tmp"
	mode := os.FileMode(0600)
	if storage.access == publicReadStorage {
		mode = 0644
	}
	file, err := os.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return "", fmt.Errorf("create protected temporary file: %w", err)
	}
	removeTemporary := true
	defer func() {
		if removeTemporary {
			_ = os.Remove(temporary)
		}
	}()

	hash := sha256.New()
	writer := &boundedContextWriter{ctx: ctx, destination: io.MultiWriter(file, hash), remaining: maxBytes}
	copyErr := produce(writer)
	if copyErr == nil {
		copyErr = writer.failure
	}
	if copyErr == nil {
		copyErr = ctx.Err()
	}
	if copyErr == nil && expectedSize >= 0 && writer.written != expectedSize {
		copyErr = errors.New("protected write size mismatch")
	}
	digest := hex.EncodeToString(hash.Sum(nil))
	if copyErr == nil && expectedHash != "" && digest != expectedHash {
		copyErr = errors.New("protected write hash mismatch")
	}
	if copyErr == nil {
		copyErr = file.Sync()
	}
	closeErr := file.Close()
	if copyErr != nil {
		return "", copyErr
	}
	if closeErr != nil {
		return "", fmt.Errorf("close protected temporary file: %w", closeErr)
	}
	if err := storage.platform.checkPath(storage.root, temporary, true); err != nil {
		return "", err
	}
	if err := storage.platform.replace(temporary, destination); err != nil {
		return "", fmt.Errorf("replace protected file: %w", err)
	}
	removeTemporary = false
	if err := storage.platform.syncDirectory(directory); err != nil {
		return "", fmt.Errorf("sync protected directory: %w", err)
	}
	if err := storage.verify(destination, writer.written, digest); err != nil {
		return "", err
	}
	return digest, nil
}

type boundedContextWriter struct {
	ctx         context.Context
	destination io.Writer
	remaining   int64
	written     int64
	failure     error
}

func (writer *boundedContextWriter) Write(data []byte) (int, error) {
	if writer.failure != nil {
		return 0, writer.failure
	}
	if err := writer.ctx.Err(); err != nil {
		writer.failure = err
		return 0, err
	}
	if int64(len(data)) > writer.remaining {
		writer.failure = errors.New("protected write exceeds signed bound")
		return 0, writer.failure
	}
	n, err := writer.destination.Write(data)
	writer.remaining -= int64(n)
	writer.written += int64(n)
	if err != nil {
		writer.failure = err
	} else if n != len(data) {
		writer.failure = io.ErrShortWrite
	}
	return n, writer.failure
}

func (storage *ProtectedStorage) verify(path string, size int64, digest string) error {
	if err := storage.platform.checkPath(storage.root, path, true); err != nil {
		return err
	}
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("reopen protected file: %w", err)
	}
	hash := sha256.New()
	written, copyErr := io.Copy(hash, io.LimitReader(file, size+1))
	closeErr := file.Close()
	if copyErr != nil {
		return fmt.Errorf("re-hash protected file: %w", copyErr)
	}
	if closeErr != nil {
		return fmt.Errorf("close re-opened protected file: %w", closeErr)
	}
	if written != size || hex.EncodeToString(hash.Sum(nil)) != digest {
		return errors.New("protected file changed after atomic replacement")
	}
	return nil
}

func (storage *ProtectedStorage) Read(components []string, maxBytes int64) ([]byte, error) {
	if maxBytes <= 0 {
		return nil, errors.New("invalid bounded read")
	}
	path, err := storage.child(components...)
	if err != nil {
		return nil, err
	}
	if err := storage.platform.checkPath(storage.root, path, true); err != nil {
		return nil, err
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maxBytes {
		return nil, errors.New("protected file exceeds read bound")
	}
	return data, nil
}

func (storage *ProtectedStorage) Remove(components ...string) error {
	path, err := storage.child(components...)
	if err != nil {
		return err
	}
	if err := storage.platform.checkPath(storage.root, path, false); err != nil {
		return err
	}
	err = os.Remove(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// Resolve returns one already-protected path selected only by closed path
// components. It is intentionally package-private so public callers can never
// turn protected storage into a general path oracle.
func (storage *ProtectedStorage) resolve(components ...string) (string, error) {
	path, err := storage.child(components...)
	if err != nil {
		return "", err
	}
	if err := storage.platform.checkPath(storage.root, path, true); err != nil {
		return "", err
	}
	return path, nil
}

func copyContext(ctx context.Context, destination io.Writer, source io.Reader) (int64, error) {
	buffer := make([]byte, 64<<10)
	var total int64
	for {
		if err := ctx.Err(); err != nil {
			return total, err
		}
		read, readErr := source.Read(buffer)
		if read > 0 {
			written, writeErr := destination.Write(buffer[:read])
			total += int64(written)
			if writeErr != nil {
				return total, writeErr
			}
			if written != read {
				return total, io.ErrShortWrite
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return total, nil
			}
			return total, readErr
		}
	}
}

// FileStateStore persists private service lifecycle state. Each document is
// strict JSON and has a fixed name; no public value can select a path.
type FileStateStore struct {
	storage *ProtectedStorage
}

type FileRunnerReadyStore struct {
	storage *ProtectedStorage
}

func NewFileRunnerReadyStore(storage *ProtectedStorage) (*FileRunnerReadyStore, error) {
	if storage == nil || storage.access != privateStorage {
		return nil, errors.New("runner readiness requires private protected storage")
	}
	return &FileRunnerReadyStore{storage: storage}, nil
}

func (store *FileRunnerReadyStore) Publish(ctx context.Context, ready RunnerReadyV1) error {
	if err := ready.Validate(); err != nil {
		return err
	}
	data, err := json.Marshal(ready)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = store.storage.WriteAtomic(ctx, []string{runnerReadyFileName(ready.TransactionID, ready.Attempt)}, bytes.NewReader(data), maxStatusBytes, int64(len(data)), "")
	return err
}

func (store *FileRunnerReadyStore) Load(_ context.Context, transactionID string, attempt uint) (*RunnerReadyV1, error) {
	if !transactionIDPattern.MatchString(transactionID) || attempt == 0 {
		return nil, errors.New("invalid runner readiness transaction")
	}
	data, err := store.storage.Read([]string{runnerReadyFileName(transactionID, attempt)}, maxStatusBytes)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var ready RunnerReadyV1
	if err := decodeStrict(data, &ready); err != nil {
		return nil, err
	}
	if err := ready.Validate(); err != nil || ready.TransactionID != transactionID || ready.Attempt != attempt {
		return nil, errors.New("invalid runner readiness evidence")
	}
	return &ready, nil
}

func runnerReadyFileName(transactionID string, attempt uint) string {
	return fmt.Sprintf("ready-%s-attempt-%d-v1.json", transactionID, attempt)
}

func NewFileStateStore(storage *ProtectedStorage) (*FileStateStore, error) {
	if storage == nil || storage.access != privateStorage {
		return nil, errors.New("state store requires private protected storage")
	}
	return &FileStateStore{storage: storage}, nil
}

func (store *FileStateStore) Load(_ context.Context) (*PendingV1, error) {
	unlock, err := lockStateStore(store.storage)
	if err != nil {
		return nil, err
	}
	defer unlock()
	data, err := store.storage.Read([]string{"pending-v2.json"}, maxStateBytes)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	pending, err := UnmarshalPending(data)
	return &pending, err
}

func (store *FileStateStore) Save(ctx context.Context, pending PendingV1) error {
	unlock, err := lockStateStore(store.storage)
	if err != nil {
		return err
	}
	defer unlock()
	data, err := MarshalPending(pending)
	if err != nil {
		return err
	}
	_, err = store.storage.WriteAtomic(ctx, []string{"pending-v2.json"}, bytes.NewReader(data), maxStateBytes, int64(len(data)), "")
	return err
}

// CompareAndSave is the short state.lock transaction used at installer
// authorization boundaries. It rejects a stale or concurrently prepared
// record instead of overwriting another process's decision.
func (store *FileStateStore) CompareAndSave(ctx context.Context, expected *PendingV1, next PendingV1) error {
	encoded, err := MarshalPending(next)
	if err != nil {
		return err
	}
	unlock, err := lockStateStore(store.storage)
	if err != nil {
		return err
	}
	defer unlock()
	if expected == nil {
		if _, err := store.storage.Read([]string{finalUninstallFenceName}, 64); err == nil {
			return ErrFinalUninstallFenced
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	current, err := store.storage.Read([]string{"pending-v2.json"}, maxStateBytes)
	if expected == nil {
		if err == nil {
			return ErrStateConflict
		}
		if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	} else {
		if err != nil {
			return err
		}
		prior, err := MarshalPending(*expected)
		if err != nil || !bytes.Equal(current, prior) {
			return ErrStateConflict
		}
	}
	_, err = store.storage.WriteAtomic(ctx, []string{"pending-v2.json"}, bytes.NewReader(encoded), maxStateBytes, int64(len(encoded)), "")
	return err
}

// BeginFinalUninstall shares state.lock with new transaction preparation.
// A pending transaction is never discarded to make uninstall appear safe.
func (store *FileStateStore) BeginFinalUninstall(ctx context.Context) error {
	unlock, err := lockStateStoreBounded(ctx, store.storage)
	if err != nil {
		return err
	}
	defer unlock()
	if _, err := store.storage.Read([]string{"pending-v2.json"}, maxStateBytes); err == nil {
		return errors.New("active machine update blocks final uninstall")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if _, err := store.storage.Read([]string{finalUninstallFenceName}, 64); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	_, err = store.storage.WriteAtomic(ctx, []string{finalUninstallFenceName}, strings.NewReader("go-mapi-final-uninstall-v1\n"), 64, -1, "")
	return err
}

func (store *FileStateStore) RollbackFinalUninstall() error {
	unlock, err := lockStateStore(store.storage)
	if err != nil {
		return err
	}
	defer unlock()
	return store.storage.Remove(finalUninstallFenceName)
}

// CompareAndClear retires only the exact terminal record observed by the
// coordinator. A runner or another service instance can never be erased by a
// stale retry decision.
func (store *FileStateStore) CompareAndClear(_ context.Context, expected PendingV1) error {
	prior, err := MarshalPending(expected)
	if err != nil {
		return err
	}
	unlock, err := lockStateStore(store.storage)
	if err != nil {
		return err
	}
	defer unlock()
	current, err := store.storage.Read([]string{"pending-v2.json"}, maxStateBytes)
	if err != nil {
		return err
	}
	if !bytes.Equal(current, prior) {
		return ErrStateConflict
	}
	return store.storage.Remove("pending-v2.json")
}

type FileReplayStore struct {
	storage *ProtectedStorage
}

func NewFileReplayStore(storage *ProtectedStorage) (*FileReplayStore, error) {
	if storage == nil || storage.access != privateStorage {
		return nil, errors.New("replay store requires private protected storage")
	}
	return &FileReplayStore{storage: storage}, nil
}

func (store *FileReplayStore) Load(_ context.Context, sku update.SKU) (update.ReplayState, error) {
	name, err := replayFileName(sku)
	if err != nil {
		return update.ReplayState{}, err
	}
	data, err := store.storage.Read([]string{name}, maxStateBytes)
	if errors.Is(err, os.ErrNotExist) {
		return update.ReplayState{}, nil
	}
	if err != nil {
		return update.ReplayState{}, err
	}
	var state update.ReplayState
	if err := decodeStrict(data, &state); err != nil {
		return update.ReplayState{}, err
	}
	if state.Namespace != string(sku) || state.Sequence == 0 || !validSHA256(state.Digest) {
		return update.ReplayState{}, errors.New("invalid replay state")
	}
	return state, nil
}

func (store *FileReplayStore) Save(ctx context.Context, state update.ReplayState) error {
	sku := update.SKU(state.Namespace)
	name, err := replayFileName(sku)
	if err != nil || state.Sequence == 0 || !validSHA256(state.Digest) {
		return errors.New("invalid replay state")
	}
	unlock, err := lockStateStore(store.storage)
	if err != nil {
		return err
	}
	defer unlock()
	previous, err := store.storage.Read([]string{name}, maxStateBytes)
	if err == nil {
		var old update.ReplayState
		if err := decodeStrict(previous, &old); err != nil {
			return err
		}
		if old.Namespace != state.Namespace || old.Sequence > state.Sequence ||
			(old.Sequence == state.Sequence && old.Digest != state.Digest) {
			return ErrStateConflict
		}
		if old.Sequence == state.Sequence {
			return nil
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = store.storage.WriteAtomic(ctx, []string{name}, bytes.NewReader(data), maxStateBytes, int64(len(data)), "")
	return err
}

func replayFileName(sku update.SKU) (string, error) {
	if sku != update.System && sku != update.Suite {
		return "", errors.New("invalid replay SKU")
	}
	return "replay-" + string(sku) + "-v1.json", nil
}

type FileLastResultStore struct{ storage *ProtectedStorage }

func NewFileLastResultStore(storage *ProtectedStorage) (*FileLastResultStore, error) {
	if storage == nil || storage.access != privateStorage {
		return nil, errors.New("last result store requires private protected storage")
	}
	return &FileLastResultStore{storage: storage}, nil
}

func (store *FileLastResultStore) Load(_ context.Context) (*LastResultV1, error) {
	data, err := store.storage.Read([]string{"last-result-v1.json"}, maxStateBytes)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var result LastResultV1
	if err := decodeStrict(data, &result); err != nil {
		return nil, err
	}
	if err := result.Validate(); err != nil {
		return nil, err
	}
	return &result, nil
}

func (store *FileLastResultStore) Save(ctx context.Context, result LastResultV1) error {
	if err := result.Validate(); err != nil {
		return err
	}
	unlock, err := lockStateStore(store.storage)
	if err != nil {
		return err
	}
	defer unlock()
	previous, err := store.storage.Read([]string{"last-result-v1.json"}, maxStateBytes)
	if err == nil {
		var old LastResultV1
		if err := decodeStrict(previous, &old); err != nil {
			return err
		}
		if err := old.Validate(); err != nil {
			return err
		}
		if old.SKU == result.SKU && (old.Sequence > result.Sequence ||
			(old.Sequence == result.Sequence && old.Digest != result.Digest)) {
			return ErrStateConflict
		}
		if old.TransactionID == result.TransactionID {
			if old != result {
				return ErrStateConflict
			}
			return nil
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	data, err := json.Marshal(result)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = store.storage.WriteAtomic(ctx, []string{"last-result-v1.json"}, bytes.NewReader(data), maxStateBytes, int64(len(data)), "")
	return err
}

// residentStatus is an in-memory health observation used to publish the
// single app-readable public status schema.
type residentStatus struct {
	SKU                update.SKU `json:"sku"`
	PackageVersion     string     `json:"packageVersion,omitempty"`
	ServiceVersion     string     `json:"serviceVersion,omitempty"`
	InterceptorVersion string     `json:"interceptorVersion,omitempty"`
	AppVersion         string     `json:"appVersion,omitempty"`
	Health             string     `json:"health,omitempty"`
	Updates            string     `json:"updates"`
	Code               EventCode  `json:"code"`
	LastResult         Result     `json:"lastResult,omitempty"`
	LastResultAt       time.Time  `json:"lastResultAt,omitempty"`
	UpdatedAt          time.Time  `json:"updatedAt"`
}

type PublicStatusStore struct {
	storage *ProtectedStorage
}

func NewPublicStatusStore(storage *ProtectedStorage) (*PublicStatusStore, error) {
	if storage == nil || storage.access != publicReadStorage {
		return nil, errors.New("public status store requires its read-only public surface")
	}
	return &PublicStatusStore{storage: storage}, nil
}

// Save publishes the bounded app-readable machine status.
func (store *PublicStatusStore) Save(ctx context.Context, status mapi.PublicStatusV2) error {
	if err := mapi.ValidatePublicStatusV2(status); err != nil {
		return err
	}
	data, err := json.Marshal(status)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if int64(len(data)) > maxStatusBytes {
		return errors.New("public status exceeds bound")
	}
	_, err = store.storage.WriteAtomic(ctx, []string{"status-v2.json"}, bytes.NewReader(data), maxStatusBytes, int64(len(data)), "")
	return err
}

func decodeStrict(data []byte, destination any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return errors.New("unexpected trailing JSON data")
	}
	return nil
}

// StagingComponents maps an authenticated release to its one fixed protected
// directory and immutable MSI name.
func StagingComponents(release update.Release) ([]string, error) {
	sku := update.SKU(release.Namespace())
	if sku != update.System && sku != update.Suite || release.Sequence() == 0 {
		return nil, errors.New("invalid staged release identity")
	}
	payload := release.Payload()
	identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(sku), payload.Version)
	if err != nil || !strings.HasSuffix(payload.Artifact.URL, "/"+identity.AssetName) {
		return nil, errors.New("invalid staged release asset")
	}
	return []string{string(sku), fmt.Sprintf("%d", release.Sequence()), identity.AssetName}, nil
}

// ProtectedArtifactStore is the coordinator's only artifact sink. The handle
// is an opaque rooted relative identity; it never accepts a destination from
// metadata or another caller.
type ProtectedArtifactStore struct {
	storage      *ProtectedStorage
	stateStorage *ProtectedStorage
}

type ProtectedArtifactResolver struct {
	storage *ProtectedStorage
}

func NewProtectedArtifactResolver(storage *ProtectedStorage) (*ProtectedArtifactResolver, error) {
	if storage == nil || storage.access != privateStorage {
		return nil, errors.New("artifact resolver requires private protected storage")
	}
	return &ProtectedArtifactResolver{storage: storage}, nil
}

func (resolver *ProtectedArtifactResolver) Resolve(_ context.Context, pending PendingV1) (string, error) {
	if err := pending.Validate(); err != nil {
		return "", err
	}
	identity, err := mapi.NewMachinePackageIdentity(mapi.MachineSKU(pending.SKU), pending.Candidate.PackageVersion)
	if err != nil {
		return "", err
	}
	return resolver.storage.resolve(string(pending.SKU), fmt.Sprintf("%d", pending.Replay.Sequence), identity.AssetName)
}

type SHA256FileVerifier struct{}

func (SHA256FileVerifier) VerifySHA256(ctx context.Context, path, expected string) error {
	if !filepath.IsAbs(path) || !validSHA256(expected) {
		return errors.New("invalid file integrity request")
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := copyContext(ctx, hash, file); err != nil {
		return err
	}
	if hex.EncodeToString(hash.Sum(nil)) != expected {
		return errors.New("protected file SHA-256 changed")
	}
	return nil
}

func NewProtectedArtifactStore(storage *ProtectedStorage, stateStorage ...*ProtectedStorage) (*ProtectedArtifactStore, error) {
	if storage == nil || storage.access != privateStorage {
		return nil, errors.New("artifact store requires private storage")
	}
	store := &ProtectedArtifactStore{storage: storage}
	if len(stateStorage) > 1 || len(stateStorage) == 1 && (stateStorage[0] == nil || stateStorage[0].access != privateStorage) {
		return nil, errors.New("artifact discard guard requires private state storage")
	}
	if len(stateStorage) == 1 {
		store.stateStorage = stateStorage[0]
	}
	return store, nil
}

// Discard removes a staged candidate only while the shared state lock proves
// that no durable pending transaction references it. An unreadable pending
// record fails closed. A concurrent winner that has not yet committed may
// need to restage, but cannot install missing or unverified bytes.
func (store *ProtectedArtifactStore) Discard(ctx context.Context, artifact StagedArtifact) error {
	if store == nil || store.stateStorage == nil {
		return errors.New("artifact discard guard is unavailable")
	}
	components := strings.Split(artifact.Handle, "/")
	if len(components) != 3 || components[0] != string(update.System) && components[0] != string(update.Suite) || !validSHA256(artifact.SHA256) {
		return errors.New("invalid staged artifact handle")
	}
	if _, err := store.storage.child(components...); err != nil {
		return err
	}
	unlock, err := lockStateStoreBounded(ctx, store.stateStorage)
	if err != nil {
		return err
	}
	defer unlock()
	data, err := store.stateStorage.Read([]string{"pending-v2.json"}, maxStateBytes)
	if err == nil {
		pending, decodeErr := UnmarshalPending(data)
		if decodeErr != nil {
			return decodeErr
		}
		if string(pending.SKU) == components[0] && fmt.Sprintf("%d", pending.Replay.Sequence) == components[1] && pending.ArtifactSHA256 == artifact.SHA256 {
			return nil
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return store.storage.Remove(components...)
}

// StageWith lets the shared engine own the only artifact network operation.
// This store only chooses and atomically writes the protected destination.
func (store *ProtectedArtifactStore) StageWith(ctx context.Context, release update.Release, write func(io.Writer) error) (StagedArtifact, error) {
	if store == nil || write == nil {
		return StagedArtifact{}, errors.New("artifact staging writer is unavailable")
	}
	components, err := StagingComponents(release)
	if err != nil {
		return StagedArtifact{}, err
	}
	payload := release.Payload()
	digest, err := store.storage.writeAtomic(ctx, components, payload.Artifact.Size, payload.Artifact.Size, payload.Artifact.SHA256, func(destination io.Writer) error {
		if err := write(destination); err != nil {
			return fmt.Errorf("write prepared artifact: %w", err)
		}
		return nil
	})
	if err != nil {
		return StagedArtifact{}, err
	}
	return StagedArtifact{Handle: strings.Join(components, "/"), SHA256: digest}, nil
}
