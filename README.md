# Hive

**Hive** is a memory-managed, table-based language. Tables are a built-in idea
rather than a library, values behave like values, and a good deal of what other
languages leave to runtime — every vector index, every branch of a match, the
columns a SQL query comes back with — is settled at compile time instead.

This repository is its compiler, written in [Gleam](https://gleam.run). It
lowers Hive source to Go and invokes the Go toolchain, which produces a native
executable for the current platform. You never write or read that Go, but a few
of Hive's rules make more sense once you know what they become — see
[How Hive maps onto Go](#how-hive-maps-onto-go).

New here? [`docs/tour.html`](docs/tour.html) is a slow, one-idea-at-a-time tour
of the whole language (in English and Portuguese). This README is the reference:
organised by feature rather than by lesson.

```
hive build <entrypoint.hive>   # compile to a native executable
hive run   <entrypoint.hive>   # compile and run
hive check <entrypoint.hive>   # report any errors, without building anything
hive emit  <entrypoint.hive>   # print the generated Go (handy for debugging)
```

Errors are reported as `file:line: message`, so an editor can jump straight to
one — see [Editor support](#editor-support).

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
(`foo.exe` on Windows, `foo` elsewhere) and leaves the intermediate project in
`foo.hive-build/` for inspection. `hive run` produces **no** executable in your
project — the binary lives only in the build cache — which is why it is the
better default on Windows (see below). It runs with the working directory set to
the entrypoint's folder, so relative paths such as `using "./test.csv"` resolve
as the author expects. Anything after the entrypoint is forwarded to the program
as its own command-line arguments (`hive run foo.hive a b c`), readable via
`hive.term.args()`.

`hive test foo.hive` runs the program's [tests](#testing) and reports coverage;
it exits non-zero if any test failed, so it is the thing a commit hook or a CI
step runs. `hive check foo.hive` runs every compiler pass and builds nothing,
which is what an editor wants — and unlike `build` and `run` it asks for no
entrypoint, since a file holding only tests, or only declarations for another
file to import, is a perfectly good file.

### Troubleshooting on Windows

If a **built** executable (`hive build`, then `.\foo.exe`) produces **no output
at all** (or crashes with an `Eacces` / "Application Control policy has blocked
this file" error), Windows is very likely blocking the freshly-compiled `.exe`
before it can start — the program never runs, so none of its `echo`s appear.
This is Windows Defender's real-time protection or SmartScreen/Application
Control scanning a brand-new unsigned binary; it is unrelated to your code, which
behaves the same on Windows and Linux. To confirm and work around it:

* Prefer `hive run`, which never writes an `.exe` into your project, so there is
  no fresh binary for Defender to intercept.
* Add a Windows Defender **exclusion** for your project folder (Settings →
  Privacy & security → Windows Security → Virus & threat protection →
  Manage settings → Exclusions), or build into an already-excluded directory.
* `hive emit foo.hive` produces no executable at all, which is handy while a
  block is being sorted out.

## Editor support

Every error the compiler reports opens with where it happened:

```
code-examples/2 - Types/types.hive:41: expected `]` but found `,`
```

That is the shape editors expect, so wiring one up needs nothing more than a
compile command and a pattern to read its output with. In Vim or Neovim:

```vim
setlocal makeprg=hive\ check\ %:S
setlocal errorformat=%-G\ %.%#,%f:%l:\ %m,%-G%.%#
```

`hive check` runs every compiler pass and stops before the Go toolchain, so it
answers as fast as the Hive front end does and writes nothing next to the file —
which is what makes it usable on every save. `:make` then fills the quickfix
list, and `:cn` walks the errors.

The two `%-G` items discard what is not a diagnostic: the first drops the
indented continuation lines of a message that runs on (so one error stays one
entry), the last drops everything else.

Two limits worth knowing:

* **Errors from the passes after parsing land on line 1.** Mutability, bounds,
  the proc/func split and the type checks all run on a flattened module whose
  nodes carry no source positions yet, so the file is as precise as they get.
  The message names the declaration it is about.
* **In a program with imports, those same errors are reported against the
  entrypoint**, even when the declaration at fault came from an imported
  module — flattening is what discards which file each declaration came from.
  Errors the lexer, parser and import resolver raise do name the right file and
  line, because those run per file.

## A taste of Hive

The three kinds of callable — a `func`, a `proc` and an inline SQL `query` — and
what a call site can decide to do with one, in one program:

```hive
type Greeting {
	Formal { title: Str }
	Casual
}

// A `func` may perform I/O, but it can't call a `proc` or declare a mutex
// parameter.
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

// Nothing about a declaration says how it runs: every call blocks its caller,
// and a call site that does not want to wait says so with `async`.
func slowShout(text: Str): Str {
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

	async slowShout("fire-and-forget")   // its own thread; no result to read
	echo slowShout("waited for")         // blocks until the value is ready
}
```

Running it prints:

```
Good evening, Dr. Grace.
Hey Linus!
first up: Grace
waited for!!!
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
walkthrough (hashing, HMAC, encryption, base64 and JWTs), an encrypted
command-line password manager whose master password never appears on screen —
with a suite of its own, run by `hive test` — a `hive.sql` example backed by an
embedded SQLite database, a tour of first-class functions and partial
application, a tour of Hive's copy-on-binding [value
semantics](#value-semantics-copy-on-binding), a tour of concurrency
(firing a call off, waiting for one, and waiting for many at once), a two-node
[`hive.syslink`](#hivesyslink) program whose services talk to each other across
two terminals or two machines, a three-node distributed cache that combines
`hive.syslink` with `hive.sql` (one owner per key, invalidated across the cluster
on every write), a three-file program
showing `import`, a walk through spreadsheets and `hive.file`, and a serverless
chat between two nodes whose [`hive.ui`](#hiveui) windows publish themselves as
[`hive.syslink`](#hivesyslink) services and post straight to each other — live in
`code-examples/`. They double as the language's specification: each one
compiles, builds and runs.

## The language

* **`test`** — a unit test, named in prose: `test "an empty cart costs nothing"
  { ... }`. It is run by [`hive test`](#testing), never called, so it takes no
  parameters and returns nothing. Its body is an ordinary `proc` body, and
  `assert` inside it records a failure instead of stopping the program.
* **`proc` / `func` / `query`** — both `proc`s and `func`s may
  perform I/O: `echo`, reading files with `using`, and `hive.net` are all
  allowed in either. A `func` differs from a `proc` in exactly two ways: it
  cannot declare a mutex parameter (`v: mut T` — a `mut` value passed to a func
  is seen as an ordinary immutable copy instead), and it cannot call a `proc`
  (only procs call procs). A `query` is a func whose body is inline SQL and whose
  return type describes its **rows** — see
  [typed queries](#queries-are-typed-by-their-rows). An interpolated `{param}`
  never enters the SQL text: it becomes a placeholder and the value is bound
  alongside it. **Nothing about a declaration says how it runs**: every call
  blocks its caller, and the *call site* decides otherwise — see the concurrency
  bullet below. Programs start at
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
  (`Str[dyn]`). Which of the two a name holds is what its **declaration** says,
  never what its value happened to show: a `:=` binding always infers a *static*
  length, so a dynamic vector has to be written out (`mut Str[dyn] v = [...]`).
  That is also exactly what `append` requires, since a static length is a promise
  it could not grow out of. A static length is
  enforced, not advertised: a `Str[3]` slot only ever takes a vector of three,
  wherever the value comes from (see
  [vector bounds](#scope)), which is what lets `v[2]` on one compile with no
  guard. A third spelling, `Str[]`, is a **parameter** spelling: it promises
  nothing about the length and accepts any vector of the right element type, so
  one helper serves callers holding a `Str[3]` and a `Str[dyn]` alike. That is
  the whole of where it is legal. A **return** has to say which kind it is
  (`Str[dyn]` or `Str[3]`), because a return is where the caller is told what it
  is getting, and the two are different answers: one guards every index, the
  other indexes freely. `Str[]` and `Str[dyn]` would be the *same* answer there —
  which is the reason to keep only one spelling of it, since two invite the
  reader to hunt for a difference that isn't there. What *names storage* —
  a variable or a field — has to say which of the two real kinds it is, since a
  promise is the only thing an index can rest on. All of them lower to Go
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
  parameter or a plain `:=` binding is a compile error. A mutex passed into such a
  parameter is **copied** on the way in, so the callee's immutable view really is
  one: it cannot see the caller's later writes, whether the two run in sequence
  or — for an `async` call — at the same time.

  A `proc` — and only a `proc` — may ask for the mutex *itself*, by writing the
  parameter `v: mut T`. The argument then has to be a `mut` variable, or a path
  into one, and what the callee gets is that storage rather than a view of it: it
  may reassign it, write its elements, and `append` to it, and every one of those
  is visible through the caller's name afterwards. **Whether it shares depends on
  the call site, not the declaration**: a call you wait for hands over the
  caller's storage, and an `async` or `await`ed one hands over a copy — a thread
  of its own gets storage of its own, which is what keeps a fired-off call from
  racing the caller it was fired off from. `mut` cannot appear anywhere else a
  type can: not on a field, not on a return, not in a `proc(...)` type. Each of
  those binds nothing, and a function value has no call site to take a mutex from,
  so a callable with one can be neither referenced (`f`) nor partially applied
  (`f(1, _)`).
* **Concurrency** — **every call blocks its caller.** Nothing about a
  declaration says otherwise, so there is no `async func`, no Future and no
  Promise type to name; what a call means is decided where it is written:
  * `f(x)` waits for it and yields `T`. It costs neither a goroutine nor a
    channel — it is a function call.
  * `async f(x)`, as a **statement**, runs it on its own virtual thread (a
    goroutine) and carries on. Fire-and-forget is the whole of what it is:
    nothing comes back, so `async` has no value and cannot appear where one is
    wanted. That is what leaves no handle to hold, to pass, or to leak out of the
    scope that started it — and why the language needs no type for one. It works
    on any call: a `func`, a `proc`, a `query`, the standard library, a
    [service](#hivesyslink). What it refuses, it refuses by name — a global
    builtin (`len`, `append` and the rest exist for the value they hand back, so
    firing one off would leave nothing of it), a constructor (it builds a value
    and runs no body), and a partial application (`f(1, _)` makes a function
    value; nothing runs until something calls it).
  * `await [f(a), f(b), f(c)]` is the **await-all**, and the only `await` there
    is: every call in the list starts on its own thread and the whole list is one
    barrier, resolving *in order* to a statically-sized, fully-typed vector of
    their results (`Str[3]`) — never a dynamic or `Any` vector. Three calls that
    each take a second take about a second. A list of one is legal and still
    means "on its own thread, then wait". Over `void` calls the barrier has no
    value either, and is a statement meaning "both of these, then carry on".
    Every entry has to be a call (a value already in hand has nothing to wait
    for) and they all have to answer with the same type, since one barrier
    resolves to one vector.
  * Work of **different types** is waited for one call at a time — each of those
    is an ordinary blocking call, so it costs the sum rather than the slowest,
    which is exactly what the writing says it does.

  Any wait may be bounded with the optional [`with timeout <ms>`](#hivetask)
  clause, which turns its result into a `Result<T, hive.task.TimeoutError>` — on
  an await-all it is one deadline across the whole barrier. The timeout abandons
  the waiting, not the work. See `code-examples/10 - Concurrency`.
* **Distribution** — [`hive.syslink`](#hivesyslink) adds *services*: long-lived,
  addressable things with a mailbox and private state, reached by the same
  statement whether they live in this process or on another machine.
  Calling the address — `address(message)` — is the only way to reach one, and —
  as with a func — the call site decides what it means: written plainly it waits
  for the service's answer and yields
  `Result<Message, hive.syslink.SyslinkError>`, and `async address(message)` is
  the send that waits for nothing and cannot fail. A service answers with one of
  its own messages, so the reply type is the mailbox type and nothing needs
  annotating. A *service* is named by an atom, which is what lets the compiler
  know the whole registry; a *node* has no name at all — it is identified by the
  endpoint it can be dialed at, so a peer list is ordinary runtime data. An
  address is an ordinary value that outlives every scope, can be stored, and can
  travel inside a message — which is the difference between a service and a call
  you did not wait for, since `async f(x)` keeps nothing at all. Its handler is a
  fold over the mailbox (`proc (State, Message, hive.syslink.Envelope): State`),
  so a service needs no mutex at all. A service name is an atom, which is what
  lets the compiler know the whole registry — and a named address is the only
  kind that survives its service being restarted. A node has no name: it is
  identified by the endpoint it can be dialed at, so a peer list is ordinary
  runtime data. A `panic` inside a service kills only that service, not the node.
* **Atoms** (`#SomeAtom`) are interned symbols. The compiler assigns each a
  small integer and embeds the atom table in the executable, so `echo` prints an
  atom's name while coercion to `Str` yields its decimal value. **`#Nil` is the
  only atom the language provides**, and it is always the first on the table, so
  `"0" + #Nil == "00"`. Every other atom exists only because your program
  mentioned it, and lands wherever its first mention puts it. An atom is **not**
  a condition: it is a label, not a yes
  or a no, so `if flag` is a compile error. Compare it with the one you mean —
  `if flag == #Ready` — or use a `Bool`.
* **Booleans** — `Bool` is a real boolean type (Go `bool`); its literals are
  `true` and `false`. Comparisons and `&&`/`||` produce `Bool`, and a `Bool`
  field or value holds `true`/`false`.
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
  A variable is pinned down by wherever it appears in the parameters — including
  *inside* a parameter's own type, which is what makes a higher-order generic
  work: in
  `func filterMap(values: T[], transform: func(T): Result<K, E>): K[dyn]`
  the call says what `T` is by the vector it passes and what `K` and `E` are by
  the function it passes. The body may write those variables down too
  (`mut K[dyn] out = []`, `for each v: T in values`, `Box<T> b = ...`); each copy
  substitutes through its own body.
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
  the one-argument handler `serve` expects.

  A **constructor** may be partially applied too, and it means the same thing:
  `Msg.Changed(_)` is a `func(Str): Msg` that builds the variant. It is not a
  callable — there is no body to run and no declared return type to read — but
  each `_` still becomes a parameter in hole order, everything supplied is still
  captured where it was written, and what comes back is typed as the union,
  since that is what a variant is once built. This is the spelling a
  [`hive.ui`](#hiveui) event attribute wants: `ui.onInput(Msg.Changed(_))`.

  The `proc`/`func` split is
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
* **Names have shapes, and a name's shape says what it is.** Keywords are lower
  case and only lower case: `PROC` is not `proc`, and it is not a name either —
  a keyword is reserved however it is spelled. Everything else follows what it
  names:
  * `camelCase` — variables, parameters, fields, every `proc`, `func` and
    `query`, and the name an `import` is reached through, which reads as the
    variable it stands in for.
  * `UPPER_CASE` — a variable that is never reassigned, which is how a constant
    is written. A `mut` variable may not be written this way, nor may a loop
    counter, which is one.
  * `PascalCase` — types, their variants and atoms: `User`, `Result.Ok`,
    `#Ready`. The types the language declares are spelled no differently from
    yours, so `Str` is a type and `str` is not.

  A name may open with a single `_` — `_scratch`, `_helperOf`, `_MAX` — an
  informal note that it is private, or is here only because something had to be.
  The compiler asks nothing of the prefix and offers nothing for it. On its own,
  `_` is the binding that throws its value away.

  SQL keeps its own convention rather than Hive's: inside a `query` body the SQL
  keywords are **upper case** (`SELECT`, `FROM`, `WHERE`), and everything else
  in there is a name the database chose, which keeps whatever spelling it has
  over there. One that collides with a keyword says so the way SQL always has —
  in quotes: `SELECT "order" FROM ...`.

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
mut Str[dyn] a = ["x", "y", "z"]
mut Str[dyn] b = a
append(b, "w")            // len(a) is now 4
if 0 < len(a) {
	a[0] = "changed"      // b[0] is "changed" too
}
b = ["replaced"]          // rebinding one rebinds both; len(a) is 1
```

Two independent slice variables could not deliver that — `append` returns a *new* slice
header, so growing one name would quietly stop the two from sharing, or not,
depending on whether the backing array happened to have spare capacity. So the
second name is not given a variable at all: it compiles to the first, and there
is one slice header for both. The one case this does not cover is a source that
does not name the same storage every time it is read — `mut b = a[i]` can be a
different element each time `i` moves — so that binding keeps a header of its
own.

Passing a mutex into an ordinary `T` parameter is the opposite case and always
**copies** (see [Mutability](#the-language)): the callee is handed an immutable
`T`, and it would not be one if the caller could still write to it.

A `mut T` parameter is the third case, and the only one where storage crosses a
call boundary on purpose:

```hive
proc grow(vec: mut Str[dyn], tag: Str): void {
	append(vec, tag)
}

proc main(): void {
	mut Str[dyn] v = ["a"]
	grow(v, "b")          // waited for: v is now ["a", "b"]
	async grow(v, "c")    // fired off: the thread grows a copy; v is untouched
}
```

It lowers to a pointer (`vec *[]string`), because a shared backing array would not
survive `append` — that returns a *new* slice header, and the caller has to see the
new one. Reads and writes in the callee go through it (`(*vec)`), which is the same
machinery `mut b = a` uses one scope down: the name is an expression, not a
variable of its own.

The `async` half needs the copy to be made on the **caller's** side of the fence,
so the argument is bound to a temporary first and the callee is handed *its*
address:

```go
{ _a0 := hive.CloneVec(v); go grow(&_a0, "c") }
```

The same applies to a call inside `await [...]`, and to a mutex call nested in a
spawned call's arguments (`await [twice(grow(v, "b"))]`) — that one is hoisted out
and run in the caller, since running it on the new thread would be the very race
the copy exists to prevent.

One consequence for the [bounds pass](#scope): a
callee holding a mutex may rebind the vector to a shorter one, so passing a
variable to a `mut` parameter costs it every length and index fact already proved
about it.

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
argument type. A declaration of your own with one of these names
[wins](#a-declaration-of-your-own-wins), and the builtin stays reachable as
`hive.<name>`.

| Function                | Signature                    | What it does                                                         |
| ----------------------- | ---------------------------- | -------------------------------------------------------------------- |
| `len(vector)`           | `len(T[]): Int`              | Number of elements in a vector.                                      |
| `len(str)`              | `len(Str): Int`              | Number of **characters** (UTF-8 runes) in a string.                  |
| `bytes(vector)`         | `bytes(T[]): Int`            | Byte footprint of a vector's contiguous storage (count × elem size). |
| `bytes(str)`            | `bytes(Str): Int`            | Number of **bytes** in a string's UTF-8 encoding.                    |
| `append(vector, value)` | `append(T[dyn], T): void`    | Grows a **mutable** dynamic vector in place with one more element.   |
| `join(vector, sep)`     | `join(Str[], Str): Str`      | Concatenates a `Str` vector into one string, `sep` between elements. |
| `split(str, sep)`       | `split(Str, Str): Str[dyn]`  | Splits a string on `sep` into a `Str` vector (inverse of `join`).    |
| `indexOf(vector, value)`| `indexOf(T[], T): Result<Int, Bool>` | Position of the first element equal to `value`, else `Error(false)`. |
| `indexOf(str, sub)`     | `indexOf(Str, Str): Result<Int, Bool>` | Position, in characters, of the first occurrence of `sub`, else `Error(false)`. |
| `row(table, key)`       | `row(Table, Str): Str[dyn]`  | The row whose first cell equals `key`, else `[]`.                    |
| `column(table, key)`    | `column(Table, Str): Str[dyn]`| The column whose top (first-row) cell equals `key`, else `[]`.      |
| `map(values, transform)`| `map(T[], func(T): K): K[dyn]` | Every element, transformed. Same length, same order.                 |
| `filter(values, keep)`  | `filter(T[], func(T): Bool): T[dyn]` | The elements `keep` says yes to, in order.                      |
| `filterMap(values, transform)` | `filterMap(T[], func(T): Result<K, E>): K[dyn]` | Transform and select in one pass: the `Ok` payloads. |
| `sort(values)`          | `sort(T[]): T[dyn]`          | The elements in their own type's order. Discarded on a `mut` vector, sorts [in place](#sorting-in-place). |
| `sort(values, first)`   | `sort(T[], func(T, T): Bool): T[dyn]` | The elements in the order `first` gives.                    |

### A declaration of your own wins

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

A **local binding** shadows a builtin the same way (`filter := addN(1, _)` then
`filter(41)`), and so does a parameter. Shadowing is **per module**: another
module's declarations are only ever reached through its alias (`text.map(...)`),
so a `map` declared in one file leaves every other file's bare `map` alone.

Two things follow from the builtin being a distinct thing rather than a fallback.
Only the builtin `append` requires a `mut` target — a declared `append` is an
ordinary callable whose first argument is nothing special. And only the builtin
`indexOf` hands back an index the [bounds pass](#indexof-returns-an-index-you-can-use)
will accept unguarded; a declared one promises nothing, so its result is guarded
like any other integer.

Compiler-generated code uses the long name for this reason: `v bounds i` desugars
to `hive.len(v)`, so the guard means the same thing in a program that has taken
`len` for itself.

`len` and `bytes` differ only for strings: for `"café"`, `len` is `4` (runes)
while `bytes` is `5` (the `é` is two bytes). `append` is the one builtin that
*requires* its target to be `mut`, and it must also be **declared** `[dyn]`: it is
the in-place way to grow a `Str[dyn]`, while `+` builds a brand-new vector.
(`sort` is the one builtin that *notices* a `mut` target without requiring one —
see [sorting in place](#sorting-in-place).) `row` and `column` look a
value up in a `Table` by its first cell — `row` matches a row's first element,
`column` matches a column's top (first-row) cell — and `column` skips any row
too short to reach the matched column.

### Walking a vector: `map`, `filter`, `filterMap`

These three take a vector and a [function value](#the-language) over its
elements, and each hands back a new vector:

```hive
func double(n: Int): Int  { return n * 2 }
func isEven(n: Int): Bool { return n % 2 == 0 }

func asPort(s: Str): Result<Int, Bool> {
    parsed := hive.conv.sti(s)
    if parsed is Result.Ok(n) && n > 0 && n < 65536 {
        return Result.Ok(n)
    }
    return Result.Error(false)
}

proc main(): void {
    Int[dyn] nums = [1, 2, 3, 4]

    echo len(map(nums, double))            // 4 — every element, doubled
    echo len(filter(nums, isEven))         // 2 — the ones that passed
    echo len(map(nums, double(_)))         // a partial application works too

    // `filterMap` transforms *and* selects: an `Ok` carries the element's new
    // value, an `Error` says it has no place in the output. One pass, and the
    // things that failed to convert simply are not there.
    Str[dyn] raw = ["8080", "nope", "443"]
    Int[dyn] ports = filterMap(raw, asPort)
    echo len(ports)                        // 2
}
```

The function is a `func`, never a `proc`. A walk says nothing about the order its
function runs in or how often, so there is nowhere to hang a side effect — and
that is also what lets a `func` body use one. To walk a vector with a proc, write
a `for each` loop, which does say.

Each of the three is specific about what its function answers with, and a
mismatch is a compile error rather than a Go one: `filter` wants a `Bool`,
`filterMap` a `Result`, and `map` wants *something* (a `void` function collects
nothing — that too is a `for each` loop).

`map` is **length-preserving**, and the [bounds pass](#scope) knows it: mapping a
vector whose length is known gives a vector of that same length, whoever the
transform is. So the result is indexed on the same terms the input was, and it
keeps a declared length's promise:

```hive
Int[2] v = [1, 2]
doubled := map(v, double)
echo doubled[1]                 // no guard — a `map` of two is two
Int[2] fixed = map(v, double)   // fills a declared `Int[2]` slot
Int[3] wrong = map(v, double)   // compile error: that is two elements, not three
```

`filter` and `filterMap` are **not**, and deliberately claim nothing. What is
knowable about them is a *maximum* — they select from their input, so no more
comes out than went in — and a maximum can never put an index in range, because
a filter that keeps nothing is always a possibility. Their results are guarded
like any other vector of unknown length, even when the input's length was known.

#### A walk is sequential

A walk calls its function once per element, in order, on the calling thread. It
is never quietly concurrent: nothing in `map(urls, fetch)` says how `fetch` runs,
and a builtin is the last place a program should hide a decision like that.

To run a batch of calls together, write the [await-all](#the-language) — which is
also where the count of them lives:

```hive
func fetch(url: Str): Str { ... }

bodies := map(urls, fetch)                        // one at a time, in order
Str[3] some = await [fetch(a), fetch(b), fetch(c)] // all three at once
```

The vector goes in the way it would go into any `T[]` parameter, so the copy
rules of [value semantics](#value-semantics-copy-on-binding) apply unchanged: a
`mut` vector is copied in, and the elements the new vector holds are its own.

Like every builtin, these yield to a declaration of your own and stay reachable as
`hive.map` / `hive.filter` / `hive.filterMap` — see
[A declaration of your own wins](#a-declaration-of-your-own-wins).

### Putting a vector in order: `sort`

`sort` hands back a new vector holding the same elements in order. The original
is never touched — sorting in place would be visible through every other name
for the same storage, and vectors are
[values](#value-semantics-copy-on-binding).

```hive
func longerFirst(a: Str, b: Str): Bool { return len(a) > len(b) }

proc main(): void {
    Str[3] words = ["pear", "apple", "fig"]

    echo join(sort(words), "|")              // apple|fig|pear
    echo join(sort(words, longerFirst), "|") // apple|pear|fig
    echo join(words, "|")                    // pear|apple|fig — untouched
}
```

**One argument** orders elements by their own type's order. Every type has one
except those there is no honest order for:

| element | order |
| ------- | ----- |
| `Int`, `Float` | numeric, ascending |
| `Str`   | by UTF-8 byte order, which for text is code point order |
| `Bool`  | `false` before `true` |
| `Atom`  | by its **compiled value** — the small integer the compiler assigned it, which is its identity; a name is for logging, not for computing with. That value is wherever the atom's first mention put it, so add an atom above an existing one and a sorted vector of them reorders |
| a vector, a `Table` | lexicographic by element, and on a shared prefix the shorter one first |
| `Result<T, E>` | every `Error` before every `Ok`; two of a kind by their payloads |
| a struct | field by field, in declaration order — the first field they differ on decides |
| a tagged union | by **variant** first, in the order the variants were declared, then by that variant's fields |
| a function value, a service address | none — a compile error, naming the part at fault |

The ordering is chosen by the element's static type and emitted inline, the same
way a deep copy is: no runtime reflection, no boxing, no dispatch. A struct or
union gets a generated `less_T` alongside its `clone_T`, and a type that reaches
back into itself is ordered by that very function.

**Two arguments** order by a `func` of your own, which answers whether its first
element comes before its second:

```hive
func byAge(a: User, b: User): Bool { return a.age < b.age }

sorted := sort(users, byAge)
byName := sort(users, olderThan(_, _))   // a partial application works too
```

That is also the answer for an element type with no default order — anything can
be sorted once you say how. As with a walk, the function is a `func`, never a
`proc`: a sort says nothing about how many comparisons it makes or in what order,
so there is nowhere to hang a side effect. Nor is there anything to gain from
running the comparisons concurrently: a sort chooses each comparison from how the
last one answered, so there is never more than one call to make.

The sort is **stable** — elements neither of which comes first keep the order
they arrived in. That is what makes `sort` a function of its input alone even
when the ordering is partial (a comparator that only looks at one field says
nothing about two rows sharing it) or inconsistent (one that contradicts itself
still gives the same answer for the same input, rather than whatever the pivots
happened to do).

Both forms are **length-preserving**, exactly as
[`map`](#walking-a-vector-map-filter-filtermap) is: a comparator decides where
elements land, never how many there are. So `sort(v)` on a `Str[3]` is three
elements, indexable on the same terms `v` was, and it fills a declared `Str[3]`.

#### Sorting in place

A `sort` written as a **statement** throws away the vector it answers with. When
the vector it was given is `mut`, that is taken at its word: the storage is
reordered where it lies, with no copy at either end.

```hive
mut Str[dyn] names = ["pear", "apple"]

sort(names)                  // in place — `names` is now sorted
sorted := sort(names)        // NOT in place — a new vector, `names` untouched
```

Both conditions have to hold, and each is doing work:

* **Discarded.** A `sort` whose value is kept has to keep answering with a new
  vector, or `b := sort(a)` would quietly reorder `a` as well.
* **`mut`.** That storage an immutable binding can see is never rewritten
  underneath it is the invariant all of
  [value semantics](#value-semantics-copy-on-binding) rests on.

And a discarded `sort` that *can't* sort in place is a **compile error**, not a
statement that quietly does nothing:

```hive
Int[dyn] v = [3, 1, 2]
sort(v)                  // compile error: `v` is not `mut`
sort(split(line, ","))   // compile error: nothing to sort in place
```

Both would sort a copy and drop it the instant it was made — dead code wearing
the exact shape of the form that works. The fix is whichever you meant: declare
the vector `mut` to sort it where it lies, or keep the answer.

The subject can be any `mut` storage, not only a bare variable — `sort(b.items)`
and `sort(rows[i])` reorder the field and the row. And because an in-place sort
*is* a write, the copy-on-binding analysis counts it as one: in

```hive
mut Int[dyn] a = [3, 1, 2]
b := a          // copies, because...
sort(a)         // ...this rewrites `a`, and `b` must not follow
```

`b` gets a copy rather than aliasing `a`. Two `mut` bindings still share
completely, so sorting through either is seen through both.

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
document). Both readers are dependency-free, so a program that opens a workbook
still builds offline.

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
`hive.syslink.Address`, `hive.task.TimeoutError`, `hive.ui.View`, and so on. The only builtin types that live directly on `hive` are the core
ones the language uses without a module: `Result`, `Table` and the
`hive.TableError` that `using` yields from a CSV.

A module reached often can be given a **short name** with the same `import`
other files use — `import hive.ui` makes `ui.row(...)` mean `hive.ui.row(...)`.
It is a spelling and nothing more: both forms are always available and neither
changes what is built. See
[Importing a standard library module](#importing-a-standard-library-module).

**A module you don't use is not in your build.** The generated project always
carries the core runtime, but each `hive.*` module is written into it — and so
compiled and linked — only when the program actually references that module (see
`hive/runtime.gleam`'s module table and `hive/cli.gleam`). A module a used one
depends on internally comes along too: `hive.crypto` decodes JWT payloads with
`hive.json` and checks `exp`/`nbf` against `hive.time`, so reaching for a JWT
pulls in all three.

Every module but one is written against the target's standard library alone, so
HTTP, WebSockets, TCP, JSON, cryptography and spreadsheets all build offline with
no dependencies. `hive.sql` is the exception, and the only module that costs you
anything at build time: it links external database drivers, and a program that
never opens a connection neither downloads nor links them.

### `hive.net`

The networking library: HTTP, WebSockets and raw TCP, clients and servers.
Everything here performs I/O, so — like `echo` and `using` — it works inside a
`func` or a `proc`, and none of it adds a dependency to your build.

Each of the three servers blocks forever, so it usually goes on a virtual
thread of its own (`async serveForever()`), and each runs its handler once per
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

**Names, and where this machine is.** Two calls name no protocol, because they
are the network the other three are built on. A `hive.net.NetError`'s `reason` is
`"NotFound"`, `"Lookup"` or `"NoAddress"`.

* `hive.net.resolve(name)` resolves a host name to **every** address behind it →
  `Result<Str[], hive.net.NetError>`, in the order the resolver gave them —
  which is information rather than noise, since rotating the answers is how a
  name balances load. It takes a name, not an endpoint (`"cache-0.internal"`,
  never `"cache-0.internal:9100"`), and an address literal resolves to itself, so
  a program that accepts "either a name or an IP" from configuration need not tell
  the two apart before asking. A name nobody registered is a `"NotFound"` — the
  answer, not a malfunction — while a resolver that could not be reached at all
  is a `"Lookup"`.
* `hive.net.localAddress()` is the address other machines reach this one on →
  `Result<Str, hive.net.NetError>`: the source address the operating system would
  stamp on a packet leaving by the default route, which is what makes it the
  *right* interface on a machine that has several. Nothing is sent to find out.
  Loopback is deliberately not an answer — a machine holding only `127.0.0.1` has
  no address a peer could dial, and `"NoAddress"` is far more use than one that
  works right up until the other node turns out to be on another host.

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
* **Encryption** — `hive.crypto.encrypt(plaintext, password)` seals a string
  under a password with **AES-256-GCM** and returns it base64-encoded (sealing
  can't fail, so it is a plain `Str`);
  `hive.crypto.decrypt(ciphertext, password)` opens it again, returning
  `Result<Str, hive.crypto.CryptoError>`.

  The key is derived from the password with 600,000 rounds of PBKDF2-HMAC-SHA256
  over a random salt, and the salt and nonce are drawn afresh on every call — so
  the same text under the same password never encrypts alike, and an attacker
  pays that derivation on every password they guess at. GCM's authentication tag
  travels with the ciphertext, so a message edited after it was encrypted is
  rejected rather than opened into something else: it fails as
  `"BadSignature"`, which is also what a wrong password gives (the tag cannot
  tell you which of the two it was).
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

#### Optional filters: `WHERE { }`

Most "dynamic" queries are a fixed query with optional predicates, and that
needs no string building. A `WHERE` block ANDs the predicates whose conditions
hold; a nested `or { }` or `and { }` flips the connective. The block is written
in upper case, like the clause it becomes; what decides which predicates go into
it is Hive's own `if`, `and` and `or`, written like the rest of your program:

```hive
query findColonies(apiary: Str, minFrames: Int, small: Bool, huge: Bool): Colony[dyn] {
	SELECT name, apiary, frames FROM colonies
	WHERE {
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

Two things a `WHERE` block deliberately cannot do. A **column name or sort
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
  virtual thread: reached through an `async` call, the rest of the program keeps
  running on other threads while that goroutine waits. At end of input it
  returns whatever preceded EOF (`""` if nothing).
* `hive.term.readSecret()` is that same read with the terminal's echo turned off
  while it waits: a password is not left on the screen as it is typed, and the
  cursor moves to the next line when the user presses Return. It reads through
  the same input `read()` does, so everything above holds for it too — the
  parking, the `""` at end of input, and the line arriving stripped of its
  newline.

  The echo is put back before the call returns, and also if the program is
  interrupted at the prompt (which ends it with status 130, as an uncaught
  interrupt does) — a terminal is never left hiding what is typed into the shell
  that gets it back. Where there is no terminal at all — input redirected from a
  file, a job started without one — the line is read exactly as `read()` reads
  it, and only the hiding of it is lost. See
  [`code-examples/16 - EXAMPLE APP - Password Vault`](code-examples/16%20-%20EXAMPLE%20APP%20-%20Password%20Vault/vault.hive).
* `hive.term.args()` returns the command-line arguments the program was started
  with — in order, excluding the program name — as a `Str[dyn]`. `hive run`
  forwards anything after the entrypoint (`hive run app.hive a b c`), and a
  built executable receives them from the shell directly.

### `hive.task`

Scheduling controls over the virtual threads a call can be put on.

* **`with timeout <ms>`** bounds how long a wait may take. The clause is optional
  and may follow anything that waits — a call (`f(x) with timeout 500`) or an
  [await-all](#the-language) (`await [f(a), f(b)] with timeout 500`) — and it
  changes what that yields: without it you get the value, with it a
  `Result<T, hive.task.TimeoutError>` — running out of patience is a value to
  handle, not a crash. A `TimeoutError` carries `waited` (the milliseconds asked
  for) and a `message`. On an await-all the timeout is **one deadline
  across the whole barrier** (`await [f(a), f(b)] with timeout 500` means "both
  within half a second"), and the whole vector fails together.

  A timeout abandons the **waiting**, not the work: a virtual thread cannot be
  stopped from the outside, so the call runs on and only its result is dropped.

  ```hive
  if slowShout("worth waiting for") with timeout 100 is Result.Error(err) {
  	echo "gave up after " + hive.conv.its(err.waited) + "ms"
  }
  ```

  A `void` call has no value for the `Result` to carry, so bounding one is
  refused rather than lowered to a type with no spelling.

  On a [`hive.syslink`](#hivesyslink) request the clause folds into that module's
  own error instead of wrapping a second `Result` around the first, so
  `a(m) with timeout 250` is still a
  `Result<Message, hive.syslink.SyslinkError>` whose reason is `"Timeout"`.
  Omitted, syslink waits its own default (5s).

  `timeout` is not a reserved word — it means something only in this two-token
  clause, so it stays usable as an ordinary variable name.
* `hive.task.sleep(ms)` parks the calling virtual thread for `ms` milliseconds
  and returns nothing. Only that goroutine waits — others keep running — so two
  calls that each `sleep`, waited for together in one `await`, finish in about
  the longer of the two, not the sum. A non-positive `ms` returns immediately.

### `hive.syslink`

Addressable **services**, in this process or on another machine, reached by the
same statement either way. A service is long-lived, owns private state only it
can touch, and has an identity you can pass around.

A service is a different thing from a call you did not wait for, and the contrast
is worth spelling out:

| | `async f(x)` | `hive.syslink.Address` |
| --- | --- | --- |
| lifetime | as long as the call takes | unscoped — outlives everything |
| identity | none (there is nothing to hold) | yes, that is the point |
| interaction | none — it keeps nothing back | called with a message, and calling it *is* the send |
| as a value | it has none at all | ordinary value; can even be sent inside a message |
| result | none; to get one, wait for the call | `Result<Message, SyslinkError>` when you wait for it |

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
		mut Table next = rows
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
* `hive.syslink.peers()` is every node this one is connected to **right now**,
  each as the endpoint it advertised → `Str[]`, sorted. It keeps no bookkeeping of
  its own because a connection *is* the record: one pipe per node pair, filed
  under the peer's advertised endpoint whichever end opened it. So sending to a
  node puts it in the list, a node that dials in appears without this node doing
  anything, and losing the connection — a peer that quit, or one that stopped
  answering its health checks — takes it out again. Every entry is exactly what
  `on` takes, which is what makes this the answer to "who can I call later?".

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

**Messages: an address is called.** There is exactly **one** way to reach a
service — you *call its address* — and, as with a func, what the *call site* does
with it decides what it means. There is no `send` and no `call`: an
address is not a handle you pass to some function, it is the thing you call.

```hive
async inbox(Note.Say("hi"))          // send it, wait for nothing
answer := cache(Op.Count())          // send it and wait for the answer
answer := cache(Op.Count()) with timeout 250 // ...for at most 250ms
both := await [a(m), b(m)]           // send both, one barrier, one deadline
```

The callee's *type* is what makes this a send, never its spelling, so a local, a
parameter, a vector element and a fresh `at(#Name)` are all callable the same way
— and an address that shares a name with a declared func resolves to the address,
exactly as a local shadows a declaration everywhere else. An address carries one
message and nothing else: a second argument, a named argument, a missing message
and a partial application (`c(_)`) are each rejected by name, because each is a
mistake about what the value is.

* Written **plainly**, `address(message)` sends it and waits for the answer,
  yielding `Result<Message, hive.syslink.SyslinkError>`. This is the one place in
  the module that reports failure, because it is the only one
  with somewhere to report to: a `"Timeout"`, a service that died mid-request
  (`"Down"` / `"NoProc"`), an unreachable node (`"Unreachable"`), a payload that
  would not decode (`"Decode"`) and a request the service handled but never
  answered (`"NoReply"`) all arrive here.
* With **`async`**, the same call returns `void` and
  **never blocks and never fails.** A dead or unreachable recipient is not an
  error at the send site — that is precisely what keeps a local send and a remote
  one the same statement, and failure is discovered through a monitor instead.
  Nothing is registered for a reply, so this is also the cheapest form.
* An **[await-all](#the-language)** over sends is one barrier with one deadline,
  and spawns nothing at all: each send registers for its answer and returns, and
  the waiting happens on the connection's own reader.
* A **bounded** send folds the deadline into syslink's own error rather than
  wrapping a second `Result` around the first, so its reason is `"Timeout"`.
* **The reply type is the mailbox type**, so nothing is ever annotated. A service
  answers with one of *its own* messages, which makes a mailbox type the whole
  protocol — requests and responses together — and lets `is` narrow a reply
  exactly like anything else.
* Either way the message is copied on its way in, using the same deep,
  type-directed copy [a binding uses](#value-semantics-copy-on-binding), so the
  recipient can never observe the sender mutating it afterwards.
* `hive.syslink.answer(from, value)` replies to whoever is waiting. If the sender
  used `async` nothing is waiting, so it is a no-op — one handler serves both
  shapes without caring which it was.

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
* If the envelope goes anywhere else — stored in the returned state, handed to a
  call the handler does not wait for, passed to one of your own procs — a reply
  may genuinely still be on its way, and the runtime keeps waiting exactly as
  before. That is what makes the *deferred* reply possible: hand the envelope to
  an `async` call and the service's turn ends immediately without the caller
  being cut off.

```hive
// Answered or not, within the turn -> a forgotten reply fails immediately.
proc tidy(n: Int, m: Ask, from: hive.syslink.Envelope): Int {
	if m is Ask.Now { hive.syslink.answer(from, Ask.Reply("here")) }
	return n + 1                       // Ask.Later gets `NoReply` at once
}

// The envelope leaves the turn, so the answer is allowed to arrive later.
proc patient(n: Int, m: Ask, from: hive.syslink.Envelope): Int {
	async answerLater(from)            // replies when it is done; nothing waits here
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
pipe, so a node that can only dial out still takes part fully. A health check
runs every 15s, and each one that goes unanswered brings the next **forward** by
5s — 15s, then 10s, then 5s — so a node that has gone quiet is declared down
after 30s rather than the 45 three full periods would spend, failing its
outstanding calls and firing its monitors. Any frame at all counts as an answer,
and hearing from the peer puts the period back to full; the check itself is a
round trip (a tick, answered with a pong), because with both ends probing on
schedules of their own, "somebody spoke lately" cannot tell a live peer from one
whose period happens to miss the shrinking window being watched. The outbox is
unbounded — a bounded one would make
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

Not yet built: rejecting a mismatched message at the call site at compile time
(the registry knows each mailbox's type, but a wrong-typed message is caught by the digest
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

### `hive.ui`

User interfaces. A **view is a value** — a tree of widgets built by the calls
below — and what paints it is decided somewhere else entirely:

* `hive.ui.window(title, view, update, state)` opens a window on this machine
  and does not return.
* `hive.ui.html(view)` renders the same tree as a fragment of HTML, and
  `hive.ui.page(title, view)` as a whole document — which is what an
  [`httpServe`](#hivenet) handler answers with.

Nothing in a view knows which of those is happening, and neither has to be
chosen when the view is written. Everything here is written against the target's
standard library, so a program with a window still builds offline into one
executable with no dependencies.

**The window is a [service](#hivesyslink).** `update` is the same fold a
`hive.syslink.spawn` handler is — `proc (State, Message, hive.syslink.Envelope):
State` — and is checked as one, so a window has an address, needs no mutex, and
can be posted to by a background task or by another machine. That is also why
the module needs no notion of a *command*: `update` is a proc, so work that must
not block the screen is an ordinary call you did not wait for.

```hive
import hive.ui

type Msg {
	Refresh
	Loaded { rows: Table }
}

func view(model: Model): ui.View {
	return ui.column([ui.pad(16), ui.gap(12)], [
		ui.text([ui.size(ui.TextSize.Title())], "Orders"),
		ui.button([ui.on(Msg.Refresh()), ui.busy(model.busy)], "Refresh"),
		ui.table([], model.rows)
	])
}

proc update(model: Model, msg: Msg, from: hive.syslink.Envelope): Model {
	if msg is Msg.Refresh {
		async reload(hive.syslink.self(from))   // off it goes; nothing to hold
		return Model(model.rows, true)
	}
	if msg is Msg.Loaded(rows) {
		return Model(rows, false)
	}
	return model
}

proc reload(window: hive.syslink.Address): void {
	if using "./orders.csv" is Result.Ok(rows) {
		async window(Msg.Loaded(rows))
	}
}
```

**The view is a `func`, and that is not a formality.** A func cannot call a proc
and cannot hold a mutex, so drawing cannot act — which matters because a repaint
happens on every change, and anything a view did would happen again with it. A
proc handed to `window` is rejected by name.

**Every widget takes the same two things: its attributes, then its payload.**
There are no optional parameters in Hive, so what would be an optional argument
elsewhere is an entry in the attribute vector — and an empty one, `[]`, is an
ordinary value rather than a special case.

| Widget | Payload | Is |
| --- | --- | --- |
| `row(attrs, children)` | `View[]` | children laid out across |
| `column(attrs, children)` | `View[]` | children laid out down |
| `spacer()` | — | the gap that takes what is left |
| `overlay(attrs, child)` | `View` | drawn above everything, with a backdrop |
| `text(attrs, content)` | `Str` | the one true leaf |
| `image(attrs, src, alt)` | `Str, Str` | a picture, described |
| `icon(attrs, name)` | `Icon` | one of a closed set |
| `link(attrs, href, label)` | `Str, Str` | a destination, which needs no event to work |
| `button(attrs, label)` | `Str` | |
| `input(attrs, value)` | `Str` | one line; `kind` says which sort |
| `textarea(attrs, value)` | `Str` | several lines |
| `checkbox(attrs, label, checked)` | `Str, Bool` | label included, and clickable |
| `select(attrs, options, chosen)` | `Str[], Str` | |
| `table(attrs, rows)` | `Table` | the headered `Table` everything else hands back |
| `spinner(attrs)` | — | |
| `none()` | — | nothing — and it keeps its place among its siblings |

Sixteen, and the rule that decided the number: a widget is here only if it
cannot be composed from the others *and* needs something the renderer has that
Hive does not. A card is a `column` with padding, a toast is an `overlay` and a
message, a divider is a `row` with a border — all of those are `func`s you
write, which is also the proof that the set is enough.

`table` takes a headered `Table` — the very shape a CSV read with
[`using`](#reading-tables-using), a [`hive.sql`](#hivesql) result and a
[`hive.json`](#hivejson) document all arrive as — so putting data on screen is
one call rather than a loop.

**`link` is the one widget that works without an event**, and that is what it is
for. A message needs somewhere to send it, and a page rendered by `ui.page` has
no socket — so a view built only from buttons is fully alive in a window and
completely inert as a page. An `<a href>` needs no socket, no handler and no
state.

A link may carry both, and usually should:

```hive
ui.link([ui.on(Msg.Went(Route.Explore()))], "/explore", "Explore")
```

The window follows the **message** and the served page follows the **href**, from
the identical tree — so one nav rail works in both. A link carrying no message
navigates in either. A plain link *inside* something that does carry a message
wins the click, since it is the more specific thing that was clicked; a link
carrying its own message never navigates away from the window it was meant to
update. Where a link may point is a closed set — a path within the page, a
relative path, or `http`, `https`, `mailto` — and anything else, `javascript:`
above all, renders as no destination at all.

**Attributes** are semantic tokens rather than CSS values, which is what lets one
view render as a window, as a page, and — for whatever comes later — somewhere
with no CSS at all. `tone` and `background` are the one deliberate exception, and
[colour](#colour) below says what that costs.

| | |
| --- | --- |
| **Layout** | `gap(Int)` `pad(Int)` `width(Int)` `height(Int)` `grow(Int)` `align(Align)` `justify(Justify)` `scroll(Axis)` |
| **Text** | `size(TextSize)` `heading(Int)` `tone(Tone)` |
| **Colour** | `background(Tone)` — the same `Tone`, behind the content instead of in it |
| **State** | `disabled(Bool)` `busy(Bool)` `placeholder(Str)` `hint(Str)` `kind(InputKind)` |
| **Events** | `on(Msg)` `onDismiss(Msg)` `onInput(f)` `onSubmit(f)` `onChoose(f)` `onToggle(f)` `onPick(f)` `onSort(f)` |

`on` and `onDismiss` carry the message itself. The rest carry a **function** of
what the user did — `func(Str): Msg` for the three that read text,
`func(Bool): Msg` for `onToggle`, `func(Int): Msg` for `onPick` and `onSort` —
which is what a [constructor with a hole](#the-language) is for:
`ui.onInput(Msg.Changed(_))`.

The enumerations the module owns are ordinary types, reached the way every other
one is (`ui.Tone.Danger()`), and each is a **closed set** so a renderer can
answer for all of it. None of them is an atom, deliberately: the atom table
belongs to your program, and a library that added to it would renumber the atoms
you wrote.

| Type | Variants |
| --- | --- |
| `Align` | `Start` `Center` `End` `Stretch` |
| `Justify` | `Start` `Center` `End` `Between` |
| `TextSize` | `Title` `Subtitle` `Body` `Caption` |
| `Tone` | `Normal` `Muted` `Good` `Warn` `Danger` `HEX(Str)` `RGBA(Int, Int, Int, Int)` |
| `Axis` | `Horizontal` `Vertical` `Both` |
| `InputKind` | `Text` `Number` `Date` `Password` `Search` |
| `Icon` | `Search` `Close` `Check` `Plus` `Minus` `Up` `Down` `Left` `Right` `Warning` `Info` `Star` `Heart` `Reply` `Repeat` `Trash` `User` `Menu` |

#### Colour

`Tone` is the one enumeration that is not only a closed set. Past the five roles
above, two variants carry a colour outright:

```hive
ui.text([ui.tone(ui.Tone.Danger())], "!")               // a role
ui.text([ui.background(ui.Tone.HEX("#1d9bf0"))], "!")   // a colour
ui.text([ui.background(ui.Tone.RGBA(29, 155, 240, 255))], "!")
```

A **role** becomes a class the stylesheet answers for; a **colour** becomes a
declaration. Which of the two you wrote is what decides, and the renderer makes
that call — a program cannot ask for a class.

That distinction is the whole cost, and it is worth naming. A view built only
from roles draws anywhere, including on a target with no notion of colour at
all; `HEX` and `RGBA` are the two calls that spend that property, and a renderer
that cannot paint a colour has nothing to fall back on but `Normal`. Reach for
them when the colour is genuinely **data** — one per user, per category, per
series — and for a role when it means *good*, *risky* or *quiet*, because a role
is the only one of the two a theme can restyle.

Two practical notes. A colour is **checked, not trusted**: `HEX` takes `#` and
then 3, 4, 6 or 8 hex digits, and anything else is `Normal` rather than text
smuggled into a stylesheet — so a colour read from a config file is safe to pass
straight through. `RGBA` clamps each channel to `0`–`255` (alpha included, which
reaches CSS as the fraction it stands for) rather than refusing, because a colour
is computed at least as often as it is written down. And a **role brings a
readable foreground with it** — `background(Tone.Danger())` sets its own text
colour — while a computed colour brings nothing, so the contrast is yours:

```hive
ui.link(
	[ui.background(chipColour(person.handle)), ui.tone(ui.Tone.HEX("#ffffff"))],
	"/profile/{person.handle}",
	person.name
)
```

**A view is a value, so a test can read one.** `hive.ui.html` is the same
renderer a served page uses and needs no browser, no screenshot and no socket —
which makes "the button is disabled while the draft is empty" something a
[`test`](#testing) can assert rather than something a person has to notice.

**How the window is opened.** `window` binds a port the operating system chooses
on the loopback interface only, puts a random token in the URL, and starts a
browser already installed on the machine in application mode — a real window
with no address bar or tabs. Chrome, Edge, Chromium, Brave and Vivaldi are
tried on Linux and on Windows; failing all of them it falls back to an ordinary
tab, and failing that it prints the URL. None of them is linked into your binary:
each is a program that may or may not be there, which is what keeps a window
free of build dependencies on every platform.

A served page has nowhere to send an event back to, so `html` and `page` write
no handler ids at all — the messages in the tree are simply not recorded. That
is the honest rendering of a page with no socket behind it.

The whole page is re-rendered on each turn and swapped in, with focus and the
caret preserved; there is no tree diffing yet, which is a thing to add rather
than a thing to design around — the view is already a value, so nothing above
has to change for it.

See [`code-examples/17 - EXAMPLE APP - Chat with User
Interface`](code-examples/17%20-%20EXAMPLE%20APP%20-%20Chat%20with%20User%20Interface/chat.hive) — two
peers with no server between them, each a window you talk from and a mailbox the
other one posts to. It is worth reading for what a window being a **service**
buys: it publishes *itself* with
`hive.syslink.register(#Chat, hive.syslink.self(from))`, so the far node reaches
the screen with `hive.syslink.on(peer, #Chat)` and an ordinary send. Nothing in
the file formats a line, parses one or escapes anything — a message is a value
and the compiler derives the codec, so the two ends cannot disagree about a wire
format because neither of them has one.

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

### Importing a standard library module

The same `import` gives a **`hive.*` module** a short name, which is worth having
anywhere one is reached often — a view tree names its module on every node:

```hive
import hive.ui
import hive.net as web

func view(model: Model): ui.View {
	return ui.row([ui.gap(8)], [ui.text([], model.title)])
}

proc handle(request: web.HttpRequest): web.HttpResponse {
	return web.HttpResponse(200, [], "ok")
}
```

It is the same feature and the same rules — the alias is a name like any other,
so a local of that name shadows it, two imports may not share one, and it may
not collide with something the file declares. Three things are particular to it:

* The path is the module and nothing else: `import hive.ui`, never
  `import hive.ui.View`. What a module holds is reached *through* the name.
* Without `as`, the name is the module's own last segment — `import hive.ui`
  gives `ui`.
* Nothing is imported into the program. The alias is a **spelling**: `ui.row`
  and `hive.ui.row` are the same call, both are always available, and neither
  changes what is linked into the build. `import hive` is not a thing to write —
  the library is reached a module at a time, and the global builtins (`len`,
  `map`, `sort`, ...) were never behind an import at all.

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

## Testing

A test is a top-level declaration, alongside `proc`, `func`, `query` and `type`:

```hive
import ./cart

test "an empty cart costs nothing" {
	cart.Item[0] empty = []
	assert cart.total(empty) == 0
}
```

Run them with **`hive test <entrypoint.hive>`**. There is nothing to install and
nothing to register: no framework, no third-party library, no `describe`/`it`, no
assertion vocabulary beyond the `assert` the language already has.

A test is named **in prose** because a test name is documentation, not something
anything calls — and for the same reason it takes no parameters and returns
nothing (`return value` inside one is a compile error; a bare `return` to leave
early is fine). Tests may live beside the code they are about or in a file of
their own; a file holding only tests needs no `main`, and `hive test` on a
program runs every test in every file the entrypoint reaches.

### `assert` means the same thing, and does something different

`assert` is the keyword you already have, and it says what it always says: this
must hold. What changes is the consequence, and — as everywhere else in Hive —
that is decided by *where it is written*. In ordinary code a failed assertion has
proved the **program** wrong, so it stops. Inside a test it has proved the
**test** wrong, so the failure is recorded and the rest of the suite still runs.

A failed comparison shows both sides. The compiler has the source text and the
static types, so neither the condition nor the values have to be spelled out in a
message by hand:

```
  PASS  an empty cart costs nothing
  FAIL  lines add up
        cart.test.hive:33: assert cart.total(two) == 17
          left:  16
          right: 17

  2 tests: 1 passed, 1 failed
```

A test that **panics** fails on its own rather than taking the suite with it, so
one broken test cannot hide every result after it.

### Coverage is not a separate command

Every `hive test` run reports it. A run that does not say what it *missed* has
answered half the question, so there is no flag to remember and no second command
to forget:

```
  6 tests: 6 passed
  coverage: 87.5% of statements (7/8)
  never exercised: describe
```

The percentage counts statements of your own declarations — the clone helpers,
ordering helpers, atom table and JSON marshalling the compiler emits alongside
them are nobody's code and are not something a test can be said to have missed.
`never exercised` names the declarations no test reached at all, which is usually
the line worth acting on. With more than one file in the program, a per-file
breakdown is printed too.

`hive test` exits non-zero when any test fails, which is what makes it the thing
a commit hook or a CI step runs.

### What runs it

`go test`. Hive already generates a Go module and drives the Go toolchain, and
that toolchain ships a runner: isolation per test, filtering by name, timing,
exit codes and coverage instrumentation. None of it is reimplemented here. The
tests are generated into a `main_test.go` in the same Go package as `main.go`,
which is what lets a test reach every proc, func and type the program declares
without any of them being exported, or named, or otherwise made testable on
purpose.

Two things a runner cannot know and a compiler can are added on top: which
`.hive` line a failure belongs to — the generated Go carries `//line` directives,
so positions are the author's file rather than the compiler's — and what the
values on either side of a failed comparison actually were.

See [`code-examples/15 - Testing`](code-examples/15%20-%20Testing/cart.test.hive).

## How Hive maps onto Go

Hive lowers to Go, and the Go toolchain turns that into the executable. You never
have to read the result — `hive emit` is there if you want to — but a handful of
Hive's rules are easier to trust once you know what they become. These are the
mappings worth knowing:

| Hive                                    | Go                                                             |
| --------------------------------------- | -------------------------------------------------------------- |
| `proc` / `func`                         | an ordinary `func`; `proc main(): void` → `func main()`        |
| `query q(p: Str): Row[dyn]`             | a function returning SQL text with `?` plus the bound args     |
| `type T { }` / `type T { A {..} B }`    | a `struct` / an `interface` + one struct per variant           |
| fields declared outside any variant     | appended to **every** variant struct                           |
| `Str`, `Int`, `Float`, `Bool`, `Atom`   | `string`, `int`, `float64`, `bool`, `hive.Atom`                |
| `Str[3]`, `Str[dyn]`, `Str[]`           | `[]string` — all three are slices, which is why [value semantics](#value-semantics-copy-on-binding) exist |
| `test "..." { }`                        | a `t.Run(...)` in a generated `main_test.go`, run by `go test` |
| `assert c` (in ordinary code)           | `hive.Assert(c)` — a panic                                     |
| `assert c` (inside a `test`)            | a recorded failure quoting `c` and, for a comparison, both sides |
| `mut` (on a declaration)                | nothing at all: it is compile-time only                        |
| `mut b = a` (both `mut`, owns storage)  | no variable — `b` compiles to `a`, so one slice header is shared |
| `ys := xs` (needs a copy)               | a generated deep clone, chosen by the static type              |
| `f(mutVec)` (argument names `mut` storage) | `f(hive.CloneVec(mutVec))` — copied in, so the callee's `T` really is immutable |
| `p(v: mut T)` (a mutex parameter)       | `p(v *T)`, read and written through `(*v)`                      |
| `p(mutVec)` (waited for)                | `p(&mutVec)` — the callee writes the caller's own storage       |
| `async p(mutVec)` (fired off)           | `{ _a0 := hive.CloneVec(mutVec); go p(&_a0) }` — the thread gets its own |
| `f(x)` / `async f(x)`                   | a plain call / `go f(x)`                                       |
| `f(x) with timeout ms`                  | `hive.AwaitTimeout(hive.Spawn(..), ms)` → a `Result`           |
| `await [f(a), f(b)]`                    | `hive.AwaitAll(..)` over one `hive.Spawn` each → a statically-sized vector |
| `addr(m)` / `async addr(m)`             | a send that waits for its answer / `hive.SyslinkSend(..)`, which cannot fail |
| `for each x in v { }`                   | `for _, x := range v { }`                                      |
| `x is Result.Ok(v)` / `x is T.Variant(a, _)` | `IsOk()` + accessor / a type assertion; `_` binds nothing |
| `if <call> is Result.Ok(v)`             | one `if` with an init slot, so the call is evaluated once       |
| `"{a} and {b}"`                         | concatenation, non-`Str` pieces via `hive.ToStr`               |
| `[x, y] + [z]` / `v1 == v2`             | `hive.Concat(..)` / `hive.VecEq(..)` (structural)              |
| `t[1:3]`                                | `t[1:4]` — Hive's high bound is **inclusive**                   |
| `#Atom`                                 | a small integer constant + a generated atom table              |
| `a / b`, `a ** b`, `a % b`              | `hive.DivInt`, `hive.PowInt`, `hive.ModInt` (see [edges](#arithmetic-at-the-edges)) |
| `echo v` / `assert c` / `panic v`       | `fmt.Println(v)` / `hive.Assert(c)` / `panic(hive.Show(v))`     |
| `f` (bare reference) / `f(a, _, c)`     | the function value / a closure whose parameter is the hole      |
| `func f(v: T[]): T` at `T = Str`        | `func f_Str(v []string) string` — one copy per instantiation    |
| `using p` / `using conn run q(..)` / `run raw t` | `hive.ReadCSV(..)` / `hive.SqlRows(..)` / `hive.SqlQuery(..)`, each → a `Result` |
| a `hive.*` library call                 | a call of the same name on the generated `hive` runtime package (`hive.json.parse` → `hive.JsonParse`, `hive.syslink.spawn` → `hive.SyslinkSpawn`, …) |
| `import hive.ui as ui`, then `ui.row(..)` | nothing — the alias is resolved during import flattening, so codegen only ever sees `hive.ui.row` |
| `Msg.Changed(_)` (a constructor hole)   | `func(_h0 string) Msg { return Msg(MsgChanged{Text: _h0}) }` |
| `ui.row(attrs, kids)` / `ui.Tone.Danger()` | `hive.UiRow(..)` / `hive.Tone("Danger")` — an enum is a named string type carrying its variant's name |
| `ui.Tone.HEX(s)` / `ui.Tone.RGBA(r, g, b, a)` | `hive.UiToneHex(s)` / `hive.UiToneRGBA(..)` — a call rather than a bare string, because the payload is validated and clamped where it lands |
| `ui.window(t, view, update, s)`         | `hive.UiWindow(..)`, which spawns the fold as a syslink service and serves the view to it |
| `Result<T, E>`, `Table`, `hive.TableError` | provided by that runtime package                            |

Two rules are worth stating outside the table. Hive requires every non-`void`
`proc`/`func` to **return on every path**: a path terminates by ending in
`return`, in `assert` or `panic` (both handy for a tail you know is unreachable),
in an `if`/`else` whose every branch terminates, or in an else-less
`if`/`else if` chain that covers its subject's whole type (a `Result`'s `Ok` +
`Error`, or every variant of an ADT). Anything else is a compile error. For an
accepted function that doesn't syntactically end in `return`, codegen appends a
`panic("hive: unreachable")` to satisfy the Go compiler; it is now genuinely
unreachable.

And a Hive identifier that happens to be a Go keyword but not a Hive one (a
variable or function named `map`, `range`, `select`, ...) is suffixed with `_` in
the generated Go — consistently at its definition and every use — so it never
collides with Go's own grammar.

Codegen runs a lightweight type-inference pass over locals so overloaded
syntax picks the right lowering (`+` on vectors vs. strings vs. numbers, atom
→ `Str` coercions, zero-safe division, vector literal element types). The same
pass decides the constructs that have no honest lowering — indexing a `Str` is
the one that exists today — so they are rejected as Hive errors rather than
emitted as code that either fails to compile or quietly means something else.

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
src/hive/testreport.gleam turns `go test` output and its coverage profile into
                          the report `hive test` prints
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

A known length also **survives the operations that can't lose it**, so whole-vector
code stays as indexable as the literals it started from. Concatenation adds the
two lengths (`Str[2] + Str[8]` is eight-plus-two elements, and fills a `Str[10]`
slot), while [`map`](#walking-a-vector-map-filter-filtermap) and
[`sort`](#putting-a-vector-in-order-sort) each carry their input's length through
unchanged — one transforms elements and the other moves them, and neither
changes how many there are. They compose, so `map(a, f) + sort(b)` is as long as
`a + b`. If *either* side of a concatenation is unknown the result is unknown —
there is no "at least this many" — and `filter`/`filterMap` never carry a length
at all, for the reason given in their section.

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
`mut v := ["a", "b", "c"]` knows it holds three today, and keeps that through a
write *through* the name (`v[i] = x` swaps an element without changing the
length), but loses it the moment the name is rebound — including in a branch or
loop body that may not even run:

```hive
mut v := ["a", "b", "c"]
if changed { v = ["x"] }
echo v[2]                   // compile error: v's length is no longer known
```

Being *dynamic*, though, is not inferred at all — it is declared. A `:=` binding
reads its length off the value it was handed, and a length read off a value is a
static one, so `append` has nothing there to grow:

```hive
mut v := ["a", "b", "c"]
append(v, "d")                   // compile error: `v` is not a dynamic vector

mut Str[dyn] w = ["a", "b", "c"]
append(w, "d")                   // fine — `w` promises nothing about its length
```

Which keeps one question answerable by reading a declaration alone: *does this
vector have a length the compiler knows?* Every rule above rests on that, and an
inferred `[dyn]` would have made the answer depend on how the value arrived.
