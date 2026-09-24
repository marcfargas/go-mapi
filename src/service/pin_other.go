//go:build !windows

package service

func pinVerifiedFile(path string) (func(), error) {
	// Native path locking is a Windows execution invariant. Portable tests use
	// fake artifact names and exercise the coordinator and runner state machine.
	return func() {}, nil
}
