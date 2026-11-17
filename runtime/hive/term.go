package hive

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

var termInput = bufio.NewReader(os.Stdin)

// TermPrint writes text to standard output exactly as it is, ending no line: a
// prompt, a cursor movement, a line built a piece at a time.
func TermPrint(text string) { os.Stdout.WriteString(text) }

func TermPrintln(text string) { fmt.Println(text) }

// The values hive.term.readKey and hive.term.size answer with. They are here
// rather than beside those calls so a program can build one without them.
type TermKey struct {
	Name string
	Text string
}

type TermSize struct {
	Width  int
	Height int
}

// TermTermError is what the program reads as hive.term.TermError: Reason is the
// variant, NotATerminal, Closed or Io.
type TermTermError struct {
	Reason  string
	Message string
}

func (e TermTermError) Error() string {
	return "hive: terminal " + e.Reason + ": " + e.Message
}

// TermProcess is what the program reads as hive.term.Process: the system's id
// for a program hive.term.start started, and the program behind it — nil in one
// a test built, which every call answers as one that has ended.
type TermProcess struct {
	Id int

	run *termRun
}

type termRun struct {
	cmd         *exec.Cmd
	output      *bufio.Reader
	pipe        *os.File
	input       io.WriteCloser
	reading     sync.Mutex
	sending     sync.Mutex
	done        chan struct{}
	code        int
	killTree    func()
	killed      atomic.Bool
	stopped     atomic.Bool
	inputClosed atomic.Bool
}

// TermProcessError is what the program reads as hive.term.ProcessError: Reason
// is Closed, Send or Receive.
type TermProcessError struct {
	Reason  string
	Message string
}

func (e TermProcessError) Error() string {
	return "hive: process " + e.Reason + ": " + e.Message
}

// TermStatus writes a line to standard error, which is where what a program is
// doing goes — as against what it was asked for, which is standard output.
// Redirecting the answer never takes the progress with it.
func TermStatus(text string) { fmt.Fprintln(os.Stderr, text) }

// ---------------------------------------------------------------------------
// Command-line flags as a codec
// ---------------------------------------------------------------------------
type TermFlagError struct {
	Path     string
	Expected string
	Found    string
}

func (e TermFlagError) Error() string {
	return "hive: cannot read the flag " + e.Path + ": expected " + e.Expected + ", found " + e.Found
}

func TermCodec() CodecCodec[TermFlagError] { return CodecCodec[TermFlagError]{} }

type TermFlagPair struct {
	Key   string
	Value string
	Bare  bool
	// The flag as it was typed — --model or -m — which is what an error names.
	Written string
}

// TermFlagShape is what a type's flags are, which a line's words are paired
// against: each flag's long name, its short one or "", and whether it is a Bool,
// which takes the word after it only when that word is true or false.
type TermFlagShape struct {
	Long  []string
	Short []string
	Bool  []bool
}

type termWord struct {
	text   string
	quoted bool
}

// termWords splits a line the way a shell would: whitespace between words,
// quotes and a backslash to keep one together. A word that opens quoted is
// never read as a flag.
func termWords(line string) ([]termWord, *TermFlagError) {
	words := []termWord{}
	var b strings.Builder
	inWord, quoted, escaped := false, false, false
	var quote rune
	for _, r := range line {
		switch {
		case escaped:
			b.WriteRune(r)
			escaped = false
		case quote == '\'':
			if r == '\'' {
				quote = 0
			} else {
				b.WriteRune(r)
			}
		case quote == '"':
			if r == '\\' {
				escaped = true
			} else if r == '"' {
				quote = 0
			} else {
				b.WriteRune(r)
			}
		case r == ' ' || r == '\t' || r == '\n' || r == '\r':
			if inWord {
				words = append(words, termWord{b.String(), quoted})
				b.Reset()
				inWord = false
			}
		default:
			if !inWord {
				quoted = r == '\\' || r == '"' || r == '\''
				inWord = true
			}
			if r == '\\' {
				escaped = true
			} else if r == '"' || r == '\'' {
				quote = r
			} else {
				b.WriteRune(r)
			}
		}
	}
	if quote != 0 {
		return nil, &TermFlagError{Path: "$", Expected: "a closing quote", Found: "the end of the text"}
	}
	if escaped {
		return nil, &TermFlagError{Path: "$", Expected: "a character after the backslash", Found: "the end of the text"}
	}
	if inWord {
		words = append(words, termWord{b.String(), quoted})
	}
	return words, nil
}

// termFlagLike is whether a word reads as a flag: unquoted and opening with a
// dash, but not a lone -, the -- that ends the flags, or a negative number.
func termFlagLike(w termWord) bool {
	if w.quoted || len(w.text) < 2 || w.text[0] != '-' || w.text == "--" {
		return false
	}
	c := w.text[1]
	return c == '-' || !(c >= '0' && c <= '9' || c == '.')
}

func termEndsFlags(w termWord) bool { return !w.quoted && w.text == "--" }

// termFlagSpan is where a line's flags are. The words before the first flag,
// and every one after a lone --, are the program's own, which
// hive.term.positional answers with; between them is nothing but flags and
// their values. It knows no type, so it is the same for decode and positional.
func termFlagSpan(words []termWord) (start, end int) {
	start, end = len(words), len(words)
	for i, w := range words {
		if termEndsFlags(w) || termFlagLike(w) {
			start = i
			break
		}
	}
	for i := start; i < len(words); i++ {
		if termEndsFlags(words[i]) {
			end = i
			break
		}
	}
	return start, end
}

// termFlags pairs the flags between those words with their values: --name
// value, --name=value, and a short -n the same ways. A Bool takes the next word
// only when it is true or false; any other flag takes the next word unless
// that is a flag itself, and stands alone where there is none.
func termFlags(words []termWord, shape TermFlagShape) ([]TermFlagPair, *TermFlagError) {
	flags := []TermFlagPair{}
	for i := 0; i < len(words); i++ {
		w := words[i]
		if !termFlagLike(w) {
			return nil, &TermFlagError{Path: "$", Expected: "a flag (words go before the flags or after --)", Found: strconv.Quote(w.text)}
		}
		written, value, valued := strings.Cut(w.text, "=")
		at := termFlagIndex(shape, written)
		if at < 0 {
			return nil, &TermFlagError{Path: written, Expected: termFlagNames(shape), Found: "a flag nothing declares"}
		}
		key := shape.Long[at]
		switch {
		case valued:
			flags = append(flags, TermFlagPair{Key: key, Value: value, Written: written})
		case i+1 < len(words) && termValueFor(words[i+1], shape.Bool[at]):
			flags = append(flags, TermFlagPair{Key: key, Value: words[i+1].text, Written: written})
			i++
		default:
			flags = append(flags, TermFlagPair{Key: key, Bare: true, Written: written})
		}
	}
	return flags, nil
}

func termValueFor(next termWord, isBool bool) bool {
	if isBool {
		return next.text == "true" || next.text == "false"
	}
	return !termFlagLike(next)
}

func termFlagIndex(shape TermFlagShape, written string) int {
	for i := range shape.Long {
		if strings.HasPrefix(written, "--") && shape.Long[i] == written[2:] {
			return i
		}
		if !strings.HasPrefix(written, "--") && shape.Short[i] != "" && shape.Short[i] == written[1:] {
			return i
		}
	}
	return -1
}

// Every flag a type takes, for the error about one it does not.
func termFlagNames(shape TermFlagShape) string {
	if len(shape.Long) == 0 {
		return "no flags at all"
	}
	names := []string{}
	for i, long := range shape.Long {
		name := "--" + long
		if shape.Short[i] != "" {
			name += "/-" + shape.Short[i]
		}
		names = append(names, name)
	}
	if len(names) == 1 {
		return names[0]
	}
	return strings.Join(names[:len(names)-1], ", ") + " or " + names[len(names)-1]
}

// TermFlagParse is what a compiler from before flag shapes calls — the seed
// this one is built with among them — and it reads a line as one always did:
// unknown flags and stray words passed over, a flag taking the next word. It
// goes when the seed is past it.
func TermFlagParse[T any](line string, dec func([]TermFlagPair) (T, *TermFlagError)) Result[T, TermFlagError] {
	words, werr := termWords(line)
	if werr != nil {
		return Err[T, TermFlagError](*werr)
	}
	flags := []TermFlagPair{}
	for i := 0; i < len(words); i++ {
		w := words[i]
		if !w.quoted && w.text == "--" {
			break
		}
		if w.quoted || !strings.HasPrefix(w.text, "--") {
			continue
		}
		name := w.text[2:]
		if key, value, found := strings.Cut(name, "="); found {
			flags = append(flags, TermFlagPair{Key: key, Value: value})
			continue
		}
		if i+1 < len(words) && (words[i+1].quoted || !strings.HasPrefix(words[i+1].text, "--")) {
			flags = append(flags, TermFlagPair{Key: name, Value: words[i+1].text})
			i++
			continue
		}
		flags = append(flags, TermFlagPair{Key: name, Bare: true})
	}
	out, ferr := dec(flags)
	if ferr != nil {
		return Err[T, TermFlagError](*ferr)
	}
	return Ok[T, TermFlagError](out)
}

// TermFlagRead backs T.decode with hive.term.codec(): the line's words paired
// against the type's flags, then read into it.
func TermFlagRead[T any](line string, shape TermFlagShape, dec func([]TermFlagPair) (T, *TermFlagError)) Result[T, TermFlagError] {
	words, werr := termWords(line)
	if werr != nil {
		return Err[T, TermFlagError](*werr)
	}
	start, end := termFlagSpan(words)
	pairs, ferr := termFlags(words[start:end], shape)
	if ferr != nil {
		return Err[T, TermFlagError](*ferr)
	}
	out, ferr := dec(pairs)
	if ferr != nil {
		return Err[T, TermFlagError](*ferr)
	}
	return Ok[T, TermFlagError](out)
}

// TermPositional backs hive.term.positional: the words of a command line that
// are the program's own rather than any flag's — those before the first flag,
// and every one after a lone --. A line with a quote left open has none.
func TermPositional(line string) []string {
	out := []string{}
	words, err := termWords(line)
	if err != nil {
		return out
	}
	start, end := termFlagSpan(words)
	for _, w := range words[:start] {
		out = append(out, w.text)
	}
	if end < len(words) {
		for _, w := range words[end+1:] {
			out = append(out, w.text)
		}
	}
	return out
}

func termFlagsNamed(q []TermFlagPair, key string) []TermFlagPair {
	out := []TermFlagPair{}
	for _, f := range q {
		if f.Key == key {
			out = append(out, f)
		}
	}
	return out
}

func termFlagCount(n int) string {
	if n == 1 {
		return "1 value"
	}
	return strconv.Itoa(n) + " values"
}

func TermFlagHas(q []TermFlagPair, key string) bool {
	return len(termFlagsNamed(q, key)) > 0
}

func TermFlagOne[T any](q []TermFlagPair, key string, read func(TermFlagPair, string) (T, *TermFlagError)) (T, *TermFlagError) {
	var zero T
	path := "--" + key
	found := termFlagsNamed(q, key)
	if len(found) == 0 {
		return zero, &TermFlagError{Path: path, Expected: "a value", Found: "nothing"}
	}
	if len(found) > 1 {
		return zero, &TermFlagError{Path: path, Expected: "one value", Found: termFlagCount(len(found))}
	}
	return read(found[0], termWritten(found[0], path))
}

func termWritten(f TermFlagPair, path string) string {
	if f.Written != "" {
		return f.Written
	}
	return path
}

func TermFlagVec[T any](q []TermFlagPair, key string, n int, read func(TermFlagPair, string) (T, *TermFlagError)) ([]T, *TermFlagError) {
	path := "--" + key
	found := termFlagsNamed(q, key)
	if n >= 0 && len(found) != n {
		return nil, &TermFlagError{Path: path, Expected: termFlagCount(n), Found: termFlagCount(len(found))}
	}
	out := make([]T, 0, len(found))
	for i, f := range found {
		e, ferr := read(f, termWritten(f, path)+"["+strconv.Itoa(i)+"]")
		if ferr != nil {
			return nil, ferr
		}
		out = append(out, e)
	}
	return out, nil
}

// Every reader but Bool's needs a value; a Bool standing alone is true.
func termFlagValue(f TermFlagPair, path string) (string, *TermFlagError) {
	if f.Bare {
		return "", &TermFlagError{Path: path, Expected: "a value", Found: "the flag alone"}
	}
	return f.Value, nil
}

func TermFlagStr(f TermFlagPair, path string) (string, *TermFlagError) {
	return termFlagValue(f, path)
}

func TermFlagInt(f TermFlagPair, path string) (int, *TermFlagError) {
	s, ferr := termFlagValue(f, path)
	if ferr != nil {
		return 0, ferr
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, &TermFlagError{Path: path, Expected: "Int", Found: strconv.Quote(s)}
	}
	return n, nil
}

func TermFlagFloat(f TermFlagPair, path string) (float64, *TermFlagError) {
	s, ferr := termFlagValue(f, path)
	if ferr != nil {
		return 0, ferr
	}
	n, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0, &TermFlagError{Path: path, Expected: "Float", Found: strconv.Quote(s)}
	}
	return n, nil
}

func TermFlagBool(f TermFlagPair, path string) (bool, *TermFlagError) {
	if f.Bare {
		return true, nil
	}
	if f.Value == "true" || f.Value == "false" {
		return f.Value == "true", nil
	}
	return false, &TermFlagError{Path: path, Expected: "Bool", Found: strconv.Quote(f.Value)}
}

func TermFlagAtom(f TermFlagPair, path string) (Atom, *TermFlagError) {
	s, ferr := termFlagValue(f, path)
	if ferr != nil {
		return 0, ferr
	}
	for i, name := range atomNames {
		if name == s {
			return Atom(i), nil
		}
	}
	return 0, &TermFlagError{Path: path, Expected: "a known atom", Found: strconv.Quote(s)}
}

// Encoding writes every field as --name value, quoting a value that would
// otherwise split, vanish or read as a flag.
func TermFlagEncodeStr(s string) string { return s }

func TermFlagEncodeInt(i int) string { return strconv.Itoa(i) }

func TermFlagEncodeFloat(f float64) string { return strconv.FormatFloat(f, 'g', -1, 64) }

func TermFlagEncodeBool(b bool) string { return strconv.FormatBool(b) }

func TermFlagEncodeAtom(a Atom) string { return a.String() }

func TermFlagOf(key string, value string) []TermFlagPair {
	return []TermFlagPair{{Key: key, Value: value}}
}

func TermFlagEach[T any](key string, items []T, write func(T) string) []TermFlagPair {
	out := make([]TermFlagPair, 0, len(items))
	for _, item := range items {
		out = append(out, TermFlagPair{Key: key, Value: write(item)})
	}
	return out
}

func TermFlagJoin(groups ...[]TermFlagPair) string {
	parts := []string{}
	for _, group := range groups {
		for _, f := range group {
			parts = append(parts, "--"+f.Key, termQuote(f.Value))
		}
	}
	return strings.Join(parts, " ")
}

func termQuote(s string) string {
	if s != "" && !strings.HasPrefix(s, "--") && !strings.ContainsAny(s, " \t\n\r\"'\\") {
		return s
	}
	return "\"" + strings.ReplaceAll(strings.ReplaceAll(s, "\\", "\\\\"), "\"", "\\\"") + "\""
}

// TermIsTerminal answers whether standard error is a terminal rather than
// a file or a pipe: the difference between somebody sitting there waiting
// and output being collected for later.
func TermIsTerminal() bool {
	info, err := os.Stderr.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}

func TermPlatform() string { return runtime.GOOS + "/" + runtime.GOARCH }

// Blocks for a line and hands it back without its trailing newline. At end
// of input it answers with whatever preceded EOF.
func TermRead() string {
	line, err := termInput.ReadString('\n')
	if err != nil && line == "" {
		return ""
	}
	return strings.TrimRight(line, "\r\n")
}

// ExecError is what hive.term.exec answers with when a command could not be
// started, or answered with a status other than zero. It carries what was run,
// the status, and everything it wrote — so a failure is one value rather than
// a message and a hunt through a log.
type TermExecError struct {
	Command string
	Code    int
	Output  string
	Message string
}

// TermExec runs command with arguments in directory and hands back everything
// it wrote — stdout and stderr together, in the order it wrote them. An empty
// directory means where this program is.
//
// A status other than zero is an Error: a command that failed is not one that
// answered. The output is on the error too, being usually why.
func TermExec(command string, arguments []string, directory string) Result[string, TermExecError] {
	return TermExecWith(command, arguments, directory, NewDict[string, string]())
}

// TermExecWith is TermExec with an environment overlay, applied on top of the
// environment this program was started with — so an empty Dict is exactly
// TermExec and a name already set is replaced rather than doubled.
//
// An overlay is deliberately the only thing on offer: a command handed a
// replaced environment finds no toolchain without PATH and no module cache
// without HOME.
func TermExecWith(command string, arguments []string, directory string, environment Dict[string, string]) Result[string, TermExecError] {
	cmd := exec.Command(command, arguments...)
	if directory != "" {
		cmd.Dir = directory
	}
	cmd.Env = termEnvironment(environment)
	written, err := cmd.CombinedOutput()
	output := string(written)
	if err == nil {
		return Ok[string, TermExecError](output)
	}
	code := -1
	if exited, ok := err.(*exec.ExitError); ok {
		code = exited.ExitCode()
	}
	return Err[string, TermExecError](TermExecError{
		Command: command,
		Code:    code,
		Output:  output,
		Message: err.Error(),
	})
}

// The environment a command runs in: this program's own with the overlay
// applied, or nil for no overlay at all.
//
// Nil is not the empty environment — it is this program's. An empty non-nil
// slice would start the command with nothing set.
//
// Appending is enough to replace a name: Go takes the last of a repeated one,
// case-insensitively on Windows where PATH and Path are one variable.
func termEnvironment(overlay Dict[string, string]) []string {
	if overlay.Len() == 0 {
		return nil
	}
	out := os.Environ()
	for _, name := range overlay.Keys() {
		if value := overlay.Get(name); value.IsOk() {
			out = append(out, name+"="+value.Ok())
		}
	}
	return out
}

// TermExit ends the program with a status. There is no value to answer with
// and nothing after it runs, which is what makes it a statement rather than
// a call.
func TermExit(code int) {
	Ending()
	os.Exit(code)
}

// TermAttach runs the command with this program's own terminal and answers
// with the status it exited with. Nothing is captured, the point being that
// the command is talking to whoever started this program.
func TermAttach(command string, arguments []string, directory string) int {
	cmd := exec.Command(command, arguments...)
	if directory != "" {
		cmd.Dir = directory
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if exited, ok := err.(*exec.ExitError); ok {
			return exited.ExitCode()
		}
		return -1
	}
	return 0
}

// The command-line arguments, in order, excluding the program name.
func TermArgs() []string {
	if len(os.Args) <= 1 {
		return []string{}
	}
	return CloneVec(os.Args[1:])
}

// TermFlags is the arguments as one line the flag codec reads back into the very
// words they arrived as. The shell has already split them, so joining them with
// spaces would split a word holding one a second time.
func TermFlags() string { return termLine(TermArgs()) }

func termLine(args []string) string {
	parts := make([]string, 0, len(args))
	for _, arg := range args {
		parts = append(parts, termSpoken(arg))
	}
	return strings.Join(parts, " ")
}

// A word as it would have to be typed. One opening with `--` stays a flag, its
// value quoted after the `=` where it needs to be, since a word that opens quoted
// is never a flag; any other word is quoted where it would split or vanish.
func termSpoken(arg string) string {
	if !strings.HasPrefix(arg, "--") {
		if arg != "" && !strings.ContainsAny(arg, " \t\n\r\"'\\") {
			return arg
		}
		return termQuote(arg)
	}
	key, value, found := strings.Cut(arg, "=")
	if strings.ContainsAny(key, " \t\n\r\"'\\") {
		return termQuote(arg)
	}
	if !found {
		return arg
	}
	return key + "=" + termQuote(value)
}
