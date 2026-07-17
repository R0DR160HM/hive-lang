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
gleam run -- build code-examples/basic-io/basic-io.hive
gleam run -- run   code-examples/basic-io/basic-io.hive
```

or through the thin wrappers at the repo root, which let you pass paths
relative to wherever you happen to be:

```sh
./hive run code-examples/basic-io/basic-io.hive     # bash / macOS / Linux
.\hive.ps1 run code-examples\basic-io\basic-io.hive  # Windows PowerShell
```

`hive build foo.hive` writes the executable next to the entrypoint
(`foo.exe` on Windows, `foo` elsewhere) and leaves the intermediate Go project
in `foo.hive-build/` for inspection. `hive run` executes it with the working
directory set to the entrypoint's folder, so relative paths such as
`using "./test.csv"` resolve as the author expects.

## The example

`code-examples/basic-io/basic-io.hive` reads a `;`-delimited CSV into a
tagged-union `ParsingResult`, then pattern-matches on it and `echo`s the
outcome. Running `hive emit` on its `parse` procedure produces:

```go
package main

import (
	"hiveapp/hive"
)

type ParsingResult interface {
	isParsingResult()
}
type ParsingResultSuccess struct {
	HeaderlessTable [][]string
	Timestamp       int
}
func (ParsingResultSuccess) isParsingResult() {}
// ... ParsingResultNoData, ParsingResultError ...

func parse() ParsingResult {
	csv := hive.ReadCSV("./test.csv", ";")
	if csv.IsOk() {
		table := csv.Ok()
		if len(table) > 1 {
			return ParsingResultSuccess{HeaderlessTable: table[1:], Timestamp: hive.Now()}
		}
		return ParsingResultNoData{Timestamp: hive.Now()}
	} else if csv.IsError() {
		error := csv.Err()
		return ParsingResultError{Error: error, Timestamp: hive.Now()}
	}
	panic("hive: unreachable")
}
```

## How Hive maps onto Go

| Hive                                  | Go                                                             |
| -------------------------------------- | ------------------------------------------------------------- |
| `proc name(): T { ... }`               | `func name() T { ... }`                                       |
| `proc main(): void`                    | `func main()`                                                 |
| `type T { }` (no variants)             | a `struct`                                                    |
| `type T { A {..} B }` (variants)       | an `interface` + one `struct` per variant (a tagged union)    |
| fields declared outside any variant    | appended to **every** variant struct                          |
| `name := expr`                         | `name := expr` (type inferred)                                |
| `T name = expr`                        | `var name T = expr`                                           |
| `echo v`                               | `fmt.Println(v)` (stringifies any value, appends a newline)   |
| `T.Variant(a, b)`                      | `TVariant{Field0: a, Field1: b}` (positional: own then common)|
| `x is Result.Ok(v)` / `Result.Error(e)`| `x.IsOk()` + `v := x.Ok()` / `x.IsError()` + `e := x.Err()`   |
| `x is T.Variant(a, _)` (user ADT)      | type assertion; bindings read fields, `_` binds nothing       |
| `using p with d`                       | `hive.ReadCSV(p, d)` → `Result[Table, TableError]`           |
| `len(t)`                               | `len(t)`                                                      |
| `now()`                                | `hive.Now()` (current Unix time)                             |
| `t[1:]`                                | `t[1:]` (slices are **inclusive** of the high bound)          |
| `String`, `Int`, `Bool`, `String[][]`  | `string`, `int`, `bool`, `[][]string`                         |
| `Table`, `hive.TableError`, `Result`  | provided by the generated `hive` runtime package             |

Keywords are matched case-insensitively; identifiers keep their spelling.

Hive relies on exhaustiveness analysis this proof-of-concept doesn't fully
model, so any non-`void` procedure that doesn't syntactically end in a `return`
gets a trailing `panic("hive: unreachable")` to satisfy the Go compiler.

## How the compiler is structured

```
src/hive.gleam            CLI entry point (build / run / emit dispatch)
src/hive/token.gleam      token definitions
src/hive/lexer.gleam      source text  -> tokens
src/hive/ast.gleam        the abstract syntax tree
src/hive/parser.gleam     tokens       -> AST (recursive descent)
src/hive/codegen.gleam    AST          -> Go source
src/hive/runtime.gleam    the fixed Go `hive` runtime + go.mod
src/hive/compiler.gleam   glue: source -> Go source
src/hive/cli.gleam        writes the Go project, drives the Go toolchain
```

Run the tests with `gleam test`.

## Scope

Per the project brief, the compiler currently targets exactly the constructs
that appear in `code-examples/`. The lexer, parser, and code generator are
written to be extended, but there is no full type checker, generics syntax,
or standard library beyond the `Table`/`Result` builtins yet.
