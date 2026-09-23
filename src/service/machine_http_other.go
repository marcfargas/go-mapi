//go:build !windows

package service

import "net/http"

func NewMachineHTTPClient() (*http.Client, error) {
	return nil, ErrMachineHTTPUnavailable
}
