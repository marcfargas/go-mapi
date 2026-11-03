package service

import (
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/marcfargas/go-mapi/internal/mapi"
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
// not accept embedded credentials or request bodies. Forwarded headers are
// public release-track and installed-version routing hints, never authorization.
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
	_, err := machineHTTPForwardHeader(request, MachineReleaseMetadataOrigin)
	return err
}

func machineHTTPForwardHeader(request *http.Request, metadataOrigin string) (string, error) {
	if request == nil || request.URL == nil {
		return "", ErrMachineHTTPInvalidRequest
	}
	if len(request.Header) == 0 {
		return "", nil
	}
	if len(request.Header) > 2 || request.Method != http.MethodGet || request.URL.RawQuery != "" || request.URL.ForceQuery ||
		request.URL.EscapedPath() != request.URL.Path ||
		request.URL.Path != "/machine/system/targets.json" && request.URL.Path != "/machine/suite/targets.json" {
		return "", ErrMachineHTTPInvalidRequest
	}
	origin, err := url.Parse(metadataOrigin)
	if err != nil || origin.Scheme != "https" || origin.Host == "" || origin.User != nil || origin.Opaque != "" || origin.RawQuery != "" || origin.Fragment != "" ||
		origin.Path != "" && origin.Path != "/" || !strings.EqualFold(request.URL.Host, origin.Host) || request.URL.Scheme != origin.Scheme {
		return "", ErrMachineHTTPInvalidRequest
	}
	var track, version string
	for name, values := range request.Header {
		if len(values) != 1 || strings.ContainsAny(values[0], "\r\n\x00") {
			return "", ErrMachineHTTPInvalidRequest
		}
		switch {
		case strings.EqualFold(name, "X-Go-Mapi-Release-Track"):
			if track != "" || values[0] != "stable" && values[0] != "development" {
				return "", ErrMachineHTTPInvalidRequest
			}
			track = values[0]
		case strings.EqualFold(name, "X-Go-Mapi-Installed-Version"):
			if _, err := mapi.NewMachinePackageIdentity(mapi.MachineSKUSystem, values[0]); err != nil || version != "" {
				return "", ErrMachineHTTPInvalidRequest
			}
			version = values[0]
		default:
			return "", ErrMachineHTTPInvalidRequest
		}
	}
	if track == "" || version != "" && mapi.ReleaseTrack(version) != track {
		return "", ErrMachineHTTPInvalidRequest
	}
	forwarded := "X-Go-Mapi-Release-Track: " + track + "\r\n"
	if version != "" {
		forwarded += "X-Go-Mapi-Installed-Version: " + version + "\r\n"
	}
	return forwarded, nil
}
