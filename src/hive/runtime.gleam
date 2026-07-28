//// The generated Go project's fixed pieces: its `go.mod`, the core `hive`
//// runtime package that backs the language itself (`Table`, `TableError`,
//// `Result`, `Atom`, `using`/`ReadCSV`, vector concatenation, safe division,
//// `**`, `assert`, SQL parameter sanitization) and one file per standard
//// library module (`hive.net`, `hive.json`, `hive.crypto`, ...).
////
//// Only the modules a program actually uses are written into its build
//// directory — see `modules` and `hive/cli`. Everything lands in the same Go
//// package (`hive`), so a module's file may call into the core runtime and
//// into any module it lists in `requires`, but nothing else.

import gleam/list
import gleam/string

/// The Go module name for every generated program. Because each program is
/// built in its own isolated directory this can be a fixed name.
pub const go_module = "hiveapp"

pub fn go_mod() -> String {
  "module " <> go_module <> "\n\ngo 1.26\n"
}

// ---------------------------------------------------------------------------
// The optional standard library modules
// ---------------------------------------------------------------------------

/// One standard library module's Go source, written into the generated project
/// only when the program uses it.
///
/// `markers` are the `hive.X` references a program that uses the module is
/// guaranteed to carry in its generated `main.go` — matching any one of them
/// pulls the module in. `requires` names the other modules this one's own Go
/// source calls into, so a module is never written without the definitions it
/// needs (the core `runtime.go` is always present, and every module may use
/// it).
pub type Module {
  Module(
    name: String,
    /// Path within the build directory.
    file: String,
    source: fn() -> String,
    markers: List(String),
    requires: List(String),
  )
}

/// Every module that is included on demand. The core runtime is not listed: it
/// is always written.
pub fn modules() -> List(Module) {
  [
    Module(
      name: "net",
      file: "hive/net.go",
      source: net_go,
      markers: ["hive.Http", "hive.Ws", "hive.Socket"],
      requires: [],
    ),
    Module(
      name: "json",
      file: "hive/json.go",
      source: json_go,
      markers: ["hive.Json"],
      requires: [],
    ),
    Module(
      name: "crypto",
      file: "hive/crypto.go",
      source: crypto_go,
      markers: [
        "hive.Sha", "hive.Hmac", "hive.Base64", "hive.RandomHex", "hive.Jwt",
        "hive.CryptoError",
      ],
      // JWTs decode their payload with the JSON module's derived decoders and
      // check exp/nbf against `Now`.
      requires: ["json", "time"],
    ),
    Module(
      name: "conv",
      file: "hive/conv.go",
      source: conv_go,
      markers: [
        "hive.Ceil", "hive.Floor", "hive.Round", "hive.IntTo", "hive.FloatTo",
        "hive.StrTo", "hive.ConversionError",
      ],
      requires: [],
    ),
    Module(
      name: "env",
      file: "hive/env.go",
      source: env_go,
      // Spelled out rather than matched on a `hive.Env` prefix: that would also
      // match `hive.Envelope`, dragging this module into every syslink program.
      markers: ["hive.EnvGet"],
      requires: [],
    ),
    Module(
      name: "term",
      file: "hive/term.go",
      source: term_go,
      markers: ["hive.Term"],
      requires: [],
    ),
    Module(
      name: "task",
      file: "hive/task.go",
      source: task_go,
      // `await ... with timeout <ms>` lives here too: bounding a wait is
      // scheduling, and a program that never bounds one does not link it.
      markers: [
        "hive.Sleep", "hive.AwaitTimeout", "hive.AwaitAllTimeout",
        "hive.TimeoutError",
      ],
      requires: [],
    ),
    Module(
      name: "time",
      file: "hive/time.go",
      source: time_go,
      markers: ["hive.Now", "hive.Timezone", "hive.TimeFormat"],
      requires: [],
    ),
    Module(
      name: "sheets",
      file: "hive/sheets.go",
      source: sheets_go,
      // `using ... as xlsx` / `as ods` names the format in the source, which is
      // exactly what keeps archive/zip and encoding/xml out of a build that
      // only ever reads a CSV.
      markers: ["hive.ReadXlsx", "hive.ReadOds"],
      requires: [],
    ),
    Module(
      name: "file",
      file: "hive/file.go",
      source: file_go,
      markers: ["hive.File"],
      requires: [],
    ),
    Module(
      name: "syslink",
      file: "hive/syslink.go",
      source: syslink_go,
      // `hive.Syslink` catches every call and the error type. The two opaque
      // types are spelled out because they lower to names that do not carry the
      // prefix: a program that declares a handler or an address-typed parameter
      // and never calls anything would otherwise reference `hive.Envelope` and
      // `hive.Address` without this module being written at all.
      markers: ["hive.Syslink", "hive.Address", "hive.Envelope"],
      // A message crosses a machine boundary through the same derived codecs
      // `hive.json` builds from a type declaration, and the wire that carries
      // it is authenticated with `hive.crypto`'s primitives.
      requires: ["json", "syslinknet"],
    ),
    Module(
      // The wire half of syslink. It carries no markers of its own: nothing in
      // Hive source names it directly, and it is written only because
      // `syslink` requires it.
      name: "syslinknet",
      file: "hive/syslink_net.go",
      source: syslink_net_go,
      markers: [],
      requires: [],
    ),
    Module(
      name: "sql",
      file: "hive/sql.go",
      source: sql_go,
      // Deliberately spelled out rather than matched on a `hive.Sql` prefix:
      // `hive.SqlParam` (query interpolation) lives in the core runtime, and
      // matching it here would drag the external drivers into a program that
      // never opens a connection.
      markers: [
        "hive.SqlConnect", "hive.SqlPool", "hive.SqlClose", "hive.SqlQuery",
        "hive.SqlError", "hive.SqlConnection", "hive.DatabaseDriver",
        // A `query` declaration builds one of these even in a program that
        // never opens a connection, so declaring one is enough to need the
        // module.
        "hive.SqlFragment", "hive.SqlRows", "hive.SqlExec", "hive.SqlCell",
        "hive.SqlJoin", "hive.SqlShapeError",
      ],
      requires: [],
    ),
  ]
}

/// The standard library modules a generated program needs, by name: every
/// module whose markers appear in the given `main.go`, plus — transitively —
/// the modules those ones call into themselves (`hive.crypto` decodes JWT
/// payloads with `hive.json` and reads the clock through `hive.time`).
///
/// A module nothing reaches for is left out of the build entirely, so a program
/// that never opens a socket does not compile the networking runtime, and one
/// that never opens a database neither downloads nor links the SQL drivers.
pub fn needed_modules(main_go: String) -> List(String) {
  let direct =
    modules()
    |> list.filter(fn(module) {
      list.any(module.markers, fn(marker) { string.contains(main_go, marker) })
    })
    |> list.map(fn(module) { module.name })
  with_requirements(direct, direct)
}

// Grows `found` with everything reachable through `requires`, one layer at a
// time, until a layer adds nothing new.
fn with_requirements(layer: List(String), found: List(String)) -> List(String) {
  let next =
    layer
    |> list.flat_map(fn(name) {
      case list.find(modules(), fn(module) { module.name == name }) {
        Ok(module) -> module.requires
        Error(_) -> []
      }
    })
    |> list.unique
    |> list.filter(fn(name) { !list.contains(found, name) })
  case next {
    [] -> found
    _ -> with_requirements(next, list.append(found, next))
  }
}

// ---------------------------------------------------------------------------
// The core runtime (always written)
// ---------------------------------------------------------------------------

/// Source of the core `hive` runtime (written to `hive/runtime.go`): what the
/// language itself needs, independent of any standard library module.
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
	\"reflect\"
	\"strconv\"
	\"strings\"
	\"unicode/utf8\"
)

// When launched by `hive run`, the program is compiled and executed from
// inside its .hive-build directory (via `go run`), but the author expects
// relative paths like `using \"./data.csv\"` to resolve against the entrypoint's
// own folder. `hive run` passes that folder in HIVE_RUN_CWD; honour it here,
// before main runs, so those paths still work. A normally-built executable
// never has this variable set, so this is a no-op for `hive build` output.
func init() {
	if dir := os.Getenv(\"HIVE_RUN_CWD\"); dir != \"\" {
		_ = os.Chdir(dir)
	}
}

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

// ToStr converts any Hive value to its Str form (used by interpolation and
// string coercion). Note that an Atom renders as its decimal value here, which
// is the language's coercion rule (\"0\" + #True == \"01\").
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

// Show renders a value exactly as `echo` displays it — same as fmt's default
// formatting, so an Atom shows its NAME (via Atom.String()) rather than the
// decimal form ToStr produces. Backs `panic value`.
func Show(v any) string { return fmt.Sprint(v) }

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

// CloneVec returns a shallow copy of a vector: a fresh backing array holding
// the same elements (each copied by Go assignment). Hive vectors are value
// types but lower to Go slices (which share storage), so a binding that must
// stay independent of its source is copied rather than aliased. This is the
// right copy when the element type owns no storage of its own (a scalar, atom,
// or struct without vector fields); deeper element types use CloneVecFn.
func CloneVec[T any](s []T) []T {
	if s == nil {
		return nil
	}
	out := make([]T, len(s))
	copy(out, s)
	return out
}

// CloneVecFn is CloneVec for element types that themselves own storage (nested
// vectors, or structs with vector fields): every element is passed through
// clone so the copy shares nothing with the original.
func CloneVecFn[T any](s []T, clone func(T) T) []T {
	if s == nil {
		return nil
	}
	out := make([]T, len(s))
	for i := range s {
		out[i] = clone(s[i])
	}
	return out
}

// CloneTable deep-copies a Table ([][]string): a fresh outer slice whose rows
// are themselves fresh, so neither the grid nor any row shares storage with
// the original.
func CloneTable(t Table) Table {
	return CloneVecFn(t, CloneVec[string])
}

// ---------------------------------------------------------------------------
// Concurrency: async tasks (`async T`)
// ---------------------------------------------------------------------------

// Unit is the value of a task produced by a void `async func` — a task joined
// on for its completion, not for a result.
type Unit = struct{}

// Async is a handle to a value being computed on its own goroutine — the
// lowering of Hive's inferred `async T`. It is never named in Hive source;
// Spawn produces it and Await consumes it.
type Async[T any] struct {
	done  chan struct{}
	val   T
	panic any
}

// Spawn starts f on a new goroutine right away and returns a handle to its
// eventual result without blocking the caller. A panic inside the task is
// captured and re-raised at the Await site (so failures stay local to the code
// that needed the value); a handle that is never awaited swallows it, rather
// than tearing down an unrelated goroutine.
func Spawn[T any](f func() T) *Async[T] {
	a := &Async[T]{done: make(chan struct{})}
	go func() {
		defer close(a.done)
		defer func() {
			if r := recover(); r != nil {
				a.panic = r
			}
		}()
		a.val = f()
	}()
	return a
}

// Await blocks until the task has produced its value, then returns it. `done`
// is closed exactly once, so receiving from it never blocks again: awaiting an
// already-finished task returns instantly, and a task may be awaited any number
// of times, always yielding the same value.
func (a *Async[T]) Await() T {
	<-a.done
	if a.panic != nil {
		panic(a.panic)
	}
	return a.val
}

// AwaitAll waits for every task and returns their values index-aligned with the
// input — position i holds task i's result regardless of the order the tasks
// finished in. It is the barrier behind `await` on a vector of handles.
func AwaitAll[T any](hs []*Async[T]) []T {
	out := make([]T, len(hs))
	for i, h := range hs {
		out[i] = h.Await()
	}
	return out
}

// VecEq reports whether two vectors are equal: the same length, then equal
// elements in order — short-circuiting on the first mismatch. Nested vectors
// (a Table) are compared the same way recursively, so an empty vector and a
// nil one count as equal; other element values are compared deeply. Hive's
// == / != on vectors lower to this, since Go cannot compare slices directly.
func VecEq(a, b any) bool {
	va := reflect.ValueOf(a)
	vb := reflect.ValueOf(b)
	if va.Kind() != reflect.Slice || vb.Kind() != reflect.Slice {
		return reflect.DeepEqual(a, b)
	}
	if va.Len() != vb.Len() {
		return false
	}
	for i := 0; i < va.Len(); i++ {
		if !VecEq(va.Index(i).Interface(), vb.Index(i).Interface()) {
			return false
		}
	}
	return true
}

// Join concatenates the elements of a string vector into a single string,
// placing sep between adjacent elements (backs the `join` builtin).
func Join(parts []string, sep string) string {
	return strings.Join(parts, sep)
}

// Split divides s into all substrings separated by sep, returning them as a
// vector (backs the `split` builtin). An empty separator splits into
// individual UTF-8 characters.
func Split(s string, sep string) []string {
	return strings.Split(s, sep)
}

// StrLen is the length of a string in characters (UTF-8 runes), which is what
// `len` reports for a Str — vectors instead use Go's builtin len.
func StrLen(s string) int {
	return utf8.RuneCountInString(s)
}

// IndexOf returns the position of the first element of v equal to value, or
// Error(false) when v holds no such element (backs the `indexOf` builtin on a
// vector). Elements are compared the way Hive's == compares them, so a vector
// of vectors matches structurally.
//
// An Ok payload is always a position v really has (0 <= i < len(v)) — the
// compiler's bounds pass relies on that to let the index be used unguarded.
func IndexOf[T any](v []T, value T) Result[int, bool] {
	for i, x := range v {
		if VecEq(x, value) {
			return Ok[int, bool](i)
		}
	}
	return Err[int, bool](false)
}

// IndexOfStr returns the position of the first occurrence of sub in s, counted
// in characters (UTF-8 runes) so it lines up with what `len` reports for a Str,
// or Error(false) when sub does not occur (backs `indexOf` on a Str).
//
// Searching an empty string never succeeds, not even for an empty needle: that
// keeps the same invariant the vector form has — an Ok payload always points at
// a character s really has.
func IndexOfStr(s string, sub string) Result[int, bool] {
	if s == \"\" {
		return Err[int, bool](false)
	}
	i := strings.Index(s, sub)
	if i < 0 {
		return Err[int, bool](false)
	}
	return Ok[int, bool](utf8.RuneCountInString(s[:i]))
}

// MatchPattern matches s against a string-pattern template and returns the
// captured hole values in order, or nil when s does not match. This backs Hive
// patterns such as `path is \"/api/{id}/{name}/delete\"`.
//
// The template is described by a leading literal prefix and, for each hole in
// order, the literal that terminates it. seps[i] is the literal following hole
// i; an empty seps[i] means hole i runs to the end of the input (only the last
// hole can be terminated this way). Matching is left-to-right and non-greedy:
// each hole captures the shortest run of text up to the next occurrence of its
// terminating literal, so a `{seg}` between two `/` never swallows a `/`. The
// template must describe the whole string — any trailing input is a no-match.
func MatchPattern(s string, prefix string, seps []string) []string {
	if !strings.HasPrefix(s, prefix) {
		return nil
	}
	s = s[len(prefix):]
	caps := make([]string, len(seps))
	for i, sep := range seps {
		if sep == \"\" {
			// The final hole captures whatever is left.
			caps[i] = s
			s = s[len(s):]
			continue
		}
		idx := strings.Index(s, sep)
		if idx < 0 {
			return nil
		}
		caps[i] = s[:idx]
		s = s[idx+len(sep):]
	}
	if s != \"\" {
		return nil
	}
	return caps
}

// Bytes is the size, in bytes, of a vector's contiguous backing storage: its
// element count times the size of one element (backs `bytes` on a vector).
// `bytes` on a Str instead reports the UTF-8 byte length of its contents.
func Bytes[T any](v []T) int {
	var zero T
	return len(v) * int(reflect.TypeOf(&zero).Elem().Size())
}

// Row returns a copy of the first row of t whose first cell equals key, or an
// empty vector when no row matches (backs the `row` builtin).
func Row(t Table, key string) []string {
	for _, r := range t {
		if len(r) > 0 && r[0] == key {
			out := make([]string, len(r))
			copy(out, r)
			return out
		}
	}
	return []string{}
}

// Column returns the cells beneath the column of t whose top (first-row) cell
// equals key, skipping any row too short to reach that column. Returns an
// empty vector when no column matches (backs the `column` builtin).
func Column(t Table, key string) []string {
	out := []string{}
	if len(t) == 0 {
		return out
	}
	col := -1
	for i, cell := range t[0] {
		if cell == key {
			col = i
			break
		}
	}
	if col < 0 {
		return out
	}
	for _, r := range t {
		if col < len(r) {
			out = append(out, r[col])
		}
	}
	return out
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

// ModInt and ModFloat implement the % (remainder) operator. Like division, a
// modulus of 0 returns 0 rather than panicking. Go's built-in % is
// integer-only, so the float case uses math.Mod.
func ModInt(a, b int) int {
	if b == 0 {
		return 0
	}
	return a % b
}

func ModFloat(a, b float64) float64 {
	if b == 0 {
		return 0
	}
	return math.Mod(a, b)
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
// literal (the sanitization behind query interpolation). It lives here rather
// than in the SQL module because a `query` declaration's interpolations are
// lowered whether or not the program ever opens a connection.
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
"
}

// ---------------------------------------------------------------------------
// hive.net
// ---------------------------------------------------------------------------

/// Source of `hive/net.go`: the networking module (`hive.net`). HTTP client and
/// server, WebSocket client and server, and raw TCP client and server.
///
/// The WebSocket half implements RFC 6455 directly on a hijacked connection
/// rather than pulling in a third-party library, so a program that speaks
/// WebSocket still builds offline with a dependency-free `go.mod`.
pub fn net_go() -> String {
  "package hive

import (
	\"bufio\"
	\"crypto/rand\"
	\"crypto/sha1\"
	\"crypto/tls\"
	\"encoding/base64\"
	\"encoding/binary\"
	\"errors\"
	\"io\"
	\"net\"
	\"net/http\"
	\"net/url\"
	\"strconv\"
	\"strings\"
	\"sync\"
	\"time\"
)

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

// HttpRequest is the value consumed by `hive.net.httpRequest` and produced for
// every incoming call handled by `hive.net.httpServe`. Headers are a Table of
// [name, value] rows.
type HttpRequest struct {
	Method  string
	Url     string
	Headers Table
	Body    string
}

// HttpResponse is what `hive.net.httpRequest` yields and what an `httpServe` handler
// returns.
type HttpResponse struct {
	Status  int
	Headers Table
	Body    string
}

// HttpError describes a request that produced no response at all (bad URL,
// connection refused, timeout, unreadable body).
type HttpError struct {
	Url     string
	Message string
}

func (e HttpError) Error() string {
	return \"hive: http error for \" + e.Url + \": \" + e.Message
}

var httpClient = &http.Client{Timeout: 30 * time.Second}

// HttpSend backs `hive.net.httpRequest`: it performs the request and returns
// the response, or an HttpError when no response was obtained.
func HttpSend(req HttpRequest) Result[HttpResponse, HttpError] {
	fail := func(err error) Result[HttpResponse, HttpError] {
		return Err[HttpResponse, HttpError](HttpError{Url: req.Url, Message: err.Error()})
	}
	hreq, err := http.NewRequest(strings.ToUpper(req.Method), req.Url, strings.NewReader(req.Body))
	if err != nil {
		return fail(err)
	}
	for _, row := range req.Headers {
		if len(row) >= 2 {
			hreq.Header.Add(row[0], row[1])
		}
	}
	resp, err := httpClient.Do(hreq)
	if err != nil {
		return fail(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fail(err)
	}
	return Ok[HttpResponse, HttpError](HttpResponse{
		Status:  resp.StatusCode,
		Headers: headerTable(resp.Header),
		Body:    string(body),
	})
}

// HttpServe backs `hive.net.httpServe`: it serves every route through the given
// handler and blocks forever (it panics if the listener cannot start).
func HttpServe(port int, handler func(HttpRequest) HttpResponse) {
	mux := http.NewServeMux()
	mux.HandleFunc(\"/\", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		resp := handler(HttpRequest{
			Method:  r.Method,
			Url:     r.URL.String(),
			Headers: headerTable(r.Header),
			Body:    string(body),
		})
		for _, row := range resp.Headers {
			if len(row) >= 2 {
				w.Header().Add(row[0], row[1])
			}
		}
		status := resp.Status
		if status == 0 {
			status = 200
		}
		w.WriteHeader(status)
		io.WriteString(w, resp.Body)
	})
	if err := http.ListenAndServe(\":\"+strconv.Itoa(port), mux); err != nil {
		panic(\"hive: net.httpServe: \" + err.Error())
	}
}

func headerTable(h http.Header) Table {
	table := Table{}
	for name, values := range h {
		for _, value := range values {
			table = append(table, []string{name, value})
		}
	}
	return table
}

// ---------------------------------------------------------------------------
// WebSockets (RFC 6455)
// ---------------------------------------------------------------------------

// The fixed GUID every handshake mixes into the client's key to prove that the
// peer really understood the upgrade (RFC 6455 §1.3).
const wsGUID = \"258EAFA5-E914-47DA-95CA-C5AB0DC85B16\"

// A frame whose length header exceeds this is refused rather than allocated, so
// a hostile peer cannot exhaust memory with one number.
const wsMaxPayload = 32 << 20

// Frame opcodes.
const (
	wsContinuation byte = 0x0
	wsText         byte = 0x1
	wsBinary       byte = 0x2
	wsCloseOp      byte = 0x8
	wsPing         byte = 0x9
	wsPong         byte = 0xA
)

// WsError says why a WebSocket operation failed. Reason is a short tag:
// \"Handshake\", \"Protocol\", \"Closed\", \"Send\" or \"Receive\".
type WsError struct {
	Reason  string
	Message string
}

func (e WsError) Error() string {
	return \"hive: websocket \" + e.Reason + \": \" + e.Message
}

// WsConnection is an open WebSocket. It is opaque in Hive: messages move
// through hive.net.wsSend and hive.net.wsReceive. Sending is safe from any
// number of virtual threads at once (writes are serialised), but one thread
// should own the receiving side — two concurrent receives would each take half
// of a fragmented message.
type WsConnection struct {
	ws *wsSocket
}

type wsSocket struct {
	conn net.Conn
	r    *bufio.Reader
	// A client must mask every frame it sends and a server must not, which is
	// the only difference between the two ends.
	masking bool
	// The HTTP request that opened the connection (hive.net.wsRequest).
	req HttpRequest
	// Guards writes and the closed flag; a message may be sent from any thread.
	mu     sync.Mutex
	closed bool
	// Payload accumulated so far across a fragmented message. Only the
	// receiving thread touches these.
	frag   []byte
	fragOp byte
}

// readFrame reads one whole frame off the wire and unmasks its payload.
func (s *wsSocket) readFrame() (byte, bool, []byte, error) {
	var head [2]byte
	if _, err := io.ReadFull(s.r, head[:]); err != nil {
		return 0, false, nil, err
	}
	fin := head[0]&0x80 != 0
	opcode := head[0] & 0x0F
	masked := head[1]&0x80 != 0
	length := uint64(head[1] & 0x7F)
	switch length {
	case 126:
		var ext [2]byte
		if _, err := io.ReadFull(s.r, ext[:]); err != nil {
			return 0, false, nil, err
		}
		length = uint64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err := io.ReadFull(s.r, ext[:]); err != nil {
			return 0, false, nil, err
		}
		length = binary.BigEndian.Uint64(ext[:])
	}
	if length > wsMaxPayload {
		return 0, false, nil, errors.New(\"the peer announced a frame larger than the 32MiB limit\")
	}
	var mask [4]byte
	if masked {
		if _, err := io.ReadFull(s.r, mask[:]); err != nil {
			return 0, false, nil, err
		}
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(s.r, payload); err != nil {
		return 0, false, nil, err
	}
	if masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	return opcode, fin, payload, nil
}

// writeFrame sends one unfragmented frame, masking the payload with a fresh
// random key when this end is the client.
func (s *wsSocket) writeFrame(opcode byte, payload []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errors.New(\"the connection is closed\")
	}
	maskBit := byte(0)
	if s.masking {
		maskBit = 0x80
	}
	n := len(payload)
	frame := []byte{0x80 | opcode}
	switch {
	case n < 126:
		frame = append(frame, maskBit|byte(n))
	case n <= 0xFFFF:
		frame = append(frame, maskBit|126)
		var ext [2]byte
		binary.BigEndian.PutUint16(ext[:], uint16(n))
		frame = append(frame, ext[:]...)
	default:
		frame = append(frame, maskBit|127)
		var ext [8]byte
		binary.BigEndian.PutUint64(ext[:], uint64(n))
		frame = append(frame, ext[:]...)
	}
	if s.masking {
		var mask [4]byte
		if _, err := rand.Read(mask[:]); err != nil {
			return err
		}
		frame = append(frame, mask[:]...)
		for i := 0; i < n; i++ {
			frame = append(frame, payload[i]^mask[i%4])
		}
	} else {
		frame = append(frame, payload...)
	}
	_, err := s.conn.Write(frame)
	return err
}

// close shuts the underlying connection down exactly once, so a handler that
// closes explicitly and the deferred close of a served connection cannot fight.
func (s *wsSocket) close() {
	s.mu.Lock()
	already := s.closed
	s.closed = true
	s.mu.Unlock()
	if !already {
		_ = s.conn.Close()
	}
}

// receive returns the payload of the next data message, answering pings and
// stitching continuation frames back together on the way. A close frame, or a
// connection that has gone away, ends the wait with a \"Closed\" error.
func (s *wsSocket) receive() (string, *WsError) {
	for {
		opcode, fin, payload, err := s.readFrame()
		if err != nil {
			if err == io.EOF || err == io.ErrUnexpectedEOF {
				s.close()
				return \"\", &WsError{Reason: \"Closed\", Message: \"the peer closed the connection\"}
			}
			return \"\", &WsError{Reason: \"Receive\", Message: err.Error()}
		}
		switch opcode {
		case wsPing:
			// A pong must echo the ping's payload back unchanged.
			if err := s.writeFrame(wsPong, payload); err != nil {
				return \"\", &WsError{Reason: \"Send\", Message: err.Error()}
			}
		case wsPong:
			// An unsolicited pong is just a keepalive; keep waiting.
		case wsCloseOp:
			_ = s.writeFrame(wsCloseOp, payload)
			s.close()
			return \"\", &WsError{Reason: \"Closed\", Message: \"the peer closed the connection\"}
		case wsText, wsBinary:
			if fin {
				return string(payload), nil
			}
			s.frag = append([]byte{}, payload...)
			s.fragOp = opcode
		case wsContinuation:
			if s.fragOp == 0 {
				return \"\", &WsError{
					Reason:  \"Protocol\",
					Message: \"a continuation frame arrived with no message to continue\",
				}
			}
			s.frag = append(s.frag, payload...)
			if fin {
				message := string(s.frag)
				s.frag, s.fragOp = nil, 0
				return message, nil
			}
		default:
			return \"\", &WsError{
				Reason:  \"Protocol\",
				Message: \"unknown opcode \" + strconv.Itoa(int(opcode)),
			}
		}
	}
}

// wsAcceptKey is the Sec-WebSocket-Accept value proving we saw the client's key.
func wsAcceptKey(key string) string {
	sum := sha1.Sum([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(sum[:])
}

// wsAccept completes the server side of the handshake, hijacking the connection
// away from net/http so frames can be read and written directly. A rejected
// handshake is answered here, so the caller only has to give up.
func wsAccept(w http.ResponseWriter, r *http.Request) (*wsSocket, error) {
	key := r.Header.Get(\"Sec-WebSocket-Key\")
	upgrading := strings.Contains(strings.ToLower(r.Header.Get(\"Connection\")), \"upgrade\") &&
		strings.EqualFold(r.Header.Get(\"Upgrade\"), \"websocket\")
	if !upgrading || key == \"\" {
		http.Error(w, \"expected a WebSocket upgrade request\", http.StatusBadRequest)
		return nil, errors.New(\"not a WebSocket upgrade request\")
	}
	if version := r.Header.Get(\"Sec-WebSocket-Version\"); version != \"13\" {
		w.Header().Set(\"Sec-WebSocket-Version\", \"13\")
		http.Error(w, \"unsupported WebSocket version \"+version, http.StatusBadRequest)
		return nil, errors.New(\"unsupported WebSocket version \" + version)
	}
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, \"this connection cannot be upgraded\", http.StatusInternalServerError)
		return nil, errors.New(\"the connection cannot be hijacked\")
	}
	// Read the request body before hijacking: afterwards net/http is out of the
	// picture and the socket carries frames, not HTTP.
	body, _ := io.ReadAll(r.Body)
	conn, rw, err := hijacker.Hijack()
	if err != nil {
		return nil, err
	}
	handshake := \"HTTP/1.1 101 Switching Protocols\\r\\n\" +
		\"Upgrade: websocket\\r\\n\" +
		\"Connection: Upgrade\\r\\n\" +
		\"Sec-WebSocket-Accept: \" + wsAcceptKey(key) + \"\\r\\n\\r\\n\"
	if _, err := rw.WriteString(handshake); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if err := rw.Flush(); err != nil {
		_ = conn.Close()
		return nil, err
	}
	// rw.Reader may already hold bytes the client pipelined behind the
	// handshake, so the frame reader must be that same buffered reader.
	return &wsSocket{
		conn: conn,
		r:    rw.Reader,
		req: HttpRequest{
			Method:  r.Method,
			Url:     r.URL.String(),
			Headers: headerTable(r.Header),
			Body:    string(body),
		},
	}, nil
}

// WsConnect opens a client WebSocket to a ws:// or wss:// URL. Backs
// hive.net.wsConnect.
func WsConnect(rawURL string) Result[WsConnection, WsError] {
	fail := func(reason string, message string) Result[WsConnection, WsError] {
		return Err[WsConnection, WsError](WsError{Reason: reason, Message: message})
	}
	target, err := url.Parse(rawURL)
	if err != nil {
		return fail(\"Handshake\", \"cannot parse the URL: \"+err.Error())
	}
	secure := false
	switch strings.ToLower(target.Scheme) {
	case \"ws\", \"http\":
	case \"wss\", \"https\":
		secure = true
	default:
		return fail(\"Handshake\", \"unsupported scheme \"+strconv.Quote(target.Scheme)+\"; expected ws:// or wss://\")
	}
	address := target.Host
	if target.Port() == \"\" {
		if secure {
			address = net.JoinHostPort(address, \"443\")
		} else {
			address = net.JoinHostPort(address, \"80\")
		}
	}
	conn, err := net.DialTimeout(\"tcp\", address, 30*time.Second)
	if err != nil {
		return fail(\"Handshake\", err.Error())
	}
	if secure {
		secured := tls.Client(conn, &tls.Config{ServerName: target.Hostname()})
		if err := secured.Handshake(); err != nil {
			_ = conn.Close()
			return fail(\"Handshake\", err.Error())
		}
		conn = secured
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		_ = conn.Close()
		return fail(\"Handshake\", err.Error())
	}
	key := base64.StdEncoding.EncodeToString(nonce[:])
	path := target.RequestURI()
	if path == \"\" {
		path = \"/\"
	}
	request := \"GET \" + path + \" HTTP/1.1\\r\\n\" +
		\"Host: \" + target.Host + \"\\r\\n\" +
		\"Upgrade: websocket\\r\\n\" +
		\"Connection: Upgrade\\r\\n\" +
		\"Sec-WebSocket-Key: \" + key + \"\\r\\n\" +
		\"Sec-WebSocket-Version: 13\\r\\n\\r\\n\"
	if _, err := io.WriteString(conn, request); err != nil {
		_ = conn.Close()
		return fail(\"Handshake\", err.Error())
	}
	// The response is parsed out of the buffered reader that then goes on to
	// read frames, so nothing the server sent immediately after 101 is lost.
	reader := bufio.NewReader(conn)
	resp, err := http.ReadResponse(reader, nil)
	if err != nil {
		_ = conn.Close()
		return fail(\"Handshake\", err.Error())
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		_ = conn.Close()
		return fail(\"Handshake\", \"the server answered \"+strconv.Itoa(resp.StatusCode)+\" instead of 101\")
	}
	if resp.Header.Get(\"Sec-WebSocket-Accept\") != wsAcceptKey(key) {
		_ = conn.Close()
		return fail(\"Handshake\", \"the server's Sec-WebSocket-Accept does not match the key we sent\")
	}
	return Ok[WsConnection, WsError](WsConnection{ws: &wsSocket{
		conn:    conn,
		r:       reader,
		masking: true,
		req: HttpRequest{
			Method:  \"GET\",
			Url:     rawURL,
			Headers: headerTable(resp.Header),
		},
	}})
}

// WsSend delivers one text message and reports how many bytes it carried.
// Backs hive.net.wsSend.
func WsSend(c WsConnection, message string) Result[int, WsError] {
	if c.ws == nil {
		return Err[int, WsError](WsError{Reason: \"Closed\", Message: \"the connection is not open\"})
	}
	if err := c.ws.writeFrame(wsText, []byte(message)); err != nil {
		return Err[int, WsError](WsError{Reason: \"Send\", Message: err.Error()})
	}
	return Ok[int, WsError](len(message))
}

// WsReceive blocks the calling virtual thread until the peer sends a message,
// then returns its payload. Pings are answered and fragmented messages
// reassembled along the way; a connection the peer has closed is a
// Result.Error whose reason is \"Closed\". Backs hive.net.wsReceive.
func WsReceive(c WsConnection) Result[string, WsError] {
	if c.ws == nil {
		return Err[string, WsError](WsError{Reason: \"Closed\", Message: \"the connection is not open\"})
	}
	message, werr := c.ws.receive()
	if werr != nil {
		return Err[string, WsError](*werr)
	}
	return Ok[string, WsError](message)
}

// WsRequest is the HTTP request that opened the connection — its method, url
// and headers — so a server handler can route or authenticate. Backs
// hive.net.wsRequest.
func WsRequest(c WsConnection) HttpRequest {
	if c.ws == nil {
		return HttpRequest{Headers: Table{}}
	}
	return c.ws.req
}

// WsClose sends a normal-closure frame and shuts the connection down. Calling
// it more than once is harmless. Backs hive.net.wsClose.
func WsClose(c WsConnection) {
	if c.ws == nil {
		return
	}
	// 1000 (normal closure), big-endian, as the close frame's payload.
	_ = c.ws.writeFrame(wsCloseOp, []byte{0x03, 0xE8})
	c.ws.close()
}

// WsServe accepts WebSocket connections on port and runs handler once per
// connection, each on its own virtual thread; the connection is closed when the
// handler returns. It blocks forever, and panics if the listener cannot start.
// Backs hive.net.wsServe.
func WsServe(port int, handler func(WsConnection)) {
	mux := http.NewServeMux()
	mux.HandleFunc(\"/\", func(w http.ResponseWriter, r *http.Request) {
		socket, err := wsAccept(w, r)
		if err != nil {
			// wsAccept has already answered the rejected handshake.
			return
		}
		defer socket.close()
		handler(WsConnection{ws: socket})
	})
	if err := http.ListenAndServe(\":\"+strconv.Itoa(port), mux); err != nil {
		panic(\"hive: net.wsServe: \" + err.Error())
	}
}

// ---------------------------------------------------------------------------
// Raw TCP sockets
// ---------------------------------------------------------------------------

// SocketError says why a socket operation failed. Reason is a short tag:
// \"Connect\", \"Closed\", \"Send\" or \"Receive\".
type SocketError struct {
	Reason  string
	Message string
}

func (e SocketError) Error() string {
	return \"hive: socket \" + e.Reason + \": \" + e.Message
}

// SocketConnection is an open TCP stream. Reads go through one buffered
// reader, so hive.net.socketReceive and hive.net.socketReceiveLine can be
// mixed on the same connection without losing bytes between them.
type SocketConnection struct {
	sock *socket
}

type socket struct {
	conn net.Conn
	r    *bufio.Reader
}

// SocketConnect dials a TCP server. Backs hive.net.socketConnect.
func SocketConnect(host string, port int) Result[SocketConnection, SocketError] {
	address := net.JoinHostPort(host, strconv.Itoa(port))
	conn, err := net.DialTimeout(\"tcp\", address, 30*time.Second)
	if err != nil {
		return Err[SocketConnection, SocketError](SocketError{Reason: \"Connect\", Message: err.Error()})
	}
	return Ok[SocketConnection, SocketError](SocketConnection{
		sock: &socket{conn: conn, r: bufio.NewReader(conn)},
	})
}

// SocketSend writes data to the stream and returns the number of bytes written.
// Backs hive.net.socketSend.
func SocketSend(c SocketConnection, data string) Result[int, SocketError] {
	if c.sock == nil {
		return Err[int, SocketError](SocketError{Reason: \"Closed\", Message: \"the connection is not open\"})
	}
	n, err := c.sock.conn.Write([]byte(data))
	if err != nil {
		return Err[int, SocketError](SocketError{Reason: \"Send\", Message: err.Error()})
	}
	return Ok[int, SocketError](n)
}

// SocketReceive blocks until at least one byte arrives and returns up to limit
// bytes of it — a short read is normal on a stream, so a protocol that needs a
// fixed number of bytes must keep calling. A peer that has closed the stream
// yields a Result.Error whose reason is \"Closed\". Backs hive.net.socketReceive.
func SocketReceive(c SocketConnection, limit int) Result[string, SocketError] {
	if c.sock == nil {
		return Err[string, SocketError](SocketError{Reason: \"Closed\", Message: \"the connection is not open\"})
	}
	if limit <= 0 {
		return Ok[string, SocketError](\"\")
	}
	buf := make([]byte, limit)
	n, err := c.sock.r.Read(buf)
	if n > 0 {
		return Ok[string, SocketError](string(buf[:n]))
	}
	if err == io.EOF {
		return Err[string, SocketError](SocketError{Reason: \"Closed\", Message: \"the peer closed the connection\"})
	}
	if err != nil {
		return Err[string, SocketError](SocketError{Reason: \"Receive\", Message: err.Error()})
	}
	return Ok[string, SocketError](\"\")
}

// SocketReceiveLine blocks until a newline arrives and returns the line without
// its trailing \"\\n\" (or \"\\r\\n\") — the read for line-oriented protocols. Backs
// hive.net.socketReceiveLine.
func SocketReceiveLine(c SocketConnection) Result[string, SocketError] {
	if c.sock == nil {
		return Err[string, SocketError](SocketError{Reason: \"Closed\", Message: \"the connection is not open\"})
	}
	line, err := c.sock.r.ReadString('\\n')
	line = strings.TrimRight(line, \"\\n\")
	line = strings.TrimRight(line, \"\\r\")
	if err != nil {
		// Whatever preceded the EOF is still a line worth delivering; only an
		// empty tail means the stream is done.
		if line != \"\" {
			return Ok[string, SocketError](line)
		}
		if err == io.EOF {
			return Err[string, SocketError](SocketError{Reason: \"Closed\", Message: \"the peer closed the connection\"})
		}
		return Err[string, SocketError](SocketError{Reason: \"Receive\", Message: err.Error()})
	}
	return Ok[string, SocketError](line)
}

// SocketPeer is the connection's remote address (\"host:port\"). Backs
// hive.net.socketPeer.
func SocketPeer(c SocketConnection) string {
	if c.sock == nil {
		return \"\"
	}
	return c.sock.conn.RemoteAddr().String()
}

// SocketClose shuts the connection down. Calling it more than once is
// harmless. Backs hive.net.socketClose.
func SocketClose(c SocketConnection) {
	if c.sock != nil {
		_ = c.sock.conn.Close()
	}
}

// SocketServe accepts TCP connections on port and runs handler once per
// connection, each on its own virtual thread; the connection is closed when the
// handler returns. It blocks forever, and panics if the listener cannot start.
// Backs hive.net.socketServe.
func SocketServe(port int, handler func(SocketConnection)) {
	listener, err := net.Listen(\"tcp\", \":\"+strconv.Itoa(port))
	if err != nil {
		panic(\"hive: net.socketServe: \" + err.Error())
	}
	for {
		conn, err := listener.Accept()
		if err != nil {
			// One peer vanishing mid-handshake must not take the server down.
			continue
		}
		go func(c net.Conn) {
			defer c.Close()
			handler(SocketConnection{sock: &socket{conn: c, r: bufio.NewReader(c)}})
		}(conn)
	}
}
"
}

// ---------------------------------------------------------------------------
// hive.json
// ---------------------------------------------------------------------------

/// Source of `hive/json.go`: the JSON module (`hive.json`). The decoders and
/// encoders here are the pieces the compiler's derived `jsonDecode_T` /
/// `jsonEncode_T` functions are built out of.
pub fn json_go() -> String {
  "package hive

import (
	\"encoding/json\"
	\"strconv\"
	\"strings\"
)

// JsonError describes why a JSON document didn't match the expected type:
// the exact path that failed, what the type expected there, and what the
// document actually held.
type JsonError struct {
	Path     string
	Expected string
	Found    string
}

func (e JsonError) Error() string {
	return \"hive: json error at \" + e.Path + \": expected \" + e.Expected + \", found \" + e.Found
}

// JsonValue is an order-preserving parsed JSON document.
type JsonValue struct {
	Kind byte // 'n' null, 'b' bool, '#' number, 's' string, 'a' array, 'o' object
	Str  string
	Num  string
	Bool bool
	Arr  []JsonValue
	Obj  []JsonMember
}

type JsonMember struct {
	Key   string
	Value JsonValue
}

func parseJsonValue(d *json.Decoder) (JsonValue, error) {
	t, err := d.Token()
	if err != nil {
		return JsonValue{}, err
	}
	return parseJsonToken(d, t)
}

func parseJsonToken(d *json.Decoder, t json.Token) (JsonValue, error) {
	switch x := t.(type) {
	case json.Delim:
		if x == '{' {
			obj := []JsonMember{}
			for d.More() {
				kt, err := d.Token()
				if err != nil {
					return JsonValue{}, err
				}
				key, _ := kt.(string)
				val, err := parseJsonValue(d)
				if err != nil {
					return JsonValue{}, err
				}
				obj = append(obj, JsonMember{Key: key, Value: val})
			}
			if _, err := d.Token(); err != nil {
				return JsonValue{}, err
			}
			return JsonValue{Kind: 'o', Obj: obj}, nil
		}
		arr := []JsonValue{}
		for d.More() {
			val, err := parseJsonValue(d)
			if err != nil {
				return JsonValue{}, err
			}
			arr = append(arr, val)
		}
		if _, err := d.Token(); err != nil {
			return JsonValue{}, err
		}
		return JsonValue{Kind: 'a', Arr: arr}, nil
	case string:
		return JsonValue{Kind: 's', Str: x}, nil
	case json.Number:
		return JsonValue{Kind: '#', Num: x.String()}, nil
	case bool:
		return JsonValue{Kind: 'b', Bool: x}, nil
	}
	return JsonValue{Kind: 'n'}, nil
}

func jsonKindName(v JsonValue) string {
	switch v.Kind {
	case 'n':
		return \"null\"
	case 'b':
		return strconv.FormatBool(v.Bool)
	case '#':
		return \"the number \" + v.Num
	case 's':
		return \"the string \" + strconv.Quote(v.Str)
	case 'a':
		return \"an array\"
	}
	return \"an object\"
}

// JsonParse backs `hive.json.parse(text) with T`; the decoder argument is
// derived from T at compile time.
func JsonParse[T any](text string, dec func(JsonValue, string) (T, *JsonError)) Result[T, JsonError] {
	d := json.NewDecoder(strings.NewReader(text))
	d.UseNumber()
	v, err := parseJsonValue(d)
	if err != nil {
		return Err[T, JsonError](JsonError{Path: \"$\", Expected: \"valid JSON\", Found: err.Error()})
	}
	out, jerr := dec(v, \"$\")
	if jerr != nil {
		return Err[T, JsonError](*jerr)
	}
	return Ok[T, JsonError](out)
}

func JsonStr(v JsonValue, path string) (string, *JsonError) {
	if v.Kind == 's' {
		return v.Str, nil
	}
	return \"\", &JsonError{Path: path, Expected: \"Str\", Found: jsonKindName(v)}
}

func JsonInt(v JsonValue, path string) (int, *JsonError) {
	if v.Kind == '#' {
		if i, err := strconv.Atoi(v.Num); err == nil {
			return i, nil
		}
	}
	return 0, &JsonError{Path: path, Expected: \"Int\", Found: jsonKindName(v)}
}

func JsonFloat(v JsonValue, path string) (float64, *JsonError) {
	if v.Kind == '#' {
		if f, err := strconv.ParseFloat(v.Num, 64); err == nil {
			return f, nil
		}
	}
	return 0, &JsonError{Path: path, Expected: \"Float\", Found: jsonKindName(v)}
}

func JsonBool(v JsonValue, path string) (bool, *JsonError) {
	if v.Kind == 'b' {
		return v.Bool, nil
	}
	return false, &JsonError{Path: path, Expected: \"Bool\", Found: jsonKindName(v)}
}

// JsonAtom decodes a JSON string holding an atom's visual form.
func JsonAtom(v JsonValue, path string) (Atom, *JsonError) {
	if v.Kind == 's' {
		for i, name := range atomNames {
			if name == v.Str {
				return Atom(i), nil
			}
		}
	}
	return 0, &JsonError{Path: path, Expected: \"a known atom\", Found: jsonKindName(v)}
}

func JsonObject(v JsonValue, path string) ([]JsonMember, *JsonError) {
	if v.Kind == 'o' {
		return v.Obj, nil
	}
	return nil, &JsonError{Path: path, Expected: \"an object\", Found: jsonKindName(v)}
}

func JsonField(obj []JsonMember, key string, path string) (JsonValue, *JsonError) {
	for _, m := range obj {
		if m.Key == key {
			return m.Value, nil
		}
	}
	return JsonValue{}, &JsonError{Path: path + \".\" + key, Expected: \"a value\", Found: \"nothing\"}
}

// JsonVariant unwraps the `{\"VariantName\": {...}}` encoding of tagged
// unions.
func JsonVariant(v JsonValue, path string) (string, JsonValue, *JsonError) {
	if v.Kind == 'o' && len(v.Obj) == 1 {
		return v.Obj[0].Key, v.Obj[0].Value, nil
	}
	return \"\", JsonValue{}, &JsonError{Path: path, Expected: \"an object with a single variant key\", Found: jsonKindName(v)}
}

func JsonVec[T any](v JsonValue, path string, elem func(JsonValue, string) (T, *JsonError)) ([]T, *JsonError) {
	if v.Kind != 'a' {
		return nil, &JsonError{Path: path, Expected: \"a vector\", Found: jsonKindName(v)}
	}
	out := make([]T, 0, len(v.Arr))
	for i, item := range v.Arr {
		e, jerr := elem(item, path+\"[\"+strconv.Itoa(i)+\"]\")
		if jerr != nil {
			return nil, jerr
		}
		out = append(out, e)
	}
	return out, nil
}

// JsonVecN also enforces the static length of e.g. `Str[3]`.
func JsonVecN[T any](v JsonValue, path string, n int, elem func(JsonValue, string) (T, *JsonError)) ([]T, *JsonError) {
	if v.Kind != 'a' || len(v.Arr) != n {
		return nil, &JsonError{Path: path, Expected: \"a vector of length \" + strconv.Itoa(n), Found: jsonKindName(v)}
	}
	return JsonVec(v, path, elem)
}

// JsonFlatten turns any JSON subtree into a Table of [path, value] rows —
// the type-safe holder for JSON that isn't modelled statically.
func JsonFlatten(v JsonValue, path string) (Table, *JsonError) {
	table := Table{}
	flattenJson(v, \"\", &table)
	return table, nil
}

func flattenJson(v JsonValue, prefix string, table *Table) {
	switch v.Kind {
	case 'o':
		for _, m := range v.Obj {
			key := m.Key
			if prefix != \"\" {
				key = prefix + \".\" + key
			}
			flattenJson(m.Value, key, table)
		}
	case 'a':
		for i, item := range v.Arr {
			flattenJson(item, prefix+\"[\"+strconv.Itoa(i)+\"]\", table)
		}
	default:
		*table = append(*table, []string{prefix, jsonLeafStr(v)})
	}
}

func jsonLeafStr(v JsonValue) string {
	switch v.Kind {
	case 's':
		return v.Str
	case '#':
		return v.Num
	case 'b':
		return strconv.FormatBool(v.Bool)
	}
	return \"null\"
}

// JsonGet looks a path up in a flattened Table.
func JsonGet(t Table, path string) Result[string, JsonError] {
	for _, row := range t {
		if len(row) >= 2 && row[0] == path {
			return Ok[string, JsonError](row[1])
		}
	}
	return Err[string, JsonError](JsonError{Path: path, Expected: \"a value\", Found: \"nothing\"})
}

// JsonTable reads a JSON array of flat objects as a headered Table (the same
// shape `using` produces from a CSV). Every object must carry the same keys
// as the first one, and every value must be a leaf.
func JsonTable(text string) Result[Table, JsonError] {
	d := json.NewDecoder(strings.NewReader(text))
	d.UseNumber()
	v, err := parseJsonValue(d)
	if err != nil {
		return Err[Table, JsonError](JsonError{Path: \"$\", Expected: \"valid JSON\", Found: err.Error()})
	}
	if v.Kind != 'a' {
		return Err[Table, JsonError](JsonError{Path: \"$\", Expected: \"an array of objects\", Found: jsonKindName(v)})
	}
	table := Table{}
	for i, item := range v.Arr {
		path := \"$[\" + strconv.Itoa(i) + \"]\"
		if item.Kind != 'o' {
			return Err[Table, JsonError](JsonError{Path: path, Expected: \"a flat object\", Found: jsonKindName(item)})
		}
		if i == 0 {
			header := []string{}
			for _, m := range item.Obj {
				header = append(header, m.Key)
			}
			table = append(table, header)
		}
		header := table[0]
		if len(item.Obj) != len(header) {
			return Err[Table, JsonError](JsonError{Path: path, Expected: \"an object with keys \" + strings.Join(header, \", \"), Found: \"an object with \" + strconv.Itoa(len(item.Obj)) + \" keys\"})
		}
		row := []string{}
		for _, key := range header {
			cell, jerr := JsonField(item.Obj, key, path)
			if jerr != nil {
				return Err[Table, JsonError](*jerr)
			}
			if cell.Kind == 'a' || cell.Kind == 'o' {
				return Err[Table, JsonError](JsonError{Path: path + \".\" + key, Expected: \"a leaf value\", Found: jsonKindName(cell)})
			}
			row = append(row, jsonLeafStr(cell))
		}
		table = append(table, row)
	}
	return Ok[Table, JsonError](table)
}

func JsonEncodeStr(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func JsonEncodeInt(i int) string { return strconv.Itoa(i) }

func JsonEncodeFloat(f float64) string { return strconv.FormatFloat(f, 'g', -1, 64) }

func JsonEncodeBool(b bool) string { return strconv.FormatBool(b) }

// Atoms encode as their visual form.
func JsonEncodeAtom(a Atom) string { return JsonEncodeStr(a.String()) }

func JsonEncodeVec[T any](items []T, elem func(T) string) string {
	var b strings.Builder
	b.WriteByte('[')
	for i, item := range items {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(elem(item))
	}
	b.WriteByte(']')
	return b.String()
}

type jsonTree struct {
	leaf  bool
	value string
	isArr bool
	keys  []string
	kids  map[string]*jsonTree
	items map[int]*jsonTree
	max   int
}

func newJsonTree() *jsonTree {
	return &jsonTree{kids: map[string]*jsonTree{}, items: map[int]*jsonTree{}, max: -1}
}

// JsonEncodeTable re-nests a Table of [path, value] rows into JSON (the
// inverse of JsonFlatten).
func JsonEncodeTable(t Table) string {
	root := newJsonTree()
	for _, row := range t {
		if len(row) >= 2 {
			insertJsonPath(root, row[0], row[1])
		}
	}
	return encodeJsonTree(root)
}

func insertJsonPath(node *jsonTree, path string, value string) {
	if path == \"\" {
		node.leaf = true
		node.value = value
		return
	}
	seg, idx, isIdx, rest := splitJsonPath(path)
	if isIdx {
		node.isArr = true
		child, ok := node.items[idx]
		if !ok {
			child = newJsonTree()
			node.items[idx] = child
			if idx > node.max {
				node.max = idx
			}
		}
		insertJsonPath(child, rest, value)
		return
	}
	child, ok := node.kids[seg]
	if !ok {
		child = newJsonTree()
		node.kids[seg] = child
		node.keys = append(node.keys, seg)
	}
	insertJsonPath(child, rest, value)
}

func splitJsonPath(path string) (string, int, bool, string) {
	if strings.HasPrefix(path, \"[\") {
		end := strings.IndexByte(path, ']')
		if end < 0 {
			return path, 0, false, \"\"
		}
		idx, _ := strconv.Atoi(path[1:end])
		rest := strings.TrimPrefix(path[end+1:], \".\")
		return \"\", idx, true, rest
	}
	for i := 0; i < len(path); i++ {
		if path[i] == '.' {
			return path[:i], 0, false, path[i+1:]
		}
		if path[i] == '[' {
			return path[:i], 0, false, path[i:]
		}
	}
	return path, 0, false, \"\"
}

func encodeJsonTree(node *jsonTree) string {
	if node.leaf {
		return jsonLeafEncode(node.value)
	}
	var b strings.Builder
	if node.isArr {
		b.WriteByte('[')
		for i := 0; i <= node.max; i++ {
			if i > 0 {
				b.WriteByte(',')
			}
			if child, ok := node.items[i]; ok {
				b.WriteString(encodeJsonTree(child))
			} else {
				b.WriteString(\"null\")
			}
		}
		b.WriteByte(']')
		return b.String()
	}
	b.WriteByte('{')
	for i, key := range node.keys {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(JsonEncodeStr(key))
		b.WriteByte(':')
		b.WriteString(encodeJsonTree(node.kids[key]))
	}
	b.WriteByte('}')
	return b.String()
}

// A leaf that reads as a JSON number/bool/null keeps its type on the way
// back out; everything else re-encodes as a string.
func jsonLeafEncode(value string) string {
	if value == \"true\" || value == \"false\" || value == \"null\" {
		return value
	}
	if _, err := strconv.ParseFloat(value, 64); err == nil {
		return value
	}
	return JsonEncodeStr(value)
}

// JsonEncodeDynamic is the fallback when the compiler couldn't infer a
// static type for `hive.json.encode`'s argument.
func JsonEncodeDynamic(v any) string {
	switch x := v.(type) {
	case string:
		return JsonEncodeStr(x)
	case int:
		return JsonEncodeInt(x)
	case float64:
		return JsonEncodeFloat(x)
	case bool:
		return JsonEncodeBool(x)
	case Atom:
		return JsonEncodeAtom(x)
	case Table:
		return JsonEncodeTable(x)
	case []string:
		return JsonEncodeVec(x, JsonEncodeStr)
	}
	panic(\"hive: json.encode: cannot derive an encoder for this value\")
}
"
}

// ---------------------------------------------------------------------------
// hive.crypto
// ---------------------------------------------------------------------------

/// Source of `hive/crypto.go`: the cryptography module (`hive.crypto`) —
/// hashes, HMAC, base64, random bytes, and JSON Web Tokens. JWT payloads are
/// decoded with the JSON module's machinery and their exp/nbf claims checked
/// against the time module's clock, so both are pulled in alongside it.
pub fn crypto_go() -> String {
  "package hive

import (
	\"crypto/hmac\"
	\"crypto/rand\"
	\"crypto/sha256\"
	\"crypto/sha512\"
	\"encoding/base64\"
	\"encoding/hex\"
	\"encoding/json\"
	\"strconv\"
	\"strings\"
)

// CryptoError says why a crypto operation failed (invalid base64, a bad
// token, ...). Reason is a short tag: \"Malformed\", \"BadSignature\",
// \"Expired\", \"NotYetValid\", \"AlgorithmMismatch\" or \"ClaimType\".
type CryptoError struct {
	Reason  string
	Message string
}

func (e CryptoError) Error() string {
	return \"hive: crypto \" + e.Reason + \": \" + e.Message
}

// JwtHeader is a token's decoded (unverified) header.
type JwtHeader struct {
	Alg string
	Typ string
	Kid string
}

// hmacSha256Raw is the HMAC-SHA256 of input keyed by secret.
func hmacSha256Raw(secret string, input string) []byte {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(input))
	return mac.Sum(nil)
}

// Sha256 returns the lowercase-hex SHA-256 digest of input.
func Sha256(input string) string {
	sum := sha256.Sum256([]byte(input))
	return hex.EncodeToString(sum[:])
}

// Sha512 returns the lowercase-hex SHA-512 digest of input.
func Sha512(input string) string {
	sum := sha512.Sum512([]byte(input))
	return hex.EncodeToString(sum[:])
}

// HmacSha256 returns the lowercase-hex HMAC-SHA256 of input under key.
func HmacSha256(input string, key string) string {
	return hex.EncodeToString(hmacSha256Raw(key, input))
}

// Base64Encode standard-base64-encodes input.
func Base64Encode(input string) string {
	return base64.StdEncoding.EncodeToString([]byte(input))
}

// Base64Decode reverses Base64Encode, or reports a CryptoError on bad input.
func Base64Decode(input string) Result[string, CryptoError] {
	b, err := base64.StdEncoding.DecodeString(input)
	if err != nil {
		return Err[string, CryptoError](CryptoError{Reason: \"Malformed\", Message: \"input is not valid base64\"})
	}
	return Ok[string, CryptoError](string(b))
}

// RandomHex returns n cryptographically random bytes as a 2n-char hex string.
func RandomHex(n int) string {
	if n <= 0 {
		return \"\"
	}
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return \"\"
	}
	return hex.EncodeToString(buf)
}

// JwtSign builds an HS256 token from an already-JSON-encoded payload and a
// shared secret. HMAC signing cannot fail, so it returns a plain string.
func JwtSign(payloadJSON string, secret string) string {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{\"alg\":\"HS256\",\"typ\":\"JWT\"}`))
	payload := base64.RawURLEncoding.EncodeToString([]byte(payloadJSON))
	input := header + \".\" + payload
	sig := base64.RawURLEncoding.EncodeToString(hmacSha256Raw(secret, input))
	return input + \".\" + sig
}

// jwtParsePayload runs a derived decoder over a raw JSON payload.
func jwtParsePayload[T any](payload []byte, dec func(JsonValue, string) (T, *JsonError)) (T, *JsonError) {
	var zero T
	d := json.NewDecoder(strings.NewReader(string(payload)))
	d.UseNumber()
	v, err := parseJsonValue(d)
	if err != nil {
		return zero, &JsonError{Path: \"$\", Expected: \"valid JSON\", Found: err.Error()}
	}
	return dec(v, \"$\")
}

// jwtCheckTime enforces the exp/nbf registered claims against the current
// time. Absent claims are skipped.
func jwtCheckTime(payload []byte) *CryptoError {
	var claims struct {
		Exp json.Number `json:\"exp\"`
		Nbf json.Number `json:\"nbf\"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return &CryptoError{Reason: \"Malformed\", Message: \"payload is not a JSON object\"}
	}
	now := int64(Now())
	if claims.Exp != \"\" {
		if exp, err := claims.Exp.Int64(); err == nil && now >= exp {
			return &CryptoError{Reason: \"Expired\", Message: \"token has expired\"}
		}
	}
	if claims.Nbf != \"\" {
		if nbf, err := claims.Nbf.Int64(); err == nil && now < nbf {
			return &CryptoError{Reason: \"NotYetValid\", Message: \"token is not valid yet\"}
		}
	}
	return nil
}

// JwtVerify checks an HS256 token's signature and its exp/nbf claims against
// the current time, then decodes the payload into T with the derived decoder.
func JwtVerify[T any](token string, secret string, dec func(JsonValue, string) (T, *JsonError)) Result[T, CryptoError] {
	fail := func(reason, msg string) Result[T, CryptoError] {
		return Err[T, CryptoError](CryptoError{Reason: reason, Message: msg})
	}
	parts := strings.Split(token, \".\")
	if len(parts) != 3 {
		return fail(\"Malformed\", \"expected three dot-separated segments\")
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return fail(\"Malformed\", \"header is not valid base64url\")
	}
	var hdr struct {
		Alg string `json:\"alg\"`
	}
	if err := json.Unmarshal(headerBytes, &hdr); err != nil {
		return fail(\"Malformed\", \"header is not valid JSON\")
	}
	// Pin the algorithm: only HS256 is accepted, so \"none\" and any other alg
	// are rejected outright (no algorithm-confusion surface).
	if hdr.Alg != \"HS256\" {
		return fail(\"AlgorithmMismatch\", \"unsupported algorithm \"+strconv.Quote(hdr.Alg)+\"; only HS256 is supported\")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return fail(\"Malformed\", \"signature is not valid base64url\")
	}
	// Constant-time comparison.
	if !hmac.Equal(sig, hmacSha256Raw(secret, parts[0]+\".\"+parts[1])) {
		return fail(\"BadSignature\", \"signature does not match\")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return fail(\"Malformed\", \"payload is not valid base64url\")
	}
	if jerr := jwtCheckTime(payload); jerr != nil {
		return Err[T, CryptoError](*jerr)
	}
	out, jerr := jwtParsePayload(payload, dec)
	if jerr != nil {
		return fail(\"ClaimType\", jerr.Error())
	}
	return Ok[T, CryptoError](out)
}

// JwtDecode decodes a token's payload into T WITHOUT verifying its signature
// or time claims. Never trust the result for authorization.
func JwtDecode[T any](token string, dec func(JsonValue, string) (T, *JsonError)) Result[T, CryptoError] {
	parts := strings.Split(token, \".\")
	if len(parts) < 2 {
		return Err[T, CryptoError](CryptoError{Reason: \"Malformed\", Message: \"expected at least two dot-separated segments\"})
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return Err[T, CryptoError](CryptoError{Reason: \"Malformed\", Message: \"payload is not valid base64url\"})
	}
	out, jerr := jwtParsePayload(payload, dec)
	if jerr != nil {
		return Err[T, CryptoError](CryptoError{Reason: \"ClaimType\", Message: jerr.Error()})
	}
	return Ok[T, CryptoError](out)
}

// JwtReadHeader decodes a token's header (alg/typ/kid) without verifying it —
// handy for choosing a key by \"kid\" before calling JwtVerify.
func JwtReadHeader(token string) Result[JwtHeader, CryptoError] {
	parts := strings.Split(token, \".\")
	if len(parts) < 1 || parts[0] == \"\" {
		return Err[JwtHeader, CryptoError](CryptoError{Reason: \"Malformed\", Message: \"missing header segment\"})
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return Err[JwtHeader, CryptoError](CryptoError{Reason: \"Malformed\", Message: \"header is not valid base64url\"})
	}
	var h struct {
		Alg string `json:\"alg\"`
		Typ string `json:\"typ\"`
		Kid string `json:\"kid\"`
	}
	if err := json.Unmarshal(headerBytes, &h); err != nil {
		return Err[JwtHeader, CryptoError](CryptoError{Reason: \"Malformed\", Message: \"header is not valid JSON\"})
	}
	return Ok[JwtHeader, CryptoError](JwtHeader{Alg: h.Alg, Typ: h.Typ, Kid: h.Kid})
}
"
}

// ---------------------------------------------------------------------------
// hive.conv
// ---------------------------------------------------------------------------

/// Source of `hive/conv.go`: the conversion module (`hive.conv`) — numeric
/// rounding plus value/string conversions.
pub fn conv_go() -> String {
  "package hive

import (
	\"math\"
	\"strconv\"
)

// ConversionError describes a Str that could not be parsed into a number.
type ConversionError struct {
	Input   string
	Message string
}

func (e ConversionError) Error() string {
	return \"hive: conversion error for \" + strconv.Quote(e.Input) + \": \" + e.Message
}

// Ceil, Floor and Round convert a Float to the Int nearest it in the named
// direction (Round rounds halves away from zero).
func Ceil(x float64) int  { return int(math.Ceil(x)) }
func Floor(x float64) int { return int(math.Floor(x)) }
func Round(x float64) int { return int(math.Round(x)) }

// IntToFloat widens an Int to a Float.
func IntToFloat(x int) float64 { return float64(x) }

// IntToStr renders an Int in base 10.
func IntToStr(x int) string { return strconv.Itoa(x) }

// FloatToStr renders a Float in its shortest round-trippable form.
func FloatToStr(x float64) string { return strconv.FormatFloat(x, 'g', -1, 64) }

// StrToInt parses a base-10 Int, or reports a ConversionError.
func StrToInt(s string) Result[int, ConversionError] {
	i, err := strconv.Atoi(s)
	if err != nil {
		return Err[int, ConversionError](ConversionError{Input: s, Message: \"not a valid integer\"})
	}
	return Ok[int, ConversionError](i)
}

// StrToFloat parses a Float, or reports a ConversionError.
func StrToFloat(s string) Result[float64, ConversionError] {
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return Err[float64, ConversionError](ConversionError{Input: s, Message: \"not a valid number\"})
	}
	return Ok[float64, ConversionError](f)
}
"
}

// ---------------------------------------------------------------------------
// hive.env
// ---------------------------------------------------------------------------

/// Source of `hive/env.go`: the environment module (`hive.env`) — variables
/// resolved from a `.env` file, then from the OS environment.
pub fn env_go() -> String {
  "package hive

import (
	\"os\"
	\"strings\"
	\"sync\"
)

// EnvironmentError describes a variable that could not be resolved from a
// .env file or the OS environment.
type EnvironmentError struct {
	Key     string
	Message string
}

func (e EnvironmentError) Error() string {
	return \"hive: environment variable \" + e.Key + \": \" + e.Message
}

var envOnce sync.Once
var envVars map[string]string

// loadDotEnv reads the .env file in the working directory, or the parent
// directory if that one is absent, into envVars. It runs once, lazily, on the
// first EnvGet — after any startup chdir, so the working directory is the
// entrypoint's folder. A missing or unreadable file just leaves envVars empty.
func loadDotEnv() {
	envVars = map[string]string{}
	path := \"\"
	if _, err := os.Stat(\".env\"); err == nil {
		path = \".env\"
	} else if _, err := os.Stat(\"../.env\"); err == nil {
		path = \"../.env\"
	}
	if path == \"\" {
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	// Split on \\n; TrimSpace then also drops any trailing \\r on Windows files.
	for _, line := range strings.Split(string(data), \"\\n\") {
		line = strings.TrimSpace(line)
		if line == \"\" || strings.HasPrefix(line, \"#\") {
			continue
		}
		line = strings.TrimPrefix(line, \"export \")
		eq := strings.Index(line, \"=\")
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.Trim(strings.TrimSpace(line[eq+1:]), \"\\\"'\")
		if key != \"\" {
			envVars[key] = val
		}
	}
}

// EnvGet resolves a variable from the .env file first, then the OS
// environment; a variable set in neither yields an EnvironmentError. Backs
// hive.env.get.
func EnvGet(key string) Result[string, EnvironmentError] {
	envOnce.Do(loadDotEnv)
	if v, ok := envVars[key]; ok {
		return Ok[string, EnvironmentError](v)
	}
	if v, ok := os.LookupEnv(key); ok {
		return Ok[string, EnvironmentError](v)
	}
	return Err[string, EnvironmentError](EnvironmentError{Key: key, Message: \"not set\"})
}
"
}

// ---------------------------------------------------------------------------
// hive.term
// ---------------------------------------------------------------------------

/// Source of `hive/term.go`: the terminal module (`hive.term`) — line-oriented
/// stdin and the program's arguments. (`hive.term.print` needs no runtime: it
/// lowers to the same `fmt.Println` as `echo`.)
pub fn term_go() -> String {
  "package hive

import (
	\"bufio\"
	\"os\"
	\"strings\"
)

// One shared buffered reader over stdin: created once so bytes read past a
// newline in one TermRead are not lost before the next.
var stdinReader = bufio.NewReader(os.Stdin)

// TermRead blocks until the user finishes a line of input and returns it
// without the trailing newline (and without a trailing CR on Windows input).
// The read parks only the calling goroutine — the Go scheduler keeps other
// virtual threads running on other OS threads. At end of input it returns
// whatever preceded EOF (\"\" if nothing). Backs hive.term.read.
func TermRead() string {
	line, err := stdinReader.ReadString('\\n')
	line = strings.TrimRight(line, \"\\n\")
	line = strings.TrimRight(line, \"\\r\")
	if err != nil && line == \"\" {
		return \"\"
	}
	return line
}

// TermArgs returns the command-line arguments the program was run with, in
// order and excluding the program name (os.Args[0]). Backs hive.term.args.
func TermArgs() []string {
	args := os.Args[1:]
	out := make([]string, len(args))
	copy(out, args)
	return out
}
"
}

// ---------------------------------------------------------------------------
// hive.task
// ---------------------------------------------------------------------------

/// Source of `hive/task.go`: the task module (`hive.task`) — scheduling
/// controls over the virtual threads an `async func` runs on.
pub fn task_go() -> String {
  "package hive

import (
	\"strconv\"
	\"time\"
)

// Sleep parks the calling goroutine for ms milliseconds; only that virtual
// thread waits, so others keep running. A non-positive duration returns at
// once. Backs hive.task.sleep.
func Sleep(ms int) {
	if ms <= 0 {
		return
	}
	time.Sleep(time.Duration(ms) * time.Millisecond)
}

// TimeoutError is what an `await ... with timeout <ms>` yields when the wait
// runs out. Backs hive.task.TimeoutError.
type TimeoutError struct {
	Waited  int
	Message string
}

func (e TimeoutError) String() string { return e.Message }

func timedOut[T any](ms int) Result[T, TimeoutError] {
	return Err[T, TimeoutError](TimeoutError{
		Waited:  ms,
		Message: \"the task did not finish within \" + strconv.Itoa(ms) + \"ms\",
	})
}

// AwaitTimeout waits at most ms for a task, and reports running out of patience
// as a Result.Error rather than as a value.
//
// The task is NOT cancelled when the wait expires: a goroutine cannot be stopped
// from the outside, so the work carries on and only its result is abandoned. The
// timeout is a failure of *waiting*, not of the work — which is also why the
// same handle can be awaited again afterwards, with a longer patience if you
// like.
func AwaitTimeout[T any](a *Async[T], ms int) Result[T, TimeoutError] {
	if ms <= 0 {
		return Ok[T, TimeoutError](a.Await())
	}
	timer := time.NewTimer(time.Duration(ms) * time.Millisecond)
	defer timer.Stop()
	select {
	case <-a.done:
		// Await() rather than a.val, so a panic inside the task still surfaces
		// here exactly as it would without a timeout.
		return Ok[T, TimeoutError](a.Await())
	case <-timer.C:
		return timedOut[T](ms)
	}
}

// AwaitAllTimeout is the same for a vector of handles: one deadline across the
// whole barrier, not ms per task, so `await [a, b, c] with timeout 500` means
// \"all three within half a second\".
func AwaitAllTimeout[T any](hs []*Async[T], ms int) Result[[]T, TimeoutError] {
	if ms <= 0 {
		return Ok[[]T, TimeoutError](AwaitAll(hs))
	}
	deadline := time.Now().Add(time.Duration(ms) * time.Millisecond)
	out := make([]T, len(hs))
	for i, h := range hs {
		left := int(time.Until(deadline) / time.Millisecond)
		if left <= 0 {
			return timedOut[[]T](ms)
		}
		one := AwaitTimeout(h, left)
		if one.IsError() {
			return timedOut[[]T](ms)
		}
		out[i] = one.Ok()
	}
	return Ok[[]T, TimeoutError](out)
}
"
}

// ---------------------------------------------------------------------------
// hive.time
// ---------------------------------------------------------------------------

/// Source of `hive/time.go`: the time module (`hive.time`) — the wall clock,
/// the local zone, and strftime-style formatting.
pub fn time_go() -> String {
  "package hive

import (
	\"fmt\"
	\"strings\"
	\"time\"
)

// Now returns the current Unix time in seconds. Backs hive.time.now.
func Now() int {
	return int(time.Now().Unix())
}

// Timezone returns the name (or abbreviation) of the machine's local time zone
// at this instant — \"UTC\", \"PST\", \"-03\", and so on. Backs hive.time.timezone.
func Timezone() string {
	name, _ := time.Now().Zone()
	return name
}

// TimezoneOffset returns the local zone's current offset from UTC in minutes,
// east of UTC being positive (so UTC+2 is 120 and UTC-3 is -180). Backs
// hive.time.timezoneOffset.
func TimezoneOffset() int {
	_, seconds := time.Now().Zone()
	return seconds / 60
}

// TimeFormat renders a Unix time (seconds), in local time, using a
// strftime-style template. Unknown \"%x\" escapes are emitted verbatim. Backs
// hive.time.format. Supported directives:
//
//	%Y year (4 digits)   %y year (2 digits)   %m month 01-12  %d day 01-31
//	%H hour 00-23        %I hour 01-12        %M minute       %S second
//	%p AM/PM             %j day-of-year       %Z zone name    %z zone offset
//	%A/%a weekday (full/short)   %B/%b month name (full/short)   %% literal %
func TimeFormat(t int, template string) string {
	tm := time.Unix(int64(t), 0)
	var b strings.Builder
	runes := []rune(template)
	for i := 0; i < len(runes); i++ {
		if runes[i] != '%' || i+1 >= len(runes) {
			b.WriteRune(runes[i])
			continue
		}
		i++
		switch runes[i] {
		case 'Y':
			fmt.Fprintf(&b, \"%04d\", tm.Year())
		case 'y':
			fmt.Fprintf(&b, \"%02d\", tm.Year()%100)
		case 'm':
			fmt.Fprintf(&b, \"%02d\", int(tm.Month()))
		case 'd':
			fmt.Fprintf(&b, \"%02d\", tm.Day())
		case 'H':
			fmt.Fprintf(&b, \"%02d\", tm.Hour())
		case 'I':
			h := tm.Hour() % 12
			if h == 0 {
				h = 12
			}
			fmt.Fprintf(&b, \"%02d\", h)
		case 'M':
			fmt.Fprintf(&b, \"%02d\", tm.Minute())
		case 'S':
			fmt.Fprintf(&b, \"%02d\", tm.Second())
		case 'p':
			if tm.Hour() < 12 {
				b.WriteString(\"AM\")
			} else {
				b.WriteString(\"PM\")
			}
		case 'j':
			fmt.Fprintf(&b, \"%03d\", tm.YearDay())
		case 'A':
			b.WriteString(tm.Weekday().String())
		case 'a':
			b.WriteString(tm.Weekday().String()[:3])
		case 'B':
			b.WriteString(tm.Month().String())
		case 'b':
			b.WriteString(tm.Month().String()[:3])
		case 'Z':
			name, _ := tm.Zone()
			b.WriteString(name)
		case 'z':
			b.WriteString(tm.Format(\"-0700\"))
		case '%':
			b.WriteByte('%')
		default:
			b.WriteByte('%')
			b.WriteRune(runes[i])
		}
	}
	return b.String()
}
"
}

// ---------------------------------------------------------------------------
// Spreadsheets (`using ... as xlsx` / `as ods`)
// ---------------------------------------------------------------------------

/// Source of `hive/sheets.go`: the readers behind `using <path> as xlsx` and
/// `using <path> as ods`, each yielding one Table per sheet in workbook order.
///
/// Both formats are a zip of XML, so `archive/zip` and `encoding/xml` cover them
/// and a program that reads a spreadsheet still builds offline. Because the
/// format is named in the source rather than sniffed from the path at runtime,
/// this file is only written when a program actually asks for a spreadsheet.
///
/// Cell text follows what the file stores, with one exception: xlsx keeps dates
/// as day counts, so a date-formatted cell would otherwise read as `46227`. The
/// cell's number format is consulted to spot those and render them as
/// `2026-07-25` (or `2026-07-25 14:30:00`, or `14:30:00` for a time). Every other
/// value — numbers, booleans, cached formula results — is passed through as it
/// was stored.
pub fn sheets_go() -> String {
  "package hive

import (
	\"archive/zip\"
	\"encoding/xml\"
	\"fmt\"
	\"io\"
	\"strconv\"
	\"strings\"
	\"time\"
)

// ---------------------------------------------------------------------------
// The zip container both formats share
// ---------------------------------------------------------------------------

func openSheets(path string) (*zip.ReadCloser, *TableError) {
	archive, err := zip.OpenReader(path)
	if err != nil {
		return nil, &TableError{Path: path, Message: err.Error()}
	}
	return archive, nil
}

// sheetsMember reads one entry out of the archive. A nil result with no error
// means the archive simply has no such entry, which several of them are allowed
// to be (a workbook with no strings has no sharedStrings.xml).
func sheetsMember(archive *zip.ReadCloser, name string) ([]byte, error) {
	for _, entry := range archive.File {
		if entry.Name == name {
			reader, err := entry.Open()
			if err != nil {
				return nil, err
			}
			defer reader.Close()
			return io.ReadAll(reader)
		}
	}
	return nil, nil
}

// padTable squares a sheet off into a Table. Spreadsheets store no trailing
// blanks, so rows arrive at whatever length their last filled cell reached,
// while a Table's readers (`row`, `column`, header lookups) expect a rectangle.
// Every row is copied, so repeated rows never end up sharing storage.
func padTable(rows [][]string) Table {
	width := 0
	for _, row := range rows {
		if len(row) > width {
			width = len(row)
		}
	}
	table := make(Table, 0, len(rows))
	for _, row := range rows {
		padded := make([]string, width)
		copy(padded, row)
		table = append(table, padded)
	}
	return table
}

// ---------------------------------------------------------------------------
// xlsx
// ---------------------------------------------------------------------------

// Element and attribute names are matched on their local part, so the file's
// choice of namespace prefixes does not matter.

type xlsxWorkbook struct {
	Sheets []struct {
		Name string `xml:\"name,attr\"`
		ID   string `xml:\"id,attr\"`
	} `xml:\"sheets>sheet\"`
}

type xlsxRels struct {
	Relationships []struct {
		ID     string `xml:\"Id,attr\"`
		Target string `xml:\"Target,attr\"`
	} `xml:\"Relationship\"`
}

// xlsxText is a string that may be split into styled runs; the runs matter only
// in that their text has to be stitched back together.
type xlsxText struct {
	Plain string `xml:\"t\"`
	Runs  []struct {
		Text string `xml:\"t\"`
	} `xml:\"r\"`
}

func (t xlsxText) String() string {
	if len(t.Runs) == 0 {
		return t.Plain
	}
	var out strings.Builder
	for _, run := range t.Runs {
		out.WriteString(run.Text)
	}
	return out.String()
}

type xlsxSharedStrings struct {
	Items []xlsxText `xml:\"si\"`
}

type xlsxStyles struct {
	Formats []struct {
		ID   string `xml:\"numFmtId,attr\"`
		Code string `xml:\"formatCode,attr\"`
	} `xml:\"numFmts>numFmt\"`
	CellFormats []struct {
		FormatID string `xml:\"numFmtId,attr\"`
	} `xml:\"cellXfs>xf\"`
}

type xlsxCell struct {
	Ref    string   `xml:\"r,attr\"`
	Type   string   `xml:\"t,attr\"`
	Style  string   `xml:\"s,attr\"`
	Value  string   `xml:\"v\"`
	Inline xlsxText `xml:\"is\"`
}

type xlsxRow struct {
	Cells []xlsxCell `xml:\"c\"`
}

type xlsxWorksheet struct {
	Rows []xlsxRow `xml:\"sheetData>row\"`
}

// What a cell's number format renders: a calendar date, a clock time, both, or
// neither. This is the only thing that distinguishes a date from the plain
// number xlsx actually stores for it.
type xlsxFormatKind struct {
	date  bool
	clock bool
}

// ReadXlsx reads every sheet of an .xlsx workbook, in workbook order, and hands
// back one Table per sheet. Backs `using <path> as xlsx`.
func ReadXlsx(path string) Result[[]Table, TableError] {
	fail := func(message string) Result[[]Table, TableError] {
		return Err[[]Table, TableError](TableError{Path: path, Message: message})
	}
	archive, openErr := openSheets(path)
	if openErr != nil {
		return Err[[]Table, TableError](*openErr)
	}
	defer archive.Close()

	workbookXML, err := sheetsMember(archive, \"xl/workbook.xml\")
	if err != nil {
		return fail(err.Error())
	}
	if workbookXML == nil {
		return fail(\"this is not an xlsx workbook: xl/workbook.xml is missing\")
	}
	var workbook xlsxWorkbook
	if err := xml.Unmarshal(workbookXML, &workbook); err != nil {
		return fail(\"xl/workbook.xml is malformed: \" + err.Error())
	}

	// Which part holds each sheet. Absent or unreadable relationships fall back
	// to the conventional sheetN.xml numbering below.
	targets := map[string]string{}
	if relsXML, err := sheetsMember(archive, \"xl/_rels/workbook.xml.rels\"); err == nil && relsXML != nil {
		var rels xlsxRels
		if xml.Unmarshal(relsXML, &rels) == nil {
			for _, rel := range rels.Relationships {
				targets[rel.ID] = xlsxPartPath(rel.Target)
			}
		}
	}

	var shared []xlsxText
	if sharedXML, err := sheetsMember(archive, \"xl/sharedStrings.xml\"); err == nil && sharedXML != nil {
		var strings xlsxSharedStrings
		if xml.Unmarshal(sharedXML, &strings) == nil {
			shared = strings.Items
		}
	}

	var kinds []xlsxFormatKind
	if stylesXML, err := sheetsMember(archive, \"xl/styles.xml\"); err == nil && stylesXML != nil {
		var styles xlsxStyles
		if xml.Unmarshal(stylesXML, &styles) == nil {
			kinds = xlsxFormatKinds(styles)
		}
	}

	tables := []Table{}
	for i, sheet := range workbook.Sheets {
		part, ok := targets[sheet.ID]
		if !ok {
			part = \"xl/worksheets/sheet\" + strconv.Itoa(i+1) + \".xml\"
		}
		sheetXML, err := sheetsMember(archive, part)
		if err != nil {
			return fail(err.Error())
		}
		// A sheet whose part is missing still holds its place in the workbook.
		if sheetXML == nil {
			tables = append(tables, Table{})
			continue
		}
		var worksheet xlsxWorksheet
		if err := xml.Unmarshal(sheetXML, &worksheet); err != nil {
			return fail(part + \" is malformed: \" + err.Error())
		}
		rows := [][]string{}
		for _, row := range worksheet.Rows {
			rows = append(rows, xlsxRowCells(row, shared, kinds))
		}
		tables = append(tables, padTable(rows))
	}
	return Ok[[]Table, TableError](tables)
}

// A relationship target is relative to xl/ unless it is rooted at the archive.
func xlsxPartPath(target string) string {
	if strings.HasPrefix(target, \"/\") {
		return strings.TrimPrefix(target, \"/\")
	}
	return \"xl/\" + target
}

// xlsxRowCells places a row's cells at the columns their references name, since
// a row stores only the cells that hold something.
func xlsxRowCells(
	row xlsxRow,
	shared []xlsxText,
	kinds []xlsxFormatKind,
) []string {
	cells := []string{}
	for _, cell := range row.Cells {
		at := xlsxColumn(cell.Ref)
		if at < 0 {
			at = len(cells)
		}
		for len(cells) <= at {
			cells = append(cells, \"\")
		}
		cells[at] = xlsxCellText(cell, shared, kinds)
	}
	return cells
}

// The column a cell reference names: \"A1\" -> 0, \"AB7\" -> 27. A reference with no
// leading letters yields -1, meaning \"wherever we had reached\".
func xlsxColumn(ref string) int {
	column := 0
	for i := 0; i < len(ref); i++ {
		letter := ref[i]
		if letter < 'A' || letter > 'Z' {
			break
		}
		column = column*26 + int(letter-'A'+1)
	}
	return column - 1
}

func xlsxCellText(
	cell xlsxCell,
	shared []xlsxText,
	kinds []xlsxFormatKind,
) string {
	switch cell.Type {
	case \"s\":
		// An index into the workbook's shared string table.
		if at, err := strconv.Atoi(cell.Value); err == nil && at >= 0 && at < len(shared) {
			return shared[at].String()
		}
		return \"\"
	case \"inlineStr\":
		return cell.Inline.String()
	case \"b\":
		if cell.Value == \"1\" {
			return \"true\"
		}
		return \"false\"
	case \"str\", \"e\", \"d\":
		// A formula's cached string result, an error text, or an ISO date.
		return cell.Value
	}
	// A number, which is also how a date is stored: only the cell's format says
	// which of the two it is meant to be.
	if at, err := strconv.Atoi(cell.Style); err == nil && at >= 0 && at < len(kinds) {
		if text, ok := xlsxDateText(cell.Value, kinds[at]); ok {
			return text
		}
	}
	return cell.Value
}

// xlsxFormatKinds resolves every cell format the workbook defines down to what
// it renders, so a cell's style index answers the question directly.
func xlsxFormatKinds(styles xlsxStyles) []xlsxFormatKind {
	codes := map[string]string{}
	for _, format := range styles.Formats {
		codes[format.ID] = format.Code
	}
	kinds := make([]xlsxFormatKind, 0, len(styles.CellFormats))
	for _, format := range styles.CellFormats {
		if code, ok := codes[format.FormatID]; ok {
			kinds = append(kinds, xlsxCodeKind(code))
			continue
		}
		kinds = append(kinds, xlsxBuiltinKind(format.FormatID))
	}
	return kinds
}

// The date and time formats every xlsx carries without defining them.
func xlsxBuiltinKind(id string) xlsxFormatKind {
	switch id {
	case \"14\", \"15\", \"16\", \"17\":
		return xlsxFormatKind{date: true}
	case \"18\", \"19\", \"20\", \"21\", \"45\", \"46\", \"47\":
		return xlsxFormatKind{clock: true}
	case \"22\":
		return xlsxFormatKind{date: true, clock: true}
	}
	return xlsxFormatKind{}
}

// A custom format renders a date when it positions any date or time field.
// Quoted literals, [...] sections and backslash escapes are dropped first: each
// can hold letters that would otherwise read as fields.
func xlsxCodeKind(code string) xlsxFormatKind {
	var fields strings.Builder
	quoted := false
	bracketed := false
	for i := 0; i < len(code); i++ {
		letter := code[i]
		switch {
		case letter == '\"':
			quoted = !quoted
		case letter == '[':
			bracketed = true
		case letter == ']':
			bracketed = false
		case quoted || bracketed:
		case letter == '\\\\':
			i++
		default:
			fields.WriteByte(letter)
		}
	}
	bare := strings.ToLower(fields.String())
	kind := xlsxFormatKind{}
	if strings.ContainsAny(bare, \"yd\") {
		kind.date = true
	}
	if strings.ContainsAny(bare, \"hs\") {
		kind.clock = true
	}
	// `m` is minutes beside an hour and months everywhere else.
	if strings.Contains(bare, \"m\") && !kind.date && !kind.clock {
		kind.date = true
	}
	return kind
}

// xlsxEpoch is the day before serial 1, so serial 1 lands on 1900-01-01.
var xlsxEpoch = time.Date(1899, 12, 30, 0, 0, 0, 0, time.UTC)

// xlsxDateText renders a stored day count as a date, a time, or both, according
// to what the cell's format asks for. It reports false when the format wants
// neither, which is how an ordinary number passes through untouched.
func xlsxDateText(raw string, kind xlsxFormatKind) (string, bool) {
	if !kind.date && !kind.clock {
		return \"\", false
	}
	serial, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return \"\", false
	}
	days := int(serial)
	moment := xlsxEpoch.AddDate(0, 0, days)
	// Excel counts a 1900-02-29 that never happened, so every serial before it
	// is a day behind.
	if days < 60 {
		moment = moment.AddDate(0, 0, 1)
	}
	seconds := int((serial-float64(days))*86400 + 0.5)
	moment = moment.Add(time.Duration(seconds) * time.Second)
	switch {
	case kind.date && kind.clock:
		return moment.Format(\"2006-01-02 15:04:05\"), true
	case kind.date:
		return moment.Format(\"2006-01-02\"), true
	}
	return moment.Format(\"15:04:05\"), true
}

// ---------------------------------------------------------------------------
// ods
// ---------------------------------------------------------------------------

type odsContent struct {
	Tables []odsTable `xml:\"body>spreadsheet>table\"`
}

type odsTable struct {
	Name string   `xml:\"name,attr\"`
	Rows []odsRow `xml:\"table-row\"`
}

type odsRow struct {
	Repeated string    `xml:\"number-rows-repeated,attr\"`
	Cells    []odsCell `xml:\"table-cell\"`
}

type odsCell struct {
	Repeated   string   `xml:\"number-columns-repeated,attr\"`
	ValueType  string   `xml:\"value-type,attr\"`
	Value      string   `xml:\"value,attr\"`
	DateValue  string   `xml:\"date-value,attr\"`
	TimeValue  string   `xml:\"time-value,attr\"`
	BoolValue  string   `xml:\"boolean-value,attr\"`
	Paragraphs []string `xml:\"p\"`
}

// A repeat count this large is the format padding a sheet out to its full width
// or height rather than real repeated data, so it is treated as one cell.
const odsMaxRepeat = 4096

// ReadOds reads every table of an OpenDocument spreadsheet, in document order,
// and hands back one Table per table. Backs `using <path> as ods`.
func ReadOds(path string) Result[[]Table, TableError] {
	fail := func(message string) Result[[]Table, TableError] {
		return Err[[]Table, TableError](TableError{Path: path, Message: message})
	}
	archive, openErr := openSheets(path)
	if openErr != nil {
		return Err[[]Table, TableError](*openErr)
	}
	defer archive.Close()

	contentXML, err := sheetsMember(archive, \"content.xml\")
	if err != nil {
		return fail(err.Error())
	}
	if contentXML == nil {
		return fail(\"this is not an ods spreadsheet: content.xml is missing\")
	}
	var content odsContent
	if err := xml.Unmarshal(contentXML, &content); err != nil {
		return fail(\"content.xml is malformed: \" + err.Error())
	}
	tables := []Table{}
	for _, table := range content.Tables {
		tables = append(tables, padTable(odsRows(table)))
	}
	return Ok[[]Table, TableError](tables)
}

// odsRows expands a table's repeat counts. Runs of empty rows are held back and
// only written out once something non-empty follows, so a sheet padded to a
// million rows still reads as the handful of rows it really holds.
func odsRows(table odsTable) [][]string {
	rows := [][]string{}
	blank := 0
	for _, row := range table.Rows {
		cells := odsRowCells(row)
		repeat := odsRepeat(row.Repeated)
		if len(cells) == 0 {
			blank += repeat
			continue
		}
		for ; blank > 0; blank-- {
			rows = append(rows, []string{})
		}
		for i := 0; i < repeat; i++ {
			rows = append(rows, cells)
		}
	}
	return rows
}

// The same holding-back applies across a row, where trailing blank cells are
// how the format pads out to the sheet's width.
func odsRowCells(row odsRow) []string {
	cells := []string{}
	blank := 0
	for _, cell := range row.Cells {
		repeat := odsRepeat(cell.Repeated)
		text := odsCellText(cell)
		if text == \"\" {
			blank += repeat
			continue
		}
		for ; blank > 0; blank-- {
			cells = append(cells, \"\")
		}
		for i := 0; i < repeat; i++ {
			cells = append(cells, text)
		}
	}
	return cells
}

func odsRepeat(value string) int {
	if value == \"\" {
		return 1
	}
	repeat, err := strconv.Atoi(value)
	if err != nil || repeat < 1 || repeat > odsMaxRepeat {
		return 1
	}
	return repeat
}

// An ods stores real dates and numbers alongside the text it displays, so unlike
// xlsx there is no serial arithmetic to undo here.
func odsCellText(cell odsCell) string {
	switch cell.ValueType {
	case \"float\", \"percentage\", \"currency\":
		return cell.Value
	case \"boolean\":
		return cell.BoolValue
	case \"date\":
		return odsDateText(cell.DateValue)
	case \"time\":
		return odsTimeText(cell.TimeValue)
	}
	return strings.Join(cell.Paragraphs, \"\\n\")
}

// A midnight timestamp is a plain date; anything else keeps its time.
func odsDateText(value string) string {
	at := strings.IndexByte(value, 'T')
	if at < 0 {
		return value
	}
	clock := value[at+1:]
	if clock == \"\" || clock == \"00:00:00\" {
		return value[:at]
	}
	return value[:at] + \" \" + clock
}

// An ods time is an ISO-8601 duration, \"PT14H30M00S\".
func odsTimeText(value string) string {
	rest := strings.TrimPrefix(strings.TrimPrefix(value, \"P\"), \"T\")
	hours, minutes, seconds := 0, 0, 0
	digits := \"\"
	for i := 0; i < len(rest); i++ {
		switch rest[i] {
		case 'H':
			hours, _ = strconv.Atoi(digits)
			digits = \"\"
		case 'M':
			minutes, _ = strconv.Atoi(digits)
			digits = \"\"
		case 'S':
			whole := digits
			if dot := strings.IndexByte(whole, '.'); dot >= 0 {
				whole = whole[:dot]
			}
			seconds, _ = strconv.Atoi(whole)
			digits = \"\"
		default:
			digits += string(rest[i])
		}
	}
	return fmt.Sprintf(\"%02d:%02d:%02d\", hours, minutes, seconds)
}
"
}

// ---------------------------------------------------------------------------
// hive.file
// ---------------------------------------------------------------------------

/// Source of `hive/file.go`: the general filesystem module (`hive.file`).
///
/// Contents move as `Str`. Go strings are byte sequences rather than validated
/// text, so binary content survives a read/write round trip unchanged.
pub fn file_go() -> String {
  "package hive

import (
	\"os\"
	\"strings\"
)

// FileError says why a filesystem operation failed. Reason is a short tag:
// \"NotFound\", \"Permission\", \"Exists\" or \"Io\".
type FileError struct {
	Path    string
	Reason  string
	Message string
}

func (e FileError) Error() string {
	return \"hive: file \" + e.Reason + \" for \" + e.Path + \": \" + e.Message
}

// fileFail tags an OS error with the distinction a caller is most likely to
// branch on, since the message itself is platform-specific prose.
func fileFail(path string, err error) FileError {
	reason := \"Io\"
	switch {
	case os.IsNotExist(err):
		reason = \"NotFound\"
	case os.IsPermission(err):
		reason = \"Permission\"
	case os.IsExist(err):
		reason = \"Exists\"
	}
	return FileError{Path: path, Reason: reason, Message: err.Error()}
}

// FileRead returns a file's whole contents. Backs hive.file.read.
func FileRead(path string) Result[string, FileError] {
	data, err := os.ReadFile(path)
	if err != nil {
		return Err[string, FileError](fileFail(path, err))
	}
	return Ok[string, FileError](string(data))
}

// FileLines reads a file and splits it into lines, dropping the empty piece a
// trailing newline would leave and any Windows carriage returns. Backs
// hive.file.lines.
func FileLines(path string) Result[[]string, FileError] {
	data, err := os.ReadFile(path)
	if err != nil {
		return Err[[]string, FileError](fileFail(path, err))
	}
	text := strings.ReplaceAll(string(data), \"\\r\\n\", \"\\n\")
	text = strings.TrimSuffix(text, \"\\n\")
	if text == \"\" {
		return Ok[[]string, FileError]([]string{})
	}
	return Ok[[]string, FileError](strings.Split(text, \"\\n\"))
}

// FileWrite replaces a file's contents, creating it when absent, and reports how
// many bytes went out. It does not create missing parent directories —
// hive.file.makeDir is for that. Backs hive.file.write.
func FileWrite(path string, contents string) Result[int, FileError] {
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		return Err[int, FileError](fileFail(path, err))
	}
	return Ok[int, FileError](len(contents))
}

// FileAppend adds to the end of a file, creating it when absent. Backs
// hive.file.append.
func FileAppend(path string, contents string) Result[int, FileError] {
	handle, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return Err[int, FileError](fileFail(path, err))
	}
	defer handle.Close()
	written, err := handle.WriteString(contents)
	if err != nil {
		return Err[int, FileError](fileFail(path, err))
	}
	return Ok[int, FileError](written)
}

// FileExists reports whether anything is at the path — a directory counts.
// Backs hive.file.exists.
func FileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// FileSize is a file's length in bytes. Backs hive.file.size.
func FileSize(path string) Result[int, FileError] {
	info, err := os.Stat(path)
	if err != nil {
		return Err[int, FileError](fileFail(path, err))
	}
	return Ok[int, FileError](int(info.Size()))
}

// FileDelete removes a file, or a directory that is already empty. Backs
// hive.file.delete.
func FileDelete(path string) Result[bool, FileError] {
	if err := os.Remove(path); err != nil {
		return Err[bool, FileError](fileFail(path, err))
	}
	return Ok[bool, FileError](true)
}

// FileList is the names of a directory's entries, sorted, without any leading
// path. Backs hive.file.list.
func FileList(path string) Result[[]string, FileError] {
	entries, err := os.ReadDir(path)
	if err != nil {
		return Err[[]string, FileError](fileFail(path, err))
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	return Ok[[]string, FileError](names)
}

// FileMakeDir creates a directory along with any missing parents. A directory
// that is already there is not an error. Backs hive.file.makeDir.
func FileMakeDir(path string) Result[bool, FileError] {
	if err := os.MkdirAll(path, 0o755); err != nil {
		return Err[bool, FileError](fileFail(path, err))
	}
	return Ok[bool, FileError](true)
}

// FileCopy copies a file's contents over another path, replacing whatever was
// there, and reports how many bytes moved. Backs hive.file.copy.
func FileCopy(from string, to string) Result[int, FileError] {
	data, err := os.ReadFile(from)
	if err != nil {
		return Err[int, FileError](fileFail(from, err))
	}
	if err := os.WriteFile(to, data, 0o644); err != nil {
		return Err[int, FileError](fileFail(to, err))
	}
	return Ok[int, FileError](len(data))
}

// FileMove renames a file or directory, which is also how one is moved. Backs
// hive.file.move.
func FileMove(from string, to string) Result[bool, FileError] {
	if err := os.Rename(from, to); err != nil {
		return Err[bool, FileError](fileFail(from, err))
	}
	return Ok[bool, FileError](true)
}
"
}

// ---------------------------------------------------------------------------
// hive.sql
// ---------------------------------------------------------------------------

/// Source of `hive/sql.go`: the SQL module (`hive.sql`). It is the one module
/// that links external Go drivers, so a program which never opens a connection
/// keeps a dependency-free `go.mod` and builds offline. SQLite is the pure-Go
/// `modernc.org/sqlite` (the engine is compiled straight into the executable —
/// no CGO, no system SQLite); Postgres is `github.com/lib/pq`.
pub fn sql_go() -> String {
  "package hive

import (
	\"database/sql\"
	\"strconv\"
	\"strings\"

	_ \"github.com/lib/pq\"
	_ \"modernc.org/sqlite\"
)

// DatabaseDriver selects the SQL driver a connection uses. Build it with
// hive.sql.DatabaseDriver.SQLite(), .PostgreSQL() or .Other(name).
type DatabaseDriver struct {
	Name string
}

// SqlError describes a failed database operation. Reason is a short tag —
// \"Connection\", \"Query\", \"Shape\" or \"Convert\" — so a caller can tell a
// database that is down from a value that did not fit the type it was declared
// with, which are very different things to do something about.
type SqlError struct {
	Reason  string
	Message string
}

func (e SqlError) Error() string {
	return \"hive: sql error (\" + e.Reason + \"): \" + e.Message
}

// SqlFragment is a piece of SQL text together with the values its placeholders
// bind to. A query declaration builds one; nothing a caller supplies ever
// reaches Text, which is what makes the text mean only what the query says.
type SqlFragment struct {
	Text string
	Args []any
}

// SqlJoin combines the fragments a `where` block collected. No fragments means
// empty text, so the clause disappears rather than leaving a dangling
// connective; more than one is parenthesised when asked, so a nested group
// cannot change how the surrounding connective binds.
func SqlJoin(parts []SqlFragment, sep string, paren bool) SqlFragment {
	if len(parts) == 0 {
		return SqlFragment{}
	}
	texts := make([]string, len(parts))
	args := []any{}
	for i, p := range parts {
		texts[i] = p.Text
		args = append(args, p.Args...)
	}
	text := strings.Join(texts, sep)
	if paren && len(parts) > 1 {
		text = \"(\" + text + \")\"
	}
	return SqlFragment{Text: text, Args: args}
}

// Queries are built with `?` placeholders; PostgreSQL wants $1, $2, ... instead.
// Rewriting here rather than at build time is what lets one query declaration
// serve every driver.
func sqlPlaceholders(conn SqlConnection, text string) string {
	if conn.driver != \"postgres\" {
		return text
	}
	var b strings.Builder
	n := 0
	for _, r := range text {
		if r == '?' {
			n++
			b.WriteString(\"$\" + strconv.Itoa(n))
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// SqlExec runs a statement that returns no rows and reports how many it
// affected — which is how a delete says whether it matched anything.
func SqlExec(conn SqlConnection, stmt SqlFragment) Result[int, SqlError] {
	if conn.db == nil {
		return Err[int, SqlError](SqlError{Reason: \"Connection\", Message: \"connection is not open\"})
	}
	res, err := conn.db.Exec(sqlPlaceholders(conn, stmt.Text), stmt.Args...)
	if err != nil {
		return Err[int, SqlError](SqlError{Reason: \"Query\", Message: err.Error()})
	}
	n, err := res.RowsAffected()
	if err != nil {
		// A driver that cannot count is not a failure of the statement itself.
		return Ok[int, SqlError](0)
	}
	return Ok[int, SqlError](int(n))
}

// SqlRows runs a query and maps every row through `row`, which the compiler
// derived from the type the query declared. A cell that does not fit its field
// stops the read and comes back as an error, rather than becoming a zero.
func SqlRows[T any](
	conn SqlConnection,
	stmt SqlFragment,
	row func([]string) (T, error),
) Result[[]T, SqlError] {
	out := []T{}
	if conn.db == nil {
		return Err[[]T, SqlError](SqlError{Reason: \"Connection\", Message: \"connection is not open\"})
	}
	rows, err := conn.db.Query(sqlPlaceholders(conn, stmt.Text), stmt.Args...)
	if err != nil {
		return Err[[]T, SqlError](SqlError{Reason: \"Query\", Message: err.Error()})
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return Err[[]T, SqlError](SqlError{Reason: \"Query\", Message: err.Error()})
	}
	for rows.Next() {
		cells := make([]sql.NullString, len(cols))
		ptrs := make([]any, len(cols))
		for i := range cells {
			ptrs[i] = &cells[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return Err[[]T, SqlError](SqlError{Reason: \"Query\", Message: err.Error()})
		}
		flat := make([]string, len(cols))
		for i, c := range cells {
			if c.Valid {
				flat[i] = c.String
			}
		}
		v, err := row(flat)
		if err != nil {
			if se, ok := err.(SqlError); ok {
				return Err[[]T, SqlError](se)
			}
			return Err[[]T, SqlError](SqlError{Reason: \"Convert\", Message: err.Error()})
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		return Err[[]T, SqlError](SqlError{Reason: \"Query\", Message: err.Error()})
	}
	return Ok[[]T, SqlError](out)
}

// SqlShapeError reports a row that arrived with the wrong number of columns —
// which the compiler checks the query text for, so it means the database
// disagreed with the query at runtime.
func SqlShapeError(want, got int) error {
	return SqlError{
		Reason: \"Shape\",
		Message: \"expected \" + strconv.Itoa(want) + \" columns but the row had \" +
			strconv.Itoa(got),
	}
}

func sqlCellError(column, value, want string) error {
	return SqlError{
		Reason:  \"Convert\",
		Message: \"column \" + column + \" held \" + strconv.Quote(value) + \", which is not \" + want,
	}
}

// The cell conversions a generated row mapper uses. A Str needs no converting,
// but it keeps the same shape as the others so the generated code is uniform.
func SqlCellStr(cell string, column string) (string, error) {
	_ = column
	return cell, nil
}

func SqlCellInt(cell string, column string) (int, error) {
	v, err := strconv.Atoi(strings.TrimSpace(cell))
	if err != nil {
		return 0, sqlCellError(column, cell, \"an Int\")
	}
	return v, nil
}

func SqlCellFloat(cell string, column string) (float64, error) {
	v, err := strconv.ParseFloat(strings.TrimSpace(cell), 64)
	if err != nil {
		return 0, sqlCellError(column, cell, \"a Float\")
	}
	return v, nil
}

// Booleans have no single spelling across databases: SQLite stores 0/1,
// PostgreSQL answers t/f, and some schemas keep the word. All of them are
// accepted; anything else is an error rather than a silent false.
func SqlCellBool(cell string, column string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(cell)) {
	case \"1\", \"t\", \"true\", \"y\", \"yes\":
		return true, nil
	case \"0\", \"f\", \"false\", \"n\", \"no\":
		return false, nil
	}
	return false, sqlCellError(column, cell, \"a Bool\")
}

// SqlConnection is a handle to an open database. The underlying *sql.DB is a
// connection pool, so a single SqlConnection is safe for concurrent use.
type SqlConnection struct {
	db *sql.DB
	// Which driver this connection speaks, so placeholders can be written in the
	// dialect it expects.
	driver string
}

// sqlDriverName maps a DatabaseDriver onto the registered database/sql driver.
func sqlDriverName(d DatabaseDriver) string {
	switch d.Name {
	case \"sqlite\":
		return \"sqlite\"
	case \"postgres\":
		return \"postgres\"
	default:
		return d.Name
	}
}

// SqlConnect opens a pooled connection to the database at connString and
// verifies it with a ping.
func SqlConnect(driver DatabaseDriver, connString string) Result[SqlConnection, SqlError] {
	db, err := sql.Open(sqlDriverName(driver), connString)
	if err != nil {
		return Err[SqlConnection, SqlError](SqlError{Reason: \"Query\", Message: err.Error()})
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return Err[SqlConnection, SqlError](SqlError{Reason: \"Query\", Message: err.Error()})
	}
	return Ok[SqlConnection, SqlError](SqlConnection{db: db, driver: sqlDriverName(driver)})
}

// SqlPool is SqlConnect with explicit pool limits (max open and idle
// connections).
func SqlPool(driver DatabaseDriver, connString string, maxOpen int, maxIdle int) Result[SqlConnection, SqlError] {
	res := SqlConnect(driver, connString)
	if res.IsError() {
		return res
	}
	conn := res.Ok()
	conn.db.SetMaxOpenConns(maxOpen)
	conn.db.SetMaxIdleConns(maxIdle)
	return Ok[SqlConnection, SqlError](conn)
}

// SqlClose releases a connection pool. It is safe to call more than once.
func SqlClose(conn SqlConnection) {
	if conn.db != nil {
		conn.db.Close()
	}
}

// SqlQuery runs any SQL statement and returns its result as a Table. A query
// that returns rows yields a header row of column names followed by one row
// per result row; a statement that returns no rows yields an empty table.
func SqlQuery(conn SqlConnection, query string) Result[Table, SqlError] {
	if conn.db == nil {
		return Err[Table, SqlError](SqlError{Reason: \"Connection\", Message: \"connection is not open\"})
	}
	rows, err := conn.db.Query(query)
	if err != nil {
		return Err[Table, SqlError](SqlError{Reason: \"Query\", Message: err.Error()})
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return Err[Table, SqlError](SqlError{Reason: \"Query\", Message: err.Error()})
	}
	if len(cols) == 0 {
		return Ok[Table, SqlError](Table{})
	}
	table := Table{cols}
	for rows.Next() {
		cells := make([]sql.NullString, len(cols))
		ptrs := make([]any, len(cols))
		for i := range cells {
			ptrs[i] = &cells[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return Err[Table, SqlError](SqlError{Reason: \"Query\", Message: err.Error()})
		}
		row := make([]string, len(cols))
		for i, c := range cells {
			if c.Valid {
				row[i] = c.String
			}
		}
		table = append(table, row)
	}
	if err := rows.Err(); err != nil {
		return Err[Table, SqlError](SqlError{Reason: \"Query\", Message: err.Error()})
	}
	return Ok[Table, SqlError](table)
}
"
}

/// Source of `hive/syslink.go`: addressable services, their mailboxes, the name
/// registry, request/response and monitors.
pub fn syslink_go() -> String {
  "package hive

import (
	\"errors\"
	\"fmt\"
	\"os\"
	\"strconv\"
	\"strings\"
	\"sync\"
	\"sync/atomic\"
	\"time\"
)

// ---------------------------------------------------------------------------
// hive.syslink — addressable services, in this process or on another machine
// ---------------------------------------------------------------------------
// A service is long-lived, has an identity you can pass around, and owns
// private state that only it can touch. It is deliberately not an `async T`: it
// outlives the scope that spawned it and is never awaited.
//
// Every choice here exists to make a send behave the same whether the recipient
// is a mailbox in this process or a service on another machine: the message is
// copied either way, the send never blocks and never fails, and a recipient
// that has died is discovered through a monitor rather than through a return
// value. Local code that works is therefore code that still works once the
// service moves to another node.

// atomNone is the \"no atom\" sentinel. Zero is taken (#False), so a negative
// value is used: no compiled atom is ever negative.
const atomNone Atom = -1

// SyslinkError is what the fallible half of the module answers with. Reason is
// a short tag, in the same spirit as FileError and WsError: \"Timeout\", \"Down\",
// \"Unreachable\", \"Decode\", \"Taken\", \"NoListener\" or \"NoPeer\".
type SyslinkError struct {
	Reason  string
	Message string
}

func (e SyslinkError) String() string { return e.Reason + \": \" + e.Message }

func syslinkErr[T any](reason, message string) Result[T, SyslinkError] {
	return Err[T, SyslinkError](SyslinkError{Reason: reason, Message: message})
}

// ---------------------------------------------------------------------------
// Codecs
// ---------------------------------------------------------------------------
// A message crosses a machine boundary through the same derived encoder and
// decoder `hive.json` builds from a type declaration, so nothing new has to be
// derived for a type to be sendable. These three adapters are all that stands
// between those and the shapes the module wants.

// SyslinkEncoder adapts a derived encoder to the bytes the wire carries.
func SyslinkEncoder[T any](enc func(T) string) func(T) []byte {
	return func(v T) []byte { return []byte(enc(v)) }
}

// SyslinkDecoder adapts a derived decoder into the erased form a mailbox holds.
// A mailbox is typed by its handler rather than by its decoder, so the decoder
// only has to produce the right dynamic type for that handler to accept.
func SyslinkDecoder[T any](dec func(JsonValue, string) (T, *JsonError)) func([]byte) (any, error) {
	return func(b []byte) (any, error) {
		r := JsonParse(string(b), dec)
		if r.IsError() {
			return nil, errors.New(jsonWhy(r.Err()))
		}
		return r.Ok(), nil
	}
}

// SyslinkReplyDecoder is the same adapter for the answer to a call, which stays
// typed because the call site said what it expected back.
func SyslinkReplyDecoder[T any](dec func(JsonValue, string) (T, *JsonError)) func([]byte) (T, error) {
	return func(b []byte) (T, error) {
		r := JsonParse(string(b), dec)
		if r.IsError() {
			var zero T
			return zero, errors.New(jsonWhy(r.Err()))
		}
		return r.Ok(), nil
	}
}

// An address travels inside a message as text, which is how a service hands out
// a way to reach it — or one of its workers — without that worker needing a
// registered name of its own. A registered name crosses as a name because atom
// ids are per build; an anonymous mailbox crosses as its id, which is only
// meaningful together with the node it lives on.
func JsonEncodeAddress(a Address) string {
	where := a.Endpoint
	if where == \"\" {
		// A local address is stamped with this node's advertised endpoint, so it
		// stays dialable once it is somewhere else — including after being passed
		// on a second time.
		where = SyslinkNode()
	}
	name := \"\"
	if a.Name != atomNone {
		name = a.Name.String()
	}
	return JsonEncodeStr(where + \"|\" + name + \"|\" + strconv.FormatUint(a.Id, 10))
}

func JsonAddress(v JsonValue, path string) (Address, *JsonError) {
	text, jerr := JsonStr(v, path)
	if jerr != nil {
		return Address{}, jerr
	}
	parts := strings.Split(text, \"|\")
	if len(parts) != 3 {
		return Address{}, &JsonError{Path: path, Expected: \"a syslink address\", Found: JsonEncodeStr(text)}
	}
	addr := Address{Endpoint: parts[0], Name: atomNone}
	if parts[1] != \"\" {
		addr.Name = atomByName(parts[1])
	}
	if id, err := strconv.ParseUint(parts[2], 10, 64); err == nil {
		addr.Id = id
	}
	// An address that names this node is resolved back to the live mailbox, so
	// sending to it takes the local path rather than a pointless round trip.
	if b, ok := resolveLocal(addr); ok {
		addr.box = b
	}
	return addr, nil
}

func jsonWhy(e JsonError) string {
	where := e.Path
	if where == \"\" {
		where = \"the message\"
	}
	return \"expected \" + e.Expected + \" at \" + where + \", found \" + e.Found
}

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

// Address identifies a service: a plain value, copyable, storable in a struct
// and sendable in a message. `box` is set only while the service lives in this
// process; a remote address carries its node role plus either a registered name
// or a mailbox id, which is all another node needs in order to route to it.
type Address struct {
	// Where the node holding this service can be reached, as it advertised
	// itself: \"10.0.0.4:9100\". Empty means this node. A node is identified by
	// where it is, not by a name — an endpoint is deployment data, resolvable at
	// runtime through ordinary DNS or configuration, and there is nothing for an
	// authenticated peer to impersonate.
	Endpoint string
	Name     Atom
	Id       uint64
	box      *mailbox
}

// String renders an address the way echo shows it — <node/name> for a
// registered service, <node#id> for an anonymous one.
func (a Address) String() string {
	where := a.Endpoint
	if where == \"\" {
		where = SyslinkNode()
	}
	if where == \"\" {
		where = \"this node\"
	}
	if a.Name != atomNone {
		return \"<\" + where + \"/\" + a.Name.String() + \">\"
	}
	return \"<\" + where + \"#\" + strconv.FormatUint(a.Id, 10) + \">\"
}

// Envelope is the turn's context: the reply token for a `call`, and the
// identity of the service handling it. Opaque in Hive — SyslinkAnswer,
// SyslinkSelf and SyslinkMonitor are what read it.
type Envelope struct {
	self   *mailbox
	ref    uint64
	origin string
	// Set by SyslinkAnswer, read by the service loop once the turn returns. It is
	// how the runtime can tell \"this request was answered\" from \"this request was
	// quietly forgotten\" without the handler saying anything.
	turn *turnState
}

type turnState struct {
	answered atomic.Bool
}

func (e Envelope) String() string {
	if e.ref == 0 {
		return \"<no reply expected>\"
	}
	return \"<reply \" + strconv.FormatUint(e.ref, 10) + \">\"
}

// ---------------------------------------------------------------------------
// Mailboxes
// ---------------------------------------------------------------------------

// delivery is one queued message. A message that arrived over the wire keeps
// its `raw` payload and is decoded on the recipient's own turn: a malformed or
// wrong-typed payload then fails as that service's problem instead of tearing
// down a connection shared with every other service on the node.
type delivery struct {
	value  any
	raw    []byte
	digest uint32
	ref    uint64
	// The advertised endpoint the request arrived from, so its answer can go back
	// the way it came. Empty for a request raised on this node.
	origin string
}

// watcher is one monitor registration: the death message to deliver, and where
// to deliver it. A local watcher holds the mailbox directly; a remote one is
// addressed by node and mailbox id, with its message pre-encoded by the node
// that asked to be told.
// Each registration carries a `mon` id so a monitor fires exactly once: the
// node holding the target reports the death against that id, and the watching
// node drops its own fallback record on arrival. Without it, losing the node
// right after a service died there would deliver the death message twice.
type watcher struct {
	box     *mailbox
	value   any
	node    string
	id      uint64
	mon     uint64
	payload []byte
	digest  uint32
}

// A mailbox is an unbounded FIFO queue plus the goroutine that folds it into
// the service's state. Unbounded is deliberate: a bounded queue would make
// `send` block, which would break the send contract and let two services that
// message each other deadlock.
type mailbox struct {
	id   uint64
	name Atom

	mu     sync.Mutex
	cond   *sync.Cond
	queue  []delivery
	closed bool

	// Installed at spawn: how to turn a wire payload into this mailbox's
	// message type, and the structural digest of that type.
	decode func([]byte) (any, error)
	digest uint32

	watchers []watcher
}

var (
	boxSeq atomic.Uint64
	boxes  sync.Map // uint64 -> *mailbox

	// The registry is indexed by atom id. Registered names come from a closed,
	// compile-time set, so its size is known before main runs and a lookup is
	// an array index rather than a hash and a lock.
	registryOnce sync.Once
	registry     []atomic.Pointer[mailbox]
)

func registrySlots() []atomic.Pointer[mailbox] {
	registryOnce.Do(func() {
		registry = make([]atomic.Pointer[mailbox], len(atomNames))
	})
	return registry
}

func newMailbox(decode func([]byte) (any, error), digest uint32) *mailbox {
	b := &mailbox{id: boxSeq.Add(1), name: atomNone, decode: decode, digest: digest}
	b.cond = sync.NewCond(&b.mu)
	boxes.Store(b.id, b)
	return b
}

// post enqueues one delivery. A send to a service that has already died is a
// no-op, not an error: that is what the monitor is for.
func (b *mailbox) post(d delivery) {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	b.queue = append(b.queue, d)
	b.mu.Unlock()
	b.cond.Signal()
}

func (b *mailbox) take() (delivery, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for len(b.queue) == 0 && !b.closed {
		b.cond.Wait()
	}
	if len(b.queue) == 0 {
		return delivery{}, false
	}
	d := b.queue[0]
	b.queue = b.queue[1:]
	return d, true
}

// value resolves a delivery to a message value, decoding a wire payload on the
// recipient's turn. A digest mismatch is reported here, where it can name the
// service, rather than silently decoding another type's bytes.
func (b *mailbox) value(d delivery) (any, error) {
	if d.raw == nil {
		return d.value, nil
	}
	if d.digest != 0 && b.digest != 0 && d.digest != b.digest {
		return nil, fmt.Errorf(
			\"message type digest %08x does not match the mailbox's %08x — the sender was built from a different message type\",
			d.digest, b.digest)
	}
	if b.decode == nil {
		return nil, fmt.Errorf(\"this service cannot decode messages from the wire\")
	}
	return b.decode(d.raw)
}

// die closes the mailbox, unregisters it, fails every call still waiting on it
// and notifies its watchers.
func (b *mailbox) die(reason string) {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	b.closed = true
	ws := b.watchers
	b.watchers = nil
	// Requests still queued will never be handled, so their callers are told
	// now rather than left to wait out a timeout.
	orphans := b.queue
	b.queue = nil
	b.mu.Unlock()
	b.cond.Broadcast()

	for _, d := range orphans {
		failDelivery(d, \"Down\", \"the service died before answering: \"+reason)
	}
	boxes.Delete(b.id)
	if b.name != atomNone {
		slots := registrySlots()
		if int(b.name) >= 0 && int(b.name) < len(slots) {
			slots[b.name].CompareAndSwap(b, nil)
		}
	}
	failCallsTo(b.id, reason)
	for _, w := range ws {
		notifyWatcher(w)
	}
}

// failDelivery tells the caller of an unanswerable request that it will never be
// answered. A local caller gets it through its pending channel; one on another
// node gets a frame, so either way it fails fast instead of timing out.
func failDelivery(d delivery, reason, message string) {
	if d.ref == 0 {
		return
	}
	if d.origin == \"\" {
		deliverAnswer(d.ref, answer{err: &SyslinkError{Reason: reason, Message: message}})
		return
	}
	// The reason has to survive the wire, so it travels ahead of the message.
	sendFrame(d.origin, frame{kind: kindNoProc, ref: d.ref, payload: []byte(reason + \"|\" + message)})
}

func notifyWatcher(w watcher) {
	if w.box != nil {
		w.box.post(delivery{value: w.value, origin: \"\"})
		return
	}
	sendFrame(w.node, frame{
		kind:    kindDown,
		name:    atomNone,
		id:      w.id,
		ref:     w.mon,
		digest:  w.digest,
		payload: w.payload,
	})
}

// ---------------------------------------------------------------------------
// Spawning
// ---------------------------------------------------------------------------

// SyslinkSpawn starts an anonymous service and returns its address without
// blocking. `handler` is the fold: it receives the state, one message and the
// turn's envelope, and returns the next state. There is no mutex anywhere —
// the fold is the mutex.
// `repliesInTurn` is decided by the compiler, not the programmer: it is true when
// the handler's envelope provably cannot outlive the turn it arrived in, which is
// what makes an unanswered request safe to fail immediately.
func SyslinkSpawn[S any, M any](
	handler func(S, M, Envelope) S,
	initial S,
	decode func([]byte) (any, error),
	digest uint32,
	repliesInTurn bool,
) Address {
	b := newMailbox(decode, digest)
	go runService(b, handler, initial, repliesInTurn)
	return Address{Name: atomNone, Id: b.id, box: b}
}

func runService[S any, M any](
	b *mailbox,
	handler func(S, M, Envelope) S,
	initial S,
	repliesInTurn bool,
) {
	state := initial
	reason := \"normal\"
	for {
		d, ok := b.take()
		if !ok {
			break
		}
		raw, err := b.value(d)
		if err != nil {
			fmt.Println(\"hive: \" + serviceLabel(b) + \" dropped a message: \" + err.Error())
			// Whoever is waiting is waiting for nothing, and this is already known
			// — so say so now instead of letting them sit out a timeout.
			failDelivery(d, \"Decode\", serviceLabel(b)+\" could not read the message: \"+err.Error())
			continue
		}
		msg, fits := raw.(M)
		if !fits {
			fmt.Println(\"hive: \" + serviceLabel(b) + \" dropped a message of an unexpected type\")
			failDelivery(d, \"Decode\", serviceLabel(b)+\" does not handle messages of that type\")
			continue
		}
		turn := &turnState{}
		next, crashed := serviceTurn(handler, state, msg, Envelope{self: b, ref: d.ref, origin: d.origin, turn: turn})
		if crashed != nil {
			// A panic inside a service kills that service and nothing else: the
			// node stays up and the failure reaches whoever is monitoring. That
			// is what makes supervision meaningful.
			reason = Show(crashed)
			fmt.Println(\"hive: \" + serviceLabel(b) + \" crashed: \" + reason)
			// The request being handled when it crashed is one its caller is
			// still waiting on.
			failDelivery(d, \"Down\", \"the service crashed while handling the request: \"+reason)
			break
		}
		state = next

		// The turn is over and nothing answered. For a handler whose envelope
		// cannot outlive its turn — which the compiler works out and passes in as
		// `repliesInTurn` — no answer is ever coming, so the caller is told at
		// once rather than discovering it when its patience runs out.
		//
		// Where the envelope *can* escape (stored in the state, handed to a task),
		// a reply may still be on its way and this stays quiet.
		if repliesInTurn && d.ref != 0 && !turn.answered.Load() {
			failDelivery(d, \"NoReply\",
				serviceLabel(b)+\" handled the message but never answered it\")
		}
	}
	b.die(reason)
}

// serviceTurn runs one turn with the panic contained. On a crash the state is
// left untouched and the panic value is handed back as the death reason.
func serviceTurn[S any, M any](
	handler func(S, M, Envelope) S,
	state S,
	msg M,
	env Envelope,
) (next S, crashed any) {
	next = state
	defer func() {
		if r := recover(); r != nil {
			crashed = r
		}
	}()
	next = handler(state, msg, env)
	return next, nil
}

func serviceLabel(b *mailbox) string {
	if b.name != atomNone {
		return \"service \" + b.name.String()
	}
	return \"service #\" + strconv.FormatUint(b.id, 10)
}

// SyslinkStop shuts a service down. Its mailbox closes, its watchers are told,
// and calling it twice is harmless.
func SyslinkStop(addr Address) {
	if b, ok := resolveLocal(addr); ok {
		b.die(\"stopped\")
		return
	}
	sendFrame(addr.Endpoint, frame{kind: kindStop, name: addr.Name, id: addr.Id})
}

// ---------------------------------------------------------------------------
// The registry
// ---------------------------------------------------------------------------

// SyslinkRegister publishes a service under a name, so another node can reach
// it without holding its address.
func SyslinkRegister(name Atom, addr Address) Result[Address, SyslinkError] {
	b, ok := resolveLocal(addr)
	if !ok {
		return syslinkErr[Address](\"NoProc\", \"only a service running on this node can be registered\")
	}
	slots := registrySlots()
	if int(name) < 0 || int(name) >= len(slots) {
		return syslinkErr[Address](\"NoProc\", \"unknown name \"+name.String())
	}
	if !slots[name].CompareAndSwap(nil, b) {
		return syslinkErr[Address](\"Taken\", \"the name \"+name.String()+\" is already registered on this node\")
	}
	b.mu.Lock()
	b.name = name
	b.mu.Unlock()
	return Ok[Address, SyslinkError](Address{Endpoint: SyslinkNode(), Name: name, Id: b.id, box: b})
}

// SyslinkAt is the address of a named service on a node role. It performs no
// I/O and cannot fail: it is address construction, not a lookup, which is what
// lets a program name a service that is not running yet, or is temporarily
// down, and still type-check and run.
func SyslinkAt(name Atom) Address {
	if b := lookupName(name); b != nil {
		return Address{Name: name, Id: b.id, box: b}
	}
	return Address{Name: name, Id: 0}
}

// SyslinkOn is the address of a named service on the node reachable at
// `endpoint`. Like SyslinkAt it performs no I/O and cannot fail: nothing is
// dialed and nothing is looked up, so a program can name a service that is not
// running yet — or a node that is temporarily down — and still run.
func SyslinkOn(endpoint string, name Atom) Address {
	if endpoint == \"\" || endpoint == SyslinkNode() {
		return SyslinkAt(name)
	}
	return Address{Endpoint: endpoint, Name: name, Id: 0}
}

func lookupName(name Atom) *mailbox {
	slots := registrySlots()
	if int(name) < 0 || int(name) >= len(slots) {
		return nil
	}
	return slots[name].Load()
}

// resolveLocal answers with the mailbox behind an address when the service
// lives in this process — either because the address carries it directly, or
// because it names this node.
func resolveLocal(addr Address) (*mailbox, bool) {
	if addr.Endpoint != \"\" && addr.Endpoint != SyslinkNode() {
		return nil, false
	}
	// A *named* address is resolved through the registry every single time, and
	// never through the mailbox it happened to find when it was built. The name is
	// the identity: a replacement registered under it has to be picked up by
	// everyone still holding the address, which is the entire reason a name is
	// worth having over an id. Trusting a cached mailbox would make a restart
	// invisible to the holder and quietly feed its messages to the dead service —
	// and since a send never fails, it would never find out.
	if addr.Name != atomNone {
		if b := lookupName(addr.Name); b != nil {
			return b, true
		}
		return nil, false
	}
	// An anonymous address is only ever itself. There is nothing to re-resolve to,
	// so its mailbox dying is final.
	if addr.box != nil {
		return addr.box, true
	}
	if addr.Id != 0 {
		if b, ok := boxes.Load(addr.Id); ok {
			return b.(*mailbox), true
		}
	}
	return nil, false
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

// syslinkStrict forces a local send through the same encode/decode path a
// remote one takes, so a message that could not survive the wire fails in a
// single-process test run rather than the first time a peer is added.
var strictOnce sync.Once
var strict bool

func syslinkStrict() bool {
	strictOnce.Do(func() {
		strict = os.Getenv(\"HIVE_SYSLINK_STRICT\") != \"\"
	})
	return strict
}

// SyslinkSend delivers one message and returns immediately. It never blocks and
// never fails — a dead or unreachable recipient is not an error at the send
// site, which is exactly what keeps a local send and a remote one the same
// statement. The caller has already copied the message, so the recipient can
// never observe the sender mutating it.
func SyslinkSend[M any](addr Address, msg M, encode func(M) []byte, digest uint32) {
	if b, ok := resolveLocal(addr); ok {
		if syslinkStrict() {
			b.post(delivery{raw: encode(msg), digest: digest, origin: \"\"})
			return
		}
		b.post(delivery{value: msg, origin: \"\"})
		return
	}
	sendFrame(addr.Endpoint, frame{
		kind:    kindCast,
		name:    addr.Name,
		id:      addr.Id,
		digest:  digest,
		payload: encode(msg),
	})
}

// ---------------------------------------------------------------------------
// Request / response
// ---------------------------------------------------------------------------

// answer is one reply travelling back to a waiting call: a value for a local
// exchange, raw bytes for one that crossed the wire, or a failure.
type answer struct {
	value any
	raw   []byte
	err   *SyslinkError
}

type pendingCall struct {
	reply  chan answer
	target uint64
	node   string
	born   time.Time
}

var (
	refSeq  atomic.Uint64
	pendMu  sync.Mutex
	pending = map[uint64]pendingCall{}
)

// How long an outstanding request is kept before it is assumed abandoned. A
// request whose value is never awaited would otherwise sit in the table forever;
// this is the backstop, not the timeout (that lives at the await site).
const syslinkRefLifetime = 10 * time.Minute

func awaitRef(target uint64, node string) (uint64, chan answer) {
	ref := refSeq.Add(1)
	ch := make(chan answer, 1)
	pendMu.Lock()
	pending[ref] = pendingCall{reply: ch, target: target, node: node, born: time.Now()}
	// Sweep abandoned requests on the way in, so no timer goroutine is needed
	// and a program that never abandons one never pays for this.
	if len(pending) > 64 {
		cutoff := time.Now().Add(-syslinkRefLifetime)
		for old, p := range pending {
			if p.born.Before(cutoff) {
				delete(pending, old)
			}
		}
	}
	pendMu.Unlock()
	return ref, ch
}

func dropRef(ref uint64) {
	pendMu.Lock()
	delete(pending, ref)
	pendMu.Unlock()
}

func deliverAnswer(ref uint64, a answer) {
	pendMu.Lock()
	p, ok := pending[ref]
	delete(pending, ref)
	pendMu.Unlock()
	if ok {
		p.reply <- a
	}
}

// failCallsTo fails every call waiting on a service that has just died, so a
// caller learns immediately instead of waiting out its timeout.
func failCallsTo(target uint64, reason string) {
	pendMu.Lock()
	hit := []pendingCall{}
	for ref, p := range pending {
		if p.target == target {
			hit = append(hit, p)
			delete(pending, ref)
		}
	}
	pendMu.Unlock()
	for _, p := range hit {
		p.reply <- answer{err: &SyslinkError{Reason: \"Down\", Message: \"the service died before answering: \" + reason}}
	}
}

// failCallsToNode fails every call waiting on a node that has just been
// declared unreachable.
func failCallsToNode(node string, reason string) {
	pendMu.Lock()
	hit := []pendingCall{}
	for ref, p := range pending {
		if p.node == node {
			hit = append(hit, p)
			delete(pending, ref)
		}
	}
	pendMu.Unlock()
	for _, p := range hit {
		p.reply <- answer{err: &SyslinkError{Reason: \"Unreachable\", Message: reason}}
	}
}

// syslinkDefaultWait is how long an awaited request waits when the await site
// gives no `with timeout` of its own.
const syslinkDefaultWait = 5000

// SyslinkPending is a request in flight — what `hive.syslink.send` evaluates to
// when its value is kept rather than discarded.
//
// It is deliberately not an *Async: no goroutine is parked waiting for the
// answer. The reply arrives on the connection's own reader goroutine, so a held
// request costs a channel and nothing else, and the waiting happens at the
// `await` site where the patience is specified.
type SyslinkPending[M any] struct {
	ref    uint64
	reply  chan answer
	decode func([]byte) (M, error)

	mu       sync.Mutex
	resolved bool
	result   Result[M, SyslinkError]
}

// SyslinkSendAwaitable starts a request and returns immediately. The message has
// already been copied by the caller, exactly as for a discarded send: whether an
// answer is wanted changes nothing about how the message travels.
func SyslinkSendAwaitable[M any](
	addr Address,
	msg M,
	encode func(M) []byte,
	digest uint32,
	decode func([]byte) (M, error),
) *SyslinkPending[M] {
	local, isLocal := resolveLocal(addr)

	target := uint64(0)
	node := \"\"
	if isLocal {
		target = local.id
	} else {
		node = addr.Endpoint
	}
	ref, ch := awaitRef(target, node)
	p := &SyslinkPending[M]{ref: ref, reply: ch, decode: decode}

	if isLocal {
		if syslinkStrict() {
			local.post(delivery{raw: encode(msg), digest: digest, ref: ref, origin: \"\"})
		} else {
			local.post(delivery{value: msg, ref: ref, origin: \"\"})
		}
		return p
	}
	if err := sendFrame(addr.Endpoint, frame{
		kind:    kindRequest,
		name:    addr.Name,
		id:      addr.Id,
		ref:     ref,
		digest:  digest,
		payload: encode(msg),
	}); err != nil {
		// Unreachable before the request even left: settle now, so awaiting is
		// instant rather than a pointless wait for an answer that cannot come.
		dropRef(ref)
		p.settle(syslinkErr[M](err.Reason, err.Message))
	}
	return p
}

func (p *SyslinkPending[M]) settle(r Result[M, SyslinkError]) {
	p.mu.Lock()
	p.resolved = true
	p.result = r
	p.mu.Unlock()
}

// SyslinkAwait waits for the answer to a request. This is the one place in the
// module that reports failure, because it is the one place with somewhere to
// report it to: a timeout, a service that died mid-request and an unreachable
// node all arrive here as a Result.Error.
//
// A settled answer is remembered, so awaiting twice returns the same value
// instantly. A timeout deliberately is *not* remembered: the request is still
// outstanding and the answer may yet arrive, so the same handle can be awaited
// again with more patience.
func SyslinkAwait[M any](p *SyslinkPending[M], ms int) Result[M, SyslinkError] {
	if p == nil {
		return syslinkErr[M](\"NoProc\", \"there is no request to wait for\")
	}
	p.mu.Lock()
	if p.resolved {
		r := p.result
		p.mu.Unlock()
		return r
	}
	p.mu.Unlock()

	if ms <= 0 {
		ms = syslinkDefaultWait
	}
	timer := time.NewTimer(time.Duration(ms) * time.Millisecond)
	defer timer.Stop()

	select {
	case a := <-p.reply:
		r := p.interpret(a)
		p.settle(r)
		return r
	case <-timer.C:
		return syslinkErr[M](\"Timeout\", \"no answer within \"+strconv.Itoa(ms)+\"ms\")
	}
}

func (p *SyslinkPending[M]) interpret(a answer) Result[M, SyslinkError] {
	if a.err != nil {
		return Err[M, SyslinkError](*a.err)
	}
	if a.raw != nil {
		v, err := p.decode(a.raw)
		if err != nil {
			return syslinkErr[M](\"Decode\", \"the answer did not match this service's message type: \"+err.Error())
		}
		return Ok[M, SyslinkError](v)
	}
	v, fits := a.value.(M)
	if !fits {
		return syslinkErr[M](\"Decode\", \"the service answered with a value that is not one of its own messages\")
	}
	return Ok[M, SyslinkError](v)
}

// SyslinkAwaitAll is the barrier behind `await` on a vector of requests: one
// deadline across all of them, so a laggard becomes a Timeout error in its own
// slot rather than failing the whole vector.
func SyslinkAwaitAll[M any](ps []*SyslinkPending[M], ms int) []Result[M, SyslinkError] {
	if ms <= 0 {
		ms = syslinkDefaultWait
	}
	deadline := time.Now().Add(time.Duration(ms) * time.Millisecond)
	out := make([]Result[M, SyslinkError], len(ps))
	for i, p := range ps {
		left := int(time.Until(deadline) / time.Millisecond)
		if left <= 0 {
			left = 1
		}
		out[i] = SyslinkAwait(p, left)
	}
	return out
}

// SyslinkAnswer replies to a call. On a cast there is nothing waiting, so it is
// a no-op — the same message can be handled either way without the service
// caring which it was.
func SyslinkAnswer[V any](env Envelope, value V, encode func(V) []byte) {
	if env.ref == 0 {
		return
	}
	if env.turn != nil {
		env.turn.answered.Store(true)
	}
	if env.origin == \"\" {
		if syslinkStrict() {
			deliverAnswer(env.ref, answer{raw: encode(value)})
			return
		}
		deliverAnswer(env.ref, answer{value: value})
		return
	}
	sendFrame(env.origin, frame{kind: kindReply, ref: env.ref, payload: encode(value)})
}

// SyslinkSelf is the running service's own address, for handing to someone who
// should reply or report back later.
func SyslinkSelf(env Envelope) Address {
	if env.self == nil {
		return Address{Name: atomNone, Id: 0}
	}
	return Address{Endpoint: SyslinkNode(), Name: env.self.name, Id: env.self.id, box: env.self}
}

// ---------------------------------------------------------------------------
// Monitors
// ---------------------------------------------------------------------------

// SyslinkMonitor asks to be told when `target` dies, by delivering a message
// the watcher chose itself — which is how a mailbox stays a single user type
// with no builtin envelope union polluting it. If the target is already dead
// the message arrives right away.
func SyslinkMonitor[M any](env Envelope, target Address, msg M, encode func(M) []byte, digest uint32) {
	if env.self == nil {
		return
	}
	me := env.self
	if b, ok := resolveLocal(target); ok {
		b.mu.Lock()
		if b.closed {
			b.mu.Unlock()
			me.post(delivery{value: msg, origin: \"\"})
			return
		}
		b.watchers = append(b.watchers, watcher{box: me, value: msg})
		b.mu.Unlock()
		return
	}
	// The target's node holds the registration and reports the death. Keep a
	// local record too, so losing the node fires the monitor even though the
	// service itself never got the chance to.
	mon := monSeq.Add(1)
	w := watcher{box: me, value: msg, mon: mon}
	rememberRemoteWatch(target.Endpoint, w)
	if err := sendFrame(target.Endpoint, frame{
		kind:    kindMonitor,
		name:    target.Name,
		id:      target.Id,
		watcher: me.id,
		ref:     mon,
		digest:  digest,
		payload: encode(msg),
	}); err != nil {
		// A node we cannot even reach is indistinguishable from a service that
		// has already died, so the monitor fires now rather than waiting for a
		// connection that may never exist.
		forgetRemoteWatch(target.Endpoint, mon)
		notifyWatcher(w)
	}
}

// registerRemoteWatcher records a monitor asked for by another node.
func registerRemoteWatcher(target Address, from string, watcherID, mon uint64, payload []byte, digest uint32) {
	w := watcher{node: from, id: watcherID, mon: mon, payload: payload, digest: digest}
	b, ok := resolveLocal(target)
	if !ok {
		notifyWatcher(w)
		return
	}
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		notifyWatcher(w)
		return
	}
	b.watchers = append(b.watchers, w)
	b.mu.Unlock()
}
"
}

/// Source of `hive/syslink_net.go`: the frame codec, one multiplexed and always
/// encrypted connection per node pair, and the handshake authenticating it.
pub fn syslink_net_go() -> String {
  "package hive

import (
	\"bufio\"
	\"bytes\"
	\"crypto/ed25519\"
	\"crypto/hmac\"
	\"crypto/rand\"
	\"crypto/sha256\"
	\"crypto/tls\"
	\"crypto/x509\"
	\"crypto/x509/pkix\"
	\"encoding/binary\"
	\"errors\"
	\"fmt\"
	\"io\"
	\"math/big\"
	\"os\"
	\"path/filepath\"
	\"strconv\"
	\"strings\"
	\"sync\"
	\"sync/atomic\"
	\"time\"
)

// ---------------------------------------------------------------------------
// hive.syslink — the wire
// ---------------------------------------------------------------------------
// One persistent, multiplexed connection per node pair, carrying
// length-prefixed frames. Not one per service and not one per message: message
// order is guaranteed between a pair of nodes, which means there has to be
// exactly one FIFO pipe per pair.
//
// The connection is symmetric: replies travel back over the same pipe, so a
// node that can only dial out (behind NAT, in a container with no inbound
// route) still takes part fully. Either end may dial, and when both do at once
// exactly one connection survives — see `install`.
//
// Every connection is TLS 1.3, mutually authenticated, always. There is no
// plaintext path and no capability flag to negotiate one away. Certificates are
// generated at boot and thrown away; they carry keys, not identity. Identity
// comes from a cluster secret proven over the pair of certificates as each side
// locally sees them, which is what stops an attacker who terminates TLS on both
// sides from relaying one side's proof to the other.

const (
	syslinkMagic     = \"HIVE-SL1\"
	syslinkTickEvery = 15 * time.Second
	syslinkTickMiss  = 3
	syslinkMaxFrame  = 8 << 20  // a frame larger than this is refused, not buffered
	syslinkMaxOutbox = 64 << 20 // past this a node is declared unreachable
)

type frameKind byte

const (
	kindCast frameKind = iota + 1
	kindRequest
	kindReply
	kindMonitor
	kindStop
	kindTick
	// kindNoProc answers a request that found no service, or whose service died
	// before it could answer. It is a distinct kind rather than an empty reply
	// because an empty reply is a legitimate answer.
	kindNoProc
	// kindDown reports a death to a monitor on another node. `id` is the
	// watching mailbox, `ref` the monitor id it was registered under, and the
	// payload is the death message the watcher chose.
	kindDown
)

// frame is one multiplexed message. `name` addresses a registered service and
// travels as text, because atom ids are assigned per build: #Cache may be 7 in
// one binary and 11 in another. `id` addresses an anonymous mailbox instead.
type frame struct {
	kind    frameKind
	name    Atom
	id      uint64
	ref     uint64
	watcher uint64
	digest  uint32
	payload []byte
}

// ---------------------------------------------------------------------------
// Node identity and peer endpoints
// ---------------------------------------------------------------------------

var (
	nodeMu sync.RWMutex
	// What this node tells peers to dial it on. It is an endpoint, not a name:
	// there is no cluster-wide namespace to register in and nothing to collide
	// over, and where a node lives is configuration rather than source.
	selfEndpoint string
	// Live connections, keyed by the peer's *advertised* endpoint rather than by
	// whatever string was dialed. That canonical key is what stops
	// \"localhost:9101\" and \"127.0.0.1:9101\" opening two connections to the same
	// node — which would quietly break the ordering guarantee.
	sessions = map[string]*session{}
	// as-dialed endpoint -> the peer's advertised endpoint, so a repeat send
	// finds the existing connection without dialing again.
	dialed    = map[string]string{}
	watchesMu sync.Mutex
	watches   = map[string][]watcher{} // local watchers waiting on a remote node
	monSeq    atomic.Uint64
)

// SyslinkNode is the endpoint this node advertises.
func SyslinkNode() string {
	nodeMu.RLock()
	defer nodeMu.RUnlock()
	return selfEndpoint
}

// SyslinkListen starts accepting connections from other nodes. `endpoint` is what
// this node tells peers to dial it on — \"127.0.0.1:9100\", \"10.0.0.4:9100\",
// \"cache-0.internal:9100\". The port is taken from it and bound on every
// interface; the whole string is advertised, which is what lets an address handed
// to one node stay dialable when it is passed on to a third.
//
// There is no port-mapper daemon and no cluster-wide name registry: a node is
// simply where it is.
func SyslinkListen(endpoint string) Result[string, SyslinkError] {
	if _, err := clusterSecret(); err != nil {
		return syslinkErr[string](\"NoKey\", err.Error())
	}
	cert, err := ephemeralCert()
	if err != nil {
		return syslinkErr[string](\"NoKey\", \"could not generate this node's key: \"+err.Error())
	}
	port := endpoint
	if i := strings.LastIndex(endpoint, \":\"); i >= 0 {
		port = endpoint[i+1:]
	}
	if _, err := strconv.Atoi(port); err != nil {
		return syslinkErr[string](\"NoListener\",
			\"`\"+endpoint+\"` is not a host:port this node can listen on\")
	}
	ln, err := tls.Listen(\"tcp\", \":\"+port, serverTLS(cert))
	if err != nil {
		return syslinkErr[string](\"NoListener\", \"could not listen on port \"+port+\": \"+err.Error())
	}
	nodeMu.Lock()
	selfEndpoint = endpoint
	nodeMu.Unlock()

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go acceptSession(conn.(*tls.Conn))
		}
	}()
	return Ok[string, SyslinkError](endpoint)
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

// session is one connection to one peer node, with an unbounded outbox drained
// by a single writer goroutine. `send` therefore never touches the socket on the
// caller's goroutine and never blocks.
type session struct {
	// The peer's advertised endpoint, learned in the handshake.
	node string
	conn *tls.Conn
	// Which end dialed. Both nodes have to agree on which of two simultaneous
	// connections survives, and direction is the only thing they can compare
	// without another round trip.
	outbound bool

	mu     sync.Mutex
	cond   *sync.Cond
	out    [][]byte
	bytes  int
	closed bool

	lastSeen time.Time
}

func newSession(node string, conn *tls.Conn, outbound bool) *session {
	s := &session{node: node, conn: conn, outbound: outbound, lastSeen: time.Now()}
	s.cond = sync.NewCond(&s.mu)
	return s
}

// enqueue queues an encoded frame. Past the water mark the peer is declared
// unreachable rather than growing the queue without bound: that turns an
// unbounded memory problem into the failure the programmer already handles,
// and keeps `send` non-blocking.
func (s *session) enqueue(b []byte) bool {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return false
	}
	if s.bytes+len(b) > syslinkMaxOutbox {
		s.mu.Unlock()
		s.shutdown(\"the outbox passed \" + strconv.Itoa(syslinkMaxOutbox) + \" bytes\")
		return false
	}
	s.out = append(s.out, b)
	s.bytes += len(b)
	s.mu.Unlock()
	s.cond.Signal()
	return true
}

func (s *session) drain() ([]byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for len(s.out) == 0 && !s.closed {
		s.cond.Wait()
	}
	if len(s.out) == 0 {
		return nil, false
	}
	b := s.out[0]
	s.out = s.out[1:]
	s.bytes -= len(b)
	return b, true
}

// shutdown drops the connection and reports the node down: every call waiting
// on it fails, and every local watcher waiting on one of its services is told.
// Messages still queued are discarded — delivery is best-effort, and a
// reconnect does not resurrect them.
func (s *session) shutdown(reason string) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.out = nil
	s.bytes = 0
	s.mu.Unlock()
	s.cond.Broadcast()
	s.conn.Close()

	nodeMu.Lock()
	if sessions[s.node] == s {
		delete(sessions, s.node)
	}
	for typed, canonical := range dialed {
		if canonical == s.node {
			delete(dialed, typed)
		}
	}
	nodeMu.Unlock()

	failCallsToNode(s.node, \"the node at \"+s.node+\" is unreachable: \"+reason)
	nodeDown(s.node)
	fmt.Println(\"hive: the node at \" + s.node + \" is down (\" + reason + \")\")
}

func (s *session) writer() {
	w := bufio.NewWriter(s.conn)
	for {
		b, ok := s.drain()
		if !ok {
			return
		}
		if _, err := w.Write(b); err != nil {
			s.shutdown(\"write failed: \" + err.Error())
			return
		}
		// Flush only when the queue has drained, so a burst of sends becomes one
		// write without ever leaving a message sitting in the buffer.
		s.mu.Lock()
		more := len(s.out) > 0
		s.mu.Unlock()
		if !more {
			if err := w.Flush(); err != nil {
				s.shutdown(\"flush failed: \" + err.Error())
				return
			}
		}
	}
}

func (s *session) reader() {
	r := bufio.NewReader(s.conn)
	for {
		s.conn.SetReadDeadline(time.Now().Add(syslinkTickEvery * syslinkTickMiss))
		f, err := readFrame(r)
		if err != nil {
			if errors.Is(err, io.EOF) {
				s.shutdown(\"the peer hung up\")
			} else {
				s.shutdown(\"read failed: \" + err.Error())
			}
			return
		}
		s.mu.Lock()
		s.lastSeen = time.Now()
		s.mu.Unlock()
		if f.kind != kindTick {
			routeFrame(s.node, f)
		}
	}
}

func (s *session) ticker() {
	t := time.NewTicker(syslinkTickEvery)
	defer t.Stop()
	for range t.C {
		s.mu.Lock()
		closed := s.closed
		s.mu.Unlock()
		if closed {
			return
		}
		s.enqueue(writeFrame(frame{kind: kindTick}))
	}
}

func (s *session) start() {
	go s.writer()
	go s.reader()
	go s.ticker()
}

// sessionFor hands back the live connection to a node, dialing one if there is
// none. It is the only place a connection is created, so a node pair can never
// end up with two.
func sessionFor(endpoint string) (*session, *SyslinkError) {
	if endpoint == \"\" {
		return nil, &SyslinkError{Reason: \"NoPeer\", Message: \"the address does not say where its node is\"}
	}
	nodeMu.RLock()
	canonical, known := dialed[endpoint]
	s, ok := sessions[endpoint]
	if !ok && known {
		s, ok = sessions[canonical]
	}
	nodeMu.RUnlock()
	if ok {
		return s, nil
	}
	if SyslinkNode() == \"\" {
		return nil, &SyslinkError{
			Reason:  \"NoListener\",
			Message: \"this node is not listening yet — call hive.syslink.listen before addressing another node\",
		}
	}
	return dialSession(endpoint)
}

func dialSession(endpoint string) (*session, *SyslinkError) {
	cert, err := ephemeralCert()
	if err != nil {
		return nil, &SyslinkError{Reason: \"NoKey\", Message: err.Error()}
	}
	raw, err := tls.Dial(\"tcp\", endpoint, clientTLS(cert))
	if err != nil {
		return nil, &SyslinkError{
			Reason:  \"Unreachable\",
			Message: \"could not reach the node at \" + endpoint + \": \" + err.Error(),
		}
	}
	// The peer's own advertised endpoint comes back from the handshake, and that
	// is what the connection is filed under — not the string that was dialed.
	advertised, err := handshakeInitiator(raw)
	if err != nil {
		raw.Close()
		return nil, &SyslinkError{Reason: \"Unreachable\", Message: err.Error()}
	}
	nodeMu.Lock()
	dialed[endpoint] = advertised
	nodeMu.Unlock()
	return install(advertised, raw, true)
}

// install adopts a freshly authenticated connection. Without a tiebreak a pair
// of nodes that dial each other at once ends up with two pipes, which silently
// breaks the ordering guarantee — so exactly one survives: the one dialed by the
// lexicographically smaller node name.
//
// That rule is stated in terms both ends compute identically. Each side asks
// only \"should this connection have been dialed by me?\", and since the two
// disagree about who is smaller in exactly the complementary way, they always
// keep the same TCP connection. Comparing anything local — which arrived first,
// say — is what the earlier version got wrong: both sides then kept a different
// connection and each closed the other's.
func install(node string, conn *tls.Conn, outbound bool) (*session, *SyslinkError) {
	keep := preferOutbound(node) == outbound

	nodeMu.Lock()
	existing, clash := sessions[node]
	if clash {
		if !keep {
			nodeMu.Unlock()
			conn.Close()
			return existing, nil
		}
		delete(sessions, node)
	}
	s := newSession(node, conn, outbound)
	sessions[node] = s
	nodeMu.Unlock()

	if clash {
		// A replaced duplicate is not a node going down: nothing failed, and
		// reporting it would fire monitors for a peer that is perfectly healthy.
		existing.closeQuietly()
	}
	s.start()
	return s, nil
}

// preferOutbound: whether the surviving connection to `node` is the one this
// node dialed. True for the lexicographically smaller name, so the two ends
// always reach complementary answers.
func preferOutbound(node string) bool {
	return SyslinkNode() < node
}

// closeQuietly drops a connection without declaring the node down.
func (s *session) closeQuietly() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.out = nil
	s.bytes = 0
	s.mu.Unlock()
	s.cond.Broadcast()
	s.conn.Close()
}

func acceptSession(conn *tls.Conn) {
	peer, err := handshakeResponder(conn)
	if err != nil {
		fmt.Println(\"hive: rejected a connection: \" + err.Error())
		// Tell the caller it was turned away, without saying which check failed:
		// \"EOF\" is a miserable thing to debug against, and an unauthenticated
		// caller has no business learning why.
		reject := append([]byte(syslinkMagic), 0, 0)
		conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
		conn.Write(reject)
		conn.Close()
		return
	}
	install(peer, conn, false)
}

// sendFrame is the one path out of this node. A failure to reach the peer is
// reported back for `call` to turn into a Result.Error; a cast ignores it,
// because a send never fails at its own call site.
func sendFrame(endpoint string, f frame) *SyslinkError {
	s, err := sessionFor(endpoint)
	if err != nil {
		return err
	}
	if !s.enqueue(writeFrame(f)) {
		return &SyslinkError{Reason: \"Unreachable\", Message: \"the node at \" + endpoint + \" is unreachable\"}
	}
	return nil
}

// routeFrame hands an arrived frame to its mailbox. The payload is not decoded
// here: that happens on the recipient's own turn, so a bad message cannot take
// down a connection shared with every other service on this node.
func routeFrame(from string, f frame) {
	switch f.kind {
	case kindCast, kindRequest:
		dest := Address{Name: f.name, Id: f.id}
		b, ok := resolveLocal(dest)
		if !ok {
			if f.kind == kindRequest {
				sendFrame(from, frame{
					kind:    kindNoProc,
					ref:     f.ref,
					payload: []byte(\"NoProc|no service is registered here under that name\"),
				})
			}
			return
		}
		ref := uint64(0)
		origin := \"\"
		if f.kind == kindRequest {
			ref = f.ref
			origin = from
		}
		b.post(delivery{raw: f.payload, digest: f.digest, ref: ref, origin: origin})
	case kindReply:
		deliverAnswer(f.ref, answer{raw: f.payload})
	case kindNoProc:
		// The reason travels ahead of the message, so a \"never answered\" is not
		// flattened into a \"no such service\".
		reason, message := \"NoProc\", string(f.payload)
		if i := strings.Index(message, \"|\"); i >= 0 {
			reason, message = message[:i], message[i+1:]
		}
		deliverAnswer(f.ref, answer{err: &SyslinkError{Reason: reason, Message: message}})
	case kindMonitor:
		registerRemoteWatcher(
			Address{Name: f.name, Id: f.id},
			from, f.watcher, f.ref, f.payload, f.digest)
	case kindDown:
		// The death was reported, so the fallback record for this monitor is
		// spent: dropping it here is what keeps a monitor one-shot when the node
		// goes on to disappear as well.
		forgetRemoteWatch(from, f.ref)
		if b, ok := boxes.Load(f.id); ok {
			b.(*mailbox).post(delivery{raw: f.payload, digest: f.digest, origin: \"\"})
		}
	case kindStop:
		if b, ok := resolveLocal(Address{Name: f.name, Id: f.id}); ok {
			b.die(\"stopped\")
		}
	}
}

// rememberRemoteWatch records that a local service is waiting on a service that
// lives on another node, so that losing the node fires the monitor.
func rememberRemoteWatch(node string, w watcher) {
	watchesMu.Lock()
	watches[node] = append(watches[node], w)
	watchesMu.Unlock()
}

func forgetRemoteWatch(node string, mon uint64) {
	watchesMu.Lock()
	defer watchesMu.Unlock()
	kept := watches[node][:0]
	for _, w := range watches[node] {
		if w.mon != mon {
			kept = append(kept, w)
		}
	}
	if len(kept) == 0 {
		delete(watches, node)
		return
	}
	watches[node] = kept
}

func nodeDown(node string) {
	watchesMu.Lock()
	ws := watches[node]
	delete(watches, node)
	watchesMu.Unlock()
	for _, w := range ws {
		notifyWatcher(w)
	}
}

// ---------------------------------------------------------------------------
// Frame codec
// ---------------------------------------------------------------------------

func writeFrame(f frame) []byte {
	name := \"\"
	if f.name != atomNone {
		name = f.name.String()
	}
	body := make([]byte, 0, 32+len(name)+len(f.payload))
	body = append(body, byte(f.kind))
	body = binary.BigEndian.AppendUint64(body, f.ref)
	body = binary.BigEndian.AppendUint64(body, f.id)
	body = binary.BigEndian.AppendUint64(body, f.watcher)
	body = binary.BigEndian.AppendUint32(body, f.digest)
	body = binary.BigEndian.AppendUint16(body, uint16(len(name)))
	body = append(body, name...)
	body = binary.BigEndian.AppendUint32(body, uint32(len(f.payload)))
	body = append(body, f.payload...)

	out := binary.BigEndian.AppendUint32(make([]byte, 0, 4+len(body)), uint32(len(body)))
	return append(out, body...)
}

func readFrame(r *bufio.Reader) (frame, error) {
	var head [4]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return frame{}, err
	}
	size := binary.BigEndian.Uint32(head[:])
	if size > syslinkMaxFrame {
		return frame{}, fmt.Errorf(\"frame of %d bytes exceeds the %d byte limit\", size, syslinkMaxFrame)
	}
	body := make([]byte, size)
	if _, err := io.ReadFull(r, body); err != nil {
		return frame{}, err
	}
	if len(body) < 31 {
		return frame{}, errors.New(\"truncated frame header\")
	}
	f := frame{kind: frameKind(body[0])}
	f.ref = binary.BigEndian.Uint64(body[1:9])
	f.id = binary.BigEndian.Uint64(body[9:17])
	f.watcher = binary.BigEndian.Uint64(body[17:25])
	f.digest = binary.BigEndian.Uint32(body[25:29])
	nameLen := int(binary.BigEndian.Uint16(body[29:31]))
	rest := body[31:]
	if len(rest) < nameLen+4 {
		return frame{}, errors.New(\"truncated frame name\")
	}
	f.name = atomNone
	if nameLen > 0 {
		f.name = atomByName(string(rest[:nameLen]))
	}
	rest = rest[nameLen:]
	payloadLen := int(binary.BigEndian.Uint32(rest[:4]))
	rest = rest[4:]
	if len(rest) < payloadLen {
		return frame{}, errors.New(\"truncated frame payload\")
	}
	f.payload = rest[:payloadLen]
	return f, nil
}

// atomByName resolves a name that arrived from the wire back to this build's
// atom. A name this binary never compiled resolves to no atom, so the frame is
// routed nowhere — which is what a service that does not exist here means.
var (
	atomIndexOnce sync.Once
	atomIndex     map[string]Atom
)

func atomByName(name string) Atom {
	atomIndexOnce.Do(func() {
		atomIndex = make(map[string]Atom, len(atomNames))
		for i, n := range atomNames {
			atomIndex[n] = Atom(i)
		}
	})
	if a, ok := atomIndex[name]; ok {
		return a
	}
	return atomNone
}

// ---------------------------------------------------------------------------
// Transport security
// ---------------------------------------------------------------------------

// clusterSecret is what proves a peer belongs. It never crosses the wire and it
// never encrypts anything: TLS 1.3 is always ECDHE, so the session keys are
// ephemeral and leaking this secret tomorrow does not decrypt traffic captured
// today.
var (
	secretOnce sync.Once
	secretVal  []byte
	secretErr  error
)

func clusterSecret() ([]byte, error) {
	secretOnce.Do(func() {
		if env := os.Getenv(\"HIVE_SYSLINK_KEY\"); env != \"\" {
			secretVal = []byte(env)
			return
		}
		home, err := os.UserHomeDir()
		if err != nil {
			secretErr = errors.New(\"no HIVE_SYSLINK_KEY is set and this machine has no home directory to keep one in\")
			return
		}
		dir := filepath.Join(home, \".hive\")
		path := filepath.Join(dir, \"syslink.key\")
		if b, err := os.ReadFile(path); err == nil && len(b) > 0 {
			secretVal = b
			return
		}
		if err := os.MkdirAll(dir, 0o700); err != nil {
			secretErr = errors.New(\"could not create \" + dir + \": \" + err.Error())
			return
		}
		fresh := make([]byte, 32)
		if _, err := rand.Read(fresh); err != nil {
			secretErr = err
			return
		}
		if err := os.WriteFile(path, fresh, 0o600); err != nil {
			secretErr = errors.New(\"could not write \" + path + \": \" + err.Error())
			return
		}
		secretVal = fresh
	})
	return secretVal, secretErr
}

// ephemeralCert is this node's certificate: a fresh Ed25519 key, self-signed,
// generated once at boot and never written to disk. It carries a key, not an
// identity — nothing verifies it, and identity is established by the proof
// below instead.
var (
	certOnce sync.Once
	certVal  tls.Certificate
	certErr  error
)

func ephemeralCert() (tls.Certificate, error) {
	certOnce.Do(func() {
		pub, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			certErr = err
			return
		}
		serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
		if err != nil {
			certErr = err
			return
		}
		template := x509.Certificate{
			SerialNumber:          serial,
			Subject:               pkix.Name{CommonName: \"hive-syslink\"},
			NotBefore:             time.Now().Add(-time.Hour),
			NotAfter:              time.Now().Add(24 * 365 * time.Hour),
			KeyUsage:              x509.KeyUsageDigitalSignature,
			ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
			BasicConstraintsValid: true,
		}
		der, err := x509.CreateCertificate(rand.Reader, &template, &template, pub, priv)
		if err != nil {
			certErr = err
			return
		}
		certVal = tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv}
	})
	return certVal, certErr
}

func serverTLS(cert tls.Certificate) *tls.Config {
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
		MaxVersion:   tls.VersionTLS13,
		// Any certificate is accepted, because the certificate is not the
		// identity. Requiring one is what makes the peer's key available for the
		// binding below.
		ClientAuth: tls.RequireAnyClientCert,
	}
}

func clientTLS(cert tls.Certificate) *tls.Config {
	return &tls.Config{
		Certificates:       []tls.Certificate{cert},
		MinVersion:         tls.VersionTLS13,
		MaxVersion:         tls.VersionTLS13,
		InsecureSkipVerify: true,
	}
}

// bindingProof ties knowledge of the cluster secret to this exact pair of
// certificates, as seen from one end. Both ends compute it from their own view;
// they agree only when the same two certificates sit at the two ends of the
// connection. An attacker who terminates TLS on both sides holds a proof over
// (peer, itself) and needs one over (itself, other peer), which it cannot
// produce without the secret — so relaying a captured proof does not work.
func bindingProof(secret []byte, role string, mine, theirs []byte) []byte {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(\"hive-syslink-v1|\"))
	mac.Write([]byte(role))
	mac.Write([]byte(\"|\"))
	mac.Write(mine)
	mac.Write(theirs)
	return mac.Sum(nil)
}

func certHashes(conn *tls.Conn) (mine, theirs []byte, err error) {
	cert, err := ephemeralCert()
	if err != nil {
		return nil, nil, err
	}
	state := conn.ConnectionState()
	if len(state.PeerCertificates) == 0 {
		return nil, nil, errors.New(\"the peer presented no certificate\")
	}
	m := sha256.Sum256(cert.Certificate[0])
	t := sha256.Sum256(state.PeerCertificates[0].Raw)
	return m[:], t[:], nil
}

// handshakeInitiator runs the dialing half: prove we hold the cluster key, bound
// to this exact pair of certificates, and learn where the peer says it can be
// reached. That advertised endpoint is what the connection gets filed under, so
// two spellings of the same node share one pipe.
//
// Note what is *not* checked any more: there is no node name to claim and none to
// verify. A node is identified by where it is, and you reached it by dialing
// there, so there is nothing left to impersonate.
func handshakeInitiator(conn *tls.Conn) (string, error) {
	if err := conn.Handshake(); err != nil {
		return \"\", errors.New(\"TLS handshake failed: \" + err.Error())
	}
	secret, err := clusterSecret()
	if err != nil {
		return \"\", err
	}
	mine, theirs, err := certHashes(conn)
	if err != nil {
		return \"\", err
	}

	hello := []byte(syslinkMagic)
	hello = appendString(hello, SyslinkNode())
	hello = append(hello, bindingProof(secret, \"initiator\", mine, theirs)...)
	conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := conn.Write(hello); err != nil {
		return \"\", err
	}

	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	r := bufio.NewReader(conn)
	magic := make([]byte, len(syslinkMagic))
	if _, err := io.ReadFull(r, magic); err != nil {
		return \"\", err
	}
	if string(magic) != syslinkMagic {
		return \"\", errors.New(\"the peer does not speak syslink\")
	}
	advertised, err := readString(r)
	if err != nil {
		return \"\", err
	}
	if advertised == \"\" {
		return \"\", errors.New(
			\"the peer turned this connection away — its cluster key does not match this node's\")
	}
	proof := make([]byte, sha256.Size)
	if _, err := io.ReadFull(r, proof); err != nil {
		return \"\", err
	}
	want := bindingProof(secret, \"responder\", theirs, mine)
	if !hmac.Equal(proof, want) {
		return \"\", errors.New(\"the peer could not prove it shares this cluster's key\")
	}
	conn.SetReadDeadline(time.Time{})
	conn.SetWriteDeadline(time.Time{})
	return advertised, nil
}

// handshakeResponder runs the accepting half and answers with its own advertised
// endpoint.
func handshakeResponder(conn *tls.Conn) (string, error) {
	if err := conn.Handshake(); err != nil {
		return \"\", errors.New(\"TLS handshake failed: \" + err.Error())
	}
	secret, err := clusterSecret()
	if err != nil {
		return \"\", err
	}
	mine, theirs, err := certHashes(conn)
	if err != nil {
		return \"\", err
	}

	conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	r := bufio.NewReader(conn)
	magic := make([]byte, len(syslinkMagic))
	if _, err := io.ReadFull(r, magic); err != nil {
		return \"\", err
	}
	if string(magic) != syslinkMagic {
		return \"\", errors.New(\"the caller does not speak syslink\")
	}
	advertised, err := readString(r)
	if err != nil {
		return \"\", err
	}
	proof := make([]byte, sha256.Size)
	if _, err := io.ReadFull(r, proof); err != nil {
		return \"\", err
	}
	want := bindingProof(secret, \"initiator\", theirs, mine)
	if !hmac.Equal(proof, want) {
		return \"\", errors.New(\"the caller could not prove it shares this cluster's key\")
	}
	if advertised == \"\" {
		return \"\", errors.New(\"the caller did not say where it can be reached\")
	}

	hello := []byte(syslinkMagic)
	hello = appendString(hello, SyslinkNode())
	hello = append(hello, bindingProof(secret, \"responder\", mine, theirs)...)
	conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := conn.Write(hello); err != nil {
		return \"\", err
	}
	conn.SetReadDeadline(time.Time{})
	conn.SetWriteDeadline(time.Time{})

	// The reader goroutine takes over from here. Anything the caller pipelined
	// after its hello is still buffered in `r`, so hand that buffer on rather
	// than dropping it.
	if r.Buffered() > 0 {
		buffered, _ := io.ReadAll(io.LimitReader(r, int64(r.Buffered())))
		return advertised, pushBack(conn, buffered)
	}
	return advertised, nil
}

// pushBack is a guard rather than a mechanism: the handshake is strictly
// request/response, so a well-behaved peer never pipelines frames behind its
// hello. If one ever does, fail loudly instead of silently losing messages.
func pushBack(conn *tls.Conn, buffered []byte) error {
	if len(bytes.TrimSpace(buffered)) == 0 {
		return nil
	}
	return errors.New(\"the caller sent frames before its handshake was acknowledged\")
}

func appendString(dst []byte, s string) []byte {
	dst = binary.BigEndian.AppendUint16(dst, uint16(len(s)))
	return append(dst, s...)
}

func readString(r *bufio.Reader) (string, error) {
	var head [2]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return \"\", err
	}
	n := int(binary.BigEndian.Uint16(head[:]))
	b := make([]byte, n)
	if _, err := io.ReadFull(r, b); err != nil {
		return \"\", err
	}
	return string(b), nil
}

"
}
