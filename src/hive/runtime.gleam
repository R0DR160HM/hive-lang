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
      markers: ["hive.Env"],
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
      markers: ["hive.Sleep"],
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

import \"time\"

// Sleep parks the calling goroutine for ms milliseconds; only that virtual
// thread waits, so others keep running. A non-positive duration returns at
// once. Backs hive.task.sleep.
func Sleep(ms int) {
	if ms <= 0 {
		return
	}
	time.Sleep(time.Duration(ms) * time.Millisecond)
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

	_ \"github.com/lib/pq\"
	_ \"modernc.org/sqlite\"
)

// DatabaseDriver selects the SQL driver a connection uses. Build it with
// hive.sql.DatabaseDriver.SQLite(), .PostgreSQL() or .Other(name).
type DatabaseDriver struct {
	Name string
}

// SqlError describes a failed database operation.
type SqlError struct {
	Message string
}

func (e SqlError) Error() string { return \"hive: sql error: \" + e.Message }

// SqlConnection is a handle to an open database. The underlying *sql.DB is a
// connection pool, so a single SqlConnection is safe for concurrent use.
type SqlConnection struct {
	db *sql.DB
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
		return Err[SqlConnection, SqlError](SqlError{Message: err.Error()})
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return Err[SqlConnection, SqlError](SqlError{Message: err.Error()})
	}
	return Ok[SqlConnection, SqlError](SqlConnection{db: db})
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
		return Err[Table, SqlError](SqlError{Message: \"connection is not open\"})
	}
	rows, err := conn.db.Query(query)
	if err != nil {
		return Err[Table, SqlError](SqlError{Message: err.Error()})
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return Err[Table, SqlError](SqlError{Message: err.Error()})
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
			return Err[Table, SqlError](SqlError{Message: err.Error()})
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
		return Err[Table, SqlError](SqlError{Message: err.Error()})
	}
	return Ok[Table, SqlError](table)
}
"
}
