// Raw mode and the window's size on a Unix terminal.

//go:build unix

package hive

import (
	"errors"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"unsafe"
)

// termRawOn puts standard input's terminal in raw mode, keeping output
// processing on, and answers with what puts it back.
//
// stty rather than termios of our own, as for the echo: the request numbers
// differ between Linux and the BSDs, where the command is the same everywhere.
func termRawOn() (func(), *TermTermError) {
	if info, err := os.Stdin.Stat(); err != nil || info.Mode()&os.ModeCharDevice == 0 {
		failed := termError("NotATerminal", "standard input is not a terminal")
		return nil, &failed
	}
	saved, err := sttyAnswer("-g")
	if err != nil {
		failed := termError("NotATerminal", "standard input is not a terminal")
		if errors.Is(err, exec.ErrNotFound) {
			failed = termError("Io", "stty is not on the PATH")
		}
		return nil, &failed
	}
	if _, err := sttyAnswer("raw", "-echo", "opost"); err != nil {
		failed := termError("Io", err.Error())
		return nil, &failed
	}
	return func() { sttyAnswer(saved) }, nil
}

func sttyAnswer(settings ...string) (string, error) {
	command := exec.Command("stty", settings...)
	command.Stdin = os.Stdin
	out, err := command.Output()
	return strings.TrimSpace(string(out)), err
}

func termWindow() (TermSize, bool) {
	var size struct{ rows, cols, x, y uint16 }
	_, _, failed := syscall.Syscall(syscall.SYS_IOCTL, os.Stdout.Fd(), uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&size)))
	if failed != 0 || size.cols == 0 || size.rows == 0 {
		return TermSize{}, false
	}
	return TermSize{Width: int(size.cols), Height: int(size.rows)}, true
}

// A terminal here is read as any file is.
func termConsoleRead() ([]byte, bool, error) { return nil, false, nil }
