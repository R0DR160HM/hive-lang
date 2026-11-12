// The Go for `hive.term.readSecret`: the same read as `read`, with the terminal's
// echo turned off. The echo is put back before the call returns — and also if the
// program is interrupted at the prompt, which is the part worth having.
package hive

import (
	"fmt"
	"os"
	"os/signal"
	"runtime"
	"sync"
	"syscall"
)

// How many reads are in progress with the echo turned off, so two virtual
// threads asking for a secret at once turn it off once and put it back once:
// the first to finish must not uncover what the other is still typing.
var (
	echoMu      sync.Mutex
	echoReaders int
	echoRestore func()
	interrupts  chan os.Signal
)

// readHidden reads a line as TermRead does, with the terminal's echo turned off
// while it waits, a byte at a time into what alloc hands out so the line is
// never a Go string. Returns it without the trailing newline and parks only the
// calling virtual thread. Backs hive.term.readSecret, into locked memory, and
// hive.term.readSecretBypass, into ordinary memory.
//
// The echo belongs to the terminal rather than to standard input: under hive run
// the line is typed at the compiler's terminal and reaches this program through
// a relay file (see TermRead). Where there is no terminal, the line is read all
// the same and only the hiding of it is lost.
func TermReadSecret() Result[Secret, SecretError] { return readHidden(newSecret) }

func TermReadSecretBypass() Secret { return readHidden(unlockedSecret).Ok() }

func readHidden(alloc func(int) (Secret, *SecretError)) Result[Secret, SecretError] {
	hidden := hideEcho()
	typed, failed := alloc(64)
	n := 0
	for {
		c, err := termInput.ReadByte()
		if err != nil || c == '\n' {
			break
		}

		// A line too long to lock is still read to its end, so what follows it is not
		// taken for the next line.
		if failed != nil {
			continue
		}
		if n == len(typed.bytes()) {
			bigger, err := alloc(2 * n)
			if err != nil {
				failed = err
				continue
			}
			copy(bigger.bytes(), typed.bytes())
			typed = bigger
		}
		typed.bytes()[n] = c
		n++
	}
	showEcho()

	// The Return that ended the line was not echoed either, so the cursor is
	// still sitting at the end of the prompt. Move it on, as the echo of that
	// Return would have.
	if hidden {
		fmt.Println()
	}
	if failed != nil {
		return Err[Secret, SecretError](*failed)
	}
	for n > 0 && typed.bytes()[n-1] == '\r' {
		n--
	}
	line, err := alloc(n)
	if err != nil {
		return Err[Secret, SecretError](*err)
	}
	copy(line.bytes(), typed.bytes()[:n])
	runtime.KeepAlive(typed)
	return Ok[Secret, SecretError](line)
}

// hideEcho turns the echo off for this read and reports whether it is off —
// false where there is no terminal, and so a visible read for the caller to
// account for. Paired with showEcho.
func hideEcho() bool {
	echoMu.Lock()
	defer echoMu.Unlock()
	if echoReaders == 0 {
		if restore, ok := termEchoOff(); ok {
			echoRestore = restore
			catchInterrupts()
		}
	}
	echoReaders++
	return echoRestore != nil
}

// showEcho puts the echo back once the last of the reads holding it off is done.
func showEcho() {
	echoMu.Lock()
	defer echoMu.Unlock()
	echoReaders--
	if echoReaders == 0 {
		restoreEcho()
	}
}

// restoreEcho puts the echo back and stops watching for interrupts. Called with
// echoMu held. Stopping before closing is what keeps the signal package from
// ever sending down a channel that is already closed.
func restoreEcho() {
	if interrupts != nil {
		signal.Stop(interrupts)
		close(interrupts)
		interrupts = nil
	}
	if echoRestore != nil {
		echoRestore()
		echoRestore = nil
	}
}

// catchInterrupts watches, for as long as the echo is off, for the signals that
// would otherwise end the program on the spot. A terminal left with its echo
// off shows nothing of what is typed into the shell that gets it back, so the
// program still ends — after putting the echo back. Called with echoMu held.
//
// Closed rather than signalled: the read finished on its own and has
// put the echo back already.
func catchInterrupts() {
	interrupts = make(chan os.Signal, 1)
	signal.Notify(interrupts, os.Interrupt, syscall.SIGTERM)
	go func(caught chan os.Signal) {
		if _, ok := <-caught; !ok {
			return
		}
		echoMu.Lock()
		restoreEcho()
		echoMu.Unlock()

		// The status a shell reports for a program an interrupt ended.
		os.Exit(130)
	}(interrupts)
}
