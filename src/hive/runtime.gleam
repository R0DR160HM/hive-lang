//// The generated Go project's fixed pieces: its `go.mod` and the `hive`
//// runtime package that backs the language's builtins (`Table`, `TableError`,
//// `Result`, `Atom`, `using`/`ReadCSV`, `now`/`Now`, vector concatenation,
//// safe division, `**`, `assert`, SQL parameter sanitization and the
//// `hive.http` standard library).

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
	\"crypto/hmac\"
	\"crypto/rand\"
	\"crypto/sha256\"
	\"crypto/sha512\"
	\"encoding/base64\"
	\"encoding/csv\"
	\"encoding/hex\"
	\"encoding/json\"
	\"fmt\"
	\"io\"
	\"math\"
	\"net/http\"
	\"os\"
	\"reflect\"
	\"strconv\"
	\"strings\"
	\"time\"
	\"unicode/utf8\"
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

// ---------------------------------------------------------------------------
// Conversions (hive.conv): numeric rounding plus value/string conversions.
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Cryptography (hive.crypto): hashes, HMAC, base64, random, and JWTs.
// ---------------------------------------------------------------------------

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

// HttpRequest is the value consumed by `hive.http.request` and produced for
// every incoming call handled by `hive.http.serve`. Headers are a Table of
// [name, value] rows.
type HttpRequest struct {
	Method  string
	Url     string
	Headers Table
	Body    string
}

// HttpResponse is what `hive.http.request` yields and what a `serve` handler
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

// HttpSend backs `hive.http.request`: it performs the request and returns
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

// HttpServe backs `hive.http.serve`: it serves every route through the given
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
		panic(\"hive: http.serve: \" + err.Error())
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
"
}

/// Source of the `hive/sql.go` file, written into the generated project only
/// when the program uses `hive.sql`. It lives in its own file (rather than in
/// `runtime.go`) so that programs which never touch SQL keep a dependency-free
/// `go.mod` and build offline. SQLite is the pure-Go `modernc.org/sqlite`
/// (the engine is compiled straight into the executable — no CGO, no system
/// SQLite); Postgres is `github.com/lib/pq`.
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
