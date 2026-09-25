package main

import (
	"errors"
	"fmt"
	"os"
	"syscall"

	service "github.com/marcfargas/go-mapi/service"
)

func main() {
	if len(os.Args) == 3 && os.Args[1] == "--verify-authenticode" {
		if err := service.RunAuthenticodeProbe(os.Args[2]); err != nil {
			var code syscall.Errno
			if errors.As(err, &code) {
				_, _ = fmt.Fprint(os.Stdout, uint32(code))
			}
			os.Exit(1)
		}
		return
	}
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
	if invocation.Mode == service.ModeBeginFinalUninstall || invocation.Mode == service.ModeRollbackFinalUninstall {
		if err := service.RunFinalUninstallFence(invocation.Mode); err != nil {
			os.Exit(1)
		}
		return
	}
	schedule, err := service.NewProductionResidentSchedule()
	if err != nil {
		os.Exit(1)
	}
	err = service.RunResidentService(schedule)
	if err != nil {
		os.Exit(1)
	}
}
