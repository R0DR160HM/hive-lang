# 13 — Builtins

These are always in scope — no import needed. Several are overloaded by argument
type.

| function | signature | what it does |
| --- | --- | --- |
| `len(vector)` | `len(T[]): Int` | number of elements |
| `len(str)` | `len(Str): Int` | number of **characters** (UTF-8 runes) |
| `len(map)` | `len(hive.map.Map<K, T>): Int` | number of pairs |
| `bytes(vector)` | `bytes(T[]): Int` | byte footprint of the contiguous storage |
| `bytes(str)` | `bytes(Str): Int` | number of **bytes** in the UTF-8 encoding |
| `append(vector, value)` | `append(T[dyn], T): void` | grows a **mutable dynamic** vector in place |
| `prepend(vector, value)` | `prepend(T[dyn], T): void` | the same, at the **front** |
| `drop(vector, low, high)` | `drop(T[dyn], Int, Int): T[dyn]` | removes `low`–`high` **inclusive** and hands them back |
| `join(vector, sep)` | `join(Str[], Str): Str` | concatenates, `sep` between elements |
| `split(str, sep)` | `split(Str, Str): Str[dyn]` | splits on `sep` (the inverse of `join`) |
| `replaceFirst(str, from, to)` | `replaceFirst(Str, Str, Str): Str` | the first occurrence of `from`, rewritten |
| `replaceAll(str, from, to)` | `replaceAll(Str, Str, Str): Str` | every occurrence of `from`, rewritten |
| `indexOf(vector, value)` | `indexOf(T[], T): Result<Int, Bool>` | position of the first equal element |
| `indexOf(str, sub)` | `indexOf(Str, Str): Result<Int, Bool>` | position, in characters, of the first occurrence |
| `row(table, key)` | `row(Table, Str): Str[dyn]` | the row whose first cell equals `key`, else `[]` |
| `column(table, key)` | `column(Table, Str): Str[dyn]` | the column whose top cell equals `key`, else `[]` |
| `map(values, transform)` | `map(T[], func(T): K): K[dyn]` | every element, transformed |
| `filter(values, keep)` | `filter(T[], func(T): Bool): T[dyn]` | the elements `keep` says yes to |
| `filterMap(values, transform)` | `filterMap(T[], func(T): Result<K, E>): K[dyn]` | transform and select in one pass |
| `sort(values)` | `sort(T[]): T[dyn]` | in the element type's own order |
| `sort(values, first)` | `sort(T[], func(T, T): Bool): T[dyn]` | in the order `first` gives |

`len` and `bytes` differ only for strings: for `"café"`, `len` is `4` (runes)
while `bytes` is `5`.

`split(s, "")` splits a string into its characters, and a `Str` is also indexed
and sliced by character directly ([03](03-types.md#str)).

`replaceFirst` and `replaceAll` **answer with a new string** and never write
through the one they were given: a `Str` is a value. `from` is plain text rather
than a pattern — to rewrite by shape, match with a
[string pattern](07-patterns.md#74-string-patterns) and build the answer from
what its holes bound. Neither is an error when `from` is not there; the string
comes back as it was.

## A declaration of your own wins

If your program declares a `func`, `proc`, `query` or type named `len`, `map`,
`join` — any of the names above — **that** is what your bare calls mean, with its
own parameters and its own arity. A name you declared quietly reading as somebody
else's function is not a surprise a compiler should spring on you, and it would
make adding a builtin a breaking change for every program that had already used
the word.

The builtin is still there as `hive.<name>`:

```hive
func len(label: Str, extra: Int): Str {   // ours
	return "{label}{extra}"
}

proc main(): void {
	Str[dyn] v = ["a", "b"]
	echo len("x", 2)          // ours: "x2"
	echo hive.len(v)          // the builtin: 2
	echo hive.join(v, "-")    // the long name works whether or not you shadowed
}
```

A **local binding** shadows a builtin the same way, and so does a parameter.
Shadowing is **per module**: another module's declarations are only ever reached
through its alias, so a `map` declared in one file leaves every other file's bare
`map` alone.

Two things follow from the builtin being a distinct thing rather than a fallback.
Only the builtin `append` requires a `mut` target — a declared `append` is an
ordinary callable whose first argument is nothing special. And only the builtin
`indexOf` hands back an index the [bounds pass](10-bounds.md) will accept
unguarded.

Compiler-generated code uses the long name for this reason: `v bounds i`
desugars to `hive.len(v)`.

## Walking a vector: `map`, `filter`, `filterMap`

Each takes a vector and a [function value](05-expressions.md#54-function-values)
over its elements, and hands back a new vector.

The function is a **`func`, never a `proc`**. A walk says nothing about the order
its function runs in or how often, so there is nowhere to hang a side effect —
and that is also what lets a `func` body use one. To walk a vector with a proc,
write a `for each` loop, which does say.

Each is specific about what its function answers with, and a mismatch is a
compile error: `filter` wants a `Bool`, `filterMap` a `Result`, and `map` wants
*something* — a `void` function collects nothing, and that too is a `for each`
loop.

**A walk is sequential.** It calls its function once per element, in order, on
the calling thread. It is never quietly concurrent: nothing in `map(urls, fetch)`
says how `fetch` runs, and a builtin is the last place a program should hide a
decision like that. To run a batch of calls together, write the
[await-all](09-concurrency.md).

`map` is **length-preserving** and the bounds pass knows it; `filter` and
`filterMap` are not ([10](10-bounds.md#102-a-known-length-survives-what-cannot-lose-it)).

## Growing and shrinking: `append`, `prepend`, `drop`

All three write *through* a vector rather than handing back a new one, and all
three ask for a **mutable dynamic** vector (`mut T[dyn]`). Dynamic has to be
declared, because a `mut v := [...]` binding reads its length off the value and a
length read off a value is a static one.

* `prepend` is `append`'s other end and costs what that implies: every element
  moves up one, where `append` costs nothing. It hands nothing back, so it may
  only stand as a statement of its own.
* `drop` removes a **range**, both ends inclusive, and hands back what it
  removed — so it is both a value and a write. It is the one builtin that makes a
  vector **shorter**, so it costs that vector whatever the bounds pass had proved
  about it ([10](10-bounds.md#107-drops-own-bounds)).

## Putting a vector in order: `sort`

`sort` hands back a new vector holding the same elements in order. The original
is never touched — sorting in place would be visible through every other name for
the same storage.

**One argument** orders elements by their own type's order:

| element | order |
| --- | --- |
| `Int`, `Float` | numeric, ascending |
| `Str` | by UTF-8 byte order, which for text is code point order |
| `Bool` | `false` before `true` |
| `Atom` | by its **compiled value** — the small integer the compiler assigned it, which is its identity |
| a vector, a `Table` | lexicographic by element; on a shared prefix the shorter one first |
| `Result<T, E>` | every `Error` before every `Ok`; two of a kind by their payloads |
| a struct | field by field, in declaration order |
| a tagged union | by **variant** first, in declaration order, then by that variant's fields |
| a function value, a service address | none — a compile error, naming the part at fault |

The ordering is chosen by the element's static type and emitted inline, the same
way a deep copy is: no runtime reflection, no boxing, no dispatch.

**Two arguments** order by a `func` of your own, which answers whether its first
element comes before its second. That is also the answer for an element type with
no default order.

The sort is **stable** — elements neither of which comes first keep the order
they arrived in. That is what makes `sort` a function of its input alone even
when the ordering is partial or inconsistent.

Both forms are **length-preserving**.

### Sorting in place

A `sort` written as a **statement** throws away the vector it answers with. When
the vector it was given is `mut`, that is taken at its word: the storage is
reordered where it lies, with no copy at either end.

```hive
mut Str[dyn] names = ["pear", "apple"]

sort(names)                  // in place — `names` is now sorted
sorted := sort(names)        // NOT in place — a new vector, `names` untouched
```

Both conditions do work. **Discarded**, because a `sort` whose value is kept has
to keep answering with a new vector, or `b := sort(a)` would quietly reorder `a`
as well. **`mut`**, because that storage an immutable binding can see is never
rewritten underneath it is the invariant all of
[value semantics](08-mutability-and-values.md) rests on.

A discarded `sort` that *cannot* sort in place is a **compile error**, not a
statement that quietly does nothing:

```hive
Int[dyn] v = [3, 1, 2]
sort(v)                  // compile error: `v` is not `mut`
sort(split(line, ","))   // compile error: nothing to sort in place
```

Both would sort a copy and drop it the instant it was made — dead code wearing
the exact shape of the form that works.

The subject can be any `mut` storage, not only a bare variable: `sort(b.items)`
and `sort(rows[i])` reorder the field and the row.

## `indexOf` returns an index you can use

See [10](10-bounds.md#105-indexof-returns-an-index-you-can-use). On a `Str` the
position counts **characters**, so it lines up with what `len` reports there.
Searching an empty `Str` never succeeds, not even for an empty needle: that keeps
the same promise the vector form makes — an `Ok` index always points at something
that is really there.
