package service

import (
	"errors"
	"net/url"
	"strconv"
	"time"
)

// MachineReleaseMetadataOrigin is fixed at build time. An empty development
// build continues local health checks without remote update discovery.
var MachineReleaseMetadataOrigin string

// Version is linked into the resident executable by the release build.
var Version string

// MachineCheckIntervalSeconds is an immutable build value. Production builds
// pin it to six hours; controlled validation builds may use a shorter interval.
var MachineCheckIntervalSeconds string

func machineCheckInterval() (time.Duration, error) {
	if MachineCheckIntervalSeconds == "" {
		return 6 * time.Hour, nil
	}
	seconds, err := strconv.Atoi(MachineCheckIntervalSeconds)
	if err != nil || seconds < 60 || seconds > 24*3600 {
		return 0, errors.New("invalid machine check cadence")
	}
	return time.Duration(seconds) * time.Second, nil
}

var ErrMachineTrustUnavailable = errors.New("embedded machine metadata origin is unavailable")

func EmbeddedMachineMetadataOrigin() (string, error) {
	if MachineReleaseMetadataOrigin == "" {
		return "", ErrMachineTrustUnavailable
	}
	if len(MachineReleaseMetadataOrigin) > 256 {
		return "", errors.New("invalid machine metadata origin")
	}
	origin, err := url.Parse(MachineReleaseMetadataOrigin)
	if err != nil || origin.Scheme != "https" || origin.Host == "" || origin.User != nil || origin.Opaque != "" || origin.RawQuery != "" || origin.Fragment != "" || origin.Path != "" && origin.Path != "/" {
		return "", errors.New("invalid machine metadata origin")
	}
	return origin.String(), nil
}
