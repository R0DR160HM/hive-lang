# Examples

Twenty-eight programs, and between them every feature the language has. Each one
compiles and runs on the compiler in [`../src`](../src) — that is what `./run`
checks, and what makes these examples rather than illustrations. They are in the
order someone learning the language would read them: the language itself first,
then the standard library, then programs built out of all of it.

```
./examples/run              all of them
./examples/run 03 15        only the ones whose directory starts like that

hive run  examples/02-types/types.hive
hive test examples/11-testing/cart.test.hive
```

| | | |
| --- | --- | --- |
| 01 | [basic-io](01-basic-io) | `echo`, a type with variants, and a CSV read with `hive.file.csv` |
| 02 | [types](02-types) | every type there is: strings, vectors, atoms, numbers, bools, `mut`, and a `query` |
| 03 | [pattern-matching](03-pattern-matching) | the four kinds of pattern, and binding through `&&` |
| 04 | [value-semantics](04-value-semantics) | why two names never observe each other's writes, and the one case where they do |
| 05 | [first-class-functions](05-first-class-functions) | bare references, partial application, the vector walks, shadowing a builtin |
| 06 | [generics](06-generics) | type variables, monomorphization, and generic types |
| 07 | [maps](07-maps) | `hive.map`: order, values, tables, composite keys |
| 08 | [advent-2025-day-2](08-advent-2025-day-2) | Advent of Code, and `assert` as a program's own check |
| 09 | [advent-2025-day-3](09-advent-2025-day-3) | day 3, where every index is proved in range |
| 10 | [modules](10-modules) | a program in four files, one of them Go |
| 11 | [testing](11-testing) | `test` declarations, `assert` with both sides, and coverage |
| 12 | [concurrency](12-concurrency) | all five spellings of a call, and what a thread does to `mut` |
| 13 | [files-and-spreadsheets](13-files-and-spreadsheets) | `hive.file.xlsx` and `hive.file.ods`, and the whole of `hive.file` |
| 14 | [sql](14-sql) | `query` declarations, typed rows, optional filters, and `hive.sql.unsafe` |
| 15 | [laws](15-laws) | a chat app with a `law` of each kind: a read message never goes back, proved for every message and receipt while the program compiles; every message has a body and goes to someone else, kept wherever one is written; and a contact reads only their own chats, in every query on the table |
| 16 | [crypto](16-crypto) | hashing, HMAC, base64, password encryption, and JWTs |
| 17 | [password-vault](17-password-vault) | a vault sealed with `hive.crypto`, read with a hidden prompt |
| 18 | [pictures](18-pictures) | Hive's logo read from inside the executable, decoded, scaled and drawn in characters |
| 19 | [programs-alongside](19-programs-alongside) | a program started, talked to, and stopped with everything it started — the program being itself |
| 20 | [networking](20-networking) | an HTTP server and client, raw TCP, WebSockets, and HTTP and WebSockets on one port |
| 21 | [streaming-answer](21-streaming-answer) | a language model's answer read as it arrives, and a looping one stopped by hanging up |
| 22 | [distributed-actors](22-distributed-actors) | two nodes, one statement to reach either, and a crash that stays local |
| 23 | [online-cache](23-online-cache) | an HTTP cache over a cluster: `hive.net`, `hive.sql` and `hive.syslink` at once |
| 24 | [every-widget](24-every-widget) | every `hive.ui` widget but the 3D ones, with every attribute and event among them, in one window |
| 25 | [chat](25-chat) | a window, a mailbox, and two nodes talking |
| 26 | [multiplayer-fps](26-multiplayer-fps) | a 3D scene, sixty frames a second, and a client and a server over a websocket |
| 27 | [formula-kart](27-formula-kart) | a ten-car race on a circuit rolled from a number, with a landscape round it, a server, a map and a dial |
| 28 | [comptime](28-comptime) | a table of countries read by `with compiler` while the program builds, and carried by it rather than the file |

## What `./run` does with them

Each directory holds one or more entrypoints, whatever they read, and — where
the program's output is worth pinning down — an `.expected` file holding what it
prints. `./run` compares the two, so an example that stops being true stops
passing.

Ten of them are **compiled but not run**, and the reason is the same in each
case: they do not finish. A server blocks forever (20, and the two games' own
servers in 26 and 27), a window waits for somebody to close it (24, 25, and the
two games' clients), a distributed pair waits for the other node (22, 23), and a
vault waits for somebody to type a password (17). Compiling one is what can be
checked without a person — and seven of those ten carry test suites that exercise
the rest, across the cache, the vault, the chat, the shooter's two halves, the
race and the widgets.

Two more have no `.expected` file because what they print is a race by design:
`10-concurrency`, whose two `note` calls run at once, and anything that reports a
clock.

## Where they came from

These are the same programs the compiler this one replaces was written against,
ported one for one and accepted very nearly verbatim — which is the useful thing
about them: two independent compilers of the same language, and the second one
takes the first one's programs as they were written. Four exceptions are worth
knowing about:

* **The remote import in [11](11-modules)** is written out in a comment rather
  than performed. It needs a repository of `.hive` files to point at, and an
  example should not need one to run; the machinery is `../src/fetch.hive` and
  `../test/fetch.test.hive` holds it to its word.
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
* **[22](22-formula-kart) was not ported from anywhere.** It is the first example
  written against this compiler rather than accepted from the last one, and four
  things in `hive.ui.scene` were added for it: the `cone` shape, the `surface`
  attribute, translucency in a scene, and `onPad`, which is how a gamepad reaches
  a Hive program at all. Each is in [14.16](../spec/14-stdlib.md#1416-hiveuiscene),
  and each earned its place by something in the race being impossible or ugly
  without it — a road drawn as a `ground` came out as a lawn.

  It takes 19's split further. A `server.hive` owns the only copy of the race and
  a `client.hive` owns a screen; a client sends `drive.Wants` — a steering angle,
  two pedals and two buttons, the identical value a bot produces — and nothing
  else, so the server puts a person's car and a bot's through the same
  `drive.stepped`. Run the client with no server and it holds the race itself,
  which is the same call again: one program, two ways of playing, and no second
  copy of the game loop.
