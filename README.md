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
in `foo.hive-build/` for inspection. `hive run` executes it with the working
directory set to the entrypoint's folder, so relative paths such as
`using "./test.csv"` resolve as the author expects.

## The examples

The language is specified by the programs in `code-examples/`; each one
compiles, builds and runs.

**`1 - Basic IO`** reads a `;`-delimited CSV into a tagged-union
`ParsingResult`, pattern-matches on it and `echo`s the outcome. The heart of
it compiles to:

```go
func parse() ParsingResult {
	csv := hive.ReadCSV("./test.csv", ";")
	if csv.IsOk() {
		table := csv.Ok()
		if len(table) > 1 {
			return ParsingResult(ParsingResultSuccess{HeaderlessTable: table[1:], Timestamp: hive.Now()})
		}
		return ParsingResult(ParsingResultNoData{Timestamp: hive.Now()})
	} else if csv.IsError() {
		error := csv.Err()
		return ParsingResult(ParsingResultError{Error: error, Timestamp: hive.Now()})
	}
	panic("hive: unreachable")
}
```

**`2 - Types`** tours the type system: strings (interpolation, backtick
multiline strings), vectors, atoms, numbers, custom types and queries.
Running it prints:

```
Strings!
[Vectors for the Win!]
True
3
Example
SELECT * FROM users u
WHERE u.name = 'O''Brien'
```

**`3 - HTTP`** serves an HTTP server on port 8080 whose handler greets every
route, logs each request, proxies `/proxy` to example.com via
`hive.http.request`, and speaks JSON on `/greet` — decoding the request body
against a declared type and encoding the typed reply back:

```sh
$ hive run "code-examples/3 - HTTP/http.hive" &
Listening on http://localhost:8080
$ curl -X POST localhost:8080/greet -d '{"name": "Ana", "details": {"mood": "curious"}}'
{"message":"Hello Ana, glad you are curious!","timestamp":1784507444}
$ curl -X POST localhost:8080/greet -d '{"name": 42, "details": {}}'
{"message":"$.name: expected Str, found the number 42","timestamp":1784507444}
```

## The language

* **`proc` / `func` / `query`** — a `proc` may perform side effects; a
  `func` is pure (using `echo`/`using` or calling a `proc` inside one is a
  compile error). A `query` is a func whose body is inline SQL: every
  `{param}` interpolated into it is rendered as a quoted SQL literal and
  sanitized at runtime (`'O''Brien'` above). Programs start at
  `proc main(): void`.
* **Strings** (`Str`) are UTF-8, support `"{expr}"` interpolation, and
  backtick multiline strings whose indentation is removed at compile time.
* **Vectors** are memory-contiguous and static (`Str[3]`) or dynamic
  (`Str[dyn]`, `Str[dyn, 2]` with an initial size). All of them lower to Go
  slices; `+` concatenates. `Table` is an alias for `Str[dyn][dyn]`.
* **Atoms** (`#SomeAtom`) are interned symbols. The compiler assigns each a
  small integer (`#False` = 0 and `#True` = 1 always come first — `false` and
  `true` are aliases for them) and embeds the atom table in the executable,
  so `echo` prints an atom's name while coercion to `Str` yields its decimal
  value (`"0" + True == "01"`).
* **Numbers** are `Int` or `Float` with `+ - * / **`; dividing by zero
  returns 0.
* **Custom types** are Gleam-style ADTs: no variants ⇒ a struct, variants ⇒
  a tagged union. Fields declared outside any variant are added to every
  variant. `is` narrows a value to a variant and can bind its fields, and the
  bindings are usable immediately in the same condition:
  `if x is T.A(v) && v == "ok" { ... }`.
* **`assert cond`** panics at runtime when the condition is false.
* **Named arguments** — funcs, procs, queries and type constructors (builtin
  ones included) accept arguments by name: `f(b: 1, "s")`. Named arguments
  can appear anywhere; only the unnamed ones need to be in order, filling
  whichever parameters the named ones didn't claim. Names must exist, can't
  repeat, and once named arguments are used the call must cover the full
  parameter list.
* **`hive.http`** is the HTTP standard library. `hive.http.request(req)`
  performs a request and returns
  `Result<hive.HttpResponse, hive.HttpError>` (a `Result.Error` means no
  response was obtained at all). `hive.http.serve(port, handler)` blocks
  forever serving every route through `handler`, which must be a
  `proc (hive.HttpRequest): hive.HttpResponse` passed by name. Both are side
  effects, so they are only available inside `proc`s. Requests and responses
  are built positionally — `hive.HttpRequest(method, url, headers, body)`,
  `hive.HttpResponse(status, headers, body)` — and headers are a `Table` of
  `[name, value]` rows.
* **`hive.json`** is the JSON standard library, built on the idea that Hive's
  type declarations *are* the JSON schema. `hive.json.parse(text) with T`
  derives a decoder for `T` at compile time and returns
  `Result<T, hive.JsonError>`: missing fields, wrong types and wrong static
  vector lengths become errors carrying the exact `path` that failed, while
  JSON fields the type doesn't declare are simply ignored. Variants decode as
  `{"VariantName": {...}}` (JSON `null` selects a type's first field-less
  variant). JSON you don't want to model stays type-safe too: `with Table`
  flattens a whole document into `[path, value]` rows, looked up with
  `hive.json.get(table, "keys.layout")` and re-nested by the encoder.
  `hive.json.encode(value)` derives the encoder from the static type and
  therefore cannot fail, and `hive.json.table(text)` reads a JSON array of
  flat objects as a headered `Table`, the same shape `using` yields from CSV.
  All of `hive.json` is pure, so it is available inside `func`s.
* All keywords are case-insensitive; identifiers keep their spelling.

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
| `echo v`                                | `fmt.Println(v)` (stringifies any value, appends a newline)    |
| `assert cond`                           | `hive.Assert(cond)`                                            |
| `T.Variant(a, b)`                       | `T(TVariant{Field0: a, Field1: b})` (positional: own then common) |
| `x is Result.Ok(v)` / `Result.Error(e)` | `x.IsOk()` + `v := x.Ok()` / `x.IsError()` + `e := x.Err()`    |
| `x is T.Variant(a, _)` (user ADT)       | type assertion; bindings read fields, `_` binds nothing        |
| `a is T.A(v) && p(v)`                   | short-circuiting `&&`; `v` reads through its accessor          |
| `using p with d`                        | `hive.ReadCSV(p, d)` → `Result[Table, TableError]`             |
| `"{a} and {b}"`                         | concatenation, non-`Str` pieces via `hive.ToStr`               |
| `[x, y] + [z]`                          | `hive.Concat([]T{x, y}, []T{z})`                               |
| `#Atom`, `true`, `false`                | `hive.Atom` constants + a generated `hive.InitAtoms` table     |
| `a / b`, `a ** b`                       | `hive.DivInt`/`hive.DivFloat`, `hive.PowInt`/`hive.PowFloat`   |
| `len(t)` / `now()`                      | `len(t)` / `hive.Now()` (current Unix time)                    |
| `hive.json.parse(t) with T`             | `hive.JsonParse(t, jsonDecode_T)` → `Result[T, JsonError]`     |
| `hive.json.encode(v)`                   | derived `jsonEncode_T(v)` (cannot fail, so plain `string`)     |
| `hive.json.table(t)` / `.get(tbl, p)`   | `hive.JsonTable(t)` / `hive.JsonGet(tbl, p)`                   |
| `hive.http.request(r)`                  | `hive.HttpSend(r)` → `Result[HttpResponse, HttpError]`         |
| `hive.http.serve(port, handler)`        | `hive.HttpServe(port, handler)` (handler passed by proc name)  |
| `hive.HttpRequest(m, u, h, b)`          | `hive.HttpRequest{Method: m, Url: u, Headers: h, Body: b}`     |
| `request.body` (builtin struct field)   | `request.Body` (fields capitalize to their exported Go names)  |
| `t[1:]`                                 | `t[1:]` (slices are **inclusive** of the high bound)           |
| `Str`, `Int`, `Bool`, `Float`, `Atom`   | `string`, `int`, `bool`, `float64`, `hive.Atom`                |
| `Str[3]`, `Str[dyn]`, `Str[dyn, 2]`     | `[]string` (all vectors lower to slices)                       |
| `Table`, `hive.TableError`, `Result`    | provided by the generated `hive` runtime package               |

Codegen runs a lightweight type-inference pass over locals so overloaded
syntax picks the right lowering (`+` on vectors vs. strings vs. numbers, atom
→ `Str` coercions, zero-safe division, vector literal element types). Hive
relies on exhaustiveness analysis this proof-of-concept doesn't fully model,
so any non-`void` function that doesn't syntactically end in a `return` gets
a trailing `panic("hive: unreachable")` to satisfy the Go compiler.

## How the compiler is structured

```
src/hive.gleam            CLI entry point (build / run / emit dispatch)
src/hive/token.gleam      token definitions
src/hive/lexer.gleam      source text  -> tokens (strings, atoms, SQL bodies)
src/hive/ast.gleam        the abstract syntax tree
src/hive/parser.gleam     tokens       -> AST (recursive descent)
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
written to be extended, but there is no full type checker, no
flow-sensitive length checking (e.g. proving `table[1:]` safe), and no
standard library beyond the builtins listed above yet.
