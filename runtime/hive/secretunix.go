//go:build linux || darwin

package hive

import (
	"errors"
	"syscall"
)

const secretLockable = true

func lockMemory(b []byte) error {
	if err := syscall.Mlock(b); err != nil {
		return errors.New(err.Error() + " (the locked-memory limit is ulimit -l)")
	}
	return nil
}

func unlockMemory(b []byte) { syscall.Munlock(b) }
