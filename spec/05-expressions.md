# 05 — Expressions

Precedence and the full expression grammar are in
[02](02-grammar.md#26-expressions). This chapter is what the forms mean.

## 5.1 Literals

`42`, `3.14`, `"text"`, `` `raw text` ``, `true`, `false`, `#Atom`, and
`[a, b, c]` for a vector.

A vector literal's element type is the type its elements share; an empty one
takes its type from where it lands. A literal's length is **static**, which is
what makes `v := ["a", "b"]` a `Str[2]`.

## 5.2 String interpolation

`"{expr}"` splices a value into a string. A non-`Str` piece is rendered the way
`echo` renders it. `\{` is a literal brace.

```hive
echo "loaded {len(rows)} of {total}"
```

Interpolation is the only implicit conversion in the language, and it goes one
way: a value becomes text, never the reverse.

## 5.3 Calls

A call is `callee(args)`. Every call **blocks its caller**
([09](09-concurrency.md)).

### Named arguments

Funcs, procs, queries and type constructors — builtin ones included — accept
arguments by name:

```hive
f(b: 1, "s")
```

Named arguments may appear anywhere; only the unnamed ones need to be in order,
filling whichever parameters the named ones did not claim. Names must exist,
must not repeat, and **once named arguments are used the call must cover the
full parameter list**.

## 5.4 Function values

A callable is a value you can pass, store and call later. Two spellings produce
one:

**A bare reference** — the callable's name on its own:

```hive
f := takes
```

**A partial application** — a call with `_` holes:

```hive
handler(_, db)          // a func of one argument; `db` is captured here
hive.net.httpServe(8080, handler(_, db))
```

Each `_` becomes a parameter of the resulting function, in hole order, and
everything supplied is captured by value where it was written.

A **constructor** may be partially applied too, and it means the same thing:
`Msg.Changed(_)` is a `func(Str): Msg` that builds the variant. It is not a
callable — there is no body to run and no declared return type to read — but each
`_` still becomes a parameter in hole order, and what comes back is typed as the
union, since that is what a variant is once built.

Three things cannot become values:

* a **generic** callable — which copy a call reaches is decided by the argument
  types, and a value carries none;
* a callable with a **mutex parameter** — a function value has no call site to
  take a mutex from;
* a callable with a **statically-sized parameter**, beyond one immutable local
  binding it is called through. See
  [10](10-bounds.md#a-promise-restricts-a-callable-as-a-value).

## 5.5 Member access, indexing, slicing

`x.field` reads a field. `x.moduleMember` reads through an import alias — the two
are told apart by what the left side names.

`v[i]` indexes. `v[lo:hi]` slices, **both bounds inclusive**: `t[1:3]` is three
elements. Either bound may be omitted (`v[:2]`, `v[1:]`, `v[:]`). Every index and
slice is proved in range at compile time ([10](10-bounds.md)).

A `Str` is subscripted the same way and **by character**, yielding a one-character
`Str` ([03](03-types.md#str)). It may not be assigned into by position. A map has
no subscript at all ([03](03-types.md#36-maps)).

## 5.6 Operators

| operator | on | yields |
| --- | --- | --- |
| `+` | `Int`, `Float` | the sum |
| `+` | `Str` | concatenation |
| `+` | vectors | a **new** vector, lengths added |
| `-` `*` `/` `%` `**` | `Int`, `Float` | arithmetic |
| unary `-` | `Int`, `Float` | negation |
| `==` `!=` | any two values of one type | structural equality |
| `<` `>` `<=` `>=` | `Int`, `Float`, `Str` | ordering |
| `&&` `\|\|` | `Bool` | short-circuiting conjunction, disjunction |
| `is` | see [07](07-patterns.md) | a `Bool`, binding as it matches |
| `bounds` | a vector and an `Int` | sugar for `i >= 0 && i < hive.len(v)` |

`%` is the remainder operator and has the same precedence as `*` and `/`.

**There is no unary `!`.** The only prefix operator is `-`, and `!` exists solely
as the first character of `!=`. A negated condition is written by comparing:

```hive
if found == false { ... }
if indexOf(v, x) is Result.Error(_) { ... }
```

That is a deliberate consequence of `is` being an expression: most conditions
worth negating are matches, and `is` has no negated form either — the `else` is
where the other case goes.

`==` on a vector compares structurally, element by element, short-circuiting on
the first difference; on a map it compares the pairs and ignores the order they
were set in; on a declared type it compares field by field. Comparing values of
two different types is a compile error, not a silent `false`.

There is **no** implicit numeric conversion in any of these
([03](03-types.md#39-assignability)).

## 5.7 Arithmetic at the edges

Most of arithmetic is unsurprising. These are the cases worth stating exactly:

| expression | result |
| --- | --- |
| `a / 0`, `a % 0` (`Int` or `Float`) | `0` — division and remainder by zero are values, not crashes |
| `Int` overflow (`+ - * **`) | wraps, two's-complement, silently |
| `2 ** 100` | `0` — the wrap above, reached by repeated multiplication |
| `n ** k` with `k < 0` (`Int`) | `0`, including `1 ** -1` |
| `n ** 0` | `1` |
| `-7 % 3` | `-1` — the remainder takes the sign of the dividend |
| `10.0 ** 400.0` | `+Inf` — `Float` arithmetic does produce non-finite values |

`**` on `Int`s is repeated multiplication and wraps the same way. A negative
`Int` exponent has no integral answer, so it yields `0` rather than a fraction.
For the mathematical answer, work in `Float`, where `**` is real exponentiation.

### Unspecified behaviour

Converting a `Float` that is `+Inf`, `-Inf`, `NaN`, or simply too large to an
`Int` (`hive.conv.ceil`, `floor`, `round`) is the **one** unspecified case in the
language. Go leaves that conversion implementation-dependent and Hive does not
paper over it, so the value may differ between Go versions and architectures.
Non-finite values reach a program through `Float` overflow and through
`hive.conv.stf("Inf")`, so check the range you expect before converting if it
matters.

## 5.8 `with` clauses

Two unrelated clauses share the `with` keyword, told apart by the word after it.

**`with timeout <ms>`** bounds a wait, and may follow anything that waits — a
call or an await-all. It turns the result into
`Result<T, hive.task.TimeoutError>`. See
[09](09-concurrency.md#94-with-timeout).

**`with <Type>`** names a decode target, for the calls whose result shape is a
type you choose: `hive.json.parse(text) with User`,
`hive.crypto.jwtVerify(token, secret) with Claims`.

`timeout` is **not** a reserved word: it means something only in this two-token
clause, so it stays usable as an ordinary variable name. Correspondingly,
`with Timeout` names a decode target, and a type may well be called that.

## 5.9 `using`

`using` reads a table, and each form says in the source what it is reading —
which is what lets the compiler pick the reader and leave the machinery for the
others out of the build. See [14](14-stdlib.md#146-reading-tables-using).

## 5.10 Evaluation order

Operands are evaluated left to right. `&&` and `||` short-circuit: the right
operand is evaluated only if the left did not decide the answer. This is what
makes `if x is T.A(v) && v == "ok"` legal — `v` exists only because the left
side matched.

Every expression is evaluated **exactly once** per time control reaches it. In
particular, an operand of `assert` runs once, whether the assertion holds or not
([16](16-testing.md#assert-evaluates-once)).
