package main

import (
	"context"
	"os"

	service "github.com/marcfargas/go-mapi/service"
)

func main() {
	invocation, err := service.ParseExecutableMode(os.Args[1:])
	if err != nil {
		os.Exit(2)
	}
	if invocation.Mode == service.ModeUpdateRunner {
		if err := service.RunProductionUpdateRunner(invocation.TransactionID); err != nil {
			os.Exit(1)
		}
		return
	}
	// Resident discovery/reconciliation composition is wired with the machine
	// products. Until then, keep SCM behavior cancellable rather than running a
	// partially composed privileged update check. The detached runner above is
	// complete and intentionally remains an unregistered one-shot mode.
	err = service.RunResidentService(service.ScheduleFunc(func(ctx context.Context) {
		<-ctx.Done()
	}))
	if err != nil {
		os.Exit(1)
	}
}
