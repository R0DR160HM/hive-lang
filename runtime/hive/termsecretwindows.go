// The same on Windows, through the console mode flags.

//go:build windows

package hive

import (
	"syscall"
	"unsafe"
)

// The console input mode bit that shows what is typed. Only it is cleared: the
// line input bit stays on, so the console still gathers a whole line and hands
// it over on Return — it just does not print it along the way.
const enableEchoInput = 0x0004

var (
	kernel32           = syscall.NewLazyDLL("kernel32.dll")
	procGetConsoleMode = kernel32.NewProc("GetConsoleMode")
	procSetConsoleMode = kernel32.NewProc("SetConsoleMode")
)

// termEchoOff turns the console's echo off and answers with what puts it back,
// or ok false where there is no console.
//
// CONIN$ names the console's input buffer, which every process attached to the
// console shares — under hive run that includes the compiler, which is the one
// actually reading what is typed.
func termEchoOff() (func(), bool) {
	console, err := syscall.Open("CONIN$", syscall.O_RDWR, 0)
	if err != nil {
		return nil, false
	}
	mode, ok := consoleMode(console)
	if !ok || !setConsoleMode(console, mode&^enableEchoInput) {
		syscall.Close(console)
		return nil, false
	}
	return func() {
		setConsoleMode(console, mode)
		syscall.Close(console)
	}, true
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
