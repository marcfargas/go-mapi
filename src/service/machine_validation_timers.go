package service

import (
	"errors"
	"strconv"
	"time"
)

// Controlled validation builds link these values so hosted CI does not wait on
// production timers. All three are empty in every production build; a build
// that sets one must set all three. Each may only shorten its production value
// (two-minute startup delay, one-minute heartbeat, 15-minute first failure
// delay) and none may be below one second. src/service/build.ps1 rejects them
// under -RequireMachineReleaseTrust, and the release provenance carries none.
var (
	MachineValidationStartupDelaySeconds string
	MachineValidationHeartbeatSeconds    string
	MachineValidationFailureBaseSeconds  string
)

const (
	productionResidentInitialDelay = 2 * time.Minute
	productionResidentHeartbeat    = time.Minute
	productionFailureDelayBase     = 15 * time.Minute
	productionMinCheckInterval     = time.Minute
	validationMinTimer             = time.Second
)

// machineValidationTimers is the validated, immutable timer set of a controlled
// validation build.
type machineValidationTimers struct {
	StartupDelay     time.Duration
	Heartbeat        time.Duration
	FailureDelayBase time.Duration
}

// loadMachineValidationTimers reports whether this build carries the validation
// timer set. Production builds return present=false and no error.
func loadMachineValidationTimers() (timers machineValidationTimers, present bool, err error) {
	values := [3]string{MachineValidationStartupDelaySeconds, MachineValidationHeartbeatSeconds, MachineValidationFailureBaseSeconds}
	set := 0
	for _, value := range values {
		if value != "" {
			set++
		}
	}
	if set == 0 {
		return machineValidationTimers{}, false, nil
	}
	if set != len(values) {
		return machineValidationTimers{}, false, errors.New("incomplete machine validation timer set")
	}
	limits := [3]time.Duration{productionResidentInitialDelay, productionResidentHeartbeat, productionFailureDelayBase}
	var parsed [3]time.Duration
	for i, value := range values {
		seconds, convErr := strconv.Atoi(value)
		if convErr != nil || seconds < 1 {
			return machineValidationTimers{}, false, errors.New("invalid machine validation timer")
		}
		parsed[i] = time.Duration(seconds) * time.Second
		if parsed[i] < validationMinTimer || parsed[i] > limits[i] {
			return machineValidationTimers{}, false, errors.New("machine validation timer does not shorten the production value")
		}
	}
	return machineValidationTimers{StartupDelay: parsed[0], Heartbeat: parsed[1], FailureDelayBase: parsed[2]}, true, nil
}

// applyResidentTimers sets the resident schedule timers once at start-up. A
// build without the validation set keeps the production values.
func applyResidentTimers(timers machineValidationTimers, present bool) {
	if !present {
		return
	}
	residentInitialDelay = timers.StartupDelay
	residentHeartbeatInterval = timers.Heartbeat
}
