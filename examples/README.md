# Examples

Twenty-one programs, and between them every feature the language has. Each one
compiles and runs on the compiler in [`../src`](../src) — that is what `./run`
checks, and what makes these examples rather than illustrations.

```
./examples/run              all of them
./examples/run 05 11        only the ones whose directory starts like that

hive run  examples/02-types/types.hive
hive test examples/15-testing/cart.test.hive
```

| | | |
| --- | --- | --- |
| 01 | [basic-io](01-basic-io) | `echo`, a type with variants, and a CSV read with `using` |
| 02 | [types](02-types) | every type there is: strings, vectors, atoms, numbers, bools, `mut`, and a `query` |
| 03 | [networking](03-networking) | an HTTP server and client, raw TCP, and WebSockets |
| 04 | [crypto](04-crypto) | hashing, HMAC, base64, password encryption, and JWTs |
| 05 | [sql](05-sql) | `query` declarations, typed rows, optional filters, and `run raw` |
| 06 | [value-semantics](06-value-semantics) | why two names never observe each other's writes, and the one case where they do |
| 07 | [pattern-matching](07-pattern-matching) | the four kinds of pattern, and binding through `&&` |
| 08 | [first-class-functions](08-first-class-functions) | bare references, partial application, the vector walks, shadowing a builtin |
| 09 | [online-cache](09-online-cache) | an HTTP cache over a cluster: `hive.net`, `hive.sql` and `hive.syslink` at once |
| 10 | [concurrency](10-concurrency) | all five spellings of a call, and what a thread does to `mut` |
| 11 | [modules](11-modules) | a program in four files, one of them Go |
| 12 | [files-and-spreadsheets](12-files-and-spreadsheets) | `using` over xlsx and ods, and the whole of `hive.file` |
| 13 | [distributed-actors](13-distributed-actors) | two nodes, one statement to reach either, and a crash that stays local |
| 14 | [generics](14-generics) | type variables, monomorphization, and generic types |
| 15 | [testing](15-testing) | `test` declarations, `assert` with both sides, and coverage |
| 16 | [password-vault](16-password-vault) | a vault sealed with `hive.crypto`, read with a hidden prompt |
| 17 | [chat](17-chat) | a window, a mailbox, and two nodes talking |
| 18 | [maps](18-maps) | `hive.map`: order, values, tables, composite keys |
| 19 | [multiplayer-fps](19-multiplayer-fps) | a 3D scene, sixty frames a second, and a client and a server over a websocket |
| 20 | [advent-2025-day-2](20-advent-2025-day-2) | Advent of Code, and `assert` as a program's own check |
| 21 | [advent-2025-day-3](21-advent-2025-day-3) | day 3, where every index is proved in range |

## What `./run` does with them

Each directory holds one or more entrypoints, whatever they read, and — where
the program's output is worth pinning down — an `.expected` file holding what it
prints. `./run` compares the two, so an example that stops being true stops
passing.

Seven of them are **compiled but not run**, and the reason is the same in each
case: they do not finish. A server blocks forever (03, and the game's own server
in 19), a window waits for a browser (17, and the game's client), a distributed
pair waits for the other node (09, 13), and a vault waits for somebody to type a
password (16). Compiling one is what can be checked without a person — and five of
those seven carry test suites that exercise the rest: 167 tests across the cache,
the vault, the chat, the game's two halves and the cart.

Two more have no `.expected` file because what they print is a race by design:
`10-concurrency`, whose two `note` calls run at once, and anything that reports a
clock.

## Where they came from

These are the same programs the compiler this one replaces was written against,
ported one for one and accepted very nearly verbatim — which is the useful thing
about them: two independent compilers of the same language, and the second one
takes the first one's programs as they were written. Three exceptions are worth
knowing about:

* **The remote import in [11](11-modules)** is written out in a comment rather
  than performed. It needs a repository of `.hive` files to point at, and an
  example should not need one to run; the machinery is `../src/fetch.hive` and
  `../test/fetchTests.hive` holds it to its word.
* **A Go file import is a real import again.** [11](11-modules) calls into
  `lib/measures.go`, whose signatures the Go toolchain reads
  ([12.4](../spec/12-modules.md#124-importing-a-go-file)) — the one example that
  needs a compiler to talk to another language's.
* **[19](19-multiplayer-fps) is architecture rather than a port.** It was one
  program that every player ran, meshed together with `hive.syslink`: each node
  held its own player and its own pack of the dead, told the others what both were
  doing, and nothing was in charge. It is now the traditional shape instead — a
  `server.hive` that owns the world and a `client.hive` that owns a screen, over a
  websocket, with the protocol a type declaration in `lib/wire.hive` and the map
  arithmetic in `lib/place.hive` that both of them import. The game plays the same;
  what changed is who decides. `13-distributed-actors` is still the example that
  is about `hive.syslink` across machines.
