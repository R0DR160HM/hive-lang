// Go's syscall package locks memory on these three alone.

//go:build !linux && !darwin && !windows

package hive

import "errors"

const secretLockable = false

func lockMemory(b []byte) error { return errors.New("this platform cannot lock memory") }

func unlockMemory(b []byte) {}
