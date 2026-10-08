<p align="center">
  <img src="assets/hive-logo.svg" alt="The Hive logo: a bee over a honeycomb" width="160">
</p>

<h1 align="center">Hive, in Hive</h1>

<p align="center">
  <a href="https://github.com/R0DR160HM/hive-lang/actions/workflows/build.yml"><img src="https://github.com/R0DR160HM/hive-lang/actions/workflows/build.yml/badge.svg" alt="build"></a>
</p>

Hive is a compiled, memory-managed language with **no runtime exceptions**: there
is no null, nothing is thrown, and every vector index is proved in bounds before
the program runs. It is built for distributed systems, secure by default, and
small enough to learn in a day.

This repository holds the [specification](spec/) and the compiler, written in Hive.

## Install

Put the `hivec` binary from a [release](../../releases) on your `PATH`, and install
[Go 1.24+](https://go.dev/dl/) to build and run programs.
[INSTALL.md](INSTALL.md) has the details, and how to build it from source.

## Use

```
hivec run       <entrypoint.hive>    compile and run
hivec test      <entrypoint.hive>    run its tests, with coverage
hivec check     <entrypoint.hive>    report errors, build nothing
hivec build     <entrypoint.hive>    compile to a native executable
hivec export    <entrypoint.hive>    package it as an Android app
hivec analyze   <entrypoint.hive>    score what it will cost to run
hivec emit      <entrypoint.hive>    print the generated Go
hivec container <entrypoint.hive>    write a Dockerfile that builds and runs it
hivec agents                         write .hivedocs/ for a coding agent to read
hivec version                        which release this compiler is
```

`build` and `export` take `--target <goos>/<goarch>`.

## Learn

* [The tour](https://hive-lang.run): the whole language. All of it.
* [examples/](examples): Complete programs, from `echo` to a multiplayer
  shooter, every one compiled and run by `./examples/run`.
* [spec/](spec/): the specification.
* [CHANGELOG.md](CHANGELOG.md): what changed, release by release.

