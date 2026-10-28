# 06 — Statements

## 6.1 Bindings

Two spellings, and the difference between them is not style:

```hive
x := expr                    // inferred
Str[dyn] v = expr            // annotated
mut x := expr                // inferred, reassignable
mut Str[dyn] v = expr        // annotated, reassignable
```

`:=` infers the type from the value, **including a static vector length**. `=`
with a type in front states it, and is the only way to say `[dyn]`, to say
`Str[3]` as a promise rather than an observation, or to give a
`hive.map.new()` somewhere to land. Only a vector declared `[dyn]` grows: an
inferred length is a length all the same, so `mut v := ["a"]` is rebound only to
another vector of one, and is never `append`ed to.

A binding is **immutable** unless it says `mut`. An immutable name may not be
reassigned, may not be written through (`v[i] = …`, `v.f = …`), and may not be
`append`ed to.

A binding whose right-hand side names existing storage may **copy** it; see
[08](08-mutability-and-values.md#84-copy-on-binding).

`_ := expr` throws the value away, and may be written as often as a block likes.
Every other name is declared **once per block**: declaring it again in the same
block is a compile error — assign to it instead — while an inner block may shadow
it. A parameter belongs to the body's own block.

A call that answers with nothing cannot be bound — `v := log("x")` has nothing
for `v` to hold — and neither can an `async` call to one.

**A statement that is only an expression has to be a call** (or an await-all, or
a call `with timeout`). A value computed and then dropped — `x + 1` on a line of
its own — is a compile error; `_ := x + 1` is how to drop one on purpose.

## 6.2 Assignment

```hive
x = expr
v[i] = expr
rec.field = expr
b.items[0] = expr
```

The target must be a `mut` binding, or a path into one. Assigning to a parameter
or to a plain `:=` binding is a compile error.

**Compound assignment** on a mutable number — `+= -= *= /=`, and on an integer
`&= |= ^= <<= >>=` — and the steps
`++` / `--` are each shorthand for the matching `x = x <op> …`.

## 6.3 `if`

```hive
if cond { ... } else if cond { ... } else { ... }
```

The condition is a `Bool`. An `Atom` is not a condition
([03](03-types.md#atom)); neither is an `Int`, a `Str` or a vector — there is no
truthiness in Hive.

Names bound by an `is` in the condition are in scope in that branch's body, and
in the rest of the same condition after `&&`:

```hive
if x is T.A(v) && v == "ok" { ... }
```

See [07](07-patterns.md).

## 6.4 `switch`

```hive
switch shape, fill {
	Shape.Circle(r), Fill.Solid(color) { ... }
	Shape.Point, _                     { ... }
	_, _                               { ... }
}
```

A `switch` matches one or more values, its **subjects**, against a list of arms.
Each subject is evaluated **exactly once**, left to right, before any arm is
tried. An arm has one **position** per subject, and a position is

* a pattern ([07](07-patterns.md)), which matches as it would after `is`;
* a literal the value has to equal: `0`, `-1`, `2.5`, `#Ready`, `true`; or
* `_`, which takes any value.

The **first** arm whose every position matches runs, and no other. There is no
fall-through, so `break` and `continue` in an arm act on the enclosing loop.

An arm is the `if` its positions spell — `Shape.Point, _ { }` is
`if shape is Shape.Point { }` — so what it binds is in scope in its body and
nowhere else. An arm binds a name **once** across all its positions; two
positions binding one name is a compile error.

A `switch` is **always exhaustive**, and **every arm can run**: an arm for every
value the subjects can take together, and no arm the ones above it already take
all of. Either falling short is a compile error ([7.8](07-patterns.md#78-switch)).
That is what makes a `switch` whose every arm terminates a terminating path
([04](04-declarations.md#44-returning-on-every-path)).

## 6.5 Loops

Two shapes.

**Counting:**

```hive
for i := 0; i < 10; i++ { ... }
for ; cond; { ... }              // any clause may be omitted: a while loop
```

The counter is scoped to the loop and **implicitly mutable**, so it needs no
`mut` — and it is held to the `mut` naming rule, so it may not be `UPPER_CASE`.

Neither the init nor the post clause may be an `async` statement or an `async`
binding: those clauses exist to set up and advance the condition, and work
running on another thread has nothing to advance it with.

**Iterating:**

```hive
for each name in values { ... }
for each name: T in values { ... }   // the annotation states the element type
```

`for each` walks a vector, binding each element to an **immutable** `name` whose
type is inferred from the vector. An annotation says the same thing out loud, and
one the element does not fit is a compile error. It never indexes, so it needs no bounds proof.
`for each` over a map is a compile error ([03](03-types.md#36-maps)).

**`break`** leaves the innermost enclosing loop and **`continue`** skips to its
next iteration. Either outside a loop is a compile error.

## 6.6 `return`

`return expr` in a non-`void` callable, bare `return` in a `void` one or to
leave a test early. Every non-`void` callable must return on every path
([04](04-declarations.md#44-returning-on-every-path)).

## 6.7 `echo`

`echo value` writes one line to stdout, rendering the value the way `hive.Show`
does: an atom prints its **name**, a vector prints its elements, a map prints its
pairs in its own order, a declared value prints its fields.

A `Str` echoed on its own **is** the line, so it is not quoted. Inside any of
those it **is** quoted, which is what tells `["1", "2"]` from `[1, 2]` and from
`["1 2"]`.

`echo` is legal in both a `func` and a `proc`. Echoing a
[`Secret`](03-types.md#311-secret), or anything holding one, is a compile error.

## 6.8 `assert`

`assert cond` says: this must hold. What happens when it does not is decided by
**where it is written**:

* in ordinary code, a failed assertion has proved the *program* wrong, so it
  stops;
* inside a `test`, it has proved the *test* wrong, so the failure is recorded and
  the rest of the suite still runs ([16](16-testing.md)).

Its operands are evaluated **exactly once**, whether it holds or not. Outside a
test, a failed assertion stops the program printing the condition as written —
and for `==` and `!=`, what each side was:

```
panic: hive: assertion failed: total == 10
  left:  9
  right: 10
```

## 6.9 `panic`

`panic value` stops the program immediately, showing `value` rendered as a string
exactly the way `echo` displays it — so `panic err` prints the error's message
and an atom prints its name, not its decimal form. Unlike `assert` it always
fires, and it takes any value rather than only a `Bool` — any but a
[`Secret`](03-types.md#311-secret) or something holding one.

Because it never returns, a branch or tail ending in `panic` counts as a
terminating path, so `panic "unreachable"` can close off an impossible tail.

The one exception to "stops the program" is inside a
[service](14-stdlib.md#1410-hivesyslink), where a panic kills only
that service and leaves the node running.

## 6.10 `async` as a statement

```hive
async f(x)
```

Runs the call on its own virtual thread and carries on. See
[09](09-concurrency.md).

## 6.11 Expression statements

A call may stand alone as a statement, and its result is discarded. Two builtins
mean something particular in that position:

* a discarded **`sort`** on a `mut` vector sorts it **in place**, and a discarded
  `sort` that cannot is a compile error rather than dead code
  ([13](13-builtins.md#sorting-in-place));
* a discarded **`drop`** is the ordinary way to remove elements you have no
  further use for.

An expression that is not a call and has no effect is not a statement.

## 6.12 Scope

A block introduces a scope. A name declared in one is visible from its
declaration to the end of that block, and shadowing an outer name is allowed:
a local binding shadows a module-level declaration and a builtin alike
([13](13-builtins.md#a-declaration-of-your-own-wins)).

There is no forward reference inside a body: a statement may only name what is
already in scope. Declarations at module level are mutually visible, so two
callables may call each other.
