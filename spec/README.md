# The Hive Language Specification

Hive is a memory-managed, table-based language that compiles to Go. Tables are a
built-in idea rather than a library, values behave like values, and a good deal
of what other languages leave to runtime — every vector index, every branch of a
match, the columns a SQL query comes back with — is settled at compile time.

This directory is the language's normative reference. It describes Hive as the
language is, not as any one compiler happens to implement it; where the two
differ, [18 — Conformance](18-conformance.md) says so explicitly and names the
gap.

Source files end in **`.hive`**. The standard library is reached as **`hive.*`**.

## Contents

| | |
| --- | --- |
| [01 — Lexical structure](01-lexical.md) | source text, comments, tokens, literals, and what a name may look like |
| [02 — Grammar](02-grammar.md) | the whole surface syntax, in EBNF |
| [03 — Types](03-types.md) | scalars, vectors, `Result`, declared types, function types, maps |
| [04 — Declarations](04-declarations.md) | `type`, `func`, `proc`, `query`, `test`, `import` |
| [05 — Expressions](05-expressions.md) | operators, precedence, calls, interpolation, arithmetic at the edges |
| [06 — Statements](06-statements.md) | bindings, assignment, control flow, `echo` / `assert` / `panic` |
| [07 — Patterns](07-patterns.md) | `is`, its four pattern kinds, the two kinds of string hole, narrowing and exhaustiveness |
| [08 — Mutability and value semantics](08-mutability-and-values.md) | `mut`, mutex parameters, copy-on-binding |
| [09 — Concurrency](09-concurrency.md) | `async`, the await-all, `with timeout` |
| [10 — Bounds](10-bounds.md) | how every index and slice is proved in range |
| [11 — Generics](11-generics.md) | type variables and monomorphization |
| [12 — Modules](12-modules.md) | `import`, the four path kinds, flattening, name resolution |
| [13 — Builtins](13-builtins.md) | the globally-available functions |
| [14 — Standard library](14-stdlib.md) | the `hive.*` modules |
| [15 — Lowering to Go](15-lowering.md) | what each construct becomes |
| [16 — Testing](16-testing.md) | `test`, `assert` inside one, coverage |
| [17 — Diagnostics](17-diagnostics.md) | the error format and what an editor can do with it |
| [18 — Conformance](18-conformance.md) | what an implementation must do, and this repository's status |

## How to read this

**Normative language.** *Must*, *must not* and *is a compile error* state
requirements on a conforming implementation. *May* marks a genuine choice left
open. *Unspecified* marks a case whose result a program must not depend on;
there is exactly one of those, and [05](05-expressions.md#unspecified-behaviour)
names it.

**Compile time versus run time.** Hive settles an unusual amount before the
program runs, so the distinction is load-bearing throughout. A rule stated as a
*compile error* is checked by the compiler and can never be observed at run
time; a rule stated as a runtime result (`a / 0` is `0`) is a value the running
program produces.

**Grammar notation.** [02](02-grammar.md) uses EBNF: `|` alternation,
`[x]` optional, `{x}` zero or more, `(x)` grouping, `"x"` a literal token.
Nonterminals are `lower-case-hyphenated`. Terminals produced by the lexer are
`UPPER_CASE`.

**Examples.** Every example is Hive unless its fence says otherwise. Examples
marked `// compile error:` do not compile, and the comment is the reason.

## The shape of a compiler

A conforming implementation is free to be organised however it likes, but the
order the checks happen in is partly observable — a bounds proof rests on types
having been resolved, and generic monomorphization must precede every check that
follows it, since each instantiation is checked separately. The pipeline this
specification is written against is:

```
source text
   ↓  lexer            (01)
tokens
   ↓  parser           (02, 04, 05, 06, 07)
one module's AST
   ↓  loader           (12)   import graph, cycle rejection, flattening
one program's AST
   ↓  monomorphizer    (11)   one copy per set of type arguments
   ↓  checker          (03, 04, 06, 07, 08)   names, types, purity, mutability,
   ↓                                          exhaustiveness, terminating paths
   ↓  bounds           (10)   flow-sensitive index and slice proofs
   ↓  emitter          (15)   Go source
Go project
   ↓  the Go toolchain
a native executable
```

The passes after the loader run on a **flattened** program: one module holding
every declaration the entrypoint reaches, each renamed to a name unique across
the program. [12](12-modules.md) specifies the flattening and what it costs in
diagnostics.
