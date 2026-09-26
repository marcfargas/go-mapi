package mapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"time"
)

const PublicStatusSchemaV2 = "go-mapi-public-status-v2"

// PublicStatusV2 is the bounded diagnostic contract between the machine
// service and an unelevated app. It carries no download or execution authority.
type PublicStatusV2 struct {
	Schema             string    `json:"schema"`
	SKU                string    `json:"sku"`
	PackageVersion     string    `json:"packageVersion,omitempty"`
	ServiceVersion     string    `json:"serviceVersion,omitempty"`
	InterceptorVersion string    `json:"interceptorVersion,omitempty"`
	AppVersion         string    `json:"appVersion,omitempty"`
	Health             string    `json:"health,omitempty"`
	Updates            string    `json:"updates"`
	Code               string    `json:"code"`
	LastResult         string    `json:"lastResult,omitempty"`
	LastResultAt       time.Time `json:"lastResultAt,omitempty"`
	Capability         string    `json:"capability"`
	Checker            string    `json:"checker"`
	CandidateVersion   string    `json:"candidateVersion,omitempty"`
	LastAttemptAt      time.Time `json:"lastAttemptAt,omitempty"`
	LastSuccessAt      time.Time `json:"lastSuccessAt,omitempty"`
	NextAttemptAt      time.Time `json:"nextAttemptAt,omitempty"`
	CandidateExpiresAt time.Time `json:"candidateExpiresAt,omitempty"`
	HealthObservedAt   time.Time `json:"healthObservedAt,omitempty"`
	UpdatedAt          time.Time `json:"updatedAt"`
}

func validStatusEnum(value string, allowed ...string) bool {
	for _, candidate := range allowed {
		if value == candidate {
			return true
		}
	}
	return false
}

func ValidatePublicStatusV2(s PublicStatusV2) error {
	if s.Schema != PublicStatusSchemaV2 || s.UpdatedAt.IsZero() ||
		!validStatusEnum(s.SKU, "", "system", "suite") ||
		!validStatusEnum(s.Health, "", "healthy", "repair-required") ||
		!validStatusEnum(s.Updates, "enabled", "disabled", "unknown") ||
		!validStatusEnum(s.Capability, "unavailable", "discovery", "automatic") ||
		!validStatusEnum(s.Checker, "unavailable", "disabled", "checking", "no-update", "available", "offline", "rejected") ||
		!validStatusEnum(s.Code, "offline", "prepared", "handed-off", "still-running", "committed", "rolled-back", "reboot-pending", "repair-required", "pending") {
		return errors.New("invalid public status identity or enum")
	}
	for _, version := range []string{s.PackageVersion, s.ServiceVersion, s.InterceptorVersion, s.AppVersion, s.CandidateVersion} {
		if version != "" && (len(version) > 64 || !IsStrictReleaseVersion(version)) {
			return errors.New("invalid public status version")
		}
	}
	if s.Checker == "available" && (s.CandidateVersion == "" || s.CandidateExpiresAt.IsZero() || s.LastSuccessAt.IsZero()) ||
		s.Checker != "available" && s.CandidateVersion != "" ||
		s.Checker == "no-update" && (s.CandidateExpiresAt.IsZero() || s.LastSuccessAt.IsZero()) ||
		s.LastResult == "" && !s.LastResultAt.IsZero() ||
		s.LastResult != "" && (!validStatusEnum(s.LastResult, "installed", "rolled-back", "busy-exhausted") || s.LastResultAt.IsZero()) {
		return errors.New("incoherent public status")
	}
	return nil
}

func DecodePublicStatusV2(data []byte) (PublicStatusV2, error) {
	if len(data) == 0 || len(data) > 4096 {
		return PublicStatusV2{}, errors.New("public status exceeds bound")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return PublicStatusV2{}, err
	}
	for _, name := range []string{"schema", "sku", "updates", "code", "capability", "checker", "updatedAt"} {
		if _, present := fields[name]; !present {
			return PublicStatusV2{}, errors.New("public status is missing a required field")
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var status PublicStatusV2
	if err := decoder.Decode(&status); err != nil {
		return PublicStatusV2{}, err
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return PublicStatusV2{}, errors.New("trailing public status data")
	}
	if err := ValidatePublicStatusV2(status); err != nil {
		return PublicStatusV2{}, err
	}
	return status, nil
}

type InstalledStatusIdentity struct{ SKU, PackageVersion, InterceptorVersion string }

// ManagedSystemUpdateEffective is deliberately false for discovery-only
// service builds. A fresh v2 publication is necessary but cannot by itself
// establish that a running service can perform automatic installation.
func ManagedSystemUpdateEffective(s PublicStatusV2, installed InstalledStatusIdentity, serviceRunning bool, now time.Time) bool {
	return serviceRunning && ValidatePublicStatusV2(s) == nil && s.Capability == "automatic" && s.Updates == "enabled" &&
		s.SKU == installed.SKU && s.PackageVersion == installed.PackageVersion && s.InterceptorVersion == installed.InterceptorVersion &&
		s.Health == "healthy" && s.Code == "pending" &&
		(s.Checker == "available" || s.Checker == "no-update") && now.Before(s.CandidateExpiresAt) &&
		!now.Before(s.UpdatedAt.Add(-time.Minute)) && now.Sub(s.UpdatedAt) <= 5*time.Minute &&
		!s.HealthObservedAt.IsZero() && !now.Before(s.HealthObservedAt.Add(-time.Minute)) && now.Sub(s.HealthObservedAt) <= 6*time.Hour &&
		!s.LastSuccessAt.IsZero() && !now.Before(s.LastSuccessAt.Add(-time.Minute)) && now.Sub(s.LastSuccessAt) <= 6*time.Hour+5*time.Minute &&
		!s.NextAttemptAt.IsZero() && now.Before(s.NextAttemptAt.Add(5*time.Minute))
}
