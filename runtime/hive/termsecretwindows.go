// The same on Windows, through the console mode flags.

//go:build windows

package hive

import "syscall"

// termEchoOff turns the console's echo off and answers with what puts it back,
// or ok false where there is no console. Only the echo is cleared: the line
// input bit stays on, so the console still gathers a whole line and hands it
// over on Return — it just does not print it along the way.
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
