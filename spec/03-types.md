# 03 — Types

Every expression has a type known at compile time. There is no dynamic type, no
`Any`, and no reflection: where a type is needed and cannot be worked out, the
program is rejected rather than deferred to run time.

## 3.1 The scalar types

| type | holds | Go |
| --- | --- | --- |
| `Str` | UTF-8 text | `string` |
| `Int` | a 64-bit signed integer | `int` |
| `UInt1` … `UInt64` | an unsigned integer of that many bits | the smallest of `uint8` … `uint64` that holds it |
| `Int1` … `Int63` | a signed integer of that many bits | the smallest of `int8` … `int64` that holds it |
| `Float` | a 64-bit float | `float64` |
| `Float32` | a 32-bit float | `float32` |
| `Bool` | `true` or `false` | `bool` |
| `Atom` | an interned symbol | a small integer |
| `void` | nothing; a return type only | — |

`Int` is exactly Go's `int`, which is 64-bit on every platform Hive targets.
It wraps: arithmetic that would pass its largest or smallest value comes round
from the other ([05](05-expressions.md#57-arithmetic-at-the-edges)). `Int64` is a
second name for `Int`, and `Float64` for `Float`.

### Sized numbers

`UInt4` holds 0 to 15 and `Int4` holds −8 to 7: any width from 1 to 64 bits, for
a program that stores many small numbers and wants each to take only the bits it
needs. A sized integer wraps at its own width, exactly as `Int` wraps at 64: a
`UInt4` at 15 plus one is 0. While a program works with one, it sits in the
smallest Go integer that holds it, and every result is trimmed back to its width.

A vector of them is **packed**: its values sit back to back, each taking only its
own bits, so a million `UInt4`s take half a megabyte and a million `UInt17`s about
two. A width of 8, 16, 32 or 64 is stored as Go stores that integer, with nothing
to pack. Packing changes how a vector is kept and nothing about what it does.

A name like `UInt4` is a builtin type the way `Secret` is: a program that declares
its own `UInt4` has that one under the bare name, and the builtin is still there
as `hive.UInt4`. `UInt64` literals stop at `Int`'s largest value, since a literal
is read as an `Int` before it lands; `UInt64(-1)` is the largest `UInt64`.

`Float32` is a 32-bit float, about seven digits, computed in single precision.
`echo` prints the shortest text that reads back as the same `Float32`, so a
`Float32` of `0.1` prints `0.1`.

`void` is not a value type. It may be written as a return type and nowhere
else: there is no `void` variable, no `void` field, and no `void` element.

### Str

A `Str` is a sequence of **characters**, and `len` counts those. It holds bytes,
so a binary file survives a read/write round trip, but it is addressed as text.

A `Str` is **subscripted by character**, never by byte: `s[0]` is its first
character and `s[1:3]` is characters one through three, both bounds inclusive.
Every one of those is proved in range at compile time, exactly as a vector's is
([10](10-bounds.md#108-a-strs-own-bounds)) — a `Str` carries no declared length,
so an index into one is always guarded or comes from `indexOf`.

Indexing yields a **`Str` of one character**. There is no character type to
answer with, and a one-character `Str` is what `split(s, "")` already hands out.

A `Str` is **never assigned into by position**. `s[0] = "x"` is a compile error:
a `Str` is a value rather than storage — the same as an `Int` — and characters
are not all the same width, so writing one would move every character after it.
Build the new string instead.

```hive
s := "café au lait"
if s bounds 3 { echo s[3] }        // é — the fourth character, not the fourth byte
if indexOf(s, "au") is Result.Ok(at) {
	echo s[at:]                    // "au lait", and no guard needed
}
```

`split(s, "")` still reaches every character at once, and remains the way to walk
a string without indexing it.

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
exhaustive ([07](07-patterns.md#76-exhaustiveness)).

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
`hive.file.csv` yields, what `hive.sql.raw` answers with, and what
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

A field declared **outside any variant** is added to every variant, after the
variant's own fields — `Event.Opened("ada", 3)` is `by` and then `at`:

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

The **call** is what builds one, including for a variant that carries nothing,
so `Shape.Point` on its own is a compile error: it names the variant rather than
a value of it. `Shape.Circle(_)` is the spelling that is a function value
([05](05-expressions.md#54-function-values)).

A union value is narrowed with `is` ([07](07-patterns.md)). There is no other
way to reach a variant's fields: a value typed as the union has only the fields
declared outside every variant, which it reads straight off the value
(`event.at`). A field each variant declares for itself, even under one name in
all of them, still belongs to the variants. Nor is a union value assigned into:
it is built whole, so `event.at = 4` is a compile error.

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
func(Int): Int
proc(hive.net.HttpRequest): hive.net.HttpResponse
proc(mut Str[dyn], Str): void
```

It is usable as a parameter, a return and a variable type.

The `proc`/`func` split is preserved through values: a `func` value **may** be
used where a `proc` is expected, and a `proc` value may **not** fill a `func`
slot.

**A `proc` type may mark a parameter `mut`**, which is a `mut` parameter of the
value ([8.2](08-mutability-and-values.md#82-mut-parameters)); a `func` type may
not, and `func(mut Int)` is a compile error. A `mut` position is part of the type:
`proc(mut Int): void` and `proc(Int): void` are different types, and neither fills
the other's slot.

## 3.6 Maps

`hive.map.Map<K, T>` is the one collection that is not a vector, so it is a
module rather than a literal. See [14](14-stdlib.md#143-hivemap) for the calls.
Three type-level rules:

* A **key is compared and hashed whole**, so it is a `Str`, `Int`, `Float`,
  `Bool` or `Atom` — or a declared type whose every field is one of those, which
  gives a composite key. **Storage cannot be a key**: two vectors can hold equal
  contents and still be different storage, so `Map<Str[dyn], Int>` is a compile
  error.
* `hive.map.new()` says *empty* and nothing about what it holds, so its type
  comes from somewhere that says: a declaration, a `return` whose callable
  declares a map, or an argument to a parameter or field declared as one. Bound
  with `:=`, it takes its type from the **first later use** that says it —
  `hive.map.set(m, "a", 1)`, or handing `m` to a parameter declared as a map — and
  keeps it: a later use that disagrees is a compile error, never a second answer.
  `m := hive.map.new()` with nothing after it that says is a compile error.
* A map is **reached by key, never by position**. `m[0]` is a compile error
  pointing at `hive.map.get`, and `for each` over a map is one too: a turn of the
  loop would have to be handed the key or the value, and the syntax never said
  which.

## 3.7 `mut` types

A `mut T` is identical to `T` at run time; `mut` only says, at compile time, that
the name may be altered. It has no spelling of its own outside a
declaration, a `proc` parameter and a `proc` type's parameter. See
[08](08-mutability-and-values.md).

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
4. `S` is `mut T` and `T` is not `mut` — the callee is handed an immutable
   copy ([08](08-mutability-and-values.md)).

There is **no** implicit numeric conversion, of size or of kind. A `UInt8` does
not become an `Int`, a `Float32` does not become a `Float`, and an `Int` does not
become a `Float`: each is written, as `Int(x)`, `Float(f)` or `hive.conv.itf(n)`
([13](13-builtins.md#number-conversions)). `hive.math.max(0, health)` is a compile
error rather than a surprise. A literal is not converted but **typed where it
lands**: `UInt4 x = 9` holds, and `UInt4 x = 16` is a compile error.

There is **no** subtyping between declared types, and no interface. A variant is
not a type of its own: `Shape.Circle` is a way of building and matching a
`Shape`, not something a parameter can be declared as.

A **declared static length is a promise**, so a `Str[3]` slot only ever takes a
vector of exactly three, wherever the value came from, and a length the compiler
cannot see is rejected ([10](10-bounds.md#103-a-declared-length-is-a-promise)).

## 3.10 `Address`

A [service](14-stdlib.md#1410-hivesyslink) taking messages of type `M`, in this
process or on another machine. It is what
[`spawn` and `at`](13-builtins.md#services-spawn-at-kill) answer with, and it is
**called**: `box(message)` sends to the service and waits for its answer
([09](09-concurrency.md)).

**The type says the protocol.** A message sent to an `Address<M>` is an `M`, and
the answer is an `M` too, since a service answers with one of its own messages —
so `box(Op.Count())` on an `Address<Op>` is a `Result<Op, SyslinkError>`, and a
message of any other type is a compile error. `M` is written wherever an address
is: `Address` on its own says nothing about what the service takes, and is a
compile error.

```hive
proc ask(counter: Address<Op>): void {
	answer := counter(Op.Count())   // Result<Op, hive.syslink.SyslinkError>
	_ := counter("count")           // compile error: an `Address<Op>` takes an Op
}
```

`spawn` reads `M` off the handler it starts. `at` cannot — a name says where a
service is and nothing about what it takes — so what it answers with has to
come from somewhere that says, as `hive.map.new()`'s does: a declaration
(`Address<Op> counter = at(#Counter)`), a `return` whose callable declares an
address, an argument to a parameter or field declared as one, or — bound with
`:=` — the first later use that says it: `counter(Op.Add(1))` makes it an
`Address<Op>`, and it stays one. Whether the
service under that name really takes an `M` is a fact about another program, or
one that has not started yet, so it is checked where the message arrives: a
service handed a message of another type answers `Decode`
([14.10](14-stdlib.md#1410-hivesyslink)).

An address is an ordinary value — stored in a field, passed as a parameter,
carried inside a message — and it has no order, so `sort` refuses one. Two
addresses compare with `==` when they take the same `M`.

A program that declares its own `Address` has that one under the bare name, and
the builtin is still there as `hive.Address<M>`.

## 3.11 `Secret`

A value that must not leak: a password, a key, a token, or a record of them.
`hide(value)` makes a `Secret<T>` of any `T`, and `reveal(secret)` is that `T`
again ([13](13-builtins.md)); nothing else opens one. The library's secrets are
text, so they are `Secret<Str>`.

```hive
type Login {
	user: Str
	pin: Int
}

if hide(Login("ada", 1234)) is Result.Ok(kept) {
	echo reveal(kept).pin
}
```

`T` is plain data: `Str`, `Int`, `Float`, `Bool`, `Atom`, and vectors, maps,
`Result`s and declared types made of them. A function, an address, a library
handle such as `hive.net.WsConnection`, or another `Secret` stands for something
the bytes of a value cannot carry, so a `Secret` of one — or of anything holding
one — is a compile error wherever it is written. So is a bare `Secret`, which
does not say what it holds.

* **It is never shown.** `echo`, `panic` and an interpolation of a `Secret` are
  compile errors, and so are they of anything holding one — a field, an element,
  a variant's payload, a `Result` — wherever it sits. So is `encode`ing or
  decoding one, and sending one in a message, since a `Secret` has no JSON.
* **It is never swapped to disk.** What it holds is written as bytes into memory
  the operating system is told to keep in RAM (`mlock` on Linux and macOS,
  `VirtualLock` on Windows), and cleared once nothing holds the `Secret` any more.
* `==` compares what two secrets hold, byte for byte and in constant time. The
  bytes are canonical — a map's pairs are kept in key order rather than the order
  they were set in, and `-0.0` as `0.0` — so two secrets are equal exactly when
  what they hold is, save that a `NaN` equals itself. `reveal` hands a map back
  in that key order. A `Secret` has no order, so `sort` and `<` refuse one.
* A `Secret<T>` fits where a `Secret<U>` is wanted when a `T` fits where a `U`
  does: a `Secret<Int[3]>` fills a `Secret<Int[dyn]>`.

**Locked memory is finite**, so everything that locks a `Secret` answers a
`Result`: `hide` answers `Result<Secret<T>, SecretError>`, and
`hive.term.readSecret` and `hive.crypto.randomSecret` answer
`Result<Secret<Str>, SecretError>`. A `SecretError` is a union of two variants,
each carrying a `message`:

```hive
type SecretError {
	LimitExceeded   // the locked-memory limit is used up
	Unsupported     // the platform cannot lock memory at all
	message: Str
}
```

A call that already fails in its own way reports it there instead:
`hive.crypto.decrypt` as the `CryptoError` variant of the same name, and
`hive.env.getSecret` as an `EnvironmentError`.

`bypass(value)` makes a `Secret<T>` without locking anything, so it cannot fail.
It is a `Secret` in every other respect — never shown, compared the same way,
accepted wherever one is — but kept in ordinary memory, which the operating
system is free to swap out. It is for a value that was never really secret on
the way in: a literal, which the executable already holds, or a ciphertext that
has to go where a `Secret<Str>` does.

Two library calls bypass the lock the same way: `hive.term.readSecretBypass`
and `hive.crypto.decryptBypass` are `readSecret` and `decrypt` keeping what they
make in ordinary memory, so neither runs into the limit. `readSecretBypass`
answers a plain `Secret<Str>`, and `decryptBypass` fails only as `Malformed` or
`BadSignature` ([14](14-stdlib.md)). They are for a program that would rather
hold a secret in memory that may be swapped out than not hold it at all.

What `reveal` answers with is an ordinary value, and is kept like one. The value
`hide` was handed was ordinary too, so a secret typed into the source or read as
a `Str` was ordinary memory before it was hidden: `hive.term.readSecret`,
`hive.env.getSecret` and `hive.crypto.randomSecret` hand one over without that
([14](14-stdlib.md)). Go's own cryptography keeps what it derives from a key on
its heap while it works.

A program that declares its own `Secret` or `SecretError` has that one under the
bare name, and the builtin is still there as `hive.Secret<T>` or
`hive.SecretError`.
