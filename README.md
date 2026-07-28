# Hive

A compiler, written in [Gleam](https://gleam.run), for **Hive** — a
memory-managed, table-based language that compiles to Go. The compiler lowers
Hive source to Go, then invokes the Go toolchain to produce a native
executable for the current platform.

```
hive build <entrypoint.hive>   # compile to a native executable
hive run   <entrypoint.hive>   # compile and run
hive emit  <entrypoint.hive>   # print the generated Go (handy for debugging)
```

## Requirements

The compiler and the programs it produces need:

| Tool            | Purpose                                    | Verified with     |
| --------------- | ------------------------------------------ | ----------------- |
| Gleam           | builds/runs this compiler                  | 1.16              |
| Erlang/OTP      | Gleam's runtime (default target)           | 27 / 28           |
| Go              | compiles the generated code to a binary    | 1.26              |

Go must be on your `PATH` (the compiler shells out to `go build` and
`go env GOEXE`).

## Usage

The CLI is a Gleam program. You can invoke it directly:

```sh
gleam run -- build "code-examples/1 - Basic IO/basic-io.hive"
gleam run -- run   "code-examples/1 - Basic IO/basic-io.hive"
```

or through the thin wrappers at the repo root, which let you pass paths
relative to wherever you happen to be:

```sh
./hive run "code-examples/1 - Basic IO/basic-io.hive"     # bash / macOS / Linux
.\hive.ps1 run "code-examples\1 - Basic IO\basic-io.hive"  # Windows PowerShell
```

To get a global `hive` command, symlink the wrapper into any directory on
your `PATH` (it resolves symlinks back to the repo, so no copying is needed):

```sh
chmod +x hive
ln -s "$(pwd)/hive" ~/.local/bin/hive
```

`hive build foo.hive` writes the executable next to the entrypoint
(`foo.exe` on Windows, `foo` elsewhere) and leaves the intermediate Go project
in `foo.hive-build/` for inspection. `hive run` instead compiles the generated
Go with `go run`, so it produces **no** executable in your project — the binary
lives only in Go's build cache — which avoids Windows Defender/SmartScreen
scanning a freshly written `.exe`. It still runs with the working directory set
to the entrypoint's folder, so relative paths such as `using "./test.csv"`
resolve as the author expects (`hive run` passes that folder through to the
program, which changes into it before `main`). Anything after the entrypoint is
forwarded to the program as its own command-line arguments
(`hive run foo.hive a b c`), readable via `hive.term.args()`.

### Troubleshooting on Windows

If a **built** executable (`hive build`, then `.\foo.exe`) produces **no output
at all** (or crashes with an `Eacces` / "Application Control policy has blocked
this file" error), Windows is very likely blocking the freshly-compiled `.exe`
before it can start — the program never runs, so none of its `echo`s appear.
This is Windows Defender's real-time protection or SmartScreen/Application
Control scanning a brand-new unsigned binary; it is unrelated to the compiled
code (`echo` lowers to Go's `fmt.Println`, which behaves the same on Windows
and Linux). To confirm and work around it:

* Prefer `hive run`, which uses `go run` and never writes an `.exe` into your
  project, so there is no fresh binary for Defender to intercept.
* Add a Windows Defender **exclusion** for your project folder (Settings →
  Privacy & security → Windows Security → Virus & threat protection →
  Manage settings → Exclusions), or build into an already-excluded directory.
* `hive emit foo.hive` prints the generated Go without producing an
  executable, which is handy while a block is being sorted out.

## A taste of Hive

The four kinds of callable — a `func`, a `proc`, an inline SQL `query`, and an
`async func` that runs on its own virtual thread — in one program:

```hive
type Greeting {
	Formal { title: Str }
	Casual
}

// A `func` may perform I/O, but it can't call a `proc` or take a mutex.
func greet(name: Str, style: Greeting): Str {
	if style is Greeting.Formal(title) {
		return "Good evening, {title} {name}."
	}
	return "Hey {name}!"
}

// A `query` is a pure function whose body is inline SQL. Its return type says
// what its ROWS are — one User per row here — so the columns are checked against
// User's fields and the mapper is generated. An interpolated parameter never
// enters the SQL text: it becomes a placeholder, bound alongside.
type User {
	id: Int
	name: Str
}

query findUser(name: Str): User[dyn] {
	SELECT id, name FROM users WHERE name = {name}
}

// A type variable makes a callable generic. Resolved entirely at compile time:
// one copy per element type it is called with.
func first(v: T[]): Result<T, Bool> {
	if len(v) > 0 {
		return Result.Ok(v[0])
	}
	return Result.Error(false)
}

// An `async func` runs on its own virtual thread (a goroutine).
async func slowShout(text: Str): Str {
	return text + "!!!"
}

// A `proc` may perform side effects (echo, using, hive.net, ...).
proc main(): void {
	mut names := ["Ada", "Linus"]
	names[0] = "Grace"

	echo greet("Grace", Greeting.Formal("Dr."))
	echo greet(names[1], Greeting.Casual())

	// `first` is generic: one definition, a concrete copy per element type.
	if first(names) is Result.Ok(who) {
		echo "first up: {who}"
	}

	slowShout("fire-and-forget")     // does not block; the result is discarded
	echo await slowShout("await")    // blocks until the value is ready
}
```

Running it prints:

```
Good evening, Dr. Grace.
Hey Linus!
first up: Grace
await!!!
```

Pattern matching with `is` — beyond the tagged-union variants and `Result`s
above (`x is T.Variant(field)`, `r is Result.Ok(v)`), it also destructures
**vectors** and **strings**, binding parts of the value as it matches:

```hive
proc main(): void {
	// Vectors match positionally; a trailing `...rest` binds the leftovers.
	command := ["move", "north", "10", "20"]
	if command is ["move", direction, ...steps] {
		echo "go " + direction + " (" + hive.conv.its(len(steps)) + " args)"
	}

	// Strings match a template of literal text and `{hole}` captures, including
	// holes in the middle. Matching is non-greedy and covers the whole string.
	path := "/users/7/posts/99"
	if path is "/users/{id}/posts/{postId}" {
		echo "user " + id + ", post " + postId
	} else if path is "/health" {          // a hole-less pattern is exact match
		echo "health check"
	}
}
```

Prints:

```
go north (2 args)
user 7, post 99
```

More complete programs — CSV parsing and a full tour of pattern matching (every
form above), the type system, an HTTP server that speaks JSON, a WebSocket
echo server talking to its own client, a line-oriented raw TCP server doing the
same, a `hive.crypto`
walkthrough (hashing, HMAC, base64 and JWTs), a `hive.sql` example backed by an
embedded SQLite database, a tour of first-class functions and partial
application, a tour of Hive's copy-on-binding [value
semantics](#value-semantics-copy-on-binding), a tour of concurrency
(spawning tasks, holding handles and awaiting one or many), a two-node
[`hive.syslink`](#hivesyslink) program whose services talk to each other across
two terminals or two machines, a three-node distributed cache that combines
`hive.syslink` with `hive.sql` (one owner per key, invalidated across the cluster
on every write), a three-file program
showing `import`, and a walk through spreadsheets and `hive.file` — live in
`code-examples/`. They double as the language's specification: each one
compiles, builds and runs.

## The language

* **`proc` / `func` / `query` / `async func`** — both `proc`s and `func`s may
  perform I/O: `echo`, reading files with `using`, and `hive.net` are all
  allowed in either. A `func` differs from a `proc` in exactly two ways: it
  cannot receive a mutex as a parameter (a `mut` value passed to a func is seen
  as an ordinary immutable copy), and it cannot call a `proc` (only procs call
  procs). A `query` is a func whose body is inline SQL and whose
  return type describes its **rows** — see
  [typed queries](#queries-are-typed-by-their-rows). An interpolated `{param}`
  never enters the SQL text: it becomes a placeholder and the value is bound
  alongside it. An `async func` runs on its own virtual
  thread — see the concurrency bullet below. Programs start at
  `proc main(): void`, in the file you hand to `hive build`/`hive run`.
* **Multiple files** — `import <path>`, written outside any callable, brings
  another `.hive` file's declarations into scope. See
  [`## Multiple files`](#multiple-files) below.
* **Strings** (`Str`) are UTF-8, support `"{expr}"` interpolation, and
  backtick multiline strings whose indentation is removed at compile time. A
  `Str` has no subscript: `s[0]` and `s[1:3]` are compile errors, because
  `[...]` addresses bytes while a `Str` is a sequence of characters (which is
  what `len` counts), so the two never line up and a byte from the middle of a
  character is not text. Take a string apart with `split`, find in it with
  `indexOf`, or match it with a [string pattern](#the-language).
* **Vectors** are memory-contiguous and either static (`Str[3]`) or dynamic
  (`Str[dyn]`). A static length is
  enforced, not advertised: a `Str[3]` slot only ever takes a vector of three,
  wherever the value comes from (see
  [vector bounds](#scope)), which is what lets `v[2]` on one compile with no
  guard. A third spelling, `Str[]`, is legal **only as a parameter**: it
  promises nothing about the length and accepts any vector of the right element
  type, so one helper serves callers holding a `Str[3]` and a `Str[dyn]` alike.
  Anything that names storage — a variable, a field, a return — has to say which
  of the two real kinds it is, since a promise is the only thing an index can
  rest on. All of them lower to Go
  slices; `+` concatenates into a new vector. `==` and `!=` compare vectors
  structurally — same length, then element by element (nested vectors and a
  `Table` compare the same way), short-circuiting on the first difference;
  comparing a vector to a non-vector is a compile error, not a silent `false`.
  Vectors are **value types**: binding one to another (`ys := xs`) copies it, so
  a later mutation of one is never seen through the other. The copy is *deep* and
  *type-directed* — nested vectors, a `Table` and the vector fields of a struct
  are all copied, with no runtime reflection. It is also only emitted when it is
  actually needed: the compiler aliases the storage instead whenever that is
  provably indistinguishable — when both sides are immutable, when a `mut`
  binding is never written through, or when the source is never mutated again —
  and two `mut` bindings always alias, deliberately sharing mutable state.
  `Table` is an alias for `Str[dyn][dyn]`. See
  [Value semantics](#value-semantics-copy-on-binding) for the full rule and a
  runnable tour. (For `append`, `join`, `split`, `indexOf`, `len` and `bytes`
  see [Built-in functions](#built-in-functions).)
* **Mutability** — variables are immutable by default; prefix a declaration
  with `mut` (`mut x := ...`, `mut Str[dyn] v = ...`) to allow reassignment
  (`x = ...`, `v[0] = ...`) and `append`. Conceptually a `mut T` is a
  `Mutex<T>`: identical to `T` at runtime, but only mutexes may be altered at
  compile time. A parameter or return of type `T` accepts a `Mutex<T>` (the
  callee just sees an immutable `T`), never the reverse, so assigning to a
  parameter or a plain `:=` binding is a compile error. A mutex passed as an
  argument is **copied** on the way in, so the callee's immutable view really is
  one: it cannot see the caller's later writes, whether the two run in sequence
  or — for an `async func` — at the same time.
* **Concurrency** — an `async func` runs on its own virtual thread (a
  goroutine). The call site decides how you interact with it, with no Future or
  Promise type to name and nothing dynamically typed. A bare call spawns the
  work; `await` waits for it. As a statement (`f(x)`) the result is discarded —
  fire-and-forget, the caller does not block. Bound (`h := f(x)`) it keeps the
  running task as a *handle*; `await h` then blocks for its value, returning
  instantly if the task already finished. `await f(x)` is the two combined:
  spawn and wait inline. To wait on many tasks at once, `await` a vector of
  handles: `await [f(a), f(b), f(c)]` runs all three concurrently and resolves,
  in order, to a statically-sized vector of their results (`Str[3]`) — one
  barrier, fully typed. Tasks of *different* types are joined the same way:
  spawn each, then `await` each; because they all started first, the total wait
  is the slowest, not the sum. A handle's type (`async T`) is inferred and never
  written: you may bind it and `await` it, but not annotate, return, pass, or
  use it as a plain `T`, so a task can never outlive the scope that spawned it.
  `await` is idempotent — the same handle may be awaited more than once. Any
  `await` may be bounded with the optional
  [`with timeout <ms>`](#hivetask) clause, which turns its result into a
  `Result<T, hive.task.TimeoutError>` — the timeout abandons the waiting, not the
  work. See `code-examples/10 - Concurrency`.
* **Distribution** — [`hive.syslink`](#hivesyslink) adds *services*: long-lived,
  addressable things with a mailbox and private state, reached by the same
  statement whether they live in this process or on another machine.
  `hive.syslink.send(address, message)` is the only way to reach one, and — as
  with an `async func` — the call site decides what it means: as a statement it
  is fire-and-forget, kept it is a request in flight, and `await`ed it yields
  `Result<Message, hive.syslink.SyslinkError>`. A service answers with one of its
  own messages, so the reply type is the mailbox type and nothing needs
  annotating. A *service* is named by an atom, which is what lets the compiler
  know the whole registry; a *node* has no name at all — it is identified by the
  endpoint it can be dialed at, so a peer list is ordinary runtime data. A service
  is not an `async T` — its
  address is an ordinary value that outlives every scope, can be stored, can be
  sent inside a message, and is never awaited. Its handler is a fold over the
  mailbox (`proc (State, Message, hive.syslink.Envelope): State`), so a service
  needs no mutex at all. A service name is an atom, which is what lets the
  compiler know the whole registry — and a named address is the only kind that
  survives its service being restarted. A node has no name: it is identified by
  the endpoint it can be dialed at, so a peer list is ordinary runtime data. A
  `panic` inside a service kills only that service, not the node.
* **Atoms** (`#SomeAtom`) are interned symbols. The compiler assigns each a
  small integer (`#False` = 0 and `#True` = 1 always come first) and embeds
  the atom table in the executable, so `echo` prints an atom's name while
  coercion to `Str` yields its decimal value (`"0" + #True == "01"`). A bare
  atom in boolean position is truthy unless it is `#False`.
* **Booleans** — `Bool` is a real boolean type (Go `bool`); its literals are
  `true` and `false`. It is distinct from the `#True`/`#False` atoms above:
  comparisons and `&&`/`||` produce `Bool`, and a `Bool` field or value holds
  `true`/`false`, not an atom.
* **Numbers** are `Int` or `Float` with `+ - * / % **` (`%` is the remainder
  operator, with the same precedence as `*` and `/`); dividing — or taking a
  remainder — by zero returns 0. A mutable number supports the compound
  assignments `+= -= *= /=` and the `++` / `--` steps (`x += 2`, `i++`), each
  shorthand for the matching `x = x <op> ...`. Prefix `-` negates; it binds
  tighter than `* / %` and looser than `**`, so `-2 ** 2` is `-(2 ** 2)` while
  `2 ** -3` reads the sign as part of the exponent. See
  [Arithmetic at the edges](#arithmetic-at-the-edges) for what overflow, a
  negative exponent, and converting a non-finite `Float` do.
* **Custom types** are Gleam-style ADTs: no variants ⇒ a struct, variants ⇒
  a tagged union. Fields declared outside any variant are added to every
  variant. `is` narrows a value to a variant and can bind its fields, and the
  bindings are usable immediately in the same condition:
  `if x is T.A(v) && v == "ok" { ... }`.
* **Pattern matching** with `is` also destructures vectors and strings, binding
  as it matches. A **vector pattern** matches positionally: `v is ["a", x]`
  requires exactly two elements whose first equals `"a"` and binds the second
  to `x`; a trailing `...rest` (`v is ["a", x, ...rest]`) relaxes the length to
  a lower bound and binds the leftover elements as a vector. Element positions
  are literals to match (`"a"`, `3`, `#Atom`), a name to bind, or `_` to skip.
  A **string pattern** is a template of literal text and `{name}` holes:
  `path is "/api/v1/{id}/{name}/delete"` matches only when the whole string
  fits the template and binds `id` and `name` to the text spanning each hole —
  including holes in the *middle* of the string. Matching is non-greedy, so a
  hole between two `/` never swallows a `/`; a hole with no literal after it
  runs to the end. Holes must be plain binding names and two holes may not sit
  side by side (the split point would be ambiguous) — both are compile errors.
  A hole-less string pattern (`path is "/health"`) is just an exact match.
* **Generics** — a name in a signature that is neither a builtin nor a declared
  type is a **type variable**, and it makes the callable generic in it:
  `func first(v: T[]): Result<T, Bool>`. That is the notation the
  [builtin table](#built-in-functions) has always used for `len`, `indexOf` and
  `append`; it is now available to ordinary code. A type declaration whose
  fields mention variables is generic the same way, and is written out where it
  is used (`Box<Str>`, `Either<Str, Int>`).
  Nothing about it is dynamic: every call site is resolved at compile time, with
  the type arguments read off the argument types, and one concrete copy emitted
  per distinct set of them — no boxing, no dispatch, no reflection. Because each
  copy is an ordinary declaration, every check runs on it separately, so an
  instantiation at `Str[3]` is held to that length while one at `Str[dyn]` guards
  its indexes. A generic callable cannot be used as a *value* (which copy a call
  reaches is decided by the argument types, and a value carries none), and a
  variable that appears only in the return type has nothing to be inferred from;
  both are compile errors. See
  [`code-examples/14 - Generics`](code-examples/14%20-%20Generics/generics.hive).
* **First-class functions** — a proc or func is a value you can pass, store and
  call later. Its type is written like a declaration with the name dropped:
  `func(Int): Int` (pure) or `proc(hive.net.HttpRequest): hive.net.HttpResponse`
  (impure), usable as a parameter, return or variable type. A value is produced
  by a **bare reference** (the callable's name on its own), or by a **partial
  application** — a call with `_` holes, e.g. `handler(_, db)`, which fixes the
  supplied arguments and leaves each `_` as a parameter of the resulting
  function (in order), capturing the rest by value. So
  `hive.net.httpServe(8080, handler(_, db))` adapts a two-argument `handler` into
  the one-argument handler `serve` expects. The `proc`/`func` split is
  preserved through values: a `func` value may be used where a `proc` is
  expected (pure widens to impure), but a `proc` value may not fill a `func`
  slot, and a `func` still cannot *call* a proc value.
* **Loops** come in two shapes. The C-style counting loop
  `for <init>; <cond>; <post> { ... }` runs `init` once, then repeats the body
  while `cond` holds, running `post` after each pass — its counter is scoped to
  the loop and implicitly mutable, so `for i := 0; i < 10; i = i + 1 { ... }`
  needs no `mut`. Any of the three clauses may be omitted
  (`for ; cond; { ... }` is a while loop). The iterating form
  `for each name in values { ... }` walks a vector, binding each element to an
  immutable `name` whose type is inferred from the vector; an optional
  annotation (`for each name: T in values`) overrides that inference. Inside
  either loop, `continue` skips to the next iteration and `break` leaves the
  loop; both act on the innermost enclosing loop, and using them outside a loop
  is a compile error.
* **`assert cond`** panics at runtime when the condition is false.
* **`panic value`** stops the program immediately, showing `value` rendered as
  a string exactly the way `echo` displays it — so `panic err` prints the
  error's message and an atom prints its name (not its decimal form). Unlike
  `assert`, it always fires and takes any value, not just a boolean. The one
  exception is inside a [`hive.syslink`](#hivesyslink) service, where a panic
  kills only that service and leaves the node running. Because it
  never returns, a branch or tail ending in `panic` counts as a terminating
  path (so `panic "unreachable"` can close off an impossible tail, like
  `assert false`).
* **Named arguments** — funcs, procs, queries and type constructors (builtin
  ones included) accept arguments by name: `f(b: 1, "s")`. Named arguments
  can appear anywhere; only the unnamed ones need to be in order, filling
  whichever parameters the named ones didn't claim. Names must exist, can't
  repeat, and once named arguments are used the call must cover the full
  parameter list.
* All keywords are case-insensitive; identifiers keep their spelling.

## Value semantics (copy-on-binding)

Vectors, `Table`s and structs that contain them are **value types**, but they
lower to Go slices, which share their backing storage. To keep the value
semantics honest, a binding whose right-hand side names existing storage
(`ys := xs`, `ys := xs[i]`, `ys := rec.field`, …) may need to **copy** so the
two names can't observe each other's mutations. A fresh right-hand side (a
literal, a `+` concatenation, a function result) is already independent and is
never copied.

Only in-place writes can break value semantics, and the compiler already
enforces that only `mut` variables can be written through (`v[i] = …`,
`v.f = …`, `append(v, …)`). So the invariant to preserve is simply: *storage
that an immutable binding observes is never mutated in place afterwards.* Each
binding is classified by the mutability of its two ends:

| target ⟵ source          | decision                                                             |
| ------------------------- | -------------------------------------------------------------------- |
| immutable ⟵ immutable    | **alias** — neither side can ever mutate the shared storage          |
| `mut` ⟵ `mut`            | **alias** — shared mutable state is the intent                       |
| `mut` ⟵ immutable        | **alias** if the target is never written through, else **copy**      |
| immutable ⟵ `mut`        | **alias** if the source is never mutated again, else **copy**        |

An alias is only chosen when it is provably indistinguishable from a copy. The
analysis is deliberately conservative: if the variable escapes into a function
call or a constructed value (where a returned or embedded slice might alias its
backing array), it is treated as possibly-mutated and the binding copies. Two
`mut` bindings always alias — that is how you opt into shared mutable state.

Shared mutable state is shared **completely**. Every change through either name
is visible through the other, including `append`:

```hive
mut a := ["x", "y", "z"]
mut b := a
append(b, "w")       // len(a) is now 4
a[0] = "changed"     // b[0] is "changed"
b = ["replaced"]     // rebinding one rebinds both; len(a) is 1
```

Two Go slice variables could not deliver that — `append` returns a *new* slice
header, so growing one name would quietly stop the two from sharing, or not,
depending on whether the backing array happened to have spare capacity. So the
second name is not given a variable at all: it compiles to the first, and there
is one slice header for both. The one case this does not cover is a source that
does not name the same storage every time it is read — `mut b = a[i]` can be a
different element each time `i` moves — so that binding keeps a header of its
own.

Passing a mutex to a proc or func is the opposite case and always **copies** (see
[Mutability](#the-language)): the callee is handed an immutable `T`, and it would
not be one if the caller could still write to it.

When a copy *is* made it is **deep and type-directed** — no runtime reflection:

* a flat vector copies its backing array (`hive.CloneVec`);
* a nested vector or `Table` copies every level (`hive.CloneVecFn` /
  `hive.CloneTable`);
* a struct or tagged union copies its storage-owning fields through a generated
  `clone_T` (scalar-only types need nothing — Go's value copy already isolates
  them).

See [`code-examples/6 - Value Semantics`](code-examples/6%20-%20Value%20Semantics/value-semantics.hive)
for a runnable walkthrough of each case.

## Arithmetic at the edges

Most of arithmetic is unsurprising. These are the cases where it is worth saying
exactly what happens, so nothing here is left to chance:

| expression                        | result                                          |
| --------------------------------- | ----------------------------------------------- |
| `a / 0`, `a % 0` (`Int` or `Float`) | `0` — division and remainder by zero are values, not crashes |
| `Int` overflow (`+ - * **`)       | wraps, two's-complement, silently               |
| `2 ** 100`                        | `0` — the wrap above, reached by repeated multiplication |
| `n ** k` with `k < 0` (`Int`)     | `0`, including `1 ** -1`                        |
| `n ** 0`                          | `1`                                             |
| `-7 % 3`                          | `-1` — the remainder takes the sign of the dividend |
| `10.0 ** 400.0`                   | `+Inf` — `Float` arithmetic does produce non-finite values |

`Int` is a 64-bit signed integer and its overflow **wraps**; it is not checked
and not an error, so `9223372036854775807 + 1` is the most negative `Int`. `**`
on `Int`s is repeated multiplication and wraps the same way. A negative `Int`
exponent has no integral answer, so it yields `0` rather than a fraction — which
means `1 ** -1` is `0`, not `1`. If you want the mathematical answer, work in
`Float`, where `**` is real exponentiation.

One case is **deliberately unspecified**: converting a `Float` that is `+Inf`,
`-Inf`, `NaN`, or simply too large to an `Int` (`hive.conv.ceil`, `floor`,
`round`). Go leaves that conversion implementation-dependent, and Hive does not
paper over it, so the value you get may differ between Go versions and between
architectures — today, on amd64, all four give the most negative `Int`. Non-finite
values reach a program through `Float` overflow (`10.0 ** 400.0`) and through
`hive.conv.stf("Inf")`, so check for the range you expect before converting if it
matters.

## Built-in functions

These are always in scope — no import needed. Several are overloaded by
argument type.

| Function                | Signature                    | What it does                                                         |
| ----------------------- | ---------------------------- | -------------------------------------------------------------------- |
| `len(vector)`           | `len(T[]): Int`              | Number of elements in a vector.                                      |
| `len(str)`              | `len(Str): Int`              | Number of **characters** (UTF-8 runes) in a string.                  |
| `bytes(vector)`         | `bytes(T[]): Int`            | Byte footprint of a vector's contiguous storage (count × elem size). |
| `bytes(str)`            | `bytes(Str): Int`            | Number of **bytes** in a string's UTF-8 encoding.                    |
| `append(vector, value)` | `append(T[dyn], T): void`    | Grows a **mutable** dynamic vector in place with one more element.   |
| `join(vector, sep)`     | `join(Str[], Str): Str`      | Concatenates a `Str` vector into one string, `sep` between elements. |
| `split(str, sep)`       | `split(Str, Str): Str[]`     | Splits a string on `sep` into a `Str` vector (inverse of `join`).    |
| `indexOf(vector, value)`| `indexOf(T[], T): Result<Int, Bool>` | Position of the first element equal to `value`, else `Error(false)`. |
| `indexOf(str, sub)`     | `indexOf(Str, Str): Result<Int, Bool>` | Position, in characters, of the first occurrence of `sub`, else `Error(false)`. |
| `row(table, key)`       | `row(Table, Str): Str[dyn]`  | The row whose first cell equals `key`, else `[]`.                    |
| `column(table, key)`    | `column(Table, Str): Str[dyn]`| The column whose top (first-row) cell equals `key`, else `[]`.      |

`len` and `bytes` differ only for strings: for `"café"`, `len` is `4` (runes)
while `bytes` is `5` (the `é` is two bytes). `append` is the one builtin that
requires its target to be `mut` — it is the in-place way to grow a
`Str[dyn]`; `+` instead builds a brand-new vector. `row` and `column` look a
value up in a `Table` by its first cell — `row` matches a row's first element,
`column` matches a column's top (first-row) cell — and `column` skips any row
too short to reach the matched column.

### `indexOf` returns an index you can use

`indexOf` searches a vector for an element (compared the way `==` compares it, so
a vector of vectors matches structurally) or a `Str` for a substring. It is
fallible, so it answers with a `Result`: `Ok(i)` carries the position, and the
`Error` payload is just `false` — there is nothing to say about a miss beyond
that it missed.

The point of returning a position rather than a `-1` is that **an `Ok` payload is
always a position the vector really has**. The bounds checker knows that, so the
index arrives already proven `>= 0` and `< len(v)` — inside the `Ok` branch you
index with no guard of your own:

```hive
found := indexOf(names, "bob")
if found is Result.Ok(i) {
    echo "{i}: {names[i]}"   // no `i >= 0 && i < len(names)` needed
} else if found is Result.Error(_) {
    echo "no bob here"
}
```

The proof is tied to the vector that was searched, and only for as long as that
vector means the same thing: an index found in `a` still needs a guard to index
`b`, and rebinding the vector (`v = [...]`) between the search and the use drops
it. Matching the call inline — `if indexOf(names, "bob") is Result.Ok(i)` —
works the same way.

On a `Str` the position counts **characters** (UTF-8 runes), so it lines up with
what `len` reports there. Searching an empty `Str` never succeeds, not even for
an empty needle: that keeps the same promise the vector form makes — an `Ok`
index always points at something that is really there.

## Reading tables (`using`)

`using` reads a table. Each form says in the source what it is reading, which is
what lets the compiler pick the reader — and leave the machinery for the others
out of the build:

```hive
using "./data.csv"                            // a comma-separated CSV
using "./data.tsv" as csv separating by "\t"  // another separator
using "./book.xlsx" as xlsx                   // every sheet of a workbook
using "./book.ods" as ods                     // every table of an ODS
using db run allUsers()                       // a declared query, typed rows
using db run raw someSqlText                  // SQL built at runtime, a Table
```

| form | yields |
| ---- | ------ |
| `using <path>` / `... as csv [separating by <sep>]` | `Result<Table, hive.TableError>` |
| `using <path> as xlsx` / `as ods` | `Result<Table[dyn], hive.TableError>` |
| `using <connection> run <query>` | whatever the query declared its rows to be |
| `using <connection> run raw <text>` | `Result<Table, hive.sql.SqlError>` |

`as csv` is optional — a bare `using <path>` is a comma-separated CSV, and
`separating by` overrides the comma. A CSV is a single table, so it comes back as
one `Table`. A **spreadsheet holds many**, so xlsx and ods come back as a
`Table[dyn]` — one `Table` per sheet, in the order the document keeps them (an
empty sheet is an empty `Table`, so the positions still line up with the
document). Both formats are read with nothing but Go's standard library, so a
program that opens a workbook still builds offline.

Spreadsheet cells arrive as the file stores them, with one exception worth
knowing: **xlsx keeps a date as a day count**, so a date column would read as
`46228`. The cell's number format is consulted to catch exactly those and render
them as `2026-07-25` (or `2026-07-25 14:30:00`, or `14:30:00` for a time-only
cell). Numbers, booleans and cached formula results pass through untouched. An
ods stores real dates, so nothing has to be undone there. Rows are padded to the
widest row in their sheet, since a spreadsheet stores no trailing blanks.

* **Querying** uses the `run` form, and what it gives back is what the query
  declared — see [typed queries](#queries-are-typed-by-their-rows). `run raw` is
  the escape hatch for SQL assembled at runtime: nothing can know its shape, so
  it comes back as a `Table` with its header row, exactly as reading a CSV does.

See [`code-examples/12 - Files and Spreadsheets`](code-examples/12%20-%20Files%20and%20Spreadsheets/files-and-spreadsheets.hive).

## Standard library (`hive.*`)

Each module owns its types under its own namespace — `hive.net.HttpRequest`,
`hive.json.JsonError`, `hive.crypto.CryptoError`, `hive.sql.DatabaseDriver`,
`hive.conv.ConversionError`, `hive.env.EnvironmentError`,
`hive.syslink.Address`, `hive.task.TimeoutError`, and so on. The only builtin types that live directly on `hive` are the core
ones the language uses without a module: `Result`, `Table` and the
`hive.TableError` that `using` yields from a CSV.

**A module you don't use is not in your build.** The generated Go project always
carries the core runtime, but each `hive.*` module is written into it — and so
compiled and linked — only when the program actually references that module (see
`hive/runtime.gleam`'s module table and `hive/cli.gleam`). A module a used one
depends on internally comes along too: `hive.crypto` decodes JWT payloads with
`hive.json` and checks `exp`/`nbf` against `hive.time`, so reaching for a JWT
pulls in all three. This is why `hive.sql` is the only module that costs you
anything at build time: it is the only one that links external Go drivers, and a
program that never opens a connection neither downloads nor links them, staying
dependency-free and buildable offline.

### `hive.net`

The networking library: HTTP, WebSockets and raw TCP, clients and servers.
Everything here performs I/O, so — like `echo` and `using` — it works inside a
`func` or a `proc`. All of it is built on Go's standard library alone, so a
program that speaks any of these still builds offline with no dependencies.

Each of the three servers blocks forever, so it usually goes on a virtual
thread of its own (`async func`), and each runs its handler once per
request/connection on a virtual thread of its own too. Every call in the module
names its protocol — `httpRequest`, `wsSend`, `socketReceive` — so nothing here
reads as "the" default one. A handler is passed **by
name**, and its declared shape is checked at compile time — including through a
partial application like `handler(_, db)`.

**HTTP.** Requests and responses are built positionally —
`hive.net.HttpRequest(method, url, headers, body)`,
`hive.net.HttpResponse(status, headers, body)` — and headers are a `Table` of
`[name, value]` rows.

* `hive.net.httpRequest(req)` performs a request and returns
  `Result<hive.net.HttpResponse, hive.net.HttpError>` (a `Result.Error`
  means no response was obtained at all).
* `hive.net.httpServe(port, handler)` serves every route through `handler`, a
  `proc (hive.net.HttpRequest): hive.net.HttpResponse`.

**WebSockets** (RFC 6455). The handshake, frame headers, masking, ping/pong and
fragmentation are the runtime's business; a program only ever sees whole
messages as `Str`. A `hive.net.WsConnection` is opaque, and a
`hive.net.WsError`'s `reason` is a short tag — `"Handshake"`, `"Protocol"`,
`"Closed"`, `"Send"` or `"Receive"`.

* `hive.net.wsConnect(url)` opens a client connection to a `ws://` or `wss://`
  URL (`wss://` negotiates TLS) →
  `Result<hive.net.WsConnection, hive.net.WsError>`.
* `hive.net.wsServe(port, handler)` accepts connections, with `handler` a
  `proc (hive.net.WsConnection): void`. The connection closes when it returns.
* `hive.net.wsSend(connection, message)` sends one text message →
  `Result<Int, hive.net.WsError>`, the `Int` being the bytes it carried.
* `hive.net.wsReceive(connection)` blocks for the next message →
  `Result<Str, hive.net.WsError>`. A peer that hangs up is a `Result.Error`
  whose reason is `"Closed"` — the ordinary end of a conversation. One virtual
  thread should own a connection's receiving side.
* `hive.net.wsRequest(connection)` is the `hive.net.HttpRequest` that opened the
  connection, so a handler can route on its `url` or authenticate from its
  `headers`.
* `hive.net.wsClose(connection)` sends a close frame and shuts down; calling it
  twice is harmless.

**Raw TCP.** A stream, not a queue of messages: `socketReceive` hands back
whatever has arrived so far, so the protocol has to say where a message ends.
A `hive.net.SocketConnection` is opaque, and a `hive.net.SocketError`'s
`reason` is `"Connect"`, `"Closed"`, `"Send"` or `"Receive"`.

* `hive.net.socketConnect(host, port)` dials a server →
  `Result<hive.net.SocketConnection, hive.net.SocketError>`.
* `hive.net.socketServe(port, handler)` accepts connections, with `handler` a
  `proc (hive.net.SocketConnection): void`. The connection closes when it
  returns.
* `hive.net.socketSend(connection, data)` → `Result<Int, hive.net.SocketError>`,
  the `Int` being the bytes written.
* `hive.net.socketReceive(connection, bytes)` blocks until at least one byte
  arrives and returns up to `bytes` of it → `Result<Str, _>`. A short read is
  normal, so code needing an exact count must keep asking.
* `hive.net.socketReceiveLine(connection)` blocks for a whole line and returns
  it without the trailing `"\n"` (or `"\r\n"`) → `Result<Str, _>` — the read for
  line-oriented protocols.
* `hive.net.socketPeer(connection)` is the remote address (`"host:port"`), and
  `hive.net.socketClose(connection)` shuts the connection down.

### `hive.file`

General filesystem access, for the files `using` does not cover. Contents move as
`Str`, which holds bytes rather than validated text, so a binary file survives a
read/write round trip unchanged. Everything fallible returns
`Result<_, hive.file.FileError>`, whose `reason` is a short tag — `"NotFound"`,
`"Permission"`, `"Exists"` or `"Io"` — alongside the `path` and the underlying
`message`.

* `hive.file.read(path)` → `Result<Str, _>` is the whole file;
  `hive.file.lines(path)` → `Result<Str[dyn], _>` splits it on newlines, dropping
  the empty piece a trailing newline leaves and any Windows carriage returns.
* `hive.file.write(path, contents)` replaces a file, creating it when absent, and
  `hive.file.append(path, contents)` adds to the end of one. Both return
  `Result<Int, _>` — the bytes written. Neither creates missing parent
  directories.
* `hive.file.exists(path)` → `Bool` (a directory counts) and
  `hive.file.size(path)` → `Result<Int, _>` in bytes.
* `hive.file.delete(path)` removes a file, or a directory that is already empty.
* `hive.file.list(path)` → `Result<Str[dyn], _>` is a directory's entry names,
  sorted and without any leading path; `hive.file.makeDir(path)` creates a
  directory along with any missing parents, and is not an error when it is
  already there.
* `hive.file.copy(from, to)` → `Result<Int, _>` copies contents over `to`,
  replacing it; `hive.file.move(from, to)` renames, which is also how one moves.

### `hive.json`

The JSON library, built on the idea that Hive's type declarations *are* the
JSON schema, and works inside both `func`s and `proc`s.

* `hive.json.parse(text) with T` derives a decoder for `T` at compile time and
  returns `Result<T, hive.json.JsonError>`: missing fields, wrong types and wrong
  static vector lengths become errors carrying the exact `path` that failed,
  while JSON fields the type doesn't declare are simply ignored. Variants
  decode as `{"VariantName": {...}}` (JSON `null` selects a type's first
  field-less variant).
* `hive.json.encode(value)` derives the encoder from the static type and
  therefore cannot fail.
* `hive.json.table(text)` reads a JSON array of flat objects as a headered
  `Table`, the same shape `using` yields from CSV.
* JSON you don't want to model stays type-safe too: `parse(text) with Table`
  flattens a whole document into `[path, value]` rows, looked up with
  `hive.json.get(table, "keys.layout")` and re-nested by the encoder.

### `hive.crypto`

General-purpose cryptography plus JSON Web Tokens. All of it is pure, so it
works inside both `func`s and `proc`s. Fallible operations return
`Result<_, hive.crypto.CryptoError>`, whose `reason` is a short tag such as
`"BadSignature"`, `"Expired"` or `"Malformed"`.

* **Hashing** — `hive.crypto.sha256(input)` and `hive.crypto.sha512(input)`
  return a lowercase-hex digest; `hive.crypto.hmacSha256(input, key)` is the
  keyed (HMAC-SHA256) variant.
* **Encoding** — `hive.crypto.base64Encode(input)` returns standard base64;
  `hive.crypto.base64Decode(input)` returns `Result<Str, hive.crypto.CryptoError>`.
* **Random** — `hive.crypto.randomHex(bytes)` returns that many
  cryptographically-random bytes as a hex string, handy for secrets or nonces.
* **JWT**, built on the same "your types are the schema" idea as `hive.json`:
  * `hive.crypto.jwtSign(claims, secret)` encodes the typed `claims` value as
    the payload and returns a compact HS256 token (signing can't fail, so it is
    a plain `Str`).
  * `hive.crypto.jwtVerify(token, secret) with T` checks the signature and the
    `exp`/`nbf` claims against the current time, then decodes the payload into `T`,
    returning `Result<T, hive.crypto.CryptoError>`. Only HS256 is accepted, so
    `alg: none` and algorithm-confusion are rejected outright.
  * `hive.crypto.jwtDecode(token) with T` decodes the payload **without
    verifying** it — for inspection only, never for authorization.
  * `hive.crypto.jwtHeader(token)` reads the `hive.crypto.JwtHeader`
    (`alg`/`typ`/`kid`) without verifying, e.g. to pick a key by `kid`.

### `hive.sql`

Talks to **SQLite** and **PostgreSQL**. SQLite is the pure-Go
`modernc.org/sqlite` driver — the engine is compiled straight into your
executable, so local databases work with no CGO and nothing to install;
Postgres is `github.com/lib/pq`.

* **Querying** uses the `using <connection> run <query>` form — see
  [Queries are typed by their rows](#queries-are-typed-by-their-rows) below.
* `hive.sql.connect(driver, connString)` opens a pooled connection and returns
  `Result<hive.sql.SqlConnection, hive.sql.SqlError>`; `hive.sql.pool(driver,
  connString, maxOpen, maxIdle)` does the same with explicit pool limits;
  `hive.sql.close(conn)` releases it.
* The `driver` is a `hive.sql.DatabaseDriver`, built with
  `hive.sql.DatabaseDriver.SQLite()`, `.PostgreSQL()`, or `.Other(name)` for
  any other registered `database/sql` driver.

A `hive.sql.SqlConnection` is a **connection pool**, not a single connection, so
one is safe to hold for the life of the program and to share across virtual
threads — open it once in `main` and pass it along (a partial application like
`handler(_, db)` is the usual way). Never open one per query: for a file-backed
database that is merely wasteful, but for an in-memory one it is worse than that.

#### Queries are typed by their rows

A `query`'s return type describes what comes back, not the SQL text:

| declared | `using conn run q(...)` yields |
| -------- | ------------------------------- |
| `Row[dyn]` (a declared type) | `Result<Row[dyn], hive.sql.SqlError>` |
| `Str[dyn]`, `Int[dyn]`, … (a scalar) | that column, as a vector |
| `void` | `Result<Int, hive.sql.SqlError>` — the number of rows it affected |

```hive
type User {
	id:   Int
	name: Str
}

query allUsers(): User[dyn] {
	SELECT id, name FROM users ORDER BY id
}

query userNames(): Str[dyn] {          // one column needs no row type
	SELECT name FROM users
}

query deleteUser(id: Int): void {      // a statement reports what it touched
	DELETE FROM users WHERE id = {id}
}
```

Columns are matched to the row type's fields **by name**, so reordering the
`SELECT` cannot silently remap them — and a column whose name differs from its
field needs an alias (`SELECT u.name AS author`). A row type holds scalars only.

**`SELECT *` is a compile error** against a declared row type. It says neither
how many columns come back nor what they are called, so there is nothing to
match the fields against — and what it stands for changes the day somebody adds
a column to the table. Spell the columns out, or declare the query as returning
a `Table` and take the rows untyped:

```hive
query allUsers(): User[dyn] {
	SELECT * FROM users           // compile error: `q` selects `*`
}
```

The rule is about the *result*, so it costs nothing elsewhere: `count(*)` is a
call rather than a star, `a * 2` is multiplication, a star inside a subquery
belongs to that subquery, and a `void` statement's select list (`INSERT INTO a
SELECT * FROM b`) is not a result at all. All four still compile.

**Values are bound, never spliced.** An interpolated `{param}` becomes a
placeholder and the value travels beside the text as an argument, so nothing a
caller supplies can change what a statement means. The dialect is handled for
you: queries are written with `?` and rewritten to `$1, $2, …` for PostgreSQL by
the connection, which is what lets one declaration serve both drivers.

What is still a runtime `hive.sql.SqlError`, because nothing at compile time can
know it, with a `reason` telling them apart:

| `reason` | what happened |
| -------- | ------------- |
| `"Connection"` | the connection is not open |
| `"Query"` | the driver rejected the SQL, or the read failed |
| `"Shape"` | the row came back with a different number of columns |
| `"Convert"` | a cell did not fit the type its field was declared with |

#### Optional filters: `where { }`

Most "dynamic" queries are a fixed query with optional predicates, and that
needs no string building. A `where` block ANDs the predicates whose conditions
hold; a nested `or { }` or `and { }` flips the connective:

```hive
query findColonies(apiary: Str, minFrames: Int, small: Bool, huge: Bool): Colony[dyn] {
	SELECT name, apiary, frames FROM colonies
	where {
		if apiary != ""   { apiary = {apiary} }
		if minFrames > 0  { frames >= {minFrames} }
		or {
			if small { frames < 4 }
			if huge  { frames > 10 }
		}
	}
	ORDER BY name
}
```

A group that contributes nothing disappears rather than leaving a dangling
connective, and if no predicate is present at all there is no `WHERE` clause —
so there is no `WHERE 1 = 1` to write. A group contributing more than one
predicate is parenthesised, so nesting cannot change how the surrounding
connective binds. Every branch's text is fixed at compile time; only which
branches are taken is decided at runtime.

Two things a `where` block deliberately cannot do. A **column name or sort
direction** can never be a parameter — `ORDER BY {col}` would sort by a constant
string — so make the choices a variant type and dispatch to one query per
ordering; the compiler then checks the match is exhaustive and injecting a column
name is structurally impossible. And **SQL you genuinely assemble yourself** —
an admin console, ad-hoc reporting — goes through `run raw`, which is untyped by
construction and greppable by design.

See [`code-examples/5 - SQL`](code-examples/5%20-%20SQL/sql.hive).

#### In-memory SQLite

A plain `:memory:` database belongs to the **connection**, not the process: each
connection gets a private, empty database that vanishes when it closes. Combined
with pooling, that has a sharp edge — under concurrency the pool opens further
connections, and each one lands on a database of its own:

| connection string | one query at a time | eight at once |
| ----------------- | ------------------- | ------------- |
| `:memory:`, default pool | works | fails intermittently: `no such table` |
| `:memory:`, `pool(…, 1, 1)` | works | works, one query at a time |
| `file::memory:?cache=shared` | works | works |

The first row is the trap: a program that passes every test single-threaded starts
failing once requests overlap — exactly what happens behind
`hive.net.httpServe`, which runs each request on its own virtual thread.

So for an in-memory database, ask for a **shared cache**:

```hive
opened := hive.sql.pool(hive.sql.DatabaseDriver.SQLite(), "file::memory:?cache=shared", 8, 1)
```

Every pooled connection then sees the same database. Pinning the pool to one
connection instead — `hive.sql.pool(driver, ":memory:", 1, 1)` — is also correct,
but it serializes every query and gives up the concurrency you had. Two things to
know about shared cache: the database lives only while at least one connection is
open, which is what the `maxIdle` of 1 above guarantees rather than leaves to the
pool's defaults; and it locks at table granularity, so a very write-heavy
concurrent workload can meet contention that a file-backed database in WAL mode
would not.

> **Build note:** SQL programs link real Go drivers, so the **first** build of
> a program that uses `hive.sql` runs `go mod tidy` to fetch them (network
> required once, then cached). Programs that don't use `hive.sql` keep a
> dependency-free `go.mod` and build fully offline, exactly as before.

### `hive.conv`

Number and string conversions. Everything here is pure, so it works inside both
`func`s and `proc`s.

* **Rounding** (`Float -> Int`) — `hive.conv.ceil(value)`,
  `hive.conv.floor(value)` and `hive.conv.round(value)` (round half away from
  zero).
* **Widening / rendering** — `hive.conv.itf(value)` widens an `Int` to a
  `Float`; `hive.conv.its(value)` renders an `Int` as a `Str`, and
  `hive.conv.fts(value)` a `Float` as a `Str`.
* **Parsing** — `hive.conv.sti(text)` parses a `Str` into
  `Result<Int, hive.conv.ConversionError>` and `hive.conv.stf(text)` into
  `Result<Float, hive.conv.ConversionError>`. A `ConversionError` carries the
  offending `input` and a short `message`.

### `hive.env`

Reads environment variables, from a `.env` file or the OS.

* `hive.env.get(name)` returns `Result<Str, hive.env.EnvironmentError>`. It
  resolves `name` in this order: the `.env` file in the program's own folder;
  failing that, the `.env` file in the parent folder; and failing that, the OS
  environment. A variable found in none of them yields an `EnvironmentError`
  carrying the `key` it looked for and a short `message`.
* The `.env` file is read **once**, when the first `get` runs. It is a plain
  list of `NAME=value` lines: blank lines and `#` comments are ignored, an
  optional `export ` prefix is allowed, and a value may be wrapped in single or
  double quotes (which are stripped).
* "The program's folder" is its working directory — which `hive run` sets to
  the entrypoint's folder, and a built executable inherits from wherever it is
  launched (the same rule `using "./file.csv"` follows).

### `hive.term`

Line-oriented terminal I/O.

* `hive.term.print(text)` writes a line to stdout — the same lowering as
  `echo`, but restricted to a `Str`.
* `hive.term.read()` blocks until the user finishes a line of input and returns
  it as a `Str`, stripped of the trailing newline. It parks only the calling
  virtual thread: called inside an `async func`, the rest of the program keeps
  running on other threads while that goroutine waits. At end of input it
  returns whatever preceded EOF (`""` if nothing).
* `hive.term.args()` returns the command-line arguments the program was started
  with — in order, excluding the program name — as a `Str[dyn]`. `hive run`
  forwards anything after the entrypoint (`hive run app.hive a b c`), and a
  built executable receives them from the shell directly.

### `hive.task`

Scheduling controls over the virtual threads an `async func` runs on.

* **`await <handle> with timeout <ms>`** bounds how long a wait may take. The
  clause is optional and may follow **any** `await`, and it changes what the
  await yields: without it you get the value, with it a
  `Result<T, hive.task.TimeoutError>` — running out of patience is a value to
  handle, not a crash. A `TimeoutError` carries `waited` (the milliseconds asked
  for) and a `message`. On a vector of handles the timeout is **one deadline
  across the whole barrier** (`await [a, b] with timeout 500` means "both within
  half a second"), and the whole vector fails together.

  A timeout abandons the **waiting**, not the work: a virtual thread cannot be
  stopped from the outside, so the task runs on and only its result is dropped.
  That is also why the same handle can be awaited again afterwards, with more
  patience or none at all, and still yield its value.

  ```hive
  patient := slowShout("worth waiting for")
  if await patient with timeout 100 is Result.Error(err) {
  	echo "gave up after " + hive.conv.its(err.waited) + "ms"
  }
  echo await patient          // the task kept running; this still gets it
  ```

  On a [`hive.syslink`](#hivesyslink) request the clause folds into that module's
  own error instead of wrapping a second `Result` around the first, so
  `await hive.syslink.send(a, m) with timeout 250` is still a
  `Result<Message, hive.syslink.SyslinkError>` whose reason is `"Timeout"`.
  Omitted, syslink waits its own default (5s).

  `timeout` is not a reserved word — it means something only in this two-token
  clause, so it stays usable as an ordinary variable name.
* `hive.task.sleep(ms)` parks the calling virtual thread for `ms` milliseconds
  and returns nothing. Only that goroutine waits — others keep running — so two
  tasks that each `sleep`, spawned and then awaited together, finish in about
  the longer of the two, not the sum. A non-positive `ms` returns immediately.

### `hive.syslink`

Addressable **services**, in this process or on another machine, reached by the
same statement either way. A service is long-lived, owns private state only it
can touch, and has an identity you can pass around.

A service is deliberately **not** an `async T`. The two features do not overlap:

| | `async T` | `hive.syslink.Address` |
| --- | --- | --- |
| lifetime | scoped — cannot outlive its spawner | unscoped — outlives everything |
| identity | none (a join point) | yes, that is the point |
| interaction | `await`, yields `T` | `send`, yields nothing |
| as a value | cannot be stored, returned or passed | ordinary value; can even be sent inside a message |

**The handler is a fold over the mailbox.** `proc (State, Message,
hive.syslink.Envelope): State` — state in, one message, the turn's envelope, and
the next state out. The compiler enforces that the state going in and the state
coming out are the same type. There is no mutex and no `mut` anywhere: the fold
*is* the mutex, which is the whole payoff of the model.

```hive
type Op {
	Put { key: Str, value: Str }
	Count
}

proc cache(rows: Table, op: Op, from: hive.syslink.Envelope): Table {
	if op is Op.Put(key, value) {
		mut next := rows
		append(next, [key, value])
		return next
	}
	hive.syslink.answer(from, len(rows))
	return rows
}
```

**Nodes.** A node has no name: it is identified by **where it is**. An endpoint is
deployment data — an IP, a DNS name, a value from config — so it is a `Str`, and a
peer list can be computed, read from a file or resolved through DNS. There is no
port-mapper daemon and no cluster-wide name registry.

* `hive.syslink.listen(endpoint)` starts accepting connections →
  `Result<Str, hive.syslink.SyslinkError>`. The endpoint is what this node tells
  peers to dial it on (`"10.0.0.4:9100"`); the port is taken from it and bound on
  every interface. Advertising it is what keeps an address this node hands out
  dialable even after a peer passes it on again.
* `hive.syslink.node()` is the endpoint this node advertises.

Nothing is dialed until there is a message to carry, and a connection is filed
under the peer's *advertised* endpoint rather than the string that was dialed — so
`"localhost:9101"` and `"127.0.0.1:9101"` share one connection instead of quietly
opening two and splitting the ordering guarantee between them.

**Services.**

* `hive.syslink.spawn(handler, state)` starts a service and returns its
  address without blocking. The handler is passed **by name** and its shape is
  checked at compile time, including through a partial application
  (`cache(_, _, _, db)`).
* `hive.syslink.register(name, address)` publishes a service under a name →
  `Result<hive.syslink.Address, _>` (`"Taken"` if the name is in use).
* `hive.syslink.at(name)` is the address of a named service **on this node**, and
  `hive.syslink.on(endpoint, name)` the same service on the node reachable at
  `endpoint`. Both perform **no I/O and cannot fail** — they are address
  construction, not a lookup, which is what lets a program name a service that is
  not running yet, or a node that is temporarily down, and still type-check and
  run.
* `hive.syslink.stop(address)` shuts a service down; calling it twice is
  harmless.

**Messages.** There is exactly **one** way to reach a service, and — as with an
`async func` — what the *call site* does with it decides what it means:

```hive
hive.syslink.send(inbox, Note.Say("hi"))          // statement: fire-and-forget
pending := hive.syslink.send(cache, Op.Count())   // keep the request in flight
answer := await pending                            // wait for it
answer := await pending with timeout 250           // ...for at most 250ms
answer := await hive.syslink.send(cache, Op.Count())        // spawn + wait
both := await [hive.syslink.send(a, m), hive.syslink.send(b, m)]  // one barrier
```

* As a **statement**, `hive.syslink.send(address, message)` returns `void` and
  **never blocks and never fails.** A dead or unreachable recipient is not an
  error at the send site — that is precisely what keeps a local send and a remote
  one the same statement, and failure is discovered through a monitor instead.
  Nothing is registered for a reply, so this is also the cheapest form.
* **Kept**, the same call is a *request in flight*. Its type is inferred and has
  no surface spelling, exactly like `async T`: you may bind it and `await` it,
  and nothing else. (It is not an `async T` underneath — no goroutine is parked
  waiting, because the answer arrives on the connection's own reader.)
* **`await`ing** it yields `Result<Message, hive.syslink.SyslinkError>`. This is
  the one place in the module that reports failure, because it is the only one
  with somewhere to report to: a `"Timeout"`, a service that died mid-request
  (`"Down"` / `"NoProc"`), an unreachable node (`"Unreachable"`), a payload that
  would not decode (`"Decode"`) and a request the service handled but never
  answered (`"NoReply"`) all arrive here. Awaiting is idempotent for a settled
  answer; a *timed-out* request deliberately is not settled, so the same handle
  may be awaited again with more patience.
* **The reply type is the mailbox type**, so nothing is ever annotated. A service
  answers with one of *its own* messages, which makes a mailbox type the whole
  protocol — requests and responses together — and lets `is` narrow a reply
  exactly like anything else.
* Either way the message is copied on its way in, using the same deep,
  type-directed copy [a binding uses](#value-semantics-copy-on-binding), so the
  recipient can never observe the sender mutating it afterwards.
* `hive.syslink.answer(from, value)` replies to whoever is awaiting. If the
  sender discarded its request nothing is waiting, so it is a no-op — one handler
  serves both shapes without caring which it was.

**Forgetting to answer fails fast, and you write nothing to get it.** Missing a
reply on one branch is the easiest mistake to make in service code, and waiting
out a timeout is a miserable way to be told — it points at the network when the
problem is a missing line. So a request a service handles without answering comes
straight back as `"NoReply"`, naming the service. The same goes for a message the
service could not decode or whose type it does not handle: the runtime already
knows no answer is coming, so it says so instead of staying quiet.

The compiler decides which services this applies to, by asking where the
envelope goes:

* If a handler's envelope only ever reaches `answer`, `self` or `monitor` — the
  three calls the runtime controls, none of which keep the reply token — it
  cannot outlive the turn it arrived in. Once that turn ends, no answer can still
  be coming, so an unanswered request is failed at once.
* If the envelope goes anywhere else — stored in the returned state, handed to an
  `async func`, passed to one of your own procs — a reply may genuinely still be
  on its way, and the runtime keeps waiting exactly as before. That is what makes
  the *deferred* reply possible: hand the envelope to a task and the service's
  turn ends immediately without the caller being cut off.

```hive
// Answered or not, within the turn -> a forgotten reply fails immediately.
proc tidy(n: Int, m: Ask, from: hive.syslink.Envelope): Int {
	if m is Ask.Now { hive.syslink.answer(from, Ask.Reply("here")) }
	return n + 1                       // Ask.Later gets `NoReply` at once
}

// The envelope leaves the turn, so the answer is allowed to arrive later.
proc patient(n: Int, m: Ask, from: hive.syslink.Envelope): Int {
	answerLater(from)                  // an async func, replies when it is done
	return n + 1
}
```

The analysis is per handler and deliberately conservative, in the same spirit as
the [copy-vs-alias rule](#value-semantics-copy-on-binding): one escape anywhere
switches the fast failure off for that whole service, and anything it cannot
vouch for counts as an escape. Being wrong that way costs a timeout; being wrong
the other way would cut off a live request.
* `hive.syslink.self(from)` is the running service's own address.
* `hive.syslink.monitor(from, target, message)` asks to be told when `target`
  dies, by delivering a message **the watcher chose itself**. That is what keeps
  a mailbox a single user type, with no builtin envelope union mixed into it. A
  monitor fires exactly once, and a target on a node that cannot even be reached
  fires it immediately.

**A crash is local to its service.** A `panic` inside a service body kills only
that service: its monitors are told, its callers stop waiting, and the node keeps
running. This is the one place `panic` does not stop the program, and it is what
makes supervision meaningful — "let it crash" is worthless if crashing takes the
node down with it.

**The registry is known at compile time.** A *service* name is an atom, and an
atom cannot be computed, so the set of names a program publishes is closed and
knowable before it runs. The compiler therefore pairs every `register(#Name, …)`
with the message type of the mailbox behind it, which is why neither
`at(#Name)` nor `on(endpoint, #Name)` needs a `with` clause to say what it
expects, and why the digest below is computed from a type the compiler resolved
rather than one the programmer restated. Erlang cannot do this at all:
`list_to_atom/1` means a registered name there is never known at compile time.

A service name is also the only kind of address that **survives its service
dying**: a named address is re-resolved through the registry on every send, so a
replacement registered under the same atom is picked up by every holder without
any of them noticing. An anonymous address carries a mailbox id and is dangling
the moment its service exits. That indirection — not lookup — is what names are
for, and it is what supervision will be built on.

Nodes deliberately have no such names. A node identity would have to be resolved
to an endpoint at runtime anyway, and there is nothing for a peer to impersonate
when you reached it by dialing it, so making one an atom bought nothing and cost
the ability to compute a peer list.

**On the wire.** One persistent, multiplexed connection per node *pair*, carrying
length-prefixed frames — not one per service and not one per message, because
message order is guaranteed between a pair of nodes and that requires exactly one
FIFO pipe per pair. Connections are dialed lazily on the first message that needs
one, and either end may dial; when both do at once, exactly one survives (the one
dialed by the lexicographically smaller endpoint). Replies travel back over the same
pipe, so a node that can only dial out still takes part fully. A heartbeat runs
every 15s and three missed ticks declares the node down, failing its outstanding
calls and firing its monitors. The outbox is unbounded — a bounded one would make
`send` block — but past a high-water mark the node is declared unreachable rather
than growing forever, which turns a memory problem into the failure the program
already handles. **Delivery is best-effort:** messages queued when a node is
declared down are dropped, and reconnecting does not resurrect them.

Messages cross as JSON, using the very same derived codecs `hive.json` builds
from a type declaration — so nothing new has to be derived for a type to be
sendable. Every frame carries a 32-bit structural **digest** of the message type,
so a peer built from a different declaration fails loudly instead of decoding
another type's bytes. Payloads are decoded on the *recipient's own turn*, so a
bad message fails as that service's problem rather than resetting a connection
shared with every other service on the node.

**Always encrypted.** Every connection is TLS 1.3, mutually authenticated, with
no plaintext path and no capability flag that could negotiate one away — on
loopback and plain IPs included. Certificates are ephemeral Ed25519, generated at
boot and never written to disk: they carry keys, not identity. Identity comes
from a cluster secret proven over the pair of certificates *as each side locally
sees them*, which is what stops an attacker who terminates TLS on both ends from
relaying one side's proof to the other. There is no node name in the proof because
there is no node name to claim: you reached a node by dialing it. The
secret never crosses the wire and never encrypts anything — TLS 1.3 is always
ECDHE, so leaking it tomorrow does not decrypt traffic captured today. It comes
from `HIVE_SYSLINK_KEY`, or from `~/.hive/syslink.key`, which is generated with
32 random bytes (mode 0600) on first use — so two nodes on one machine are
authenticated with no setup at all, and spanning machines means copying that one
file.

Set `HIVE_SYSLINK_STRICT=1` to force **local** sends through the same
encode/decode path a remote one takes. A message that could not survive the wire
then fails in a single-process run instead of the first time a peer is added.

Not yet built: rejecting a mismatched `send` at compile time (the registry knows
each mailbox's type, but a wrong-typed message is currently caught by the digest
at runtime — the recipient drops it and says so — rather than refused by the
compiler), message fragmentation (a frame over 8 MB is refused rather than split,
so a very large message can head-of-line block its node pair), a WebSocket
transport for environments that only forward HTTP, pinned per-node keys as an
alternative to the shared secret, and supervision trees. See
`code-examples/13 - Distributed Actors`, which runs as two nodes in two terminals
or on two machines, and `code-examples/9 - EXAMPLE APP - Online Cache`, a
three-node cache that reads its peer list at startup.

### `hive.time`

The wall clock and calendar formatting. Times are plain `Int`s — Unix seconds.

* `hive.time.now()` returns the current Unix time in seconds. (This was the bare
  `now()` builtin; it now lives here, and a stray `now()` reports as much.)
* `hive.time.timezone()` returns the machine's local zone name or abbreviation
  at this instant (`"UTC"`, `"PST"`, `"-03"`, ...), and
  `hive.time.timezoneOffset()` its current offset from UTC in **minutes**, east
  of UTC positive (so UTC+2 is `120`, UTC−3 is `-180`).
* `hive.time.format(time, template)` renders a Unix time, in local time, with a
  `strftime`-style template — familiar rather than Go's reference-date layout.
  Unrecognized `%x` escapes pass through verbatim. Directives:

  | | | | |
  |---|---|---|---|
  | `%Y` year (4) | `%y` year (2) | `%m` month `01`–`12` | `%d` day `01`–`31` |
  | `%H` hour `00`–`23` | `%I` hour `01`–`12` | `%M` minute | `%S` second |
  | `%p` `AM`/`PM` | `%j` day-of-year | `%Z` zone name | `%z` zone offset |
  | `%A`/`%a` weekday | `%B`/`%b` month name | `%%` literal `%` | |

  ```hive
  echo hive.time.format(hive.time.now(), "%Y-%m-%d %H:%M:%S")
  echo hive.time.format(1700000000, "%A, %d %B %Y")   // Tuesday, 14 November 2023
  ```

## Multiple files

A Hive program can span as many files as you like. `import`, written outside any
`proc` or `func`, brings another file's declarations into scope:

```hive
import ./lib/text
import ./lib/inventory as stock

proc main(): void {
	echo text.repeat("=", 28)
	echo stock.line(stock.Item("Beeswax", 450))
}
```

* The **path is relative to the importing file's own directory** and leaves the
  `.hive` extension off, so `./lib/text` is `lib/text.hive` next door and
  `../../shared/text` climbs out first. It is the file's location that matters,
  not where you happen to run `hive` from.
* A module is reached through a **name**: the file's own name by default
  (`./lib/text` → `text`), or whatever `as` gives it. Use `as` when two modules
  would otherwise collide, when a name would clash with something the importing
  file declares, or when the file name isn't usable as a name at all
  (`./lib/text-utils` needs one).
* **Everything a module declares is visible** — procs, funcs, queries and types.
  There is no `pub`/`priv` distinction yet.
* Modules may import modules of their own, and a file is **loaded once** however
  many modules reach for it.
* **Import cycles are rejected**, whether direct (a file importing itself) or
  round any number of steps. The error prints the loop it found:

  ```
  hive: this import forms a cycle:

      lib/inventory.hive
        -> lib/pricing.hive
        -> lib/inventory.hive
  ```

Names carry no baggage across a module boundary: a type or function only ever
means what the module you read it in says it means. Two files may each declare
their own `Align` and both stay distinct types, referenced as `Align` in one and
`text.Align` in the other. An imported type is constructed, annotated and
matched through the same name its module is reached by
(`text.Align.Left()`, a `text.Align` parameter, `style is text.Align.Left`), and
an imported callable is an ordinary value — partially applicable
(`text.repeat("~", _)`) and passable like any other.

Under the hood the whole program becomes **one Go package**: the entrypoint keeps
its own names and every imported module's declarations are given a prefix of
their own, so `hive emit` shows `text_0_repeat` beside your untouched `main`. A
local binding still shadows a module-level name of the same shape, exactly as it
does in a single file.

See [`code-examples/11 - Modules`](code-examples/11%20-%20Modules/modules.hive).

## How Hive maps onto Go

| Hive                                    | Go                                                             |
| --------------------------------------- | -------------------------------------------------------------- |
| `proc`/`func` `name(): T { ... }`       | `func name() T { ... }`                                        |
| `proc main(): void`                     | `func main()`                                                  |
| `query q(p: Str): Row[dyn] { SQL {p} }` | `func q(p string) hive.SqlFragment` — text with `?`, plus the bound args |
| `query q(...): void`                    | run with `hive.SqlExec` → `Result[int, SqlError]` (rows affected) |
| `where { if c { … } or { … } }`         | fragments collected at runtime, joined by `hive.SqlJoin`        |
| `type T { }` (no variants)              | a `struct`                                                     |
| `type T { A {..} B }` (variants)        | an `interface` + one `struct` per variant (a tagged union)     |
| fields declared outside any variant     | appended to **every** variant struct                           |
| `name := expr`                          | `name := expr` (type inferred)                                 |
| `T name = expr`                         | `var name T = expr`                                            |
| `mut name := expr` / `mut T name = e`   | same as above (`mut` is compile-time only — permits reassign)  |
| `mut b = a` (both `mut`, owns storage)  | no variable at all — `b` compiles to `a`, so one slice header is shared |
| `x = expr` / `v[0] = expr`              | `x = expr` / `v[0] = expr` (only on `mut` variables)           |
| `ys := xs` (needs a copy — see [value semantics](#value-semantics-copy-on-binding)) | `ys := hive.CloneVec(xs)` / `hive.CloneVecFn(..)` / `hive.CloneTable(..)` / `clone_T(..)` |
| `for i := 0; i < n; i = i + 1 { }`      | `for i := 0; i < n; i = i + 1 { }` (counter scoped to the loop) |
| `for each x in v { }`                   | `for _, x := range v { }` (binds the value, discards the index) |
| `async func f(): T { ... }`             | `func f() T { ... }` (an ordinary Go function)                 |
| `f(x)` bare stmt / `await f(x)` (async `f`) | `go f(x)` (fire-and-forget goroutine) / `f(x)` (blocking call) |
| `h := f(x)` (async `f`) / `await h`     | `h := hive.Spawn(func() T { return f(x) })` / `h.Await()`      |
| `await [f(a), f(b)]` (async `f`)        | `hive.AwaitAll([]*hive.Async[T]{ hive.Spawn(..), hive.Spawn(..) })` |
| `await h with timeout ms`               | `hive.AwaitTimeout(h, ms)` → `Result[T, TimeoutError]`          |
| `await [f(a), f(b)] with timeout ms`    | `hive.AwaitAllTimeout(hs, ms)` → `Result[[]T, TimeoutError]`     |
| `echo v`                                | `fmt.Println(v)` (stringifies any value, appends a newline)    |
| `assert cond`                           | `hive.Assert(cond)`                                            |
| `panic value`                           | `panic(hive.Show(value))` (renders `value` like `echo`)        |
| `T.Variant(a, b)`                       | `T(TVariant{Field0: a, Field1: b})` (positional: own then common) |
| `x is Result.Ok(v)` / `Result.Error(e)` | `x.IsOk()` + `v := x.Ok()` / `x.IsError()` + `e := x.Err()`    |
| `x is T.Variant(a, _)` (user ADT)       | type assertion; bindings read fields, `_` binds nothing        |
| `a is T.A(v) && p(v)`                   | short-circuiting `&&`; `v` reads through its accessor          |
| `using p` / `using p as csv separating by d` | `hive.ReadCSV(p, d)` → `Result[Table, TableError]`       |
| `using p as xlsx` / `as ods`            | `hive.ReadXlsx(p)` / `hive.ReadOds(p)` → `Result[[]Table, TableError]` |
| `using conn run q(...)`                 | `hive.SqlRows(conn, q(...), sqlRow_T)` → `Result[[]T, SqlError]` |
| `using conn run raw text`               | `hive.SqlQuery(conn, text)` → `Result[Table, SqlError]`         |
| `if <call> is Result.Ok(v)`             | `if _u := <call>; _u.IsOk() { v := _u.Ok()` (evaluated once)    |
| `if p && <call> is Result.Ok(v)`        | one nested `if` per `&&` test, so each has an init slot of its own (still evaluated once, still short-circuiting) |
| `"{a} and {b}"`                         | concatenation, non-`Str` pieces via `hive.ToStr`               |
| `[x, y] + [z]`                          | `hive.Concat([]T{x, y}, []T{z})`                               |
| `v1 == v2` / `v1 != v2` (vectors)       | `hive.VecEq(v1, v2)` / `!hive.VecEq(v1, v2)` (structural)      |
| `#Atom`                                 | `hive.Atom` constants + a generated `hive.InitAtoms` table     |
| `true` / `false`                        | Go `true` / `false` (the `Bool` type, not atoms)               |
| `a / b`, `a ** b`                       | `hive.DivInt`/`hive.DivFloat`, `hive.PowInt`/`hive.PowFloat` (see [edges](#arithmetic-at-the-edges)) |
| `a % b`                                 | `hive.ModInt`/`hive.ModFloat` (remainder; `% 0` returns 0)    |
| `len(v)` vector / `len(s)` Str          | `len(v)` (elements) / `hive.StrLen(s)` (UTF-8 runes)           |
| `bytes(v)` vector / `bytes(s)` Str      | `hive.Bytes(v)` (footprint) / `len(s)` (UTF-8 byte length)     |
| `append(v, x)` / `join(v, sep)`         | `v = append(v, x)` (statement) / `hive.Join(v, sep)`           |
| `split(s, sep)`                         | `hive.Split(s, sep)` → `Str[dyn]`                             |
| `row(t, k)` / `column(t, k)`            | `hive.Row(t, k)` / `hive.Column(t, k)` → `Str[dyn]`           |
| `hive.json.parse(t) with T`             | `hive.JsonParse(t, jsonDecode_T)` → `Result[T, JsonError]`     |
| `hive.json.encode(v)`                   | derived `jsonEncode_T(v)` (cannot fail, so plain `string`)     |
| `hive.json.table(t)` / `.get(tbl, p)`   | `hive.JsonTable(t)` / `hive.JsonGet(tbl, p)`                   |
| `hive.net.httpRequest(r)`               | `hive.HttpSend(r)` → `Result[HttpResponse, HttpError]`         |
| `hive.net.httpServe(port, handler)`     | `hive.HttpServe(port, handler)` (handler is any function value) |
| `hive.net.wsConnect(u)` / `.wsServe(p, h)` | `hive.WsConnect(u)` → `Result[WsConnection, WsError]` / `hive.WsServe(p, h)` |
| `hive.net.wsSend(c, m)` / `.wsReceive(c)` | `hive.WsSend(c, m)` → `Result[Int, _]` / `hive.WsReceive(c)` → `Result[Str, _]` |
| `hive.net.wsRequest(c)` / `.wsClose(c)` | `hive.WsRequest(c)` → `HttpRequest` / `hive.WsClose(c)`         |
| `hive.net.socketConnect(h, p)` / `.socketServe(p, h)` | `hive.SocketConnect(h, p)` → `Result[SocketConnection, SocketError]` / `hive.SocketServe(p, h)` |
| `hive.net.socketSend(c, d)` / `.socketReceive(c, n)` | `hive.SocketSend(c, d)` → `Result[Int, _]` / `hive.SocketReceive(c, n)` → `Result[Str, _]` |
| `hive.net.socketReceiveLine(c)`         | `hive.SocketReceiveLine(c)` → `Result[Str, SocketError]` (newline trimmed) |
| `hive.net.socketPeer(c)` / `.socketClose(c)` | `hive.SocketPeer(c)` → `Str` / `hive.SocketClose(c)`       |
| `f(mutVec)` (argument names `mut` storage) | `f(hive.CloneVec(mutVec))` (copied in, so the callee's `T` really is immutable) |
| `func f(v: T[]): T` at `T = Str`        | `func f_Str(v []string) string` (one copy per instantiation)   |
| `type Box { items: T[dyn] }` at `Str`   | `type Box_Str struct { Items []string }` (+ its own clone/codec) |
| `Result<T, E>`                          | `hive.Result[T, E]`; `Result.Ok(v)` → `hive.Ok[T, E](v)`        |
| `f` (bare reference)                    | `f` (the Go function value)                                    |
| `f(a, _, c)` (partial application)      | `func(h T) R { return f(a, h, c) }` (a closure; `_`→ parameter) |
| `hive.crypto.sha256/sha512(s)`          | `hive.Sha256/Sha512(s)` (lowercase-hex digest)                 |
| `hive.crypto.hmacSha256(s, k)`          | `hive.HmacSha256(s, k)` (hex) / `randomHex(n)` → `hive.RandomHex(n)` |
| `hive.crypto.base64Encode/Decode(s)`    | `hive.Base64Encode(s)` / `hive.Base64Decode(s)` → `Result`     |
| `hive.crypto.jwtSign(claims, secret)`   | `hive.JwtSign(jsonEncode_T(claims), secret)` → `Str`           |
| `hive.crypto.jwtVerify(t, s) with T`    | `hive.JwtVerify(t, s, jsonDecode_T)` → `Result[T, CryptoError]` |
| `hive.crypto.jwtDecode(t) with T` / `.jwtHeader(t)` | `hive.JwtDecode(t, jsonDecode_T)` / `hive.JwtReadHeader(t)` |
| `hive.sql.connect(d, s)` / `.pool(d, s, o, i)` | `hive.SqlConnect(d, s)` / `hive.SqlPool(d, s, o, i)`     |
| `hive.sql.close(c)`                     | `hive.SqlClose(c)`                                             |
| `hive.sql.DatabaseDriver.SQLite()`      | `hive.DatabaseDriver{Name: "sqlite"}` (also PostgreSQL/Other)  |
| `hive.conv.ceil/floor/round(f)`         | `hive.Ceil/Floor/Round(f)` → `Int`                            |
| `hive.conv.itf(i)` / `its(i)` / `fts(f)` | `hive.IntToFloat(i)` / `hive.IntToStr(i)` / `hive.FloatToStr(f)` |
| `hive.conv.sti(s)` / `stf(s)`           | `hive.StrToInt(s)` / `hive.StrToFloat(s)` → `Result[_, ConversionError]` |
| `hive.env.get(name)`                    | `hive.EnvGet(name)` → `Result[Str, EnvironmentError]` (.env, then OS)   |
| `hive.net.HttpRequest(m, u, h, b)`      | `hive.HttpRequest{Method: m, Url: u, Headers: h, Body: b}`     |
| `request.body` (builtin struct field)   | `request.Body` (fields capitalize to their exported Go names)  |
| `t[1:]`                                 | `t[1:]` (slices are **inclusive** of the high bound)           |
| `hive.syslink.listen(endpoint)`          | `hive.SyslinkListen(endpoint)` → `Result[Str, SyslinkError]`     |
| `hive.syslink.spawn(handler, state)`    | `hive.SyslinkSpawn(handler, state, dec, digest, repliesInTurn)` → `hive.Address` |
| `hive.syslink.register(#N, a)`           | `hive.SyslinkRegister(atom_N, a)` → `Result[Address, SyslinkError]` |
| `hive.syslink.at(#N)` / `.on(endpoint, #N)` | `hive.SyslinkAt(atom_N)` / `hive.SyslinkOn(endpoint, atom_N)`  |
| `hive.syslink.send(a, msg)` (statement) | `hive.SyslinkSend(a, clone_T(msg), enc, digest)` (a cast: copied in, never fails) |
| `h := hive.syslink.send(a, msg)`        | `hive.SyslinkSendAwaitable(a, clone_T(msg), enc, digest, dec)` → `*hive.SyslinkPending[M]` |
| `await h` / `await h with timeout ms`   | `hive.SyslinkAwait(h, 0)` / `hive.SyslinkAwait(h, ms)` → `Result[M, SyslinkError]` |
| `await [send(..), send(..)] with timeout ms` | `hive.SyslinkAwaitAll(ps, ms)` → `[]Result[M, SyslinkError]`  |
| `hive.syslink.answer(from, v)` / `.self(from)` | `hive.SyslinkAnswer(from, v, enc)` / `hive.SyslinkSelf(from)` |
| `hive.syslink.monitor(from, t, msg)`    | `hive.SyslinkMonitor(from, t, msg, enc, digest)`                |
| `hive.syslink.stop(a)` / `.node()`      | `hive.SyslinkStop(a)` / `hive.SyslinkNode()` → `string`         |
| `hive.syslink.Address` / `.Envelope`    | `hive.Address` / `hive.Envelope` (message type inferred, never written) |
| `Str`, `Int`, `Bool`, `Float`, `Atom`   | `string`, `int`, `bool`, `float64`, `hive.Atom`                |
| `Str[3]`, `Str[dyn]`, `Str[]`           | `[]string` (all vectors lower to slices)                       |
| `Table`, `hive.TableError`, `Result`    | provided by the generated `hive` runtime package               |

Codegen runs a lightweight type-inference pass over locals so overloaded
syntax picks the right lowering (`+` on vectors vs. strings vs. numbers, atom
→ `Str` coercions, zero-safe division, vector literal element types). The same
pass decides the constructs that have no honest lowering — indexing a `Str` is
the one that exists today — so they are rejected as Hive errors rather than
emitted as Go that either fails to compile or quietly means something else. Hive
requires every non-`void` `proc`/`func` to return on every path: a path
terminates by ending in `return`, in `assert` or `panic` (both handy for a tail
you know is unreachable, e.g. `assert false` or `panic "unreachable"`), in an
`if`/`else` whose every
branch terminates, or in an else-less `if`/`else if` chain that covers its
subject's whole type (a `Result`'s `Ok`+`Error`, or every variant of an ADT).
Anything else is a compile error. For an accepted function that doesn't
syntactically end in `return` (an exhaustive match), codegen still appends a
`panic("hive: unreachable")` to satisfy the Go compiler; it is now genuinely
unreachable. A Hive
identifier that happens to be a Go keyword but not a Hive one (a variable or
function named `map`, `range`, `select`, ...) is suffixed with `_` in the
generated Go — consistently at its definition and every use — so it never
collides with Go's own grammar.

## How the compiler is structured

```
src/hive.gleam            CLI entry point (build / run / emit dispatch)
src/hive/token.gleam      token definitions
src/hive/lexer.gleam      source text  -> tokens (strings, atoms, SQL bodies)
src/hive/ast.gleam        the abstract syntax tree
src/hive/parser.gleam     tokens       -> AST (recursive descent)
src/hive/modules.gleam    resolves the `import` graph (rejecting cycles) and
                          flattens the whole program into one module
src/hive/generics.gleam   monomorphization: one concrete copy of a generic
                          callable or type per set of type arguments it is
                          used at, so every later pass sees ordinary code
src/hive/bounds.gleam     flow-sensitive vector index/slice bounds checking
src/hive/codegen.gleam    AST          -> Go source (with local type inference)
src/hive/runtime.gleam    go.mod, the core Go `hive` runtime, and one Go
                          source per module written on demand — the `hive.*`
                          library plus the xlsx/ods readers
src/hive/compiler.gleam   glue: source -> Go source, purity checks for funcs
src/hive/cli.gleam        writes the Go project, drives the Go toolchain
```

Run the tests with `gleam test` (they include compiling every shipped
example).

## Scope

Per the project brief, the compiler currently targets exactly the constructs
that appear in `code-examples/`. The lexer, parser, and code generator are
written to be extended, but there is no full type checker and no standard
library beyond the `hive.*` modules and builtins documented above yet.

One exception is **vector bounds**: a dedicated flow-sensitive pass
(`src/hive/bounds.gleam`) proves every index and slice in range at compile
time, so the generated Go can never panic out of bounds. Indexing a static
vector with a literal is decided outright (`v[2]` on a `Str[3]` compiles,
`v[3]` does not); any access whose safety isn't known must be guarded so the
compiler can see it — `if i >= 0 && i < len(v) { v[i] }`, the condition of a
counting `for` loop, or a `for each`, which never indexes. The `bounds`
keyword is shorthand for that guard: `if v bounds i { ... }` means exactly
`if i >= 0 && i < len(v) { ... }`; an index that came from
[`indexOf`](#indexof-returns-an-index-you-can-use) needs no guard at all.
Anything the pass can't prove safe (a computed index, an unusual guard) is a
compile error rather than a runtime crash.

A **declared** length is a promise, not a hint. `Str[3]` means three, so every
value that lands in such a slot — an initialiser, a later assignment, an
argument, a **field of a constructed value**, a returned value, a row written
into a `Str[2][2]` — has to be a
vector of exactly that many elements, and a length the compiler can't see is
rejected too:

```hive
mut Str[3] v = ["a", "b", "c"]
v = ["x", "y", "z"]              // fine — still three
v = ["x"]                        // compile error: `v` is declared `Str[3]`
Str[3] parts = split(line, ",")  // compile error: that length isn't known
```

Because the promise is kept everywhere, a declared length is never lost: `v[2]`
above stays legal after the reassignment, and a `Str[3]` parameter can be
indexed inside the callee without a guard, since every call site was checked.
The escape, as always, is `[dyn]`: `Str[dyn]` promises nothing and guards its
indexes.

Because keeping a promise means keeping it at *every* call site, a callable with
a statically-sized parameter is restricted as a **value**. It may be bound to an
immutable name — a bare reference or a partial application — and called through
it, and those calls are checked exactly as direct ones are:

```hive
proc takes(v: Str[3]): void { echo v[2] }

f := takes
f(["a", "b", "c"])               // fine
f(["a"])                         // compile error: `f` holds a `Str[3]` taker
```

It may not be handed on any further — passed as an argument, returned, stored in
a vector or a field — because the eventual call would happen somewhere with no
idea what was promised. The same reason rules out a `mut` holder, which could be
pointed at a different callable after the fact. Declaring the parameter `Str[dyn]`
or `Str[]` lifts every one of these restrictions, at the cost of guarding the
index inside the callee.

A vector inside a **struct** is a vector like any other, with the same
guarantees. A `Str[3]` field is enforced wherever a value reaches it — including
at construction — and so can be indexed unguarded; a `Str[dyn]` field guards its
indexes, and replacing the field (`b.items = …`) costs it whatever had been
proven about the old value, exactly as rebinding a variable does:

```hive
type Box { items: Str[dyn] }

mut b := Box(["a", "b", "c"])
if 2 < len(b.items) {
    b.items = ["one"]
    echo b.items[2]              // compile error: that proof died with the old value
}
```

An **inferred** length is weaker, because nothing constrains what comes next:
`mut v := ["a", "b", "c"]` knows it holds three today, and keeps that through
writes *through* the name (`v[i] = x` swaps an element without changing the
length, `append(v, x)` only grows it), but loses it the moment the name is
rebound — including in a branch or loop body that may not even run:

```hive
mut v := ["a", "b", "c"]
if changed { v = ["x"] }
echo v[2]                   // compile error: v's length is no longer known
```
