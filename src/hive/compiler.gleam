//// Ties the pipeline together: source text -> tokens -> AST -> Go source.
////
//// Between parsing and codegen a validation pass walks every body to
//// enforce:
////   * the proc/func split — a `func` may perform I/O (`echo`, `using`,
////     `hive.http`) just like a `proc`, but it may not call a `proc` (only
////     procs call procs) and cannot receive a mutex as a parameter;
////   * mutability — only `mut` variables may be reassigned (`x = ...`,
////     `v[0] = ...`) or grown with `append`;
////   * the `hive.http` builtins — known member names, right arity, and a
////     `serve` handler that really is a `proc(hive.HttpRequest):
////     hive.HttpResponse`;
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
import hive/codegen
import hive/lexer
import hive/parser

/// Compile Hive source into the contents of the generated `main.go`.
pub fn compile(source: String) -> Result(String, String) {
  use tokens <- result.try(lexer.lex(source))
  use module <- result.try(parser.parse(tokens))
  use _ <- result.try(check(module))
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
    /// (echo, using, hive.http) just like procs, but they may not call a
    /// `proc` — only procs may, since procs are the ones that own and pass
    /// mutable state (mutexes).
    in_func: Bool,
    /// Signatures of every declared `proc`, used to reject func→proc calls and
    /// to validate the `hive.http.serve` handler.
    procs: Dict(String, #(List(ast.Field), ast.TypeExpr)),
    /// Parameter names of every declared proc/func/query.
    callables: Dict(String, List(String)),
    types: Dict(String, ast.Decl),
    /// True while checking statements inside a loop body, so `break`/`continue`
    /// outside any loop can be rejected.
    in_loop: Bool,
  )
}

fn check(module: ast.Module) -> Result(Nil, String) {
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
  let types =
    list.fold(module.decls, dict.new(), fn(acc, d) {
      case d {
        ast.TypeDecl(name, _, _) -> dict.insert(acc, name, d)
        _ -> acc
      }
    })
  list.try_fold(module.decls, Nil, fn(_, d) {
    case d {
      ast.ProcDecl(name, _, _, body) ->
        check_body(Ctx(name, False, procs, callables, types, False), body)
      // A `func` may perform I/O (echo, using, hive.http, ...) just like a
      // `proc`. Its two restrictions — no mutex parameters, no calling procs —
      // are what `in_func` marks.
      ast.FuncDecl(name, _, _, body, _) ->
        check_body(Ctx(name, True, procs, callables, types, False), body)
      ast.QueryDecl(name, _, _, sql) ->
        // A query is a func whose body is inline SQL; its interpolations are
        // walked with the same func restrictions.
        list.try_fold(sql, Nil, fn(_, p) {
          case p {
            ast.ILit(_) -> Ok(Nil)
            ast.IExpr(e) ->
              check_expr(Ctx(name, True, procs, callables, types, False), e)
          }
        })
        |> result.map(fn(_) { Nil })
      ast.TypeDecl(..) -> Ok(Nil)
    }
  })
  |> result.map(fn(_) { Nil })
}

fn check_body(ctx: Ctx, stmts: List(ast.Stmt)) -> Result(Nil, String) {
  check_stmts(ctx, stmts, dict.new())
  |> result.map(fn(_) { Nil })
}

// Walks a statement list threading the mutability of each declared local
// (name -> declared with `mut`?), so assignments and `append`s targeting an
// immutable variable can be rejected. Returns the updated set so declarations
// stay visible to the statements that follow them.
fn check_stmts(
  ctx: Ctx,
  stmts: List(ast.Stmt),
  muts: Dict(String, Bool),
) -> Result(Dict(String, Bool), String) {
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
  muts: Dict(String, Bool),
) -> Result(Dict(String, Bool), String) {
  case s {
    ast.SEcho(e) -> {
      use _ <- result.try(check_expr(ctx, e))
      Ok(muts)
    }
    ast.SVarDecl(name, value, mutable) -> {
      use _ <- result.try(check_expr(ctx, value))
      Ok(dict.insert(muts, name, mutable))
    }
    ast.STypedDecl(_, name, value, mutable) -> {
      use _ <- result.try(check_expr(ctx, value))
      Ok(dict.insert(muts, name, mutable))
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
    ast.SForEach(name, _, iterable, body) -> {
      use _ <- result.try(check_expr(ctx, iterable))
      // The iteration variable is a fresh, immutable binding in the body.
      let inner = dict.insert(muts, name, False)
      use _ <- result.try(
        check_stmts(Ctx(..ctx, in_loop: True), body, inner)
        |> result.map(fn(_) { Nil }),
      )
      Ok(muts)
    }
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
  muts: Dict(String, Bool),
) -> Result(Nil, String) {
  use root <- result.try(assign_root(target))
  case dict.get(muts, root) {
    Ok(True) -> Ok(Nil)
    _ ->
      Error(
        "cannot assign to `"
        <> root
        <> "`: it is immutable — declare it with `mut` to allow reassignment",
      )
  }
}

// `append(v, ...)` grows a vector in place, so `v` must be a mutable variable
// (per the spec: append "only compiles when used on mutable dynamic vectors").
fn check_append(e: ast.Expr, muts: Dict(String, Bool)) -> Result(Nil, String) {
  case e {
    ast.ECall(ast.EIdent("append"), args) ->
      case args {
        [ast.Arg(_, target), ..] -> {
          use root <- result.try(
            assign_root(target)
            |> result.replace_error(
              "`append`'s first argument must be a mutable vector variable",
            ),
          )
          case dict.get(muts, root) {
            Ok(True) -> Ok(Nil)
            _ ->
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

fn check_expr(ctx: Ctx, e: ast.Expr) -> Result(Nil, String) {
  case e {
    // `using` (reading a file) is I/O, which funcs may now do too, so there is
    // nothing to reject here — just walk its sub-expressions.
    ast.EUsing(path, delim) ->
      check_exprs(ctx, [path, ..option.values([delim])])
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
            <> "`hive.crypto.jwtVerify(...)` or `hive.crypto.jwtDecode(...)` calls",
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
        // A builtin type constructor: `hive.http.HttpRequest(...)` etc.
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
            "http" -> {
              use _ <- result.try(check_http_call(ctx, fname, args))
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
            _ ->
              Error(
                "unknown builtin namespace `hive."
                <> ns
                <> "` (available: http, json, crypto, sql, conv, env)",
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
            // Builtin types are namespaced now: `hive.http.HttpRequest(...)`,
            // not the bare `hive.HttpRequest(...)`.
            "hive" ->
              case codegen.builtin_fields(member) {
                Some(_) ->
                  Error(
                    "`hive."
                    <> member
                    <> "` is not a builtin; use `"
                    <> codegen.builtin_qualifier(member)
                    <> "."
                    <> member
                    <> "` instead",
                  )
                None -> check_named(target, args, None)
              }
            _ -> check_named(target, args, None)
          }
      })
      check_args(ctx, args)
    }
    ast.ECall(ast.EIdent(name), args) -> {
      // Funcs (and queries) may do I/O, but they may not call procs — only
      // procs call procs.
      use _ <- result.try(case ctx.in_func && dict.has_key(ctx.procs, name) {
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
    ast.EAwait(value) -> check_expr(ctx, value)
  }
}

fn check_exprs(ctx: Ctx, exprs: List(ast.Expr)) -> Result(Nil, String) {
  list.try_fold(exprs, Nil, fn(_, e) { check_expr(ctx, e) })
  |> result.map(fn(_) { Nil })
}

fn check_args(ctx: Ctx, args: List(ast.Arg)) -> Result(Nil, String) {
  check_exprs(ctx, list.map(args, fn(a) { a.value }))
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
    ast.TName(None, name, _) ->
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
    ast.TName(None, name, _) ->
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
// hive.http builtins
// ---------------------------------------------------------------------------

fn check_http_call(
  ctx: Ctx,
  fname: String,
  args: List(ast.Arg),
) -> Result(Nil, String) {
  case fname {
    "request" -> {
      use _ <- result.try(check_named(
        "`hive.http.request`",
        args,
        Some(["request"]),
      ))
      case codegen.assign_args(args, ["request"]) {
        #([_], []) -> Ok(Nil)
        _ ->
          Error(
            "`hive.http.request` takes exactly one hive.HttpRequest argument",
          )
      }
    }
    "serve" -> {
      use _ <- result.try(check_named(
        "`hive.http.serve`",
        args,
        Some(["port", "handler"]),
      ))
      case codegen.assign_args(args, ["port", "handler"]) {
        #([#(_, _), #(_, handler)], []) -> check_handler(ctx, handler)
        _ ->
          Error(
            "`hive.http.serve` takes exactly two arguments: a port and a handler proc",
          )
      }
    }
    _ ->
      Error(
        "unknown builtin `hive.http."
        <> fname
        <> "` (available: request, serve)",
      )
  }
}

// The handler must be the name of a proc taking exactly one hive.HttpRequest
// and returning hive.HttpResponse. This is where the parameter's declared
// shape `proc (hive.HttpRequest): hive.HttpResponse` is enforced.
fn check_handler(ctx: Ctx, handler: ast.Expr) -> Result(Nil, String) {
  let bad_signature =
    "a handler must take exactly one hive.http.HttpRequest and return "
    <> "hive.http.HttpResponse"
  case handler {
    ast.EIdent(name) ->
      case dict.get(ctx.procs, name) {
        Ok(#([ast.Field(_, req)], resp)) ->
          case
            is_hive_type(req, "HttpRequest")
            && is_hive_type(resp, "HttpResponse")
          {
            True -> Ok(Nil)
            False ->
              Error(
                "proc `" <> name <> "` cannot handle HTTP requests: " <> bad_signature,
              )
          }
        Ok(_) ->
          Error(
            "proc `" <> name <> "` cannot handle HTTP requests: " <> bad_signature,
          )
        Error(_) ->
          Error(
            "the handler passed to `hive.http.serve` must be the name of a "
            <> "proc, but `"
            <> name
            <> "` is not one",
          )
      }
    _ ->
      Error(
        "the handler passed to `hive.http.serve` must be the name of a proc",
      )
  }
}

// Whether a type expression is the builtin `name`, referenced through its
// own namespace (e.g. `hive.http.HttpRequest`).
fn is_hive_type(t: ast.TypeExpr, name: String) -> Bool {
  case t {
    ast.TName(Some(pkg), n, []) ->
      n == name && pkg == codegen.builtin_qualifier(name)
    _ -> False
  }
}
