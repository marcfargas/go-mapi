//go:build windows

package main

import (
	"errors"

	"golang.org/x/sys/windows/registry"
)

const machineStartupValue = `go-mapi-user-machine-v4`

// The suite MSI owns HKLM startup. The interactive process can only observe
// its registration; per-user opt-out is enforced before queue startup.
type windowsMachineStartupRegistrationStore struct{}

func (windowsMachineStartupRegistrationStore) Read() (string, error) {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, standaloneStartupKey, registry.QUERY_VALUE)
	if err != nil {
		return "", err
	}
	defer key.Close()
	value, _, err := key.GetStringValue(machineStartupValue)
	return value, err
}

func (windowsMachineStartupRegistrationStore) Write(string) error {
	return errors.New("machine startup is owned by the suite MSI")
}

func (windowsMachineStartupRegistrationStore) Delete() error {
	return errors.New("machine startup is owned by the suite MSI")
}
