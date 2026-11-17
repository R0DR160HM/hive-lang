//go:build unix

package hive

import "syscall"

// A process that was killed and whose parent is gone is reaped by init; until
// then signal 0 still finds it, which is why the caller asks more than once.
func alive(pid int) bool {
	return syscall.Kill(pid, 0) == nil
}
