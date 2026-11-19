# 19 — Laws

A **law** is a claim about the program that the compiler proves while it
compiles. Its parameters take every value of their types, and every `assert` its
body reaches has to hold for all of them. A law the compiler cannot prove is a
compile error, and nothing lets a program accept one anyway.

```hive
law cancelledIsFinal(booking: Booking, event: Event) {
	if booking.status is Status.Cancelled {
		assert apply(booking, event).status == booking.status
	}
}
```

A law is never emitted and never runs: proving it is all that happens to it. The
one exception is a type's law, which a decoder runs on what it reads
([19.6](#196-a-types-laws)). A law about a table is a filter rather than a claim,
and is held to every query's SQL ([19.7](#197-a-tables-laws)).

## 19.1 Declaring a law

```
law-decl = "law" IDENT "(" [ params ] ")" block ;
```

A law is named in `camelCase` like every callable, and another module reaches it
as `module.name`. **It has no return type** — writing one is a compile error — and
**none of its parameters may be `mut`**. Its body may hold whatever a `func` body
may, within the limits of [19.4](#194-what-a-law-may-reach).

## 19.2 What a law claims

For every combination of values its parameters can take:

* **every `assert` the body reaches holds**;
* **nothing the body reaches panics or fails an `assert`**, in the law or in any
  callable it calls.

An `assert` under an `if` claims something only where the `if` holds, which is how
a condition is written. A pattern narrows the same way. A law with no `assert`
claims only the second point: that its body runs to the end.

```hive
law parsesEveryNonEmptyLine(text: Str) {
	if text != "" {
		_ := nightsOf(text)        // claims that nightsOf never panics here
	}
}
```

An `assert` is a claim and, from then on, something the body knows: later
statements may rely on it.

Values mean exactly what they mean at run time ([05](05-expressions.md#57-arithmetic-at-the-edges)).
An `Int` wraps round, so `a + 1 > a` is false for `a = MAX`, and a law claiming it
is refused. Division by zero is `0`.

Two assumptions are allowed, and nothing else is:

* **No vector or string holds more than 2^60 elements.** No machine can — a packed
  vector of `UInt1`s that long needs 128 PiB — and it is what lets a length, or
  anything equal to one, have one added to it without wrapping.
* **Nothing is known about `Float` arithmetic.** A law may carry floats and
  compare them, but an implementation need not prove anything that depends on
  what an operation on floats comes to.

## 19.3 Calling a law

**Only a law may call a law**, as a statement of its own; anywhere else it is a
compile error, and so is a law used as a value.

* **Calling another law** hands over its claim for those arguments: the body may
  rely on it from then on. The other law is proved on its own.
* **A law calling itself** is an induction. At least one argument must be, in its
  parameter's place, **a part a pattern took from that parameter** — the rest of
  a vector, an element of one, a field of a variant — so the chain of calls ends.
  A call to itself on anything else is a compile error.
* **Laws may not call each other round in a circle**: each would be assumed to
  prove the other. That is a compile error at every law in the circle.

```hive
law replayKeepsTheRoom(booking: Booking, log: Event[dyn]) {
	if log is [first, ...rest] {
		applyKeepsTheRoom(booking, first)                      // another law
		replayKeepsTheRoom(apply(booking, first), rest)        // itself, on less
	}
	assert replay(booking, log).room == booking.room
}
```

A call to a law is a hint and nothing more: it is never run. Hints come first and
the claim last, so a reader can stop at the claim.

## 19.4 What a law may reach

A law may reach, through the callables it calls, only code that gives the same
answer every time and comes to an end. Everything else is a compile error that
names the path from the law to it:

| reached | |
| --- | --- |
| a `func` or `proc` body, with local `mut` and `proc`s writing local storage | allowed |
| recursion on a part a pattern took from a parameter | allowed |
| `for each`, and a counting `for` loop of the shape [10](10-bounds.md) trusts | allowed |
| any other loop | refused |
| two callables calling each other round in a circle | refused |
| a `hive.*` library call | refused: its body is not Hive |
| `async`, the await-all, `with timeout` | refused: timing is not a value |
| `spawn`, `at`, `kill`, `hide`, `encode` | refused |
| a `query`, or a function from an imported Go file | refused: its body is not Hive the prover can read |
| `echo` | allowed, and ignored |

Only what a law actually reaches is held to this. What a `func` may do does not
change ([04](04-declarations.md#42-func)).

A law with a type variable among its parameters' types is proved **on each copy**,
like every other check ([11](11-generics.md)): at every set of types the program
uses the generic callables the law calls at. A generic law nothing instantiates
that way is not copied, and so is not checked.

## 19.5 When a law is refused

A law is refused, as a compile error at the law, when:

* **a counterexample is found** — the message gives the values and the `assert`
  that fails, or says a `panic` is reached;
* **it is not proved** — the message gives the goal still open, the case it is
  in, and what was known there;
* **the prover cannot follow it** — the message says what it could not follow,
  and where.

```
bookings.hive:12: in law `grows`: it does not hold for a = 9223372036854775807: `a + 1 > a` is false
bookings.hive:30: in law `replayKeepsTheRoom`: cannot prove `(current after the loop at line 24 over the rest of log, starting from current = ...).room == booking.room`
    in the case log is [the first of log, ...the rest of log], and booking.status is Status.Requested, and the first of log is Event.Cancel
    known: ...
```

The laws checked are those of every file the entrypoint reaches, as with tests.
`hive check`, `build`, `run` and `test` all prove them before anything is written.

## 19.6 A type's laws

A law written **inside a type declaration** is about every value of that type.
It takes **exactly one parameter, of the type itself** — anything else is a
compile error — and a message names it `Type.law`.

```hive
type Booking {
	room: Str
	checkInDay: Int
	checkOutDay: Int

	law atLeastOneNight(b: Booking) {
		assert b.checkInDay >= 0 && b.checkInDay < b.checkOutDay
	}

}
```

Nothing proves it once. **Every value of the type keeps it at every moment**, and
the compiler holds the program to that.

### 19.6.1 Where it is kept

The law is proved for the new value at each of these, in every callable and test
of the program, and one it cannot prove is a compile error there:

* **a construction** — `T(...)`, `T.Variant(...)`;
* **a write to a field** — `x.f = e`, a compound assignment, and a write deeper
  down a path (`x.a.b = e`, `x.items[i] = e`), which builds anew every value of a
  type with laws that the path goes through;
* **a write in place** — `append`, `prepend`, `drop` and `sort` on a field, and
  `hive.map.set` or `hive.map.delete` on one;
* **a field handed to a `mut` parameter**, which may come back holding any value
  of its type.

A `mut` bound to storage under another `mut` name shares it
([8.4](08-mutability-and-values.md#84-copy-on-binding)), so a write through either is a write
through both, and what was known about the other is known no longer. **A write
through a `mut` sharing part of a value with laws is refused** — `mut lines :=
o.lines` followed by `append(lines, x)` — since that value's law cannot see it;
the write goes through `o.lines` itself.

**Each write keeps the law on its own.** Two fields that have to move together
move as one value built anew: `b = Booking(b.room, 10, 12)`, never
`b.checkInDay = 10` followed by `b.checkOutDay = 12`.

What the check knows at a place is what **that callable** says before it:

* the guards around it and the early returns above it;
* its own bindings, and the `assert`s it has passed;
* the laws of every value in scope.

A call's answer is known only through the laws of its type, and a loop leaves
nothing known about what it writes but those laws. A `proc` given a value of the
type through a `mut` parameter is held to the law itself, so the value comes back
keeping it.

The type's own law is the one body where a value of it need not keep it: the
value there is the one being asked about.

```
bookings.hive:24: in `moveEarlier`: cannot prove `Booking.atLeastOneNight` for this `Booking(...)`: nothing here shows `0 <= b.checkInDay - days`
    known: 0 <= b.checkInDay; b.checkInDay < b.checkOutDay
    guard it, so that the law holds here
bookings.hive:62: in `"a booking"`: this `Booking(...)` does not keep `Booking.atLeastOneNight`: `b.checkInDay < b.checkOutDay` is false
```

### 19.6.2 Where it is known

Wherever a value of the type is read, its laws hold:

* **a function law** may rely on the laws of its parameters' types, and of every
  value it takes apart;
* **the bounds pass** learns from each `assert` at the top of a type's law what the
  same condition would prove as a guard ([10.1](10-bounds.md#101-what-counts-as-a-proof)),
  for every value of the type, so `p.rooms[p.selected]` needs no guard where the
  law says `assert p.rooms bounds p.selected`.

### 19.6.3 What a decoder reads

A value a decoder reads was built by nothing the compiler saw, so **a decoder
checks each law of the type as it runs**, once it has read a value whole, and a
value breaking one is refused. Each codec's error is a union with two variants
and the fields `path`, `expected` and `found`:

| codec | error | wrong shape | breaks a law |
| --- | --- | --- | --- |
| `hive.json.codec()` | `hive.json.JsonError` | `Mismatch` | `Broken` |
| `hive.crypto.jwtCodec(secret)` | `hive.crypto.JwtError` | `Mismatch` | `Broken` |
| `hive.net.queryParamsCodec()` | `hive.net.QueryParamsError` | `Mismatch` | `Broken` |
| `hive.term.codec()` | `hive.term.FlagError` | `Mismatch` | `Broken` |

A query's rows are refused as `hive.sql.SqlError.Broken`. A value nested in
another is checked as it is read, so `path` is where it was:

```
hive: cannot decode JSON at $.booking: expected a `Booking` keeping `Booking.atLeastOneNight`, found one where `b.checkInDay < b.checkOutDay` is false
```

Run this way, an `assert` answers with the first of its `&&` parts that does not
hold, and a call to a function law, which holds for every value, does nothing.

## 19.7 A table's laws

A law written `for table <name>` is about every query on that table. It takes
**exactly one parameter**, the value a query is run for, and its body is **a SQL
filter** rather than statements: read as a query body is, with Hive only in `{…}`
values and `if` conditions.

```hive
law sameOrganization(session: Session) for table users {
	org_id = {session.orgId}
}

law ownChatsOnly(contact: Contact) for table chats {
	fk_contact_from_id = {contact.id} or
	fk_contact_to_id = {contact.id}
}
```

A body that opens with `if`, `or` or `and` is a `WHERE { }` block, whose filter
applies only where its `if`s hold; any other body is a filter that always applies.
An `or { }` block in a law's body is a compile error: it would say nothing about
any one row.

### 19.7.1 What a query has to carry

A `query` whose SQL takes rows from the table, or writes rows into it, **takes a
parameter of the law's parameter type**, and with it, for every statement:

* **what it reads, changes or deletes carries the filter**: one of the parts its
  WHERE ANDs — or the ON of an inner or left JOIN bringing the table in — is the
  filter's, with the query's parameter in the law's, or a part that says more: one
  made of only some of the alternatives the filter's `OR` allows;
* **wherever the law's `if` holds**: a filter under a `WHERE { }` block's `if`
  counts where that condition follows from the law's, which the compiler proves
  as it proves a law; one under an `or { }` block never counts;
* **a row it inserts lands inside the filter**: for each part, it writes the value
  of one of that part's `column = value` alternatives into that column. A part with
  no such alternative refuses every insert into the table, and so does an insert
  whose values cannot be read — one from a `SELECT`, of defaults, or naming no
  columns;
* **a row it updates stays inside the filter**: an `UPDATE` that sets a column the
  filter names sets it to the value of one of its alternatives, or leaves alone an
  alternative its own WHERE guaranteed. `ON CONFLICT ... DO UPDATE` is such an
  update.

A column is the table's where it is named through the table's alias in the
statement, or named bare in a statement taking rows from that table alone. A
subquery, a `WITH` statement and each side of a `UNION` carry the filter on their
own. Two parts compare as written, word by word: spacing, case and the
parentheses around a whole part aside.

```
users.hive:15: in `everyoneActive`: this query reads `users` without the filter law `sameOrganization` keeps on it
    its WHERE has to carry `org_id = {session.orgId}`
chats.hive:31: in `forge`: this query inserts a row into `chats` that law `ownChatsOnly`'s filter does not keep
    it has to write one of `fk_contact_from_id` as `{contact.id}`, or `fk_contact_to_id` as `{contact.id}`
```

A statement naming the table that the compiler cannot read — another kind of
statement, or the table inside parentheses in a FROM list — is refused.
**`hive.sql.unsafe` is not a query, and no law reads it.** Nor do views, triggers
or functions in the database: a law is about the SQL the program writes.

## 19.8 How this implementation proves a law

*Informative.* What is refused above is normative; how much an implementation
manages to prove is its own business, and every stage here is deterministic: it
counts steps, never time, so a law proved on one machine is proved on every one.

1. **Edge values.** The law runs on the values most likely to break a claim — `0`,
   `1`, `-1`, `MIN`, `MAX`; `""` and a one-letter string; the empty vector and a
   short one; every variant — at most 512 combinations of them. A failure is a
   counterexample.
2. **Every value.** Where every parameter's type is small — a `Bool`, a union whose
   variants carry such values, a `Result` of them — and the combinations come to
   at most 65,536, the law runs on all of them, and that is a proof.
3. **Unknowns.** The law runs on unknowns. Looking inside one splits the run: a
   union into a path per variant, a vector into the empty one and a first and a
   rest. A condition nothing settles splits it into the path where it holds and
   the one where it does not. Each `assert` is decided from what its path knows:
   integers by difference constraints wherever a sum provably cannot wrap, and
   equalities modulo 2^64 everywhere. A fact `a != b` between integers is the two
   cases `a < b` and `b < a`, the first four such facts on a path split at once, so
   `n >= 0` and `n != 0` together show `n > 0`.
4. **Induction.** Where that leaves a goal open, the law is run again as if it had
   called itself on the rest of each vector parameter in turn.

A callable is followed into, three levels deep into itself; past that, or on the
part of a vector an induction is about, its call stays a term of its own, which
is allowed only where nothing it reaches can panic. A `for each` over a vector of
unknown length is followed through the part that is known, and the rest of it
is a term of its own: the callable called again, where the loop is all the
callable does, or otherwise what the loop leaves in each variable it writes,
given the rest of the vector and what the loop reads.

`indexOf` on a vector is followed through the elements the path knows it to
hold, splitting the path at each one that may or may not be the one sought, so
`indexOf([], x)` is `Error` for every `x`. Past those elements, in a vector
whose rest is unknown, it is not followed. On strings it is followed only where
both are known.
