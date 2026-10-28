# 10 — Bounds

A dedicated flow-sensitive pass proves **every index and slice in range at
compile time**, so the generated code can never fail out of bounds. Anything the
pass cannot prove safe is a compile error rather than a runtime crash.

## 10.1 What counts as a proof

An access is safe when one of these holds:

* the vector's length is **statically known** and the index is a literal within
  it — `v[2]` on a `Str[3]` compiles, `v[3]` does not;
* the access sits under a **guard the pass can read**:
  * `if i >= 0 && i < len(v) { v[i] }`,
  * `if v bounds i { v[i] }` — the same guard, spelled shorter,
  * the condition of a counting `for` loop — `for i := 0; i < len(v); i++` — whose
    counter starts at a non-negative literal, steps by one, and is held strictly
    below something by its condition (`i < e`, or that on either side of an
    `&&`). An `Int` wraps past `MAX` ([05](05-expressions.md#57-arithmetic-at-the-edges)),
    so a counter stepping by more, or with nothing above it, could turn negative,
    and proves nothing;
* the index came from **`indexOf`** ([10.5](#105-indexof-returns-an-index-you-can-use));
* the index is a **sized integer** ([3.1](03-types.md#sized-numbers)) and the
  vector's known length is past the top of its type: a `UInt4` indexes any vector
  of 16 or more, and an `Int4` one of 8 or more under an `i >= 0` guard. An
  unsigned index is never negative, so against a `[dyn]` vector only
  `i < len(v)` is left to guard. Wrapping keeps this true after arithmetic: `i + 1`
  on a `UInt4` at 15 is 0. The bound travels with the type — `Int(i)` is an `Int`,
  and proves nothing;
* the index is **masked by a literal**, `i & 15`, against a vector whose known
  length is past it: the result is never negative and never above the mask,
  whatever `i` holds — `buckets[hash & 255]` on a `Str[256]`;
* the access is a **`for each`**, which never indexes.

Any other **computed** index is not provable and must be bound to a variable and guarded:

```hive
echo v[len(v) - 1]           // compile error: the index is a computed expression

last := len(v) - 1
if v bounds last { echo v[last] }   // fine
```

`v bounds i` desugars to `i >= 0 && i < hive.len(v)`. The `len` is written
qualified so the guard means the same thing in a program that declared a `len` of
its own.

## 10.2 A known length survives what cannot lose it

Whole-vector code stays as indexable as the literals it started from:

| operation | length of the result |
| --- | --- |
| `a + b` | the two lengths added — `Str[2] + Str[8]` fills a `Str[10]` |
| `map(v, f)` | `v`'s length, unchanged — a transform changes elements, not how many |
| `sort(v)` / `sort(v, first)` | `v`'s length, unchanged — a comparator moves elements, not how many |
| `filter`, `filterMap` | **unknown**, always |
| `split`, `hive.map.keys`, most library calls | unknown |

They compose, so `map(a, f) + sort(b)` is as long as `a + b`. If **either** side
of a concatenation is unknown the result is unknown — there is no "at least this
many".

`filter` and `filterMap` deliberately claim nothing. What is knowable about them
is a *maximum*, and a maximum can never put an index in range, because a filter
that keeps nothing is always a possibility.

## 10.3 A declared length is a promise

`Str[3]` means three, so **every** value that lands in such a slot has to be a
vector of exactly that many: an initialiser, a later assignment, an argument, a
field of a constructed value, a returned value, a row written into a
`Str[2][2]`. A length the compiler cannot see is rejected too.

```hive
mut Str[3] v = ["a", "b", "c"]
v = ["x", "y", "z"]              // fine — still three
v = ["x"]                        // compile error: `v` is declared `Str[3]`
Str[3] parts = split(line, ",")  // compile error: that length isn't known
```

Because the promise is kept everywhere, it is never lost: `v[2]` stays legal
after the reassignment, and a `Str[3]` parameter can be indexed inside the callee
without a guard, since every call site was checked.

### A promise travels with a callable as a value

Keeping a promise means keeping it at every call site, and a function type spells
the length: `f := takes` is a `proc(Str[3]): void`, and every call through it —
or through a parameter, a field or a vector holding it — is checked exactly as a
direct one is:

```hive
proc takes(v: Str[3]): void { echo v[2] }

f := takes
f(["a", "b", "c"])               // fine
f(["a"])                         // compile error: `f` holds a `Str[3]` taker
```

So it fills only a slot that promises as much. A `proc(Str[]): void` or
`proc(Str[dyn]): void` parameter would be called with a vector of any length,
which `takes` cannot take, so handing it one is a compile error. The other way
round is safe: a callable taking `Str[]` fills a `proc(Str[3]): void` slot, since
three is a length it takes.

## 10.4 An inferred length is weaker

An inferred length is still the vector's length — `mut v := ["a", "b", "c"]` is
rebound only to another three, and never grows, since only a vector declared
`[dyn]` does. What is weaker is what the bounds pass keeps: a proof from an
inferred length survives a write *through* the name and dies the moment the name
is rebound — including in a branch or loop body that may not even run — where a
declared length ([10.3](#103-a-declared-length-is-a-promise)) proves every index
below it for as long as the name exists:

```hive
mut v := ["a", "b", "c"]
v[0] = "x"                        // still three, and still proved
if changed { v = ["x", "y", "z"] }
echo v[2]                         // compile error: v was rebound, so guard it
```

The same applies to a field: replacing it costs whatever had been proven about
the old value, exactly as rebinding a variable does.

```hive
type Box { items: Str[dyn] }

mut b := Box(["a", "b", "c"])
if 2 < len(b.items) {
	b.items = ["one"]
	echo b.items[2]             // compile error: that proof died with the old value
}
```

A `Str[3]` **field** is enforced wherever a value reaches it — including at
construction — and so can be indexed unguarded.

## 10.5 `indexOf` returns an index you can use

`indexOf` is fallible, so it answers with a `Result`. The point of returning a
position rather than a `-1` is that **an `Ok` payload is always a position the
vector — or the string — really has**, and the bounds pass knows it:

```hive
found := indexOf(names, "bob")
if found is Result.Ok(i) {
	echo "{i}: {names[i]}"   // no guard needed
}
```

The proof is tied to the vector that was searched, and only for as long as that
vector means the same thing: an index found in `a` still needs a guard to index
`b`, and rebinding the vector between the search and the use drops it. Matching
the call inline works the same way.

## 10.6 What costs a proof

* **rebinding** the vector (`v = [...]`), including in a branch that may not run;
* **`drop`**, the one builtin that makes a vector shorter — a `v[1]` proven safe
  before a `drop(v, 0, 0)` needs proving again after;
* passing the vector to a **`mut` parameter**, by name or through a function
  value, since the callee may rebind it to a shorter one;
* replacing a **field** that held it.

## 10.7 `drop`'s own bounds

`drop(v, low, high)` removes `low` through `high`, **both inclusive** — the same
two numbers a slice takes — and its bounds are proven exactly as a slice's are.
On a dynamic vector that needs a guard: `if 1 < len(v) { … }` proves the high
bound and, with it, a low bound of `0`, since a length is never negative.

Crossed bounds (`drop(v, 2, 1)`) take nothing and hand back an empty vector — the
same as the slice they describe.

## 10.8 A `Str`'s own bounds

A `Str` is indexed and sliced like a vector ([03](03-types.md#str)) and proved
like one, with a single difference: **a `Str` never has a length the compiler
knows.** There is no `Str[3]` for text — a declared length is a promise about a
vector's elements, and a string's length is a count of characters that only the
value itself carries. So 10.1's first proof never applies to one:

```hive
s := "abc"
echo s[1]                    // compile error, even though `s` is right there
if s bounds 1 { echo s[1] }  // fine
```

That leaves the same two proofs the rest of this chapter describes, and both work
unchanged:

* a **guard** — `if s bounds i`, which counts characters here because `hive.len`
  does;
* an index from **`indexOf`**, whose `Ok` payload is a character position the
  string really has.

```hive
if indexOf(line, "=") is Result.Ok(at) {
	echo line[at:]           // no guard: the search proved it
}
```

A slice's two bounds are proved separately, so a guard that settles one says
nothing about the other, and a **computed** bound is bound to a name and guarded
like any other ([10.1](#101-what-counts-as-a-proof)):

```hive
last := at - 1
if line bounds last { echo line[:last] }
```

Because a `Str` has no length to lose, nothing in [10.6](#106-what-costs-a-proof)
costs one anything but the guard's own scope.
