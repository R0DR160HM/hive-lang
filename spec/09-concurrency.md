# 09 — Concurrency

**Every call blocks its caller.** Nothing about a declaration says otherwise, so
there is no `async func`, no Future and no Promise type to name. What a call
means is decided **where it is written**.

## 9.1 The four call sites

### `f(x)` — wait for it

Yields `T`. It costs neither a goroutine nor a channel: it is a function call.

### `async f(x)` — as a statement

Runs the call on its own virtual thread and carries on. Fire-and-forget is the
whole of what it is: the result is discarded, and nothing is left behind to read
one from.

It works on any call — a `func`, a `proc`, a `query`, the standard library, a
[service](14-stdlib.md#1410-hivesyslink). What it refuses, it refuses by name:

* a **global builtin** (`len`, `append` and the rest exist for the value they
  hand back, so firing one off would leave nothing of it);
* a **constructor** (it builds a value and runs no body);
* a **partial application** (`f(1, _)` makes a function value; nothing runs until
  something calls it).

### `x := async f(a)` — keep the result

Starts the call the same way and keeps its result. The **wait happens wherever
`x` is read**, and only if the call has not finished by then.

```hive
rows  := async loadRows()        // Str[dyn] — starts now
total := async countAll()        // Int      — starts now, alongside
echo "loaded {len(rows)} of {total}"   // waits for both, here
```

`x`'s type is the call's return type with **nothing wrapped around it** (`Str`,
not a Future of one). There is no handle type in the language, nothing to
unwrap, and no way to forget to.

* Reading `x` again is free and always answers the same value.
* A panic inside the call is raised at the **first read**, and if nothing ever
  reads `x` the work still runs and the panic is dropped with the result.
* It refuses the same three immediate calls `async` does, and a `void` call
  besides — there would be nothing for the name to hold.
* `mut` cannot be combined with it: the name is work in flight, not storage.
* Neither can `with timeout`, which needs one moment to measure from where this
  has as many as it has reads.

This is the only place `async` may appear other than a statement of its own.

### `await [f(a), f(b), f(c)]` — the await-all

The **only** `await` there is. Every call in the list starts on its own thread
and the whole list is one barrier, resolving **in order** to a statically-sized,
fully-typed vector of their results (`Str[3]`) — never a dynamic or `Any` vector.
Three calls that each take a second take about a second.

* A list of one is legal and still means "on its own thread, then wait".
* Over `void` calls the barrier has no value either, and is a **statement**
  meaning "both of these, then carry on".
* Every entry has to be a **call** — a value already in hand has nothing to wait
  for — and they all have to answer with the **same type**, since one barrier
  resolves to one vector.
* `await []` is a compile error.

## 9.2 Work of different types

An await-all resolves to one vector and a vector holds one type, so several calls
that answer differently are given **names** instead — the `async` binding above.
`s := async slowShout("a")` then `n := async slowCount("bb")` are two threads
running at once, each waited for where its own name is read.

## 9.3 Threads and mutex arguments

A call handed a mutex argument shares the caller's storage **only when the caller
waits for it there**. An `async` or `await`ed call gets a copy, made on the
caller's side of the fence. See
[08](08-mutability-and-values.md#82-mutex-parameters).

## 9.4 `with timeout`

Any wait **written where it happens** may be bounded:

```hive
f(x) with timeout 500
await [f(a), f(b)] with timeout 500
```

It changes what the wait yields: without it, the value; with it, a
`Result<T, hive.task.TimeoutError>` — running out of patience is a value to
handle, not a crash. A `TimeoutError` carries `waited` (the milliseconds asked
for) and a `message`.

```hive
if slowShout("worth waiting for") with timeout 100 is Result.Error(err) {
	echo "gave up after {err.waited}ms"
}
```

* On an await-all it is **one deadline across the whole barrier**, and the whole
  vector fails together.
* A timeout abandons the **waiting, not the work**: a virtual thread cannot be
  stopped from the outside, so the call runs on and only its result is dropped.
* A `void` call has no value for the `Result` to carry, so bounding one is
  refused rather than lowered to a type with no spelling.
* On a [`hive.syslink`](14-stdlib.md#1410-hivesyslink) request the clause folds
  into that module's own error rather than wrapping a second `Result` around the
  first, so the result is still
  `Result<Message, hive.syslink.SyslinkError>` with reason `"Timeout"`.
* An `async` binding cannot take one ([9.1](#x--async-fa--keep-the-result)).

## 9.5 What is deliberately absent

There is no channel type, no mutex primitive, no thread handle, no cancellation
token and no scheduler to configure. A program that needs long-lived shared state
reaches for a [service](14-stdlib.md#1410-hivesyslink), whose handler is a fold
over its mailbox and therefore needs no lock at all; a program that needs a
result from work in flight names it.
