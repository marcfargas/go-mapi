//go:build !windows

package service

import "errors"

func RunProductionUpdateRunner(string) error {
	return errors.New("go-mapi update runner requires Windows")
}

func RunAuthenticodeProbe(string) error {
	return errors.New("Windows Authenticode requires Windows")
}
