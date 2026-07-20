//// Ties the pipeline together: source text -> tokens -> AST -> Go source.
////
//// Between parsing and codegen a validation pass walks every body to
//// enforce:
////   * the proc/func split — only `proc`s may perform side effects, so a
////     `func` cannot `echo`, read files with `using`, use `hive.http`, or
////     call a `proc`;
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
import hive/codegen
import hive/lexer
import hive/parser

/// Compile Hive source into the contents of the generated `main.go`.
pub fn compile(source: String) -> Result(String, String) {
  use tokens <- result.try(lexer.lex(source))
  use module <- result.try(parser.parse(tokens))
  use _ <- result.try(check(module))
  Ok(codegen.generate(module))
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

type Kind {
  InProc
  InFunc
}

type Ctx {
  Ctx(
    kind: Kind,
    name: String,
    procs: Dict(String, #(List(ast.Field), ast.TypeExpr)),
    /// Parameter names of every declared proc/func/query.
    callables: Dict(String, List(String)),
    types: Dict(String, ast.Decl),
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
        | ast.FuncDecl(name, params, _, _)
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
        check_stmts(Ctx(InProc, name, procs, callables, types), body)
      ast.FuncDecl(name, _, _, body) ->
        check_stmts(Ctx(InFunc, name, procs, callables, types), body)
      ast.QueryDecl(name, _, _, sql) ->
        // A query is pure by construction; its interpolations still get
        // walked (they could call procs).
        list.try_fold(sql, Nil, fn(_, p) {
          case p {
            ast.ILit(_) -> Ok(Nil)
            ast.IExpr(e) ->
              check_expr(Ctx(InFunc, name, procs, callables, types), e)
          }
        })
        |> result.map(fn(_) { Nil })
      ast.TypeDecl(..) -> Ok(Nil)
    }
  })
  |> result.map(fn(_) { Nil })
}

fn impure(ctx: Ctx, what: String) -> Result(Nil, String) {
  case ctx.kind {
    InProc -> Ok(Nil)
    InFunc ->
      Error(
        "func `"
        <> ctx.name
        <> "` cannot use "
        <> what
        <> ": only procs may perform side effects",
      )
  }
}

fn check_stmts(ctx: Ctx, stmts: List(ast.Stmt)) -> Result(Nil, String) {
  list.try_fold(stmts, Nil, fn(_, s) { check_stmt(ctx, s) })
  |> result.map(fn(_) { Nil })
}

fn check_stmt(ctx: Ctx, s: ast.Stmt) -> Result(Nil, String) {
  case s {
    ast.SEcho(e) -> {
      use _ <- result.try(impure(ctx, "`echo`"))
      check_expr(ctx, e)
    }
    ast.SVarDecl(_, value) -> check_expr(ctx, value)
    ast.STypedDecl(_, _, value) -> check_expr(ctx, value)
    ast.SReturn(None) -> Ok(Nil)
    ast.SReturn(Some(e)) -> check_expr(ctx, e)
    ast.SAssert(e) -> check_expr(ctx, e)
    ast.SExpr(e) -> check_expr(ctx, e)
    ast.SIf(branches, else_body) -> {
      use _ <- result.try(
        list.try_fold(branches, Nil, fn(_, b) {
          use _ <- result.try(check_expr(ctx, b.cond))
          check_stmts(ctx, b.body)
        })
        |> result.map(fn(_) { Nil }),
      )
      case else_body {
        Some(body) -> check_stmts(ctx, body)
        None -> Ok(Nil)
      }
    }
  }
}

fn check_expr(ctx: Ctx, e: ast.Expr) -> Result(Nil, String) {
  case e {
    ast.EUsing(_, _) -> impure(ctx, "`using`")
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
        _ ->
          Error(
            "`with <Type>` can only be applied to `hive.json.parse(...)` calls",
          )
      }
    ast.ECall(ast.EMember(ast.EMember(ast.EIdent("hive"), ns), fname), args) ->
      case ns {
        "http" -> {
          use _ <- result.try(impure(ctx, "`hive.http." <> fname <> "`"))
          use _ <- result.try(check_http_call(ctx, fname, args))
          check_args(ctx, args)
        }
        "json" -> {
          use _ <- result.try(check_json_call(fname, args))
          check_args(ctx, args)
        }
        _ ->
          Error(
            "unknown builtin namespace `hive."
            <> ns
            <> "` (available: http, json)",
          )
      }
    ast.ECall(ast.EMember(ast.EIdent(tname), member), args) -> {
      let target = "`" <> tname <> "." <> member <> "`"
      use _ <- result.try(case dict.get(ctx.types, tname) {
        // `Type.Variant(...)` — a user constructor.
        Ok(decl) ->
          check_named(target, args, Some(variant_field_names(decl, member)))
        Error(_) ->
          case tname {
            // `hive.HttpRequest(...)` etc. — a builtin constructor.
            "hive" ->
              case codegen.builtin_fields(member) {
                Some(fields) ->
                  check_named(
                    target,
                    args,
                    Some(list.map(fields, fn(f) { f.0 })),
                  )
                None -> check_named(target, args, None)
              }
            _ -> check_named(target, args, None)
          }
      })
      check_args(ctx, args)
    }
    ast.ECall(ast.EIdent(name), args) -> {
      use _ <- result.try(case
        dict.has_key(ctx.procs, name) && ctx.kind == InFunc
      {
        True ->
          Error(
            "func `"
            <> ctx.name
            <> "` cannot call proc `"
            <> name
            <> "`: only procs may perform side effects",
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
  case handler {
    ast.EIdent(name) ->
      case dict.get(ctx.procs, name) {
        Ok(#(
          [ast.Field(_, ast.TName(Some("hive"), "HttpRequest", []))],
          ast.TName(Some("hive"), "HttpResponse", []),
        )) -> Ok(Nil)
        Ok(_) ->
          Error(
            "proc `"
            <> name
            <> "` cannot handle HTTP requests: a handler must take exactly one "
            <> "hive.HttpRequest and return hive.HttpResponse",
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
