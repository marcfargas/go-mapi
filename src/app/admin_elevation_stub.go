//go:build !windows

package main

import (
	"context"
	"errors"
)

type productionAdminAuthenticodeInspector struct{}

func (productionAdminAuthenticodeInspector) InspectAdminMSI(context.Context, string) (adminAuthenticodeIdentity, error) {
	return adminAuthenticodeIdentity{}, errors.New("Windows Authenticode verification is unavailable")
}

func handoffAuthorizedAdminMSI(context.Context, authorizedAdminMSICandidate) error {
	return errors.New("Windows elevation is unavailable")
}

func launchElevatedAdminHelper() (bool, error) { return false, errors.New("Windows elevation is unavailable") }

func stagePrivilegedAuthorizedAdminMSI(ctx context.Context, release authorizedAdminRelease, contents []byte) (string, func(), error) {
	return stageAuthorizedAdminMSI(ctx, release, contents)
}
