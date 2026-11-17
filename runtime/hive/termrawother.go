// Where there is no terminal at all — a program built for a browser, as
// WebAssembly — raw mode and the window's size are not to be had, and input is
// read as any file is.

//go:build !unix && !windows

package hive

func termRawOn() (func(), *TermTermError) {
	failed := termError("NotATerminal", "there is no terminal here")
	return nil, &failed
}

func termWindow() (TermSize, bool) { return TermSize{}, false }

func termConsoleRead() ([]byte, bool, error) { return nil, false, nil }
