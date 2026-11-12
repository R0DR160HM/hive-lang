// And on Linux.

//go:build linux && !android

package hive

import (
	"os"
	"os/exec"
	"strconv"
	"syscall"
)

type uiEngineShared struct {
	name  string
	bytes []byte
}

func uiEngineShare(size int, serial int) (*uiEngineShared, error) {
	dir := "/dev/shm"
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		dir = os.TempDir()
	}
	name := dir + "/hive-scene-" + strconv.Itoa(os.Getpid()) + "-" + strconv.Itoa(serial)
	f, err := os.OpenFile(name, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if err := f.Truncate(int64(size)); err != nil {
		os.Remove(name)
		return nil, err
	}
	bytes, err := syscall.Mmap(int(f.Fd()), 0, size, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_SHARED)
	if err != nil {
		os.Remove(name)
		return nil, err
	}
	return &uiEngineShared{name: name, bytes: bytes}, nil
}

func (s *uiEngineShared) close() {
	syscall.Munmap(s.bytes)
	os.Remove(s.name)
	s.bytes = nil
}

func uiEngineQuiet(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
}
