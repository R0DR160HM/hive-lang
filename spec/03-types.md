# 03 — Types

Every expression has a type known at compile time. There is no dynamic type, no
`Any`, and no reflection: where a type is needed and cannot be worked out, the
program is rejected rather than deferred to run time.

## 3.1 The scalar types

| type | holds | Go |
| --- | --- | --- |
| `Str` | UTF-8 text | `string` |
| `Int` | a 64-bit signed integer | `int` |
| `Float` | a 64-bit float | `float64` |
| `Bool` | `true` or `false` | `bool` |
| `Atom` | an interned symbol | a small integer |
| `void` | nothing; a return type only | — |

`Int` is exactly Go's `int`, which is 64-bit on every platform Hive targets.
Its overflow **wraps**, silently and by design
([05](05-expressions.md#57-arithmetic-at-the-edges)).

`void` is not a value type. It may be written as a return type and nowhere
else: there is no `void` variable, no `void` field, and no `void` element.

### Str

A `Str` is a sequence of **characters**, and `len` counts those. It holds bytes,
so a binary file survives a read/write round trip, but it is addressed as text.

A `Str` has **no subscript**. `s[0]` and `s[1:3]` are compile errors, because
`[...]` addresses bytes while a `Str` is a sequence of characters, so the two
never line up and a byte from the middle of a character is not text. Take a
string apart with `split`, find in it with `indexOf`, or match it with a
[string pattern](07-patterns.md#74-string-patterns).

`split(s, "")` is the way to reach individual characters: it answers with a
`Str[dyn]` of one-character strings.

### Atom

An atom is written `#Name` and is interned: the compiler assigns each a small
integer and embeds the atom table in the executable. `echo` prints an atom's
name; coercing one to `Str` yields its decimal value.

**`#Nil` is the only atom the language provides**, and it is always first on the
table, so `"0" + #Nil` is `"00"`. Every other atom exists only because a program
mentioned it, and lands wherever its first mention puts it.

An atom is **not a condition**. It is a label, not a yes or a no, so `if flag` is
a compile error where `flag` is an `Atom`. Compare it with the one you mean —
`if flag == #Ready` — or use a `Bool`.

An atom cannot be computed, which is what lets the compiler know the whole set a
program uses.

## 3.2 `Result<T, E>`

The language's one built-in generic union:

```hive
Result.Ok(value)      // carries a T
Result.Error(payload) // carries an E
```

It is how every fallible operation reports itself. Matching both variants is
exhaustive ([07](07-patterns.md#75-exhaustiveness)).

## 3.3 Vectors

A vector is memory-contiguous and homogeneous. Its type is an element type
followed by one or more dimensions:

| written | means | where it is legal |
| --- | --- | --- |
| `Str[3]` | **static**: exactly three | anywhere |
| `Str[dyn]` | **dynamic**: promises nothing about the length | anywhere |
| `Str[]` | **any length**, of this element type | parameters only |

Which of the three a name holds is what its **declaration** says, never what its
value happened to show.

* `Str[]` is a **parameter** spelling. It promises nothing about the length and
  accepts any vector of the right element type, so one helper serves callers
  holding a `Str[3]` and a `Str[dyn]` alike. That is the whole of where it is
  legal.
* A **return** must say which of the two real kinds it is. A return is where the
  caller is told what it is getting, and the two are different answers: one
  guards every index, the other indexes freely. `Str[]` and `Str[dyn]` would be
  the *same* answer there, which is the reason to keep only one spelling of it.
* What **names storage** — a variable or a field — must likewise say which of the
  two real kinds it is, since a promise is the only thing an index can rest on.

Being *dynamic* is **declared, never inferred**. A `:=` binding reads its length
off the value it was handed, and a length read off a value is a static one:

```hive
mut v := ["a", "b", "c"]
append(v, "d")                   // compile error: `v` is not a dynamic vector

mut Str[dyn] w = ["a", "b", "c"]
append(w, "d")                   // fine
```

That keeps one question answerable by reading a declaration alone: *does this
vector have a length the compiler knows?*

### Operations

* `+` concatenates into a **new** vector, and adds the two lengths.
* `==` and `!=` compare **structurally** — same length, then element by element,
  short-circuiting on the first difference. Nested vectors and `Table`s compare
  the same way. Comparing a vector to a non-vector is a compile error, not a
  silent `false`.
* `v[i]` indexes and `v[lo:hi]` slices, with `hi` **inclusive**. Every one is
  proved in range at compile time ([10](10-bounds.md)).

Vectors are **value types**: binding one to another copies it whenever the two
could otherwise observe each other's writes
([08](08-mutability-and-values.md)).

### Table

`Table` is an alias for `Str[dyn][dyn]` — a vector of rows of cells. It is what
`using` yields from a CSV, what a `run raw` query answers with, and what
`hive.map.toTable` builds.

## 3.4 Declared types

A `type` declaration with **no variants** is a struct; **with variants** it is a
tagged union.

```hive
type User {                 // a struct
	id:   Int
	name: Str
}

type Shape {                // a tagged union
	Circle { radius: Int }
	Rectangle { width: Int, height: Int }
	Point                   // a variant may carry nothing
}
```

A field declared **outside any variant** is added to every variant:

```hive
type Event {
	at: Int                 // every variant has `at`
	Opened { by: Str }
	Closed
}
```

A value is built by calling the type (a struct) or the variant (a union):
`User(1, "ada")`, `Shape.Circle(5)`, `Shape.Point()`. Constructors accept
[named arguments](05-expressions.md#named-arguments).

A union value is narrowed with `is` ([07](07-patterns.md)). There is no other
way to reach a variant's fields: a value typed as the union has only the fields
every variant shares.

**Recursion.** A type may reach back into itself through a variant, which is
what an expression tree needs:

```hive
type Expr {
	Num { value: Int }
	Add { left: Expr, right: Expr }
	Call { callee: Str, args: Expr[dyn] }
}
```

A **struct** may not contain itself directly — it would have no finite size —
but it may contain a union that does.

## 3.5 Function types

A `proc` or `func` is a value. Its type is written like a declaration with the
name dropped:

```hive
func(Int): Int                                  // pure
proc(hive.net.HttpRequest): hive.net.HttpResponse  // impure
```

It is usable as a parameter, a return and a variable type.

The `proc`/`func` split is preserved through values: a `func` value **may** be
used where a `proc` is expected (pure widens to impure), a `proc` value may
**not** fill a `func` slot, and a `func` still cannot *call* a proc value.

`mut` may not appear in a function type. A function value has no call site to
take a mutex from, so a callable with a mutex parameter can be neither
referenced nor partially applied.

## 3.6 Maps

`hive.map.Map<K, T>` is the one collection that is not a vector, so it is a
module rather than a literal. See [14](14-stdlib.md#143-hivemap) for the calls.
Three type-level rules:

* A **key is compared and hashed whole**, so it is a `Str`, `Int`, `Float`,
  `Bool` or `Atom` — or a declared type whose every field is one of those, which
  gives a composite key. **Storage cannot be a key**: two vectors can hold equal
  contents and still be different storage, so `Map<Str[dyn], Int>` is a compile
  error.
* `hive.map.new()` says *empty* and nothing about what it holds, so it must land
  somewhere that says: a declaration, a `return` whose callable declares a map,
  or an argument to a parameter or field declared as one. `m := hive.map.new()`
  is a compile error.
* A map is **reached by key, never by position**. `m[0]` is a compile error
  pointing at `hive.map.get`, and `for each` over a map is one too: a turn of the
  loop would have to be handed the key or the value, and the syntax never said
  which.

## 3.7 Mutex types

Conceptually a `mut T` is a `Mutex<T>`: identical to `T` at run time, but only
mutexes may be altered at compile time. It has no spelling of its own outside a
declaration and a `proc` parameter. See [08](08-mutability-and-values.md).

## 3.8 Type variables

A name in a signature that is neither a builtin nor a declared type is a **type
variable**, and it makes the callable generic in it:

```hive
func first(v: T[]): Result<T, Bool> { ... }
```

A type declaration whose fields mention variables is generic the same way, and is
written out where it is used (`Box<Str>`, `Either<Str, Int>`). Everything about
it is resolved at compile time — see [11](11-generics.md).

## 3.9 Assignability

A value of type `S` may be used where `T` is expected exactly when:

1. `S` and `T` are the same type; or
2. `T` is `T'[]` (a parameter spelling), `S` is `T'[n]` or `T'[dyn]`, and the
   element types match; or
3. `T` is a `proc` function type and `S` is the `func` type with the same
   parameters and return; or
4. `S` is `mut T` and `T` names no mutex — the callee is handed an immutable
   copy ([08](08-mutability-and-values.md)).

There is **no** implicit numeric widening. `Int` does not become `Float`; use
`hive.conv.itf`. `hive.math.max(0, health)` is a compile error rather than a
surprise.

There is **no** subtyping between declared types, and no interface. A variant is
not a type of its own: `Shape.Circle` is a way of building and matching a
`Shape`, not something a parameter can be declared as.

A **declared static length is a promise**, so a `Str[3]` slot only ever takes a
vector of exactly three, wherever the value came from, and a length the compiler
cannot see is rejected ([10](10-bounds.md#103-a-declared-length-is-a-promise)).
