# 08 — Mutability and value semantics

## 8.1 `mut`

Variables are immutable by default. Prefixing a declaration with `mut` allows
reassignment, writing through (`v[0] = …`, `rec.f = …`) and `append`.

Conceptually a `mut T` is a **`Mutex<T>`**: identical to `T` at run time, but
only mutexes may be altered at compile time.

A parameter or return of type `T` accepts a `Mutex<T>` — the callee just sees an
immutable `T` — never the reverse. So assigning to a parameter, or to a plain
`:=` binding, is a compile error.

A mutex passed into such a parameter is **copied** on the way in, so the callee's
immutable view really is one: it cannot see the caller's later writes, whether
the two run in sequence or, for an `async` call, at the same time.

`mut` may not appear anywhere else a type can: not on a field, not on a return,
not in a `proc(...)` type. Each of those binds nothing.

A `mut` variable may not be named `UPPER_CASE`
([01](01-lexical.md#14-names-have-shapes)).

## 8.2 Mutex parameters

A **`proc` — and only a `proc`** — may ask for the mutex itself:

```hive
proc grow(vec: mut Str[dyn], tag: Str): void {
	append(vec, tag)
}
```

The argument then has to be a `mut` variable, or a path into one, and what the
callee gets is **that storage** rather than a view of it: it may reassign it,
write its elements and `append` to it, and every one of those is visible through
the caller's name afterwards.

**Whether it shares depends on the call site, not the declaration:**

```hive
mut Str[dyn] v = ["a"]
grow(v, "b")          // waited for: v is now ["a", "b"]
async grow(v, "c")    // fired off: the thread grows a copy; v is untouched
```

A call you wait for *there* hands over the caller's storage; an `async` or
`await`ed one hands over a copy. A thread of its own gets storage of its own,
which is what keeps a call running alongside the caller from racing it. Whether
the call's result is kept makes no difference: `n := async count(v)` gets storage
of its own too. What decides is the thread, not the name.

A callable with a mutex parameter can be neither referenced (`f`) nor partially
applied (`f(1, _)`): a function value has no call site to take a mutex from.

One consequence for the [bounds pass](10-bounds.md): a callee holding a mutex may
rebind the vector to a shorter one, so passing a variable to a `mut` parameter
costs it every length and index fact already proved about it.

## 8.3 What a value is

Vectors, `Table`s, [maps](14-stdlib.md#143-hivemap) and declared types that
contain them are **value types**. Two names for one value never observe each
other's mutations — unless both of them are `mut`, which is how shared mutable
state is opted into.

Only in-place writes can break that, and the compiler already enforces that only
`mut` bindings can be written through. So the invariant to preserve is:

> **Storage that an immutable binding observes is never mutated in place
> afterwards.**

## 8.4 Copy-on-binding

A binding whose right-hand side **names existing storage** (`ys := xs`,
`ys := xs[i]`, `ys := rec.field`, …) may need to copy. A **fresh** right-hand
side — a literal, a `+` concatenation, a function result — is already independent
and is never copied.

Each binding is classified by the mutability of its two ends:

| target ⟵ source | decision |
| --- | --- |
| immutable ⟵ immutable | **alias** — neither side can ever mutate the shared storage |
| `mut` ⟵ `mut` | **alias** — shared mutable state is the intent |
| `mut` ⟵ immutable | **alias** if the target is never written through, else **copy** |
| immutable ⟵ `mut` | **alias** if the source is never mutated again, else **copy** |

An alias is only chosen when it is provably indistinguishable from a copy. The
analysis is deliberately **conservative**: if the variable escapes into a
function call or a constructed value, where a returned or embedded slice might
alias its backing array, it is treated as possibly-mutated and the binding
copies.

An in-place `sort` counts as a write, so it forces the copy too:

```hive
mut Int[dyn] a = [3, 1, 2]
b := a          // copies, because...
sort(a)         // ...this rewrites `a`, and `b` must not follow
```

### Two `mut` bindings share completely

```hive
mut Str[dyn] a = ["x", "y", "z"]
mut Str[dyn] b = a
append(b, "w")            // len(a) is now 4
a[0] = "changed"          // b[0] is "changed" too
b = ["replaced"]          // rebinding one rebinds both; len(a) is 1
```

Two independent variables could not deliver that: `append` produces a new slice
header, so growing one name would quietly stop the two from sharing depending on
spare capacity. So the second name is **not given a variable at all** — it
compiles to the first, and there is one header for both.

The one case this does not cover is a source that does not name the same storage
every time it is read: `mut b = a[i]` can be a different element each time `i`
moves, so that binding keeps a header of its own.

## 8.5 What a copy copies

A copy is **deep and type-directed** — chosen by the static type, with no runtime
reflection:

* a flat vector copies its backing array;
* a nested vector or `Table` copies every level;
* a map copies its key order and its lookup, and its values too when they own
  storage of their own;
* a declared type copies its storage-owning fields through a generated clone.
  Scalar-only types need nothing — a value copy already isolates them.

## 8.6 Where a copy is not enough

A **`mut T` parameter** is the one place storage crosses a call boundary on
purpose, and it lowers to a pointer, because a shared backing array would not
survive `append` — that produces a new header and the caller has to see it.

For an `async` call the copy has to be made on the **caller's** side of the
fence, so the argument is bound to a temporary first and the callee is handed
that. The same applies to a call inside `await [...]`, and to a mutex call
nested in a spawned call's arguments — that one is hoisted out and run in the
caller, since running it on the new thread would be the very race the copy exists
to prevent.
