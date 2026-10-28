# 07 — Patterns

`is` checks a value against a pattern. It is an ordinary expression yielding a
`Bool`, written in an `if` — or, for several values at once, as the arms of a
[`switch`](06-statements.md#64-switch) ([7.8](#78-switch)). When it matches, it
**narrows** the value and binds parts of it to fresh names, usable immediately:
in the rest of the same condition after `&&`, and in the branch body.

Five kinds of thing can be matched.

## 7.1 Variant patterns

```hive
value is Type.Variant(a, b)
value is Type.Variant          // a variant that carries nothing
```

Fields are bound **by position**. `_` matches a field without binding it, and a
pattern or a literal in its place matches what it holds ([7.5](#75-patterns-inside-patterns)).
A partially-written argument list is not allowed: name every field or none.

```hive
if shape is Shape.Circle(r) {
	echo r
} else if shape is Shape.Rectangle(w, _) {
	echo w
}
```

An imported type is matched through the name its module is reached by
(`text.Align.Left`). A two-segment path is normally a type and one of its
variants, and is a module and one of its types when the first segment names an
import instead; a three-segment path can only be the module form.

## 7.2 `Result` patterns

```hive
parsed is Result.Ok(value)
parsed is Result.Error(problem)
```

The same rules, on the language's own union. Matching both variants is
exhaustive.

Matching a call inline evaluates it **once**:

```hive
if indexOf(names, "bob") is Result.Ok(i) { ... }
```

## 7.3 Vector patterns

A vector pattern matches **positionally**:

```hive
v is ["a", x]                  // exactly two; first equals "a", second binds
v is ["a", x, ...rest]         // at least two; `rest` binds the leftovers
```

Element positions are a **literal** to match (`"a"`, `3`, `#Atom`, `true`), a
**name** to bind, `_` to skip, or a **pattern** of their own
([7.5](#75-patterns-inside-patterns)). A trailing `...rest` relaxes the length from an
exact count to a lower bound and binds the leftover elements as a vector. Without
one, the pattern matches only a vector of exactly that length.

```hive
if command is ["move", direction, ...steps] {
	echo "move {direction} ({len(steps)} extra)"
} else if command is ["stop"] {
	echo "halt"
} else if command is [single] {
	echo "one-word command: {single}"
}
```

## 7.4 String patterns

A string pattern is a **template**: literal text that must match verbatim, plus
holes that bind the text spanning each one.

```hive
path is "/health"                        // a hole-less pattern: an exact match
path is "/users/{id}/posts/{postId}"     // holes in the middle
path is "/files/{rest}"                  // a trailing hole runs to the end
```

* The template must cover the **whole** string.
* Matching is **non-greedy**, so a hole between two `/` never swallows a `/`.
* A hole with no literal after it runs to the end of the string.
* Holes must be plain **binding names**, and two **open** holes may not sit side
  by side — the split point would be ambiguous. Both are compile errors.

### A hole may say what it takes

`{name}` takes any text. `{name is (regex)}` takes only text matching the regex,
and binds it the same way:

```hive
if line is "{user is (\w+)}@{host is ([\w.]+)}" {
	echo "{user} at {host}"
}

if path is "/api/v{version is (\d+)}/{rest}" {
	echo "version {version}, then {rest}"
}
```

The two are **one construct**, and everything above holds for both: the template
covers the whole string, a hole binds a `Str`, and the bindings are in scope for
the rest of the condition and the branch body. The only difference is what the
hole accepts — so a `{name}` and a `{name is (...)}` may sit side by side, because
the second says for itself where it ends.

**Nothing inside the parentheses is escaped by the string.** A hole is recognised
by that exact shape, so the `\` and the `{` between them belong to the regex:
`{year is (\d{4})}` is four digits, not an interpolation of `4`. A backtick
pattern reads holes the same way. Written as `\{name is (...)}`, though, a hole
is literal text that would match those characters and never the shape, which
the compiler refuses rather than allows.

**The regex is read at compile time**, so a malformed one is a compile error
naming what is wrong with it:

```hive
if s is "{a is (a{2,1})}" { }   // error: `{2,1}` counts down
if s is "{a is ((?=x))}" { }    // error: lookaround is not part of this syntax
```

The syntax is Go's, which is RE2: there is **no backreference and no lookaround**,
because an expression that cannot backtrack is one whose running time is a fact
about the text's length rather than about the pattern. Both are refused by name.

A group inside a hole **groups and does not capture** — the hole is already the
binding, so `(a)(b)` there means "an `a` then a `b`". A named group is a compile
error for the same reason: the hole's own name is what the text binds to.

### One matcher

A template is compiled to a single anchored expression, once, when the program
starts — whichever kind of hole it holds. An open `{name}` is the shortest run of
any text that lets the **whole** template match, so a hole is reconsidered when
what follows it does not fit:

```hive
"(a(b))" is "({inner}))"     // matches; `inner` is "a(b"
```

Two templates that come to the same expression share the one compiled pattern,
and a program that writes no string pattern links no matcher at all.

## 7.5 Patterns inside patterns

A position that binds a name — a variant's field, a vector's element — may hold a
pattern instead, and the whole is still one match:

```hive
if foo() is Result.Ok(Foo.Bar(["foo/{padding}/bar", ...rest])) {
	echo "{padding}, then {len(rest)} more"
}
```

**It is the chain it abbreviates**, and compiles to exactly that:

```hive
if foo() is Result.Ok(result) && result is Foo.Bar(values) && values is [head, ...rest] && head is "foo/{padding}/bar" {
	echo "{padding}, then {len(rest)} more"
}
```

Each part is bound to a name no program can write, and tested once the pattern
around it has matched — an outer part before its own parts, siblings left to
right. So every rule of a chain holds unchanged: the subject is evaluated once,
the bindings are in scope for the rest of the condition and the branch body, and
a `!` cannot negate one.

* A part is a variant, vector or string pattern. A vector's `...rest` is still a
  name, and so is a string pattern's hole.
* A variant's position may also hold a **literal** the field has to equal, as a
  vector's position may: `Result.Ok(3)`, `Pair.Of("bees", n)`.
* **A pattern binds a name once.** Two parts bound to one name would leave the
  first unreachable, so `Pair.Of(a, Result.Ok(a))` is a compile error.
* **A variant pattern matches only its own type**, at any depth:
  `Result.Ok(Foo.Bar)` against a `Result<Str, E>` is a compile error.

## 7.6 Exhaustiveness

An else-less `if`/`else if` chain whose branches take **every value of its
subject** is a **terminating path**
([04](04-declarations.md#44-returning-on-every-path)), which is what lets a total
function over a union be written without a dead `else`:

```hive
func describe(shape: Shape): Str {
	if shape is Shape.Circle(r)            { return "circle" }
	else if shape is Shape.Rectangle(w, h) { return "rectangle" }
	else if shape is Shape.Point           { return "a point" }
}
```

**Coverage follows nesting.** A union is covered by its variants and a `Result`
by `Ok` and `Error`, each as far down as the patterns go:

```hive
func kind(r: Result<Route, Str>): Str {
	if r is Result.Ok(Route.Page([]))               { return "an empty page" }
	else if r is Result.Ok(Route.Page([_, ...more])) { return "a page" }
	else if r is Result.Ok(Route.Missing)            { return "a missing page" }
	else if r is Result.Error(_)                     { return "no page at all" }
}
```

* A **vector** is covered by its lengths: `[]` and `[first, ...rest]` take every
  one. A `Bool` is covered by `true` and `false`.
* **Numbers, atoms and strings have no finite cover.** A literal or a template
  takes some of them and never all — the one exception being a template that is
  a single open hole, `"{text}"`, which takes every string, the empty one
  included.
* A hand-written chain on a pattern's own bindings — `r is Result.Ok(page) && page
  is Route.Missing` — covers what the nested pattern it spells out would, since
  that is what a nested pattern is ([7.5](#75-patterns-inside-patterns)).
* **A branch whose condition goes on past its pattern** —
  `r is Result.Ok(n) && n > 0` — takes only part of what the pattern does, so it
  covers nothing.
* The subject is a variable, or a path of fields and indexes from one (`order`,
  `order.status`, `rows[0]`). A call is not one, because it may answer
  differently each time it is made. Branches may test different subjects, and the
  chain terminates when its branches cover any one of them.

A chain that falls short is reported with a value **no branch takes** — `kind`
without its third branch says:

```
`kind` answers with Str, so every path through it has to return one, and no
branch of the else-less `if` chain it ends with takes `r` when it is
`Result.Ok(Route.Missing)`. Give that a branch of its own, or end the chain with
an `else`
```

## 7.7 Narrowing and scope

A binding introduced by `is` is:

* **immutable** — it is a new name for part of a value, not storage;
* in scope for the rest of the condition after `&&`, and for the branch body —
  a `switch` arm's body, for a position of one;
* out of scope in an `else` branch, or any other arm, where the pattern did *not*
  match;
* held to the `Binding` naming rule: `camelCase`, or `_` to throw it away.

Narrowing is per branch. A value typed as a union still has only the fields every
variant shares outside a branch that narrowed it.

## 7.8 `switch`

A [`switch`](06-statements.md#64-switch)'s arms are held to two rules an `if`
chain is not.

**Every value has an arm.** Coverage is [7.6](#76-exhaustiveness)'s, taken over
all the subjects together: an arm covers the values whose every subject its
positions take, so `Shape.Point, _` covers each fill a point can have, and
`_, Fill.None` each shape without one. Literals count as patterns do — `true`
and `false` cover a `Bool` — and since no finite set of them covers a number,
an atom or a string, a `switch` testing one with literals or templates ends with
`_` for it. A `switch` that falls short is a compile error naming a value **no
arm takes**:

```hive
switch shape, fill {
	Shape.Circle(_), Fill.Solid(_) { ... }
	Shape.Point, _                 { ... }
}
```

```
no arm of this `switch` takes `Shape.Circle(_), Fill.None`. Give that an arm of
its own, or end the `switch` with `_, _`
```

Since a subject is evaluated once, a call is as good a subject as a variable
here, which [7.6](#76-exhaustiveness) cannot say of an `if` chain.

**Every arm can run.** An arm whose every value the arms above it already take
is a compile error — one after `_, _`, a literal written twice, or
`Shape.Circle(_), Fill.None` below `Shape.Circle(_), _`:

```
arm 3 of this `switch` can never run: the arms above it take every value it
would. Take it out, or move it above the arm that takes its values
```

Only what coverage can tell apart is compared, so two string templates with
holes are never found to overlap: the error is never wrong, though it can be
missing.

## 7.9 Binary patterns

`<<...>>` reads its subject's bits in order, most significant first, each field
as many as its type has:

```hive
if packet is <<version: UInt4, ihl: UInt4, _: UInt8, length: UInt16, ...rest>> {
	echo "IPv{version}, {length} bytes"
}

if file is <<0x89, "PNG", 0x0D0A_1A0A: UInt32, size: UInt32, body: UInt8[size], ...more>> {
	...
}
```

| field | matches | binds |
| --- | --- | --- |
| `name: UInt4` | 4 bits | a `UInt4` |
| `name: Int12` | 12 bits, the top one the sign | an `Int12` |
| `name` | one byte | a `UInt8` |
| `0x45`, `0x45: UInt16` | a byte, or 16 bits, equal to that value | nothing |
| `"PNG"` | exactly those bytes | nothing |
| `_: UInt3` | 3 bits, skipped | nothing |
| `body: UInt8[size]` | `size` bytes, `size` read from an earlier field or anything in scope | a `UInt8[dyn]` |
| `...rest` | what is left | the rest, as a `Str` for a `Str` and a `UInt8[dyn]` otherwise |

A multi-byte field is big-endian, the order a network writes; `size: UInt32
little` reads one least significant byte first. `little` is read there and
reserved nowhere.

The subject is a `UInt8[]`, a `Str` — by its bytes, so a `Str` is matched without
a copy — or an integer of any size, whose bits the fields have to take every one
of: `op is <<code: UInt4, reg: UInt4>>` on a `UInt8`. An integer has no rest, no
run of bytes and no string to match.

**The match checks the length**, so a field needs no bounds proof. Without
`...rest` the pattern takes exactly that many bytes; with it, at least that many.

**Alignment is checked at compile time.** Every width is known but a run's, and a
run is whole bytes, so where each field starts within a byte is too. A pattern
over bytes whose fields come to a part of a byte, a run, a string or `...rest`
that starts mid-byte, and a `little` field that is not whole bytes at a byte's
start are each a compile error naming the bits that finish the byte.

A binary pattern is never exhaustive, so a `switch` over one ends with `_`. The
way to build what one reads is [`<<...>>` as a value](05-expressions.md#building-bytes).
