//// Ties the pipeline together: source text -> tokens -> AST -> Go source.
////
//// Between parsing and codegen a small validation pass enforces the
//// proc/func split: only `proc`s may perform side effects, so a `func` body
//// cannot `echo`, read files with `using`, or call a `proc`.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import hive/ast
import hive/codegen
import hive/lexer
import hive/parser

/// Compile Hive source into the contents of the generated `main.go`.
pub fn compile(source: String) -> Result(String, String) {
  use tokens <- result.try(lexer.lex(source))
  use module <- result.try(parser.parse(tokens))
  use _ <- result.try(check_purity(module))
  Ok(codegen.generate(module))
}

fn check_purity(module: ast.Module) -> Result(Nil, String) {
  let proc_names =
    list.filter_map(module.decls, fn(d) {
      case d {
        ast.ProcDecl(name, _, _, _) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  list.try_fold(module.decls, Nil, fn(_, d) {
    case d {
      ast.FuncDecl(name, _, _, body) -> check_stmts(name, body, proc_names)
      _ -> Ok(Nil)
    }
  })
  |> result.map(fn(_) { Nil })
}

fn check_stmts(
  func: String,
  stmts: List(ast.Stmt),
  procs: List(String),
) -> Result(Nil, String) {
  list.try_fold(stmts, Nil, fn(_, s) { check_stmt(func, s, procs) })
  |> result.map(fn(_) { Nil })
}

fn check_stmt(
  func: String,
  s: ast.Stmt,
  procs: List(String),
) -> Result(Nil, String) {
  case s {
    ast.SEcho(_) ->
      Error(
        "func `"
        <> func
        <> "` cannot use `echo`: only procs may perform side effects",
      )
    ast.SVarDecl(_, value) -> check_expr(func, value, procs)
    ast.STypedDecl(_, _, value) -> check_expr(func, value, procs)
    ast.SReturn(None) -> Ok(Nil)
    ast.SReturn(Some(e)) -> check_expr(func, e, procs)
    ast.SAssert(e) -> check_expr(func, e, procs)
    ast.SExpr(e) -> check_expr(func, e, procs)
    ast.SIf(branches, else_body) -> {
      use _ <- result.try(
        list.try_fold(branches, Nil, fn(_, b) {
          use _ <- result.try(check_expr(func, b.cond, procs))
          check_stmts(func, b.body, procs)
        })
        |> result.map(fn(_) { Nil }),
      )
      case else_body {
        Some(body) -> check_stmts(func, body, procs)
        None -> Ok(Nil)
      }
    }
  }
}

fn check_expr(
  func: String,
  e: ast.Expr,
  procs: List(String),
) -> Result(Nil, String) {
  case e {
    ast.EUsing(_, _, _) ->
      Error(
        "func `"
        <> func
        <> "` cannot use `using`: only procs may perform side effects",
      )
    ast.ECall(ast.EIdent(name), args) ->
      case list.contains(procs, name) {
        True ->
          Error(
            "func `"
            <> func
            <> "` cannot call proc `"
            <> name
            <> "`: only procs may perform side effects",
          )
        False -> check_exprs(func, args, procs)
      }
    ast.ECall(callee, args) -> check_exprs(func, [callee, ..args], procs)
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
          ast.IExpr(inner) -> check_expr(func, inner, procs)
        }
      })
      |> result.map(fn(_) { Nil })
    ast.EVector(items) -> check_exprs(func, items, procs)
    ast.EMember(target, _) -> check_expr(func, target, procs)
    ast.EIndex(target, index) -> check_exprs(func, [target, index], procs)
    ast.ESlice(target, low, high) ->
      check_exprs(
        func,
        [target, ..option.values([low, high])],
        procs,
      )
    ast.EBinary(_, l, r) -> check_exprs(func, [l, r], procs)
    ast.EIs(subject, _) -> check_expr(func, subject, procs)
  }
}

fn check_exprs(
  func: String,
  exprs: List(ast.Expr),
  procs: List(String),
) -> Result(Nil, String) {
  list.try_fold(exprs, Nil, fn(_, e) { check_expr(func, e, procs) })
  |> result.map(fn(_) { Nil })
}
