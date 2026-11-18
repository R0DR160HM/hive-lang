// A Go file an `import` can name. Hive is Go behind the curtain, so a Go file
// next to a Hive one can be called from it directly — `import ./lib/measures.go`
// (the `.go` is written, unlike a Hive module's `.hive`, which never is).
//
// Only what Go *exports* is reachable, which is what capitalising a name does
// there. Hive names callables in camelCase, so `Grams` is reached as
// `measures.grams`; a type keeps its PascalCase, so `Weight` is `measures.Weight`.
//
// Every value crossing the boundary is copied — in both directions — so nothing
// in here can hold on to a Hive value or write through one. `Heaviest` below
// sorts the slice it is handed and the caller's vector is untouched.
package measures

import (
	"errors"
	"fmt"
	"sort"
	"strings"
)

// Weight is a struct that crosses the boundary. Every field is exported and of a
// type Hive has a shape for, which is what a struct needs to be readable as a
// Hive type of its own.
type Weight struct {
	Grams int
	Label string
}

// Grams renders a weight the way a scale would. A `string` is a `Str`, an `int`
// is an `Int`: Hive's Int *is* Go's int, so no conversion happens here.
func Grams(w Weight) string {
	if w.Grams >= 1000 {
		return fmt.Sprintf("%s: %.2f kg", w.Label, float64(w.Grams)/1000)
	}
	return fmt.Sprintf("%s: %d g", w.Label, w.Grams)
}

// Heaviest sorts what it is given — in place, which is exactly the kind of thing
// Go code does and Hive's rules forbid. It is safe because the slice it sorted is
// a copy: the caller's vector never moves.
func Heaviest(labels []string, grams []int) []string {
	type pair struct {
		label string
		grams int
	}
	pairs := make([]pair, 0, len(labels))
	for i, label := range labels {
		weight := 0
		if i < len(grams) {
			weight = grams[i]
		}
		pairs = append(pairs, pair{label: label, grams: weight})
	}
	sort.SliceStable(pairs, func(a, b int) bool {
		return pairs[a].grams > pairs[b].grams
	})
	out := make([]string, 0, len(pairs))
	for _, p := range pairs {
		out = append(out, p.label)
	}
	return out
}

// Tally hands back a Go map, which arrives in Hive as a `hive.map.Map<Str, Int>`.
// A Go map has no order of its own, so the pairs come back sorted by key — the
// only choice that gives the same program the same output twice.
func Tally(words []string) map[string]int {
	counts := map[string]int{}
	for _, word := range words {
		counts[strings.ToLower(word)]++
	}
	return counts
}

// Parse reports failure the way Go does, with a second return value. That is
// what a Hive `Result` means, so this arrives as `Result<Int, Str>` — and what
// the error carries is its message.
func Parse(text string) (int, error) {
	total := 0
	for _, field := range strings.Fields(text) {
		var grams int
		if _, err := fmt.Sscanf(field, "%d", &grams); err != nil {
			return 0, errors.New("`" + field + "` is not a number of grams")
		}
		total += grams
	}
	if total == 0 {
		return 0, errors.New("nothing weighed anything")
	}
	return total, nil
}

// unexported is the file's own: Hive cannot see it, and neither can any other Go
// package.
func unexported() string { return "not reachable" }
