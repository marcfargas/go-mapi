package main

import (
	"errors"
	"fmt"
	"os"

	"github.com/zalando/go-keyring"
)

// purgeUserData is intentionally reachable only through the explicit
// --purge-user-data command used by the standalone uninstaller's confirmed
// remove-all option. Ordinary uninstall never calls it.
func purgeUserData() error {
	return purgeUserDataWithStore(realKeyringStore{})
}

func purgeUserDataWithStore(store KeyringStore) error {
	var errs []error
	if err := store.Delete(keyringService, keyringUser); err != nil && !errors.Is(err, keyring.ErrNotFound) {
		errs = append(errs, fmt.Errorf("delete credential: %w", err))
	}
	for _, path := range []string{watcherDir(), appDataDir()} {
		if err := os.RemoveAll(path); err != nil {
			errs = append(errs, fmt.Errorf("remove %s: %w", path, err))
		}
	}
	return errors.Join(errs...)
}
