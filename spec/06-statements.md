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
`hive.map.new()` somewhere to land.

A binding is **immutable** unless it says `mut`. An immutable name may not be
reassigned, may not be written through (`v[i] = …`, `v.f = …`), and may not be
`append`ed to.

A binding whose right-hand side names existing storage may **copy** it; see
[08](08-mutability-and-values.md#84-copy-on-binding).

`_ := expr` throws the value away.

## 6.2 Assignment

```hive
x = expr
v[i] = expr
rec.field = expr
b.items[0] = expr
```

The target must be a `mut` binding, or a path into one. Assigning to a parameter
or to a plain `:=` binding is a compile error.

**Compound assignment** on a mutable number — `+= -= *= /=` — and the steps
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

## 6.4 Loops

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
for each name: T in values { ... }   // the annotation overrides inference
```

`for each` walks a vector, binding each element to an **immutable** `name` whose
type is inferred from the vector. It never indexes, so it needs no bounds proof.
`for each` over a map is a compile error ([03](03-types.md#36-maps)).

**`break`** leaves the innermost enclosing loop and **`continue`** skips to its
next iteration. Either outside a loop is a compile error.

## 6.5 `return`

`return expr` in a non-`void` callable, bare `return` in a `void` one or to
leave a test early. Every non-`void` callable must return on every path
([04](04-declarations.md#44-returning-on-every-path)).

## 6.6 `echo`

`echo value` writes one line to stdout, rendering the value the way `hive.Show`
does: an atom prints its **name**, a vector prints its elements, a map prints its
pairs in its own order, a declared value prints its fields.

`echo` is legal in both a `func` and a `proc`.

## 6.7 `assert`

`assert cond` says: this must hold. What happens when it does not is decided by
**where it is written**:

* in ordinary code, a failed assertion has proved the *program* wrong, so it
  stops;
* inside a `test`, it has proved the *test* wrong, so the failure is recorded and
  the rest of the suite still runs ([16](16-testing.md)).

Its operands are evaluated **exactly once**, whether it holds or not.

## 6.8 `panic`

`panic value` stops the program immediately, showing `value` rendered as a string
exactly the way `echo` displays it — so `panic err` prints the error's message
and an atom prints its name, not its decimal form. Unlike `assert` it always
fires, and it takes any value rather than only a `Bool`.

Because it never returns, a branch or tail ending in `panic` counts as a
terminating path, so `panic "unreachable"` can close off an impossible tail.

The one exception to "stops the program" is inside a
[`hive.syslink`](14-stdlib.md#1410-hivesyslink) service, where a panic kills only
that service and leaves the node running.

## 6.9 `async` as a statement

```hive
async f(x)
```

Runs the call on its own virtual thread and carries on. See
[09](09-concurrency.md).

## 6.10 Expression statements

A call may stand alone as a statement, and its result is discarded. Two builtins
mean something particular in that position:

* a discarded **`sort`** on a `mut` vector sorts it **in place**, and a discarded
  `sort` that cannot is a compile error rather than dead code
  ([13](13-builtins.md#sorting-in-place));
* a discarded **`drop`** is the ordinary way to remove elements you have no
  further use for.

An expression that is not a call and has no effect is not a statement.

## 6.11 Scope

A block introduces a scope. A name declared in one is visible from its
declaration to the end of that block, and shadowing an outer name is allowed:
a local binding shadows a module-level declaration and a builtin alike
([13](13-builtins.md#a-declaration-of-your-own-wins)).

There is no forward reference inside a body: a statement may only name what is
already in scope. Declarations at module level are mutually visible, so two
callables may call each other.
