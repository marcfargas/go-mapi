//go:build windows

package service

import (
	"context"

	"golang.org/x/sys/windows/svc"
)

func RunResidentService(schedule Schedule) error {
	return svc.Run(ServiceName, scmHandler{host: Host{Schedule: schedule}})
}

type scmHandler struct {
	host Host
}

func (handler scmHandler) Execute(_ []string, requests <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	// Buffer startup/control crossings so an early SCM stop cannot deadlock
	// against the host's initial status report.
	controls := make(chan Control, 1)
	statuses := make(chan HostStatus, 3)
	done := make(chan error, 1)
	go func() { done <- handler.host.Run(context.Background(), controls, statuses) }()

	current := svc.Status{State: svc.StartPending}
	for {
		select {
		case status := <-statuses:
			current = windowsServiceStatus(status)
			changes <- current
		case request := <-requests:
			switch request.Cmd {
			case svc.Interrogate:
				changes <- current
			case svc.Stop:
				controls <- ControlStop
			case svc.Shutdown:
				controls <- ControlShutdown
			}
		case err := <-done:
			if err != nil {
				return true, 1
			}
			return false, 0
		}
	}
}

func windowsServiceStatus(status HostStatus) svc.Status {
	result := svc.Status{}
	switch status.State {
	case HostStartPending:
		result.State = svc.StartPending
	case HostRunning:
		result.State = svc.Running
	case HostStopPending:
		result.State = svc.StopPending
	}
	if status.Accepts&AcceptStop != 0 {
		result.Accepts |= svc.AcceptStop
	}
	if status.Accepts&AcceptShutdown != 0 {
		result.Accepts |= svc.AcceptShutdown
	}
	return result
}
