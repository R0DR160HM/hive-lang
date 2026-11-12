package hive

import (
	"encoding/binary"
	"math"
	"runtime"
	"sort"
)

func SecretPutInt(b *[]byte, n int) { *b = binary.LittleEndian.AppendUint64(*b, uint64(n)) }

func SecretPutFloat(b *[]byte, f float64) {
	if f == 0 {
		f = 0
	}
	SecretPutInt(b, int(math.Float64bits(f)))
}

func SecretPutWhole[T Whole](b *[]byte, x T) { SecretPutInt(b, int(x)) }

func SecretPutFloat32(b *[]byte, f float32) {
	if f == 0 {
		f = 0
	}
	*b = binary.LittleEndian.AppendUint32(*b, math.Float32bits(f))
}

func SecretPutBool(b *[]byte, v bool) {
	if v {
		*b = append(*b, 1)
	} else {
		*b = append(*b, 0)
	}
}

func SecretPutAtom(b *[]byte, a Atom) { SecretPutInt(b, int(a)) }

func SecretPutStr(b *[]byte, s string) {
	SecretPutInt(b, len(s))
	*b = append(*b, s...)
}

func SecretPutVec[T any](b *[]byte, v []T, put func(*[]byte, T)) {
	SecretPutInt(b, len(v))
	for _, e := range v {
		put(b, e)
	}
}

func SecretPutResult[T any, E any](b *[]byte, r Result[T, E], ok func(*[]byte, T), bad func(*[]byte, E)) {
	SecretPutBool(b, r.ok)
	if r.ok {
		ok(b, r.value)
	} else {
		bad(b, r.bad)
	}
}

func SecretPutDict[K comparable, V any](b *[]byte, d Dict[K, V], key func(*[]byte, K), value func(*[]byte, V)) {
	keys := CloneVec(d.order)
	sort.Slice(keys, func(i, j int) bool { return Less(keys[i], keys[j]) })
	SecretPutInt(b, len(keys))
	for _, k := range keys {
		key(b, k)
		value(b, d.byKey[k])
	}
}

type SecretReader struct {
	b  []byte
	at int
}

func SecretTakeInt(r *SecretReader) int {
	n := int(binary.LittleEndian.Uint64(r.b[r.at:]))
	r.at += 8
	return n
}

func SecretTakeFloat(r *SecretReader) float64 { return math.Float64frombits(uint64(SecretTakeInt(r))) }

func SecretTakeWhole[T Whole](r *SecretReader) T { return T(SecretTakeInt(r)) }

func SecretTakeFloat32(r *SecretReader) float32 {
	v := math.Float32frombits(binary.LittleEndian.Uint32(r.b[r.at:]))
	r.at += 4
	return v
}

func SecretTakeBool(r *SecretReader) bool {
	v := r.b[r.at] == 1
	r.at++
	return v
}

func SecretTakeAtom(r *SecretReader) Atom { return Atom(SecretTakeInt(r)) }

func SecretTakeStr(r *SecretReader) string {
	n := SecretTakeInt(r)
	s := string(r.b[r.at : r.at+n])
	r.at += n
	return s
}

func SecretTakeVec[T any](r *SecretReader, take func(*SecretReader) T) []T {
	n := SecretTakeInt(r)
	out := make([]T, 0, n)
	for ; n > 0; n-- {
		out = append(out, take(r))
	}
	return out
}

func SecretTakeResult[T any, E any](r *SecretReader, ok func(*SecretReader) T, bad func(*SecretReader) E) Result[T, E] {
	if SecretTakeBool(r) {
		return Ok[T, E](ok(r))
	}
	return Err[T, E](bad(r))
}

func SecretTakeDict[K comparable, V any](r *SecretReader, key func(*SecretReader) K, value func(*SecretReader) V) Dict[K, V] {
	out := NewDict[K, V]()
	for n := SecretTakeInt(r); n > 0; n-- {
		k := key(r)
		out.Set(k, value(r))
	}
	return out
}

func BypassWith[T any](x T, put func(*[]byte, T)) Secret {
	var b []byte
	put(&b, x)
	return bypassed(b)
}

func RevealWith[T any](s Secret, take func(*SecretReader) T) T {
	defer runtime.KeepAlive(s)
	return take(&SecretReader{b: s.bytes()})
}
