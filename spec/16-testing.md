# 16 — Testing

A test is a top-level declaration, alongside `proc`, `func`, `query` and `type`:

```hive
import ./cart

test "an empty cart costs nothing" {
	cart.Item[0] empty = []
	assert cart.total(empty) == 0
}
```

Run them with **`hive test <entrypoint.hive>`**. There is nothing to install and
nothing to register: no framework, no third-party library, no `describe`/`it`, no
assertion vocabulary beyond the `assert` the language already has.

A test is named **in prose** because a test name is documentation, not something
anything calls — and for the same reason it takes no parameters and returns
nothing. Tests may live beside the code they are about or in a file of their own;
a file holding only tests needs no `main`, and a test run on a program runs
**every test in every file the entrypoint reaches**.

## `assert` means the same thing, and does something different

`assert` says what it always says: this must hold. What changes is the
consequence, and — as everywhere else in Hive — that is decided by *where it is
written*. In ordinary code a failed assertion has proved the **program** wrong,
so it stops. Inside a test it has proved the **test** wrong, so the failure is
recorded and the rest of the suite still runs.

A failed comparison shows both sides. The compiler has the source text and the
static types, so neither the condition nor the values have to be spelled out by
hand:

```
  PASS  an empty cart costs nothing
  FAIL  lines add up
        cart.test.hive:33: assert cart.total(two) == 17
          left:  16
          right: 17

  2 tests: 1 passed, 1 failed
```

A test that **panics** fails on its own rather than taking the suite with it, so
one broken test cannot hide every result after it.

### `assert` evaluates once

An `assert`'s operands are evaluated **exactly once**, whether it holds or not.
The values shown on a failure are the ones the check itself computed, not a
second evaluation of the same source.

This is not a detail. An implementation that emits the operand twice — once for
the condition and once for the report — makes any assertion over a call with an
effect quietly wrong:

```hive
test "the cursor advances" {
	mut P p = P(tokens, 0, [])
	assert parseSum(p) == 42     // must run parseSum once, not twice
	assert len(p.errors) == 0
}
```

A conforming implementation binds each side to a temporary and uses that
temporary for both the comparison and the report.

## Coverage is not a separate command

Every run reports it. A run that does not say what it *missed* has answered half
the question, so there is no flag to remember and no second command to forget:

```
  6 tests: 6 passed
  coverage: 87.5% of statements (7/8)
  never exercised: describe
```

The percentage counts statements of **your own** declarations — the clone
helpers, ordering helpers, atom table and JSON marshalling the compiler emits
alongside them are nobody's code and are not something a test can be said to have
missed. `never exercised` names the declarations no test reached at all, which is
usually the line worth acting on. With more than one file in the program, a
per-file breakdown is printed too.

A test run **exits non-zero when any test fails**, which is what makes it the
thing a commit hook or a CI step runs.

## Where a test runs

A test runs with the working directory set to the **generated project**, not to
the entrypoint's folder. That is a difference from `hive run`, which chdirs to
the entrypoint's folder so `using "./test.csv"` resolves the way its author
wrote it.

The consequence is worth stating because it is easy to trip over: a test that
opens a relative path is not looking where the source file is. A test that needs
files should **write them itself** — `hive.file.makeDir` and `hive.file.write`
into a directory of its own — which is also what makes it independent of how the
suite was invoked.

## What runs it

`go test`. Hive already generates a Go module and drives the Go toolchain, and
that toolchain ships a runner: isolation per test, filtering by name, timing,
exit codes and coverage instrumentation. None of it is reimplemented.

The tests are generated into a `main_test.go` in the **same Go package** as
`main.go`, which is what lets a test reach every proc, func and type the program
declares without any of them being exported, or named, or otherwise made testable
on purpose.

Two things a runner cannot know and a compiler can are added on top: which
`.hive` line a failure belongs to — the generated Go carries `//line` directives
([15](15-lowering.md#154-source-positions)) — and what the values on either side
of a failed comparison actually were.
