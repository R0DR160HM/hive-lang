//// The builtins that answer to a bare name, and how a program reaches one whose
//// name it has taken for itself.
////
//// `len`, `map`, `append` and the rest are in scope with no import. A program's
//// own declaration of one of those names **wins**: a `func map` you wrote is the
//// `map` your calls mean. A name you declared quietly reading as somebody else's
//// function is the kind of surprise a compiler should not spring on you, and it
//// would make adding a builtin a breaking change for every program that had
//// already used the word.
////
//// `hive.map(...)` always reaches the builtin. So taking the short name for
//// yourself costs nothing but five characters wherever you want the other one —
//// and it is what compiler-generated code uses (`v bounds i` desugars to
//// `hive.len(v)`), which is why the desugaring cannot be captured by a
//// declaration either.
////
//// Which of the two a bare call means is settled during import flattening (see
//// `hive/modules`), the one place that knows both the declarations able to shadow
//// a builtin — a module's own, since an imported name is only ever reached
//// through its alias — and the locals in scope at the call. A bare call that
//// reaches a builtin is rewritten to the qualified form there. Every pass after
//// that reads `hive.len` as *the* builtin and a bare `len` as the program's own,
//// with nothing left to decide and no way to decide it differently twice.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import hive/ast

/// Every builtin reachable by a bare name, in the order the documentation lists
/// them — which is also the order an error message names them in.
///
/// These are the global builtins only. The `hive.<module>.<name>` standard library
/// (`hive.file.read`, `hive.conv.sti`, ...) is already qualified and was never
/// shadowable, so it is not part of this.
pub fn globals() -> List(String) {
  [
    "len", "bytes", "print", "println", "join", "split", "indexOf", "row",
    "column", "append", "map", "filter", "filterMap", "sort",
  ]
}

/// Whether `name` is one of the builtins reachable by a bare name.
pub fn is_global(name: String) -> Bool {
  list.contains(globals(), name)
}

/// Every standard library module a program can name, which is also every module
/// an `import hive.<name>` may alias.
///
/// This is the *user-facing* list rather than `hive/runtime`'s: that one also
/// carries the pieces a module is split into for the build (the two halves of
/// turning terminal echo off, syslink's wire), which no program ever writes
/// down. A name here is one that appears in a program as `hive.<name>.<thing>`.
pub fn stdlib_modules() -> List(String) {
  [
    "net", "file", "json", "crypto", "sql", "conv", "env", "term", "task",
    "syslink", "time", "ui",
  ]
}

/// The standard library module an `import` path names, if it names one.
///
/// `hive.ui` is the whole of the spelling: a stdlib import is a module, never a
/// path into one, so `hive.ui.View` is not something to import — it is reached
/// through whatever the module was aliased as.
pub fn stdlib_import(path: String) -> Option(String) {
  case string.split(path, ".") {
    ["hive", name] ->
      case list.contains(stdlib_modules(), name) {
        True -> Some(name)
        False -> None
      }
    _ -> None
  }
}

/// Whether an import path is aimed at the standard library at all — `hive`
/// alone, or any `hive.` spelling, real module or not.
///
/// A path that starts this way is never looked for on disk, so a misspelt module
/// is reported as a misspelt module rather than as a missing file.
pub fn names_stdlib(path: String) -> Bool {
  path == "hive" || string.starts_with(path, "hive.")
}

/// The spelling that always reaches the builtin: `hive.<name>`.
pub fn qualified(name: String) -> ast.Expr {
  ast.EMember(ast.EIdent("hive"), name)
}

/// The global builtin a call's callee names, if it names one.
///
/// Only the qualified form counts. A bare name that reached a builtin has already
/// been rewritten to it, so one still bare at this point is the program's own
/// declaration — which is exactly what makes this the single answer for every
/// pass that asks.
pub fn called(callee: ast.Expr) -> Option(String) {
  case callee {
    ast.EMember(ast.EIdent("hive"), name) ->
      case is_global(name) {
        True -> Some(name)
        False -> None
      }
    _ -> None
  }
}

/// Whether a callee names one particular builtin — for the passes that mine a
/// single call shape (`append` as a statement, `len` as a bound).
pub fn is_call(callee: ast.Expr, name: String) -> Bool {
  called(callee) == Some(name)
}
