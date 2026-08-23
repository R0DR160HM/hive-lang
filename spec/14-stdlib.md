# 14 — Standard library

Each module owns its types under its own namespace — `hive.net.HttpRequest`,
`hive.json.JsonError`, `hive.map.Map`, `hive.syslink.Address`. The only builtin
types that live directly on `hive` are the core ones the language uses without a
module: `Result`, `Table` and the `hive.TableError` that `using` yields from a
CSV.

A module reached often can be given a short name with `import`
([12](12-modules.md#126-importing-a-standard-library-module)). It is a spelling
and nothing more.

**A module you don't use is not in your build**
([12](12-modules.md#127-what-is-linked)). Every module but two is written against
the target's standard library alone, so HTTP, WebSockets, TCP, JSON,
cryptography, spreadsheets and windows all build offline with no dependencies.
The two exceptions are fetched on the first build that needs them, cached, and
never linked into a program that does not: `hive.sql` links database drivers, and
`hive.ui.scene` is drawn with a pinned three.js.

## 14.1 `hive.conv`

Number and string conversions. Pure.

* **Rounding** (`Float → Int`) — `ceil(v)`, `floor(v)`, `round(v)` (round half
  away from zero). See [05](05-expressions.md#unspecified-behaviour) for
  non-finite inputs.
* **Widening / rendering** — `itf(v)` widens an `Int` to a `Float`; `its(v)`
  renders an `Int` as a `Str`; `fts(v)` a `Float` as a `Str`.
* **Parsing** — `sti(text)` → `Result<Int, hive.conv.ConversionError>`,
  `stf(text)` → `Result<Float, _>`. A `ConversionError` carries the offending
  `input` and a short `message`.

## 14.2 `hive.math`

| | |
| --- | --- |
| **Constants** | `pi()` |
| **Angles** | `sin` `cos` `tan` `asin` `acos` `atan2(y, x)` |
| **Distances** | `sqrt` `hypot(x, y)` `abs` |
| **Bounds** | `min(a, b)` `max(a, b)` `clamp(value, low, high)` |

**Every one takes and answers with a `Float`**, and there is no integer twin.
That is one rule for thirteen functions, and it is the same rule the rest of the
language keeps: Hive never widens a number behind your back, so an `Int` goes in
through `hive.conv.itf` and `hive.math.max(0, health)` is a compile error rather
than a surprise. Clamping an `Int` is an `if`, and needs no library.

Nothing here reports an error, because none of these have one: a value outside a
function's domain answers with the non-finite `Float` the arithmetic already
produces. `atan2` takes the two legs rather than their ratio, which is what lets
it tell the four quadrants apart; `clamp` is exactly `min(max(v, low), high)`, so
bounds the wrong way round answer with `high`.

## 14.3 `hive.map`

A dictionary: keys paired with values, looked up by key. Type-level rules are in
[03](03-types.md#36-maps).

| call | type | what it does |
| --- | --- | --- |
| `new()` | `Map<K, T>` | the empty map |
| `set(m, key, value)` | `(mut Map<K, T>, K, T): void` | adds or replaces a pair |
| `get(m, key)` | `(Map<K, T>, K): Result<T, Bool>` | the value, or `Error(false)` |
| `has(m, key)` | `(Map<K, T>, K): Bool` | the same question without the value |
| `delete(m, key)` | `(mut Map<K, T>, K): void` | removes a pair |
| `keys(m)` | `(Map<K, T>): K[dyn]` | its keys, in order |
| `values(m)` | `(Map<K, T>): T[dyn]` | its values, in the same order |
| `fromTable(t)` | `(Table): Map<Str, Str>` | reads rows as key/value pairs |
| `toTable(m)` | `(Map<Str, Str>): Table` | one two-cell row per pair |

* **The order is the order you set the keys in.** `keys`, `values`, `toTable` and
  `echo` all use it, and replacing a value leaves its key where it was. Go's own
  map iterates in a deliberately randomised order, so a program built on one
  would print something different every run; this one prints the same thing
  twice, which is what makes it testable.
* **Only a `mut` map can be written to.** `set` and `delete` follow `append`'s
  rule exactly, and a `proc` can take a `m: mut hive.map.Map<K, T>` parameter.
* **A map is a value**, and so is what comes out of it: `keys` and `values` are
  fresh vectors.
* **`==` compares the pairs** and ignores the order they were set in. There is no
  ordering *between* maps, so `sort` on a vector of them is a compile error.
* **A map does not travel and does not encode.** `hive.json.encode` refuses one
  and so does a `hive.syslink` mailbox: decoding here is by declared shape, while
  a map's keys are whatever was put in it. Send `toTable(m)` and rebuild it with
  `fromTable` on the other side.
* `import hive.map` names the module `map`, which **coexists with the
  `map(v, f)` builtin**: a call on the name is the module and a bare call is the
  builtin. Nothing has to choose, because the two are told apart by shape.

## 14.4 `hive.file`

General filesystem access, for the files `using` does not cover. Contents move as
`Str`, which holds bytes rather than validated text, so a binary file survives a
read/write round trip. Everything fallible returns
`Result<_, hive.file.FileError>`, whose `reason` is `"NotFound"`,
`"Permission"`, `"Exists"` or `"Io"`, alongside the `path` and the underlying
`message`.

* `read(path)` → `Result<Str, _>`; `lines(path)` → `Result<Str[dyn], _>` splits
  on newlines, dropping the empty piece a trailing newline leaves and any Windows
  carriage returns.
* `write(path, contents)` replaces a file, creating it when absent;
  `append(path, contents)` adds to the end. Both → `Result<Int, _>`, the bytes
  written. Neither creates missing parent directories.
* `exists(path)` → `Bool` (a directory counts); `size(path)` → `Result<Int, _>`.
* `delete(path)` removes a file, or an already-empty directory.
* `list(path)` → `Result<Str[dyn], _>`, sorted and without any leading path;
  `makeDir(path)` creates a directory along with any missing parents, and is not
  an error when it is already there.
* `copy(from, to)` → `Result<Int, _>`; `move(from, to)` renames.

## 14.5 `hive.term`

Line-oriented terminal I/O.

* `print(text)` writes a line to stdout — the same lowering as `echo`, but
  restricted to a `Str`.
* `status(text)` writes a line to **standard error**: what a program is *doing*,
  as against what it was asked for. Redirecting the answer never takes the
  progress with it, which is what lets `hive emit x.hive > main.go` be Go while
  the compiler still says where it has got to.
* `isTerminal()` → `Bool`, whether standard error is a terminal rather than a
  file or a pipe — the difference between somebody sitting there waiting and
  output being collected for later. A program that reports its own progress asks
  this first.
* `read()` blocks for a line of input, stripped of its trailing newline. It parks
  only the calling virtual thread. At end of input it returns whatever preceded
  EOF (`""` if nothing).
* `readSecret()` is that same read with the terminal's echo turned off. The echo
  is put back before the call returns, and also if the program is interrupted at
  the prompt. Where there is no terminal at all, the line is read exactly as
  `read()` reads it and only the hiding of it is lost.
* `args()` → `Str[dyn]`, the command-line arguments in order, excluding the
  program name.
* `exit(code)` ends the program with a status. There is no value to answer with
  and nothing after it runs, which is what makes it a statement rather than a
  call.

**Running another program.** Two calls, and the difference between them is who
is talking to the terminal.

* `exec(command, arguments, directory)` runs it and hands back **everything it
  wrote** — standard output and standard error together, in the order it wrote
  them, which is the order somebody reading a terminal would have seen. An empty
  `directory` means where this program is. It answers with
  `Result<Str, hive.term.ExecError>`: a status other than zero is an `Error`,
  because a command that failed is not a command that answered. The error
  carries the `command`, the `code`, the `output` and a `message` — the output is
  on it because that is usually the whole of why it failed, and a command that
  could not be started at all has a `code` of `-1`.
* `attach(command, arguments, directory)` gives the command **this program's own
  terminal** — its input, its output, its errors — and answers with the `Int`
  status it exited with. Nothing is captured, because the point of it is that the
  command is talking to whoever started this program.

```hive
if hive.term.exec("go", ["build", "."], buildDirectory) is Result.Error(why) {
	echo "the build failed:\n{why.output}"
	hive.term.exit(1)
}
```

The arguments are a vector rather than a line of text, and that is the whole of
the safety story: nothing is handed to a shell, so nothing in an argument can be
read as one. A command that needs a shell asks for one by name.

## 14.6 Reading tables (`using`)

`using` reads a table. Each form says in the source what it is reading, which is
what lets the compiler pick the reader and leave the machinery for the others out
of the build.

```hive
using "./data.csv"                            // a comma-separated CSV
using "./data.tsv" as csv separating by "\t"  // another separator
using "./book.xlsx" as xlsx                   // every sheet of a workbook
using "./book.ods" as ods                     // every table of an ODS
using db run allUsers()                       // a declared query, typed rows
using db run raw someSqlText                  // SQL built at runtime, a Table
```

| form | yields |
| --- | --- |
| `using <path>` / `… as csv [separating by <sep>]` | `Result<Table, hive.TableError>` |
| `using <path> as xlsx` / `as ods` | `Result<Table[dyn], hive.TableError>` |
| `using <connection> run <query>` | whatever the query declared its rows to be |
| `using <connection> run raw <text>` | `Result<Table, hive.sql.SqlError>` |

A CSV is a single table, so it comes back as one `Table`. A **spreadsheet holds
many**, so xlsx and ods come back as a `Table[dyn]` — one per sheet, in document
order, an empty sheet being an empty `Table` so the positions still line up.
Both readers are dependency-free.

Spreadsheet cells arrive as the file stores them, with one exception: **xlsx
keeps a date as a day count**, so the cell's number format is consulted to catch
exactly those and render them as `2026-07-25` (or with a time, or time-only).
Numbers, booleans and cached formula results pass through untouched. An ods
stores real dates, so nothing has to be undone there. Rows are padded to the
widest row in their sheet.

## 14.7 `hive.json`

Built on the idea that Hive's type declarations *are* the JSON schema.

* `parse(text) with T` derives a decoder for `T` at compile time →
  `Result<T, hive.json.JsonError>`. Missing fields, wrong types and wrong static
  vector lengths become errors carrying the exact `path` that failed; JSON fields
  the type doesn't declare are ignored. Variants decode as
  `{"VariantName": {...}}`, and JSON `null` selects a type's first field-less
  variant.
* `encode(value)` derives the encoder from the static type and therefore cannot
  fail.
* `table(text)` reads a JSON array of flat objects as a headered `Table`.
* `parse(text) with Table` flattens a whole document into `[path, value]` rows,
  looked up with `get(table, "keys.layout")` and re-nested by the encoder.

## 14.8 `hive.crypto`

Pure, so it works in a `func` too. Fallible operations return
`Result<_, hive.crypto.CryptoError>`, whose `reason` is a short tag such as
`"BadSignature"`, `"Expired"` or `"Malformed"`.

* **Hashing** — `sha256(input)`, `sha512(input)` (lowercase hex),
  `hmacSha256(input, key)`.
* **Encryption** — `encrypt(plaintext, password)` seals under a password with
  AES-256-GCM, base64-encoded; `decrypt(ciphertext, password)` opens it →
  `Result<Str, _>`. The key is derived with 600,000 rounds of PBKDF2-HMAC-SHA256
  over a random salt, and the salt and nonce are drawn afresh every call, so the
  same text under the same password never encrypts alike. GCM's tag travels with
  the ciphertext, so an edited message is rejected rather than opened into
  something else — `"BadSignature"`, which is also what a wrong password gives.
* **Encoding** — `base64Encode`, `base64Decode`.
* **Random** — `randomHex(bytes)`.
* **JWT** — `jwtSign(claims, secret)` (HS256, compact, cannot fail);
  `jwtVerify(token, secret) with T` checks the signature and the `exp`/`nbf`
  claims, then decodes into `T` — only HS256 is accepted, so `alg: none` and
  algorithm confusion are rejected outright; `jwtDecode(token) with T` decodes
  **without verifying**, for inspection only; `jwtHeader(token)` reads
  `alg`/`typ`/`kid`.

## 14.9 `hive.net`

HTTP, WebSockets and raw TCP, clients and servers. Everything here performs I/O,
so it works inside a `func` or a `proc`, and none of it adds a dependency.

Each of the three servers blocks forever, so it usually goes on a virtual thread
of its own, and each runs its handler once per request/connection on a thread of
its own too. Every call names its protocol, so nothing reads as "the" default
one. A handler is passed **by name** and its declared shape is checked at compile
time, including through a partial application.

**HTTP.** `HttpRequest(method, url, headers, body)`,
`HttpResponse(status, headers, body)`; headers are a `Table` of `[name, value]`
rows.

* `httpRequest(req)` → `Result<HttpResponse, HttpError>`.
* `httpServe(port, handler)`, with `handler` a
  `proc (HttpRequest): HttpResponse`.

**WebSockets** (RFC 6455). The handshake, frame headers, masking, ping/pong and
fragmentation are the runtime's business; a program sees whole messages as `Str`.
A `WsError`'s `reason` is `"Handshake"`, `"Protocol"`, `"Closed"`, `"Send"` or
`"Receive"`.

* `wsConnect(url)`, `wsServe(port, handler)`, `wsSend(conn, message)` →
  the bytes it carried, `wsReceive(conn)` → the next message,
  `wsRequest(conn)` → the `HttpRequest` that opened it, `wsClose(conn)`.
  A peer that hangs up is `"Closed"` — the ordinary end of a conversation.

**Raw TCP.** A stream, not a queue of messages. A `SocketError`'s `reason` is
`"Connect"`, `"Closed"`, `"Send"` or `"Receive"`.

* `socketConnect(host, port)`, `socketServe(port, handler)`,
  `socketSend(conn, data)`, `socketReceive(conn, bytes)` (a short read is
  normal), `socketReceiveLine(conn)` (without the trailing newline),
  `socketPeer(conn)`, `socketClose(conn)`.

**Names.** A `NetError`'s reason is `"NotFound"`, `"Lookup"` or `"NoAddress"`.

* `resolve(name)` → **every** address behind a name, in resolver order. It takes
  a name, not an endpoint, and an address literal resolves to itself.
* `localAddress()` → the address other machines reach this one on: the source
  address the OS would stamp on a packet leaving by the default route. Nothing is
  sent to find out, and loopback is deliberately not an answer.

## 14.10 `hive.syslink`

Addressable **services**, in this process or on another machine, reached by the
same statement either way. A service is long-lived, owns private state only it
can touch, and has an identity you can pass around.

**The handler is a fold over the mailbox** —
`proc (State, Message, hive.syslink.Envelope): State`. The compiler enforces that
the state going in and coming out are the same type. There is no mutex and no
`mut` anywhere: the fold *is* the mutex.

**An address is called.** There is exactly one way to reach a service, and — as
with a func — the call site decides what it means:

```hive
async inbox(Note.Say("hi"))          // send it, wait for nothing; cannot fail
answer := cache(Op.Count())          // send it and wait: Result<Message, SyslinkError>
answer := cache(Op.Count()) with timeout 250
later  := async cache(Op.Count())    // wait where `later` is read
both   := await [a(m), b(m)]         // one barrier, one deadline
```

The reply type **is the mailbox type**, so nothing is annotated: a service answers
with one of its own messages, which makes a mailbox type the whole protocol.

* `spawn(handler, state)` starts a service and returns its address.
* `register(name, address)` publishes it under an atom → `"Taken"` if in use.
* `at(name)` is that service on this node; `on(endpoint, name)` the same service
  on another. Both perform **no I/O and cannot fail** — they are address
  construction, not a lookup.
* `stop(address)`, `answer(from, value)`, `self(from)`,
  `monitor(from, target, message)`.
* `listen(endpoint)`, `node()`, `peers()`.

**A service name is an atom**, which is what lets the compiler know the whole
registry, and a named address is the only kind that **survives its service being
restarted**. A **node has no name**: it is identified by the endpoint it can be
dialed at, so a peer list is ordinary runtime data.

**A crash is local to its service.** A `panic` inside a service body kills only
that service; its monitors are told, its callers stop waiting, and the node keeps
running. This is the one place `panic` does not stop the program.

**Forgetting to answer fails fast.** A request a service handles without
answering comes straight back as `"NoReply"` — unless the envelope escaped the
turn, in which case a reply may genuinely still be on its way and the runtime
keeps waiting. That is what makes a deferred reply possible.

**On the wire.** One persistent, multiplexed connection per node *pair*, carrying
length-prefixed frames, dialed lazily. Messages cross as JSON using the same
derived codecs `hive.json` builds, and every frame carries a 32-bit structural
digest of the message type, so a peer built from a different declaration fails
loudly instead of decoding another type's bytes. Every connection is TLS 1.3,
mutually authenticated, with no plaintext path. **Delivery is best-effort:**
messages queued when a node is declared down are dropped.

## 14.11 `hive.task`

* **`with timeout <ms>`** — see [09](09-concurrency.md#94-with-timeout).
* `sleep(ms)` parks the calling virtual thread. Only that goroutine waits, so two
  calls that each sleep, waited for together in one `await`, finish in about the
  longer of the two rather than the sum. A non-positive `ms` returns immediately.

## 14.12 `hive.time`

Times are plain `Int`s — Unix seconds.

* `now()`, `timezone()` (the zone name or abbreviation at this instant),
  `timezoneOffset()` (minutes east of UTC).
* `format(time, template)` renders in local time with a `strftime`-style
  template. Unrecognised `%x` escapes pass through verbatim:

  | | | | |
  |---|---|---|---|
  | `%Y` year (4) | `%y` year (2) | `%m` month | `%d` day |
  | `%H` hour 00–23 | `%I` hour 01–12 | `%M` minute | `%S` second |
  | `%p` AM/PM | `%j` day-of-year | `%Z` zone name | `%z` zone offset |
  | `%A`/`%a` weekday | `%B`/`%b` month name | `%%` literal `%` | |

## 14.13 `hive.env`

* `get(name)` → `Result<Str, hive.env.EnvironmentError>`. It resolves in this
  order: the `.env` file in the program's own folder; the `.env` in the parent
  folder; the OS environment.
* The `.env` file is read **once**, on the first `get`. Blank lines and `#`
  comments are ignored, an optional `export ` prefix is allowed, and a value may
  be wrapped in quotes, which are stripped.

## 14.14 `hive.sql`

Talks to **SQLite** (the pure-Go `modernc.org/sqlite` driver, compiled straight
into your executable) and **PostgreSQL** (`github.com/lib/pq`).

* Querying uses `using <connection> run <query>`
  ([04](04-declarations.md#45-query)).
* `connect(driver, connString)` → `Result<SqlConnection, SqlError>`;
  `pool(driver, connString, maxOpen, maxIdle)`; `close(conn)`.
* The driver is a `hive.sql.DatabaseDriver`, built with `.SQLite()`,
  `.PostgreSQL()`, or `.Other(name)`.

A `SqlConnection` is a **connection pool**, safe to hold for the life of the
program and to share across virtual threads. Open it once in `main` and pass it
along. Never open one per query.

Runtime failures carry a `reason`: `"Connection"`, `"Query"`, `"Shape"` (a
different number of columns came back) or `"Convert"` (a cell did not fit its
field's type).

**In-memory SQLite** belongs to the *connection*, not the process, which under a
pool means each connection lands on a database of its own. Ask for a shared
cache — `pool(driver, "file::memory:?cache=shared", 8, 1)` — or pin the pool to
one connection.

## 14.15 `hive.ui`

A **view is a value** — a tree of widgets — and what paints it is decided
somewhere else:

* `window(title, view, update, state)` opens a window and does not return.
* `html(view)` renders the same tree as an HTML fragment, and `page(title, view)`
  as a whole document — which is what an `httpServe` handler answers with.

**The window is a service.** `update` is the same fold a `hive.syslink.spawn`
handler is, and is checked as one, so a window has an address, needs no mutex,
and can be posted to by a background task or by another machine. That is why the
module needs no notion of a *command*.

**The view is a `func`, and that is not a formality.** A func cannot call a proc
and cannot hold a mutex, so drawing cannot act — which matters because a repaint
happens on every change.

**Every widget takes the same two things: its attributes, then its payload.**
There are no optional parameters in Hive, so what would be an optional argument
elsewhere is an entry in the attribute vector.

| widget | payload |
| --- | --- |
| `row` / `column` | `View[]` |
| `spacer()` / `spinner(attrs)` / `none()` | — |
| `overlay(attrs, child)` | `View` |
| `text(attrs, content)` | `Str` |
| `image(attrs, src, alt)` / `link(attrs, href, label)` | `Str, Str` |
| `icon(attrs, name)` | `Icon` |
| `button(attrs, label)` / `input(attrs, value)` / `textarea(attrs, value)` | `Str` |
| `checkbox(attrs, label, checked)` | `Str, Bool` |
| `select(attrs, options, chosen)` | `Str[], Str` |
| `table(attrs, rows)` | `Table` |
| `scene(attrs, shapes)` | `Shape[]` — see [14.16](#1416-hiveuiscene) |

A widget is here only if it cannot be composed from the others *and* needs
something the renderer has that Hive does not. A card is a `column` with padding,
a toast is an `overlay` and a message, a divider is a `row` with a border.

**`link` is the one widget that works without an event.** The window follows the
**message** and a served page follows the **href**, from the identical tree.
Where a link may point is a closed set — a path within the page, a relative path,
or `http`, `https`, `mailto` — and anything else renders as no destination at
all.

**Attributes** are semantic tokens rather than CSS values:

| | |
| --- | --- |
| Layout | `gap` `pad` `width` `height` `grow` `align` `justify` `scroll` |
| Text | `size` `heading` `tone` |
| Colour | `background(Tone)` |
| State | `disabled` `busy` `placeholder` `hint` `kind` |
| Events | `on(Msg)` `onDismiss(Msg)` `onInput(f)` `onSubmit(f)` `onChoose(f)` `onToggle(f)` `onPick(f)` `onSort(f)` |

A scene takes attributes of its own — a camera, a sky, and the events a game
needs — and so do the shapes in one. They are [14.16](#1416-hiveuiscene).

`on` and `onDismiss` carry the message itself; the rest carry a **function** of
what the user did, which is what a constructor with a hole is for:
`ui.onInput(Msg.Changed(_))`.

The enumerations are ordinary closed types (`Align`, `Justify`, `TextSize`,
`Tone`, `Axis`, `InputKind`, `Icon`), reached the way every other type is. None
is an atom, deliberately: the atom table belongs to your program, and a library
that added to it would renumber the atoms you wrote.

**Colour.** `Tone` is the one enumeration that is not only a closed set: past the
five roles, `HEX(Str)` and `RGBA(Int, Int, Int, Int)` carry a colour outright. A
role becomes a class the stylesheet answers for; a colour becomes a declaration.
A colour is **checked, not trusted** — `HEX` takes `#` and 3, 4, 6 or 8 hex
digits and anything else is `Normal`, and `RGBA` clamps each channel — and a role
brings a readable foreground with it while a computed colour brings nothing.

## 14.16 `hive.ui.scene`

Three dimensions inside a window. A scene is a **value** like every other view: a
camera, a sky, and a vector of shapes, rebuilt by an ordinary `func` from the
state as often as there are frames. Nothing here is a handle — there is no mesh
to keep, no material to allocate and no canvas to hold — so a program that draws
one answers "what is there right now" and never "what has changed".

It is **a module of its own because it is the one that carries a download**
([14](#14--standard-library)): a pinned three.js, fetched on the first build that
needs it and cached. A window that draws no scene links none of this.

### The shapes

A shape is here only if it cannot be made out of the others. Dimensions are the
payload rather than attributes, because they are what the shape *is*: a sphere
without a radius is not a sphere with a default one.

| shape | payload |
| --- | --- |
| `box(attrs, width, height, depth)` | a solid |
| `sphere(attrs, radius)` | |
| `cylinder(attrs, radius, height)` | standing on its end |
| `cone(attrs, top, bottom, height)` | standing on its end, **both** radii |
| `ground(attrs, width, depth)` | a plane that already lies flat |
| `label(attrs, words)` | words that always face the viewer |
| `line(attrs, fromX, fromY, fromZ, toX, toY, toZ)` | |

**`cone` takes both of its radii** rather than only the base. A cone in the world
is hardly ever the perfect one — a track marker is snub-nosed, a nose cone ends in
a blade, a stack of tyres narrows without coming to a point — and a shape that
could only be the perfect one would be composed around rather than used. A top of
nought is the perfect one, and a top equal to the bottom is a `cylinder`.

**`ground` is already lying down**, so a floor costs no rotation and `turn` still
means everywhere what it means anywhere. **`label` takes no rotation** for the
same reason a label exists: one you can read from one side only is not a label.
**`line` takes no position**, because a line is *between* two places and has no
third one to call its own.

### Where a shape is, and what it is made of

| attribute | carries |
| --- | --- |
| `at(x, y, z)` | where its middle is |
| `turn(x, y, z)` | its rotation, in radians, applied X then Y then Z |
| `paint(Tone)` | its colour |
| `surface(Surface)` | what it is made of |

`Surface` is the finish, as against `paint`'s colour: `Turf`, `Gravel`, `Tarmac`,
`Kerb`, `Planks`, `Staves`, `Speckle`, `Metal`, `Carbon`, `Gloss`. Every one is
drawn **over** whatever colour the shape is, so one pattern serves a red kerb and
a blue one, and `Gloss` adds no pattern at all.

Where a shape says nothing, its **kind** decides: a `ground` is `Turf`, a
`cylinder` or a `cone` is `Staves`, a `sphere` is `Speckle`, and everything else
is `Planks`. That is what the renderer did before there was a way to say, so a
scene that never mentions a surface draws exactly as it did — and it is also why
saying is worth having, because a road drawn as a `ground` came out as a lawn.

**A colour with an alpha is translucent.** `Tone.RGBA(r, g, b, a)` and an eight-
or four-digit `Tone.HEX` carry one, and in a scene it is honoured: the shape is
drawn see-through and writes no depth, so whatever is behind it stays visible.
This is how a ghost, a tinted screen or the plume behind something is drawn.

### The camera, the sky and the mouse

These go on the `scene` itself rather than on a shape.

| attribute | carries |
| --- | --- |
| `eye(x, y, z)` | where the camera is |
| `aim(yaw, pitch)` | where it is looking, in radians |
| `lens(Int)` | the field of view, in degrees |
| `fog(Int)` | how far you can see, in metres |
| `background(Tone)` | the sky, which the fog fades into |
| `grab(Bool)` | whether the window should hold the mouse |
| `crosshair(Bool)` | whether to draw one in the middle |

Lighting is **not** something a scene describes. The rig is fixed — one light
from the sky and one from a sun — chosen so that a solid painted a colour comes
out that colour with a shaded side. What makes a scene dark is its palette, which
is why a night scene is written in dark colours rather than by turning something
down.

### What the player did

| event | reports |
| --- | --- |
| `onFrame(f)` | `Int` — how many milliseconds the last frame took |
| `onKeyDown(f)` / `onKeyUp(f)` | `Str` — the key's name |
| `onLook(f)` | `Float, Float` — how far the mouse moved, across and down |
| `onGrab(f)` | `Bool` — whether the window is holding the mouse now |
| `onPad(f)` | `Int, Str, Float` — which pad, which control, where it now is |

A key is named the same on every layout the browser can report: a letter or a
digit is itself, and everything else is the word for it — `space`, `enter`,
`escape`, `tab`, `shift`, `ctrl`, `up`, `down`, `left`, `right`.

**A gamepad is the one input a browser will not tell you about**: there is no
event for a stick moving, only a snapshot you have to ask for. So a pad is read
once a frame and what arrives is what *changed* — which is what makes a button on
a pad the same kind of thing as a key going down rather than a second way of
hearing about input.

One shape covers the whole device, because a button is a control that is only ever
0 or 1:

| control | name | reports |
| --- | --- | --- |
| sticks | `leftX` `leftY` `rightX` `rightY` | −1 to 1 |
| triggers | `lt` `rt` | 0 to 1 |
| face | `a` `b` `x` `y` | 0 or 1 |
| shoulders | `lb` `rb` | 0 or 1 |
| dpad | `up` `down` `left` `right` | 0 or 1 |
| the rest | `back` `start` `guide` `lstick` `rstick` | 0 or 1 |
| anything past those | `b17` `b18` … `axis4` … | by number |
| the pad itself | `here` | 1 when it arrives, **2** when it arrives with a layout the browser could not name, 0 when it goes |

The names are the standard mapping's, **by position, for every pad** — including
the ones the browser declines to name. It leaves `mapping` empty for any device
missing from its own table, which on a desktop is most of them and very nearly
every wheel, while the ordering underneath is the same in almost every case. A
pad nobody can name is still a pad; ignoring it would throw away most of the
working controllers there are.

`here` arriving as **2** rather than 1 is how a program is told that the names it
is about to hear are a good guess rather than a promise — which is worth showing
somebody, because it is also the answer to "why is the brake on the wrong pedal".
A pad that is unplugged lets go of every control it was holding first, and then
says `here` is 0.

**A pad the browser cannot see at all** is not this module's doing and is worth
knowing about: a browser reports no pads until one has been *used* — a button
press or a stick moved — and a sandboxed browser reports none ever unless it was
given access to input devices (for a Flatpak, `flatpak override --user
--device=all <app-id>`).

A dead zone of eight percent is applied before the event is sent, and nothing is
sent until a control has moved by a hundredth — a stick at rest is never quite at
rest, and a pad that reported that would post sixty messages a second saying
nothing.

The **first number is which pad**, so two of them in one machine are told apart
without anything else changing.
