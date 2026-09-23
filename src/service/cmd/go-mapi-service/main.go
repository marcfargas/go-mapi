package main

import (
	"context"
	"os"

	service "github.com/marcfargas/go-mapi/service"
)

func main() {
	if _, err := service.ParseExecutableMode(os.Args[1:]); err != nil {
		os.Exit(2)
	}
	// Platform adapters are deliberately wired one milestone at a time. Until
	// the protected state and network adapters land, this is a cancellable idle
	// schedule rather than an updater with partial privileges.
	err := service.RunResidentService(service.ScheduleFunc(func(ctx context.Context) {
		<-ctx.Done()
	}))
	if err != nil {
		os.Exit(1)
	}
}
