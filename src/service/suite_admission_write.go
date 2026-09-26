package service

import (
	"errors"
	"fmt"
)

type suiteByteFile interface {
	WriteAt([]byte, int64) (int, error)
	Truncate(int64) error
	Sync() error
}

// writeSuiteByte leaves C (or an unreadable zero-length file) after any
// unsuccessful write. unsafe means even that recovery could not be proved;
// the Windows caller retains its exclusive lock for the service lifetime.
func writeSuiteByte(file suiteByteFile, value byte) (unsafe bool, err error) {
	if value != 'O' && value != 'C' {
		return false, errors.New("invalid suite admission value")
	}
	write := func(b byte) error {
		n, err := file.WriteAt([]byte{b}, 0)
		if err != nil {
			return err
		}
		if n != 1 {
			return fmt.Errorf("short suite admission write: %d", n)
		}
		if err := file.Truncate(1); err != nil {
			return err
		}
		return file.Sync()
	}
	if err := write(value); err != nil {
		if closedErr := write('C'); closedErr == nil {
			return false, err
		} else {
			// A malformed length is also rejected by every reader. If even
			// this fails, keeping the exclusive handle is the only live guard.
			truncateErr := file.Truncate(0)
			var syncErr error
			if truncateErr == nil {
				syncErr = file.Sync()
			}
			if truncateErr == nil && syncErr == nil {
				return false, errors.Join(err, fmt.Errorf("restore C: %w", closedErr))
			}
			return true, errors.Join(err, fmt.Errorf("restore C: %w", closedErr), truncateErr, syncErr)
		}
	}
	return false, nil
}
