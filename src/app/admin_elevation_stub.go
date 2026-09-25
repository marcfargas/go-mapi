//go:build !windows

package main

import (
	"context"
	"errors"
	"io"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

func verifyAdminMSI(context.Context, string) error {
	return errors.New("Windows Authenticode verification is unavailable")
}
func handoffAdminMSI(context.Context, update.Prepared) error {
	return errors.New("Windows elevation is unavailable")
}
func launchElevatedAdminHelper() (bool, error) {
	return false, errors.New("Windows elevation is unavailable")
}
func stagePrivilegedAdminMSI(context.Context, update.Candidate, func(io.Writer) error) (string, func(), error) {
	return "", nil, errors.New("protected Windows staging is unavailable")
}
