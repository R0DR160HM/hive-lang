//// A recursive-descent parser turning a token list into an `ast.Module`.
////
//// Each helper consumes tokens from the front of the list and returns the
//// produced node together with the remaining tokens, or an error message.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import hive/ast
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
        "expected an identifier but found " <> token.describe(other) <> at(tokens),
      )
  }
}

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

fn parse_decls(tokens: Toks, acc: List(ast.Decl)) -> Result(List(ast.Decl), String) {
  case kind(tokens) {
    token.Eof -> Ok(list.reverse(acc))
    token.KwProc -> {
      use #(decl, rest) <- result.try(parse_proc(tokens))
      parse_decls(rest, [decl, ..acc])
    }
    token.KwType -> {
      use #(decl, rest) <- result.try(parse_type(tokens))
      parse_decls(rest, [decl, ..acc])
    }
    other ->
      Error(
        "expected `proc` or `type` at the top level but found "
        <> token.describe(other)
        <> at(tokens),
      )
  }
}

fn parse_proc(tokens: Toks) -> Result(#(ast.Decl, Toks), String) {
  use t1 <- result.try(expect(tokens, token.KwProc))
  use #(name, t2) <- result.try(expect_ident(t1))
  use t3 <- result.try(expect(t2, token.LParen))
  use #(params, t4) <- result.try(parse_params(t3, []))
  use t5 <- result.try(expect(t4, token.RParen))
  use t6 <- result.try(expect(t5, token.Colon))
  use #(ret, t7) <- result.try(parse_type_expr(t6))
  use #(body, t8) <- result.try(parse_block(t7))
  Ok(#(ast.ProcDecl(name, params, ret, body), t8))
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
      use #(first, t1) <- result.try(expect_ident(tokens))
      use #(pkg, name, t2) <- result.try(case kind(t1) {
        token.Dot -> {
          use #(second, t2b) <- result.try(expect_ident(tail(t1)))
          Ok(#(Some(first), second, t2b))
        }
        _ -> Ok(#(None, first, t1))
      })
      let #(dims, t3) = count_dims(t2, 0)
      Ok(#(ast.TName(pkg, name, dims), t3))
    }
  }
}

fn count_dims(tokens: Toks, n: Int) -> #(Int, Toks) {
  case kind(tokens) {
    token.LBracket ->
      case kind(tail(tokens)) {
        token.RBracket -> count_dims(tail(tail(tokens)), n + 1)
        _ -> #(n, tokens)
      }
    _ -> #(n, tokens)
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
    token.KwEcho -> parse_echo(tokens)
    token.Ident(name) ->
      case kind(tail(tokens)) {
        token.ColonEq -> {
          use #(value, t2) <- result.try(parse_expr(tail(tail(tokens))))
          Ok(#(ast.SVarDecl(name, value), t2))
        }
        _ -> parse_typed_or_expr(tokens)
      }
    _ -> {
      use #(expr, t1) <- result.try(parse_expr(tokens))
      Ok(#(ast.SExpr(expr), t1))
    }
  }
}

fn parse_echo(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  use #(value, t1) <- result.try(parse_expr(tail(tokens)))
  Ok(#(ast.SEcho(value), t1))
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
          Ok(#(ast.STypedDecl(typ, vname, value), t2))
        }
        _, _ -> parse_expr_stmt(tokens)
      }
    Error(_) -> parse_expr_stmt(tokens)
  }
}

fn parse_expr_stmt(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  use #(expr, t1) <- result.try(parse_expr(tokens))
  Ok(#(ast.SExpr(expr), t1))
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

// ---------------------------------------------------------------------------
// Expressions (precedence climbing)
// ---------------------------------------------------------------------------

fn parse_expr(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  parse_is(tokens)
}

fn parse_is(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  use #(left, t1) <- result.try(parse_comparison(tokens))
  case kind(t1) {
    token.KwIs -> {
      use #(pattern, t2) <- result.try(parse_pattern(tail(t1)))
      Ok(#(ast.EIs(left, pattern), t2))
    }
    _ -> Ok(#(left, t1))
  }
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
  use #(left, t1) <- result.try(parse_postfix(tokens))
  parse_multiplicative_rest(left, t1)
}

fn parse_multiplicative_rest(
  left: ast.Expr,
  tokens: Toks,
) -> Result(#(ast.Expr, Toks), String) {
  case kind(tokens) {
    token.Star -> {
      use #(right, t1) <- result.try(parse_postfix(tail(tokens)))
      parse_multiplicative_rest(ast.EBinary(ast.OpMul, left, right), t1)
    }
    token.Slash -> {
      use #(right, t1) <- result.try(parse_postfix(tail(tokens)))
      parse_multiplicative_rest(ast.EBinary(ast.OpDiv, left, right), t1)
    }
    _ -> Ok(#(left, tokens))
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
  acc: List(ast.Expr),
) -> Result(#(List(ast.Expr), Toks), String) {
  case kind(tokens) {
    token.RParen -> Ok(#(list.reverse(acc), tail(tokens)))
    _ -> {
      use #(arg, t1) <- result.try(parse_expr(tokens))
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

fn parse_index_or_slice(
  target: ast.Expr,
  tokens: Toks,
) -> Result(#(ast.Expr, Toks), String) {
  case kind(tokens) {
    // `[:` ... — slice with no low bound
    token.Colon ->
      case kind(tail(tokens)) {
        token.RBracket -> Ok(#(ast.ESlice(target, None, None), tail(tail(tokens))))
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
    token.StringLit(s) -> Ok(#(ast.EString(s), tail(tokens)))
    token.KwTrue -> Ok(#(ast.EBool(True), tail(tokens)))
    token.KwFalse -> Ok(#(ast.EBool(False), tail(tokens)))
    token.Ident(name) -> Ok(#(ast.EIdent(name), tail(tokens)))
    token.KwUsing -> parse_using(tokens)
    token.LParen -> {
      use #(inner, t1) <- result.try(parse_expr(tail(tokens)))
      use t2 <- result.try(expect(t1, token.RParen))
      Ok(#(inner, t2))
    }
    other ->
      Error(
        "unexpected " <> token.describe(other) <> " in an expression" <> at(tokens),
      )
  }
}

fn parse_using(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  let t1 = tail(tokens)
  use #(path, t2) <- result.try(parse_primary(t1))
  use #(delim, t3) <- result.try(case kind(t2) {
    token.KwWith -> {
      use #(d, t) <- result.try(parse_primary(tail(t2)))
      Ok(#(Some(d), t))
    }
    _ -> Ok(#(None, t2))
  })
  use #(as_name, t4) <- result.try(case kind(t3) {
    token.KwAs -> {
      use #(n, t) <- result.try(expect_ident(tail(t3)))
      Ok(#(Some(n), t))
    }
    _ -> Ok(#(None, t3))
  })
  Ok(#(ast.EUsing(path, delim, as_name), t4))
}

fn parse_pattern(tokens: Toks) -> Result(#(ast.Pattern, Toks), String) {
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
