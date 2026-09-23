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
	if len(components) == 0 || source == nil || maxBytes <= 0 || expectedSize > maxBytes || expectedSize < -1 {
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
	written, copyErr := copyContext(ctx, io.MultiWriter(file, hash), io.LimitReader(source, maxBytes+1))
	if copyErr == nil && written > maxBytes {
		copyErr = errors.New("protected write exceeds signed bound")
	}
	if copyErr == nil && expectedSize >= 0 && written != expectedSize {
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
	if err := storage.verify(destination, written, digest); err != nil {
		return "", err
	}
	return digest, nil
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
	_, err = store.storage.WriteAtomic(ctx, []string{runnerReadyFileName(ready.TransactionID)}, bytes.NewReader(data), maxStatusBytes, int64(len(data)), "")
	return err
}

func (store *FileRunnerReadyStore) Load(_ context.Context, transactionID string) (*RunnerReadyV1, error) {
	if !transactionIDPattern.MatchString(transactionID) {
		return nil, errors.New("invalid runner readiness transaction")
	}
	data, err := store.storage.Read([]string{runnerReadyFileName(transactionID)}, maxStatusBytes)
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
	if err := ready.Validate(); err != nil || ready.TransactionID != transactionID {
		return nil, errors.New("invalid runner readiness evidence")
	}
	return &ready, nil
}

func runnerReadyFileName(transactionID string) string { return "ready-" + transactionID + "-v1.json" }

func NewFileStateStore(storage *ProtectedStorage) (*FileStateStore, error) {
	if storage == nil || storage.access != privateStorage {
		return nil, errors.New("state store requires private protected storage")
	}
	return &FileStateStore{storage: storage}, nil
}

func (store *FileStateStore) Load(_ context.Context) (*PendingV1, error) {
	data, err := store.storage.Read([]string{"pending-v1.json"}, maxStateBytes)
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
	data, err := MarshalPending(pending)
	if err != nil {
		return err
	}
	_, err = store.storage.WriteAtomic(ctx, []string{"pending-v1.json"}, bytes.NewReader(data), maxStateBytes, int64(len(data)), "")
	return err
}

func (store *FileStateStore) Clear(_ context.Context) error {
	return store.storage.Remove("pending-v1.json")
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

type FileStatusStore struct {
	storage *ProtectedStorage
}

func NewFileStatusStore(storage *ProtectedStorage) (*FileStatusStore, error) {
	if storage == nil || storage.access != privateStorage {
		return nil, errors.New("internal status store requires private protected storage")
	}
	return &FileStatusStore{storage: storage}, nil
}

func (store *FileStatusStore) Load(_ context.Context) (ServiceStatus, error) {
	data, err := store.storage.Read([]string{"status-v1.json"}, maxStatusBytes)
	if errors.Is(err, os.ErrNotExist) {
		return ServiceStatus{}, nil
	}
	if err != nil {
		return ServiceStatus{}, err
	}
	var status ServiceStatus
	if err := decodeStrict(data, &status); err != nil {
		return ServiceStatus{}, err
	}
	if !validStatusCode(status.LastCode) {
		return ServiceStatus{}, errors.New("invalid internal status code")
	}
	return status, nil
}

func (store *FileStatusStore) Save(ctx context.Context, status ServiceStatus) error {
	if !validStatusCode(status.LastCode) {
		return errors.New("invalid internal status code")
	}
	data, err := json.Marshal(status)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = store.storage.WriteAtomic(ctx, []string{"status-v1.json"}, bytes.NewReader(data), maxStatusBytes, int64(len(data)), "")
	return err
}

func validStatusCode(code string) bool {
	return code == "" || code == StatusOffline || code == StatusReady
}

const PublicStatusSchemaV1 = "go-mapi-public-status-v1"

// PublicStatusV1 is intentionally too small to carry URLs, paths, errors,
// account names, proxy details, transaction IDs, or installer arguments.
type PublicStatusV1 struct {
	Schema    string    `json:"schema"`
	Code      EventCode `json:"code"`
	UpdatedAt time.Time `json:"updatedAt"`
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

func (store *PublicStatusStore) Save(ctx context.Context, status PublicStatusV1) error {
	if status.Schema != PublicStatusSchemaV1 || status.UpdatedAt.IsZero() || !validPublicEvent(status.Code) {
		return errors.New("invalid public status")
	}
	data, err := json.Marshal(status)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if int64(len(data)) > maxStatusBytes {
		return errors.New("public status exceeds bound")
	}
	_, err = store.storage.WriteAtomic(ctx, []string{"status-v1.json"}, bytes.NewReader(data), maxStatusBytes, int64(len(data)), "")
	return err
}

func validPublicEvent(code EventCode) bool {
	switch code {
	case EventOffline, EventPrepared, EventHandedOff, EventStillRunning, EventCommitted, EventRolledBack, EventRebootPending, EventRepairNeeded:
		return true
	default:
		return false
	}
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
	identity, err := machineIdentity(sku, payload.Version)
	if err != nil || !strings.HasSuffix(payload.Artifact.URL, "/"+identity.AssetName) {
		return nil, errors.New("invalid staged release asset")
	}
	return []string{string(sku), fmt.Sprintf("%d", release.Sequence()), identity.AssetName}, nil
}

type stagedMachineIdentity struct{ AssetName string }

func machineIdentity(sku update.SKU, version string) (stagedMachineIdentity, error) {
	name := "go-mapi-" + string(sku) + "-" + version + "-x64.msi"
	if !storageNamePattern.MatchString(name) {
		return stagedMachineIdentity{}, errors.New("invalid machine asset name")
	}
	return stagedMachineIdentity{AssetName: name}, nil
}

type ArtifactDownload func(context.Context, update.Release, io.Writer) error

// ProtectedArtifactStore is the coordinator's only artifact sink. The handle
// is an opaque rooted relative identity; it never accepts a destination from
// metadata or another caller.
type ProtectedArtifactStore struct {
	storage  *ProtectedStorage
	download ArtifactDownload
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
	identity, err := machineIdentity(pending.SKU, pending.Candidate.PackageVersion)
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

func NewProtectedArtifactStore(storage *ProtectedStorage, download ArtifactDownload) (*ProtectedArtifactStore, error) {
	if storage == nil || storage.access != privateStorage || download == nil {
		return nil, errors.New("artifact store requires private storage and a downloader")
	}
	return &ProtectedArtifactStore{storage: storage, download: download}, nil
}

func (store *ProtectedArtifactStore) Stage(ctx context.Context, release update.Release) (StagedArtifact, error) {
	components, err := StagingComponents(release)
	if err != nil {
		return StagedArtifact{}, err
	}
	payload := release.Payload()
	reader, writer := io.Pipe()
	downloadDone := make(chan error, 1)
	go func() {
		err := store.download(ctx, release, writer)
		_ = writer.CloseWithError(err)
		downloadDone <- err
	}()
	digest, writeErr := store.storage.WriteAtomic(ctx, components, reader, payload.Artifact.Size, payload.Artifact.Size, payload.Artifact.SHA256)
	_ = reader.CloseWithError(writeErr)
	downloadErr := <-downloadDone
	if downloadErr != nil {
		return StagedArtifact{}, fmt.Errorf("download authenticated artifact: %w", downloadErr)
	}
	if writeErr != nil {
		return StagedArtifact{}, writeErr
	}
	return StagedArtifact{Handle: strings.Join(components, "/"), SHA256: digest}, nil
}
