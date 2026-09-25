//go:build windows

package main

func publicUpdateState(raw UpdateState) UpdateState {
	channel := updateDistributionChannel()
	return effectiveUpdateState(raw, channel, readPublicMachineStatus())
}
