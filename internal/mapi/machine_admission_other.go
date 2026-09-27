//go:build !windows

package mapi

import "context"

func withMachineAdmission(ctx context.Context, _ func() error) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	return false, ErrMachineAdmissionClosed
}
