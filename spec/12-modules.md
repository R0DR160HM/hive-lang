# 12 — Modules

A Hive program can span as many files as you like. `import`, written outside any
callable, brings another file's declarations into scope.

```hive
import ./lib/text
import ./lib/inventory as stock

proc main(): void {
	echo text.repeat("=", 28)
	echo stock.line(stock.Item("Beeswax", 450))
}
```

## 12.1 Four kinds of path

The path itself says which:

| written | what it names |
| --- | --- |
| `import ./lib/text` | a Hive file on this disk — `.hive` is never written |
| `import ./lib/util.go` | a [Go file](#124-importing-a-go-file) on this disk — `.go` always is |
| `import https://host/owner/repo/src/foo` | a file in a [git repository](#125-importing-from-a-git-repository) |
| `import hive.ui` | a [standard library module](#126-importing-a-standard-library-module), which names no file |

The two extensions are opposites on purpose. A Hive module's is never written,
because the path names a *module* and the file is only where it lives; a Go
file's always is, because nothing about `import ./lib/util` should leave you
wondering which of the two languages you are about to read.

A path may also be **quoted**, which is how one holding a space is written:
`import "./lib/my file"`. Inside the quotes everything up to the closing one is
the path, so nothing needs escaping — and `as` after it still reads as `as`.

## 12.2 Names

* The **path is relative to the importing file's own directory** and leaves the
  `.hive` extension off, so `./lib/text` is `lib/text.hive` next door and
  `../../shared/text` climbs out first. It is the file's location that matters,
  not where you happen to run the compiler from.
* A module is reached through a **name**: the file's own name by default
  (`./lib/text` → `text`), or whatever `as` gives it. Use `as` when two modules
  would otherwise collide, when a name would clash with something the importing
  file declares, or when the file name isn't usable as a name at all
  (`./lib/text-utils` needs one).
* The name is `camelCase`, like the variable it reads as at every use.
* An import may not be named `hive`: that name belongs to the standard library.
* **Everything a module declares is visible** — procs, funcs, queries and types.
  There is no `pub`/`priv` distinction.

## 12.3 The import graph

* Modules may import modules of their own, and a file is **loaded once** however
  many modules reach for it.
* **Import cycles are rejected**, whether direct (a file importing itself) or
  round any number of steps. The error prints the loop it found:

  ```
  hive: this import forms a cycle:

      lib/inventory.hive
        -> lib/pricing.hive
        -> lib/inventory.hive
  ```

### Flattening

The whole program becomes **one module**: the entrypoint keeps its own names and
every imported module's declarations are given a prefix of their own, so
`text_0_repeat` sits beside your untouched `main`. Every pass after the loader
runs on that.

Names carry **no baggage across a module boundary**: a type or function only ever
means what the module you read it in says it means. Two files may each declare
their own `Align` and both stay distinct types, referenced as `Align` in one and
`text.Align` in the other. An imported type is constructed, annotated and matched
through the same name its module is reached by (`text.Align.Left()`, a
`text.Align` parameter, `style is text.Align.Left`), and an imported callable is
an ordinary value — partially applicable and passable like any other.

A local binding still shadows a module-level name of the same shape, exactly as
it does in a single file.

Flattening has one cost, and [17](17-diagnostics.md) states it: it discards which
file each declaration came from, so the passes that run after it report against
the entrypoint.

## 12.4 Importing a Go file

Hive is Go behind the curtain, so a Go file next to a Hive one can be called from
it directly. The path ends in **`.go`**, which is compulsory:

```hive
import ./lib/measures.go

proc main(): void {
	echo measures.grams(measures.Weight(899, "Hive tool"))
}
```

* **Every value is deep-copied, in both directions.** That is the whole point of
  the boundary: a Go function can sort the slice it was handed, keep a reference
  to it, or write through it, and none of that can reach the Hive value it came
  from. It is also why an imported Go function is a **`func`** rather than a
  `proc` ([04](04-declarations.md#42-func)).
* **Only what Go exports is reachable**, which there means a capitalised name.
  Hive names callables in camelCase, so the name is reached with its first letter
  lowered — `Grams` is `measures.grams` — while a type keeps its PascalCase.
* The signatures are read by **the Go toolchain**, not guessed at.
* **The boundary is narrow**, and everything outside it is a compile error naming
  the parameter it could not take:

  | Go | Hive |
  | -- | ---- |
  | `string` | `Str` |
  | `int` | `Int` — Hive's `Int` *is* Go's `int`, so `int64` and the rest are rejected rather than silently converted |
  | `float64` | `Float` |
  | `bool` | `Bool` |
  | `[]T` | `T[dyn]` |
  | `[][]string` | `Table` |
  | `map[K]V` | `hive.map.Map<K, T>`, with a `string`/`int`/`float64`/`bool` key |
  | a struct the file exports | a Hive type of the same name and shape |
  | `(T, error)` | `Result<T, Str>` — Go's way of reporting failure is Hive's |
  | `error` alone | `Result<Bool, Str>`, whose `Ok` carries `true` |
  | no result | a function answering with nothing |

  A pointer, a channel, an interface, a function value, a variadic parameter, a
  fixed-size array, a type from another package, an unexported or embedded struct
  field: each is refused, and the message says why. A struct crosses only when
  *every* field of it does.
* A Go map has **no order of its own**, so one arriving in Hive has its keys
  **sorted**. Going the other way the order is simply dropped.
* Each imported file is compiled as **its own package** inside the generated
  project, and it is *copied* there.
* The file may import whatever it likes. A build that sees a third-party import
  runs `go mod tidy` first, so that build needs network access once.

## 12.5 Importing from a git repository

```hive
import https://github.com/owner/repo/src/text               // a Hive module
import https://github.com/owner/repo@a1b2c3/src/text        // pinned to a commit
import https://github.com/owner/repo/go/util.go as helpers  // a Go file, same rules
```

* **`https://host/owner/repo` is the repository**; everything after it is the
  path inside it, and it leaves `.hive` off exactly as a local import does. A
  **revision** goes where the repository ends: `repo@a1b2c3`, `repo@v1.2.0`,
  `repo@main` — a commit, a tag or a branch.
* The module is **named after the file inside the repository**, not after the
  repository or its host, so moving a module out to a repository does not change
  how the code that uses it reads.
* **Everything is fetched once**, into a cache shared by every program on the
  machine that wants that commit. Nothing touches the network when the clone is
  already there.
* An import that **names no revision is pinned on first use**: the commit it
  resolved to is written into a lock file beside the entrypoint (`main.hive` →
  `main.hive-lock`), and every later build reads that. Keep it in version
  control — it is what makes another machine build the same program. Delete a
  line from it to take the latest of that repository again.
* A remote module is an **ordinary module**. It is also a *different* module from
  the same file read locally — two copies of one file are two modules, with types
  of their own.
* Fetching needs `git` on the PATH. A missing one, an unreachable host, a
  revision that does not exist and a path the repository does not have are four
  different errors, and each says which it is.

## 12.6 Importing a standard library module

```hive
import hive.ui
import hive.net as web
```

It is the same feature and the same rules — the alias is a name like any other.
Three things are particular to it:

* The path is the module and nothing else: `import hive.ui`, never
  `import hive.ui.View`.
* Without `as`, the name is the module's own last segment.
* **Nothing is imported into the program.** The alias is a *spelling*: `ui.row`
  and `hive.ui.row` are the same call, both are always available, and neither
  changes what is linked into the build. `import hive` is not a thing to write —
  the library is reached a module at a time, and the global builtins were never
  behind an import at all.

## 12.7 What is linked

**A module you don't use is not in your build.** The generated project always
carries the core runtime, and each `hive.*` module is written into it — and so
compiled and linked — only when the program actually references that module. A
module a used one depends on internally comes along too.
