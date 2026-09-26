// Package service coordinates authenticated machine-package updates.
//
// Platform adapters host this package in the Windows Service Control Manager,
// persist its state in protected storage, and launch the detached installer
// runner. The coordinator itself deliberately contains no SCM, filesystem,
// network, or process implementation.
package service
