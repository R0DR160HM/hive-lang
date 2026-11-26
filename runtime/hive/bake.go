//go:build hivebake

// The run a build makes before the program's own: each `with compiler` call, its
// answer written down as the Go that builds it again. Only that run is compiled
// with this file, so no program carries it.

package hive

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Baker is the Go source of one answer, written a piece at a time.
type Baker struct{ strings.Builder }

func (b *Baker) W(s string) { b.WriteString(s) }

func BakeStr(b *Baker, v string) { b.WriteString(strconv.Quote(v)) }

func BakeInt(b *Baker, v int) { b.WriteString(strconv.Itoa(v)) }

func BakeBool(b *Baker, v bool) { b.WriteString(strconv.FormatBool(v)) }

// The atom table the run had is the program's own, so the number is the same.
func BakeAtom(b *Baker, v Atom) { b.WriteString("hive.Atom(" + strconv.Itoa(int(v)) + ")") }

func BakeWhole[T Whole](b *Baker, goType string, v T) {
	fmt.Fprintf(b, "%s(%d)", goType, v)
}

// A float is written exactly, which its shortest decimal is; one with no decimal
// at all is written as its bits.
func BakeFloat(b *Baker, v float64) {
	if math.IsInf(v, 0) || math.IsNaN(v) || (v == 0 && math.Signbit(v)) {
		fmt.Fprintf(b, "hive.FloatBits(0x%x)", math.Float64bits(v))
		return
	}
	b.WriteString("float64(" + strconv.FormatFloat(v, 'g', -1, 64) + ")")
}

func BakeFloat32(b *Baker, v float32) {
	w := float64(v)
	if math.IsInf(w, 0) || math.IsNaN(w) || (w == 0 && math.Signbit(w)) {
		fmt.Fprintf(b, "hive.Float32Bits(0x%x)", math.Float32bits(v))
		return
	}
	b.WriteString("float32(" + strconv.FormatFloat(w, 'g', -1, 32) + ")")
}

func BakeVec[T any](b *Baker, goType string, v []T, each func(*Baker, T)) {
	b.WriteString(goType + "{")
	for i, x := range v {
		if i > 0 {
			b.WriteString(", ")
		}
		each(b, x)
	}
	b.WriteString("}")
}

func BakePacked[T Whole](b *Baker, goElement string, width int, v Packed[T], each func(*Baker, T)) {
	b.WriteString("hive.Pack[" + goElement + "](" + strconv.Itoa(width) + ", ")
	BakeVec(b, "[]"+goElement, v.Unpack(), each)
	b.WriteString(")")
}

func BakeResult[T any, E any](b *Baker, goOk string, goBad string, v Result[T, E], ok func(*Baker, T), bad func(*Baker, E)) {
	if v.ok {
		b.WriteString("hive.Ok[" + goOk + ", " + goBad + "](")
		ok(b, v.value)
	} else {
		b.WriteString("hive.Err[" + goOk + ", " + goBad + "](")
		bad(b, v.bad)
	}
	b.WriteString(")")
}

func BakeDict[K comparable, V any](b *Baker, goKey string, goValue string, v Dict[K, V], key func(*Baker, K), value func(*Baker, V)) {
	b.WriteString("hive.DictOf(")
	BakeVec(b, "[]"+goKey, v.order, key)
	b.WriteString(", ")
	values := make([]V, len(v.order))
	for i, k := range v.order {
		values[i] = v.byKey[k]
	}
	BakeVec(b, "[]"+goValue, values, value)
	b.WriteString(")")
}

// BakeSite runs one call. What it prints goes to a file of its own, so the build
// can say which call printed it; its answer, or why there is none, to another.
func BakeSite(index int, run func(*Baker)) {
	dir := os.Getenv("HIVE_BAKE_OUT")
	named := func(kind string) string { return filepath.Join(dir, strconv.Itoa(index)+"."+kind) }
	said, err := os.Create(named("said"))
	if err == nil {
		os.Stdout, os.Stderr = said, said
	}
	b := &Baker{}
	why, panicked := bakeRun(b, run)
	if said != nil {
		said.Close()
	}
	if panicked {
		os.WriteFile(named("panic"), []byte(why), 0o644)
		os.Exit(1)
	}
	if err := os.WriteFile(named("value"), []byte(b.String()), 0o644); err != nil {
		os.Exit(1)
	}
}

func bakeRun(b *Baker, run func(*Baker)) (why string, panicked bool) {
	defer func() {
		if r := recover(); r != nil {
			why, panicked = fmt.Sprint(r), true
		}
	}()
	run(b)
	return "", false
}
