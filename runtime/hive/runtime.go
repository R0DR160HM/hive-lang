// Package hive is the runtime every Hive program is compiled against. It is
// generated: what is here is what the program referenced, and a module it
// never reached for was never written.
package hive

import (
	"crypto/subtle"
	"fmt"
	"math"
	"reflect"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// Table is a vector of rows of cells — what a CSV, a raw query and a map
// all arrive as.
type Table = [][]string

// FileTableError is what a table that could not be read answers with. A file
// that opened and then turned out not to hold what it said it did is not a
// filesystem failure, which is why hive.file keeps this apart from FileError.
type FileTableError struct {
	Path    string
	Message string
}

func (e FileTableError) Error() string {
	return "hive: table error for " + e.Path + ": " + e.Message
}

// What a module other than hive.ui puts on a program's window, should the
// program open one: markup for the page, and the routes that markup asks for.
// A route is a func(http.ResponseWriter, *http.Request) held as an any, so that
// a program that never opens a window carries no HTTP for it. hive.ui serves
// both; nothing else reads them.
var hivePageScripts []string
var hivePageRoutes = map[string]any{}

// Result is the builtin fallible value: either an Ok payload of type T or
// an Error payload of type E.
type Result[T any, E any] struct {
	ok    bool
	value T
	bad   E
}

func Ok[T any, E any](value T) Result[T, E] { return Result[T, E]{ok: true, value: value} }
func Err[T any, E any](bad E) Result[T, E]  { return Result[T, E]{ok: false, bad: bad} }

func (r Result[T, E]) IsOk() bool    { return r.ok }
func (r Result[T, E]) IsError() bool { return !r.ok }
func (r Result[T, E]) Ok() T         { return r.value }
func (r Result[T, E]) Err() E        { return r.bad }

// Every Error comes before every Ok; two of a kind compare by their
// payloads.
func (r Result[T, E]) lessThan(other any) bool {
	o, ok := other.(Result[T, E])
	if !ok {
		return false
	}
	if r.ok != o.ok {
		return !r.ok
	}
	if r.ok {
		return Less(r.value, o.value)
	}
	return Less(r.bad, o.bad)
}

// String is what echo prints for a Result, which is the payload with a
// word in front of it rather than the struct.
func (r Result[T, E]) String() string {
	if r.ok {
		return "Ok(" + ShowIn(r.value) + ")"
	}
	return "Error(" + ShowIn(r.bad) + ")"
}

// A library failure is reported here as a struct with a Reason, and read by
// the program as the union its module declares; lift is the generated
// function from one to the other.
func LiftBad[T any, E any, F any](r Result[T, E], lift func(E) F) Result[T, F] {
	if r.ok {
		return Ok[T, F](r.value)
	}
	return Err[T, F](lift(r.bad))
}

func LiftEach[T any, E any, F any](rs []Result[T, E], lift func(E) F) []Result[T, F] {
	out := make([]Result[T, F], len(rs))
	for i, r := range rs {
		out[i] = LiftBad(r, lift)
	}
	return out
}

// Atom is an interned symbol. The compiler assigns every distinct atom a small
// integer and registers the table of names here, so an echoed atom can show
// its name. #Nil is the only atom the language provides, and it is always 0.
type Atom int

var atomNames = []string{"Nil"}

// InitAtoms installs the program's atom table (called from generated code).
func InitAtoms(names []string) { atomNames = names }

// String is the atom's name, which is what echo prints.
func (a Atom) String() string {
	if int(a) >= 0 && int(a) < len(atomNames) {
		return atomNames[a]
	}
	return "#" + strconv.Itoa(int(a))
}

// AtomToStr is the Str form of an atom: the decimal digits of its compiled
// value, so "0" + #Nil is "00".
func AtomToStr(a Atom) string { return strconv.Itoa(int(a)) }

// ToStr is a value in its Str form, which is what interpolation splices.
// An Atom renders as its decimal value here, which is the language's
// coercion rule.
func ToStr(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case Atom:
		return AtomToStr(x)
	default:
		return Show(v)
	}
}

// Show renders a value exactly as echo displays it, so an Atom shows its
// NAME rather than the decimal form ToStr produces. A top-level Str is the
// line itself, which is the one place a Str is not quoted.
func Show(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ShowIn(v)
}

// ShowIn is a value as it reads inside another one, where a Str is quoted:
// ["1", "2"] is then a different line from [1, 2] and from ["1 2"].
func ShowIn(v any) string {
	switch x := v.(type) {
	case string:
		return strconv.Quote(x)
	case bool:
		if x {
			return "true"
		}
		return "false"
	case float64:
		return strconv.FormatFloat(x, 'g', -1, 64)
	case float32:
		return strconv.FormatFloat(float64(x), 'g', -1, 32)
	case error:
		return x.Error()
	case fmt.Stringer:
		return x.String()
	}
	return showParts(reflect.ValueOf(v))
}

// A vector's elements or a declared type's fields, one at a time, which is
// what carries the quoting all the way down. Anything with no parts to walk
// is left to Go's own form.
func showParts(rv reflect.Value) string {
	switch rv.Kind() {
	case reflect.Slice, reflect.Array:
		parts := make([]string, 0, rv.Len())
		for i := 0; i < rv.Len(); i++ {
			parts = append(parts, ShowIn(rv.Index(i).Interface()))
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case reflect.Struct:
		parts := make([]string, 0, rv.NumField())
		for i := 0; i < rv.NumField(); i++ {
			if !rv.Type().Field(i).IsExported() {
				return fmt.Sprint(rv.Interface())
			}
			parts = append(parts, ShowIn(rv.Field(i).Interface()))
		}
		return "{" + strings.Join(parts, ", ") + "}"
	case reflect.Pointer, reflect.Interface:
		if !rv.IsNil() {
			return showParts(rv.Elem())
		}
	}
	if !rv.IsValid() {
		return "<nil>"
	}
	return fmt.Sprint(rv.Interface())
}

// Echo writes one line to stdout. Every print in a generated program goes
// through here, which is what lets main.go import one package.
func Echo(v any) { fmt.Println(Show(v)) }

// Assert panics when a runtime assertion fails. Inside a test it is a
// recorded failure instead — see TestAssert.
func Assert(cond bool, text string) {
	if !cond {
		panic("hive: assertion failed: " + text)
	}
}

func AssertCmp(cond bool, text string, left string, right string) {
	if !cond {
		panic("hive: assertion failed: " + text + "\n  left:  " + left + "\n  right: " + right)
	}
}

// What a `Secret` is wherever one is named. Making one is the `secret` module's,
// since only that needs locked memory.
// Secret is text kept where the operating system will not swap it out. Hide is
// the way in and Reveal the only way out.
type Secret struct{ p *[]byte }

func (Secret) String() string { return "<secret>" }

// bytes is what s holds. The caller keeps s alive with runtime.KeepAlive until
// it is done with them, or the cleanup that clears them can run underneath it.
func (s Secret) bytes() []byte {
	if s.p == nil {
		return nil
	}
	return *s.p
}

func Reveal(s Secret) string {
	defer runtime.KeepAlive(s)
	return string(s.bytes())
}

// Bypass is a Secret in ordinary memory: as unprintable as any, but free to be
// swapped out. Cleared all the same once nothing holds it.
func Bypass(text string) Secret { return bypassed([]byte(text)) }

func bypassed(b []byte) Secret {
	s := Secret{p: &b}
	runtime.AddCleanup(s.p, func(b []byte) { clear(b) }, b)
	return s
}

// SecretError is why a Secret could not be made. Reason is "LimitExceeded" or
// "Unsupported".
type SecretError struct {
	Reason  string
	Message string
}

func (e SecretError) Error() string {
	return "hive: secret " + e.Reason + ": " + e.Message
}

// Constant time, so how long == takes says nothing about where two differ.
func (s Secret) equalTo(other any) bool {
	o, ok := other.(Secret)
	defer runtime.KeepAlive(s)
	defer runtime.KeepAlive(o)
	return ok && subtle.ConstantTimeCompare(s.bytes(), o.bytes()) == 1
}

// Concat is the + operator on vectors: a new vector holding a's elements
// followed by b's, so neither side is touched.
func Concat[T any](a, b []T) []T {
	out := make([]T, 0, len(a)+len(b))
	out = append(out, a...)
	return append(out, b...)
}

// Cell is storage two `mut` names share: both hold this pointer, so a write
// through either reaches the other, while rebinding one hands that name a
// cell of its own and leaves the other where it was.
func Cell[T any](v T) *T { return &v }

// CloneVec is a fresh backing array holding the same elements. Hive
// vectors are values but lower to Go slices, so a binding that must stay
// independent of its source is copied rather than aliased.
func CloneVec[T any](s []T) []T {
	if s == nil {
		return nil
	}
	out := make([]T, len(s))
	copy(out, s)
	return out
}

// MapVec is a vector with every element passed through f. It is what the
// boundary with an imported Go file needs when a slice of a mirrored struct
// crosses it: same shape both sides, and this is the copy between them.
func MapVec[T any, K any](s []T, f func(T) K) []K {
	out := make([]K, len(s))
	for i := range s {
		out[i] = f(s[i])
	}
	return out
}

// CloneVecFn is CloneVec for an element type that owns storage of its own —
// a nested vector, or a declared type with a vector field. Every element is
// passed through clone, so the copy shares nothing with the original.
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

// Prepend puts value at the front of the vector the pointer names. It takes
// an address because growing a slice returns a new header and the caller
// has to end up holding that one.
func Prepend[T any](v *[]T, value T) {
	out := make([]T, 0, len(*v)+1)
	out = append(out, value)
	*v = append(out, (*v)...)
}

// Drop removes low through high — inclusive of both, as every bound in Hive
// is — and returns what it removed. Crossed bounds take nothing and hand
// back an empty vector, which is what the equivalent slice would have been.
func Drop[T any](v *[]T, low, high int) []T {
	if low < 0 {
		low = 0
	}
	if high >= len(*v) {
		high = len(*v) - 1
	}
	if low > high {
		return []T{}
	}
	taken := make([]T, high-low+1)
	copy(taken, (*v)[low:high+1])
	*v = append((*v)[:low], (*v)[high+1:]...)
	return taken
}

// InRange is what a bounds guard compiles to: written once rather than as
// two comparisons that repeat half of themselves.
func InRange[T any](i int, v []T) bool { return i >= 0 && i < len(v) }

// And the same guard on a Str, which counts characters rather than the
// bytes that hold them.
func InRangeStr(i int, s string) bool {
	return i >= 0 && i < utf8.RuneCountInString(s)
}

// Bytes is a vector's byte footprint: its length times the size of one
// element.
func Bytes[T any](v []T) int {
	var zero T
	return len(v) * int(reflect.TypeOf(&zero).Elem().Size())
}

// Eq is == on anything that owns storage: structural, all the way down. Two
// vectors are equal when they are the same length and equal element by
// element; a Dict compares its pairs and ignores the order they were set in.
func Eq(a, b any) bool {
	if d, ok := a.(interface{ equalTo(any) bool }); ok {
		return d.equalTo(b)
	}
	return reflect.DeepEqual(a, b)
}

// Kept canonical — empty is the zero value, bits past the end are zero — so
// reflect.DeepEqual compares two by their values.
type Packed[T Whole] struct {
	words []uint64
	n     int
	width uint8
}

func Pack[T Whole](width uint8, values []T) Packed[T] {
	if len(values) == 0 {
		return Packed[T]{}
	}
	p := Packed[T]{words: make([]uint64, (len(values)*int(width)+63)/64), n: len(values), width: width}
	for i, v := range values {
		p.Set(i, v)
	}
	return p
}

func (p Packed[T]) Len() int { return p.n }

func (p Packed[T]) Bytes() int { return len(p.words) * 8 }

func (p Packed[T]) At(i int) T {
	w := uint(p.width)
	bit := uint(i) * w
	k, s := bit>>6, bit&63
	v := p.words[k] >> s
	if s+w > 64 {
		v |= p.words[k+1] << (64 - s)
	}
	v &= 1<<w - 1
	if ^T(0) < 0 {
		return T(int64(v<<(64-w)) >> (64 - w))
	}
	return T(v)
}

func (p Packed[T]) Set(i int, x T) {
	w := uint(p.width)
	mask := uint64(1)<<w - 1
	v := uint64(x) & mask
	bit := uint(i) * w
	k, s := bit>>6, bit&63
	p.words[k] = p.words[k]&^(mask<<s) | v<<s
	if s+w > 64 {
		p.words[k+1] = p.words[k+1]&^(mask>>(64-s)) | v>>(64-s)
	}
}

func (p Packed[T]) Append(width uint8, x T) Packed[T] {
	if p.n == 0 {
		p = Packed[T]{width: width}
	}
	if (p.n+1)*int(p.width) > len(p.words)*64 {
		p.words = append(p.words, 0)
	}
	p.n++
	p.Set(p.n-1, x)
	return p
}

func (p Packed[T]) Unpack() []T {
	out := make([]T, p.n)
	for i := range out {
		out[i] = p.At(i)
	}
	return out
}

func (p Packed[T]) Part(low, high int) Packed[T] {
	if high <= low {
		return Packed[T]{}
	}
	out := Packed[T]{words: make([]uint64, ((high-low)*int(p.width)+63)/64), n: high - low, width: p.width}
	for i := 0; i < out.n; i++ {
		out.Set(i, p.At(low+i))
	}
	return out
}

func (p Packed[T]) From(low int) Packed[T] { return p.Part(low, p.n) }

func (p Packed[T]) All(yield func(int, T) bool) {
	for i := 0; i < p.n; i++ {
		if !yield(i, p.At(i)) {
			return
		}
	}
}

func (p Packed[T]) IndexOf(x T) Result[int, bool] {
	for i := 0; i < p.n; i++ {
		if p.At(i) == x {
			return Ok[int, bool](i)
		}
	}
	return Err[int, bool](false)
}

func (p Packed[T]) String() string {
	parts := make([]string, p.n)
	for i := range parts {
		parts[i] = WholeText(p.At(i))
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

func (p Packed[T]) lessThan(other any) bool {
	o, ok := other.(Packed[T])
	if !ok {
		return false
	}
	for i := 0; i < p.n && i < o.n; i++ {
		if a, b := p.At(i), o.At(i); a != b {
			return a < b
		}
	}
	return p.n < o.n
}

func ClonePacked[T Whole](p Packed[T]) Packed[T] {
	p.words = append([]uint64(nil), p.words...)
	return p
}

func ConcatPacked[T Whole](a, b Packed[T]) Packed[T] {
	out := ClonePacked(a)
	for i := 0; i < b.n; i++ {
		out = out.Append(b.width, b.At(i))
	}
	return out
}

func PrependPacked[T Whole](p *Packed[T], width uint8, x T) {
	*p = Pack(width, append([]T{x}, p.Unpack()...))
}

func DropPacked[T Whole](p *Packed[T], low, high int) Packed[T] {
	values := p.Unpack()
	taken := Drop(&values, low, high)
	width := p.width
	*p = Pack(width, values)
	return Pack(width, taken)
}

func InRangePacked[T Whole](i int, p Packed[T]) bool { return i >= 0 && i < p.n }

func SortPacked[T Whole](p Packed[T]) Packed[T] { return Pack(p.width, Sort(p.Unpack())) }

func SortPackedBy[T Whole](p Packed[T], first func(T, T) bool) Packed[T] {
	return Pack(p.width, SortBy(p.Unpack(), first))
}

func SortPackedInPlace[T Whole](p Packed[T]) {
	for i, v := range Sort(p.Unpack()) {
		p.Set(i, v)
	}
}

func SortPackedInPlaceBy[T Whole](p Packed[T], first func(T, T) bool) {
	for i, v := range SortBy(p.Unpack(), first) {
		p.Set(i, v)
	}
}

func PackResult[T Whole, E any](width uint8, r Result[[]T, E]) Result[Packed[T], E] {
	if r.ok {
		return Ok[Packed[T], E](Pack(width, r.value))
	}
	return Err[Packed[T], E](r.bad)
}

// Only where the vector still reaches that far.
func PutBack[T Whole](p *Packed[T], i int, x T) {
	if i >= 0 && i < p.n {
		p.Set(i, x)
	}
}

// variantOrder is the declaration order of every tagged union's variants,
// registered by the generated code. A union sorts by variant first, and Go's
// reflection cannot know that order — so the compiler says.
var variantOrder = map[string]int{}

// RegisterVariants installs one union's variant order (called from
// generated code).
func RegisterVariants(names []string) {
	for i, n := range names {
		variantOrder[n] = i
	}
}

// Less is the order a type has of its own, which is what sort with one
// argument uses: numeric for numbers, code point order for strings, false
// before true, Error before Ok, lexicographic for vectors, field by field for
// a struct, and by variant first for a union.
func Less(a, b any) bool {
	if o, ok := a.(ordered); ok {
		return o.lessThan(b)
	}
	return lessValue(reflect.ValueOf(a), reflect.ValueOf(b))
}

// A type that knows its own order, which is how a Result gets one: its
// fields are the runtime's business and reflection cannot reach them.
type ordered interface{ lessThan(any) bool }

func lessValue(a, b reflect.Value) bool {
	if !a.IsValid() || !b.IsValid() {
		return false
	}
	if a.CanInterface() && b.CanInterface() {
		if o, ok := a.Interface().(ordered); ok {
			return o.lessThan(b.Interface())
		}
	}
	if a.Kind() == reflect.Interface {
		return lessInterface(a, b)
	}
	if a.Type() != b.Type() {
		return lessVariant(a, b)
	}
	switch a.Kind() {
	case reflect.Bool:
		return !a.Bool() && b.Bool()
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return a.Int() < b.Int()
	case reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return a.Uint() < b.Uint()
	case reflect.Float32, reflect.Float64:
		return a.Float() < b.Float()
	case reflect.String:
		return a.String() < b.String()
	case reflect.Slice, reflect.Array:
		return lessSequence(a, b)
	case reflect.Struct:
		return lessStruct(a, b)
	}
	return false
}

// A union value is an interface holding one variant's struct. Which variant
// it is decides first; two of a kind compare by their fields.
func lessInterface(a, b reflect.Value) bool {
	if a.IsNil() || b.IsNil() {
		return !a.IsNil() && b.IsNil()
	}
	return lessValue(a.Elem(), b.Elem())
}

func lessVariant(a, b reflect.Value) bool {
	li, lok := variantOrder[a.Type().Name()]
	ri, rok := variantOrder[b.Type().Name()]
	if lok && rok {
		return li < ri
	}
	return a.Type().Name() < b.Type().Name()
}

// Lexicographic by element, and on a shared prefix the shorter one first.
func lessSequence(a, b reflect.Value) bool {
	n := a.Len()
	if b.Len() < n {
		n = b.Len()
	}
	for i := 0; i < n; i++ {
		if lessValue(a.Index(i), b.Index(i)) {
			return true
		}
		if lessValue(b.Index(i), a.Index(i)) {
			return false
		}
	}
	return a.Len() < b.Len()
}

// Field by field, in declaration order — the first field they differ on
// decides. A Result is a struct too, and its first field is the ok flag,
// which is what puts every Error before every Ok.
func lessStruct(a, b reflect.Value) bool {
	for i := 0; i < a.NumField(); i++ {
		af, bf := a.Field(i), b.Field(i)
		if !af.CanInterface() {
			continue
		}
		if lessValue(af, bf) {
			return true
		}
		if lessValue(bf, af) {
			return false
		}
	}
	return false
}

// Map is every element, transformed. Same length, same order, one call per
// element on the calling thread.
func Map[T any, K any](values []T, transform func(T) K) []K {
	out := make([]K, len(values))
	for i, v := range values {
		out[i] = transform(v)
	}
	return out
}

// Filter is the elements keep says yes to, in order.
func Filter[T any](values []T, keep func(T) bool) []T {
	out := make([]T, 0, len(values))
	for _, v := range values {
		if keep(v) {
			out = append(out, v)
		}
	}
	return out
}

// FilterMap transforms and selects in one pass: the Ok payloads.
func FilterMap[T any, K any, E any](values []T, transform func(T) Result[K, E]) []K {
	out := make([]K, 0, len(values))
	for _, v := range values {
		if r := transform(v); r.IsOk() {
			out = append(out, r.Ok())
		}
	}
	return out
}

// Sort is the elements in their own type's order, in a new vector. The
// original is never touched — sorting in place would be visible through
// every other name for the same storage.
func Sort[T any](values []T) []T {
	out := CloneVec(values)
	sort.SliceStable(out, func(i, j int) bool { return Less(out[i], out[j]) })
	return out
}

func SortBy[T any](values []T, first func(T, T) bool) []T {
	out := CloneVec(values)
	sort.SliceStable(out, func(i, j int) bool { return first(out[i], out[j]) })
	return out
}

// SortInPlace is a discarded sort on a mut vector: the storage is reordered
// where it lies, with no copy at either end.
func SortInPlace[T any](values []T) {
	sort.SliceStable(values, func(i, j int) bool { return Less(values[i], values[j]) })
}

func SortInPlaceBy[T any](values []T, first func(T, T) bool) {
	sort.SliceStable(values, func(i, j int) bool { return first(values[i], values[j]) })
}

// LenStr counts characters, which is what len means on a Str.
func LenStr(s string) int { return utf8.RuneCountInString(s) }

func Join(v []string, sep string) string { return strings.Join(v, sep) }

// Split on the empty separator divides after every character, which is how
// a program reaches a string's characters at all.
func Split(s, sep string) []string { return strings.Split(s, sep) }

// ReplaceFirst rewrites the first occurrence of from, and ReplaceAll every
// one of them. Both answer with a new string: a Str is a value, so nothing
// is written through.
func ReplaceFirst(s, from, to string) string {
	return strings.Replace(s, from, to, 1)
}

func ReplaceAll(s, from, to string) string {
	return strings.ReplaceAll(s, from, to)
}

// IndexStr is the character at position i, as a one-character string. The
// bounds pass proves i in range before this is ever called, so the empty
// answer is a defence rather than a case a program can reach.
func IndexStr(s string, i int) string {
	n := 0
	for _, r := range s {
		if n == i {
			return string(r)
		}
		n++
	}
	return ""
}

// SliceStr is characters low through high, both inclusive — the same two
// numbers a vector slice takes. Crossed bounds take nothing, exactly as
// the slice they describe does.
func SliceStr(s string, low, high int) string {
	if high < low {
		return ""
	}
	start := -1
	end := len(s)
	n := 0
	for at := range s {
		if n == low {
			start = at
		}
		if n == high+1 {
			end = at
			break
		}
		n++
	}
	if start < 0 {
		return ""
	}
	return s[start:end]
}

// SliceStrFrom is s[low:] counted in characters. It is its own function
// rather than SliceStr with a length written at the call, because writing
// one there would evaluate the subject twice.
func SliceStrFrom(s string, low int) string {
	n := 0
	for at := range s {
		if n == low {
			return s[at:]
		}
		n++
	}
	return ""
}

// IndexOfStr is the position, in characters, of the first occurrence of
// sub. Searching an empty string never succeeds, not even for an empty
// needle: an Ok index always points at something really there.
func IndexOfStr(s, sub string) Result[int, bool] {
	if s == "" {
		return Err[int, bool](false)
	}
	at := strings.Index(s, sub)
	if at < 0 {
		return Err[int, bool](false)
	}
	return Ok[int, bool](utf8.RuneCountInString(s[:at]))
}

// IndexOfVec is the position of the first element equal to value, compared
// the way == compares it — so a vector of vectors matches structurally.
func IndexOfVec[T any](v []T, value T) Result[int, bool] {
	for i := range v {
		if Eq(v[i], value) {
			return Ok[int, bool](i)
		}
	}
	return Err[int, bool](false)
}

// Row is the row whose first cell equals key, else an empty vector.
func Row(t Table, key string) []string {
	for _, row := range t {
		if len(row) > 0 && row[0] == key {
			return row
		}
	}
	return []string{}
}

// Column is the column whose top cell equals key, else an empty vector. A
// row too short to reach the matched column is skipped.
func Column(t Table, key string) []string {
	if len(t) == 0 {
		return []string{}
	}
	at := -1
	for i, cell := range t[0] {
		if cell == key {
			at = i
			break
		}
	}
	if at < 0 {
		return []string{}
	}
	out := []string{}
	for _, row := range t {
		if at < len(row) {
			out = append(out, row[at])
		}
	}
	return out
}

// ToTable cuts a flat vector into rows of at most wide cells. A width
// below one is refused as a literal, so reaching here it was computed.
func ToTable(v []string, wide int) Table {
	out := Table{}
	if wide < 1 {
		return out
	}
	for at := 0; at < len(v); at += wide {
		end := at + wide
		if end > len(v) {
			end = len(v)
		}
		out = append(out, CloneVec(v[at:end]))
	}
	return out
}

// Dividing — or taking a remainder — by zero is a value rather than a crash.
func DivInt(a, b int) int {
	if b == 0 {
		return 0
	}
	return a / b
}

func Unfolded(v float64) float64 { return v }

// Calls rather than Go's operators, so two literals that overflow together
// wrap at run time instead of being refused by Go's constant folding.
func AddInt(a, b int) int { return a + b }

func SubInt(a, b int) int { return a - b }

func MulInt(a, b int) int { return a * b }

func NegInt(a int) int { return -a }

func DivFloat(a, b float64) float64 {
	if b == 0 {
		return 0
	}
	return a / b
}

// The remainder takes the sign of the dividend, which is Go's own rule.
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

// A negative exponent has no integral answer, so it is 0.
func PowInt(a, b int) int {
	if b < 0 {
		return 0
	}
	out := 1
	for ; b > 0; b >>= 1 {
		if b&1 == 1 {
			out *= a
		}
		a *= a
	}
	return out
}

func PowFloat(a, b float64) float64 { return math.Pow(a, b) }

// Calls, like Int's, so two literals that overflow together wrap at run time.
type Whole interface {
	~int | ~int8 | ~int16 | ~int32 | ~int64 | ~uint8 | ~uint16 | ~uint32 | ~uint64
}

type unsignedWhole interface {
	~uint8 | ~uint16 | ~uint32 | ~uint64
}

type signedWhole interface {
	~int | ~int8 | ~int16 | ~int32 | ~int64
}

func Add[T Whole](a, b T) T { return a + b }

func Sub[T Whole](a, b T) T { return a - b }

func Mul[T Whole](a, b T) T { return a * b }

func DivWhole[T Whole](a, b T) T {
	if b == 0 {
		return 0
	}
	return a / b
}

func ModWhole[T Whole](a, b T) T {
	if b == 0 {
		return 0
	}
	return a % b
}

func PowWhole[T Whole](a, b T) T {
	if b < 0 {
		return 0
	}
	var out T = 1
	for ; b > 0; b >>= 1 {
		if b&1 == 1 {
			out *= a
		}
		a *= a
	}
	return out
}

func TrimU[T unsignedWhole](x T, bits uint) T { return x & (T(1)<<bits - 1) }

func TrimS[T signedWhole](x T, spare uint) T { return x << spare >> spare }

func Narrow[T Whole, F Whole](x F) T { return T(x) }

func CheckedU[T unsignedWhole, F Whole](x F, bits uint) Result[T, F] {
	y := TrimU(T(x), bits)
	if x < 0 || F(y) != x {
		return Err[T, F](x)
	}
	return Ok[T, F](y)
}

func CheckedS[T signedWhole, F Whole](x F, spare uint) Result[T, F] {
	y := TrimS(T(x), spare)
	if F(y) != x || (x < 0) != (y < 0) {
		return Err[T, F](x)
	}
	return Ok[T, F](y)
}

func FitsSized[T Whole](n int, signed bool, bits uint) (T, bool) {
	if signed {
		top := 1 << (bits - 1)
		if bits < 64 && (n < -top || n >= top) {
			return 0, false
		}
		return T(n), true
	}
	if n < 0 || bits < 63 && n >= 1<<bits {
		return 0, false
	}
	return T(n), true
}

func LessWhole[A Whole, B Whole](a A, b B) bool {
	if a < 0 || b < 0 {
		return (a < 0 && b >= 0) || (a < 0 && b < 0 && int64(a) < int64(b))
	}
	return uint64(a) < uint64(b)
}

func EqualWhole[A Whole, B Whole](a A, b B) bool {
	if (a < 0) != (b < 0) {
		return false
	}
	if a < 0 {
		return int64(a) == int64(b)
	}
	return uint64(a) == uint64(b)
}

func WholeText[T Whole](x T) string {
	if x < 0 {
		return strconv.FormatInt(int64(x), 10)
	}
	return strconv.FormatUint(uint64(x), 10)
}

func DivFloat32(a, b float32) float32 {
	if b == 0 {
		return 0
	}
	return a / b
}

func ModFloat32(a, b float32) float32 {
	if b == 0 {
		return 0
	}
	return float32(math.Mod(float64(a), float64(b)))
}

func PowFloat32(a, b float32) float32 { return float32(math.Pow(float64(a), float64(b))) }

func Unfolded32(v float32) float32 { return v }

func ToFloat32(v float64) float32 { return float32(v) }

func FitsFloat32(v float64) (float32, bool) {
	f := float32(v)
	return f, !math.IsInf(float64(f), 0) || math.IsInf(v, 0)
}

func FloatText(f float64) string { return strconv.FormatFloat(f, 'g', -1, 64) }

func Float32Text(f float32) string { return strconv.FormatFloat(float64(f), 'g', -1, 32) }

// The checker allows only an unsigned count or a literal one, so no shift
// here is ever by a negative number.
func Shl[T Whole, N Whole](x T, n N) T { return x << n }

func Shr[T Whole, N Whole](x T, n N) T { return x >> n }

// What a binary pattern reads, most significant bit first. A read past the
// end answers 0 and marks the match failed, so a length read off a field
// that was never there cannot reach anything.
type BitReader struct {
	bytes  []byte
	text   string
	isText bool
	isWord bool
	word   uint64
	size   int
	at     int
	failed bool
}

func ReadBytes(b []uint8) BitReader { return BitReader{bytes: b, size: len(b) * 8} }

func ReadText(s string) BitReader { return BitReader{text: s, isText: true, size: len(s) * 8} }

func ReadWord[T Whole](x T, width int) BitReader {
	return BitReader{isWord: true, word: uint64(x) << uint(64-width), size: width}
}

func (r *BitReader) byteAt(i int) uint64 {
	if r.isText {
		return uint64(r.text[i])
	}
	return uint64(r.bytes[i])
}

func (r *BitReader) take(n int) uint64 {
	if n <= 0 {
		return 0
	}
	if r.at+n > r.size {
		r.failed = true
		r.at = r.size
		return 0
	}
	if r.isWord {
		v := (r.word << uint(r.at)) >> uint(64-n)
		r.at += n
		return v
	}
	var v uint64
	for n > 0 {
		off := r.at & 7
		k := 8 - off
		if n < k {
			k = n
		}
		chunk := (r.byteAt(r.at>>3) >> uint(8-off-k)) & (1<<uint(k) - 1)
		v = v<<uint(k) | chunk
		r.at += k
		n -= k
	}
	return v
}

func extended[T Whole](v uint64, n int) T {
	if ^T(0) < 0 && n < 64 {
		s := uint(64 - n)
		return T(int64(v<<s) >> s)
	}
	return T(v)
}

func TakeBits[T Whole](r *BitReader, n int) T { return extended[T](r.take(n), n) }

func TakeBitsLittle[T Whole](r *BitReader, n int) T {
	var v uint64
	for i := 0; i < n/8; i++ {
		v |= r.take(8) << uint(8*i)
	}
	return extended[T](v, n)
}

func (r *BitReader) TakeBytes(n int) []uint8 {
	if n < 0 || r.at+n*8 > r.size {
		r.failed = true
		r.at = r.size
		return []uint8{}
	}
	out := make([]uint8, n)
	for i := range out {
		out[i] = uint8(r.byteAt(r.at/8 + i))
	}
	r.at += n * 8
	return out
}

func (r *BitReader) Expect(text string) {
	got := r.TakeBytes(len(text))
	if string(got) != text {
		r.failed = true
	}
}

func (r *BitReader) RestBytes() []uint8 { return r.TakeBytes((r.size - r.at) / 8) }

func (r *BitReader) RestText() string {
	if r.failed {
		return ""
	}
	out := r.text[r.at/8:]
	r.at = r.size
	return out
}

func (r *BitReader) Failed() bool { return r.failed }

func (r *BitReader) Done() bool { return !r.failed && r.at == r.size }

// What `<<...>>` builds, most significant bit first. The checker has every
// run of bytes start on a byte and the whole come to whole bytes.
type BitWriter struct {
	out []uint8
	acc uint64
	n   int
}

func (w *BitWriter) put(v uint64, width int) {
	for width > 0 {
		k := 8 - w.n
		if width < k {
			k = width
		}
		w.acc = w.acc<<uint(k) | (v>>uint(width-k))&(1<<uint(k)-1)
		w.n += k
		width -= k
		if w.n == 8 {
			w.out = append(w.out, uint8(w.acc))
			w.acc, w.n = 0, 0
		}
	}
}

func PutBits[T Whole](w *BitWriter, x T, width int) { w.put(uint64(x), width) }

func PutBitsLittle[T Whole](w *BitWriter, x T, width int) {
	for i := 0; i < width/8; i++ {
		w.put(uint64(x)>>uint(8*i), 8)
	}
}

func (w *BitWriter) PutBytes(b []uint8) { w.out = append(w.out, b...) }

func (w *BitWriter) PutText(s string) { w.out = append(w.out, s...) }

func (w *BitWriter) Bytes() []uint8 {
	if w.out == nil {
		return []uint8{}
	}
	return w.out
}

// Dict is hive.map.Map: keys paired with values, keeping the order the keys
// were first set in. A Go map iterates randomly, so a program built on one
// would print something different every run; this one prints the same twice.
type Dict[K comparable, V any] struct {
	order []K
	byKey map[K]V
}

func NewDict[K comparable, V any]() Dict[K, V] {
	return Dict[K, V]{order: []K{}, byKey: map[K]V{}}
}

func (d *Dict[K, V]) Set(key K, value V) {
	if d.byKey == nil {
		d.byKey = map[K]V{}
	}
	if _, seen := d.byKey[key]; !seen {
		d.order = append(d.order, key)
	}
	d.byKey[key] = value
}

func (d Dict[K, V]) Get(key K) Result[V, bool] {
	if v, seen := d.byKey[key]; seen {
		return Ok[V, bool](v)
	}
	return Err[V, bool](false)
}

func (d Dict[K, V]) Has(key K) bool {
	_, seen := d.byKey[key]
	return seen
}

func (d *Dict[K, V]) Delete(key K) {
	if _, seen := d.byKey[key]; !seen {
		return
	}
	delete(d.byKey, key)
	for i, k := range d.order {
		if k == key {
			d.order = append(d.order[:i], d.order[i+1:]...)
			break
		}
	}
}

func (d Dict[K, V]) Keys() []K { return CloneVec(d.order) }

func (d Dict[K, V]) Values() []V {
	out := make([]V, 0, len(d.order))
	for _, k := range d.order {
		out = append(out, d.byKey[k])
	}
	return out
}

func (d Dict[K, V]) Len() int { return len(d.order) }

// Clone copies a map's key order and its lookup. A value that owns storage
// of its own is passed through clone, so the copy shares nothing.
func (d Dict[K, V]) Clone(clone func(V) V) Dict[K, V] {
	out := NewDict[K, V]()
	for _, k := range d.order {
		out.Set(k, clone(d.byKey[k]))
	}
	return out
}

// Same is the identity, for a value that owns no storage: Go's own copy
// has already isolated it.
func Same[T any](v T) T { return v }

// A map is what it holds, so == compares the pairs and ignores the order
// they were set in.
func (d Dict[K, V]) equalTo(other any) bool {
	o, ok := other.(Dict[K, V])
	if !ok || len(d.byKey) != len(o.byKey) {
		return false
	}
	for k, v := range d.byKey {
		ov, seen := o.byKey[k]
		if !seen || !Eq(v, ov) {
			return false
		}
	}
	return true
}

func (d Dict[K, V]) String() string {
	parts := make([]string, 0, len(d.order))
	for _, k := range d.order {
		parts = append(parts, ShowIn(k)+": "+ShowIn(d.byKey[k]))
	}
	return "{" + strings.Join(parts, ", ") + "}"
}

// MapFromTable reads a Table's rows as key/value pairs.
func MapFromTable(t Table) Dict[string, string] {
	out := NewDict[string, string]()
	for _, row := range t {
		if len(row) >= 2 {
			out.Set(row[0], row[1])
		}
	}
	return out
}

// MapToTable is one two-cell row per pair, in the map's own order.
func MapToTable(d Dict[string, string]) Table {
	out := Table{}
	for _, k := range d.order {
		out = append(out, []string{k, d.byKey[k]})
	}
	return out
}

// DictToGo is a map on its way into an imported Go function: a fresh Go map, so
// whatever that function does to it cannot reach the Hive value it came from.
// The order is not carried over — a Go map has nowhere to keep one.
func DictToGo[K comparable, V any](d Dict[K, V]) map[K]V {
	out := make(map[K]V, len(d.byKey))
	for key, value := range d.byKey {
		out[key] = value
	}
	return out
}

// DictToGoFn is DictToGo with the values converted on the way, which is what
// a value that is itself a map, a vector or a mirrored struct needs.
func DictToGoFn[K comparable, V any, W any](d Dict[K, V], conv func(V) W) map[K]W {
	out := make(map[K]W, len(d.byKey))
	for key, value := range d.byKey {
		out[key] = conv(value)
	}
	return out
}

// DictFromGo is a Go map on its way back: a fresh Hive map, with its keys put
// in order by the comparison it is handed. A Hive map's order is the order its
// keys were set in and a Go map has none to give, so something has to be
// chosen — sorted is the only choice that gives the same output twice.
func DictFromGo[K comparable, V any](m map[K]V, less func(a, b K) bool) Dict[K, V] {
	out := Dict[K, V]{order: make([]K, 0, len(m)), byKey: make(map[K]V, len(m))}
	for key, value := range m {
		out.order = append(out.order, key)
		out.byKey[key] = value
	}
	sort.SliceStable(out.order, func(i, j int) bool { return less(out.order[i], out.order[j]) })
	return out
}

// DictFromGoFn is DictFromGo with the values converted on the way.
func DictFromGoFn[K comparable, V any, W any](m map[K]W, less func(a, b K) bool, conv func(W) V) Dict[K, V] {
	out := Dict[K, V]{order: make([]K, 0, len(m)), byKey: make(map[K]V, len(m))}
	for key, value := range m {
		out.order = append(out.order, key)
		out.byKey[key] = conv(value)
	}
	sort.SliceStable(out.order, func(i, j int) bool { return less(out.order[i], out.order[j]) })
	return out
}

// Task is a call running on a virtual thread of its own. There is no handle
// type in the language: a name bound to an async call reads as its result,
// and this is what that name compiles to.
type Task struct {
	done  chan struct{}
	value any
	blown any
	once  sync.Once
}

// Spawn starts f on its own goroutine and hands back what to wait on.
func Spawn(f func() any) *Task {
	t := &Task{done: make(chan struct{})}
	go func() {
		defer func() {
			if r := recover(); r != nil {
				t.blown = r
			}
			close(t.done)
		}()
		t.value = f()
	}()
	return t
}

// Await waits for the task and answers with its value. A panic inside the
// call is raised here, at the first read, and reading again is free.
func (t *Task) Await() any {
	<-t.done
	if t.blown != nil {
		panic(t.blown)
	}
	return t.value
}

// AwaitAll is one barrier over every call, resolving in order.
func AwaitAll[T any](tasks []*Task) []T {
	out := make([]T, 0, len(tasks))
	for _, t := range tasks {
		v, _ := t.Await().(T)
		out = append(out, v)
	}
	return out
}

// AwaitAllVoid is the same barrier over calls that answer with nothing:
// both of these, then carry on.
func AwaitAllVoid(tasks []*Task) {
	for _, t := range tasks {
		t.Await()
	}
}

// TimeoutError is what a bounded wait answers with when it runs out of
// patience. The timeout abandons the waiting, not the work: a virtual thread
// cannot be stopped from outside, so the call runs on and its result is
// dropped.
type TaskTimeoutError struct {
	Waited  int
	Message string
}

func AwaitTimeout[T any](t *Task, ms int) Result[T, TaskTimeoutError] {
	select {
	case <-t.done:
		if t.blown != nil {
			panic(t.blown)
		}
		v, _ := t.value.(T)
		return Ok[T, TaskTimeoutError](v)
	case <-time.After(time.Duration(ms) * time.Millisecond):
		return Err[T, TaskTimeoutError](TaskTimeoutError{Waited: ms, Message: "hive: timed out"})
	}
}

// AwaitAllTimeout is the barrier with a deadline across the whole of it:
// one wait for all of them rather than one each, so what it answers is
// either every result or the first sign that there was not time.
func AwaitAllTimeout[T any](tasks []*Task, ms int) Result[[]T, TaskTimeoutError] {
	deadline := time.After(time.Duration(ms) * time.Millisecond)
	out := make([]T, 0, len(tasks))
	for _, t := range tasks {
		select {
		case <-t.done:
			if t.blown != nil {
				panic(t.blown)
			}
			v, _ := t.value.(T)
			out = append(out, v)
		case <-deadline:
			return Err[[]T, TaskTimeoutError](TaskTimeoutError{Waited: ms, Message: "hive: timed out"})
		}
	}
	return Ok[[]T, TaskTimeoutError](out)
}

// TaskSleep parks the calling virtual thread. Only that goroutine waits.
func TaskSleep(ms int) {
	if ms > 0 {
		time.Sleep(time.Duration(ms) * time.Millisecond)
	}
}

// Not an empty select, which Go reports as a deadlock when nothing else can run.
func TaskSleepForever() {
	for {
		time.Sleep(time.Hour)
	}
}

// Open windows: the last to close ends the program, so a returning `main` waits.
var holding struct {
	mu    sync.Mutex
	count int
}

func Hold() {
	holding.mu.Lock()
	holding.count++
	holding.mu.Unlock()
}

func Release() int {
	holding.mu.Lock()
	defer holding.mu.Unlock()
	holding.count--
	return holding.count
}

func MainReturned() {
	holding.mu.Lock()
	held := holding.count > 0
	holding.mu.Unlock()
	if held {
		TaskSleepForever()
	}
}

// The three calls a generated main_test.go makes. An assertion inside a
// test has proved the TEST wrong rather than the program, so it is recorded
// and the rest of the suite still runs.
type T interface {
	Errorf(format string, args ...any)
	Helper()
}

func TestAssert(t T, ok bool, source string) {
	t.Helper()
	if !ok {
		t.Errorf("assert %s", source)
	}
}

func TestAssertCmp(t T, ok bool, source, left, right string) {
	t.Helper()
	if !ok {
		t.Errorf("assert %s\n  left:  %s\n  right: %s", source, left, right)
	}
}

// A panic is this test failing, not the suite ending.
func TestRecover(t T) {
	if r := recover(); r != nil {
		t.Errorf("panicked: %v", r)
	}
}
