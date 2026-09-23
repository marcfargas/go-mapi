package main

func isMachineStartup(args []string) bool {
	return len(args) == 2 && args[0] == "--startup" && args[1] == "--machine-install"
}

func hasMachineStartupArgument(args []string) bool {
	for _, arg := range args {
		if arg == "--machine-install" {
			return true
		}
	}
	return false
}
