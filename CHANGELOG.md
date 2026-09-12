# Changelog

## v0.2.2

### Language

* **Pipes.** `x | f(a)` is sugar for `f(x, a)`: `nums | filter(isEven) | join(" ")`.
* **`encode(value, codec)` and `T.decode(text, codec)`** replace the JSON-specific
  pair. Neither names a format — the codec does, and it must be named at the call.
* A variant standing as a value is refused: `Shape.Point()` builds one,
  `Shape.Circle(_)` is a function value.

### Standard library

* **`hive.term.writeSecret(path, contents)`** — `write` leaving the file readable
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
