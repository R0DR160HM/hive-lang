# Changelog

## v0.2.13

### Standard library

* **`hive.ui.code(attrs, text, runs)` is a code editor**: fixed-width, no wrapping, coloured by runs — `ink`, `shade`, `squiggle`, `underline`, `marker` (a line's mark in the gutter), `band` (a line's background) and `note` (text after a line's end that is not part of the text), each placed by character offsets. It types, selects, scrolls, undoes and pastes as a textarea does; Tab types a tab and Enter keeps the line's indentation.
* **A code editor tells and is told**: `onEdit` is handed what an edit replaced (from, to, text) rather than the whole text, `onCaret` the selection, `onView` the lines in view, `onFit` the columns and rows that fit, `onHover` and `onJump` the character under the pointer and under a Ctrl+click, `onProbe` the one under the pointer while Ctrl is held, and `onPaste` the clipboard's text. `caret(anchor, head, serial)` puts the selection somewhere, once per change; `numbers`, `tabSize`, `fontSize`, `readOnly` and `perform(command, serial)` (undo, redo, cut, copy, paste, select all) round it out.
* **`hive.ui.keys(names)` and `onKey(f)`**: a widget takes the keys it names — `"Ctrl+S"`, `"Escape"`, `":"`, or `"Any"` — and the innermost one around the focus that names a key gets it; nothing else happens to that key.
* **The pointer's own events on any widget**: `onMenu` (a right click), `onMiddle`, `onDouble` and `onDrag(f)`, handed how far the pointer moved since the press and whether it was let go.
* **`anchor(Anchor.Pointer)` and `anchor(Anchor.Caret)`** open an overlay where the pointer was last pressed or under a code editor's caret, never past the window's edge; a press anywhere else is its `onDismiss`.
* **`hive.ui.title(text)`** on the outermost widget is what the window's title bar says.
* **Requests carried out once per serial**: `focus(serial)` focuses a widget (or the first field in it) and `clip(text, serial)` puts text on the clipboard.
* **A button's or a field's look**: `border(n)`, `borderTone(tone)`, `radius(n)`, `ring(false)` (no accent ring while focused) and `hover(tone)` (the colour behind any widget under the pointer; a link with one is not underlined). A button or field in a colour of its own draws no edge unless it asks for one.
* **A row that scrolls across keeps its children's widths**, so what does not fit is scrolled to rather than squeezed.

### Fixes

* **The native window no longer crashes at random on Windows**: the message `DispatchMessage` worked on lived on a goroutine stack that could move while the window procedure ran.
* **The native window paints faster**: a rounded box fills its middle a row at a time, and a field works out its text and its lines once per change.
* **A link drawn natively keeps a colour of its own** rather than taking the accent.
* **A crash in a native window is kept**: what it prints is also appended to `<temp>/<program>-crash.log`, since such a window has no console.

## v0.2.12

### Language

* **`Secret` is text that must not leak**: `hide(text)` answers a `Result<Secret, SecretError>` kept in memory that is never swapped to disk, and `reveal(secret)` is the only way back to a `Str`.
* **`bypass(text)`** is a `Secret` that cannot fail, kept in ordinary memory that may be swapped out.
* **`hive.Secret` and `hive.SecretError`** reach the builtins from a program that declares its own.
* **A `Secret` is never shown**: `echo`, `panic`, interpolation, `encode` and a service message refuse one, or anything holding one, at compile time.
* **`==` on secrets compares what they hold**, in constant time.

### Standard library

* **`hive.crypto.encrypt` and `decrypt` keep the plaintext a `Secret`**, under a `Secret` password, and `hmacSha256` and `jwtCodec` take a `Secret` key.
* **`hive.term.readSecret()` answers a `Result<Secret, SecretError>`**, read straight into locked memory, and `hive.file.writeSecret` and `hive.syslink.setKey` take a `Secret`.
* **`hive.env.getSecret(name)`** is `get` answering a `Secret`, and **`hive.crypto.randomSecret(bytes)`** is `randomHex` drawn into locked memory, answering a `Result`.
* **`hive.ui.touch(name)` makes any widget a thumb control.** While a finger is on it, a scene's `onPad` hears pad -1: `name` is 1 while the finger is down and 0 once it lifts, and `nameX` and `nameY` are where on the widget it is, -1 to 1 from the middle and held inside a circle. Every finger is followed on its own, so a stick and a button can be held together, and the widget's box is taken when the finger goes down, so a repaint under it moves nothing. The page neither scrolls nor zooms under one.

### Tooling

* **`hive test <directory>`** runs every test under it that git does not ignore, plus those of anything outside it that a file inside imports, each file's tests once.

### Breaking

| was | is |
| --- | --- |
| `hive.crypto.encrypt(text, password)` | `hive.crypto.encrypt(bypass(text), bypass(password))` |
| `hive.crypto.decrypt(sealed, password)` → `Result<Str, _>` | `hive.crypto.decrypt(sealed, bypass(password))` → `Result<Secret, _>` |
| `hive.crypto.hmacSha256(input, key)`, `hive.crypto.jwtCodec(key)` | `bypass(key)` |
| `hive.term.readSecret()` → `Str` | → `Result<Secret, SecretError>`; `reveal` the `Secret` for the text |
| `hive.file.writeSecret(path, text)`, `hive.syslink.setKey(key)` | `bypass(text)`, `bypass(key)` |

## v0.2.11

### Language

* **Library modules need no `hive.` prefix**: `task.sleep(10)` is `hive.task.sleep(10)`. A declaration, import, local or parameter of the same name comes first, and `hive.<module>` always reaches the library.
* **Patterns nest**: `foo() is Result.Ok(Foo.Bar(["foo/{padding}/bar", ...rest]))` compiles to exactly the `&&` chain it abbreviates. A variant's field may also hold a literal, as in `Result.Ok(3)`.
* **Exhaustiveness follows nested patterns**, vector lengths (`[]` and `[x, ...rest]`) and `Bool`s, and a chain that falls short names a value no branch takes.

### Standard library

* **Windows and Linux draw a `hive.ui.window` themselves** — every widget but `scene` and `inset`, with no browser and no C compiler. The layout is modelled on [Clay](https://github.com/nicbarker/clay) by Nic Barker.
* **Such a window behaves like a desktop one**: selection and copying, context menus, undo, draggable scroll bars, resizable textareas, and PNG, JPEG, GIF, WebP and SVG images.
* **Screen readers and input methods work in it**: UI Automation on Windows, AT-SPI on Linux, and IBus or Fcitx5 for typing.
* **`hive.ui.webview(title, view, update)`** is a `window` that is always a page.
* **`hive.syslink.setKey(key)`** sets this program's cluster key for every connection after it, held in memory only.

### Tooling

* **`hive analyze` lists dead code**: what nothing reached from `main` or a test names, and parameters never read.

### Examples

* **`23-every-widget`**: every `hive.ui` widget but the 3D ones, in one window.

### Fixes

* **A member of a value with no fields**, such as `n.size` on an `Int`, is a compile error rather than a Go toolchain failure.
* **A chain testing `p.left` then `p.right` no longer counts as exhaustive**; it compiled and panicked with `hive: unreachable`.
* **A variant pattern must match its subject's type**, where a mismatch reached the Go toolchain.

## v0.2.10

### Language

* **Services are the language's own.** Three builtins start, name and stop them:
  * **`spawn(handler, state)`** starts a service, and **`spawn(handler, state, name)`** starts one registered under an atom. Either answers `Result<Address, hive.syslink.SyslinkError>` — `"Taken"` for a name another service holds — and either takes a handler of both shapes, `proc(mut S, M): M` or `proc(mut S, M, Address): M`.
  * **`at(name)`** is the service registered under `name` on this node, and **`at(endpoint, name)`** the same one on another. Neither does any I/O.
  * **`kill(address)`** stops a service, on this node or another.
* **`Address`** is a builtin type, written with no module; `hive.Address` is the same type where a program declares an `Address` of its own.
* **A `query` may answer with a `Table`**: a header row of column names, then every row as text — the one result `SELECT *` fills.
* **An `Int` never wraps.** Arithmetic that would pass the largest or smallest `Int` stays at it — `MAX + 1` is `MAX`, `MIN - 1` is `MIN`, `2 ** 100` is `MAX`, and `-MIN` is `MAX` — where it wrapped around to the other end. Two literals that overflow together, `9223372036854775807 + 1`, compile too, where the Go toolchain refused them.
* **A guard covers the rest of its own condition**: `if v bounds i && v[i] > 0` compiles, and a name a pattern binds is proved by a guard after it.

### Standard library

* **`hive.json.JsonValue.Null`** — a document's `null`, read and written as one, where a `null` anywhere in a `JsonValue` was an error at its path.
* **`hive.ui.window(title, view, update)` is a handler, and `spawn` opens it.** Opening a window no longer waits for it, so a program may open several: closing one kills its service, closing the last ends the program, and a `main` that returns while one is open waits for them.
* **`hive.task.sleepForever()`** parks the calling thread for good.

### Fixes

* **A builtin called from an imported module is the builtin**, where the entrypoint declaring one of the same name — a test file's own `at`, say — captured the call.
* **A dead service's name is free before anyone hears it died**, so a caller told `"Down"` can spawn under it straight away.
* **The bounds pass is sound where it was not.** An index rebound, redeclared or shadowed by a pattern under its guard, a length lost through an assignment in a loop body, a counter moved inside its loop, and an upper bound with no lower one all compiled and could fail at run time; each now costs the proof.
* **Builtins and library calls take named arguments** like any call, by the names specs 13 and 14 give them, and work them out in the order written: `join(sep: ",", vector: v)`, `hive.math.clamp(value: x, low: 0.0, high: 1.0)`. A builtin ignored the names and reached the Go toolchain with the arguments in the wrong places, and a library call silently took them by position.
* **A function value fills only a slot whose calls it can take.** A `proc(Str[3]): void` passed where a `proc(Str[]): void` was wanted compiled, and failed out of range when the slot handed it one element; a callable with a sized parameter is otherwise a value like any other, its type carrying the promise.
* **Programs the Go toolchain refused are refused by the checker**, with a message about the program: binding a call that answers with nothing; declaring a name twice in one block; an expression that is not a call standing as a statement; an operator on a type it is not defined on (`<` on vectors, `-` on strings, `==` on function values); an await-all mixing answer types; `with timeout` on a `void` call; a `for each` annotation the element does not fit; a struct that holds itself by value; `main` taking or answering anything; a builtin or library call as a value or partially applied; a union field only some variants have, or an assignment into a union's field; two tests with one title.
* **A union value reads its shared fields**, where `event.at` failed in the Go toolchain.
* **`sort` orders a union by its variants' declaration order**, where it left the vector as it was or panicked.
* **A partial application captures what it was given**, where it read the variable at each call; **named arguments are evaluated in the order written**; **`_ := x` compiles**, and an `async` binding nobody reads still runs.
* **A failed `assert` says what it asserted**, and for `==`/`!=` both sides, where it said only "assertion failed".
* **`hive test` shows what a failing test printed, and only that**: a line of go test's own about the runtime package no longer trails the last failure as a blank line, and a printed line keeps the tabs in it.
* **A function that answers with a value cannot end on an `assert`.** One that holds carries on past it, so `func f(n: Int): Int { ...; assert n == 0 }` fell off its own end and crashed with "hive: unreachable" on exactly the input it asserted; it is now a compile error asking for a `return` or a `panic`. A call to `hive.term.exit`, which never returns, now closes a path the way `panic` does.
* **An error in an imported module is reported in that module's file**, with names as the source spells them (`text.pad`, not `text_0_pad`) — from every pass, the emitter's included, and in coverage too; an import that names no file is reported at the import; a file named `text-utils.hive` compiles.
* **Errors go to standard error**, so `hive emit x.hive > main.go` never writes one into the Go; a usage error exits non-zero with `hive:` in front; every command refuses a flag it does not take. What a running program's runtime says about itself — a service that crashed or dropped a message, a node gone down, a window that could not open — goes there too, rather than into the program's own output.
* **The runtime:** a `.env` beside the executable is read wherever it is started from; a CSV's byte-order mark is dropped and a separator longer than one character refused; JSON keeps a repeated key's last value in both readers and refuses text after the document; a failed `connect` is `"Connection"`; a local name nobody registered answers `"NoProc"` and a killed service `"Down"` at once, where both waited out the timeout; `listen` on a loopback host binds only loopback; `assets/` is served to any window, so `assets/font.woff2` sets it; `hive container` exposes no port for a program that serves none, and writes no Dockerfile for a program that does not compile.

### Breaking

| was | is |
| --- | --- |
| `hive.syslink.spawn(h, s)`, `hive.syslink.spawnAddressed(h, s)` | `spawn(h, s)`, answering a `Result` |
| `hive.syslink.register(#Name, address)` | `spawn(h, s, #Name)` |
| `hive.syslink.at(#Name)` / `hive.syslink.on(endpoint, #Name)` | `at(#Name)` / `at(endpoint, #Name)` |
| `hive.syslink.stop(address)` | `kill(address)` |
| `hive.syslink.Address` | `Address` |
| `hive.ui.window(title, view, update, state)`, `hive.ui.windowAddressed(...)` | `spawn(hive.ui.window(title, view, update), state)` |
| closing a window ending the program | closing the last one does |
| an address in a message's digest as `hive.syslink.Address` | `Address`: a node built before this one does not talk to one built after |
| a path ending in `assert` | end it in `panic` or `return` |
| `hive.conv.its(_)`, `join(_, ",")` | a `func` of your own, partially applied |
| `proc main(args: Str[]): Int` | `proc main(): void`, with `hive.term.args()` and `hive.term.exit(code)` |
| `x := 1` twice in one block | `mut x`, then `x = 2` |
| `#A + #B` | atoms do not add |
| `Int` overflow wrapping around | it stops at `MAX` or `MIN` |
| compile errors, and the runtime's `hive:` notices, on standard output | on standard error |

## v0.2.9

### Language

* **A `proc` with a mutex parameter is a value.** It can be referenced, partially applied, stored and passed like any other: a function type marks the position `mut` — `proc(mut Str[dyn], Str): void` — and a call through the value hands it a `mut` variable exactly as a direct call does. A partial application leaves a mutex position a hole, and `func(mut ...)` is refused.
* **A call through a function value is held to its type**: how many arguments, what each one is, and no named arguments, where only a field's argument count was checked and a local's mistakes reached the Go toolchain.

### Standard library

* **A service's handler is now `proc(state: mut S, msg: M): M`.** It writes its state in place and answers with what it returns, so every request is answered, and the handler is an ordinary proc a test can call.
* **`hive.syslink.spawnAddressed`** and **`hive.ui.windowAddressed`** start a handler that takes its own address third, `proc(mut S, M, hive.syslink.Address): M`, and is handed it every turn.
* A handler whose state is not `mut`, whose answer is not one of its own messages, or whose state argument does not fit is refused where it is started.
* **`hive.json.JsonValue`** — a document whose shape is not declared: a union of `String`, `Boolean`, `Int`, `Float`, `Array` and `Object`, whose codec reads and writes the JSON as it is. It is built, matched and compared like any declared type, and may be a field of one. An `Object` holds its properties as a `hive.map.Map<Str, JsonValue>` in document order, so `hive.map.get(properties, "name")` reads one, and a key written twice keeps its place and its last value.

### Performance

* **`x = f(x)` hands `x` over without copying it** wherever nothing but `f`'s result can keep it — no mutex parameter, no thread handed any storage, no function value in the result — nested calls included. A service's `world = ticked(world, dt)` copied its whole world every message.
* A `proc` with no mutex parameter is lent storage the way a `func` is, and a send counts as starting no thread: its message is copied on the way out.

### Fixes

* **A vector handed to a mutex parameter loses what was proved about its length**, where `shrink(v)` inside `if v bounds 0` left `v[0]` compiling and failing at run time.
* **A library type the library does not have is refused**, where `hive.net.Nonesuch` compiled and the Go toolchain reported it undefined.
* **`sort` with nothing to order by is refused.** A vector of maps, addresses or function values — or of a type holding one — compiled and panicked when it ran; it now asks for the `func` that says which of two comes first.
* A `mut` value handed to a function value's ordinary parameter is copied, as a direct call copies it.

### Breaking

| was | is |
| --- | --- |
| `hive.json.flatten`, `hive.json.get`, `hive.json.table` | `hive.json.JsonValue.decode(text, hive.json.codec())`, then a pattern |
| `encode` of a `Table`, or of a type with a `Table` field, re-nesting `[path, value]` rows | a compile error, `Str[dyn][dyn]` included |
| a `Table` field decoding as a flattened document | a compile error |
| `proc h(s: S, m: M, from: hive.syslink.Envelope): S` | `proc h(s: mut S, m: M): M` |
| `hive.syslink.answer(from, v)` | `return v` |
| `hive.syslink.self(from)` | a third parameter `me: hive.syslink.Address`, started with `spawnAddressed` or `windowAddressed` |
| `hive.syslink.monitor(from, target, notice)` | `hive.syslink.monitor(watcher, target, notice)`, `watcher` an address on this node |
| an answer given after the turn ended | removed: a turn answers when it returns |
| a request left unanswered failing as `NoReply` | removed: every request is answered |

## v0.2.8

### Standard library

* **`ui.onSize(f)`** — a scene reports how wide and how tall its box landed, as two `Int`s. It says so when it starts listening and whenever the box changes, which is the one number a view cannot work out for itself.

### Performance

* **A window sends what changed in the document, not the document**, which took formula-hive's 96-element HUD from 20.5KB a fold to 2.6KB and from every element parsed to 24.
* **Drawing one costs a fraction of what it did**, byte for byte the same: one render of formula-hive's HUD and standings went from 3,819 allocations, 1.67MB and 513us to 1,407, 104KB and 133us.
* **A `ui.Attr` is 80 bytes rather than 144**, which took building a formula-hive frame of 1,495 shapes from 1.97MB allocated to 1.56MB.
* **A window that folds frames draws once a frame.** A pad, a key or a message from the network is still folded the moment it arrives, but `view` runs only for a frame or for something clicked. A moving gamepad was a whole `view` and `publish` for every stick that moved: formula-hive went from 120 draws a second to 57 with one in hand, and from 160 collections a second to 80.
* **A scene frame carries the shapes that moved as moves.** A shape that is now in a different slot is sent as `[dst, src, len]` and the page moves the mesh it already built, where a list shifted by one was every later shape sent again and rebuilt. Driving formula-hive went from 35–48KB a frame to 6–16KB.
* **A world is drawn on the frame it arrives in**, where it waited one more refresh.
* **Positioned sounds pan with equal power**, not HRTF: HRTF convolves every voice, and a racing grid is sixty of them.
* **An Android app collects garbage about once a second rather than once a frame**, with `GOGC=off` and `GOMEMLIMIT=256MiB`. `HIVE_FOLDS`, `GOGC` and `GOMEMLIMIT` can be given as intent extras, and `HIVE_INSPECT` lets `chrome://inspect` attach.
* `HIVE_FOLDS=1` prints fold timings once a second, and `HIVE_WINDOW=print` prints a window's address instead of opening a browser.

### Fixes

* **A variant no library enumeration has is refused here**, where `hive.ui.TextSize.Small()` compiled and the Go toolchain reported `undefined: hive.Ui` against a file nobody wrote. A name that is not a type of that module — `hive.ui.Nonesuch.Caption()` — is refused the same way.
* **An Android app asks for `ACCESS_NETWORK_STATE`**, where the manifest named only `INTERNET` and every `ConnectivityManager` call threw for want of it: nothing was written to `$HOME/.hive/resolvers` and every lookup failed. Installing over an earlier app picks it up.

## v0.2.7

### Building

* **`hive export <entrypoint.hive> --target android/arm64`** writes an installable app. The program is the same one `hive build` writes; what the handset needs to start it — a WebView host, a binary manifest, a resource table, an aligned archive and an APK Signature Scheme v2 signature over it — the build writes itself. **No Android SDK and no network**, the way the Windows resource object is written. The application id comes from the entrypoint, so `chat.hive` is `hive.chat`, and the signing key is made on first use at `~/.hive/android.key` so a later build installs over an earlier one.
* `android/arm64` is the only Android target, being the only one Go links without a C cross-compiler; the other three are refused by name. A program that opens no window is refused too — an app with no window has nothing to show and no way to start.

### Standard library

* **A window is usable with a finger.** Where the pointer is coarse, a button, a field and a checkbox stand at least 44px tall and a field's text is 16px — below which a phone zooms the page on focus and never zooms back. A dialog no longer runs wider than the screen it is on. **No layout moves:** a `row` is a row at every width, on every device.
* **`width` on a `row` or a `column` is held to the space there is**, where a `width(460)` box on a 360px screen made the whole page 460 wide and every window on a handset opened zoomed out. A `canvas`, a `scene` and an `image` keep the width they asked for, since one wider than the box showing it is what `scroll(Horizontal)` is for.

### Fixes

* **An import of a library module this compiler does not carry is refused at the import**, where it loaded nothing and said nothing: the standard library names no file, so `import hive.jsno` compiled and the error arrived later against every use of the alias instead of against the line that got it wrong. An import naming something *inside* a module is answered as that rather than as a mistake about names — no alias makes `import hive.ui.View` right.
* **`hive.syslink.listen` answers with the port it bound**, where a `0` asking the kernel to choose was handed straight back and `node()` went on telling peers to dial `:0`. The host is untouched — which address a machine advertises stays the program's to answer, with `hive.net.localAddress`.
* **A declaration of your own is what a bare call answers with**, where inference handed back the shadowed builtin's result type and every typed position was held to that instead.
* A declared `append`, `prepend`, `drop` or `sort` called as a statement is an ordinary call, where it lowered to the builtin's own statement and the Go toolchain refused what came out.
* `hive.append(v, x)` stands as a statement of its own while a binding of your own shadows `append`, where the long name was turned down for the short one's reason.
* `async` fires off a declaration named after a builtin, where it was turned down as the builtin.
* A generic reached only from a `test` is specialised for it, where no copy was made and the call was reported as a name nothing declared.

### Documentation

* **`hive analyze` is in the pages `hive agents` writes**, which until now documented every command but that one.

## v0.2.6

### Building

* **Every executable carries `assets/icon.png`** as a Windows resource, where before only a windowed program did.

### Standard library

* **`ui.InputKind.Range()`** — a slider running 0–100, whose value and `onInput` text are that number, and which keeps only the keys that move it while it has focus, so a scene still hears `Escape`.

### Fixes

* **A `Str` inside an echoed value is quoted**, where `[1 2]` was the line for `[1, 2]`, `["1", "2"]` and `["1 2"]` alike. Elements and fields are separated by `, ` too, and a `Str` echoed on its own is still the line itself rather than a quoted one.
* **A key released while a field has focus is let go**, where a scene ignored keyup as well as keydown while typing and a key held as focus moved into a field stayed held after it came up.
* **An inset no longer shrinks the picture behind it**, where under `ui.grain` it set the renderer's viewport rather than the render target's and left the canvas at the buffer's size, drawing the whole blown-up world into its bottom-left corner.

## v0.2.5

### Language

* **`toTable(cells, wide)`** — a flat `Str[]` cut into a `Table` of rows that
  wide, the last row holding what was left. A width written as a literal below
  one is a compile error; a computed one that turns out below one hands back an
  empty `Table`.
* **`URL as <name>;`** — a field annotation naming the query parameter the field is read from and written as.
* **`Flag as <name>;`** — a field annotation naming the command-line flag, without its dashes, the field is read from and written as.
* **Codecs are ordinary values** — held in a variable, passed, stored or returned, since a `hive.codec.Codec<E>`'s type says its format.

### Standard library

* **`hive.net.urlEncode(text)`** percent-encodes every byte but RFC 3986's unreserved characters.
* **`hive.net.queryParamsCodec()`** reads and writes a flat type as a query string, without the leading `?`.
* **`hive.term.codec()`** reads a line of `--name value` flags, quoted words kept together, into a flat type and writes them back.
* **`hive.codec.Codec<E>`** names the error its decoding fails with, and each module with a codec owns its own: `hive.json.JsonError`, `hive.crypto.JwtError`, `hive.net.QueryParamsError` and `hive.term.FlagError`.

* **`hive.time.dateFrom(year, month, day)`** and
  **`dateTimeFrom(year, month, day, hour, minute, second)`** — a stamp for a date
  you name, the same kind of `Int` `now()` answers. Both build in local time, and
  a field out of range carries into the next: `dateFrom(2026, 3, 0)` is
  February's last day.
* **`hive.time`** reads the current instant field by field: `year`, `month`,
  `day`, `weekday` (1 Monday – 7 Sunday), `lastDayOfMonth`, `hour`, `minute`,
  `second` and `millisecond`. `millisecond` is a sub-second field, not a
  millisecond clock — a reading is still seconds.

### Fixes

* **A standard library call is held to how many arguments it takes**, the way a
  declared `func` is. The table behind `hive.<module>.<name>` recorded a type for
  the positions a module had something to say about and stopped, so a miscount —
  `hive.math.pi(1.0)`, `hive.file.read("a", "b")`, `hive.map.set(m, "a")` —
  reached the Go toolchain and was reported there, against a file nobody wrote.
  It is a whole signature now, so its length is the arity.
* Argument **types** are held more closely for the same reason: every
  `hive.math` call claimed three `Float`s, `hive.map` and `hive.syslink` claimed
  nothing, and each now says what it takes.
* One of the library's own types — `hive.net.HttpResponse(200, body: ..., ...)` —
  is checked against its fields, so a named argument may come in any order.

### Breaking

| was | is |
| --- | --- |
| `hive.codec.Codec` | `hive.codec.Codec<E>` |
| `hive.codec.DecodingError` | `hive.json.JsonError`, `hive.crypto.JwtError` or `hive.net.QueryParamsError` |

## v0.2.4

### Language

* A backtick string interpolates `{expression}` the way a `"..."` string does, and `\{` is its literal `{`.

## v0.2.4-pre1

### Language

* **A `func` may call a `proc`.** It still cannot declare a mutex parameter,
  which is what keeps it from writing to storage its caller can see.
* A backtick string reads `\{` as a literal `{`, ahead of backtick strings gaining interpolation.

### Standard library

* **`hive.ui.scene`** — `grain(px)` draws the world into a buffer that many pixels
  on its short edge and blows it up unfiltered; `bits(n)` keeps `n` bits of colour
  a channel, dithered rather than rounded. Together: a handheld's picture.
* **`hive.ui.scene`** — a `sprite(attrs, image, wide, tall)` shape: a picture from
  `assets/`, standing on its place, always facing the viewer, tinted by `paint`.
* **`hive.ui.scene`** — a `Talk` voice: struck like `Impact` and `Chime`, unpanned
  like `Music`. For anything said *about* a scene rather than in it, which pinned
  to a place is a voice the listener walks away from.
* A program shipping `assets/font.woff2` has its window set in that typeface.

### Fixes

* **`hive.ui.scene`** — a scene that shrinks no longer strands its sound slots.
  They sit past the end of the solids, so the frame's trim loop never reached
  them and a stale voice fought the live one for its name: silence, wherever a
  program renamed a `track` mid-run.

* A callable that asks for a mutex is refused as a value — `f := grow`,
  `grow(_, "x")` — where it used to reach the Go toolchain and be refused there.
* The loop-invariant finding asks whether the callee really answers off its
  arguments, rather than whether it is a `func`. One that prints, reads the
  clock or reaches any of those through another call is no longer advised as
  the same answer every turn.
* A stdlib module used only inside a `test` is now carried into the test build.
* A name an `is` binds now reaches the rest of its condition outside an `if` too.

## v0.2.3

### Language

* **A call on a thread of its own is handed a copy of every argument**, made on
  the caller's side before the thread starts.
* **Two `mut` names share their storage, not their names.** Writing through
  either still reaches both, but rebinding one no longer rebinds the other.

### Standard library

* **`hive.crypto.jwtCodec(secret)`** — a token is a codec: `encode` signs the
  claims, `T.decode` checks the signature and the times before reading them.

### Fixes


### Breaking

| was | is |
| --- | --- |
| `hive.crypto.jwtSign(claims, secret)` | `encode(claims, hive.crypto.jwtCodec(secret))` |
| `hive.crypto.jwtVerify(token, secret)` then `T.decode` | `T.decode(token, hive.crypto.jwtCodec(secret))` |
| a bad token as a `CryptoError` | a `hive.codec.DecodingError` |
| `b = [...]` rebinding `a` too, after `mut b = a` | it rebinds `b` alone |
| `async f(v)` writing through the caller's `v` | it writes through a copy |

## v0.2.2

### Language

* **Pipes.** `x | f(a)` is sugar for `f(x, a)`: `nums | filter(isEven) | join(" ")`.
* **`encode(value, codec)` and `T.decode(text, codec)`** replace the JSON-specific
  pair. Neither names a format — the codec does, and it must be named at the call.
* A variant standing as a value is refused: `Shape.Point()` builds one,
  `Shape.Circle(_)` is a function value.

### Standard library

* **`hive.file.writeSecret(path, contents)`** — `write` leaving the file readable
  by its author alone: `0600` on Linux and macOS, a protected access list on
  Windows. Settled before any of the secret is in the file.
* **`hive.codec`** — new. `Codec` and `DecodingError`, so a second format is a
  second module rather than a change to the language.
* **`hive.json`** — gains `codec()`.
* **`hive.ui.scene`** — a `roof` shape and a `Panes` surface. `turn` is now yaw,
  pitch and roll about the shape's own axes.

### Windowed programs

* A `hive.ui.window` is an application-mode browser window on a profile of its own
  — no address bar, no tabs, its own process. Closing it ends the program.
* Its icon is `assets/icon.png` beside the entrypoint, embedded by the build.
* On Windows a built windowed program links without a console and carries its icon
  as a PE resource.

### Breaking

| was | is |
| --- | --- |
| `hive.json.encode(v)` | `encode(v, hive.json.codec())` |
| `T.fromJson(text)` | `T.decode(text, hive.json.codec())` |
| `hive.json.JsonError` | `hive.codec.DecodingError` |
| `fromJson` reserved as a field name | `decode` is instead |
| `Shape.Point` as a value | `Shape.Point()` |
| `turn` as world X, Y, Z | yaw, pitch, roll |
