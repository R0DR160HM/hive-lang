//// A recursive-descent parser turning a token list into an `ast.Module`.
////
//// Each helper consumes tokens from the front of the list and returns the
//// produced node together with the remaining tokens, or an error message.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import hive/ast
import hive/lexer
import hive/token.{type Token, Token}

type Toks =
  List(Token)

pub fn parse(tokens: Toks) -> Result(ast.Module, String) {
  use decls <- result.try(parse_decls(tokens, []))
  Ok(ast.Module(decls))
}

// ---------------------------------------------------------------------------
// Token helpers
// ---------------------------------------------------------------------------

fn head(tokens: Toks) -> Token {
  case tokens {
    [t, ..] -> t
    [] -> Token(token.Eof, 0)
  }
}

fn kind(tokens: Toks) -> token.Kind {
  head(tokens).kind
}

fn line(tokens: Toks) -> Int {
  head(tokens).line
}

fn tail(tokens: Toks) -> Toks {
  case tokens {
    [_, ..r] -> r
    [] -> []
  }
}

fn at(tokens: Toks) -> String {
  " (line " <> int.to_string(line(tokens)) <> ")"
}

fn expect(tokens: Toks, k: token.Kind) -> Result(Toks, String) {
  case kind(tokens) == k {
    True -> Ok(tail(tokens))
    False ->
      Error(
        "expected "
        <> token.describe(k)
        <> " but found "
        <> token.describe(kind(tokens))
        <> at(tokens),
      )
  }
}

fn expect_ident(tokens: Toks) -> Result(#(String, Toks), String) {
  case kind(tokens) {
    token.Ident(name) -> Ok(#(name, tail(tokens)))
    other ->
      Error(
        "expected an identifier but found "
        <> token.describe(other)
        <> at(tokens),
      )
  }
}

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

fn parse_decls(
  tokens: Toks,
  acc: List(ast.Decl),
) -> Result(List(ast.Decl), String) {
  case kind(tokens) {
    token.Eof -> Ok(list.reverse(acc))
    token.KwProc -> {
      use #(decl, rest) <- result.try(parse_proc(tokens))
      parse_decls(rest, [decl, ..acc])
    }
    token.KwFunc -> {
      use #(decl, rest) <- result.try(parse_func(tokens))
      parse_decls(rest, [decl, ..acc])
    }
    token.KwAsync -> {
      use #(decl, rest) <- result.try(parse_async_func(tokens))
      parse_decls(rest, [decl, ..acc])
    }
    token.KwQuery -> {
      use #(decl, rest) <- result.try(parse_query(tokens))
      parse_decls(rest, [decl, ..acc])
    }
    token.KwType -> {
      use #(decl, rest) <- result.try(parse_type(tokens))
      parse_decls(rest, [decl, ..acc])
    }
    other ->
      Error(
        "expected `proc`, `func`, `async func`, `query` or `type` at the top "
        <> "level but found "
        <> token.describe(other)
        <> at(tokens),
      )
  }
}

// Parses the shared `<kw> name(params): ReturnType` header.
fn parse_header(
  tokens: Toks,
  kw: token.Kind,
) -> Result(#(String, List(ast.Field), ast.TypeExpr, Toks), String) {
  use t1 <- result.try(expect(tokens, kw))
  use #(name, t2) <- result.try(expect_ident(t1))
  use t3 <- result.try(expect(t2, token.LParen))
  use #(params, t4) <- result.try(parse_params(t3, []))
  use t5 <- result.try(expect(t4, token.RParen))
  use t6 <- result.try(expect(t5, token.Colon))
  use #(ret, t7) <- result.try(parse_type_expr(t6))
  Ok(#(name, params, ret, t7))
}

fn parse_proc(tokens: Toks) -> Result(#(ast.Decl, Toks), String) {
  use #(name, params, ret, t1) <- result.try(parse_header(tokens, token.KwProc))
  use #(body, t2) <- result.try(parse_block(t1))
  Ok(#(ast.ProcDecl(name, params, ret, body), t2))
}

fn parse_func(tokens: Toks) -> Result(#(ast.Decl, Toks), String) {
  use #(name, params, ret, t1) <- result.try(parse_header(tokens, token.KwFunc))
  use #(body, t2) <- result.try(parse_block(t1))
  Ok(#(ast.FuncDecl(name, params, ret, body, False), t2))
}

// `async func name(): T { ... }` — a func that runs on its own virtual thread.
fn parse_async_func(tokens: Toks) -> Result(#(ast.Decl, Toks), String) {
  let t0 = tail(tokens)
  case kind(t0) {
    token.KwFunc -> {
      use #(name, params, ret, t1) <- result.try(parse_header(t0, token.KwFunc))
      use #(body, t2) <- result.try(parse_block(t1))
      Ok(#(ast.FuncDecl(name, params, ret, body, True), t2))
    }
    other ->
      Error(
        "expected `func` after `async` but found "
        <> token.describe(other)
        <> at(t0),
      )
  }
}

fn parse_query(tokens: Toks) -> Result(#(ast.Decl, Toks), String) {
  use #(name, params, ret, t1) <- result.try(parse_header(
    tokens,
    token.KwQuery,
  ))
  case kind(t1) {
    token.SqlBody(sql) -> {
      use parts <- result.try(parse_sql_parts(sql, line(t1)))
      Ok(#(ast.QueryDecl(name, params, ret, parts), tail(t1)))
    }
    other ->
      Error(
        "expected a `{ ...SQL... }` body for query `"
        <> name
        <> "` but found "
        <> token.describe(other)
        <> at(t1),
      )
  }
}

// Splits a raw SQL body into literal chunks and `{expression}` interpolations.
fn parse_sql_parts(sql: String, line: Int) -> Result(List(ast.IPart), String) {
  split_sql(string.to_graphemes(sql), line, "", [])
}

fn split_sql(
  chars: List(String),
  line: Int,
  buf: String,
  acc: List(ast.IPart),
) -> Result(List(ast.IPart), String) {
  case chars {
    [] -> Ok(list.reverse(push_sql_lit(buf, acc)))
    ["{", ..rest] -> take_sql_code(rest, line, "", push_sql_lit(buf, acc))
    [c, ..rest] -> split_sql(rest, line, buf <> c, acc)
  }
}

fn take_sql_code(
  chars: List(String),
  line: Int,
  code: String,
  acc: List(ast.IPart),
) -> Result(List(ast.IPart), String) {
  case chars {
    [] ->
      Error(
        "unterminated `{` interpolation in a query body (line "
        <> int.to_string(line)
        <> ")",
      )
    ["}", ..rest] -> {
      use e <- result.try(parse_sub_expr(code, line))
      split_sql(rest, line, "", [ast.IExpr(e), ..acc])
    }
    [c, ..rest] -> take_sql_code(rest, line, code <> c, acc)
  }
}

fn push_sql_lit(buf: String, acc: List(ast.IPart)) -> List(ast.IPart) {
  case buf {
    "" -> acc
    _ -> [ast.ILit(buf), ..acc]
  }
}

fn parse_params(
  tokens: Toks,
  acc: List(ast.Field),
) -> Result(#(List(ast.Field), Toks), String) {
  case kind(tokens) {
    token.RParen -> Ok(#(list.reverse(acc), tokens))
    _ -> {
      use #(pname, t1) <- result.try(expect_ident(tokens))
      use t2 <- result.try(expect(t1, token.Colon))
      use #(ptype, t3) <- result.try(parse_type_expr(t2))
      let param = ast.Field(pname, ptype)
      case kind(t3) {
        token.Comma -> parse_params(tail(t3), [param, ..acc])
        _ -> Ok(#(list.reverse([param, ..acc]), t3))
      }
    }
  }
}

fn parse_type(tokens: Toks) -> Result(#(ast.Decl, Toks), String) {
  use t1 <- result.try(expect(tokens, token.KwType))
  use #(name, t2) <- result.try(expect_ident(t1))
  use t3 <- result.try(expect(t2, token.LBrace))
  use #(variants, commons, t4) <- result.try(parse_type_items(t3, [], []))
  Ok(#(ast.TypeDecl(name, variants, commons), t4))
}

fn parse_type_items(
  tokens: Toks,
  variants: List(ast.Variant),
  commons: List(ast.Field),
) -> Result(#(List(ast.Variant), List(ast.Field), Toks), String) {
  case kind(tokens) {
    token.RBrace ->
      Ok(#(list.reverse(variants), list.reverse(commons), tail(tokens)))
    _ -> {
      use #(name, t1) <- result.try(expect_ident(tokens))
      case kind(t1) {
        // `Name { ... }` — a variant carrying fields
        token.LBrace -> {
          use #(fields, t2) <- result.try(parse_fields(tail(t1), []))
          parse_type_items(t2, [ast.Variant(name, fields), ..variants], commons)
        }
        // `name: Type` — a common field shared by every variant
        token.Colon -> {
          use #(ftype, t2) <- result.try(parse_type_expr(tail(t1)))
          parse_type_items(t2, variants, [ast.Field(name, ftype), ..commons])
        }
        // `Name` — a bare variant with no fields
        _ -> parse_type_items(t1, [ast.Variant(name, []), ..variants], commons)
      }
    }
  }
}

fn parse_fields(
  tokens: Toks,
  acc: List(ast.Field),
) -> Result(#(List(ast.Field), Toks), String) {
  case kind(tokens) {
    token.RBrace -> Ok(#(list.reverse(acc), tail(tokens)))
    token.Comma -> parse_fields(tail(tokens), acc)
    _ -> {
      use #(fname, t1) <- result.try(expect_ident(tokens))
      use t2 <- result.try(expect(t1, token.Colon))
      use #(ftype, t3) <- result.try(parse_type_expr(t2))
      parse_fields(t3, [ast.Field(fname, ftype), ..acc])
    }
  }
}

fn parse_type_expr(tokens: Toks) -> Result(#(ast.TypeExpr, Toks), String) {
  case kind(tokens) {
    token.KwVoid -> Ok(#(ast.TVoid, tail(tokens)))
    _ -> {
      // A dotted, possibly multi-segment qualified name: `Str`, `hive.Table`,
      // `hive.http.HttpRequest`. The last segment is the type; everything
      // before it (joined by `.`) is the package/namespace path.
      use #(first, t1) <- result.try(expect_ident(tokens))
      use #(segments, t2) <- result.try(collect_type_segments(t1, [first]))
      let #(pkg, name) = split_type_path(segments)
      let #(dims, t3) = parse_dims(t2, [])
      Ok(#(ast.TName(pkg, name, dims), t3))
    }
  }
}

// Consumes further `.ident` segments of a qualified type name.
fn collect_type_segments(
  tokens: Toks,
  acc: List(String),
) -> Result(#(List(String), Toks), String) {
  case kind(tokens) {
    token.Dot -> {
      use #(seg, t1) <- result.try(expect_ident(tail(tokens)))
      collect_type_segments(t1, [seg, ..acc])
    }
    _ -> Ok(#(list.reverse(acc), tokens))
  }
}

// Splits `[hive, http, HttpRequest]` into (Some("hive.http"), "HttpRequest").
fn split_type_path(segments: List(String)) -> #(Option(String), String) {
  case list.reverse(segments) {
    [name] -> #(None, name)
    [name, ..rest] -> #(Some(string.join(list.reverse(rest), ".")), name)
    [] -> #(None, "")
  }
}

// Parses trailing vector markers: `[]`, `[3]`, `[dyn]` or `[dyn, 2]`. A `[`
// that doesn't start a well-formed marker is left in place (it may be an
// index expression instead).
fn parse_dims(tokens: Toks, acc: List(ast.Dim)) -> #(List(ast.Dim), Toks) {
  case kind(tokens) {
    token.LBracket -> {
      let t1 = tail(tokens)
      case kind(t1) {
        token.RBracket -> parse_dims(tail(t1), [ast.DimEmpty, ..acc])
        token.IntLit(n) ->
          case kind(tail(t1)) {
            token.RBracket ->
              parse_dims(tail(tail(t1)), [ast.DimStatic(n), ..acc])
            _ -> #(list.reverse(acc), tokens)
          }
        token.KwDyn -> {
          let t2 = tail(t1)
          case kind(t2) {
            token.RBracket -> parse_dims(tail(t2), [ast.DimDyn(None), ..acc])
            token.Comma ->
              case kind(tail(t2)) {
                token.IntLit(n) ->
                  case kind(tail(tail(t2))) {
                    token.RBracket ->
                      parse_dims(tail(tail(tail(t2))), [
                        ast.DimDyn(Some(n)),
                        ..acc
                      ])
                    _ -> #(list.reverse(acc), tokens)
                  }
                _ -> #(list.reverse(acc), tokens)
              }
            _ -> #(list.reverse(acc), tokens)
          }
        }
        _ -> #(list.reverse(acc), tokens)
      }
    }
    _ -> #(list.reverse(acc), tokens)
  }
}

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

fn parse_block(tokens: Toks) -> Result(#(List(ast.Stmt), Toks), String) {
  use t1 <- result.try(expect(tokens, token.LBrace))
  parse_stmts(t1, [])
}

fn parse_stmts(
  tokens: Toks,
  acc: List(ast.Stmt),
) -> Result(#(List(ast.Stmt), Toks), String) {
  case kind(tokens) {
    token.RBrace -> Ok(#(list.reverse(acc), tail(tokens)))
    token.Semicolon -> parse_stmts(tail(tokens), acc)
    token.Eof -> Error("unexpected end of file inside a block" <> at(tokens))
    _ -> {
      use #(stmt, t1) <- result.try(parse_stmt(tokens))
      parse_stmts(skip_semicolons(t1), [stmt, ..acc])
    }
  }
}

fn skip_semicolons(tokens: Toks) -> Toks {
  case kind(tokens) {
    token.Semicolon -> skip_semicolons(tail(tokens))
    _ -> tokens
  }
}

fn parse_stmt(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  case kind(tokens) {
    token.KwReturn -> parse_return(tokens)
    token.KwIf -> parse_if(tokens)
    token.KwFor -> parse_for(tokens)
    token.KwEcho -> parse_echo(tokens)
    token.KwAssert -> parse_assert(tokens)
    token.KwBreak -> Ok(#(ast.SBreak, tail(tokens)))
    token.KwContinue -> Ok(#(ast.SContinue, tail(tokens)))
    token.KwMut -> parse_mut(tail(tokens))
    token.Ident(name) ->
      case kind(tail(tokens)) {
        token.ColonEq -> {
          use #(value, t2) <- result.try(parse_expr(tail(tail(tokens))))
          Ok(#(ast.SVarDecl(name, value, False), t2))
        }
        _ -> parse_typed_or_expr(tokens)
      }
    _ -> parse_expr_stmt(tokens)
  }
}

// A `mut` declaration: either `mut name := value` (inferred) or
// `mut Type name = value` (annotated). The mutable flag lets the validation
// pass permit later reassignment.
fn parse_mut(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  case kind(tokens), kind(tail(tokens)) {
    token.Ident(name), token.ColonEq -> {
      use #(value, t2) <- result.try(parse_expr(tail(tail(tokens))))
      Ok(#(ast.SVarDecl(name, value, True), t2))
    }
    _, _ -> {
      use #(typ, t1) <- result.try(parse_type_expr(tokens))
      case kind(t1), kind(tail(t1)) {
        token.Ident(vname), token.Assign -> {
          use #(value, t2) <- result.try(parse_expr(tail(tail(t1))))
          Ok(#(ast.STypedDecl(typ, vname, value, True), t2))
        }
        _, _ ->
          Error(
            "expected `name := value` or `Type name = value` after `mut`"
            <> at(tokens),
          )
      }
    }
  }
}

fn parse_echo(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  use #(value, t1) <- result.try(parse_expr(tail(tokens)))
  Ok(#(ast.SEcho(value), t1))
}

fn parse_assert(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  use #(value, t1) <- result.try(parse_expr(tail(tokens)))
  Ok(#(ast.SAssert(value), t1))
}

// An identifier-led statement is either a typed declaration (`Type name =
// value`) or a plain expression statement. Try the declaration form first: it
// only commits if a type expression is followed by `identifier =`.
fn parse_typed_or_expr(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  case parse_type_expr(tokens) {
    Ok(#(typ, t1)) ->
      case kind(t1), kind(tail(t1)) {
        token.Ident(vname), token.Assign -> {
          use #(value, t2) <- result.try(parse_expr(tail(tail(t1))))
          Ok(#(ast.STypedDecl(typ, vname, value, False), t2))
        }
        _, _ -> parse_expr_stmt(tokens)
      }
    Error(_) -> parse_expr_stmt(tokens)
  }
}

// Either a bare expression statement or a reassignment `lvalue = value`. The
// left-hand side is parsed as an ordinary expression (so `v`, `v[0]` and
// `v.field` all work); a trailing `=` promotes it to an assignment.
fn parse_expr_stmt(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  use #(expr, t1) <- result.try(parse_expr(tokens))
  case kind(t1) {
    token.Assign -> {
      use #(value, t2) <- result.try(parse_expr(tail(t1)))
      Ok(#(ast.SAssign(expr, value), t2))
    }
    // Compound assignments `x <op>= v` desugar to `x = x <op> v`; the existing
    // mutability check and (for `/=`) zero-safe division then apply unchanged.
    token.PlusEq -> parse_compound_assign(expr, ast.OpAdd, tail(t1))
    token.MinusEq -> parse_compound_assign(expr, ast.OpSub, tail(t1))
    token.StarEq -> parse_compound_assign(expr, ast.OpMul, tail(t1))
    token.SlashEq -> parse_compound_assign(expr, ast.OpDiv, tail(t1))
    // `x++` / `x--` desugar to `x = x + 1` / `x = x - 1`.
    token.PlusPlus -> Ok(#(compound(expr, ast.OpAdd, ast.EInt(1)), tail(t1)))
    token.MinusMinus -> Ok(#(compound(expr, ast.OpSub, ast.EInt(1)), tail(t1)))
    _ -> Ok(#(ast.SExpr(expr), t1))
  }
}

fn parse_compound_assign(
  target: ast.Expr,
  op: ast.BinOp,
  tokens: Toks,
) -> Result(#(ast.Stmt, Toks), String) {
  use #(value, t1) <- result.try(parse_expr(tokens))
  Ok(#(compound(target, op, value), t1))
}

fn compound(target: ast.Expr, op: ast.BinOp, value: ast.Expr) -> ast.Stmt {
  ast.SAssign(target, ast.EBinary(op, target, value))
}

fn parse_return(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  let t1 = tail(tokens)
  case kind(t1) {
    token.RBrace -> Ok(#(ast.SReturn(None), t1))
    token.Semicolon -> Ok(#(ast.SReturn(None), t1))
    token.Eof -> Ok(#(ast.SReturn(None), t1))
    _ -> {
      use #(expr, t2) <- result.try(parse_expr(t1))
      Ok(#(ast.SReturn(Some(expr)), t2))
    }
  }
}

fn parse_if(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  use t1 <- result.try(expect(tokens, token.KwIf))
  use #(cond, t2) <- result.try(parse_expr(t1))
  use #(body, t3) <- result.try(parse_block(t2))
  parse_if_rest(t3, [ast.Branch(cond, body)])
}

fn parse_if_rest(
  tokens: Toks,
  branches: List(ast.Branch),
) -> Result(#(ast.Stmt, Toks), String) {
  case kind(tokens) {
    token.KwElse ->
      case kind(tail(tokens)) {
        token.KwIf -> {
          use #(cond, t2) <- result.try(parse_expr(tail(tail(tokens))))
          use #(body, t3) <- result.try(parse_block(t2))
          parse_if_rest(t3, [ast.Branch(cond, body), ..branches])
        }
        _ -> {
          use #(else_body, t2) <- result.try(parse_block(tail(tokens)))
          Ok(#(ast.SIf(list.reverse(branches), Some(else_body)), t2))
        }
      }
    _ -> Ok(#(ast.SIf(list.reverse(branches), None), tokens))
  }
}

// A `for` loop, in one of two shapes: the C-style
// `for <init>; <cond>; <post> { }` or the iterating
// `for each name: T in iterable { }`.
fn parse_for(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  let t0 = tail(tokens)
  case kind(t0) {
    token.KwEach -> parse_for_each(tail(t0))
    _ -> parse_for_c(t0)
  }
}

// `for each name in iterable { body }`. The element type is inferred from the
// vector; an optional `name: T` annotation overrides that inference.
fn parse_for_each(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  use #(name, t1) <- result.try(expect_ident(tokens))
  use #(elem_type, t2) <- result.try(case kind(t1) {
    token.Colon -> {
      use #(typ, t) <- result.try(parse_type_expr(tail(t1)))
      Ok(#(Some(typ), t))
    }
    _ -> Ok(#(None, t1))
  })
  use t3 <- result.try(expect(t2, token.KwIn))
  use #(iterable, t4) <- result.try(parse_expr(t3))
  use #(body, t5) <- result.try(parse_block(t4))
  Ok(#(ast.SForEach(name, elem_type, iterable, body), t5))
}

// `for <init>; <cond>; <post> { body }`. Each of the three clauses is
// optional (an empty init/post is just absent, an empty condition loops until
// something else stops it), matching the standard C-style shape.
fn parse_for_c(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  use #(init, t1) <- result.try(case kind(tokens) {
    token.Semicolon -> Ok(#(None, tokens))
    _ -> {
      use #(s, t) <- result.try(parse_for_init(tokens))
      Ok(#(Some(s), t))
    }
  })
  use t2 <- result.try(expect(t1, token.Semicolon))
  use #(cond, t3) <- result.try(case kind(t2) {
    token.Semicolon -> Ok(#(None, t2))
    _ -> {
      use #(e, t) <- result.try(parse_expr(t2))
      Ok(#(Some(e), t))
    }
  })
  use t4 <- result.try(expect(t3, token.Semicolon))
  use #(post, t5) <- result.try(case kind(t4) {
    token.LBrace -> Ok(#(None, t4))
    _ -> {
      use #(s, t) <- result.try(parse_stmt(t4))
      Ok(#(Some(s), t))
    }
  })
  use #(body, t6) <- result.try(parse_block(t5))
  Ok(#(ast.SFor(init, cond, post, body), t6))
}

// The init clause is an ordinary statement, but a variable it declares is
// forced mutable: the loop's post clause advances it (`i = i + 1`), which the
// mutability check would otherwise reject.
fn parse_for_init(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  use #(stmt, rest) <- result.try(parse_stmt(tokens))
  let stmt = case stmt {
    ast.SVarDecl(name, value, _) -> ast.SVarDecl(name, value, True)
    ast.STypedDecl(typ, name, value, _) -> ast.STypedDecl(typ, name, value, True)
    _ -> stmt
  }
  Ok(#(stmt, rest))
}

// ---------------------------------------------------------------------------
// Expressions (precedence climbing)
// ---------------------------------------------------------------------------
// Loosest to tightest: `||`, `&&`, `is`, comparisons, `+`/`-`, `*`/`/`, `**`,
// postfix, primary.

fn parse_expr(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  parse_or(tokens)
}

fn parse_or(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  use #(left, t1) <- result.try(parse_and(tokens))
  parse_or_rest(left, t1)
}

fn parse_or_rest(
  left: ast.Expr,
  tokens: Toks,
) -> Result(#(ast.Expr, Toks), String) {
  case kind(tokens) {
    token.PipePipe -> {
      use #(right, t1) <- result.try(parse_and(tail(tokens)))
      parse_or_rest(ast.EBinary(ast.OpOr, left, right), t1)
    }
    _ -> Ok(#(left, tokens))
  }
}

fn parse_and(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  use #(left, t1) <- result.try(parse_is(tokens))
  parse_and_rest(left, t1)
}

fn parse_and_rest(
  left: ast.Expr,
  tokens: Toks,
) -> Result(#(ast.Expr, Toks), String) {
  case kind(tokens) {
    token.AmpAmp -> {
      use #(right, t1) <- result.try(parse_is(tail(tokens)))
      parse_and_rest(ast.EBinary(ast.OpAnd, left, right), t1)
    }
    _ -> Ok(#(left, tokens))
  }
}

fn parse_is(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  use #(left, t1) <- result.try(parse_comparison(tokens))
  case kind(t1) {
    token.KwIs -> {
      use #(pattern, t2) <- result.try(parse_pattern(tail(t1)))
      Ok(#(ast.EIs(left, pattern), t2))
    }
    // `vector bounds index` is sugar for `index >= 0 && index < len(vector)`.
    // Desugaring here means codegen and the index-safety pass both understand
    // it for free — the bounds checker already mines exactly this shape.
    token.KwBounds -> {
      use #(index, t2) <- result.try(parse_additive(tail(t1)))
      Ok(#(desugar_bounds(left, index), t2))
    }
    _ -> Ok(#(left, t1))
  }
}

fn desugar_bounds(vector: ast.Expr, index: ast.Expr) -> ast.Expr {
  ast.EBinary(
    ast.OpAnd,
    ast.EBinary(ast.OpGe, index, ast.EInt(0)),
    ast.EBinary(
      ast.OpLt,
      index,
      ast.ECall(ast.EIdent("len"), [ast.Arg(None, vector)]),
    ),
  )
}

fn parse_comparison(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  use #(left, t1) <- result.try(parse_additive(tokens))
  case comparison_op(kind(t1)) {
    Some(op) -> {
      use #(right, t2) <- result.try(parse_additive(tail(t1)))
      Ok(#(ast.EBinary(op, left, right), t2))
    }
    None -> Ok(#(left, t1))
  }
}

fn comparison_op(k: token.Kind) -> Option(ast.BinOp) {
  case k {
    token.Gt -> Some(ast.OpGt)
    token.Lt -> Some(ast.OpLt)
    token.Ge -> Some(ast.OpGe)
    token.Le -> Some(ast.OpLe)
    token.EqEq -> Some(ast.OpEq)
    token.NotEq -> Some(ast.OpNeq)
    _ -> None
  }
}

fn parse_additive(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  use #(left, t1) <- result.try(parse_multiplicative(tokens))
  parse_additive_rest(left, t1)
}

fn parse_additive_rest(
  left: ast.Expr,
  tokens: Toks,
) -> Result(#(ast.Expr, Toks), String) {
  case kind(tokens) {
    token.Plus -> {
      use #(right, t1) <- result.try(parse_multiplicative(tail(tokens)))
      parse_additive_rest(ast.EBinary(ast.OpAdd, left, right), t1)
    }
    token.Minus -> {
      use #(right, t1) <- result.try(parse_multiplicative(tail(tokens)))
      parse_additive_rest(ast.EBinary(ast.OpSub, left, right), t1)
    }
    _ -> Ok(#(left, tokens))
  }
}

fn parse_multiplicative(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  use #(left, t1) <- result.try(parse_power(tokens))
  parse_multiplicative_rest(left, t1)
}

fn parse_multiplicative_rest(
  left: ast.Expr,
  tokens: Toks,
) -> Result(#(ast.Expr, Toks), String) {
  case kind(tokens) {
    token.Star -> {
      use #(right, t1) <- result.try(parse_power(tail(tokens)))
      parse_multiplicative_rest(ast.EBinary(ast.OpMul, left, right), t1)
    }
    token.Slash -> {
      use #(right, t1) <- result.try(parse_power(tail(tokens)))
      parse_multiplicative_rest(ast.EBinary(ast.OpDiv, left, right), t1)
    }
    token.Percent -> {
      use #(right, t1) <- result.try(parse_power(tail(tokens)))
      parse_multiplicative_rest(ast.EBinary(ast.OpMod, left, right), t1)
    }
    _ -> Ok(#(left, tokens))
  }
}

// `**` is right-associative: `2 ** 3 ** 2` is `2 ** (3 ** 2)`.
fn parse_power(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  use #(base, t1) <- result.try(parse_with_type(tokens))
  case kind(t1) {
    token.StarStar -> {
      use #(exponent, t2) <- result.try(parse_power(tail(t1)))
      Ok(#(ast.EBinary(ast.OpPow, base, exponent), t2))
    }
    _ -> Ok(#(base, t1))
  }
}

// `expr with Type` — a decode-target annotation (`hive.json.parse(x) with
// User`). Note that `using`'s own `with <delimiter>` is consumed inside
// `parse_using` and never reaches here.
fn parse_with_type(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  use #(value, t1) <- result.try(parse_postfix(tokens))
  case kind(t1) {
    token.KwWith -> {
      use #(typ, t2) <- result.try(parse_type_expr(tail(t1)))
      Ok(#(ast.EWith(value, typ), t2))
    }
    _ -> Ok(#(value, t1))
  }
}

fn parse_postfix(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  use #(primary, t1) <- result.try(parse_primary(tokens))
  parse_postfix_rest(primary, t1)
}

fn parse_postfix_rest(
  expr: ast.Expr,
  tokens: Toks,
) -> Result(#(ast.Expr, Toks), String) {
  case kind(tokens) {
    token.LParen -> {
      use #(args, t1) <- result.try(parse_args(tail(tokens), []))
      parse_postfix_rest(ast.ECall(expr, args), t1)
    }
    token.LBracket -> {
      use #(node, t1) <- result.try(parse_index_or_slice(expr, tail(tokens)))
      parse_postfix_rest(node, t1)
    }
    token.Dot -> {
      use #(name, t1) <- result.try(expect_ident(tail(tokens)))
      parse_postfix_rest(ast.EMember(expr, name), t1)
    }
    _ -> Ok(#(expr, tokens))
  }
}

fn parse_args(
  tokens: Toks,
  acc: List(ast.Arg),
) -> Result(#(List(ast.Arg), Toks), String) {
  case kind(tokens) {
    token.RParen -> Ok(#(list.reverse(acc), tail(tokens)))
    _ -> {
      use #(arg, t1) <- result.try(parse_arg(tokens))
      case kind(t1) {
        token.Comma -> parse_args(tail(t1), [arg, ..acc])
        token.RParen -> Ok(#(list.reverse([arg, ..acc]), tail(t1)))
        other ->
          Error(
            "expected `,` or `)` in argument list but found "
            <> token.describe(other)
            <> at(t1),
          )
      }
    }
  }
}

// An argument is either `name: expr` (named) or a plain expression.
fn parse_arg(tokens: Toks) -> Result(#(ast.Arg, Toks), String) {
  case kind(tokens), kind(tail(tokens)) {
    token.Ident(name), token.Colon -> {
      use #(value, t1) <- result.try(parse_expr(tail(tail(tokens))))
      Ok(#(ast.Arg(Some(name), value), t1))
    }
    _, _ -> {
      use #(value, t1) <- result.try(parse_expr(tokens))
      Ok(#(ast.Arg(None, value), t1))
    }
  }
}

fn parse_index_or_slice(
  target: ast.Expr,
  tokens: Toks,
) -> Result(#(ast.Expr, Toks), String) {
  case kind(tokens) {
    // `[:` ... — slice with no low bound
    token.Colon ->
      case kind(tail(tokens)) {
        token.RBracket ->
          Ok(#(ast.ESlice(target, None, None), tail(tail(tokens))))
        _ -> {
          use #(high, t1) <- result.try(parse_expr(tail(tokens)))
          use t2 <- result.try(expect(t1, token.RBracket))
          Ok(#(ast.ESlice(target, None, Some(high)), t2))
        }
      }
    _ -> {
      use #(low, t1) <- result.try(parse_expr(tokens))
      case kind(t1) {
        token.RBracket -> Ok(#(ast.EIndex(target, low), tail(t1)))
        token.Colon ->
          case kind(tail(t1)) {
            token.RBracket ->
              Ok(#(ast.ESlice(target, Some(low), None), tail(tail(t1))))
            _ -> {
              use #(high, t2) <- result.try(parse_expr(tail(t1)))
              use t3 <- result.try(expect(t2, token.RBracket))
              Ok(#(ast.ESlice(target, Some(low), Some(high)), t3))
            }
          }
        other ->
          Error(
            "expected `]` or `:` in index/slice but found "
            <> token.describe(other)
            <> at(t1),
          )
      }
    }
  }
}

fn parse_primary(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  case kind(tokens) {
    token.IntLit(v) -> Ok(#(ast.EInt(v), tail(tokens)))
    token.FloatLit(v) -> Ok(#(ast.EFloat(v), tail(tokens)))
    token.StringLit(s) -> Ok(#(ast.EString(s), tail(tokens)))
    token.StrInterp(parts) -> parse_interp(parts, line(tokens), tail(tokens))
    token.AtomLit(name) -> Ok(#(ast.EAtom(name), tail(tokens)))
    token.KwTrue -> Ok(#(ast.EBool(True), tail(tokens)))
    token.KwFalse -> Ok(#(ast.EBool(False), tail(tokens)))
    token.Ident(name) -> Ok(#(ast.EIdent(name), tail(tokens)))
    // `await <call>` binds to the postfix expression that follows, so
    // `await f(x)` awaits the whole call.
    token.KwAwait -> {
      use #(inner, t1) <- result.try(parse_postfix(tail(tokens)))
      Ok(#(ast.EAwait(inner), t1))
    }
    token.KwUsing -> parse_using(tokens)
    token.LBracket -> parse_vector(tail(tokens), [])
    token.LParen -> {
      use #(inner, t1) <- result.try(parse_expr(tail(tokens)))
      use t2 <- result.try(expect(t1, token.RParen))
      Ok(#(inner, t2))
    }
    other ->
      Error(
        "unexpected "
        <> token.describe(other)
        <> " in an expression"
        <> at(tokens),
      )
  }
}

fn parse_vector(
  tokens: Toks,
  acc: List(ast.Expr),
) -> Result(#(ast.Expr, Toks), String) {
  case kind(tokens) {
    token.RBracket -> Ok(#(ast.EVector(list.reverse(acc)), tail(tokens)))
    _ -> {
      use #(item, t1) <- result.try(parse_expr(tokens))
      case kind(t1) {
        token.Comma -> parse_vector(tail(t1), [item, ..acc])
        token.RBracket ->
          Ok(#(ast.EVector(list.reverse([item, ..acc])), tail(t1)))
        other ->
          Error(
            "expected `,` or `]` in a vector literal but found "
            <> token.describe(other)
            <> at(t1),
          )
      }
    }
  }
}

// Converts an interpolated string token into an expression by parsing each
// captured `{...}` chunk as a full expression.
fn parse_interp(
  parts: List(token.StrPart),
  line: Int,
  rest: Toks,
) -> Result(#(ast.Expr, Toks), String) {
  use iparts <- result.try(
    list.try_map(parts, fn(p) {
      case p {
        token.SLit(s) -> Ok(ast.ILit(s))
        token.SCode(code) -> {
          use e <- result.try(parse_sub_expr(code, line))
          Ok(ast.IExpr(e))
        }
      }
    }),
  )
  Ok(#(ast.EInterp(iparts), rest))
}

// Parses an embedded expression (from a string interpolation or a query
// body) by re-running the lexer on the captured source.
fn parse_sub_expr(code: String, line: Int) -> Result(ast.Expr, String) {
  use tokens <- result.try(lexer.lex(code))
  use #(e, rest) <- result.try(parse_expr(tokens))
  case kind(rest) {
    token.Eof -> Ok(e)
    other ->
      Error(
        "unexpected "
        <> token.describe(other)
        <> " in interpolated expression `"
        <> code
        <> "` (line "
        <> int.to_string(line)
        <> ")",
      )
  }
}

fn parse_using(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  let t1 = tail(tokens)
  // Operands are parsed at the postfix level so a call (e.g. a `query`
  // producing the SQL for `using conn with theQuery(arg)`) is consumed whole;
  // wrap richer expressions in parentheses. `with` is not a postfix operator,
  // so the path stops cleanly before it.
  use #(path, t2) <- result.try(parse_postfix(t1))
  use #(delim, t3) <- result.try(case kind(t2) {
    token.KwWith -> {
      use #(d, t) <- result.try(parse_postfix(tail(t2)))
      Ok(#(Some(d), t))
    }
    _ -> Ok(#(None, t2))
  })
  Ok(#(ast.EUsing(path, delim), t3))
}

fn parse_pattern(tokens: Toks) -> Result(#(ast.Pattern, Toks), String) {
  case kind(tokens) {
    // `["a", x, ...tail]` — a vector pattern.
    token.LBracket -> parse_vector_pattern(tail(tokens), [])
    // `"/health"` — a string pattern with no holes (an exact match).
    token.StringLit(s) -> Ok(#(ast.PString([ast.SPatLit(s)]), tail(tokens)))
    // `"/api/{id}/{name}/delete"` — a string template pattern.
    token.StrInterp(parts) -> {
      use spats <- result.try(str_pattern_parts(parts, line(tokens)))
      Ok(#(ast.PString(spats), tail(tokens)))
    }
    // `Type.Variant(bindings)` — a constructor pattern.
    _ -> {
      use #(first, t1) <- result.try(expect_ident(tokens))
      use #(path, t2) <- result.try(parse_pattern_path(t1, [first]))
      case kind(t2) {
        token.LParen -> {
          use #(bindings, t3) <- result.try(parse_bindings(tail(t2), []))
          Ok(#(ast.PConstructor(path, bindings), t3))
        }
        _ -> Ok(#(ast.PConstructor(path, []), t2))
      }
    }
  }
}

// A vector pattern's elements, up to the closing `]`. A trailing `...name`
// captures the leftover elements and, per the grammar, may only appear last.
fn parse_vector_pattern(
  tokens: Toks,
  acc: List(ast.PatElem),
) -> Result(#(ast.Pattern, Toks), String) {
  case kind(tokens) {
    token.RBracket -> Ok(#(ast.PVector(list.reverse(acc), None), tail(tokens)))
    token.Ellipsis -> {
      use #(name, t1) <- result.try(expect_ident(tail(tokens)))
      use t2 <- result.try(expect(t1, token.RBracket))
      Ok(#(ast.PVector(list.reverse(acc), Some(name)), t2))
    }
    _ -> {
      use #(elem, t1) <- result.try(parse_pattern_elem(tokens))
      case kind(t1) {
        token.Comma -> parse_vector_pattern(tail(t1), [elem, ..acc])
        token.RBracket ->
          Ok(#(ast.PVector(list.reverse([elem, ..acc]), None), tail(t1)))
        token.Ellipsis ->
          Error(
            "a `...` rest in a vector pattern must be separated from the "
            <> "previous element by a `,`"
            <> at(t1),
          )
        other ->
          Error(
            "expected `,` or `]` in a vector pattern but found "
            <> token.describe(other)
            <> at(t1),
          )
      }
    }
  }
}

// One element of a vector pattern: a literal to match, or a name to bind. A
// bare identifier always *binds* (it introduces a new name), following the
// usual pattern-matching convention; `_` binds nothing.
fn parse_pattern_elem(tokens: Toks) -> Result(#(ast.PatElem, Toks), String) {
  use #(e, t1) <- result.try(parse_expr(tokens))
  case e {
    ast.EString(_)
    | ast.EInt(_)
    | ast.EFloat(_)
    | ast.EBool(_)
    | ast.EAtom(_) -> Ok(#(ast.PElemLit(e), t1))
    ast.EIdent(name) -> Ok(#(ast.PElemBind(name), t1))
    _ ->
      Error(
        "a vector pattern element must be a literal (string, number, boolean "
        <> "or atom) or a binding name"
        <> at(tokens),
      )
  }
}

// Turns an interpolated-string token into the pieces of a string pattern: each
// literal chunk must match verbatim, each `{name}` hole binds a capture. Holes
// must be plain binding names and two holes may not sit side by side (with no
// literal between them the split point would be ambiguous).
fn str_pattern_parts(
  parts: List(token.StrPart),
  line: Int,
) -> Result(List(ast.StrPat), String) {
  use spats <- result.try(
    list.try_map(parts, fn(p) {
      case p {
        token.SLit(s) -> Ok(ast.SPatLit(s))
        token.SCode(code) -> {
          use name <- result.try(hole_name(code, line))
          Ok(ast.SPatHole(name))
        }
      }
    }),
  )
  use _ <- result.try(check_no_adjacent_holes(spats, line))
  Ok(spats)
}

fn hole_name(code: String, line: Int) -> Result(String, String) {
  case string.trim(code) {
    "" ->
      Error(
        "an empty `{}` hole is not allowed in a string pattern (line "
        <> int.to_string(line)
        <> ")",
      )
    trimmed -> {
      use e <- result.try(parse_sub_expr(code, line))
      case e {
        ast.EIdent(name) -> Ok(name)
        _ ->
          Error(
            "a `{...}` hole in a string pattern must be a single binding name, "
            <> "but found `"
            <> trimmed
            <> "` (line "
            <> int.to_string(line)
            <> ")",
          )
      }
    }
  }
}

fn check_no_adjacent_holes(
  parts: List(ast.StrPat),
  line: Int,
) -> Result(Nil, String) {
  case parts {
    [ast.SPatHole(_), ast.SPatHole(_), ..] ->
      Error(
        "two `{...}` holes in a string pattern must be separated by some "
        <> "literal text, otherwise where one ends and the next begins is "
        <> "ambiguous (line "
        <> int.to_string(line)
        <> ")",
      )
    [_, ..rest] -> check_no_adjacent_holes(rest, line)
    [] -> Ok(Nil)
  }
}

fn parse_pattern_path(
  tokens: Toks,
  acc: List(String),
) -> Result(#(List(String), Toks), String) {
  case kind(tokens) {
    token.Dot -> {
      use #(name, t1) <- result.try(expect_ident(tail(tokens)))
      parse_pattern_path(t1, [name, ..acc])
    }
    _ -> Ok(#(list.reverse(acc), tokens))
  }
}

fn parse_bindings(
  tokens: Toks,
  acc: List(String),
) -> Result(#(List(String), Toks), String) {
  case kind(tokens) {
    token.RParen -> Ok(#(list.reverse(acc), tail(tokens)))
    _ -> {
      use #(name, t1) <- result.try(expect_ident(tokens))
      case kind(t1) {
        token.Comma -> parse_bindings(tail(t1), [name, ..acc])
        token.RParen -> Ok(#(list.reverse([name, ..acc]), tail(t1)))
        other ->
          Error(
            "expected `,` or `)` in pattern bindings but found "
            <> token.describe(other)
            <> at(t1),
          )
      }
    }
  }
}
