//// What an `import` names, and how the ones that are not next door are fetched.
////
//// There are five kinds of import, and the path says which:
////
////     import hive.ui                              a standard library module
////     import ./lib/text                           a Hive file on this disk
////     import ./util.go                            a Go file on this disk
////     import https://host/owner/repo/src/foo      a Hive file in a git repo
////     import https://host/owner/repo/go/util.go   a Go file in one
////
//// The two extensions are the whole of the distinction and they are opposites:
//// `.hive` is never written (the path names a module, and its file is where that
//// module lives), while `.go` always is (a Go file is not a Hive module, and
//// nothing about `import ./util` should make you wonder which of the two it is).
////
//// A remote path is read as **host plus two segments** — `https://host/owner/repo`
//// is the repository and everything after it is the path inside it. A revision
//// goes on the repository, where the repository ends: `.../owner/repo@a1b2c3/src/foo`.
////
//// Fetching happens once. A repository is cloned into a cache under the user's
//// home directory, keyed by the exact commit it was resolved to, and an import
//// that names no revision has the commit it resolved to written into a lock file
//// beside the entrypoint. So the second build of a program needs no network and
//// gets the same code as the first — and a build on another machine, from the
//// same lock file, gets the same code again.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import filepath
import shellout
import simplifile
import hive/builtins

/// A repository and the revision to read it at. `rev` is what the import asked
/// for — a commit, tag or branch — and `None` when it asked for nothing, which
/// means the default branch's tip (pinned on first use, see `Lock`).
pub type Repo {
  Repo(url: String, rev: Option(String))
}

/// What an import path names.
pub type Import {
  /// `import hive.ui` — a module that is always there, naming no file.
  Stdlib(module: String)
  /// `import ./lib/text` — a Hive module, `.hive` supplied.
  LocalHive(path: String)
  /// `import ./util.go` — a Go file, compiled and called through the FFI.
  LocalGo(path: String)
  /// `import https://host/owner/repo[@rev]/src/foo`
  RemoteHive(repo: Repo, path: String)
  /// `import https://host/owner/repo[@rev]/go/util.go`
  RemoteGo(repo: Repo, path: String)
}

/// What each un-pinned repository resolved to, so it resolves to the same thing
/// next time. `path` is the file this is read from and written back to, or `""`
/// for a program compiled from memory, which has nowhere to keep one.
pub type Lock {
  Lock(path: String, pins: Dict(String, String), added: Bool)
}

// ---------------------------------------------------------------------------
// Reading a path
// ---------------------------------------------------------------------------

/// What `path` names, or why it names nothing.
pub fn classify(path: String) -> Result(Import, String) {
  case builtins.names_stdlib(path), is_url(path) {
    True, _ -> Ok(Stdlib(path))
    False, True -> remote(path)
    False, False ->
      case names_go(path) {
        True -> Ok(LocalGo(path))
        False -> Ok(LocalHive(path))
      }
  }
}

/// Whether a path is aimed at a git repository rather than at this disk.
pub fn is_url(path: String) -> Bool {
  string.starts_with(path, "https://") || string.starts_with(path, "http://")
}

/// Whether a path names a Go file, which is the one extension an import writes.
pub fn names_go(path: String) -> Bool {
  string.ends_with(path, ".go")
}

// `https://host/owner/repo[@rev]/some/path` split at the repository.
fn remote(path: String) -> Result(Import, String) {
  let #(scheme, rest) = case string.split_once(path, "://") {
    Ok(#(s, r)) -> #(s <> "://", r)
    Error(_) -> #("", path)
  }
  case string.split(rest, "/") {
    [host, owner, repo, ..inside] -> {
      use #(repo_name, rev) <- result.try(split_rev(repo, path))
      use _ <- result.try(case host, owner, repo_name {
        "", _, _ | _, "", _ | _, _, "" -> Error(malformed(path))
        _, _, _ -> Ok(Nil)
      })
      let url = scheme <> host <> "/" <> owner <> "/" <> repo_name
      case string.join(inside, "/") {
        "" -> Error(no_file_named(path, url))
        inside ->
          case names_go(inside) {
            True -> Ok(RemoteGo(Repo(url, rev), inside))
            False -> Ok(RemoteHive(Repo(url, rev), inside))
          }
      }
    }
    // Host and one segment, or less: there is no repository here to clone.
    _ -> Error(malformed(path))
  }
}

// `repo@a1b2c3` -> the repository and the revision. A `@` anywhere else in the
// path is the mistake it looks like: a revision belongs to a repository, and
// this is the one place the repository ends.
fn split_rev(
  segment: String,
  whole: String,
) -> Result(#(String, Option(String)), String) {
  case string.split_once(segment, "@") {
    Ok(#(_, "")) ->
      Error(
        "`import "
        <> whole
        <> "` ends the repository with `@` but names no revision after it. "
        <> "Write the commit, tag or branch (`repo@a1b2c3/src/foo`), or leave "
        <> "the `@` off to take the default branch.",
      )
    Ok(#(name, rev)) -> Ok(#(name, Some(rev)))
    Error(_) -> Ok(#(segment, None))
  }
}

fn malformed(path: String) -> String {
  "`import "
  <> path
  <> "` does not name a repository and a file in it. A remote import is a host, "
  <> "an owner and a repository, then the path inside it: "
  <> "`https://github.com/owner/repo/src/foo`. Pin a commit, tag or branch by "
  <> "putting it on the repository — `https://github.com/owner/repo@a1b2c3/src/foo`."
}

fn no_file_named(path: String, url: String) -> String {
  "`import "
  <> path
  <> "` names the repository "
  <> url
  <> " but no file inside it. Add the path the module has in the repository, as "
  <> "in `"
  <> url
  <> "/src/foo`."
}

// ---------------------------------------------------------------------------
// The lock file
// ---------------------------------------------------------------------------

/// The lock file beside `entry`: `main.hive` keeps its pins in `main.hive-lock`.
pub fn lock_path(entry: String) -> String {
  filepath.strip_extension(entry) <> ".hive-lock"
}

/// Read the pins beside `entry`. A missing file is an empty lock rather than an
/// error: nothing has been pinned yet, which is how the first build starts.
pub fn read_lock(entry: String) -> Lock {
  let path = lock_path(entry)
  let pins = case simplifile.read(path) {
    Ok(text) ->
      text
      |> string.replace("\r\n", "\n")
      |> string.split("\n")
      |> list.fold(dict.new(), fn(acc, line) {
        case string.split(string.trim(line), " ") {
          // `<url> <commit>`; anything else — a blank line, a comment — is not
          // a pin and is left where it was.
          [url, commit] if url != "" && commit != "" ->
            dict.insert(acc, url, commit)
          _ -> acc
        }
      })
    Error(_) -> dict.new()
  }
  Lock(path, pins, False)
}

/// A lock for source with no file of its own. Nothing is read and nothing is
/// written, so an un-pinned import resolves fresh every time.
pub fn no_lock() -> Lock {
  Lock("", dict.new(), False)
}

/// Write the lock back, if anything was added to it and there is a file to write.
/// The pins are written in name order, so the file does not churn between builds.
pub fn write_lock(lock: Lock) -> Result(Nil, String) {
  use <- bool.guard(!lock.added || lock.path == "", Ok(Nil))
  let body =
    lock.pins
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(pin) { pin.0 <> " " <> pin.1 })
    |> string.join("\n")
  simplifile.write(
    to: lock.path,
    contents: "# Written by the Hive compiler: the commit each remote import was\n"
      <> "# resolved to. Keep it in version control — it is what makes another\n"
      <> "# machine build the same program. Delete a line to take the latest.\n"
      <> body
      <> "\n",
  )
  |> result.map_error(fn(e) {
    "could not write the lock file "
    <> lock.path
    <> ": "
    <> simplifile.describe_error(e)
  })
}

// ---------------------------------------------------------------------------
// Fetching
// ---------------------------------------------------------------------------

/// The directory holding `repo` at the revision it resolves to, cloning it if
/// this machine does not have it yet. Returns the directory and the lock, which
/// gains a pin when a revision had to be resolved.
///
/// Nothing here touches the network when the clone is already there and the
/// revision is already known — which, after one build, is every import.
pub fn fetch(repo: Repo, lock: Lock) -> Result(#(String, Lock), String) {
  use #(commit, lock) <- result.try(resolve_rev(repo, lock))
  let dir = clone_dir(repo.url, commit)
  case is_dir(dir) {
    True -> Ok(#(dir, lock))
    False -> {
      use _ <- result.try(clone(repo.url, commit, dir))
      Ok(#(dir, lock))
    }
  }
}

// The commit to read the repository at. An import that pinned one says it
// outright; one that did not is answered by the lock, and failing that by asking
// the repository what its default branch points at — which is then pinned, so
// this is the only build that has to ask.
fn resolve_rev(repo: Repo, lock: Lock) -> Result(#(String, Lock), String) {
  case repo.rev {
    // A full commit hash is already the answer. A tag or branch is a name that
    // can move, so it is resolved and pinned like a missing revision.
    Some(rev) ->
      case is_commit_hash(rev) {
        True -> Ok(#(rev, lock))
        False -> pin(repo.url, rev, lock)
      }
    None ->
      case dict.get(lock.pins, repo.url) {
        Ok(commit) -> Ok(#(commit, lock))
        Error(_) -> pin(repo.url, "HEAD", lock)
      }
  }
}

// Asks the repository what `ref` points at, and writes it down. `git ls-remote`
// answers without cloning, so a revision is known before anything is fetched —
// which is what lets the clone go straight into the directory named after it.
fn pin(url: String, ref: String, lock: Lock) -> Result(#(String, Lock), String) {
  use commit <- result.try(ls_remote(url, ref))
  let pins = case ref {
    // Only an import that named no revision is pinned by url: a tag or branch it
    // did name is what the program asked for, and the program is where it is
    // written down.
    "HEAD" -> dict.insert(lock.pins, url, commit)
    _ -> lock.pins
  }
  Ok(#(commit, Lock(..lock, pins: pins, added: ref == "HEAD")))
}

fn ls_remote(url: String, ref: String) -> Result(String, String) {
  case
    shellout.command(
      run: "git",
      with: ["ls-remote", "--quiet", url, ref],
      in: ".",
      opt: [],
    )
  {
    Ok(output) ->
      case first_hash(output) {
        Some(commit) -> Ok(commit)
        None ->
          Error(
            "the repository "
            <> url
            <> " has no `"
            <> ref
            <> "`. Check the spelling, or pin a commit hash — which needs no "
            <> "branch or tag to still exist.",
          )
      }
    Error(#(code, message)) -> Error(git_failed(url, code, message))
  }
}

// `ls-remote` answers with `<hash>\t<ref>` lines. The first hash is the answer:
// a ref resolves to one commit, and `HEAD` is listed before anything it also
// matched.
fn first_hash(output: String) -> Option(String) {
  output
  |> string.replace("\r\n", "\n")
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    case string.split(string.trim(line), "\t") {
      [hash, ..] if hash != "" -> Ok(hash)
      _ -> Error(Nil)
    }
  })
  |> list.first
  |> option.from_result
}

// A shallow clone first, which is the whole repository's history left unfetched
// — everything a build needs is one commit's files. That works outright when the
// commit wanted is the tip; when it is older, the history it needs is fetched
// after the fact.
fn clone(url: String, commit: String, dir: String) -> Result(Nil, String) {
  use _ <- result.try(mkdir(filepath.directory_name(dir)))
  use _ <- result.try(
    git([
      "clone", "--quiet", "--depth", "1", "--no-single-branch", url, dir,
    ])
    |> result.map_error(fn(failure) {
      let #(code, message) = failure
      git_failed(url, code, message)
    }),
  )
  case git(["-C", dir, "checkout", "--quiet", commit]) {
    Ok(_) -> Ok(Nil)
    // The commit is not in what a shallow clone brought, so the rest of the
    // history is fetched and the checkout tried once more.
    Error(_) ->
      case git(["-C", dir, "fetch", "--quiet", "--unshallow"]) {
        Error(#(code, message)) -> {
          let _ = simplifile.delete_all([dir])
          Error(git_failed(url, code, message))
        }
        Ok(_) ->
          case git(["-C", dir, "checkout", "--quiet", commit]) {
            Ok(_) -> Ok(Nil)
            Error(#(_, message)) -> {
              // A half-checked-out clone would be read as a good one next time.
              let _ = simplifile.delete_all([dir])
              Error(
                "the repository "
                <> url
                <> " has no commit "
                <> commit
                <> ":\n\n"
                <> message,
              )
            }
          }
      }
  }
}

fn git(args: List(String)) -> Result(String, #(Int, String)) {
  shellout.command(run: "git", with: args, in: ".", opt: [])
}

fn git_failed(url: String, code: Int, message: String) -> String {
  case code {
    // `shellout` reports a command it could not run this way.
    127 ->
      "a remote import needs `git` on the PATH, and it is not there. Install "
      <> "git, or vendor the module you are importing next to your program."
    _ ->
      "could not reach the repository "
      <> url
      <> " (this needs network access on the first build; after that the clone "
      <> "is cached and the build is offline):\n\n"
      <> message
  }
}

// ---------------------------------------------------------------------------
// The cache
// ---------------------------------------------------------------------------

/// Where a repository's clone lives: under the user's home directory, keyed by
/// the commit, so two programs wanting the same commit share one clone and two
/// wanting different ones do not collide.
pub fn clone_dir(url: String, commit: String) -> String {
  filepath.join(cache_root(), slug(url) <> "@" <> commit)
}

fn cache_root() -> String {
  filepath.join(hive_dir(), "pkg")
}

/// The root of everything the compiler keeps between builds: cloned
/// repositories, and the small Go program that reads a Go file's signatures.
///
/// It is `.hive` in the user's home directory, so it is shared by every program
/// they compile. A machine that says nothing about a home directory gets a
/// directory beside the program instead — which works, and is only worse in that
/// it is not shared.
pub fn hive_dir() -> String {
  case home() {
    "" -> ".hive-packages"
    dir -> filepath.join(normalize(dir), ".hive")
  }
}

// The repository's identity as one path segment. Every character that is not a
// name is an underscore, so `https://github.com/owner/repo` reads back as
// `github.com_owner_repo` — recognisable, and nothing a filesystem objects to.
fn slug(url: String) -> String {
  url
  |> string.replace("https://", "")
  |> string.replace("http://", "")
  |> string.to_graphemes
  |> list.map(fn(c) {
    case is_slug_char(c) {
      True -> c
      False -> "_"
    }
  })
  |> string.concat
}

fn is_slug_char(c: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._",
    c,
  )
}

// Whether a revision is already a commit rather than a name for one: hex, and
// long enough to be one (git's own abbreviations start at four).
fn is_commit_hash(rev: String) -> Bool {
  let chars = string.to_graphemes(rev)
  list.length(chars) >= 7
  && list.length(chars) <= 40
  && list.all(chars, fn(c) { string.contains("0123456789abcdefABCDEF", c) })
}

@external(erlang, "hive_home_ffi", "home")
fn home() -> String

fn is_dir(path: String) -> Bool {
  simplifile.is_directory(path) == Ok(True)
}

fn mkdir(path: String) -> Result(Nil, String) {
  simplifile.create_directory_all(path)
  |> result.map_error(fn(e) {
    "could not create " <> path <> ": " <> simplifile.describe_error(e)
  })
}

fn normalize(path: String) -> String {
  string.replace(path, "\\", "/")
}
