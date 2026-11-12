// ponytail: the lockable total is the minimum working set (about 200 KB by default); SetProcessWorkingSetSize raises it.

//go:build windows

package hive

import (
	"errors"
	"syscall"
	"unsafe"
)

const secretLockable = true

func lockMemory(b []byte) error {
	if err := syscall.VirtualLock(uintptr(unsafe.Pointer(&b[0])), uintptr(len(b))); err != nil {
		return errors.New(err.Error() + " (the limit is the process's minimum working set)")
	}
	return nil
}

func unlockMemory(b []byte) {
	syscall.VirtualUnlock(uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)))
}
