// The Windows console, in every program built for Windows: escape sequences in
// what a program prints are painted rather than printed, as on every other
// terminal.

//go:build windows

package hive

import (
	"os"
	"syscall"
	"unsafe"
)

const (
	enableProcessedOutput           = 0x0001
	enableVirtualTerminalProcessing = 0x0004
	enableEchoInput                 = 0x0004
)

var (
	kernel32           = syscall.NewLazyDLL("kernel32.dll")
	procGetConsoleMode = kernel32.NewProc("GetConsoleMode")
	procSetConsoleMode = kernel32.NewProc("SetConsoleMode")
)

func init() {
	for _, stream := range []*os.File{os.Stdout, os.Stderr} {
		console := syscall.Handle(stream.Fd())
		if mode, ok := consoleMode(console); ok {
			setConsoleMode(console, mode|enableProcessedOutput|enableVirtualTerminalProcessing)
		}
	}
}

func consoleMode(console syscall.Handle) (uint32, bool) {
	var mode uint32
	done, _, _ := procGetConsoleMode.Call(
		uintptr(console),
		uintptr(unsafe.Pointer(&mode)),
	)
	return mode, done != 0
}

func setConsoleMode(console syscall.Handle, mode uint32) bool {
	done, _, _ := procSetConsoleMode.Call(uintptr(console), uintptr(mode))
	return done != 0
}
