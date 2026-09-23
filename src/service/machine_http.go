package service

import (
	"errors"
	"fmt"
	"net/http"
)

var (
	ErrMachineHTTPUnavailable     = fmt.Errorf("%w: machine HTTP transport unavailable", ErrOffline)
	ErrMachineHTTPFailure         = fmt.Errorf("%w: machine HTTP request failed", ErrOffline)
	ErrMachineProxyAuthentication = fmt.Errorf("%w: machine proxy authentication required", ErrOffline)
	ErrMachineHTTPInvalidRequest  = errors.New("machine HTTP request is not permitted")
)

const (
	machineHTTPResolveTimeoutMS = 15_000
	machineHTTPConnectTimeoutMS = 15_000
	machineHTTPSendTimeoutMS    = 30_000
	machineHTTPReceiveTimeoutMS = 30_000
)

// validateMachineHTTPRequest closes the privileged adapter over the one
// operation needed by authenticated release discovery and download. It does
// not accept embedded credentials or request bodies.
func validateMachineHTTPRequest(request *http.Request) error {
	if request == nil || request.URL == nil || request.URL.Scheme != "https" || request.URL.Host == "" || request.URL.User != nil || request.URL.Opaque != "" || request.URL.Fragment != "" {
		return ErrMachineHTTPInvalidRequest
	}
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		return ErrMachineHTTPInvalidRequest
	}
	if request.Body != nil && request.Body != http.NoBody {
		return ErrMachineHTTPInvalidRequest
	}
	if request.Header.Get("Authorization") != "" || request.Header.Get("Proxy-Authorization") != "" || request.Header.Get("Cookie") != "" {
		return ErrMachineHTTPInvalidRequest
	}
	return nil
}
