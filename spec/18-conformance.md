# 18 — Conformance

This chapter is about implementations rather than about the language. It says
what a conforming one has to do, and then what **this** one does — including
where it falls short, which is the part worth reading.

## 18.1 What a conforming implementation must do

1. **Accept every program this specification describes**, and reject every one it
   describes as a compile error. A rejection must name the thing at fault
   ([17](17-diagnostics.md)).
2. **Settle at compile time everything the specification says is settled then**:
   every vector index and slice ([10](10-bounds.md)), every generic
   instantiation ([11](11-generics.md)), every atom's value
   ([03](03-types.md#atom)), the exhaustiveness of a terminating chain
   ([04](04-declarations.md#44-returning-on-every-path)).
3. **Preserve value semantics.** Storage an immutable binding observes is never
   mutated in place afterwards ([08](08-mutability-and-values.md)). *How* that is
   preserved — where copies go, which aliases are proved safe — is an
   implementation's own business, but the invariant is not.
4. **Evaluate every expression exactly once** per time control reaches it, an
   `assert`'s operands included ([16](16-testing.md#assert-evaluates-once)).
5. **Report against `file:line:`** so an editor can jump to it
   ([17](17-diagnostics.md#171-the-format)).
6. **Exit non-zero when a test fails** ([16](16-testing.md)).

An implementation may choose freely how it lowers anything, so long as what the
program does is what this specification says it does. Two implementations may
generate very different Go and both be right.

## 18.2 This implementation

`hivec`, in `../src`, is written in Hive and compiles to Go. It compiles itself,
and it drives the Go toolchain itself: `hive build` writes a Go module and then
runs `go build` over it, through
[`hive.term.exec`](14-stdlib.md#145-hiveterm). There is no wrapper script doing
part of the job.

**It is a fixpoint of itself.** `../selfhost` builds stage 2 with stage 1 and
stage 3 with stage 2, and checks that the two emit byte-identical Go. They do.
That is the test that says a self-hosted compiler works: the language it accepts
and the code it writes are the same on both sides, and nothing about whatever
compiled it first is left in it. `../bootstrap` builds it with itself and with
nothing else — the compiler that first compiled it is no longer part of this
project.

**It runs every example.** [`../examples`](../examples) holds twenty-one
programs, and they are the same programs the compiler this one replaces was
written against: three servers, a database, a distributed pair of nodes, a
password vault, a chat with a user interface, a multiplayer game with a 3D
scene, and the tours of the language itself. `../examples/run` compiles and runs
them, and the five with test suites of their own contribute 155 tests more. That
is the other half of what "implemented" means here: not that the compiler
accepts the specification's grammar, but that it builds the programs the
specification was written for.

### What is implemented

All of it.

| | |
| --- | --- |
| lexing | all of [01](01-lexical.md), including interpolation, backtick strings, atoms, query bodies and import paths |
| parsing | all of [02](02-grammar.md), query bodies and their `WHERE` blocks included |
| modules | local `.hive` imports, Go file imports, git repository imports with a shared clone cache and a lock file, standard library aliases, cycle rejection, flattening ([12](12-modules.md)) |
| the toolchain | `build`, `run` and `test` drive `go` themselves, a test run is reported and exits non-zero when it failed ([16](16-testing.md)), and the one build that links anything from outside Go's standard library resolves it first |
| generics | monomorphization: one copy per set of type arguments, read off the argument types, for callables and types alike ([11](11-generics.md)) |
| bounds | every index and slice proved in range, flow-sensitively: declared and inferred lengths, guards, counting loops, `indexOf`, and what an assignment or a `drop` costs ([10](10-bounds.md)) |
| checks | names, arity, named arguments, argument and return types, the proc/func split, mutability, terminating paths, exhaustiveness, conditions, subscripts, `async`'s three refusals, pattern shapes, a query's rows and its bound values ([04](04-declarations.md), [06](06-statements.md), [07](07-patterns.md), [08](08-mutability-and-values.md)) |
| value semantics | copy-on-binding, type-directed deep copies, two `mut` names sharing one header, mutex parameters as pointers ([08](08-mutability-and-values.md)) |
| concurrency | `async` as a statement, the `async` binding, the await-all, `with timeout` ([09](09-concurrency.md)) |
| patterns | all four kinds, with narrowing through `&&` ([07](07-patterns.md)) |
| builtins | all of [13](13-builtins.md) |
| standard library | every module of [14](14-stdlib.md): `hive.conv`, `hive.math`, `hive.map`, `hive.file`, `hive.term`, `hive.task`, `hive.time`, `hive.json`, `hive.crypto`, `hive.net`, `hive.syslink`, `hive.sql`, `hive.ui` and `hive.ui.scene` |
| reading tables | every `using` form: CSV, xlsx, ods, a declared `query`, and `run raw` ([14.6](14-stdlib.md#146-reading-tables-using)) |
| testing | `test` declarations, `assert` with both sides, per-declaration coverage, the report ([16](16-testing.md)) |

A module nothing reaches for is still not in the build: what a program links is
what it named. `hive.sql` is the one that carries dependencies (its two drivers)
and `hive.ui.scene` the one that carries a download (a pinned three.js, fetched
once against its SHA-256 and embedded), and a program that opens no database and
draws no scene fetches neither.

### Where it deviates

These are places where this compiler does what the specification describes by a
different route, or does not quite do it.

* **`==` and the default `sort` order use reflection.** The specification says
  both are emitted inline from the static type, with no runtime reflection
  ([08](08-mutability-and-values.md#85-what-a-copy-copies),
  [13](13-builtins.md#putting-a-vector-in-order-sort)). Here they go through
  `hive.Eq` and `hive.Less`, which use `reflect`. The *semantics* are the ones
  specified — structural equality, field-by-field ordering in declaration order,
  variant order first for a union (registered by the compiler, since reflection
  cannot know it) — and only the cost differs. Deep **copies** are type-directed
  as specified, with no reflection.
* **Copy-on-binding is conservative.** The four-way table in
  [08](08-mutability-and-values.md#84-copy-on-binding) is implemented as: two
  immutable ends alias, two `mut` ends alias, a mixed pair copies. The
  specification allows an alias in a mixed pair when it is *provably*
  indistinguishable; this compiler does not attempt the proof, so it copies where
  a cleverer one would not. That is slower and never wrong.
* **Coverage names a declaration as the flattened program spells it.** With more
  than one file in the program, `never exercised` reads `cart_0_describe` rather
  than `describe` ([16](16-testing.md#coverage-is-not-a-separate-command)), because the report is written
  from the flattened module and nothing maps a name back to the file it came
  from. The per-file breakdown that chapter describes is not printed, for the
  same reason.
* **A test failure names the generated file.** The specification says a failure
  reports the `.hive` line, through `//line` directives
  ([15](15-lowering.md#154-source-positions)). Here it reports `main_test.go`,
  because the tree carries no positions past the parser — the same reason
  [17](17-diagnostics.md#173-two-limits-worth-knowing) gives for the other
  passes reporting against a declaration.
* **The bounds pass proves less than it could.** Everything
  [10](10-bounds.md) describes is implemented, and it is conservative in three
  places the specification leaves open: a proof is keyed on a *path* — a name, a
  field, a row at a literal index — so a guard on anything else proves nothing;
  two names for one vector each need their own guard; and what one conjunct of a
  guard proves is not carried into a later conjunct of the same guard, so
  `if v bounds i && v[i] > 0` is refused where `if v bounds i { if v[i] > 0 }`
  is not. All three refuse a program the specification permits rather than
  accepting one it forbids, which is the safe direction to be wrong in.
* **A local that is never read still compiles.** Hive allows it and Go does not,
  so every generated local is followed by `_ = name`. That is noise in the
  generated Go and nothing else.
* **A message's digest is hashed at run time.** The specification says every
  frame carries a 32-bit structural digest of the message type
  ([14.10](14-stdlib.md#1410-hivesyslink)) and this compiler writes the
  *signature* — the type's spelling and every variant and field it declares — for
  the runtime to hash on the way out. FNV-1a wants exclusive-or and a byte's
  value, and Hive has neither, so the hash is one line of Go instead of thirty of
  Hive. What matters is that both ends of a wire compute the same number from the
  same declaration, and they do.
* **An address does not carry its mailbox type.** `hive.syslink.Address` is one
  type rather than one per protocol, and what a send answers with is read off the
  *message* instead — which is the same type, since a service answers with one of
  its own messages. The effect is the one the specification describes; what is
  missing is the compile-time refusal of a send whose message is not the
  mailbox's.

## 18.3 Defects found in the compiler this one replaces

Writing this one turned up four things wrong with the compiler it was first built
by. That compiler is gone — Hive builds Hive now, and `../bootstrap` reaches for
nothing else — so these are recorded for one reason only: each is a
language-level fact somebody else could meet again, and three of them are things
this compiler had to be written around.

1. **`assert` evaluates its operands twice.** In a generated test, a comparison
   is emitted once for the check and again for the report, so
   `assert parseSum(p) == 42` runs `parseSum` twice — silently, whether the
   assertion holds or not. [16](16-testing.md#assert-evaluates-once) states the
   rule; this compiler binds each side to a temporary first.
2. **`==` on a tagged union crashes when the variant holds a vector.** It lowers
   to Go's own `==`, which panics on an interface holding a struct with a slice
   in it. A structural comparison is what the language means. This compiler emits
   `hive.Eq`.
3. **A call's arity is not checked.** `two(1)` on a `func two(): Int` compiles,
   and fails in the generated Go with a message about Go. This compiler checks it
   ([04](04-declarations.md)).
4. **`v bounds i && w bounds i` generates Go that `go vet` rejects**, because the
   desugaring repeats the `i >= 0` half. The program builds and cannot be tested,
   since `go test` runs vet. This compiler lowers a bounds guard to a single
   `hive.InRange` call.
