# Changelog

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
