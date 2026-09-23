package main

import (
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
	schedule, err := service.NewProductionResidentSchedule()
	if err != nil {
		os.Exit(1)
	}
	err = service.RunResidentService(schedule)
	if err != nil {
		os.Exit(1)
	}
}
