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

A law is never emitted and never runs: proving it is all that happens to it.

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

## 19.6 How this implementation proves a law

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
   equalities modulo 2^64 everywhere.
4. **Induction.** Where that leaves a goal open, the law is run again as if it had
   called itself on the rest of each vector parameter in turn.

A callable is followed into, three levels deep into itself; past that, or on the
part of a vector an induction is about, its call stays a term of its own, which
is allowed only where nothing it reaches can panic. A `for each` over a vector of
unknown length is followed through the part that is known, and the rest of it
is a term of its own: the callable called again, where the loop is all the
callable does, or otherwise what the loop leaves in each variable it writes,
given the rest of the vector and what the loop reads.
