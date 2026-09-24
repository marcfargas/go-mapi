package service

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

const PendingSchemaV1 = "go-mapi-service-pending-v1"
const PendingSchemaV2 = "go-mapi-service-pending-v2"

type Phase string

const (
	PhasePrepared           Phase = "prepared"
	PhaseChildRecorded      Phase = "child-recorded"
	PhaseResumeAuthorized   Phase = "resume-authorized"
	PhaseRunning            Phase = "running"
	PhaseInstallerRunning   Phase = "installer-running"
	PhaseStillRunning       Phase = "still-running"
	PhaseCommitted          Phase = "committed"
	PhaseRolledBack         Phase = "rolled-back"
	PhaseRebootPending      Phase = "reboot-pending"
	PhaseRepairRequired     Phase = "repair-required"
	PhaseOutcomeUnconfirmed Phase = "outcome-unconfirmed"
)

type Result string

const (
	ResultNone               Result = ""
	ResultInstalled          Result = "installed"
	ResultRolledBack         Result = "rolled-back"
	ResultRebootRequired     Result = "reboot-required"
	ResultAmbiguous          Result = "ambiguous"
	ResultRetryScheduled     Result = "retry-scheduled"
	ResultBusyExhausted      Result = "busy-exhausted"
	ResultOutcomeUnconfirmed Result = "outcome-unconfirmed"
)

// ProcessIdentity prevents a recycled PID from being mistaken for the runner
// or Windows Installer instance recorded before a service restart.
type ProcessIdentity struct {
	PID               uint32 `json:"pid"`
	CreatedAtUnixNano int64  `json:"createdAtUnixNano"`
}

type ExitEvidence struct {
	Code       uint32    `json:"code"`
	ObservedAt time.Time `json:"observedAt"`
}

type ProductSnapshot struct {
	SKU            update.SKU        `json:"sku"`
	PackageVersion string            `json:"packageVersion"`
	ProductVersion string            `json:"productVersion"`
	ProductCode    string            `json:"productCode"`
	Contained      map[string]string `json:"containedVersions"`
}

// PendingV1 contains only data required to reconcile one authenticated MSI
// transaction. It intentionally has no URL, command-line, property, signer,
// or caller-selected destination fields.
type PendingV1 struct {
	Schema          string             `json:"schema"`
	TransactionID   string             `json:"transactionId"`
	SKU             update.SKU         `json:"sku"`
	Old             ProductSnapshot    `json:"old"`
	Candidate       ProductSnapshot    `json:"candidate"`
	Replay          update.ReplayState `json:"replay"`
	ArtifactSHA256  string             `json:"artifactSha256"`
	LaunchBootID    string             `json:"launchBootId,omitempty"`
	Phase           Phase              `json:"phase"`
	Runner          *ProcessIdentity   `json:"runner,omitempty"`
	Installer       *ProcessIdentity   `json:"installer,omitempty"`
	InstallerThread *ProcessIdentity   `json:"installerThread,omitempty"`
	Exit            *ExitEvidence      `json:"exit,omitempty"`
	PreparedAt      time.Time          `json:"preparedAt"`
	UpdatedAt       time.Time          `json:"updatedAt"`
	Attempt         uint               `json:"attempt"`
	NextAttemptAt   *time.Time         `json:"nextAttemptAt,omitempty"`
	RetryDeadline   *time.Time         `json:"retryDeadline,omitempty"`
	Result          Result             `json:"result,omitempty"`
}

var transactionIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{0,63}$`)

func MarshalPending(pending PendingV1) ([]byte, error) {
	if err := pending.Validate(); err != nil {
		return nil, err
	}
	encoded, err := json.Marshal(pending)
	if err != nil {
		return nil, fmt.Errorf("encode pending update: %w", err)
	}
	return append(encoded, '\n'), nil
}

func UnmarshalPending(encoded []byte) (PendingV1, error) {
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.DisallowUnknownFields()
	var pending PendingV1
	if err := decoder.Decode(&pending); err != nil {
		return PendingV1{}, fmt.Errorf("decode pending update: %w", err)
	}
	if decoder.More() {
		return PendingV1{}, errors.New("decode pending update: trailing data")
	}
	var extra any
	if err := decoder.Decode(&extra); err == nil {
		return PendingV1{}, errors.New("decode pending update: trailing value")
	}
	if err := pending.Validate(); err != nil {
		return PendingV1{}, err
	}
	return pending, nil
}

func (pending PendingV1) Validate() error {
	if pending.Schema != PendingSchemaV1 && pending.Schema != PendingSchemaV2 {
		return errors.New("unsupported pending update schema")
	}
	if !transactionIDPattern.MatchString(pending.TransactionID) {
		return errors.New("invalid pending transaction identity")
	}
	if pending.SKU != update.System && pending.SKU != update.Suite {
		return errors.New("invalid pending SKU")
	}
	if err := validateProduct("old", pending.Old, pending.SKU); err != nil {
		return err
	}
	if err := validateProduct("candidate", pending.Candidate, pending.SKU); err != nil {
		return err
	}
	if pending.Replay.Namespace != string(pending.SKU) || pending.Replay.Sequence == 0 || !validSHA256(pending.Replay.Digest) {
		return errors.New("invalid pending replay authorization")
	}
	if !validSHA256(pending.ArtifactSHA256) {
		return errors.New("invalid pending artifact hash")
	}
	if pending.LaunchBootID != "" && !transactionIDPattern.MatchString(pending.LaunchBootID) {
		return errors.New("invalid launch boot identity")
	}
	if !validPhase(pending.Phase) || pending.PreparedAt.IsZero() || pending.UpdatedAt.IsZero() || pending.Attempt == 0 {
		return errors.New("invalid pending lifecycle state")
	}
	if err := validateProcessIdentity(pending.Runner); err != nil {
		return fmt.Errorf("invalid runner identity: %w", err)
	}
	if err := validateProcessIdentity(pending.Installer); err != nil {
		return fmt.Errorf("invalid installer identity: %w", err)
	}
	if err := validateProcessIdentity(pending.InstallerThread); err != nil {
		return fmt.Errorf("invalid installer thread identity: %w", err)
	}
	if pending.Schema == PendingSchemaV1 && (pending.InstallerThread != nil || pending.Phase == PhaseChildRecorded || pending.Phase == PhaseResumeAuthorized || pending.Phase == PhaseRunning) {
		return errors.New("v1 pending record contains v2 execution state")
	}
	if pending.Schema == PendingSchemaV2 && (pending.Phase == PhaseChildRecorded || pending.Phase == PhaseResumeAuthorized || pending.Phase == PhaseRunning) && (pending.Runner == nil || pending.Installer == nil || pending.InstallerThread == nil) {
		return errors.New("v2 running transaction lacks process and thread identities")
	}
	if (pending.Phase == PhaseInstallerRunning || pending.Phase == PhaseStillRunning) && (pending.Runner == nil || pending.Installer == nil) {
		return errors.New("running transaction lacks process identities")
	}
	if pending.Exit != nil && pending.Exit.ObservedAt.IsZero() {
		return errors.New("invalid installer exit evidence")
	}
	if pending.RetryDeadline != nil && (!pending.RetryDeadline.After(pending.PreparedAt) || pending.RetryDeadline.After(pending.PreparedAt.Add(10*time.Minute))) {
		return errors.New("invalid absolute installer retry deadline")
	}
	if pending.Schema == PendingSchemaV2 && pending.Result == ResultRetryScheduled &&
		(pending.Phase != PhaseRolledBack || pending.Exit == nil || pending.Exit.Code != 1618 || pending.NextAttemptAt == nil || pending.RetryDeadline == nil ||
			!pending.NextAttemptAt.Before(*pending.RetryDeadline) || pending.Attempt >= 3) {
		return errors.New("invalid installer-busy retry authorization")
	}
	return nil
}

func validateProduct(label string, product ProductSnapshot, sku update.SKU) error {
	if product.SKU != sku || product.PackageVersion == "" || product.ProductVersion == "" || product.ProductCode == "" || len(product.Contained) == 0 {
		return fmt.Errorf("invalid %s product snapshot", label)
	}
	for component, version := range product.Contained {
		if component == "" || version == "" {
			return fmt.Errorf("invalid %s contained version", label)
		}
	}
	return nil
}

func validateProcessIdentity(identity *ProcessIdentity) error {
	if identity != nil && (identity.PID == 0 || identity.CreatedAtUnixNano <= 0) {
		return errors.New("PID and creation time are required")
	}
	return nil
}

func validSHA256(value string) bool {
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 32 && value == fmt.Sprintf("%x", decoded)
}

func validPhase(phase Phase) bool {
	switch phase {
	case PhasePrepared, PhaseChildRecorded, PhaseResumeAuthorized, PhaseRunning, PhaseInstallerRunning, PhaseStillRunning, PhaseCommitted, PhaseRolledBack, PhaseRebootPending, PhaseRepairRequired, PhaseOutcomeUnconfirmed:
		return true
	default:
		return false
	}
}
