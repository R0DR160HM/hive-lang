// Turning the echo off on a Unix terminal: `tcgetattr`, clear `ECHO`,
// `tcsetattr`, and put it back. One of these two files is left out of the build
// by the tag at the top of it.

//go:build !windows

package hive

import (
	"os"
	"os/exec"
)

// termEchoOff turns the terminal's echo off and answers with what puts it back,
// or ok false if there is no terminal to turn it off on.
//
// The setting belongs to the device rather than to any one file description, so
// any of these reaches it: /dev/tty for a program run from a shell; standard
// error for one under hive run, which has no controlling terminal but does get
// the compiler's stderr passed straight through; standard input otherwise.
//
// stty rather than an ioctl of our own: the termios request numbers differ
// between Linux and the BSDs, where the command is the same on every unix.
func termEchoOff() (func(), bool) {
	if tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0); err == nil {
		if stty(tty, "-echo") {
			return func() {
				stty(tty, "echo")
				tty.Close()
			}, true
		}
		tty.Close()
	}
	for _, stream := range []*os.File{os.Stderr, os.Stdin} {
		if stty(stream, "-echo") {
			terminal := stream
			return func() { stty(terminal, "echo") }, true
		}
	}
	return nil, false
}

// stty applies one terminal setting to tty, which it hands over as the standard
// input of the command — the terminal stty acts on is its own — and reports
// whether that worked.
func stty(tty *os.File, setting string) bool {
	command := exec.Command("stty", setting)
	command.Stdin = tty
	return command.Run() == nil
}
