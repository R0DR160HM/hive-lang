package hive

import "syscall"

func alive(pid int) bool {
	const synchronize = 0x00100000
	process, err := syscall.OpenProcess(synchronize, false, uint32(pid))
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(process)
	waited, _ := syscall.WaitForSingleObject(process, 0)
	return waited == syscall.WAIT_TIMEOUT
}
