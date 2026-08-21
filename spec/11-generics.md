# 11 — Generics

A name in a signature that is neither a builtin nor a declared type is a **type
variable**, and it makes the callable generic in it. That is the notation the
builtin table has always used for `len`, `indexOf` and `append`; it is available
to ordinary code on the same terms.

```hive
func first(v: T[]): Result<T, Bool> {
	if len(v) > 0 {
		return Result.Ok(v[0])
	}
	return Result.Error(false)
}
```

## 11.1 Where a variable is pinned down

A variable is pinned down by wherever it appears in the **parameters** —
including *inside* a parameter's own type, which is what makes a higher-order
generic work:

```hive
func filterMap(values: T[], transform: func(T): Result<K, E>): K[dyn] {
	mut K[dyn] out = []
	for each value in values {
		if transform(value) is Result.Ok(next) {
			append(out, next)
		}
	}
	return out
}
```

The call says what `T` is by the vector it passes, and what `K` and `E` are by
the function it passes. None of the three is written at the call site.

The body may write those variables down too — `mut K[dyn] out = []`,
`for each v: T in values`, `Box<T> b = …` — and each copy substitutes through its
own body.

## 11.2 Generic types

A type declaration whose fields mention variables is generic in them, in
**first-appearance order**, and is written out where it is used:

```hive
type Box {
	items: T[dyn]
	label: Str
}

type Either {
	Left  { left: A }
	Right { right: B }
}

Box<Str> people = Box(["ada", "grace"], "people")
Either<Str, Int> answer = Either.Right(42)
```

Each instantiation gets its own clone, its own JSON codec and its own structural
digest, so `Either<Str, Int>` and `Either<Int, Str>` are different types all the
way down to the wire.

The type arguments are written on the **declaration** of the value, which is also
what tells a variant constructor which instantiation it is building.

## 11.3 Monomorphization

Nothing about generics is dynamic. Every call site is resolved at compile time,
with the type arguments read off the argument types, and **one concrete copy is
emitted per distinct set of them** — `first_Str`, `first_Int`. No boxing, no
dispatch, no reflection.

Because each copy is an ordinary declaration, **every later check runs on it
separately**. Two of them get sharper for it: an instantiation at `Str[3]` is
held to that length while one at `Str[dyn]` guards its indexes, which is the
right answer for both.

Monomorphization therefore runs **before** the checks that follow it, and every
pass after it sees ordinary, non-generic code.

## 11.4 What is rejected

**A generic callable cannot be used as a value.** Which copy a call reaches is
decided by the argument types, and a value carries none:

```hive
f := first            // compile error
```

**A variable that appears only in the return type** has nothing to be inferred
from, so there is no way to say which copy is wanted:

```hive
func makeOne(n: Int): T { ... }   // compile error at the call
```

**Runaway expansion is capped.** A generic that instantiates itself at an
ever-larger type would never settle, so the expansion has a limit and overrunning
it is a compile error rather than a hung build.
