package mapi

import (
	"context"
	"errors"
)

const MachineAdmissionFileName = "suite-admission-v1"

var ErrMachineAdmissionClosed = errors.New("machine suite admission is closed or unavailable")

// MachineAdmissionOpen reads the service-owned projection under a shared lock.
// A false result always refuses admission, including when err is non-nil.
func MachineAdmissionOpen(ctx context.Context) (bool, error) {
	return withMachineAdmission(ctx, nil)
}

// WithMachineAdmission runs a short local admission action while retaining the
// shared byte lock. Callers must release it before doing operation work.
func WithMachineAdmission(ctx context.Context, fn func() error) error {
	if fn == nil {
		return errors.New("machine admission action is nil")
	}
	open, err := withMachineAdmission(ctx, fn)
	if err != nil {
		return err
	}
	if !open {
		return ErrMachineAdmissionClosed
	}
	return nil
}

func validMachineAdmissionByte(data []byte) (bool, error) {
	if len(data) != 1 {
		return false, ErrMachineAdmissionClosed
	}
	switch data[0] {
	case 'O':
		return true, nil
	case 'C':
		return false, nil
	default:
		return false, ErrMachineAdmissionClosed
	}
}
