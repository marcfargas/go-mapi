//go:build !windows

package service

import "errors"

func NewProductionResidentSchedule() (Schedule, error) {
	return nil, errors.New("resident service is only supported on Windows")
}
