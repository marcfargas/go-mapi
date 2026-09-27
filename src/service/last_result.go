package service

import (
	"errors"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

const LastResultSchemaV1 = "go-mapi-service-last-result-v1"

// LastResultV1 is the bounded, private terminal witness retained after the
// pending transaction has been retired. It contains no path or release URL.
type LastResultV1 struct {
	Schema        string        `json:"schema"`
	TransactionID string        `json:"transactionId"`
	SKU           update.SKU    `json:"sku"`
	Result        Result        `json:"result"`
	Sequence      uint64        `json:"sequence"`
	Digest        string        `json:"digest"`
	FinishedAt    time.Time     `json:"finishedAt"`
	Exit          *ExitEvidence `json:"exit,omitempty"`
}

func (result LastResultV1) Validate() error {
	if result.Schema != LastResultSchemaV1 || !transactionIDPattern.MatchString(result.TransactionID) ||
		(result.SKU != update.System && result.SKU != update.Suite) ||
		(result.Result != ResultInstalled && result.Result != ResultRolledBack && result.Result != ResultBusyExhausted &&
			!(result.SKU == update.Suite && result.Result == ResultAmbiguous)) ||
		result.Sequence == 0 || !validSHA256(result.Digest) || result.FinishedAt.IsZero() {
		return errors.New("invalid last transaction result")
	}
	if result.Exit != nil && (result.Result != ResultAmbiguous || result.Exit.ObservedAt.IsZero()) {
		return errors.New("invalid original installer exit evidence")
	}
	return nil
}

func lastResultFromPending(pending PendingV1) LastResultV1 {
	return LastResultV1{Schema: LastResultSchemaV1, TransactionID: pending.TransactionID,
		SKU: pending.SKU, Result: pending.Result, Sequence: pending.Replay.Sequence,
		Digest: pending.Replay.Digest, FinishedAt: pending.UpdatedAt, Exit: func() *ExitEvidence {
			if pending.Result != ResultAmbiguous || pending.Exit == nil {
				return nil
			}
			copy := *pending.Exit
			return &copy
		}()}
}
