// Raw mode, the console's keys and the window's size on Windows.

//go:build windows

package hive

import (
	"os"
	"syscall"
	"unicode/utf16"
	"unsafe"
)

const (
	enableProcessedInput       = 0x0001
	enableLineInput            = 0x0002
	enableVirtualTerminalInput = 0x0200
)

var (
	procReadConsoleW               = kernel32.NewProc("ReadConsoleW")
	procGetConsoleScreenBufferInfo = kernel32.NewProc("GetConsoleScreenBufferInfo")
)

// termRawOn clears the console's echo, line and Ctrl+C handling on standard input
// and asks for keys as the escape sequences every other terminal sends.
func termRawOn() (func(), *TermTermError) {
	console := syscall.Handle(os.Stdin.Fd())
	mode, ok := consoleMode(console)
	if !ok {
		failed := termError("NotATerminal", "standard input is not a console")
		return nil, &failed
	}
	raw := mode&^(enableEchoInput|enableLineInput|enableProcessedInput) | enableVirtualTerminalInput
	if !setConsoleMode(console, raw) {
		failed := termError("Io", "the console would not take raw mode")
		return nil, &failed
	}
	return func() { setConsoleMode(console, mode) }, nil
}

// A half of a character the last read ended on, kept for the next.
var consoleHalf []uint16

// termConsoleRead reads the console itself where standard input is one, since
// Go's own read of a console takes Ctrl+Z for the end of the input.
func termConsoleRead() ([]byte, bool, error) {
	console := syscall.Handle(os.Stdin.Fd())
	if _, ok := consoleMode(console); !ok {
		return nil, false, nil
	}
	var buf [512]uint16
	var n uint32
	done, _, err := procReadConsoleW.Call(
		uintptr(console),
		uintptr(unsafe.Pointer(&buf[0])),
		uintptr(len(buf)),
		uintptr(unsafe.Pointer(&n)),
		0,
	)
	if done == 0 {
		return nil, true, err
	}
	units := append(consoleHalf, buf[:n]...)
	consoleHalf = nil
	if last := len(units) - 1; last >= 0 && utf16.IsSurrogate(rune(units[last])) && units[last] < 0xdc00 {
		consoleHalf = []uint16{units[last]}
		units = units[:last]
	}
	return []byte(string(utf16.Decode(units))), true, nil
}

type consoleCoord struct{ x, y int16 }

type consoleScreen struct {
	size       consoleCoord
	cursor     consoleCoord
	attributes uint16
	left       int16
	top        int16
	right      int16
	bottom     int16
	maximum    consoleCoord
}

func termWindow() (TermSize, bool) {
	var screen consoleScreen
	done, _, _ := procGetConsoleScreenBufferInfo.Call(
		uintptr(syscall.Handle(os.Stdout.Fd())),
		uintptr(unsafe.Pointer(&screen)),
	)
	if done == 0 {
		return TermSize{}, false
	}
	return TermSize{
		Width:  int(screen.right-screen.left) + 1,
		Height: int(screen.bottom-screen.top) + 1,
	}, true
}
