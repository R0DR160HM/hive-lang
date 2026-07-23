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
program, which changes into it before `main`).

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

// A `query` is a pure function whose body is inline SQL; every interpolated
// parameter is sanitized automatically (note the doubled quote in the output).
query findUser(name: Str): Str {
	SELECT * FROM users WHERE name = {name}
}

// An `async func` runs on its own virtual thread (a goroutine).
async func slowShout(text: Str): Str {
	return text + "!!!"
}

// A `proc` may perform side effects (echo, using, hive.http, ...).
proc main(): void {
	mut names := ["Ada", "Linus"]
	names[0] = "Grace"

	echo greet("Grace", Greeting.Formal("Dr."))
	echo greet(names[1], Greeting.Casual())
	echo findUser("O'Brien")

	slowShout("fire-and-forget")     // does not block; the result is discarded
	echo await slowShout("await")    // blocks until the value is ready
}
```

Running it prints:

```
Good evening, Dr. Grace.
Hey Linus!
SELECT * FROM users WHERE name = 'O''Brien'
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
form above), the type system, an HTTP server that speaks JSON, a `hive.crypto`
walkthrough (hashing, HMAC, base64 and JWTs), a `hive.sql` example backed by an
embedded SQLite database, a tour of first-class functions and partial
application, and a tour of Hive's copy-on-binding [value
semantics](#value-semantics-copy-on-binding) — live in `code-examples/`. They
double as the language's specification: each one compiles, builds and runs.

## The language

* **`proc` / `func` / `query` / `async func`** — both `proc`s and `func`s may
  perform I/O: `echo`, reading files with `using`, and `hive.http` are all
  allowed in either. A `func` differs from a `proc` in exactly two ways: it
  cannot receive a mutex as a parameter (a `mut` value passed to a func is seen
  as an ordinary immutable copy), and it cannot call a `proc` (only procs call
  procs). A `query` is a func whose body is inline SQL: every `{param}`
  interpolated into it is rendered as a quoted SQL literal and sanitized at
  runtime (`'O''Brien'` above). An `async func` runs on its own virtual
  thread — see the concurrency bullet below. Programs start at
  `proc main(): void`.
* **Strings** (`Str`) are UTF-8, support `"{expr}"` interpolation, and
  backtick multiline strings whose indentation is removed at compile time.
* **Vectors** are memory-contiguous and static (`Str[3]`) or dynamic
  (`Str[dyn]`, `Str[dyn, 2]` with an initial size). All of them lower to Go
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
  runnable tour. (For `append`, `join`, `split`, `len` and `bytes` see
  [Built-in functions](#built-in-functions).)
* **Mutability** — variables are immutable by default; prefix a declaration
  with `mut` (`mut x := ...`, `mut Str[dyn] v = ...`) to allow reassignment
  (`x = ...`, `v[0] = ...`) and `append`. Conceptually a `mut T` is a
  `Mutex<T>`: identical to `T` at runtime, but only mutexes may be altered at
  compile time. A parameter or return of type `T` accepts a `Mutex<T>` (the
  callee just sees an immutable `T`), never the reverse, so assigning to a
  parameter or a plain `:=` binding is a compile error.
* **Concurrency** — an `async func` runs on its own virtual thread (a
  goroutine). Calling one bare is fire-and-forget — it behaves as `void` and
  does not block the caller — while `await someAsyncCall()` blocks the current
  thread until the function returns its value.
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
  shorthand for the matching `x = x <op> ...`.
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
* **First-class functions** — a proc or func is a value you can pass, store and
  call later. Its type is written like a declaration with the name dropped:
  `func(Int): Int` (pure) or `proc(hive.http.HttpRequest): hive.http.HttpResponse`
  (impure), usable as a parameter, return or variable type. A value is produced
  by a **bare reference** (the callable's name on its own), or by a **partial
  application** — a call with `_` holes, e.g. `handler(_, db)`, which fixes the
  supplied arguments and leaves each `_` as a parameter of the resulting
  function (in order), capturing the rest by value. So
  `hive.http.serve(8080, handler(_, db))` adapts a two-argument `handler` into
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
  `assert`, it always fires and takes any value, not just a boolean. Because it
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

When a copy *is* made it is **deep and type-directed** — no runtime reflection:

* a flat vector copies its backing array (`hive.CloneVec`);
* a nested vector or `Table` copies every level (`hive.CloneVecFn` /
  `hive.CloneTable`);
* a struct or tagged union copies its storage-owning fields through a generated
  `clone_T` (scalar-only types need nothing — Go's value copy already isolates
  them).

See [`code-examples/6 - Value Semantics`](code-examples/6%20-%20Value%20Semantics/value-semantics.hive)
for a runnable walkthrough of each case.

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
| `row(table, key)`       | `row(Table, Str): Str[dyn]`  | The row whose first cell equals `key`, else `[]`.                    |
| `column(table, key)`    | `column(Table, Str): Str[dyn]`| The column whose top (first-row) cell equals `key`, else `[]`.      |
| `now()`                 | `now(): Int`                 | Current Unix time, in seconds.                                       |

`len` and `bytes` differ only for strings: for `"café"`, `len` is `4` (runes)
while `bytes` is `5` (the `é` is two bytes). `append` is the one builtin that
requires its target to be `mut` — it is the in-place way to grow a
`Str[dyn]`; `+` instead builds a brand-new vector. `row` and `column` look a
value up in a `Table` by its first cell — `row` matches a row's first element,
`column` matches a column's top (first-row) cell — and `column` skips any row
too short to reach the matched column.

## Standard library (`hive.*`)

Each module owns its types under its own namespace — `hive.http.HttpRequest`,
`hive.json.JsonError`, `hive.crypto.CryptoError`, `hive.sql.DatabaseDriver`,
`hive.conv.ConversionError`, `hive.env.EnvironmentError`, and so on. The only builtin types that live directly on `hive` are the core
ones the language uses without a module: `Result`, `Table` and the
`hive.TableError` that `using` yields from a CSV.

### `hive.http`

The HTTP library. Both calls perform I/O, so — like `echo` and `using` — they
work inside a `func` or a `proc`. Requests and responses are built
positionally —
`hive.http.HttpRequest(method, url, headers, body)`,
`hive.http.HttpResponse(status, headers, body)` — and headers are a `Table` of
`[name, value]` rows.

* `hive.http.request(req)` performs a request and returns
  `Result<hive.http.HttpResponse, hive.http.HttpError>` (a `Result.Error`
  means no response was obtained at all).
* `hive.http.serve(port, handler)` blocks forever, serving every route through
  `handler` — which must be a
  `proc (hive.http.HttpRequest): hive.http.HttpResponse` passed by name.

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
    `exp`/`nbf` claims against `now()`, then decodes the payload into `T`,
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

* **Querying** reuses the `using ... with ...` form:
  `using <connection> with <query>` runs *any* SQL and returns
  `Result<Table, hive.sql.SqlError>`. A query that returns rows yields a header
  row of column names followed by one row per result row; a statement that
  returns none (INSERT/UPDATE/DDL) yields an empty table. Build the query
  string safely with a `query` declaration, whose `{param}`s are sanitized:
  `using db with insertUser(1, "O'Brien")`.
* `hive.sql.connect(driver, connString)` opens a pooled connection and returns
  `Result<hive.sql.SqlConnection, hive.sql.SqlError>`; `hive.sql.pool(driver,
  connString, maxOpen, maxIdle)` does the same with explicit pool limits;
  `hive.sql.close(conn)` releases it.
* The `driver` is a `hive.sql.DatabaseDriver`, built with
  `hive.sql.DatabaseDriver.SQLite()`, `.PostgreSQL()`, or `.Other(name)` for
  any other registered `database/sql` driver.

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

## How Hive maps onto Go

| Hive                                    | Go                                                             |
| --------------------------------------- | -------------------------------------------------------------- |
| `proc`/`func` `name(): T { ... }`       | `func name() T { ... }`                                        |
| `proc main(): void`                     | `func main()`                                                  |
| `query q(p: Str): Str { SQL {p} }`      | `func q(p string) string { return "SQL " + hive.SqlParam(p) }`  |
| `type T { }` (no variants)              | a `struct`                                                     |
| `type T { A {..} B }` (variants)        | an `interface` + one `struct` per variant (a tagged union)     |
| fields declared outside any variant     | appended to **every** variant struct                           |
| `name := expr`                          | `name := expr` (type inferred)                                 |
| `T name = expr`                         | `var name T = expr`                                            |
| `mut name := expr` / `mut T name = e`   | same as above (`mut` is compile-time only — permits reassign)  |
| `x = expr` / `v[0] = expr`              | `x = expr` / `v[0] = expr` (only on `mut` variables)           |
| `ys := xs` (needs a copy — see [value semantics](#value-semantics-copy-on-binding)) | `ys := hive.CloneVec(xs)` / `hive.CloneVecFn(..)` / `hive.CloneTable(..)` / `clone_T(..)` |
| `for i := 0; i < n; i = i + 1 { }`      | `for i := 0; i < n; i = i + 1 { }` (counter scoped to the loop) |
| `for each x in v { }`                   | `for _, x := range v { }` (binds the value, discards the index) |
| `async func f(): T { ... }`             | `func f() T { ... }` (an ordinary Go function)                 |
| `f(x)` bare / `await f(x)` (async `f`)  | `go f(x)` (fire-and-forget goroutine) / `f(x)` (blocking call) |
| `echo v`                                | `fmt.Println(v)` (stringifies any value, appends a newline)    |
| `assert cond`                           | `hive.Assert(cond)`                                            |
| `panic value`                           | `panic(hive.Show(value))` (renders `value` like `echo`)        |
| `T.Variant(a, b)`                       | `T(TVariant{Field0: a, Field1: b})` (positional: own then common) |
| `x is Result.Ok(v)` / `Result.Error(e)` | `x.IsOk()` + `v := x.Ok()` / `x.IsError()` + `e := x.Err()`    |
| `x is T.Variant(a, _)` (user ADT)       | type assertion; bindings read fields, `_` binds nothing        |
| `a is T.A(v) && p(v)`                   | short-circuiting `&&`; `v` reads through its accessor          |
| `using p with d` (Str path)             | `hive.ReadCSV(p, d)` → `Result[Table, TableError]`             |
| `using conn with q` (SQL connection)    | `hive.SqlQuery(conn, q)` → `Result[Table, SqlError]`           |
| `"{a} and {b}"`                         | concatenation, non-`Str` pieces via `hive.ToStr`               |
| `[x, y] + [z]`                          | `hive.Concat([]T{x, y}, []T{z})`                               |
| `v1 == v2` / `v1 != v2` (vectors)       | `hive.VecEq(v1, v2)` / `!hive.VecEq(v1, v2)` (structural)      |
| `#Atom`                                 | `hive.Atom` constants + a generated `hive.InitAtoms` table     |
| `true` / `false`                        | Go `true` / `false` (the `Bool` type, not atoms)               |
| `a / b`, `a ** b`                       | `hive.DivInt`/`hive.DivFloat`, `hive.PowInt`/`hive.PowFloat`   |
| `a % b`                                 | `hive.ModInt`/`hive.ModFloat` (remainder; `% 0` returns 0)    |
| `len(v)` vector / `len(s)` Str          | `len(v)` (elements) / `hive.StrLen(s)` (UTF-8 runes)           |
| `bytes(v)` vector / `bytes(s)` Str      | `hive.Bytes(v)` (footprint) / `len(s)` (UTF-8 byte length)     |
| `append(v, x)` / `join(v, sep)`         | `v = append(v, x)` (statement) / `hive.Join(v, sep)`           |
| `split(s, sep)` / `now()`               | `hive.Split(s, sep)` → `Str[dyn]` / `hive.Now()` (Unix time)   |
| `row(t, k)` / `column(t, k)`            | `hive.Row(t, k)` / `hive.Column(t, k)` → `Str[dyn]`           |
| `hive.json.parse(t) with T`             | `hive.JsonParse(t, jsonDecode_T)` → `Result[T, JsonError]`     |
| `hive.json.encode(v)`                   | derived `jsonEncode_T(v)` (cannot fail, so plain `string`)     |
| `hive.json.table(t)` / `.get(tbl, p)`   | `hive.JsonTable(t)` / `hive.JsonGet(tbl, p)`                   |
| `hive.http.request(r)`                  | `hive.HttpSend(r)` → `Result[HttpResponse, HttpError]`         |
| `hive.http.serve(port, handler)`        | `hive.HttpServe(port, handler)` (handler is any function value) |
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
| `hive.http.HttpRequest(m, u, h, b)`     | `hive.HttpRequest{Method: m, Url: u, Headers: h, Body: b}`     |
| `request.body` (builtin struct field)   | `request.Body` (fields capitalize to their exported Go names)  |
| `t[1:]`                                 | `t[1:]` (slices are **inclusive** of the high bound)           |
| `Str`, `Int`, `Bool`, `Float`, `Atom`   | `string`, `int`, `bool`, `float64`, `hive.Atom`                |
| `Str[3]`, `Str[dyn]`, `Str[dyn, 2]`     | `[]string` (all vectors lower to slices)                       |
| `Table`, `hive.TableError`, `Result`    | provided by the generated `hive` runtime package               |

Codegen runs a lightweight type-inference pass over locals so overloaded
syntax picks the right lowering (`+` on vectors vs. strings vs. numbers, atom
→ `Str` coercions, zero-safe division, vector literal element types). Hive
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
src/hive/bounds.gleam     flow-sensitive vector index/slice bounds checking
src/hive/codegen.gleam    AST          -> Go source (with local type inference)
src/hive/runtime.gleam    the fixed Go `hive` runtime + go.mod
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
`if i >= 0 && i < len(v) { ... }`. Anything the pass can't prove safe (a
computed index, an unusual guard) is a compile error rather than a runtime
crash.
