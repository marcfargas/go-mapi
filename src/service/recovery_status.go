package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

// PublicRecoveryV1 is a diagnostic companion. Old status-v2 consumers see the
// same schema and enums, and no public file is read as execution authority.
type PublicRecoveryV1 struct {
	Schema        string     `json:"schema"`
	SKU           update.SKU `json:"sku"`
	Version       string     `json:"version"`
	TransactionID string     `json:"transactionId"`
	Consumed      uint       `json:"consumed"`
	Maximum       uint       `json:"maximum"`
	Stage         string     `json:"stage"`
	Reason        string     `json:"reason"`
	FailedAt      time.Time  `json:"failedAt,omitempty"`
	DueAt         time.Time  `json:"dueAt,omitempty"`
	UpdatedAt     time.Time  `json:"updatedAt"`
}

func publicRecovery(r RecoveryV1) PublicRecoveryV1 {
	return PublicRecoveryV1{Schema: "go-mapi-public-recovery-v1", SKU: r.Reservation.SKU, Version: r.Reservation.Candidate.PackageVersion, TransactionID: r.Reservation.TransactionID, Consumed: r.Consumed, Maximum: maxRecoveryLaunches, Stage: r.Stage, Reason: r.Reason, FailedAt: r.FailedAt, DueAt: r.DueAt, UpdatedAt: r.UpdatedAt}
}
func publishRecovery(ctx context.Context, storage *ProtectedStorage, r RecoveryV1) error {
	if storage == nil || storage.access != publicReadStorage {
		return errors.New("recovery status requires public protected storage")
	}
	if err := r.Validate(); err != nil {
		return err
	}
	data, err := json.Marshal(publicRecovery(r))
	if err != nil {
		return err
	}
	_, err = storage.WriteAtomic(ctx, []string{"recovery-v1.json"}, bytes.NewReader(data), maxStatusBytes, int64(len(data)), "")
	return err
}
