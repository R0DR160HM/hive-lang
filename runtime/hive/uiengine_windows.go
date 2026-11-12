// The memory a picture comes back through, on Windows.

//go:build windows

package hive

import (
	"errors"
	"os"
	"os/exec"
	"strconv"
	"syscall"
	"unsafe"
)

var (
	uiShareKernel = syscall.NewLazyDLL("kernel32.dll")
	uiShareCreate = uiShareKernel.NewProc("CreateFileMappingW")
	uiShareMap    = uiShareKernel.NewProc("MapViewOfFile")
	uiShareUnmap  = uiShareKernel.NewProc("UnmapViewOfFile")
)

type uiEngineShared struct {
	name   string
	bytes  []byte
	handle uintptr
	at     uintptr
}

func uiEngineShare(size int, serial int) (*uiEngineShared, error) {
	name := "Local\\hive-scene-" + strconv.Itoa(os.Getpid()) + "-" + strconv.Itoa(serial)
	wide, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return nil, err
	}
	handle, _, _ := uiShareCreate.Call(^uintptr(0), 0, 4, uintptr(uint64(size)>>32), uintptr(uint32(size)),
		uintptr(unsafe.Pointer(wide)))
	if handle == 0 {
		return nil, errors.New("no memory to share the picture through")
	}
	at, _, _ := uiShareMap.Call(handle, 6, 0, 0, uintptr(size))
	if at == 0 {
		syscall.CloseHandle(syscall.Handle(handle))
		return nil, errors.New("no memory to share the picture through")
	}
	return &uiEngineShared{name: name, handle: handle, at: at,
		bytes: unsafe.Slice((*byte)(*(*unsafe.Pointer)(unsafe.Pointer(&at))), size)}, nil
}

func (s *uiEngineShared) close() {
	uiShareUnmap.Call(s.at)
	syscall.CloseHandle(syscall.Handle(s.handle))
	s.bytes = nil
}

func uiEngineQuiet(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
}
