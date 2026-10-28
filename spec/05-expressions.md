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
way: a value becomes text, never the reverse. A [`Secret`](03-types.md#311-secret),
or anything holding one, is never interpolated.

## 5.3 Calls

A call is `callee(args)`. Every call **blocks its caller**
([09](09-concurrency.md)).

### Named arguments

Every call accepts arguments by name — funcs, procs, queries, type
constructors, the builtins and every library call:

```hive
f(b: 1, "s")
```

Named arguments may appear anywhere; only the unnamed ones need to be in order,
filling whichever parameters the named ones did not claim. Names must exist,
must not repeat, and **once named arguments are used the call must cover the
full parameter list**. They are evaluated in the order they are written, whatever
order the parameters come in.

A builtin's parameters are called what [13](13-builtins.md) calls them, and a
library call's what [14](14-stdlib.md) does: `join(sep: ",", vector: names)`,
`hive.math.clamp(value: x, low: 0.0, high: 1.0)`. A builtin position that is
overloaded by type answers to each of its names, so `len(str: s)` and
`len(vector: v)` are both `len`. A function value is the one call whose
parameters have no names.

### Piping a value in

`x | f(a)` is **sugar** for `f(x, a)`: the value on the left becomes the call's
first argument. `|` is left-associative, so a chain of them reads in the order
it runs:

```hive
echo nums | filter(isEven) | map(label) | join(" ")
```

The right side has to be something that can be called — a call, a callable's
name, or a constructor — and a stage with nothing else in it needs no
parentheses: `x | f` is `f(x)`, as `x | f()` is. A `proc`, a builtin and a
constructor all pipe, and a `_` in a stage still makes that call a partial
application, since what a pipe leaves behind is the call somebody could have
written by hand.

`|` binds tighter than every binary operator and looser than the prefix ones,
which lets a pipeline sit on either side of one — `v | len > 2` compares the
length. It takes the value written **beside** it, so `1 + 2 | f` is `1 + f(2)`
and a computed value goes in parentheses: `(1 + 2) | f`.

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

A constructor has **no bare reference**: a variant is a value once it is built,
so `Msg.Changed` on its own is a compile error and the hole is what makes one a
function value ([03](03-types.md#34-declared-types)).

**A callable with a `mut` parameter is a value like any other.** `f := grow` is a
`proc(mut Str[dyn], Str): void`, and `grow(_, "x")` a `proc(mut Str[dyn]): void`.
A `mut` position in a partial application has to stay a hole: what is supplied is
captured by value, so writes through it would land in a copy nobody sees.

**A call through a function value is held to the value's type**: how many
arguments, what each one is, and a `mut` variable or a path into one wherever the
type says `mut` ([8.2](08-mutability-and-values.md#82-mut-parameters)). A
function value's parameters have no names, so its arguments go by position.

Two things cannot become values:

* a **builtin** or a **library call** — neither a bare reference nor a `_` hole
  makes one a value. Several builtins are overloaded, and a library call has no
  signature a value could carry. Wrap it in a `func` of your own, and use that;
* a **generic** callable — which copy a call reaches is decided by the argument
  types, and a value carries none.

A callable with a statically-sized parameter is a value like any other, and its
type carries the promise — see
[10](10-bounds.md#a-promise-travels-with-a-callable-as-a-value).

## 5.5 Member access, indexing, slicing

`x.field` reads a field. `x.moduleMember` reads through an import alias or a
library module's name ([12](12-modules.md#126-the-standard-library)) — the two are
told apart by what the left side names.

`v[i]` indexes. `v[lo:hi]` slices, **both bounds inclusive**: `t[1:3]` is three
elements. Either bound may be omitted (`v[:2]`, `v[1:]`, `v[:]`). Every index and
slice is proved in range at compile time ([10](10-bounds.md)).

A `Str` is subscripted the same way and **by character**, yielding a one-character
`Str` ([03](03-types.md#str)). It may not be assigned into by position. A map has
no subscript at all ([03](03-types.md#36-maps)).

## 5.6 Operators

| operator | on | yields |
| --- | --- | --- |
| `+` | numbers | the sum |
| `+` | `Str` | concatenation |
| `+` | vectors | a **new** vector, lengths added |
| `-` `*` `/` `%` `**` | numbers | arithmetic |
| unary `-` | signed numbers | negation |
| unary `!` | `Bool` | the opposite |
| `==` `!=` | any two values of one type | structural equality |
| `<` `>` `<=` `>=` | numbers, `Str` | ordering |
| `&&` `\|\|` | `Bool` | short-circuiting conjunction, disjunction |
| `is` | see [07](07-patterns.md) | a `Bool`, binding as it matches |
| `bounds` | a vector and an `Int` | sugar for `i >= 0 && i < hive.len(v)` |
| `\|` | a value and a callable | sugar for the call with the value first |

`%` is the remainder operator and has the same precedence as `*` and `/`.

**Arithmetic wants two numbers of one type**, and answers that type:
`UInt4 + UInt8` is a compile error until one side is converted, `UInt8(a) + b`, and
so is `Float32 + Float`. A literal on one side takes the other side's type, so
`a + 1` on a `UInt4` stays a `UInt4` and `a += 1` works — and a literal that type
cannot hold is a compile error.

**Two integers compare whatever their sizes.** `==`, `!=`, `<`, `>`, `<=` and `>=`
take any two integers and compare their values — a `UInt64` at its largest is not
equal to an `Int` of `-1` — since comparing converts nothing that is kept. That is
what keeps `i < len(v)` and `v bounds i` guards for a sized `i`. Floats of
different sizes do not compare without a conversion, and an integer never compares
with a float.

### Unary `!`

`!` takes a **`Bool`** and answers with the opposite one. Anything else is a
compile error, for the reason a condition may not be one: there is no
truthiness, so there is nothing about an `Int`, a `Str` or an `Atom` to be the
opposite of.

It is a prefix operator at the same level as unary `-`, which puts it **tighter
than every comparison and every conjunction**:

```hive
if !found { ... }              // the whole of what it is for
echo !isEven(3)                // the call is the operand, not `isEven`
if !found && ready { ... }     // (!found) && ready
if !(a == b) { ... }           // parentheses, because `==` is looser
if !(v bounds i) { ... }       // the same, and this proves nothing about `i`
```

`!` is not the only way to say it and does not make the others wrong:
`found == false` is an ordinary comparison and `indexOf(v, x) is Result.Error(_)`
is an ordinary match.

#### No negated match

**`!` may not be applied to an expression holding an `is`.** It is a compile
error, and it is the one `Bool` the operator refuses:

```hive
if !(x is Shape.Circle(r)) { ... }   // compile error: a match cannot be negated
if !(ready && (x is Shape.Point)) { ... }  // the same, through the `&&`
```

The reason is what `is` does beyond answering: it **narrows** the value it
matched and **binds** parts of it, and neither survives being negated — the
branch under a negated match is the branch where the pattern did *not* hold, so
`r` above could never be set. Writing it would be a reader looking at a name
that means nothing.

The other case goes in the `else`, which is where it always went:

```hive
if x is Shape.Circle(r) {
	echo r
} else {
	echo "not a circle"
}
```

The refusal reaches through `&&`, `||` and a second `!`, and no further: `is`
binds looser than every comparison, so those three are the only operators a
match can sit beneath. A `!` **beside** a match is untouched — `!a && (x is P)`
negates `a` and nothing else.

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
| `Int` overflow (`+ - * **`, unary `-`, `/`) | wraps round, two's-complement: `MAX + 1` is `MIN`, `MIN - 1` is `MAX` |
| `2 ** 100` | `0` — the wrap above, reached by repeated multiplication |
| `-MIN`, `MIN * -1`, `MIN / -1` | `MIN` — the one value with no opposite is its own |
| `n ** k` with `k < 0` (`Int`) | `0`, including `1 ** -1` |
| `n ** 0` | `1` |
| `-7 % 3` | `-1` — the remainder takes the sign of the dividend |
| `10.0 ** 400.0` | `+Inf` — `Float` arithmetic does produce non-finite values |

`MAX` and `MIN` are the largest and smallest `Int`, `9223372036854775807` and
`-9223372036854775808`. A sum, difference, product or power that would pass one
comes round from the other, as the machine's own arithmetic does — so a counter
that passes `MAX` turns negative. Compound assignments and `++`/`--` are
arithmetic like any other and wrap the same way. Two literals that overflow
together, `9223372036854775807 + 1`, wrap too, rather than being refused.

`**` on `Int`s is repeated multiplication and wraps the same way. A negative
`Int` exponent has no integral answer, so it yields `0` rather than a fraction.
For the mathematical answer, work in `Float`, where `**` is real exponentiation.

A sized integer follows every row of the table at its own width: a `UInt4` wraps
at 16, an `Int4` at −8 and 7, and `-` on an unsigned type is a compile error, since
it has no negative values to answer with. A `Float32` follows `Float`'s rows in
single precision.

The bounds pass knows a counter can wrap: a counting loop proves its counter's
low half only where it cannot pass `MAX` ([10](10-bounds.md#101-what-counts-as-a-proof)).

### Unspecified behaviour

Converting a `Float` that is `+Inf`, `-Inf`, `NaN`, or simply too large to an
`Int` (`hive.conv.ceil`, `floor`, `round`) is the **one** unspecified case in the
language. Go leaves that conversion implementation-dependent and Hive does not
paper over it, so the value may differ between Go versions and architectures.
Non-finite values reach a program through `Float` overflow and through
`hive.conv.stf("Inf")`, so check the range you expect before converting if it
matters.

## 5.8 `with` clauses

`with` introduces one clause and only one.

**`with timeout <ms>`** bounds a wait, and may follow anything that waits — a
call or an await-all. It turns the result into
`Result<T, hive.task.TimeoutError>`. See
[09](09-concurrency.md#94-with-timeout).

`timeout` is **not** a reserved word: it means something only in this two-token
clause, so it stays usable as an ordinary variable name.

A decode target is not written here. Reading a document into a declared type is
`T.decode(text, codec)`, the decoder that type derives named directly
([14](14-stdlib.md#147-hivejson)).

## 5.9 Evaluation order

Operands, and a call's arguments, are evaluated left to right as written. `&&` and `||` short-circuit: the right
operand is evaluated only if the left did not decide the answer. This is what
makes `if x is T.A(v) && v == "ok"` legal — `v` exists only because the left
side matched.

Every expression is evaluated **exactly once** per time control reaches it. In
particular, an operand of `assert` runs once, whether the assertion holds or not
([16](16-testing.md#assert-evaluates-once)).
