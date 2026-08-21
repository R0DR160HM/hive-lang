# 15 — Lowering to Go

Hive lowers to Go, and the Go toolchain turns that into the executable. You never
have to read the result, but a handful of Hive's rules are easier to trust once
you know what they become.

The whole program becomes **one Go package**, plus one package per imported Go
file, plus a generated `hive` runtime package.

## 15.1 The mapping

| Hive | Go |
| --- | --- |
| `proc` / `func` | an ordinary `func`; `proc main(): void` → `func main()` |
| `query q(p: Str): Row[dyn]` | a function returning SQL text with `?` plus the bound args |
| `type T { }` / `type T { A {..} B }` | a `struct` / an `interface` + one struct per variant |
| fields declared outside any variant | appended to **every** variant struct |
| `Str` `Int` `Float` `Bool` `Atom` | `string` `int` `float64` `bool` `hive.Atom` |
| `Str[3]`, `Str[dyn]`, `Str[]` | `[]string` — all three, which is why value semantics exist |
| `test "..." { }` | a `t.Run(...)` in a generated `main_test.go`, run by `go test` |
| `assert c` (ordinary code) | `hive.Assert(c)` — a panic |
| `assert c` (inside a `test`) | a recorded failure quoting `c` and, for a comparison, both sides |
| `mut` (on a declaration) | nothing at all: it is compile-time only |
| `mut b = a` (both `mut`, owns storage) | no variable — `b` compiles to `a`, so one slice header is shared |
| `ys := xs` (needs a copy) | a generated deep clone, chosen by the static type |
| `f(mutVec)` (argument names `mut` storage) | `f(hive.CloneVec(mutVec))` |
| `p(v: mut T)` (a mutex parameter) | `p(v *T)`, read and written through `(*v)` |
| `p(mutVec)` (waited for) | `p(&mutVec)` — the callee writes the caller's own storage |
| `async p(mutVec)` (fired off) | `{ _a0 := hive.CloneVec(mutVec); go p(&_a0) }` |
| `f(x)` / `async f(x)` | a plain call / `go f(x)` |
| `x := async f(a)` | `_task_x := hive.Spawn(..)`, and every read of `x` becomes `_task_x.Await()` |
| `f(x) with timeout ms` | `hive.AwaitTimeout(hive.Spawn(..), ms)` → a `Result` |
| `await [f(a), f(b)]` | `hive.AwaitAll(..)` over one `hive.Spawn` each → a statically-sized vector |
| `addr(m)` / `async addr(m)` | a send that waits for its answer / `hive.SyslinkSend(..)`, which cannot fail |
| `append(v, x)` (a statement) | `v = append(v, x)` — Go's own, with the new header written back |
| `prepend(v, x)` / `drop(v, a, b)` | `hive.Prepend(&v, x)` / `hive.Drop(&v, a, b)` — the address, since both rewrite the header |
| `for each x in v { }` | `for _, x := range v { }` |
| `x is Result.Ok(v)` / `x is T.Variant(a, _)` | `IsOk()` + accessor / a type assertion; `_` binds nothing |
| `if <call> is Result.Ok(v)` | one `if` with an init slot, so the call is evaluated once |
| `"{a} and {b}"` | concatenation, non-`Str` pieces via `hive.ToStr` |
| `[x, y] + [z]` / `v1 == v2` | `hive.Concat(..)` / `hive.VecEq(..)` (structural) |
| `t[1:3]` | `t[1:4]` — Hive's high bound is **inclusive** |
| `#Atom` | a small integer constant + a generated atom table |
| `a / b`, `a ** b`, `a % b` | `hive.DivInt`, `hive.PowInt`, `hive.ModInt` ([05](05-expressions.md#57-arithmetic-at-the-edges)) |
| `echo v` / `panic v` | `fmt.Println(v)` / `panic(hive.Show(v))` |
| `f` (bare reference) / `f(a, _, c)` | the function value / a closure whose parameter is the hole |
| `func f(v: T[]): T` at `T = Str` | `func f_Str(v []string) string` — one copy per instantiation |
| `using p` / `using conn run q(..)` / `run raw t` | `hive.ReadCSV(..)` / `hive.SqlRows(..)` / `hive.SqlQuery(..)`, each → a `Result` |
| a `hive.*` library call | a call of the same name on the generated `hive` runtime package (`hive.json.parse` → `hive.JsonParse`) |
| `import hive.ui as ui`, then `ui.row(..)` | nothing — the alias is resolved during flattening, so the emitter only ever sees `hive.ui.row` |
| `hive.map.Map<Str, Int>` | `hive.Dict[string, int]` — a key order beside a Go map |
| `import ./util.go`, then `util.slugify(s)` | the file compiled as its own package, plus a wrapper `func util_0_slugify(s string) string { return ffi_util_1.Slugify(s) }`, with a copy around every value that owns storage |
| `Msg.Changed(_)` (a constructor hole) | `func(_h0 string) Msg { return Msg(MsgChanged{Text: _h0}) }` |
| `ui.row(attrs, kids)` / `ui.Tone.Danger()` | `hive.UiRow(..)` / `hive.Tone("Danger")` |
| `Result<T, E>`, `Table`, `hive.TableError` | provided by the runtime package |

## 15.2 Two rules worth stating outside the table

**Returning on every path.** For an accepted callable that doesn't syntactically
end in `return`, the emitter appends a `panic("hive: unreachable")` to satisfy
the Go compiler. It is genuinely unreachable, because
[04](04-declarations.md#44-returning-on-every-path) already proved it.

**Go keywords.** A Hive identifier that happens to be a Go keyword but not a Hive
one (a variable or function named `map`, `range`, `select`, …) is suffixed with
`_` in the generated Go — consistently at its definition and every use — so it
never collides with Go's own grammar.

## 15.3 Local type inference in the emitter

The emitter runs a lightweight type-inference pass over locals so overloaded
syntax picks the right lowering: `+` on vectors versus strings versus numbers,
atom → `Str` coercions, zero-safe division, vector literal element types.

The same pass decides the constructs that have **no honest lowering** —
indexing a `Str` is the one that exists today — so they are rejected as Hive
errors rather than emitted as code that either fails to compile or quietly means
something else.

## 15.4 Source positions

The generated Go carries `//line` directives pointing back at the `.hive` file,
so a panic's stack trace and a test failure both name the author's file and line
rather than the compiler's. A `//line` directive has to start at column 1, which
is why the generated code is laid out the way it is.

## 15.5 The generated project

```
<entry>.hive-build/
	go.mod
	main.go              the whole program, one package
	main_test.go         only for a test run
	hive/
		runtime.go       always
		conv.go          only if the program references hive.conv
		json.go          only if ...
		...
	ffi_<name>_<n>/      one package per imported Go file
```

`go.mod` names no dependency unless the program reached for one of the two
modules that have any ([14](14-stdlib.md)). A build that sees a third-party
import in an FFI file runs `go mod tidy` first.
