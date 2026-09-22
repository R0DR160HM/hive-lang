# Changelog

## v0.2.8

### Fixes

* **An Android app asks for `ACCESS_NETWORK_STATE`**, where the manifest named only `INTERNET` and every `ConnectivityManager` call threw for want of it: no DNS servers were written to `$HOME/.hive/resolvers` and every lookup failed. Installing over an earlier app picks it up.

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
