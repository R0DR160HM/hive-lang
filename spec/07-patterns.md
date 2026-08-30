# 07 — Patterns

`is` checks a value against a pattern. It is an ordinary expression yielding a
`Bool`, so every match is written as a plain `if` / `else if` — there is no
`match` or `case` statement. When it matches, it **narrows** the value and binds
parts of it to fresh names, usable immediately: in the rest of the same
condition after `&&`, and in the branch body.

Four kinds of thing can be matched.

## 7.1 Variant patterns

```hive
value is Type.Variant(a, b)
value is Type.Variant          // a variant that carries nothing
```

Fields are bound **by position**. `_` matches a field without binding it. A
partially-written argument list is not allowed: name every field or none.

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
**name** to bind, or `_` to skip. A trailing `...rest` relaxes the length from an
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
`{year is (\d{4})}` is four digits, not an interpolation of `4`. That is also why
a hole is written in an ordinary `"..."` pattern and never a backtick one — a
backtick string has no holes at all, and one written there would match those
characters literally, which the compiler refuses rather than allows.

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

## 7.5 Exhaustiveness

An else-less `if`/`else if` chain that covers its subject's whole type is a
**terminating path** ([04](04-declarations.md#44-returning-on-every-path)), which
is what lets a total function over a union be written without a dead `else`:

```hive
func describe(shape: Shape): Str {
	if shape is Shape.Circle(r)            { return "circle" }
	else if shape is Shape.Rectangle(w, h) { return "rectangle" }
	else if shape is Shape.Point           { return "a point" }
}
```

The subject's whole type means: every variant of a declared union, or a
`Result`'s `Ok` and `Error`. Every branch of the chain must test the **same**
subject. Vector and string patterns never make a chain exhaustive — no finite set
of them covers every string or every length.

## 7.6 Narrowing and scope

A binding introduced by `is` is:

* **immutable** — it is a new name for part of a value, not storage;
* in scope for the rest of the condition after `&&`, and for the branch body;
* out of scope in an `else` branch, where the pattern did *not* match;
* held to the `Binding` naming rule: `camelCase`, or `_` to throw it away.

Narrowing is per branch. A value typed as a union still has only the fields every
variant shares outside a branch that narrowed it.
