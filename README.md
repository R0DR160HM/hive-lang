<p align="center">
  <img src="assets/hive-logo.svg" alt="The Hive logo: a bee over a honeycomb" width="160">
</p>

<h1 align="center">Hive, in Hive</h1>

<p align="center">
  <a href="https://github.com/R0DR160HM/hive-lang/actions/workflows/build.yml"><img src="https://github.com/R0DR160HM/hive-lang/actions/workflows/build.yml/badge.svg" alt="build"></a>
</p>

The Hive compiler, written in Hive.

Hive is a compiled, memory-managed language with **no runtime exceptions**:
there is no null, nothing is thrown, and every vector index is proved in bounds
before the program runs. What other languages leave to run time — an index, the
branch of a match, the columns a SQL query comes back with — is settled at
compile time instead.

It is built for distributed systems from the start, secure by default — TLS
between nodes, SQL values always bound as parameters, AES-256-GCM and HS256
tokens in the standard library — and small enough to learn in a day:
[a tour of the whole language](https://hive-tour.fly.dev) is fifty-four pages.

This directory holds the [specification](spec/) and a compiler for it written in
the language it compiles.

```
./bootstrap                           build the compiler with itself
./hive run       <entrypoint.hive>    compile and run
./hive test      <entrypoint.hive>    run the program's tests, with coverage
./hive check     <entrypoint.hive>    report any errors, build nothing
./hive analyze   <entrypoint.hive>    score what it will cost, and write a page
./hive emit      <entrypoint.hive>    print the generated Go
./hive build     <entrypoint.hive>    compile to a native executable
./hive build     <entrypoint.hive> --target <goos>/<goarch>
./hive container <entrypoint.hive>    write a Dockerfile that builds and runs it
./hive agents                         write .hivedocs/ for a coding agent to read
./hive version                        which release this compiler is

./test/run                            every test the compiler has
./examples/run                        every example, compiled and run
./selfhost                            compile the compiler with itself, twice
```

`./hive` finds the binary and gets out of the way; `hive.cmd` is the same for
Windows. Installed rather than run from here, the compiler *is* `hivec` and takes
exactly those arguments.

## Installing it

The compiler is **one executable**. It carries the Go it compiles against as
source text, so there is no runtime library, no standard library directory and no
configuration file: put the binary on your `PATH` and you are done.

| also needed | for |
| --- | --- |
| **Go 1.24+**, on the `PATH` | `build`, `run` and `test`, which write a Go module and compile it. `check` and `emit` need nothing |
| `git` | only an import that names a repository |
| a network | only the *first* build of a program that opens a database or draws a scene. Both cache under `~/.hive`; every build after is offline |

### Linux and macOS

A file out of a browser or an archive may not have kept its executable bit:

```sh
chmod +x hivec
mkdir -p ~/.local/bin && mv hivec ~/.local/bin/
```

`~/.local/bin` is on the `PATH` on most distributions; where it is not, add
`export PATH="$HOME/.local/bin:$PATH"` to your shell's startup file.
`/usr/local/bin` is the usual place for everybody on the machine.

**On macOS** a downloaded binary is quarantined, and Gatekeeper refuses it with
*"the developer cannot be verified"* — clear it with
`xattr -d com.apple.quarantine ~/.local/bin/hivec`. Mind the architecture too:
Apple silicon wants `arm64`, Intel `amd64`, and `file hivec` says which you have.

### Windows

No `chmod` — the `.exe` is what makes it runnable — but the folder has to be on
the `PATH` and a downloaded file has to be unblocked. In PowerShell:

```powershell
$dir = "$env:LOCALAPPDATA\Hive"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Move-Item .\hivec.exe $dir
Unblock-File "$dir\hivec.exe"

# The *user* PATH, read first so no system entry is copied into your account:
$user = [Environment]::GetEnvironmentVariable("Path", "User")
[Environment]::SetEnvironmentVariable("Path", "$user;$dir", "User")
```

**Open a new terminal afterwards** — a running one keeps the environment it
started with. SmartScreen may still ask the first time; *More info → Run anyway*.

Inside this repository `hive.cmd` finds `src\hivec.exe`; it is a batch file, so
it runs from `cmd.exe` and PowerShell alike with no execution policy involved.
The cache is `%USERPROFILE%\.hive`, the same `~/.hive` as everywhere else.

### Checking that it worked

```sh
$ hivec version
v0.2.2
$ printf 'proc main(): void {\n\techo "it works"\n}\n' > hello.hive
$ hivec check hello.hive
No problems found in hello.hive (0s)
$ hivec run hello.hive
it works
```

`version` builds nothing, so it answers as soon as the binary is on the `PATH`;
`check` asks nothing of the machine but the compiler. If `run` then says
`this needs the Go toolchain, and 'go' is not on the PATH`, the compiler is
installed and Go is not — [go.dev/dl](https://go.dev/dl/) has it.

### The environment it reads, and what it writes

Nothing has to be set. These four change what it does:

| | |
| --- | --- |
| `PATH` | where `go` and `git` are found |
| `HOME`, or `USERPROFILE` on Windows | where the cache goes: `~/.hive` |
| `HIVE_PROGRESS` | `1` reports progress even when captured, `0` never. Unset means "when standard error is a terminal" |
| `GOTOOLCHAIN`, `GOFLAGS`, `GOPROXY`, … | Go's own, since a build runs Go |

```
~/.hive/pkg/<repo>@<commit>/   a remote import's clone, shared by every program
~/.hive/vendor/three@0.180.0/  the three.js a scene is drawn with
~/.hive/tool/godecl/           the reader that gets Go to describe a Go file
~/.hive/syslink.key            a *program's* cluster key, written on first use
```

The first three cost one fetch to lose, so deleting them is always safe. The
fourth is not the compiler's: it is the key two `hive.syslink` nodes
authenticate with, so copy it between machines, or set `HIVE_SYSLINK_KEY` to the
same value on each.

### Getting the first compiler

Hive builds Hive, so `./bootstrap` needs a compiler to start from — `src/hivec`,
or another named outright with `HIVEC=/path/to/hivec ./bootstrap`. Any `hivec`
that accepts this source will do.

No binary is committed here. The one a build starts from comes from
[a release](../../releases), and [`seed/pinned.txt`](seed/pinned.txt) says which
release, which asset, and what it hashes to:

```sh
tag=$(awk '$1=="tag:"{print $2}' seed/pinned.txt)
gh release download "$tag" --pattern hivec-linux-amd64 --dir /tmp
sha256sum -c <(printf '%s  /tmp/hivec-linux-amd64\n' \
  "$(awk '$1=="sha256:"{print $2}' seed/pinned.txt)")

chmod +x /tmp/hivec-linux-amd64
HIVEC=/tmp/hivec-linux-amd64 ./bootstrap    # the release builds src/hivec
./bootstrap                                 # and then it builds itself
```

That is what [the build workflow](.github/workflows/build.yml) does on every
push, followed by `./selfhost`, the tests and the examples. Pushing a tag
publishes what came out, for every platform Go targets;
[`seed/README.md`](seed/README.md) says how a release becomes the next build's
starting point. It is pinned **by digest** because a release asset can be
replaced under its own tag, and a digest that does not match is never run.

### Building it for another platform

**Your own program** takes a `goos/goarch` pair, checked against
`go tool dist list` before a line of Hive is read:

```sh
./hive build main.hive --target linux/arm64      # writes main-linux-arm64
./hive build main.hive --target=windows/amd64    # writes main-windows-amd64.exe
```

A cross build says which platform it is for in its name, so it never displaces
the local one, and takes its `.exe` from the target. `CGO_ENABLED=0` goes with a
cross build and only with one: nothing in the runtime needs a C compiler, and a C
*cross*-compiler is the one thing a machine with Go may not have.

**The compiler itself** is a Go program, and the module it was compiled from is
still there afterwards — so Go's own cross-compilation makes a binary for
anywhere it targets, in about twenty seconds:

```sh
./bootstrap                                   # writes src/hivec.hive-build
cd src/hivec.hive-build
GOOS=windows GOARCH=amd64 go build -o hivec.exe .
GOOS=darwin  GOARCH=arm64 go build -o hivec-macos-arm64 .
```

Each is a complete compiler: the runtime it carries is source text inside it.

### What it will cost

`hive analyze main.hive` reads the program the emitter is about to write, scores
every `proc` and `func` out of a hundred, prints the worst and writes the whole
thing as an HTML page beside the entrypoint — a [`hive.ui`](spec/14-stdlib.md#1415-hiveui)
view, so it carries its own stylesheet. Nothing is built and nothing is run.

It looks for loops inside loops, a name rebuilt out of itself one turn at a time,
a linear search inside a loop, something that waits on a disk or a database once
per turn, and — the one a language of values has that others do not — **implicit
deep copies**. Those are not guessed at: `writes` already works out which fields
a `clone_T` has to copy ([8.4](spec/08-mutability-and-values.md#84-copy-on-binding)),
and the analysis reads its answer, so a copy it names is one that will be
emitted. Everything else is a **weight rather than a measurement** — no compiler
knows how many times a loop goes round.

### In a container

`hive container main.hive` writes a Dockerfile into the folder the command ran
in, which is also the build's context:

```sh
hive container main.hive
docker build -t main .
docker run --rm -p 8080:8080 main
```

Nothing but Docker has to be installed. The first stage downloads Go and the
compiler for the platform being built for, so the build is native either way; the
second is the executable and nothing else on `distroless/static` — no Go, no
compiler, not even a shell.

The compiler it downloads is **the one that wrote the file**, named in an
`ARG HIVEC_VERSION`, rather than whatever is newest on the day — an image
following the newest release could stop building a program that never changed.

The parts that are not a template are read off the program: a
`hive.net.httpServe(8080, ...)` becomes an `EXPOSE 8080` saying in a comment
where the number came from, an import naming a repository puts `git` in the build
stage, a program opening a database says why `go mod tidy` runs first. A
`Dockerfile` already in the folder is never written over — ours is called
`Dockerfile-hive-container`, and the command says which it wrote.

## It compiles itself

`./selfhost` builds stage 2 with stage 1 and stage 3 with stage 2, then compares
what the two wrote:

```
stage 2: the compiler, compiled by stage 1...
stage 3: the compiler, compiled by stage 2...

  FIXPOINT — stage 2 and stage 3 emit byte-identical Go.
```

That is the test that says a self-hosted compiler works: once the two agree,
nothing of whatever compiled it the first time is left in it.

## It says what it is doing

Every pass says what it is about to do, with the time so far in front of it:

```
$ ./hive build src/hivec.hive
 0:00  reading src/hivec.hive
 0:00  expanding generics in 28 files
 0:00    100 of 1028 declarations
 0:00  checking 1028 declarations
 0:02  proving every index in range
 0:03  emitting Go
 0:07  go build
Compiled src/hivec.hive -> hivec (9s)
```

Every line names something about to be waited on rather than something just
finished, so the last one printed always answers "what is it doing?". It goes to
**standard error** and only when that is a **terminal**, so
`hive emit x.hive > main.go` is still Go; `HIVE_PROGRESS` overrides either way.

## What is here

```
spec/                the language specification, in 18 chapters
examples/            twenty-two of them, thirty-three programs, every feature there is
src/                 the compiler, in the order the pipeline runs
  lexer token ast parser         source text -> tokens -> one module's tree
  regex show                     a string pattern's regex, read at compile time; a tree as one line
  loader fetch goffi             the import graph: files, repositories, and Go files
  mono                           one copy of a generic per set of type arguments
  types infer stdlib             what a written type means, what an expression is, what `hive.*` is
  check ranges writes            everything the grammar cannot say; every index proved; what a copy copies
  emit runtime                   one module -> one Go file, and the Go it compiles against
  project vendor progress        the Go module and toolchain, the one download, what it says meanwhile
  analyze analyzereport          what `hive analyze` scores, and the page it writes
  container agents icon docs/    a Dockerfile, .hivedocs/, a window's icon, the pages themselves
  text paths naming diag         strings, paths, what a name may look like, one error
  version testreport hivec       the release, what `hive test` prints, the command line
test/
  *.test.hive        one suite per module, written in Hive
  e2e/               whole programs, compiled, run, and compared
hive, hive.cmd       the command line, for Unix and for Windows
bootstrap selfhost   build with itself; build twice and check the two agree
seed/                which release a build bootstraps from, and its digest
CHANGELOG.md         what changed, release by release
.github/workflows/   the bootstrap chain, run on every push
```

[examples/](examples) is the other half of the documentation: twenty-two of them
and thirty-three programs between them, from a two-line `echo` to a multiplayer
shooter and a ten-car grand prix — every one compiled by `./examples/run`, and
run and compared where the program finishes on its own.

The compiler is about 38,000 lines of Hive — 12,000 of which are the Go runtime
and the JavaScript a scene is drawn by, carried as source text — its tests are
6,400 more, and the examples another 23,000.

## The pipeline

```
source text
   ↓  lexer            strings, interpolation, atoms, SQL bodies, import paths
tokens
   ↓  parser           recursive descent, recovering at each declaration
one module's tree
   ↓  loader           the import graph, cycles rejected, everything flattened
   ↓    fetch          an import that names a repository, cloned once
   ↓    goffi          an import that names a Go file, read by Go itself
one program's tree
   ↓  mono             one copy of each generic, per set of type arguments
   ↓  check            names, types, purity, mutability, terminating paths
   ↓  ranges           every index and slice proved in range
   ↓  emit             Go, with the copies value semantics need — and the
   ↓    writes         which of those copies anybody could tell apart
   ↓                   codecs, row mappers and wrappers a declaration derives
a Go module
   ↓  the Go toolchain
a native executable
```

Every pass reports as much as it can find rather than stopping at the first
thing: a program with six mistakes is a program whose author would rather hear
about six.

## It drives the toolchain itself

`hive build` runs `go build` over the module it wrote; `hive test` runs `go test`
and turns what it said into a report; a remote import runs `git`; an imported Go
file's signatures are read by a Go program this compiler writes into its cache
and runs; a build linking the SQL drivers runs `go mod tidy` first; and a scene's
three.js is fetched over HTTPS and checked against a pinned SHA-256 — with
`hive.net` and `hive.crypto`, which is to say with its own standard library.

All of it is Hive, through
[`hive.term.exec`](spec/14-stdlib.md#145-hiveterm), `attach` and `execWith` —
the last being the whole of how `--target` builds for another platform.

[18 — Conformance](spec/18-conformance.md) is where an implementation answers for
itself: what it implements, where it takes a different route to what the
specification describes, and the divergences that holding it against 18.1 turned
up.

## Tests

```
$ ./test/run
Running the suites with the compiler itself.

text         16 tests: 16 passed
...
hivec        15 tests: 15 passed

End to end:
  PASS  collections
  ...
  PASS  values

  13 programs: 13 passed

Everything passed.
```

602 unit tests over nineteen suites, and thirteen whole programs. The unit suites
are Hive files declaring `test` blocks that call the compiler's own passes, run
**by the compiler itself** — one that could not compile its own test suite would
not be much of one. The end-to-end suite compiles whole programs, runs them, and
compares what they printed with the `.expected` beside each; it is a shell script
because comparing two files is what a shell is for.

`./examples/run` does the same for the thirty-three programs in
[examples/](examples), which are the language's tour rather than a test of the
compiler — but compiled, run and compared all the same, because an example that
has stopped being true is worse than none. Six carry test suites of their own,
and those are 273 tests more.

## Reading it

The compiler is meant to be read. Every module opens with what it is for and what
it decided not to do, and the interesting choices are argued for where they were
made. Eight are worth reading first, because each is a decision the language
forced:

* **`lexer.hive`** — works over `split(source, "")` rather than indexing, because
  every index is proved in range one at a time and a scanner asks a million times.
* **`parser.hive`** — errors do not stop it: a failure sets a flag, every loop
  checks it, and the declaration loop clears it and skips to the next `proc`.
* **`emit.hive`** — every lowering decision is a type. `+` is three operators and
  `==` is two; the walk carries the *wanted* type down, which is the only thing
  that can settle a `Result.Ok` or an empty vector.
* **`project.hive`** — where the compiler stops being a compiler and starts being
  a build: a Go module on disk, and `go build` run over it.
* **`ranges.hive`** — the bounds pass, and the headline guarantee: it proves the
  compiler's own thirty-eight thousand lines in range without a single refusal.
  Called `ranges` because `bounds` is a keyword.
* **`types.hive`** — `same` is written out rather than left to `==`, because `==`
  on a union whose variant holds a vector crashes. That is a bug in the compiler
  that bootstraps this one, and finding it is what made this one write its own.
* **`goffi.hive`** — what happens when a program imports a Go file: the signatures
  are read by Go's own parser, in a program this compiler writes and runs.
* **`runtime.hive`** — twelve thousand lines of Go carried as source text, which is
  where the standard library actually lives. A module a program never named is
  never written into the build, and that decision is one table.
