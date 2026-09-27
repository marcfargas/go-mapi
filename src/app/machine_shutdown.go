package main

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

var errMachineDraining = errors.New("machine installation is updating or unavailable; try again later")

// machineOperations counts only operations admitted while the service's byte
// lock was shared. The lock is released before any operation I/O begins.
type machineOperations struct {
	mu      sync.Mutex
	active  int
	closing bool
	drained chan struct{}
	gate    func(context.Context, func() error) error
}

func (o *machineOperations) begin(ctx context.Context) (func(), error) {
	gate := o.gate
	if gate == nil {
		gate = mapi.WithMachineAdmission
	}
	err := gate(ctx, func() error {
		o.mu.Lock()
		defer o.mu.Unlock()
		if o.closing {
			return errMachineDraining
		}
		o.active++
		return nil
	})
	if err != nil {
		return nil, errMachineDraining
	}
	return func() {
		o.mu.Lock()
		o.active--
		if o.closing && o.active == 0 {
			close(o.drained)
		}
		o.mu.Unlock()
	}, nil
}

func (o *machineOperations) close() <-chan struct{} {
	o.mu.Lock()
	defer o.mu.Unlock()
	if !o.closing {
		o.closing = true
		o.drained = make(chan struct{})
		if o.active == 0 {
			close(o.drained)
		}
	}
	return o.drained
}

func (o *machineOperations) isClosing() bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.closing
}

func (a *App) beginMachineOperation(ctx context.Context) (func(), error) {
	if AppDistribution != "machine" {
		return func() {}, nil
	}
	return a.machineOperations.begin(ctx)
}

// startMachineDrain is called before queue and UI initialization. A refusal is
// latched; admitted work then drains without cancelling shutdownCtx or OAuth.
func (a *App) startMachineDrain() bool {
	if AppDistribution != "machine" {
		return true
	}
	open, err := a.readMachineAdmission(context.Background())
	if err != nil || !open {
		a.machineOperations.close()
		return false
	}
	go func() {
		ticks := a.machineDrainTicks
		if ticks == nil {
			ticker := time.NewTicker(250 * time.Millisecond)
			defer ticker.Stop()
			ticks = ticker.C
		}
		for {
			select {
			case <-a.shutdownCtx.Done():
				return
			case <-ticks:
				open, err := a.readMachineAdmission(a.shutdownCtx)
				if err == nil && open {
					continue
				}
				logInfo("machine suite admission closed; draining admitted operations")
				<-a.machineOperations.close()
				a.requestMachineQuit()
				return
			}
		}
	}()
	return true
}

func (a *App) readMachineAdmission(ctx context.Context) (bool, error) {
	if a.machineAdmissionOpen != nil {
		return a.machineAdmissionOpen(ctx)
	}
	return mapi.MachineAdmissionOpen(ctx)
}

// Startup crosses several initialization phases after Wails OnStartup. Check
// again immediately before opening the queue and scheduling automatic work.
// A bootstrap callback already admitted in an earlier phase must settle before
// this late refusal asks Wails to quit.
func (a *App) machineStartupCanProceed() bool {
	if AppDistribution != "machine" {
		return true
	}
	open, err := a.readMachineAdmission(context.Background())
	if err == nil && open && !a.machineOperations.isClosing() {
		return true
	}
	drained := a.machineOperations.close()
	go func() {
		<-drained
		a.requestMachineQuit()
	}()
	return false
}

func (a *App) requestMachineQuit() {
	a.machineQuitOnce.Do(func() {
		if a.machineQuit != nil {
			a.machineQuit()
		} else {
			a.requestQuit()
		}
	})
}
