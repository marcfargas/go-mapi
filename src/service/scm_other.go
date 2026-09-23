//go:build !windows

package service

import "errors"

func RunResidentService(Schedule) error {
	return errors.New("go-mapi system service requires Windows")
}
