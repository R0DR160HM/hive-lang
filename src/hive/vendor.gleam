//// The one thing a Hive build ever downloads for itself: the three.js library a
//// `hive.ui.scene` is drawn with.
////
//// It follows `hive.sql`'s rule exactly — a program that never draws a scene
//// neither downloads nor links it, and one that does downloads it **once**, on
//// the first build, and never again. What is fetched is written into the build
//// directory and `go:embed`ed into the executable, so the program that comes out
//// is still a single file that runs on a machine with no network and no browser
//// cache to warm.
////
//// Two properties are worth being plain about, because a compiler that fetches
//// code has to answer for both:
////
////   * **The version is pinned and so is the file.** Not a range, not "latest":
////     one version, and the SHA-256 of each file's exact bytes. A file that does
////     not hash to what is written here is not the file this compiler was
////     tested against, so the build **fails** — it is not used and not cached.
////     That holds for a corrupted download, a hijacked one, and a registry that
////     silently republished a version.
////   * **The transport is verified too.** The request goes through TLS with the
////     chain and the hostname checked against the machine's own trust store (see
////     `hive_fetch_ffi.erl`). The digest above would catch a tampered file
////     anyway; there is no reason to hand it a plausible one.

import gleam/io
import gleam/list
import gleam/result
import filepath
import simplifile
import hive/imports

/// The three.js release every scene is drawn with.
pub const three_version = "0.180.0"

/// The files that release is made of, in the order a page loads them: the module
/// a scene imports, and the core it imports in turn. Modern three.js is two
/// files rather than one — `three.module.min.js` is the API surface and
/// `three.core.min.js` the engine behind it — and the first one's `import` is a
/// relative path, so both have to sit in the same directory and be served from
/// it.
///
/// Each entry is the name it keeps everywhere (in the cache, in the build
/// directory, and in the URL the window serves it from) and the SHA-256 of its
/// bytes in this release.
pub fn three_files() -> List(#(String, String)) {
  [
    #(
      "three.module.min.js",
      "e2b5ee6bccd38fd6d8a2428546b83c5f2426d84b152ef82be8055556e3b40eb6",
    ),
    #(
      "three.core.min.js",
      "61ba0df005b05991361d040d8ff670e1aadfd0ce7aeebd1fdb0725957a8957de",
    ),
  ]
}

/// Where a file of the pinned release is fetched from. The registry's own
/// immutable per-version path: a published version's bytes never change, which
/// is what makes the digests above a pin rather than a hope.
fn three_url(file: String) -> String {
  "https://cdn.jsdelivr.net/npm/three@" <> three_version <> "/build/" <> file
}

/// Make sure the pinned three.js is in `dir`, fetching it once if this machine
/// has never built a scene before.
///
/// Called with the generated project's `hive/` directory, which is where
/// `ui_scene.go` embeds the files from. A file already there with the right
/// digest is left alone, so a rebuild does no work at all.
pub fn place_three(dir: String) -> Result(Nil, String) {
  list.try_fold(three_files(), Nil, fn(_, entry) {
    let #(file, digest) = entry
    use bytes <- result.try(three_file(file, digest))
    simplifile.write_bits(to: filepath.join(dir, file), bits: bytes)
    |> result.map_error(fn(e) {
      "could not write " <> file <> ": " <> simplifile.describe_error(e)
    })
  })
  |> result.map(fn(_) { Nil })
}

/// Remove the pinned three.js from `dir` — what a build directory whose program
/// no longer draws a scene needs, for the reason a stale module file is removed:
/// what is in the directory is what was compiled.
pub fn clear_three(dir: String) -> Result(Nil, String) {
  three_files()
  |> list.try_fold(Nil, fn(_, entry) {
    simplifile.delete_all([filepath.join(dir, entry.0)])
    |> result.map_error(fn(e) {
      "could not remove a stale " <> entry.0 <> ": " <> simplifile.describe_error(e)
    })
  })
  |> result.map(fn(_) { Nil })
}

// One file of the release: from the shared cache when it is there and intact,
// and from the registry the first time.
fn three_file(file: String, digest: String) -> Result(BitArray, String) {
  let cached = cache_path(file)
  case read_verified(cached, digest) {
    Ok(bytes) -> Ok(bytes)
    Error(_) -> download(file, digest, cached)
  }
}

// A cached file is trusted only as far as its digest goes: anything else — a
// half-written file from an interrupted build, a version that was overwritten by
// hand — counts as not being there, and is fetched again.
fn read_verified(path: String, digest: String) -> Result(BitArray, Nil) {
  case simplifile.read_bits(path) {
    Error(_) -> Error(Nil)
    Ok(bytes) ->
      case sha256_hex(bytes) == digest {
        True -> Ok(bytes)
        False -> Error(Nil)
      }
  }
}

fn download(
  file: String,
  digest: String,
  cached: String,
) -> Result(BitArray, String) {
  let url = three_url(file)
  // The one line the compiler prints for itself. A silent 700 KB download is
  // worse than a noisy one: the first build of a scene takes as long as the
  // network does, and that is worth saying out loud.
  io.println("hive: fetching three.js " <> three_version <> " (" <> file <> ")")
  use bytes <- result.try(
    fetch(url)
    |> result.map_error(fn(why) { unreachable(url, why) }),
  )
  let got = sha256_hex(bytes)
  use _ <- result.try(case got == digest {
    True -> Ok(Nil)
    False -> Error(mismatch(url, digest, got))
  })
  // Cached only after it has been verified, so a bad download is never written
  // down as a good one. Failing to cache is not failing the build: the bytes are
  // in hand, and the next build fetches them again.
  let _ = write_cached(cached, bytes)
  Ok(bytes)
}

fn write_cached(path: String, bytes: BitArray) -> Result(Nil, String) {
  use _ <- result.try(
    simplifile.create_directory_all(filepath.directory_name(path))
    |> result.map_error(fn(e) { simplifile.describe_error(e) }),
  )
  simplifile.write_bits(to: path, bits: bytes)
  |> result.map_error(fn(e) { simplifile.describe_error(e) })
}

fn unreachable(url: String, why: String) -> String {
  "could not fetch the three.js build a `hive.ui.scene` is drawn with (this "
  <> "needs network access on the first build; after that it is cached in "
  <> filepath.directory_name(cache_path(""))
  <> " and every build is offline):\n\n    "
  <> url
  <> "\n    "
  <> why
}

fn mismatch(url: String, want: String, got: String) -> String {
  "the three.js build downloaded from\n\n    "
  <> url
  <> "\n\nis not the file this compiler pins. Expected SHA-256\n\n    "
  <> want
  <> "\n\nand got\n\n    "
  <> got
  <> "\n\nNothing was cached and nothing was compiled against it. Either the "
  <> "download was corrupted — try again — or those bytes are not the ones "
  <> "three.js "
  <> three_version
  <> " published, which is not something to build a program on."
}

/// Where a fetched file lives between builds: under the same `~/.hive` the
/// remote-import clones use, so every program on the machine shares one copy,
/// keyed by the version it belongs to.
fn cache_path(file: String) -> String {
  filepath.join(
    filepath.join(imports.hive_dir(), "vendor/three@" <> three_version),
    file,
  )
}

@external(erlang, "hive_fetch_ffi", "get")
fn fetch(url: String) -> Result(BitArray, String)

@external(erlang, "hive_fetch_ffi", "sha256_hex")
fn sha256_hex(bytes: BitArray) -> String
