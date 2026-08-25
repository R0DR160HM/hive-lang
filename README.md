# Hive, in Hive

[![build](https://github.com/R0DR160HM/hive-lang/actions/workflows/build.yml/badge.svg)](https://github.com/R0DR160HM/hive-lang/actions/workflows/build.yml)

The Hive compiler, written in Hive.

Hive is a memory-managed, table-based language that compiles to Go. Tables are a
built-in idea rather than a library, values behave like values, and a good deal
of what other languages leave to runtime is settled at compile time instead.
This directory holds two things: the [specification](spec/) of the language, and
a compiler for it written in the language it compiles.

```
./bootstrap                           build the compiler with itself
./hive run       <entrypoint.hive>    compile and run
./hive test      <entrypoint.hive>    run the program's tests, with coverage
./hive check     <entrypoint.hive>    report any errors, build nothing
./hive emit      <entrypoint.hive>    print the generated Go
./hive build     <entrypoint.hive>    compile to a native executable
./hive container <entrypoint.hive>    write a Dockerfile that builds and runs it

./test/run                            every test the compiler has
./examples/run                        every example, compiled and run
./selfhost                            compile the compiler with itself, twice
```

`./hive` is a two-line script that finds the binary and gets out of the way;
`hive.cmd` is the same thing for Windows. Installed rather than run from here,
the compiler *is* `hivec` and takes exactly those arguments — see
[Installing it](#installing-it).

## Installing it

The compiler is **one executable**, and there is nothing to install beside it:
it carries the Go it compiles against as source text, so there is no runtime
library, no standard library directory and no configuration file. Put the binary
somewhere on your `PATH` and you are done.

What has to be on the machine as well:

| | |
| --- | --- |
| **Go 1.24 or newer**, on the `PATH` | for `build`, `run` and `test`, which write a Go module and compile it. `check` and `emit` need nothing at all |
| `git` | only for an import that names a repository |
| a network | only the *first* build of a program that opens a database (the SQL drivers) or draws a scene (a pinned three.js). Both are cached under `~/.hive`, and every build after that is offline |

### Linux and macOS

A file that arrived through a browser, or out of an archive that did not keep
the bit, is not executable — which is the one step that is easy to forget:

```sh
chmod +x hivec
mkdir -p ~/.local/bin
mv hivec ~/.local/bin/
```

`~/.local/bin` is already on the `PATH` on most distributions. Where it is not,
add it to whichever file your shell reads at startup — `~/.bashrc`, `~/.zshrc`,
`~/.config/fish/config.fish`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

For everybody on the machine rather than just you, `/usr/local/bin` is the usual
place and needs `sudo mv`.

**On macOS**, a binary that arrived through a browser is quarantined, and
Gatekeeper will refuse it with *"cannot be opened because the developer cannot be
verified"*. Clear the flag:

```sh
xattr -d com.apple.quarantine ~/.local/bin/hivec
```

Also mind the architecture: an Apple-silicon Mac wants an `arm64` build and an
Intel one an `amd64` build. `file hivec` says which you have, and
[cross-compiling](#building-it-for-another-platform) says how to make the other.

### Windows

There is no `chmod` to do — the `.exe` extension is what makes a file runnable —
but the folder has to be on the `PATH`, and a downloaded file has to be
unblocked. In PowerShell:

```powershell
$dir = "$env:LOCALAPPDATA\Hive"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Move-Item .\hivec.exe $dir
Unblock-File "$dir\hivec.exe"          # clears the "downloaded from the internet" mark

# Add it to your own PATH, without touching the machine's:
$user = [Environment]::GetEnvironmentVariable("Path", "User")
[Environment]::SetEnvironmentVariable("Path", "$user;$dir", "User")
```

The last line writes the *user* `PATH`, which is why it reads the user `PATH`
first rather than `$env:Path` — that one is the user's and the machine's joined
together, and writing it back would copy every system entry into your account.
**Open a new terminal afterwards**: a running one keeps the environment it
started with.

SmartScreen may still ask about an unsigned executable the first time; *More
info → Run anyway* is the answer, and `Unblock-File` above usually forestalls it.

Inside this repository, `hive.cmd` is the wrapper that finds `src\hivec.exe` —
a batch file rather than a PowerShell script, so it runs from `cmd.exe` and from
PowerShell alike with no execution policy involved:

```
hive run examples\02-types\types.hive
```

The cache lives in `%USERPROFILE%\.hive`, which is the same `~/.hive` the rest
of this README talks about.

### Checking that it worked

```sh
$ printf 'proc main(): void {\n\techo "it works"\n}\n' > hello.hive
$ hivec check hello.hive
No problems found in hello.hive (0s)
$ hivec run hello.hive
it works
```

`check` asks nothing of the machine but the compiler itself, which is what makes
it the useful thing to try first. If `run` then says

```
hello.hive:0: this needs the Go toolchain, and `go` is not on the PATH.
```

then the compiler is installed and Go is not: `go version` should print 1.24 or
newer, and [go.dev/dl](https://go.dev/dl/) has it for every platform this one
runs on.

### The environment it reads, and what it writes

Nothing has to be set for the compiler to work. These four change what it does:

| | |
| --- | --- |
| `PATH` | where `go` and `git` are found |
| `HOME`, or `USERPROFILE` on Windows | decides where the cache goes: `~/.hive` |
| `HIVE_PROGRESS` | `1` reports progress even when the output is being captured; `0` never reports it. Unset means "when standard error is a terminal" |
| `GOTOOLCHAIN`, `GOFLAGS`, `GOPROXY`, … | Go's own, since a build runs Go |

And `~/.hive` is everything it keeps between builds, all of it re-fetchable:

```
~/.hive/pkg/<repo>@<commit>/   a remote import's clone, shared by every program
~/.hive/vendor/three@0.180.0/  the three.js a scene is drawn with
~/.hive/tool/godecl/           the reader that gets Go to describe a Go file
~/.hive/syslink.key            a *program's* cluster key, written on first use
```

The first three cost one fetch to lose and nothing else, so deleting them is
always safe. The fourth is not the compiler's at all: it is the key two
`hive.syslink` nodes authenticate each other with, so replacing it means the
cluster no longer agrees — copy that file between machines, or set
`HIVE_SYSLINK_KEY` to the same value on each.

### Getting the first compiler

Hive builds Hive, so `./bootstrap` needs a compiler to start from — the one at
`src/hivec`, or another one named outright:

```sh
HIVEC=/path/to/some/hivec ./bootstrap
```

A checkout with no binary in it and nothing to point at cannot build itself,
which is the ordinary condition of a self-hosted compiler. Any `hivec` that
accepts this source will do: a colleague's, a release's, or one you
cross-compiled from another machine.

No binary is committed here. The compiler a build starts from comes from
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
push, followed by `./selfhost`, the tests and the examples — the whole of what
"it still builds" means here. Pushing a tag publishes what came out, for every
platform Go targets, and [`seed/README.md`](seed/README.md) says how a release
becomes the one the next build starts from.

It is pinned by digest rather than taken from the latest release for the same
reason [`src/vendor.hive`](src/vendor.hive) pins three.js: a release asset can be
replaced under its own tag, and a bootstrap that can be moved under you is not
one. A digest that does not match is never run.

### Building it for another platform

The compiler *is* a Go program, and after any build the module it was compiled
from is still sitting there — so Go's own cross-compilation makes a binary for
anywhere it targets, in about twenty seconds:

```sh
./bootstrap                                   # writes src/hivec.hive-build
cd src/hivec.hive-build
GOOS=windows GOARCH=amd64 go build -o hivec.exe .
GOOS=darwin  GOARCH=arm64 go build -o hivec-macos-arm64 .
GOOS=linux   GOARCH=arm64 go build -o hivec-linux-arm64 .
```

Each one is a complete compiler: the runtime it carries is source text inside it,
so nothing else has to travel. The same trick builds *your* program for another
platform — every `hive build` leaves its Go module in `<entrypoint>.hive-build`.

### In a container

`hive container <entrypoint.hive>` writes a Dockerfile for a program, into the
folder the command was run in — which is also the build's context:

```sh
hive container main.hive
docker build -t main .
docker run --rm -p 8080:8080 main
```

Nothing has to be installed to build that image but Docker itself. The first
stage downloads Go and the compiler's latest release for the platform being
built for — `amd64` on an ordinary machine, `arm64` on an Apple-silicon one, so
the build is native either way — and compiles the program with the two of them.
The second stage is the executable and nothing else, on `distroless/static`: no
Go, no compiler, not even a shell.

The parts of the file that are not a template are read off the program rather
than guessed at. A `hive.net.httpServe(8080, ...)` becomes an `EXPOSE 8080` that
says in a comment where the number came from; an import that names a repository
puts `git` in the build stage, since the compiler clones it while the image
builds; a program that opens a database says why `go mod tidy` runs before
anything compiles. Everything beside the Dockerfile goes into the build, so a
`.dockerignore` is what narrows that.

What comes out is an ordinary Dockerfile and editing it is expected. A
`Dockerfile` already in the folder is never written over — ours is called
`Dockerfile-hive-container` instead, and the command says which of the two it
wrote.

## It compiles itself

`./selfhost` builds stage 2 with stage 1 and stage 3 with stage 2, then compares
what the two wrote:

```
stage 2: the compiler, compiled by stage 1...
stage 3: the compiler, compiled by stage 2...

  FIXPOINT — stage 2 and stage 3 emit byte-identical Go.
```

That is the test that says a self-hosted compiler works. Once stage 2 and stage
3 agree, nothing about whatever compiled the compiler the first time is left in
it — the language it accepts and the code it writes are the same on both sides.

## It says what it is doing

A compile is not instant — the compiler's own twenty-three thousand lines take
minutes — so every pass says what it is about to do, with the time so far in
front of it:

```
$ ./hive build src/hivec.hive
 0:00  reading src/hivec.hive
 0:08  expanding generics in 25 files
 0:44    100 of 872 declarations
 ...
 5:02    800 of 872 declarations
 5:18  checking 872 declarations
 5:58  proving every index in range
 6:17  emitting Go
 6:44  go build
Compiled src/hivec.hive -> src/hivec (7m15s)
```

Every line names something about to be waited on rather than something just
finished, so the last one printed is always the answer to "what is it doing?".
It goes to **standard error** and only when standard error is a **terminal**, so
`hive emit x.hive > main.go` is still Go and a script comparing what a program
printed is unaffected; `HIVE_PROGRESS=1` says it anyway, and `HIVE_PROGRESS=0`
never does. The one pass that reports while it works rather than only when it
starts is the expansion of generics, because it is where most of a compile goes —
five of those seven minutes, and the number worth attacking if anybody wants this
faster.

## What is here

```
spec/                the language specification, in 19 chapters
examples/            twenty-two programs, and between them every feature there is
src/                 the compiler
  text.hive          the string handling the standard library does not have
  paths.hive         enough path handling for an `import` to name a file
  naming.hive        what a name is allowed to look like
  diag.hive          one error, and where it happened
  token.hive         what the lexer produces and the parser consumes
  lexer.hive         source text -> tokens
  ast.hive           the syntax tree
  parser.hive        tokens -> one module's tree
  show.hive          a tree rendered as one line of parentheses
  loader.hive        the import graph, and the one module every later pass reads
  fetch.hive         the import that names a repository rather than a file
  mono.hive          one copy of a generic per set of type arguments
  ranges.hive        the bounds pass: every index proved in range
  types.hive         what a written type means, and what a value's type is
  stdlib.hive        what `hive.<module>.<name>` means
  infer.hive         what an expression's type is
  check.hive         everything a program has to be that the grammar cannot say
  emit.hive          one flattened module -> one Go file
  runtime.hive       the Go the generated program is compiled against
  goffi.hive         reading an imported Go file's signatures, through Go itself
  vendor.hive        the one thing a build downloads: the three.js a scene needs
  progress.hive      what the compiler says while it is working
  project.hive       writing the Go module, and running the Go toolchain over it
  container.hive     the Dockerfile `hive container` writes
  testreport.hive    what `hive test` prints
  hivec.hive         the command line
test/                the tests
  *.test.hive        one suite per module, written in Hive
  e2e/               whole programs, compiled, run, and compared
hive, hive.cmd       the command line, for Unix and for Windows
bootstrap            build the compiler with itself
selfhost             build it twice and check the two agree
seed/                which release a build bootstraps from, and its digest
.github/workflows/   the bootstrap chain, run on every push
```

[examples/](examples) is the other half of the documentation: twenty-two
programs, from a two-line `echo` to a multiplayer shooter and a ten-car grand
prix — each of those a server and a client, on a world rolled from a number —
every one compiled by `./examples/run` and — where a program finishes on its own
— run and compared with what it says it prints.

The compiler is about 23,000 lines of Hive — 8,700 of which are the Go runtime
and the JavaScript a scene is drawn by, carried as source text — its tests are
3,000 more, and the examples another 11,000.

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
   ↓                   codecs, row mappers and wrappers a declaration derives
a Go module
   ↓  the Go toolchain
a native executable
```

Every pass reports as much as it can find rather than stopping at the first
thing: a program with six mistakes is a program whose author would rather hear
about six.

## It drives the toolchain itself

`hive build` writes a Go module and then runs `go build` over it; `hive test`
runs `go test` and turns what it said into a report; a remote import runs `git`
to clone the repository it names; an imported Go file's signatures are read by a
Go program this compiler writes into its own cache and runs; a build that links
the SQL drivers runs `go mod tidy` first; and a program that draws a scene has
its three.js fetched over HTTPS and checked against a pinned SHA-256 — with
`hive.net` and `hive.crypto`, which is to say with its own standard library.

All of that is Hive, through
[`hive.term.exec`](spec/14-stdlib.md#145-hiveterm) — a call that runs a command
and hands back everything it wrote, and `hive.term.attach`, which gives a command
this program's own terminal instead.

[18 — Conformance](spec/18-conformance.md) is where an implementation answers for
itself: what it implements (all of it), where it does what the specification
describes by a different route, and four defects that writing it turned up in the
compiler it replaces.

## Tests

```
$ ./test/run
Running the suites with the compiler itself.

text         16 tests: 16 passed
naming       20 tests: 20 passed
paths        8 tests: 8 passed
lexer        34 tests: 34 passed
parser       55 tests: 55 passed
loader       23 tests: 23 passed
fetch        15 tests: 15 passed
goffi        10 tests: 10 passed
mono         18 tests: 18 passed
check        45 tests: 45 passed
ranges       29 tests: 29 passed
emit         53 tests: 53 passed
container    17 tests: 17 passed

End to end:
  PASS  collections
  PASS  concurrency
  PASS  functions
  PASS  generics
  PASS  modules
  PASS  patterns
  PASS  valueSemantics
  PASS  values

  8 programs: 8 passed

Everything passed.
```

The unit suites are Hive files declaring `test` blocks: they call the compiler's
own passes and assert about what came back. They are run **by the compiler
itself**, which is its own kind of test — a compiler that could not compile its
own test suite would not be much of one.

The end-to-end suite compiles whole programs and runs them, comparing what they
printed with the `.expected` file beside each. It is a shell script because
comparing two files is what a shell is for, not because Hive could not.

`./examples/run` does the same for the twenty-two programs in
[examples/](examples), which are the language's own tour rather than a test of
the compiler — but they are compiled, run and compared all the same, because an
example that has stopped being true is worse than no example. Six of them carry
test suites of their own, and those are 221 tests more.

## Reading it

The compiler is meant to be read. Every module opens with what it is for and
what it decided not to do; the interesting choices are argued for where they were
made rather than in a design document nobody opens.

Six places are worth reading first, because each is a decision the language
forced:

* **`lexer.hive`** — a `Str` has no subscript in Hive, so the lexer works over
  `split(source, "")`. The cursor is a `mut` parameter, which is the one way
  storage crosses a call boundary; everything that only reads takes the
  characters and an index instead, so no reader ever costs a copy.
* **`parser.hive`** — errors do not stop it. A failure sets a flag, every loop
  checks it, and the declaration loop clears it and skips to the next `proc`.
* **`emit.hive`** — every lowering decision is a type. `+` is three operators,
  `==` is two, and `/` is one of two; the walk carries the scope beside the
  output, and the *wanted* type down, which is the only thing that can settle a
  `Result.Ok` or an empty vector.
* **`project.hive`** — where the compiler stops being a compiler and starts
  being a build: a Go module written to disk, `go build` run over it, and the
  difference between a command whose output only matters when it fails and one
  that is talking to whoever started you.
* **`ranges.hive`** — the bounds pass, and the language's headline guarantee: it
  proves the compiler's own eleven thousand lines in range without a single
  refusal. The module is called `ranges` because `bounds` is a keyword.
* **`types.hive`** — `same` is written out rather than left to `==`, and the
  comment says why: `==` on a union whose variant holds a vector crashes. That is
  a bug in the compiler that bootstraps this one, and finding it is what made
  this compiler write its own.
* **`goffi.hive`** — what happens when a program imports a Go file. The
  signatures are read by Go's own parser, in a program this compiler writes into
  its cache and runs; everything after that is the mapping between the two type
  systems, and every refusal in it names the parameter it could not take.
* **`runtime.hive`** — eight thousand lines of Go carried as source text, which
  is where the standard library actually lives: HTTP and WebSockets on a hijacked
  connection, a service's mailbox and the TLS wire under it, a window and the
  three.js a scene is drawn by. A module a program never named is never written
  into the build, and that decision is one table.
