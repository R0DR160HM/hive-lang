//// The generated Go project's fixed pieces: its `go.mod` and the `hive`
//// runtime package that backs the language's builtins (`Table`, `TableError`,
//// `Result`, `Atom`, `using`/`ReadCSV`, `now`/`Now`, vector concatenation,
//// safe division, `**`, `assert` and SQL parameter sanitization).

/// The Go module name for every generated program. Because each program is
/// built in its own isolated directory this can be a fixed name.
pub const go_module = "hiveapp"

pub fn go_mod() -> String {
  "module " <> go_module <> "\n\ngo 1.26\n"
}

/// Source of the `hive` runtime package (written to `hive/runtime.go`).
///
/// `Table` is a type *alias* for `[][]string` so tables and `Str[dyn][dyn]`
/// values interconvert freely, as the language spec requires.
pub fn runtime_go() -> String {
  "package hive

import (
	\"encoding/csv\"
	\"fmt\"
	\"math\"
	\"os\"
	\"strconv\"
	\"strings\"
	\"time\"
)

// Table is a grid of string cells (a CSV, headerful or headerless).
type Table = [][]string

// TableError describes a failure encountered while reading a table.
type TableError struct {
	Path    string
	Message string
}

func (e TableError) Error() string {
	return \"hive: table error for \" + e.Path + \": \" + e.Message
}

// Result is the builtin fallible value: either an Ok payload of type T or an
// Error payload of type E.
type Result[T any, E any] struct {
	ok    bool
	value T
	err   E
}

func Ok[T any, E any](value T) Result[T, E] {
	return Result[T, E]{ok: true, value: value}
}

func Err[T any, E any](err E) Result[T, E] {
	return Result[T, E]{ok: false, err: err}
}

func (r Result[T, E]) IsOk() bool    { return r.ok }
func (r Result[T, E]) IsError() bool { return !r.ok }
func (r Result[T, E]) Ok() T         { return r.value }
func (r Result[T, E]) Err() E        { return r.err }

// Atom is an interned symbol. The compiler assigns every distinct atom in
// the program a small integer value (#False is always 0 and #True always 1)
// and registers the table of names via InitAtoms, so an echoed atom can show
// its visual form.
type Atom int

const (
	False Atom = 0
	True  Atom = 1
)

var atomNames = []string{\"False\", \"True\"}

// InitAtoms installs the program's atom table (called from generated code).
func InitAtoms(names []string) { atomNames = names }

// String is the atom's visual form (its name), which is what echo prints.
func (a Atom) String() string {
	if int(a) >= 0 && int(a) < len(atomNames) {
		return atomNames[a]
	}
	return \"#\" + strconv.Itoa(int(a))
}

// AtomToStr is the Str form of an atom: the decimal digits of its compiled
// value (so \"0\" + True == \"01\").
func AtomToStr(a Atom) string { return strconv.Itoa(int(a)) }

// Bool reports whether an atom is truthy (anything but #False).
func Bool(a Atom) bool { return a != False }

// ToStr converts any Hive value to its Str form (used by interpolation).
func ToStr(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case Atom:
		return AtomToStr(x)
	default:
		return fmt.Sprint(v)
	}
}

// Assert panics when a runtime assertion fails.
func Assert(cond bool) {
	if !cond {
		panic(\"hive: assertion failed\")
	}
}

// Concat returns a new vector holding a's elements followed by b's (the `+`
// operator on vectors).
func Concat[T any](a, b []T) []T {
	out := make([]T, 0, len(a)+len(b))
	out = append(out, a...)
	return append(out, b...)
}

// DivInt and DivFloat implement Hive division: dividing by 0 returns 0.
func DivInt(a, b int) int {
	if b == 0 {
		return 0
	}
	return a / b
}

func DivFloat(a, b float64) float64 {
	if b == 0 {
		return 0
	}
	return a / b
}

// PowInt and PowFloat implement the ** operator.
func PowInt(a, b int) int {
	if b < 0 {
		return 0
	}
	out := 1
	for i := 0; i < b; i++ {
		out *= a
	}
	return out
}

func PowFloat(a, b float64) float64 { return math.Pow(a, b) }

// SqlParam renders a value as a single-quoted SQL literal, doubling any
// embedded single quotes so interpolated parameters cannot break out of the
// literal (the sanitization behind query interpolation).
func SqlParam(v any) string {
	return \"'\" + strings.ReplaceAll(ToStr(v), \"'\", \"''\") + \"'\"
}

// ReadCSV reads a UTF-8 CSV file and returns its rows as a Table. The
// delimiter defaults to a comma when empty.
func ReadCSV(path string, delimiter string) Result[Table, TableError] {
	raw, err := os.ReadFile(path)
	if err != nil {
		return Err[Table, TableError](TableError{Path: path, Message: err.Error()})
	}
	reader := csv.NewReader(strings.NewReader(string(raw)))
	reader.FieldsPerRecord = -1
	if len(delimiter) > 0 {
		reader.Comma = []rune(delimiter)[0]
	}
	rows, err := reader.ReadAll()
	if err != nil {
		return Err[Table, TableError](TableError{Path: path, Message: err.Error()})
	}
	return Ok[Table, TableError](rows)
}

// Now returns the current Unix time in seconds.
func Now() int {
	return int(time.Now().Unix())
}
"
}
