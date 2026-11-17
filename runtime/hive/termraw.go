// The Go for hive.term.raw, readKey and size: the terminal a key at a time.
// Turning raw mode on and off, reading the console and measuring the window
// differ per platform, and the tag atop termrawunix.go and termrawwindows.go
// leaves one of them out of the build.
package hive

import (
	"errors"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"unicode/utf8"
)

func termError(reason, message string) TermTermError {
	return TermTermError{Reason: reason, Message: message}
}

var rawMode struct {
	mu         sync.Mutex
	restore    func()
	signals    chan os.Signal
	registered bool
}

// TermRaw turns raw mode on or off. On: what is typed is neither shown nor held
// back for a whole line, and Ctrl+C arrives as a key rather than ending the
// program. Output is untouched, so a newline still starts the next line.
func TermRaw(on bool) Result[bool, TermTermError] {
	rawMode.mu.Lock()
	defer rawMode.mu.Unlock()
	if !on {
		termRawOff()
		return Ok[bool, TermTermError](true)
	}
	if rawMode.restore != nil {
		return Ok[bool, TermTermError](true)
	}
	restore, failed := termRawOn()
	if failed != nil {
		return Err[bool, TermTermError](*failed)
	}
	rawMode.restore = restore
	// A paste comes bracketed, so it reaches the program as one value rather than
	// as keys — a newline in it is not Enter.
	termToScreen("\x1b[?2004h")
	if !rawMode.registered {
		atEnd(func() {
			rawMode.mu.Lock()
			termRawOff()
			rawMode.mu.Unlock()
		})
		rawMode.registered = true
	}
	// Ctrl+C is a key now, so these come only from outside; the terminal is put
	// back before the program ends, as an interrupt would have ended it.
	rawMode.signals = make(chan os.Signal, 1)
	signal.Notify(rawMode.signals, os.Interrupt, syscall.SIGTERM)
	go func(caught chan os.Signal) {
		if _, ok := <-caught; !ok {
			return
		}
		Ending()
		os.Exit(130)
	}(rawMode.signals)
	return Ok[bool, TermTermError](true)
}

// termRawOff puts the terminal back, if raw mode is on. Called with rawMode.mu held.
func termRawOff() {
	if rawMode.signals != nil {
		signal.Stop(rawMode.signals)
		close(rawMode.signals)
		rawMode.signals = nil
	}
	if rawMode.restore != nil {
		termToScreen("\x1b[?2004l")
		rawMode.restore()
		rawMode.restore = nil
	}
}

// termToScreen writes an escape sequence only where standard output is a
// terminal, so a file or a pipe never gets one.
func termToScreen(sequence string) {
	if info, err := os.Stdout.Stat(); err == nil && info.Mode()&os.ModeCharDevice != 0 {
		os.Stdout.WriteString(sequence)
	}
}

func TermSizeOf() Result[TermSize, TermTermError] {
	if size, ok := termWindow(); ok {
		return Ok[TermSize, TermTermError](size)
	}
	return Err[TermSize, TermTermError](termError("NotATerminal", "standard output is not a terminal"))
}

// What has been read and not yet handed over as a key.
var keyInput struct {
	mu      sync.Mutex
	pending []byte
}

// TermReadKey blocks for the next key — or the next paste — and answers with it,
// named as hive.ui names a key. It reads standard input whether or not raw mode
// is on, so a pipe can be read a key at a time too.
func TermReadKey() Result[TermKey, TermTermError] {
	keyInput.mu.Lock()
	defer keyInput.mu.Unlock()
	for {
		if len(keyInput.pending) > 0 {
			key, used, whole := termNextKey(keyInput.pending)
			if whole {
				keyInput.pending = keyInput.pending[used:]
				if key.Name == "" {
					continue
				}
				return Ok[TermKey, TermTermError](key)
			}
		}
		chunk, err := termReadChunk()
		if len(chunk) > 0 {
			keyInput.pending = append(keyInput.pending, chunk...)
			continue
		}
		if err != nil {
			keyInput.pending = nil
			if errors.Is(err, io.EOF) {
				return Err[TermKey, TermTermError](termError("Closed", "the input has ended"))
			}
			return Err[TermKey, TermTermError](termError("Io", err.Error()))
		}
	}
}

// termReadChunk answers with whatever arrives next: what hive.term.read left
// buffered first, then the console or standard input.
func termReadChunk() ([]byte, error) {
	if n := termInput.Buffered(); n > 0 {
		held, _ := termInput.Peek(n)
		out := append([]byte{}, held...)
		termInput.Discard(n)
		return out, nil
	}
	if read, console, err := termConsoleRead(); console {
		return read, err
	}
	buf := make([]byte, 4096)
	n, err := termInput.Read(buf)
	return buf[:n], err
}

// A key as read, before it is named.
type termPress struct {
	key   string
	text  string
	ctrl  bool
	shift bool
	alt   bool
}

// The name hive.ui gives it: what it types when nothing but Shift is held, and
// the key itself, modifiers first — Ctrl, then Shift, then Alt — when anything
// else is. A key held with Ctrl or Alt types nothing.
func (p termPress) named() TermKey {
	name := p.key
	if p.alt {
		name = "Alt+" + name
	}
	if p.shift {
		name = "Shift+" + name
	}
	if p.ctrl {
		name = "Ctrl+" + name
	}
	text := p.text
	if p.ctrl || p.alt {
		text = ""
	}
	return TermKey{Name: name, Text: text}
}

func pressed(key string) termPress { return termPress{key: key} }

// termNextKey reads the key at the front of b. whole is false where b ends
// part-way through one and more has to be read first; a key named "" is a
// sequence nobody asked for, to be skipped.
func termNextKey(b []byte) (key TermKey, used int, whole bool) {
	press, used, whole := termNextPress(b)
	if !whole {
		return TermKey{}, 0, false
	}
	if press.key == "" {
		return TermKey{}, used, true
	}
	if press.key == "Paste" {
		return TermKey{Name: "Paste", Text: press.text}, used, true
	}
	return press.named(), used, true
}

func termNextPress(b []byte) (termPress, int, bool) {
	if len(b) == 0 {
		return termPress{}, 0, false
	}
	c := b[0]
	switch {
	case c == 0x1b:
		return termEscape(b)
	case c == '\r':
		if len(b) > 1 && b[1] == '\n' {
			return pressed("Enter"), 2, true
		}
		return pressed("Enter"), 1, true
	case c == '\n':
		return pressed("Enter"), 1, true
	case c == '\t':
		return pressed("Tab"), 1, true
	case c == 0x7f || c == 0x08:
		return pressed("Backspace"), 1, true
	case c == 0:
		return termPress{key: "Space", ctrl: true}, 1, true
	case c < 0x1b:
		return termPress{key: string(rune('A' + c - 1)), ctrl: true}, 1, true
	case c < 0x20:
		return termPress{key: [...]string{"\\", "]", "6", "/"}[c-0x1c], ctrl: true}, 1, true
	case c == ' ':
		return termPress{key: "Space", text: " "}, 1, true
	}
	r, size := utf8.DecodeRune(b)
	if r == utf8.RuneError && size <= 1 {
		if !utf8.FullRune(b) {
			return termPress{}, 0, false
		}
		return termPress{}, 1, true
	}
	typed := string(b[:size])
	return termPress{key: typed, text: typed}, size, true
}

// termEscape reads what opens with ESC: a key's sequence, a paste, or Alt held
// with whatever follows. ESC alone, at the end of what arrived, is the key.
func termEscape(b []byte) (termPress, int, bool) {
	if len(b) == 1 {
		return pressed("Escape"), 1, true
	}
	switch b[1] {
	case '[':
		return termCSI(b)
	case 'O':
		if len(b) < 3 {
			return termPress{}, 0, false
		}
		return termFinal(b[2], 1), 3, true
	case 0x1b:
		return pressed("Escape"), 1, true
	}
	press, used, whole := termNextPress(b[1:])
	if !whole {
		return termPress{}, 0, false
	}
	if press.key == "" || press.key == "Paste" || press.alt {
		return press, used + 1, true
	}
	return withAlt(press), used + 1, true
}

// withAlt is a key typed with Alt held, which a terminal sends as ESC before
// it. A letter is named by its key, Shift held where it came upper case.
func withAlt(p termPress) termPress {
	p.alt = true
	if p.text != "" && len(p.key) == 1 {
		c := p.key[0]
		if c >= 'a' && c <= 'z' {
			p.key = string(c - 'a' + 'A')
		} else if c >= 'A' && c <= 'Z' {
			p.shift = true
		}
	}
	return p
}

// termCSI reads ESC [ parameters final.
func termCSI(b []byte) (termPress, int, bool) {
	end := 2
	for end < len(b) && (b[end] < 0x40 || b[end] > 0x7e) {
		end++
	}
	if end == len(b) {
		// Alt+[ is ESC [ and nothing more.
		if len(b) == 2 {
			return termPress{key: "[", alt: true}, 2, true
		}
		return termPress{}, 0, false
	}
	params := strings.Split(string(b[2:end]), ";")
	if b[end] == '~' && params[0] == "200" {
		return termPaste(b, end+1)
	}
	modifiers := 1
	if len(params) > 1 {
		if m, err := strconv.Atoi(params[1]); err == nil {
			modifiers = m
		}
	}
	if b[end] == '~' {
		n, _ := strconv.Atoi(params[0])
		return termTilde(n, modifiers), end + 1, true
	}
	return termFinal(b[end], modifiers), end + 1, true
}

// termFinal names a sequence by its last byte, with the modifiers a terminal
// sends as a number: one more than Shift 1, Alt 2, Ctrl 4, Meta 8.
func termFinal(final byte, modifiers int) termPress {
	name := ""
	switch final {
	case 'A':
		name = "ArrowUp"
	case 'B':
		name = "ArrowDown"
	case 'C':
		name = "ArrowRight"
	case 'D':
		name = "ArrowLeft"
	case 'H':
		name = "Home"
	case 'F':
		name = "End"
	case 'P':
		name = "F1"
	case 'Q':
		name = "F2"
	case 'R':
		name = "F3"
	case 'S':
		name = "F4"
	case 'Z':
		return termPress{key: "Tab", shift: true}
	}
	return withModifiers(name, modifiers)
}

func termTilde(n int, modifiers int) termPress {
	names := map[int]string{
		1: "Home", 2: "Insert", 3: "Delete", 4: "End", 5: "PageUp", 6: "PageDown",
		7: "Home", 8: "End", 11: "F1", 12: "F2", 13: "F3", 14: "F4", 15: "F5",
		17: "F6", 18: "F7", 19: "F8", 20: "F9", 21: "F10", 23: "F11", 24: "F12",
	}
	return withModifiers(names[n], modifiers)
}

func withModifiers(name string, modifiers int) termPress {
	if name == "" {
		return termPress{}
	}
	held := modifiers - 1
	if held < 0 {
		held = 0
	}
	return termPress{
		key:   name,
		shift: held&1 != 0,
		alt:   held&2 != 0,
		ctrl:  held&4 != 0 || held&8 != 0,
	}
}

// termPaste reads a bracketed paste, from just after ESC [ 200 ~ to ESC [ 201 ~.
// A terminal sends its line breaks as carriage returns; they come back as "\n".
func termPaste(b []byte, from int) (termPress, int, bool) {
	at := strings.Index(string(b[from:]), "\x1b[201~")
	if at < 0 {
		return termPress{}, 0, false
	}
	text := string(b[from : from+at])
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	return termPress{key: "Paste", text: text}, from + at + len("\x1b[201~"), true
}
