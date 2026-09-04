# 04 — Declarations

A file holds imports and then declarations, in any order. There are five kinds
of declaration and no `pub`/`priv` distinction: everything a module declares is
visible to whoever imports it.

## 4.1 `type`

```hive
type User {
	id:   Int
	name: Str
}

type Shape {
	Circle { radius: Int }
	Rectangle { width: Int, height: Int }
	Point
}
```

No variants ⇒ a struct. Variants ⇒ a tagged union. Fields declared outside any
variant are added to every variant. Types and variants are `PascalCase`; fields
are `camelCase`. See [03](03-types.md#34-declared-types).

A type whose fields mention type variables is generic in them, in
first-appearance order ([11](11-generics.md)).

Every declared type gets, derived from its declaration and emitted only where
used: a deep copy, a total order, a JSON codec, and a structural digest. None of
it is written by hand and none of it uses reflection.

### Annotations

A field may be annotated, and both annotations are about the **JSON codec**
derived above — what the field is called on the wire, and what to read where the
wire has nothing:

```hive
type User {
	name: Str -- JSON as username;
	age:  Int
	firstName: Str -- Default as "";
}
```

| written | means |
| --- | --- |
| `JSON as <name>;` | the key this field is read from and written as |
| `Default as <literal>;` | what to use where JSON has `null` or nothing at all |

A `--` opens them and each clause ends at its `;`, so **they may be written in
any order** and a field may carry one, both or neither:

```hive
theme: Str -- JSON as colour_scheme; Default as "light";
theme: Str -- Default as "light"; JSON as colour_scheme;   // the same field
```

These are **compile-time**, and nothing about the Hive side of the field
changes: it is still `user.name` whatever JSON calls it, still ordered and
copied and compared as it was, and still `name` in every message the compiler
writes about it.

**`JSON as` takes a name rather than a Hive one.** A key is somebody else's, so
it is held to none of Hive's shapes — `user_name` is a key and so is
`"user-name"`, written as a string where it is not a word at all. **Two fields
of one object may not answer to one key**, which is a compile error naming it:
the decoder would read the same member twice and the encoder would write it
twice.

**`Default as` takes a literal** — an `Int`, `Float`, `Str`, `Bool` or `Atom`,
with a leading `-` where a number is negative — and it must be a value the field
can hold, checked against the declared type. What it stands in for is a key that
is **absent** and a key that is present and **null**, which are one nothing:
without it, either is an error. It stands in for nothing else, so a value of the
wrong type is still an error — a default is for what was never said, not for
what was said wrongly.

An annotation reaches a variant's own fields and the shared ones alike, and a
shared field is annotated once for every variant it joins.

Neither annotation changes what `hive.json.parse(text) with Table` does: that
flattens a document rather than decoding a declared shape, so there is nothing
there for a field to be named.

## 4.2 `func`

```hive
func greet(name: Str, style: Greeting): Str {
	if style is Greeting.Formal(title) {
		return "Good evening, {title} {name}."
	}
	return "Hey {name}!"
}
```

A `func` **may perform I/O** — `echo`, `using`, `hive.net` are all allowed. It
differs from a `proc` in exactly two ways:

1. it cannot declare a mutex parameter (`v: mut T`); a `mut` value passed to a
   `func` is seen as an ordinary immutable copy instead, and
2. it cannot call a `proc`.

What a `func` promises, then, is not purity in the mathematical sense but that
**it cannot write to storage its caller can see**. That is exactly what makes an
imported Go function a `func` ([12](12-modules.md#124-importing-a-go-file)): the
boundary copies in both directions, so nothing on the far side can reach back.

## 4.3 `proc`

```hive
proc grow(vec: mut Str[dyn], tag: Str): void {
	append(vec, tag)
}
```

A `proc` may do everything a `func` may, plus declare mutex parameters and call
other procs. Programs start at `proc main(): void`, in the file handed to
`hive build` / `hive run`.

## 4.4 Returning on every path

Every non-`void` `proc` and `func` must **return on every path**. A path
terminates by ending in:

* `return`;
* `assert` or `panic` — both handy for a tail you know is unreachable;
* an `if`/`else` whose every branch terminates; or
* an else-less `if`/`else if` chain that covers its subject's whole type — a
  `Result`'s `Ok` and `Error`, or every variant of a declared union.

Anything else is a compile error. The last case is what lets a total function
over a union be written without a dead `else`:

```hive
func describe(shape: Shape): Str {
	if shape is Shape.Circle(r)         { return "circle" }
	else if shape is Shape.Rectangle(w, h) { return "rectangle" }
	else if shape is Shape.Point        { return "a point" }
}                                       // no `else` — and dropping one is an error
```

## 4.5 `query`

A `query` is a `func` whose body is inline SQL and whose **return type describes
its rows**.

```hive
type User {
	id:   Int
	name: Str
}

query findUser(name: Str): User[dyn] {
	SELECT id, name FROM users WHERE name = {name}
}

query userNames(): Str[dyn] {      // one column needs no row type
	SELECT name FROM users
}

query deleteUser(id: Int): void {  // a statement reports what it touched
	DELETE FROM users WHERE id = {id}
}
```

| declared | `using conn run q(...)` yields |
| --- | --- |
| `Row[dyn]` (a declared type) | `Result<Row[dyn], hive.sql.SqlError>` |
| `Str[dyn]`, `Int[dyn]`, … | that column, as a vector |
| `void` | `Result<Int, hive.sql.SqlError>` — the rows it affected |

Rules the compiler enforces:

* **Columns match fields by name**, so reordering the `SELECT` cannot silently
  remap them. A column whose name differs from its field needs an alias
  (`SELECT u.name AS author`). A row type holds scalars only.
* **`SELECT *` against a declared row type is a compile error.** It says neither
  how many columns come back nor what they are called, and what it stands for
  changes the day somebody adds a column. The rule is about the *result*, so
  `count(*)`, `a * 2`, a star inside a subquery and a `void` statement's select
  list all still compile.
* **Values are bound, never spliced.** An interpolated `{param}` becomes a
  placeholder and the value travels beside the text, so nothing a caller supplies
  can change what a statement means. Queries are written with `?` and rewritten
  to `$1, $2, …` for PostgreSQL by the connection, which is what lets one
  declaration serve both drivers.

### Optional filters: `WHERE { }`

A `WHERE` block ANDs the predicates whose conditions hold; a nested `or { }` or
`and { }` flips the connective:

```hive
query findColonies(apiary: Str, minFrames: Int, small: Bool, huge: Bool): Colony[dyn] {
	SELECT name, apiary, frames FROM colonies
	WHERE {
		if apiary != ""  { apiary = {apiary} }
		if minFrames > 0 { frames >= {minFrames} }
		or {
			if small { frames < 4 }
			if huge  { frames > 10 }
		}
	}
	ORDER BY name
}
```

A group that contributes nothing disappears rather than leaving a dangling
connective, and if no predicate is present at all there is no `WHERE` clause — so
there is no `WHERE 1 = 1` to write. A group contributing more than one predicate
is parenthesised. Every branch's text is fixed at compile time; only which
branches are taken is decided at run time.

Two things a `WHERE` block deliberately cannot do. A **column name or sort
direction** can never be a parameter — `ORDER BY {col}` would sort by a constant
string — so make the choices a variant type and dispatch to one query per
ordering. And **SQL you genuinely assemble yourself** goes through
`run raw`, which is untyped by construction and greppable by design.

## 4.6 `test`

```hive
test "an empty cart costs nothing" {
	Item[0] empty = []
	assert total(empty) == 0
}
```

A test is named **in prose** because a test name is documentation, not something
anything calls — and for the same reason it takes no parameters and returns
nothing. `return value` inside one is a compile error; a bare `return` to leave
early is fine. Its body is an ordinary `proc` body. See [16](16-testing.md).

## 4.7 Nothing about a declaration says how it runs

**Every call blocks its caller.** There is no `async func`, no Future and no
Promise type to name; what a call means is decided where it is written
([09](09-concurrency.md)). This is why the two callable kinds are about *what a
body may do*, never about *when it happens*.
