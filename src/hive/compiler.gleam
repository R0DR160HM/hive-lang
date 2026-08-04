//// Ties the pipeline together: source text -> tokens -> AST -> Go source.
////
//// Between parsing and codegen a validation pass walks every body to
//// enforce:
////   * the proc/func split — a `func` may perform I/O (`echo`, `using`,
////     `hive.net`) just like a `proc`, but it may not call a `proc` (only
////     procs call procs) and cannot receive a mutex as a parameter;
////   * mutability — only `mut` variables may be reassigned (`x = ...`,
////     `v[0] = ...`) or grown with `append`;
////   * the `hive.net` builtins — known member names, right arity, and a
////     handler that really has the shape its server calls it with (a
////     `proc(hive.net.HttpRequest): hive.net.HttpResponse` for `serve`, a
////     `proc(hive.net.WsConnection): void` for `wsServe`, ...);
////   * named arguments — the target must be known (a declared callable, a
////     type constructor, or a builtin), every name must exist, no name may
////     repeat, and once named arguments are used the call must line up with
////     the full parameter list.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import hive/ast
import hive/bounds
import hive/builtins
import hive/codegen
import hive/diagnostic
import hive/generics
import hive/modules

/// Compile the program rooted at `entry` — a path to a `.hive` file — into the
/// contents of the generated `main.go`, resolving its `import` graph first.
pub fn compile_file(entry: String) -> Result(String, String) {
  // `load`'s errors already carry the file and line they happened on; the passes
  // `finish` runs work on a flattened module whose nodes carry no positions, so
  // theirs are reported against the entrypoint as a whole.
  use module <- result.try(modules.load(entry))
  finish(module)
  |> result.map_error(diagnostic.whole_file(entry, _))
}

/// Compile Hive source held in memory into the contents of the generated
/// `main.go`. Any `import` it carries resolves relative to the current working
/// directory, since the source itself has no location of its own.
pub fn compile(source: String) -> Result(String, String) {
  use module <- result.try(modules.load_source(source, ".", "the source"))
  finish(module)
  |> result.map_error(diagnostic.whole_file("the source", _))
}

// Everything past import resolution, which works on one flat module and so does
// not care how many files it came from.
fn finish(module: ast.Module) -> Result(String, String) {
  // Generic callables are resolved into concrete ones first, so every pass
  // after this one sees ordinary declarations and checks each instantiation on
  // its own terms.
  use module <- result.try(generics.expand(module))
  use _ <- result.try(check(module))
  use _ <- result.try(codegen.check_types(module))
  use _ <- result.try(bounds.check(module))
  Ok(codegen.generate(module))
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

type Ctx {
  Ctx(
    /// The callable currently being checked (used in error messages).
    name: String,
    /// True while checking a `func` or `query` body. Funcs may perform I/O
    /// (echo, using, hive.net) just like procs, but they may not call a
    /// `proc` — only procs may, since procs are the ones that own and pass
    /// mutable state (mutexes).
    in_func: Bool,
    /// Signatures of every declared `proc`, used to reject func→proc calls and
    /// to validate the handler passed to a `hive.net` server.
    procs: Dict(String, #(List(ast.Field), ast.TypeExpr)),
    /// Parameter names of every declared proc/func/query.
    callables: Dict(String, List(String)),
    types: Dict(String, ast.Decl),
    /// True while checking statements inside a loop body, so `break`/`continue`
    /// outside any loop can be rejected.
    in_loop: Bool,
    /// Full parameter list of every declared proc/func/query, so an argument
    /// passed to a `func`-typed parameter can be checked for purity (a `func`
    /// slot accepts only a func value; a `proc` slot accepts either).
    fn_params: Dict(String, List(ast.Field)),
    /// Names of the declared `query`s. `using ... run` needs one: a query is
    /// what knows the shape of what comes back.
    queries: List(String),
  )
}

fn check(module: ast.Module) -> Result(Nil, String) {
  use _ <- result.try(check_has_main(module))
  use _ <- result.try(check_decl_types(module.decls))
  let procs =
    list.fold(module.decls, dict.new(), fn(acc, d) {
      case d {
        ast.ProcDecl(name, params, ret, _) ->
          dict.insert(acc, name, #(params, ret))
        _ -> acc
      }
    })
  let callables =
    list.fold(module.decls, dict.new(), fn(acc, d) {
      case d {
        ast.ProcDecl(name, params, _, _)
        | ast.FuncDecl(name, params, _, _, _)
        | ast.QueryDecl(name, params, _, _) ->
          dict.insert(acc, name, list.map(params, fn(p) { p.name }))
        ast.TypeDecl(..) -> acc
      }
    })
  let fn_params =
    list.fold(module.decls, dict.new(), fn(acc, d) {
      case d {
        ast.ProcDecl(name, params, _, _)
        | ast.FuncDecl(name, params, _, _, _)
        | ast.QueryDecl(name, params, _, _) -> dict.insert(acc, name, params)
        ast.TypeDecl(..) -> acc
      }
    })
  let types =
    list.fold(module.decls, dict.new(), fn(acc, d) {
      case d {
        ast.TypeDecl(name, _, _) -> dict.insert(acc, name, d)
        _ -> acc
      }
    })
  let queries =
    list.filter_map(module.decls, fn(d) {
      case d {
        ast.QueryDecl(name, _, _, _) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  list.try_fold(module.decls, Nil, fn(_, d) {
    case d {
      ast.ProcDecl(name, _, ret, body) -> {
        use _ <- result.try(check_body(
          Ctx(name, False, procs, callables, types, False, fn_params, queries),
          body,
        ))
        check_returns(types, name, ret, body)
      }
      // A `func` may perform I/O (echo, using, hive.net, ...) just like a
      // `proc`. Its two restrictions — no mutex parameters, no calling procs —
      // are what `in_func` marks.
      ast.FuncDecl(name, _, ret, body, _) -> {
        use _ <- result.try(check_body(
          Ctx(name, True, procs, callables, types, False, fn_params, queries),
          body,
        ))
        check_returns(types, name, ret, body)
      }
      ast.QueryDecl(name, _, _, sql) ->
        // A query is a func whose body is inline SQL; every expression in it —
        // an interpolated value or a `where` predicate's condition — is walked
        // with the same func restrictions.
        list.try_fold(ast.sql_exprs(sql), Nil, fn(_, e) {
          check_expr(
            Ctx(name, True, procs, callables, types, False, fn_params, queries),
            e,
          )
        })
        |> result.map(fn(_) { Nil })
      ast.TypeDecl(..) -> Ok(Nil)
    }
  })
  |> result.map(fn(_) { Nil })
}

// ---------------------------------------------------------------------------
// Where an unsized vector type may appear
// ---------------------------------------------------------------------------
//
// `T[]` says only "a vector of T, of some length". That is exactly what a
// parameter wants — it accepts any vector of the right element type, and the
// callee guards every access into it, having been promised nothing. It is
// exactly what a variable or field must *not* be: each of those names storage,
// and storage has to declare which of the two real kinds it is (`T[3]`, whose
// length is a promise checked everywhere a value can reach it, or `T[dyn]`,
// which promises nothing and guards its indexes) for the bounds pass to have
// anything to reason about.
//
// A *return* is neither. It names no storage of its own — it says what the
// caller gets — and the only thing a caller can do with a length is rely on it,
// so a return has exactly two things to say: a static length is a promise
// (`T[3]`), and everything else is "some length". `T[]` and `T[dyn]` are that
// same second answer, and the bounds pass already treats them as one (both are
// `Dyn`, so every index into the result is guarded). Which of the two the callee
// keeps its own values in is its business, and `T[]` is how a signature says so
// — which is what lets a generic hand back a vector without naming a kind for
// it.

// Every type written in a declaration, checked in the position it appears in.
fn check_decl_types(decls: List(ast.Decl)) -> Result(Nil, String) {
  list.try_fold(decls, Nil, fn(_, d) {
    case d {
      ast.ProcDecl(name, params, ret, _)
      | ast.FuncDecl(name, params, ret, _, _) -> {
        use _ <- result.try(
          list.try_fold(params, Nil, fn(_, p) {
            check_param_type(p.typ, "parameter `" <> p.name <> "` of `" <> name <> "`")
          }),
        )
        check_return_type(ret, "the return type of `" <> name <> "`")
      }
      ast.QueryDecl(name, params, ret, sql) -> {
        use _ <- result.try(
          list.try_fold(params, Nil, fn(_, p) {
            check_param_type(p.typ, "parameter `" <> p.name <> "` of `" <> name <> "`")
          }),
        )
        use _ <- result.try(check_return_type(
          ret,
          "the return type of `" <> name <> "`",
        ))
        check_select_star(name, ret, sql)
      }
      ast.TypeDecl(name, variants, commons) -> {
        let fields =
          list.append(list.flat_map(variants, fn(v) { v.fields }), commons)
        list.try_fold(fields, Nil, fn(_, f) {
          check_sized(f.typ, "field `" <> f.name <> "` of type `" <> name <> "`")
        })
      }
    }
  })
  |> result.map(fn(_) { Nil })
}

// A parameter's own type may be unsized. A function *type* in that position
// carries positions of its own: its parameters are parameter positions too, and
// its return is a return position.
fn check_param_type(t: ast.TypeExpr, where: String) -> Result(Nil, String) {
  case t {
    ast.TName(_, _, _, _) | ast.TVoid -> Ok(Nil)
    ast.TFunc(_, params, ret) -> {
      use _ <- result.try(
        list.try_fold(params, Nil, fn(_, p) { check_param_type(p, where) }),
      )
      check_return_type(ret, "the return type in " <> where)
    }
  }
}

// A return position: `T[]` is rejected here, unlike in a parameter.
//
// `[]` means "a vector of some length", which is exactly what a *caller* needs
// told — a returned `Str[]` and a returned `Str[dyn]` are the same promise to
// them (none, so every index is guarded), and a returned `Str[3]` is a very
// different one. Which of the three it is settles how the caller may use the
// value, so it is not a detail the callee gets to leave open: two spellings for
// one meaning only invite the reader to hunt for a difference that isn't there.
// A parameter is the other way round — there `[]` lets one helper serve callers
// holding a `Str[3]` and a `Str[dyn]` alike, which is a real thing to say.
//
// A function type nested in a return carries positions of its own, so the
// recursion sorts them out rather than waving the whole thing through.
fn check_return_type(t: ast.TypeExpr, where: String) -> Result(Nil, String) {
  case t {
    ast.TVoid -> Ok(Nil)
    ast.TName(_, _, _, dims) ->
      case list.contains(dims, ast.DimEmpty) {
        False -> Ok(Nil)
        True ->
          Error(
            where
            <> " is declared `"
            <> ast.show_type(t)
            <> "`, but `[]` only says \"a vector of some length\", and a return "
            <> "is where the caller is told what it is getting. Declare it "
            <> "`[dyn]` (any length, guarded indexes) — which is what `[]` "
            <> "already means to a caller — or give it a static length like "
            <> "`[3]`, which promises one. `[]` stays available on a parameter, "
            <> "where accepting either kind is the point.",
          )
      }
    ast.TFunc(_, params, ret) -> {
      use _ <- result.try(
        list.try_fold(params, Nil, fn(_, p) { check_param_type(p, where) }),
      )
      check_return_type(ret, "the return type in " <> where)
    }
  }
}

// A position that names storage: reject `T[]` anywhere in it.
fn check_sized(t: ast.TypeExpr, where: String) -> Result(Nil, String) {
  case t {
    ast.TVoid -> Ok(Nil)
    ast.TName(_, _, _, dims) ->
      case list.contains(dims, ast.DimEmpty) {
        False -> Ok(Nil)
        True ->
          Error(
            where
            <> " is declared `"
            <> ast.show_type(t)
            <> "`, but `[]` only says \"a vector of some length\" — which is a "
            <> "promise a parameter or a return can make and storage cannot. "
            <> "Declare it `[dyn]` (any length, guarded indexes) or give it a "
            <> "static length like `[3]`.",
          )
      }
    ast.TFunc(_, params, ret) -> {
      use _ <- result.try(
        list.try_fold(params, Nil, fn(_, p) { check_param_type(p, where) }),
      )
      check_return_type(ret, "the return type in " <> where)
    }
  }
}

// `using <connection> run <query>` wants a declared query: the query is what
// says how many columns come back and what they are called, which is the whole
// reason its result can be typed. SQL assembled at runtime says none of that, so
// it goes through `run raw` and comes back as a Table.
fn check_run_target(ctx: Ctx, kind: ast.UsingKind) -> Result(Nil, String) {
  case kind {
    ast.UsingQuery(ast.ECall(ast.EIdent(name), _)) ->
      case list.contains(ctx.queries, name) {
        True -> Ok(Nil)
        False ->
          Error(
            "`using ... run "
            <> name
            <> "(...)` needs `"
            <> name
            <> "` to be a declared `query`. If you are running SQL you built at "
            <> "runtime, say so with `run raw` — it comes back as a `Table`, "
            <> "since nothing is known about its shape.",
          )
      }
    ast.UsingQuery(_) ->
      Error(
        "`using ... run ...` takes a declared `query`, which is what knows the "
        <> "shape of the rows. To run SQL text directly, use `run raw <text>` "
        <> "and take a `Table` back.",
      )
    _ -> Ok(Nil)
  }
}

// ---------------------------------------------------------------------------
// `SELECT *` and a declared row type
// ---------------------------------------------------------------------------

// A star says neither how many columns come back nor what they are called, so
// there is nothing to match a row type's fields against — and the shape it
// stands for changes the day someone adds a column to the table. It stays legal
// for a `Table`, which promises nothing anyway, and for a `void` statement,
// whose select list (if it has one) is a subquery rather than a result.
fn check_select_star(
  name: String,
  ret: ast.TypeExpr,
  sql: List(ast.SqlPart),
) -> Result(Nil, String) {
  case ret {
    ast.TVoid -> Ok(Nil)
    ast.TName(None, "Table", _, _) -> Ok(Nil)
    _ ->
      case list.find(select_list(sql_text(sql)), is_star) {
        Error(_) -> Ok(Nil)
        Ok(item) ->
          Error(
            "`"
            <> name
            <> "` selects `"
            <> item
            <> "`, which does not say how many columns it returns or what they "
            <> "are called — so there is nothing to match `"
            <> ast.show_type(ret)
            <> "`'s fields against. List the columns, or declare the query as "
            <> "returning a `Table` and take the rows untyped.",
          )
      }
  }
}

// The body's literal SQL, with each interpolation standing in as a placeholder.
// A `where` block only ever follows the select list, so it contributes nothing
// worth reading here.
fn sql_text(parts: List(ast.SqlPart)) -> String {
  parts
  |> list.map(fn(part) {
    case part {
      ast.SqlLit(text) -> text
      ast.SqlParam(_) -> "?"
      ast.SqlWhere(_) -> " "
    }
  })
  |> string.concat
}

// The comma-separated items of the first top-level `SELECT`. Anything inside
// quotes or parentheses is skipped, so a subquery's star and `count(*)` are
// both left alone.
fn select_list(text: String) -> List(String) {
  case after_select(string.to_graphemes(text), 0, False, " ") {
    None -> []
    Some(rest) ->
      rest
      |> take_until_from(0, False, "", " ")
      |> string.to_graphemes
      |> split_columns(0, False, "", [])
  }
}

fn after_select(
  chars: List(String),
  depth: Int,
  quoted: Bool,
  prev: String,
) -> Option(List(String)) {
  case chars {
    [] -> None
    ["'", ..rest] -> after_select(rest, depth, !quoted, "'")
    [c, ..rest] if quoted -> after_select(rest, depth, quoted, c)
    ["(", ..rest] -> after_select(rest, depth + 1, quoted, "(")
    [")", ..rest] -> after_select(rest, depth - 1, quoted, ")")
    [c, ..rest] ->
      case depth == 0 && !is_word_char(prev) && matches_word(chars, "select") {
        True -> Some(list.drop(chars, 6))
        False -> after_select(rest, depth, quoted, c)
      }
  }
}

fn take_until_from(
  chars: List(String),
  depth: Int,
  quoted: Bool,
  buf: String,
  prev: String,
) -> String {
  case chars {
    [] -> buf
    ["'", ..rest] -> take_until_from(rest, depth, !quoted, buf <> "'", "'")
    [c, ..rest] if quoted -> take_until_from(rest, depth, quoted, buf <> c, c)
    ["(", ..rest] -> take_until_from(rest, depth + 1, quoted, buf <> "(", "(")
    [")", ..rest] -> take_until_from(rest, depth - 1, quoted, buf <> ")", ")")
    [c, ..rest] ->
      case depth == 0 && !is_word_char(prev) && matches_word(chars, "from") {
        True -> buf
        False -> take_until_from(rest, depth, quoted, buf <> c, c)
      }
  }
}

fn split_columns(
  chars: List(String),
  depth: Int,
  quoted: Bool,
  buf: String,
  acc: List(String),
) -> List(String) {
  case chars {
    [] -> list.reverse(push_column(buf, acc))
    ["'", ..rest] -> split_columns(rest, depth, !quoted, buf <> "'", acc)
    [c, ..rest] if quoted -> split_columns(rest, depth, quoted, buf <> c, acc)
    ["(", ..rest] -> split_columns(rest, depth + 1, quoted, buf <> "(", acc)
    [")", ..rest] -> split_columns(rest, depth - 1, quoted, buf <> ")", acc)
    [",", ..rest] if depth == 0 ->
      split_columns(rest, depth, quoted, "", push_column(buf, acc))
    [c, ..rest] -> split_columns(rest, depth, quoted, buf <> c, acc)
  }
}

fn push_column(buf: String, acc: List(String)) -> List(String) {
  case string.trim(buf) {
    "" -> acc
    trimmed -> [trimmed, ..acc]
  }
}

// A star expansion: a bare `*`, or a qualified `t.*`. `DISTINCT`/`ALL` may sit
// in front of the first column, and `count(*)` is a call rather than a star.
fn is_star(column: String) -> Bool {
  let bare =
    column
    |> strip_leading_word("distinct")
    |> strip_leading_word("all")
    |> string.trim
  bare == "*" || string.ends_with(bare, ".*")
}

fn strip_leading_word(column: String, word: String) -> String {
  let lower = string.lowercase(string.trim(column))
  case string.starts_with(lower, word <> " ") {
    True -> string.drop_start(string.trim(column), string.length(word))
    False -> column
  }
}

fn matches_word(chars: List(String), word: String) -> Bool {
  let n = string.length(word)
  let head = chars |> list.take(n) |> string.concat |> string.lowercase
  case head == word {
    False -> False
    True ->
      case list.drop(chars, n) {
        [] -> True
        [c, ..] -> !is_word_char(c)
      }
  }
}

fn is_word_char(c: String) -> Bool {
  case c {
    "_" -> True
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> string.lowercase(c) != string.uppercase(c)
  }
}

// A program starts at `proc main(): void`. Only the entrypoint's `main` keeps
// that name through import flattening, so a module meant to be imported has
// none — and building one directly would otherwise fail as a Go linker error
// rather than something an author can act on.
fn check_has_main(module: ast.Module) -> Result(Nil, String) {
  let has_main =
    list.any(module.decls, fn(d) {
      case d {
        ast.ProcDecl("main", [], ast.TVoid, _) -> True
        _ -> False
      }
    })
  case has_main {
    True -> Ok(Nil)
    False ->
      Error(
        "this program has no entrypoint: it needs a `proc main(): void`. (A "
        <> "module written to be imported by another file has none — build the "
        <> "file with `main` in it instead.)",
      )
  }
}

fn check_body(ctx: Ctx, stmts: List(ast.Stmt)) -> Result(Nil, String) {
  check_stmts(ctx, stmts, dict.new())
  |> result.map(fn(_) { Nil })
}

/// Whether a local's declaration allows `append` to grow it.
///
/// `append` grows a vector in place, which only a `[dyn]` one can do — a static
/// length is a promise, and a promise cannot be grown out of. The three cases are
/// kept apart so the error can say which mistake was made.
type Grow {
  /// Declared with an explicit `[dyn]` outer dimension (or a `Table`, which is
  /// `Str[dyn][dyn]`). This is the only growable kind.
  Growable
  /// Bound with `:=`, so the length was read off the value. An inferred length is
  /// a static one: `:=` never produces a dynamic vector, since a dynamic vector
  /// is exactly the thing whose length is *not* part of what the value showed.
  Inferred
  /// Declared with a static length (`Str[3]`), or not a vector at all.
  Fixed
}

/// What a local binding permits: `mut` allows writing to it at all, and `grow`
/// allows `append` specifically.
type Binding {
  Binding(mutable: Bool, grow: Grow)
}

/// The `grow` a written-out type declares. Only the **outer** dimension matters,
/// since that is the vector `append` would grow — `Str[3][dyn]` is three vectors
/// of `Str[dyn]`, so appending to it is growing a static three.
fn declared_grow(t: ast.TypeExpr) -> Grow {
  case t {
    // `Table` is an alias for `Str[dyn][dyn]`, kept unexpanded in the AST.
    ast.TName(None, "Table", _, []) -> Growable
    ast.TName(_, _, _, [ast.DimDyn, ..]) -> Growable
    // `T[]` promises nothing about the length, but it is a signature-only
    // spelling: a local declared with it is rejected before this point.
    _ -> Fixed
  }
}

// Walks a statement list threading what each declared local permits (`mut`, and
// whether `append` may grow it), so assignments and `append`s targeting a local
// that does not allow them can be rejected. Returns the updated set so
// declarations stay visible to the statements that follow them.
fn check_stmts(
  ctx: Ctx,
  stmts: List(ast.Stmt),
  muts: Dict(String, Binding),
) -> Result(Dict(String, Binding), String) {
  case stmts {
    [] -> Ok(muts)
    [s, ..rest] -> {
      use muts2 <- result.try(check_stmt(ctx, s, muts))
      check_stmts(ctx, rest, muts2)
    }
  }
}

fn check_stmt(
  ctx: Ctx,
  s: ast.Stmt,
  muts: Dict(String, Binding),
) -> Result(Dict(String, Binding), String) {
  case s {
    ast.SEcho(e) -> {
      use _ <- result.try(check_expr(ctx, e))
      Ok(muts)
    }
    ast.SVarDecl(name, value, mutable) -> {
      use _ <- result.try(check_expr(ctx, value))
      Ok(dict.insert(muts, name, Binding(mutable, Inferred)))
    }
    ast.STypedDecl(typ, name, value, mutable) -> {
      use _ <- result.try(check_sized(typ, "`" <> name <> "`"))
      use _ <- result.try(check_expr(ctx, value))
      Ok(dict.insert(muts, name, Binding(mutable, declared_grow(typ))))
    }
    ast.SAssign(target, value) -> {
      use _ <- result.try(check_assign_target(target, muts))
      use _ <- result.try(check_expr(ctx, target))
      use _ <- result.try(check_expr(ctx, value))
      Ok(muts)
    }
    ast.SReturn(None) -> Ok(muts)
    ast.SReturn(Some(e)) -> {
      use _ <- result.try(check_expr(ctx, e))
      Ok(muts)
    }
    ast.SAssert(e) -> {
      use _ <- result.try(check_expr(ctx, e))
      Ok(muts)
    }
    ast.SPanic(e) -> {
      use _ <- result.try(check_expr(ctx, e))
      Ok(muts)
    }
    ast.SExpr(e) -> {
      use _ <- result.try(check_append(e, muts))
      use _ <- result.try(check_expr(ctx, e))
      Ok(muts)
    }
    ast.SBreak ->
      case ctx.in_loop {
        True -> Ok(muts)
        False -> Error("`break` can only be used inside a loop")
      }
    ast.SContinue ->
      case ctx.in_loop {
        True -> Ok(muts)
        False -> Error("`continue` can only be used inside a loop")
      }
    ast.SIf(branches, else_body) -> {
      use _ <- result.try(
        list.try_fold(branches, Nil, fn(_, b) {
          use _ <- result.try(check_expr(ctx, b.cond))
          use _ <- result.try(check_stmts(ctx, b.body, muts))
          Ok(Nil)
        })
        |> result.map(fn(_) { Nil }),
      )
      use _ <- result.try(case else_body {
        Some(body) -> {
          use _ <- result.try(check_stmts(ctx, body, muts))
          Ok(Nil)
        }
        None -> Ok(Nil)
      })
      Ok(muts)
    }
    ast.SFor(init, cond, post, body) -> {
      // The init clause introduces the loop variable, whose mutability is
      // visible to the condition, the post clause and the body — all scoped to
      // the loop, so the outer `muts` is returned unchanged afterwards.
      use inner <- result.try(case init {
        Some(s) -> check_stmt(ctx, s, muts)
        None -> Ok(muts)
      })
      use _ <- result.try(case cond {
        Some(e) -> check_expr(ctx, e)
        None -> Ok(Nil)
      })
      use _ <- result.try(case post {
        Some(s) -> check_stmt(ctx, s, inner) |> result.map(fn(_) { Nil })
        None -> Ok(Nil)
      })
      use _ <- result.try(
        check_stmts(Ctx(..ctx, in_loop: True), body, inner)
        |> result.map(fn(_) { Nil }),
      )
      Ok(muts)
    }
    ast.SForEach(name, elem_type, iterable, body) -> {
      use _ <- result.try(case elem_type {
        Some(t) -> check_sized(t, "the element type of `" <> name <> "`")
        None -> Ok(Nil)
      })
      use _ <- result.try(check_expr(ctx, iterable))
      // The iteration variable is a fresh, immutable binding in the body.
      let inner = dict.insert(muts, name, Binding(False, Fixed))
      use _ <- result.try(
        check_stmts(Ctx(..ctx, in_loop: True), body, inner)
        |> result.map(fn(_) { Nil }),
      )
      Ok(muts)
    }
  }
}

// ---------------------------------------------------------------------------
// Exhaustiveness: every non-void proc/func must return on all paths
// ---------------------------------------------------------------------------

// Codegen still appends a `panic` fallback so Go accepts the output, but that
// turns a reachable fall-through into a runtime panic. This catches those at
// compile time. A branch that ends in `assert` counts as terminating — it is
// Hive's panic — so an author can mark an impossible tail with `assert false`.
fn check_returns(
  types: Dict(String, ast.Decl),
  name: String,
  ret: ast.TypeExpr,
  body: List(ast.Stmt),
) -> Result(Nil, String) {
  case ret {
    ast.TVoid -> Ok(Nil)
    _ ->
      case terminates(types, body) {
        True -> Ok(Nil)
        False ->
          Error(
            "`"
            <> name
            <> "` can finish without returning a value: every path must end in "
            <> "`return` (or `assert`, which panics). If a tail is unreachable, "
            <> "make it explicit with a final `return` or `assert false`.",
          )
      }
  }
}

// Whether a statement list always transfers control away from its end (so the
// enclosing function never falls off it without returning).
fn terminates(types: Dict(String, ast.Decl), stmts: List(ast.Stmt)) -> Bool {
  case list.last(stmts) {
    Ok(s) -> stmt_terminates(types, s)
    Error(_) -> False
  }
}

fn stmt_terminates(types: Dict(String, ast.Decl), s: ast.Stmt) -> Bool {
  case s {
    ast.SReturn(_) -> True
    // `assert` and `panic` both stop the path here, so a branch ending in
    // either is a terminating path.
    ast.SAssert(_) | ast.SPanic(_) -> True
    ast.SIf(branches, else_body) -> {
      let all_return =
        list.all(branches, fn(b) { terminates(types, b.body) })
      case else_body {
        Some(body) -> all_return && terminates(types, body)
        // No `else`: the branches must themselves cover the whole subject
        // (Result's Ok+Error, or every variant of a user ADT).
        None -> all_return && exhaustive(types, branches)
      }
    }
    _ -> False
  }
}

// Whether an else-less `if`/`else if` chain covers its subject exhaustively:
// every branch guards on `subject is Constructor`, all on the same subject, and
// the constructors span the whole type.
fn exhaustive(
  types: Dict(String, ast.Decl),
  branches: List(ast.Branch),
) -> Bool {
  case list.first(branches) {
    Ok(ast.Branch(ast.EIs(subject, _), _)) ->
      case extract_paths(subject, branches) {
        Ok(paths) -> covers(types, paths)
        Error(_) -> False
      }
    _ -> False
  }
}

// Each branch must be `subject is Type.Variant`, all sharing `subject`; returns
// the list of `[Type, Variant]` paths, or Error if any branch doesn't fit.
fn extract_paths(
  subject: ast.Expr,
  branches: List(ast.Branch),
) -> Result(List(List(String)), Nil) {
  list.try_map(branches, fn(b) {
    case b.cond {
      ast.EIs(s, ast.PConstructor(path, _)) ->
        case s == subject {
          True -> Ok(path)
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

fn covers(types: Dict(String, ast.Decl), paths: List(List(String))) -> Bool {
  case paths {
    // Result is exhaustive exactly when both Ok and Error are matched.
    [["Result", _], ..] ->
      list.contains(paths, ["Result", "Ok"])
      && list.contains(paths, ["Result", "Error"])
    // A user ADT: all paths must name the same type, and every one of its
    // variants must be matched.
    [[tname, _], ..] ->
      case dict.get(types, tname) {
        Ok(ast.TypeDecl(_, variants, _)) -> {
          let want = list.map(variants, fn(v) { v.name })
          let got =
            list.filter_map(paths, fn(p) {
              case p {
                [t, v] if t == tname -> Ok(v)
                _ -> Error(Nil)
              }
            })
          want != [] && list.all(want, fn(v) { list.contains(got, v) })
        }
        _ -> False
      }
    _ -> False
  }
}

// The root variable an lvalue ultimately assigns into: `v`, `v[i]`, `v.field`
// and `v[a:b]` all root at `v`.
fn assign_root(target: ast.Expr) -> Result(String, String) {
  case target {
    ast.EIdent(n) -> Ok(n)
    ast.EIndex(t, _) -> assign_root(t)
    ast.EMember(t, _) -> assign_root(t)
    ast.ESlice(t, _, _) -> assign_root(t)
    _ -> Error("the left-hand side of `=` is not something you can assign to")
  }
}

fn check_assign_target(
  target: ast.Expr,
  muts: Dict(String, Binding),
) -> Result(Nil, String) {
  use root <- result.try(assign_root(target))
  case dict.get(muts, root) {
    Ok(Binding(True, _)) -> Ok(Nil)
    _ ->
      Error(
        "cannot assign to `"
        <> root
        <> "`: it is immutable — declare it with `mut` to allow reassignment",
      )
  }
}

// `append(v, ...)` grows a vector in place, so `v` must be a **mutable dynamic**
// vector — the two halves of what the spec says: append "only compiles when used
// on mutable dynamic vectors".
//
// Dynamic is the half that has to be *declared*. A `mut v := [...]` binding reads
// its length off the value, and a length read off a value is a static one, so it
// is not something `append` can grow; `mut Str[dyn] v = [...]` is. Requiring the
// explicit type is what keeps "does this vector have a known length?" answerable
// by reading its declaration, which is the same property every rule in the bounds
// pass rests on.
//
// Only the builtin is meant: a program's own `append` is an ordinary callable and
// its first argument is nothing special.
fn check_append(e: ast.Expr, muts: Dict(String, Binding)) -> Result(Nil, String) {
  case e {
    ast.ECall(ast.EMember(ast.EIdent("hive"), "append"), args) ->
      case args {
        [ast.Arg(_, target), ..] -> {
          use root <- result.try(
            assign_root(target)
            |> result.replace_error(
              "`append`'s first argument must be a mutable vector variable",
            ),
          )
          case dict.get(muts, root) {
            Ok(Binding(True, Growable)) -> Ok(Nil)
            // A member or index path (`append(box.items, x)`) is rooted at a
            // variable whose own type says nothing about the field being grown,
            // so there is nothing to check beyond its mutability.
            Ok(Binding(True, _)) ->
              case target {
                ast.EIdent(_) -> Error(not_growable(root, muts))
                _ -> Ok(Nil)
              }
            Ok(Binding(False, _)) ->
              Error(
                "`append` requires a mutable vector: `"
                <> root
                <> "` is immutable — declare it with `mut`",
              )
            // Not a local at all: a parameter, which is never mutable.
            Error(_) ->
              Error(
                "`append` requires a mutable vector: `"
                <> root
                <> "` is immutable — declare it with `mut`",
              )
          }
        }
        [] -> Error("`append` takes a mutable vector and at least one value")
      }
    _ -> Ok(Nil)
  }
}

fn not_growable(root: String, muts: Dict(String, Binding)) -> String {
  case dict.get(muts, root) {
    Ok(Binding(_, Inferred)) ->
      "`append` requires a dynamic vector, and `"
      <> root
      <> "` is not one: it was bound with `:=`, which reads the length off the "
      <> "value — an inferred length is a static one. Declare it explicitly to "
      <> "make it dynamic: `mut "
      <> root
      <> "` needs a type such as `mut Str[dyn] "
      <> root
      <> " = ...`."
    _ ->
      "`append` requires a dynamic vector: `"
      <> root
      <> "` is declared with a static length, which is a promise it cannot grow "
      <> "out of. Declare it `[dyn]` to allow appending."
  }
}

fn check_expr(ctx: Ctx, e: ast.Expr) -> Result(Nil, String) {
  case e {
    // `using` (reading a file) is I/O, which funcs may now do too, so there is
    // nothing to reject here — just walk its sub-expressions.
    ast.EUsing(source, kind) -> {
      use _ <- result.try(check_run_target(ctx, kind))
      check_exprs(ctx, [source, ..ast.using_exprs(kind)])
    }
    // `hive.json.parse(text) with Type` — the only place `with` is allowed.
    ast.EWith(value, typ) ->
      case value {
        ast.ECall(
          ast.EMember(ast.EMember(ast.EIdent("hive"), "json"), "parse"),
          args,
        ) -> {
          use _ <- result.try(check_named(
            "`hive.json.parse`",
            args,
            Some(["text"]),
          ))
          use _ <- result.try(case codegen.assign_args(args, ["text"]) {
            #([_], []) -> Ok(Nil)
            _ -> Error("`hive.json.parse` takes exactly one Str argument")
          })
          use _ <- result.try(check_with_type(ctx, typ))
          check_args(ctx, args)
        }
        ast.ECall(
          ast.EMember(ast.EMember(ast.EIdent("hive"), "crypto"), "jwtVerify"),
          args,
        ) -> {
          use _ <- result.try(check_named(
            "`hive.crypto.jwtVerify`",
            args,
            Some(["token", "secret"]),
          ))
          use _ <- result.try(case codegen.assign_args(args, ["token", "secret"]) {
            #([_, _], []) -> Ok(Nil)
            _ ->
              Error(
                "`hive.crypto.jwtVerify` takes exactly two Str arguments: a token and a secret",
              )
          })
          use _ <- result.try(check_with_type(ctx, typ))
          check_args(ctx, args)
        }
        ast.ECall(
          ast.EMember(ast.EMember(ast.EIdent("hive"), "crypto"), "jwtDecode"),
          args,
        ) -> {
          use _ <- result.try(check_named(
            "`hive.crypto.jwtDecode`",
            args,
            Some(["token"]),
          ))
          use _ <- result.try(case codegen.assign_args(args, ["token"]) {
            #([_], []) -> Ok(Nil)
            _ ->
              Error("`hive.crypto.jwtDecode` takes exactly one Str argument: a token")
          })
          use _ <- result.try(check_with_type(ctx, typ))
          check_args(ctx, args)
        }
        _ ->
          Error(
            "`with <Type>` can only be applied to `hive.json.parse(...)`, "
            <> "`hive.crypto.jwtVerify(...)` or `hive.crypto.jwtDecode(...)` "
            <> "calls. (`with timeout <ms>` is a different clause and belongs "
            <> "on an `await`.)",
          )
      }
    // `hive.sql.DatabaseDriver.SQLite()` etc. — driver constructors.
    ast.ECall(
      ast.EMember(
        ast.EMember(ast.EMember(ast.EIdent("hive"), "sql"), "DatabaseDriver"),
        variant,
      ),
      args,
    ) -> {
      use _ <- result.try(check_sql_driver(variant, args))
      check_args(ctx, args)
    }
    ast.ECall(ast.EMember(ast.EMember(ast.EIdent("hive"), ns), fname), args) ->
      case codegen.builtin_fields(fname) {
        // A builtin type constructor: `hive.net.HttpRequest(...)` etc.
        Some(fields) -> {
          use _ <- result.try(check_named(
            "`hive." <> ns <> "." <> fname <> "`",
            args,
            Some(list.map(fields, fn(f) { f.0 })),
          ))
          check_args(ctx, args)
        }
        // Otherwise a stdlib function in that namespace.
        None ->
          case ns {
            "net" -> {
              use _ <- result.try(check_net_call(ctx, fname, args))
              check_args(ctx, args)
            }
            "file" -> {
              use _ <- result.try(check_file_call(fname, args))
              check_args(ctx, args)
            }
            "json" -> {
              use _ <- result.try(check_json_call(fname, args))
              check_args(ctx, args)
            }
            "crypto" -> {
              use _ <- result.try(check_crypto_call(fname, args))
              check_args(ctx, args)
            }
            "sql" -> {
              use _ <- result.try(check_sql_call(fname, args))
              check_args(ctx, args)
            }
            "conv" -> {
              use _ <- result.try(check_conv_call(fname, args))
              check_args(ctx, args)
            }
            "env" -> {
              use _ <- result.try(check_env_call(fname, args))
              check_args(ctx, args)
            }
            "term" -> {
              use _ <- result.try(check_term_call(fname, args))
              check_args(ctx, args)
            }
            "task" -> {
              use _ <- result.try(check_task_call(fname, args))
              check_args(ctx, args)
            }
            "syslink" -> {
              use _ <- result.try(check_syslink_call(ctx, fname, args))
              check_args(ctx, args)
            }
            "time" -> {
              use _ <- result.try(check_time_call(fname, args))
              check_args(ctx, args)
            }
            _ ->
              Error(
                "unknown builtin namespace `hive."
                <> ns
                <> "` (available: net, file, json, crypto, sql, conv, env, "
                <> "term, task, syslink, time)",
              )
          }
      }
    ast.ECall(ast.EMember(ast.EIdent(tname), member), args) -> {
      let target = "`" <> tname <> "." <> member <> "`"
      use _ <- result.try(case dict.get(ctx.types, tname) {
        // `Type.Variant(...)` — a user constructor.
        Ok(decl) ->
          check_named(target, args, Some(variant_field_names(decl, member)))
        Error(_) ->
          case tname {
            "hive" ->
              case builtins.is_global(member), codegen.builtin_fields(member) {
                // `hive.len(v)`, `hive.map(v, f)` — a global builtin named the
                // long way, which is how a program that declared a `len` or a
                // `map` of its own still reaches this one. It is also what a bare
                // call became when nothing shadowed it, so most of these were
                // never written by hand.
                True, _ -> check_named(target, args, None)
                // Builtin types are namespaced now: `hive.net.HttpRequest(...)`,
                // not the bare `hive.HttpRequest(...)`.
                False, Some(_) ->
                  Error(
                    "`hive."
                    <> member
                    <> "` is not a builtin; use `"
                    <> codegen.builtin_qualifier(member)
                    <> "."
                    <> member
                    <> "` instead",
                  )
                False, None ->
                  Error(
                    "`hive."
                    <> member
                    <> "` is not a builtin. The ones reached directly on `hive` "
                    <> "are the globals ("
                    <> string.join(builtins.globals(), ", ")
                    <> "); everything else lives in a module, as in "
                    <> "`hive.file.read` or `hive.conv.sti`.",
                  )
              }
            _ -> check_named(target, args, None)
          }
      })
      check_args(ctx, args)
    }
    ast.ECall(ast.EIdent(name), args) -> {
      // `now()` used to be a bare builtin; it now lives in `hive.time`. Point
      // there — unless the program defines its own `now`, in which case the
      // ordinary rules below apply.
      use _ <- result.try(case
        name == "now"
        && !dict.has_key(ctx.callables, name)
        && !dict.has_key(ctx.types, name)
      {
        True ->
          Error(
            "`now()` has moved to the `hive.time` module — call `hive.time.now()`",
          )
        False -> Ok(Nil)
      })
      // Funcs (and queries) may do I/O, but they may not call procs — only
      // procs call procs. A partial application (`p(_, x)`) merely *wraps* the
      // proc into a value; it does not call it, so it stays allowed in a func.
      use _ <- result.try(case
        ctx.in_func
        && dict.has_key(ctx.procs, name)
        && !has_placeholder(args)
      {
        True ->
          Error(
            "func `"
            <> ctx.name
            <> "` cannot call proc `"
            <> name
            <> "`: funcs may perform I/O but only procs may call procs",
          )
        False -> Ok(Nil)
      })
      let target = "`" <> name <> "`"
      use _ <- result.try(case dict.get(ctx.callables, name) {
        Ok(param_names) -> check_named(target, args, Some(param_names))
        Error(_) ->
          case dict.get(ctx.types, name) {
            // Bare `Type(...)` constructs the first variant (or the struct
            // itself for a variant-less type).
            Ok(ast.TypeDecl(_, [first, ..], _) as decl) ->
              check_named(
                target,
                args,
                Some(variant_field_names(decl, first.name)),
              )
            Ok(decl) -> check_named(target, args, Some(variant_field_names(decl, "")))
            Error(_) -> check_named(target, args, None)
          }
      })
      use _ <- result.try(check_fn_arg_purity(ctx, name, args))
      check_args(ctx, args)
    }
    ast.ECall(callee, args) -> {
      use _ <- result.try(check_named("this call", args, None))
      use _ <- result.try(check_expr(ctx, callee))
      check_args(ctx, args)
    }
    ast.EInt(_)
    | ast.EFloat(_)
    | ast.EString(_)
    | ast.EBool(_)
    | ast.EAtom(_)
    | ast.EIdent(_) -> Ok(Nil)
    ast.EInterp(parts) ->
      list.try_fold(parts, Nil, fn(_, p) {
        case p {
          ast.ILit(_) -> Ok(Nil)
          ast.IExpr(inner) -> check_expr(ctx, inner)
        }
      })
      |> result.map(fn(_) { Nil })
    ast.EVector(items) -> check_exprs(ctx, items)
    ast.EMember(target, _) -> check_expr(ctx, target)
    ast.EIndex(target, index) -> check_exprs(ctx, [target, index])
    ast.ESlice(target, low, high) ->
      check_exprs(ctx, [target, ..option.values([low, high])])
    ast.EBinary(_, l, r) -> check_exprs(ctx, [l, r])
    ast.EIs(subject, _) -> check_expr(ctx, subject)
    ast.EAwait(value, _) -> check_expr(ctx, value)
  }
}

fn check_exprs(ctx: Ctx, exprs: List(ast.Expr)) -> Result(Nil, String) {
  list.try_fold(exprs, Nil, fn(_, e) { check_expr(ctx, e) })
  |> result.map(fn(_) { Nil })
}

fn check_args(ctx: Ctx, args: List(ast.Arg)) -> Result(Nil, String) {
  check_exprs(ctx, list.map(args, fn(a) { a.value }))
}

// Whether any argument is a `_` placeholder — i.e. the call is a partial
// application (`f(_, x)`) that builds a function value rather than calling.
fn has_placeholder(args: List(ast.Arg)) -> Bool {
  list.any(args, fn(a) {
    case a.value {
      ast.EIdent("_") -> True
      _ -> False
    }
  })
}

// A `func`-typed parameter is pure, so it may only receive a func value; a
// `proc`-typed parameter accepts either (a func widens to a proc). This
// enforces that rule for the argument shapes whose purity the checker can see
// exactly — a bare reference to, or a partial application of, a declared
// callable. A function value carried in through a local or parameter is not
// inspectable here (the checker does no type inference), so those cases fall
// through to Go's structural types. A partial application of `name` itself is
// a wrapper, not a call, so its arguments are not checked against `name`.
fn check_fn_arg_purity(
  ctx: Ctx,
  name: String,
  args: List(ast.Arg),
) -> Result(Nil, String) {
  case has_placeholder(args), dict.get(ctx.fn_params, name) {
    False, Ok(params) -> {
      let #(assigned, _) =
        codegen.assign_args(args, list.map(params, fn(p) { p.name }))
      list.zip(assigned, params)
      |> list.try_fold(Nil, fn(_, pair) {
        let #(#(_, arg), field) = pair
        case field.typ, value_is_proc(ctx, arg) {
          ast.TFunc(True, _, _), True ->
            Error(
              "the `"
              <> field.name
              <> "` parameter of `"
              <> name
              <> "` is a `func` (pure), so it cannot receive a proc value — a "
              <> "proc may perform side effects a func must not",
            )
          _, _ -> Ok(Nil)
        }
      })
      |> result.map(fn(_) { Nil })
    }
    _, _ -> Ok(Nil)
  }
}

// Whether an expression is a function value known to be impure (a proc): a bare
// reference to a proc, or a partial application of one. Anything else — a func
// reference, or a value arriving through a local/parameter — is not treated as
// a known proc value here.
fn value_is_proc(ctx: Ctx, e: ast.Expr) -> Bool {
  case e {
    ast.EIdent(n) -> dict.has_key(ctx.procs, n)
    ast.ECall(ast.EIdent(n), inner) ->
      has_placeholder(inner) && dict.has_key(ctx.procs, n)
    _ -> False
  }
}

fn variant_field_names(decl: ast.Decl, variant: String) -> List(String) {
  case decl {
    ast.TypeDecl(_, variants, commons) -> {
      let own = case list.find(variants, fn(v) { v.name == variant }) {
        Ok(v) -> v.fields
        Error(_) -> []
      }
      list.map(list.append(own, commons), fn(f) { f.name })
    }
    _ -> []
  }
}

// ---------------------------------------------------------------------------
// Named arguments
// ---------------------------------------------------------------------------

// Validates named-argument usage against the target's parameter list (`None`
// when the target has no known parameter names, in which case named
// arguments are rejected outright). Once named arguments are involved, the
// call must resolve to the complete parameter list with nothing left over.
fn check_named(
  target: String,
  args: List(ast.Arg),
  allowed: Option(List(String)),
) -> Result(Nil, String) {
  let named = list.filter_map(args, fn(a) { option.to_result(a.name, Nil) })
  use _ <- result.try(case find_duplicate(named) {
    Some(n) ->
      Error("duplicate named argument `" <> n <> "` in call to " <> target)
    None -> Ok(Nil)
  })
  case named, allowed {
    [], _ -> Ok(Nil)
    [n, ..], None ->
      Error(
        target
        <> " does not accept named arguments (got `"
        <> n
        <> ":`)",
      )
    _, Some(names) -> {
      use _ <- result.try(
        list.try_fold(named, Nil, fn(_, n) {
          case list.contains(names, n) {
            True -> Ok(Nil)
            False ->
              Error(
                "unknown named argument `"
                <> n
                <> "` in call to "
                <> target
                <> " (expected: "
                <> string.join(names, ", ")
                <> ")",
              )
          }
        })
        |> result.map(fn(_) { Nil }),
      )
      let #(assigned, extra) = codegen.assign_args(args, names)
      case list.length(assigned) == list.length(names) && extra == [] {
        True -> Ok(Nil)
        False ->
          Error(
            "call to "
            <> target
            <> " with named arguments must provide exactly: "
            <> string.join(names, ", "),
          )
      }
    }
  }
}

fn find_duplicate(names: List(String)) -> Option(String) {
  case names {
    [] -> None
    [n, ..rest] ->
      case list.contains(rest, n) {
        True -> Some(n)
        False -> find_duplicate(rest)
      }
  }
}

// ---------------------------------------------------------------------------
// hive.file builtins
// ---------------------------------------------------------------------------

fn check_file_call(fname: String, args: List(ast.Arg)) -> Result(Nil, String) {
  case fname {
    "read" -> check_arity("`hive.file.read`", args, ["path"])
    "lines" -> check_arity("`hive.file.lines`", args, ["path"])
    "exists" -> check_arity("`hive.file.exists`", args, ["path"])
    "size" -> check_arity("`hive.file.size`", args, ["path"])
    "delete" -> check_arity("`hive.file.delete`", args, ["path"])
    "list" -> check_arity("`hive.file.list`", args, ["path"])
    "makeDir" -> check_arity("`hive.file.makeDir`", args, ["path"])
    "write" -> check_arity("`hive.file.write`", args, ["path", "contents"])
    "append" -> check_arity("`hive.file.append`", args, ["path", "contents"])
    "copy" -> check_arity("`hive.file.copy`", args, ["from", "to"])
    "move" -> check_arity("`hive.file.move`", args, ["from", "to"])
    _ ->
      Error(
        "unknown builtin `hive.file."
        <> fname
        <> "` (available: read, lines, write, append, exists, size, delete, "
        <> "list, makeDir, copy, move)",
      )
  }
}

// ---------------------------------------------------------------------------
// hive.json builtins
// ---------------------------------------------------------------------------

fn check_json_call(fname: String, args: List(ast.Arg)) -> Result(Nil, String) {
  case fname {
    "parse" ->
      Error(
        "`hive.json.parse` needs a decode target: write "
        <> "`hive.json.parse(text) with SomeType`",
      )
    "encode" -> {
      use _ <- result.try(check_named(
        "`hive.json.encode`",
        args,
        Some(["value"]),
      ))
      case codegen.assign_args(args, ["value"]) {
        #([_], []) -> Ok(Nil)
        _ -> Error("`hive.json.encode` takes exactly one argument")
      }
    }
    "table" -> {
      use _ <- result.try(check_named("`hive.json.table`", args, Some(["text"])))
      case codegen.assign_args(args, ["text"]) {
        #([_], []) -> Ok(Nil)
        _ -> Error("`hive.json.table` takes exactly one Str argument")
      }
    }
    "get" -> {
      use _ <- result.try(check_named(
        "`hive.json.get`",
        args,
        Some(["table", "path"]),
      ))
      case codegen.assign_args(args, ["table", "path"]) {
        #([_, _], []) -> Ok(Nil)
        _ ->
          Error("`hive.json.get` takes exactly two arguments: a Table and a path")
      }
    }
    _ ->
      Error(
        "unknown builtin `hive.json."
        <> fname
        <> "` (available: encode, get, parse, table)",
      )
  }
}

// ---------------------------------------------------------------------------
// hive.crypto builtins
// ---------------------------------------------------------------------------

fn check_crypto_call(fname: String, args: List(ast.Arg)) -> Result(Nil, String) {
  case fname {
    "sha256" -> check_arity("`hive.crypto.sha256`", args, ["input"])
    "sha512" -> check_arity("`hive.crypto.sha512`", args, ["input"])
    "base64Encode" -> check_arity("`hive.crypto.base64Encode`", args, ["input"])
    "base64Decode" -> check_arity("`hive.crypto.base64Decode`", args, ["input"])
    "randomHex" -> check_arity("`hive.crypto.randomHex`", args, ["bytes"])
    "hmacSha256" ->
      check_arity("`hive.crypto.hmacSha256`", args, ["input", "key"])
    "jwtSign" -> check_arity("`hive.crypto.jwtSign`", args, ["claims", "secret"])
    "jwtHeader" -> check_arity("`hive.crypto.jwtHeader`", args, ["token"])
    "jwtVerify" ->
      Error(
        "`hive.crypto.jwtVerify` needs a decode target: write "
        <> "`hive.crypto.jwtVerify(token, secret) with SomeType`",
      )
    "jwtDecode" ->
      Error(
        "`hive.crypto.jwtDecode` needs a decode target: write "
        <> "`hive.crypto.jwtDecode(token) with SomeType`",
      )
    _ ->
      Error(
        "unknown builtin `hive.crypto."
        <> fname
        <> "` (available: sha256, sha512, hmacSha256, base64Encode, "
        <> "base64Decode, randomHex, jwtSign, jwtVerify, jwtDecode, jwtHeader)",
      )
  }
}

// ---------------------------------------------------------------------------
// hive.sql builtins
// ---------------------------------------------------------------------------

fn check_sql_call(fname: String, args: List(ast.Arg)) -> Result(Nil, String) {
  case fname {
    "connect" ->
      check_arity("`hive.sql.connect`", args, ["driver", "connString"])
    "pool" ->
      check_arity("`hive.sql.pool`", args, [
        "driver",
        "connString",
        "maxOpen",
        "maxIdle",
      ])
    "close" -> check_arity("`hive.sql.close`", args, ["connection"])
    _ ->
      Error(
        "unknown builtin `hive.sql."
        <> fname
        <> "` (available: connect, pool, close; query with `using conn with ...`)",
      )
  }
}

fn check_sql_driver(
  variant: String,
  args: List(ast.Arg),
) -> Result(Nil, String) {
  case variant {
    "SQLite" -> check_arity("`hive.sql.DatabaseDriver.SQLite`", args, [])
    "PostgreSQL" ->
      check_arity("`hive.sql.DatabaseDriver.PostgreSQL`", args, [])
    "Other" -> check_arity("`hive.sql.DatabaseDriver.Other`", args, ["name"])
    _ ->
      Error(
        "unknown `hive.sql.DatabaseDriver."
        <> variant
        <> "` (variants: SQLite, PostgreSQL, Other)",
      )
  }
}

// ---------------------------------------------------------------------------
// hive.conv builtins
// ---------------------------------------------------------------------------

fn check_conv_call(fname: String, args: List(ast.Arg)) -> Result(Nil, String) {
  case fname {
    "ceil" -> check_arity("`hive.conv.ceil`", args, ["value"])
    "floor" -> check_arity("`hive.conv.floor`", args, ["value"])
    "round" -> check_arity("`hive.conv.round`", args, ["value"])
    "itf" -> check_arity("`hive.conv.itf`", args, ["value"])
    "its" -> check_arity("`hive.conv.its`", args, ["value"])
    "fts" -> check_arity("`hive.conv.fts`", args, ["value"])
    "sti" -> check_arity("`hive.conv.sti`", args, ["value"])
    "stf" -> check_arity("`hive.conv.stf`", args, ["value"])
    _ ->
      Error(
        "unknown builtin `hive.conv."
        <> fname
        <> "` (available: ceil, floor, round, itf, its, fts, sti, stf)",
      )
  }
}

// ---------------------------------------------------------------------------
// hive.env builtins
// ---------------------------------------------------------------------------

fn check_env_call(fname: String, args: List(ast.Arg)) -> Result(Nil, String) {
  case fname {
    "get" -> check_arity("`hive.env.get`", args, ["key"])
    _ ->
      Error(
        "unknown builtin `hive.env." <> fname <> "` (available: get)",
      )
  }
}

fn check_term_call(fname: String, args: List(ast.Arg)) -> Result(Nil, String) {
  case fname {
    "print" -> check_arity("`hive.term.print`", args, ["text"])
    "read" -> check_arity("`hive.term.read`", args, [])
    "args" -> check_arity("`hive.term.args`", args, [])
    _ ->
      Error(
        "unknown builtin `hive.term."
        <> fname
        <> "` (available: print, read, args)",
      )
  }
}

fn check_task_call(fname: String, args: List(ast.Arg)) -> Result(Nil, String) {
  case fname {
    "sleep" -> check_arity("`hive.task.sleep`", args, ["ms"])
    _ ->
      Error(
        "unknown builtin `hive.task." <> fname <> "` (available: sleep)",
      )
  }
}

fn check_time_call(fname: String, args: List(ast.Arg)) -> Result(Nil, String) {
  case fname {
    "now" -> check_arity("`hive.time.now`", args, [])
    "timezone" -> check_arity("`hive.time.timezone`", args, [])
    "timezoneOffset" -> check_arity("`hive.time.timezoneOffset`", args, [])
    "format" -> check_arity("`hive.time.format`", args, ["time", "template"])
    _ ->
      Error(
        "unknown builtin `hive.time."
        <> fname
        <> "` (available: now, timezone, timezoneOffset, format)",
      )
  }
}

// Validates a builtin call against a fixed parameter list: named arguments
// must be known, and (positional or not) the call must cover exactly those
// parameters with nothing left over.
fn check_arity(
  target: String,
  args: List(ast.Arg),
  names: List(String),
) -> Result(Nil, String) {
  use _ <- result.try(check_named(target, args, Some(names)))
  let #(assigned, extra) = codegen.assign_args(args, names)
  case list.length(assigned) == list.length(names) && extra == [] {
    True -> Ok(Nil)
    False ->
      Error(
        target
        <> " takes exactly these arguments: "
        <> string.join(names, ", "),
      )
  }
}

// The `with` target must be a type the compiler can derive a decoder for.
// `Table` is allowed at the top level (it flattens the whole document) but
// not as a field of a custom type: unmapped JSON fields are simply ignored,
// so there is nothing for a Table field to hold.
fn check_with_type(ctx: Ctx, t: ast.TypeExpr) -> Result(Nil, String) {
  case t {
    ast.TName(None, name, _, _) ->
      case name {
        "Str" | "String" | "Int" | "Float" | "Bool" | "Atom" | "Table" ->
          Ok(Nil)
        _ ->
          case dict.get(ctx.types, name) {
            Ok(decl) -> check_decodable_fields(ctx, decl, [name])
            Error(_) ->
              Error(
                "cannot derive a JSON decoder for unknown type `"
                <> name
                <> "`",
              )
          }
      }
    _ -> Error("cannot derive a JSON decoder for this type")
  }
}

fn check_decodable_fields(
  ctx: Ctx,
  decl: ast.Decl,
  visited: List(String),
) -> Result(Nil, String) {
  case decl {
    ast.TypeDecl(tname, variants, commons) -> {
      let all =
        list.append(list.flat_map(variants, fn(v) { v.fields }), commons)
      list.try_fold(all, Nil, fn(_, f) {
        check_decodable_field(ctx, tname, f, visited)
      })
      |> result.map(fn(_) { Nil })
    }
    _ -> Ok(Nil)
  }
}

fn check_decodable_field(
  ctx: Ctx,
  tname: String,
  f: ast.Field,
  visited: List(String),
) -> Result(Nil, String) {
  case f.typ {
    ast.TName(None, name, _, _) ->
      case name {
        "Str" | "String" | "Int" | "Float" | "Bool" | "Atom" -> Ok(Nil)
        "Table" ->
          Error(
            "cannot derive a JSON decoder for `"
            <> tname
            <> "`: field `"
            <> f.name
            <> "` is a Table — unmapped JSON fields are simply ignored, so "
            <> "declare only the fields you need, or flatten the whole "
            <> "document with `with Table`",
          )
        _ ->
          case dict.get(ctx.types, name) {
            Ok(decl) ->
              case list.contains(visited, name) {
                True -> Ok(Nil)
                False -> check_decodable_fields(ctx, decl, [name, ..visited])
              }
            Error(_) ->
              Error(
                "cannot derive a JSON decoder for `"
                <> tname
                <> "`: field `"
                <> f.name
                <> "` has unknown type `"
                <> name
                <> "`",
              )
          }
      }
    _ ->
      Error(
        "cannot derive a JSON decoder for `"
        <> tname
        <> "`: field `"
        <> f.name
        <> "` cannot be decoded from JSON",
      )
  }
}

// ---------------------------------------------------------------------------
// hive.net builtins
// ---------------------------------------------------------------------------

fn check_net_call(
  ctx: Ctx,
  fname: String,
  args: List(ast.Arg),
) -> Result(Nil, String) {
  case fname {
    // --- HTTP ---
    "httpRequest" -> {
      use _ <- result.try(check_named(
        "`hive.net.httpRequest`",
        args,
        Some(["request"]),
      ))
      case codegen.assign_args(args, ["request"]) {
        #([_], []) -> Ok(Nil)
        _ ->
          Error(
            "`hive.net.httpRequest` takes exactly one hive.net.HttpRequest argument",
          )
      }
    }
    "httpServe" -> check_serve_call(ctx, "httpServe", args, ServeHttp)
    // Every call in this module now names its protocol, so the two bare HTTP
    // spellings point at their replacements rather than reading as unknown
    // members next to `wsServe` and `socketServe`.
    "request" ->
      Error(
        "`hive.net.request` is now `hive.net.httpRequest` — every call in "
        <> "`hive.net` names its protocol (httpRequest, wsSend, socketSend, ...)",
      )
    "serve" ->
      Error(
        "`hive.net.serve` is now `hive.net.httpServe` — every call in "
        <> "`hive.net` names its protocol (httpServe, wsServe, socketServe)",
      )
    // --- WebSockets ---
    "wsConnect" -> check_arity("`hive.net.wsConnect`", args, ["url"])
    "wsSend" ->
      check_arity("`hive.net.wsSend`", args, ["connection", "message"])
    "wsReceive" -> check_arity("`hive.net.wsReceive`", args, ["connection"])
    "wsRequest" -> check_arity("`hive.net.wsRequest`", args, ["connection"])
    "wsClose" -> check_arity("`hive.net.wsClose`", args, ["connection"])
    "wsServe" -> check_serve_call(ctx, "wsServe", args, ServeWs)
    // --- Raw TCP ---
    "socketConnect" ->
      check_arity("`hive.net.socketConnect`", args, ["host", "port"])
    "socketSend" ->
      check_arity("`hive.net.socketSend`", args, ["connection", "data"])
    "socketReceive" ->
      check_arity("`hive.net.socketReceive`", args, ["connection", "bytes"])
    "socketReceiveLine" ->
      check_arity("`hive.net.socketReceiveLine`", args, ["connection"])
    "socketPeer" -> check_arity("`hive.net.socketPeer`", args, ["connection"])
    "socketClose" -> check_arity("`hive.net.socketClose`", args, ["connection"])
    "socketServe" -> check_serve_call(ctx, "socketServe", args, ServeSocket)
    // --- The network underneath all three ---
    "resolve" -> check_arity("`hive.net.resolve`", args, ["name"])
    "localAddress" -> check_arity("`hive.net.localAddress`", args, [])
    _ ->
      Error(
        "unknown builtin `hive.net."
        <> fname
        <> "` (available: httpRequest, httpServe; wsConnect, wsSend, "
        <> "wsReceive, wsRequest, wsClose, wsServe; socketConnect, socketSend, "
        <> "socketReceive, socketReceiveLine, socketPeer, socketClose, "
        <> "socketServe; resolve, localAddress)",
      )
  }
}

// Which of the three servers a handler is being checked for. Each one calls its
// handler with a different value, so each demands a different signature.
type ServeKind {
  ServeHttp
  ServeWs
  ServeSocket
}

// The parameter type a handler of this kind receives, and the type it must
// return (`None` for a `void` handler).
fn serve_signature(kind: ServeKind) -> #(String, Option(String)) {
  case kind {
    ServeHttp -> #("HttpRequest", Some("HttpResponse"))
    ServeWs -> #("WsConnection", None)
    ServeSocket -> #("SocketConnection", None)
  }
}

fn check_serve_call(
  ctx: Ctx,
  fname: String,
  args: List(ast.Arg),
  kind: ServeKind,
) -> Result(Nil, String) {
  let target = "`hive.net." <> fname <> "`"
  use _ <- result.try(check_named(target, args, Some(["port", "handler"])))
  case codegen.assign_args(args, ["port", "handler"]) {
    #([#(_, _), #(_, handler)], []) ->
      check_handler(ctx, fname, handler, kind)
    _ ->
      Error(
        target
        <> " takes exactly two arguments: a port and a handler proc",
      )
  }
}

// The handler must be the name of a proc with the shape the server calls it
// with — `proc (hive.net.HttpRequest): hive.net.HttpResponse` for `serve`, and
// `proc (hive.net.WsConnection): void` / `proc (hive.net.SocketConnection):
// void` for the other two. This is where that declared shape is enforced.
fn check_handler(
  ctx: Ctx,
  fname: String,
  handler: ast.Expr,
  kind: ServeKind,
) -> Result(Nil, String) {
  let #(param, ret) = serve_signature(kind)
  let bad_signature =
    "a handler for `hive.net."
    <> fname
    <> "` must take exactly one hive.net."
    <> param
    <> " and return "
    <> case ret {
      Some(r) -> "hive.net." <> r
      None -> "void"
    }
  case handler {
    // A partial application (or any call producing a function value), e.g.
    // `handler(_, db)`. Its exact shape is enforced by Go's typed server
    // signature; here we just let it through.
    ast.ECall(..) -> Ok(Nil)
    ast.EIdent(name) ->
      case dict.get(ctx.procs, name) {
        Ok(#([ast.Field(_, got_param)], got_ret)) ->
          case
            is_hive_type(got_param, param) && returns_hive_type(got_ret, ret)
          {
            True -> Ok(Nil)
            False -> Error("proc `" <> name <> "` cannot be used: " <> bad_signature)
          }
        Ok(_) -> Error("proc `" <> name <> "` cannot be used: " <> bad_signature)
        Error(_) ->
          Error(
            "the handler passed to `hive.net."
            <> fname
            <> "` must be the name of a proc, but `"
            <> name
            <> "` is not one",
          )
      }
    _ ->
      Error(
        "the handler passed to `hive.net."
        <> fname
        <> "` must be the name of a proc",
      )
  }
}

// ---------------------------------------------------------------------------
// hive.syslink
// ---------------------------------------------------------------------------

fn check_syslink_call(
  ctx: Ctx,
  fname: String,
  args: List(ast.Arg),
) -> Result(Nil, String) {
  case fname {
    "listen" -> check_arity("`hive.syslink.listen`", args, ["endpoint"])
    "node" -> check_arity("`hive.syslink.node`", args, [])
    "peers" -> check_arity("`hive.syslink.peers`", args, [])
    // Node roles used to be atoms too. They earned nothing: routing wants an
    // endpoint that can be resolved at runtime, and there is no name for an
    // authenticated peer to impersonate, so all they did was force the cluster's
    // size to be known when the program was written.
    "peer" | "endpoint" ->
      Error(
        "`hive.syslink."
        <> fname
        <> "` is gone: a node is identified by where it is, not by a name. Pass "
        <> "the endpoint straight to `hive.syslink.on(\"10.0.0.4:9100\", #Cache)` "
        <> "— it can come from config, DNS or a vector, so a cluster no longer "
        <> "has to be a fixed set of roles",
      )
    "spawn" -> {
      use _ <- result.try(check_arity(
        "`hive.syslink.spawn`",
        args,
        ["handler", "state"],
      ))
      case codegen.assign_args(args, ["handler", "state"]) {
        #([#(_, handler), _], []) -> check_service_handler(ctx, handler)
        _ -> Ok(Nil)
      }
    }
    "register" ->
      check_atom_named(
        "`hive.syslink.register`",
        args,
        ["name", "address"],
        ["name"],
      )
    "at" -> check_atom_named("`hive.syslink.at`", args, ["name"], ["name"])
    "on" ->
      check_atom_named("`hive.syslink.on`", args, ["endpoint", "name"], ["name"])
    "answer" -> check_arity("`hive.syslink.answer`", args, ["from", "value"])
    "self" -> check_arity("`hive.syslink.self`", args, ["from"])
    "monitor" ->
      check_arity("`hive.syslink.monitor`", args, ["from", "target", "message"])
    "stop" -> check_arity("`hive.syslink.stop`", args, ["address"])
    // There is no `send` and no `call`: an address *is* the way to reach its
    // service, so it is called directly and the call site decides what the call
    // means — exactly as it does for an `async func`.
    "send" | "call" ->
      Error(
        "there is no `hive.syslink."
        <> fname
        <> "` — a service address is called directly, and what the call site "
        <> "does with it decides what it means: `cache(Op.Count())` as a "
        <> "statement is fire-and-forget, `p := cache(Op.Count())` keeps the "
        <> "request in flight, and `await cache(Op.Count())` waits for the "
        <> "service's answer (optionally bounded with `with timeout <ms>`)",
      )
    _ ->
      Error(
        "unknown builtin `hive.syslink."
        <> fname
        <> "` (available: listen, node, peers; spawn, register, at, on, stop; "
        <> "answer, self, monitor). A service is reached by calling its address — "
        <> "`cache(Op.Count())` — not through a function in this module.",
      )
  }
}

// A registered name and a node role are atoms, never computed: that is what
// makes the registry knowable at compile time, so `at` needs no `with` clause
// and a `send` to another machine can be type-checked at all.
fn check_atom_named(
  target: String,
  args: List(ast.Arg),
  names: List(String),
  must_be_atoms: List(String),
) -> Result(Nil, String) {
  use _ <- result.try(check_arity(target, args, names))
  let #(assigned, _) = codegen.assign_args(args, names)
  list.try_fold(list.zip(assigned, names), Nil, fn(_, pair) {
    let #(#(_, value), name) = pair
    case list.contains(must_be_atoms, name), value {
      True, ast.EAtom(_) -> Ok(Nil)
      True, _ ->
        Error(
          target
          <> "'s `"
          <> name
          <> "` must be an atom literal (`#Cache`), not a computed value — "
          <> "names come from a closed set so the compiler knows every service "
          <> "the program addresses",
        )
      False, _ -> Ok(Nil)
    }
  })
}

// A service handler is the fold over its mailbox: it takes the state, one
// message and the turn's envelope, and returns the next state. The state going
// in and the state coming out have to be the same type, which is what makes the
// fold well-founded — and it is why a service needs no mutex.
fn check_service_handler(ctx: Ctx, handler: ast.Expr) -> Result(Nil, String) {
  let shape =
    "a handler for `hive.syslink.spawn` must be a proc taking (state, message, "
    <> "hive.syslink.Envelope) and returning the state's own type"
  case handler {
    // A partial application (`inbox(_, _, _, db)`) fixes some arguments and
    // leaves the rest as holes. Go's typed spawn signature enforces the result,
    // exactly as it does for the `hive.net` servers.
    ast.ECall(..) -> Ok(Nil)
    ast.EIdent(name) ->
      case dict.get(ctx.procs, name) {
        Ok(#([state, _message, envelope], ret)) ->
          case is_hive_type(envelope.typ, "Envelope"), ret == state.typ {
            False, _ ->
              Error(
                "proc `"
                <> name
                <> "` cannot be used: its third parameter must be a "
                <> "hive.syslink.Envelope — "
                <> shape,
              )
            _, False ->
              Error(
                "proc `"
                <> name
                <> "` cannot be used: it must return the same type as its "
                <> "first parameter, since each turn hands the next turn its "
                <> "state — "
                <> shape,
              )
            True, True -> Ok(Nil)
          }
        Ok(_) -> Error("proc `" <> name <> "` cannot be used: " <> shape)
        Error(_) ->
          Error(
            "the handler passed to `hive.syslink.spawn` must be the name of a "
            <> "proc, but `"
            <> name
            <> "` is not one",
          )
      }
    _ ->
      Error("the handler passed to `hive.syslink.spawn` must be the name of a proc")
  }
}

// Whether a type expression is the builtin `name`, referenced through its
// own namespace (e.g. `hive.net.HttpRequest`).
fn is_hive_type(t: ast.TypeExpr, name: String) -> Bool {
  case t {
    ast.TName(Some(pkg), n, _, []) ->
      n == name && pkg == codegen.builtin_qualifier(name)
    _ -> False
  }
}

// The handler's return, which is either a named builtin or `void`.
fn returns_hive_type(t: ast.TypeExpr, want: Option(String)) -> Bool {
  case want, t {
    Some(name), _ -> is_hive_type(t, name)
    None, ast.TVoid -> True
    None, _ -> False
  }
}
