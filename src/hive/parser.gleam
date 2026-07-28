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
  use #(imports, decls) <- result.try(parse_decls(tokens, [], []))
  Ok(ast.Module(imports, decls))
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
  imports: List(ast.Import),
  acc: List(ast.Decl),
) -> Result(#(List(ast.Import), List(ast.Decl)), String) {
  case kind(tokens) {
    token.Eof -> Ok(#(list.reverse(imports), list.reverse(acc)))
    token.KwImport -> {
      use #(imp, rest) <- result.try(parse_import(tokens))
      parse_decls(rest, [imp, ..imports], acc)
    }
    token.KwProc -> {
      use #(decl, rest) <- result.try(parse_proc(tokens))
      parse_decls(rest, imports, [decl, ..acc])
    }
    token.KwFunc -> {
      use #(decl, rest) <- result.try(parse_func(tokens))
      parse_decls(rest, imports, [decl, ..acc])
    }
    token.KwAsync -> {
      use #(decl, rest) <- result.try(parse_async_func(tokens))
      parse_decls(rest, imports, [decl, ..acc])
    }
    token.KwQuery -> {
      use #(decl, rest) <- result.try(parse_query(tokens))
      parse_decls(rest, imports, [decl, ..acc])
    }
    token.KwType -> {
      use #(decl, rest) <- result.try(parse_type(tokens))
      parse_decls(rest, imports, [decl, ..acc])
    }
    other ->
      Error(
        "expected `import`, `proc`, `func`, `async func`, `query` or `type` at "
        <> "the top level but found "
        <> token.describe(other)
        <> at(tokens),
      )
  }
}

// `import ../lib/strings` or `import ../lib/strings as text`. The lexer has
// already captured the path as one token, so all that is left is the optional
// `as <name>`. Since every other top-level declaration starts with a keyword, a
// bare identifier in that position can only be the `as`.
fn parse_import(tokens: Toks) -> Result(#(ast.Import, Toks), String) {
  let at_line = line(tokens)
  let t0 = tail(tokens)
  use #(path, t1) <- result.try(case kind(t0) {
    token.PathLit(path) -> Ok(#(path, tail(t0)))
    other ->
      Error(
        "expected a module path after `import` but found "
        <> token.describe(other)
        <> at(t0),
      )
  })
  case kind(t1) {
    token.Ident(word) ->
      case string.lowercase(word) {
        "as" -> {
          use #(alias, t2) <- result.try(expect_ident(tail(t1)))
          Ok(#(ast.Import(path, alias, at_line), t2))
        }
        _ ->
          Error(
            "expected `as` or the next declaration after `import "
            <> path
            <> "` but found identifier `"
            <> word
            <> "`"
            <> at(t1),
          )
      }
    _ -> {
      use alias <- result.try(default_alias(path, at_line))
      Ok(#(ast.Import(path, alias, at_line), t1))
    }
  }
}

// Without `as`, a module is named after its file: `../lib/strings` -> `strings`.
// A file name Hive source could not spell as a name needs the explicit form.
fn default_alias(path: String, at_line: Int) -> Result(String, String) {
  let base =
    string.split(path, "/") |> list.last |> result.unwrap("")
  case is_usable_name(base) {
    True -> Ok(base)
    False ->
      Error(
        "`import "
        <> path
        <> "` needs a name of its own: `"
        <> base
        <> "` cannot be used as one — write `import "
        <> path
        <> " as <name>` (line "
        <> int.to_string(at_line)
        <> ")",
      )
  }
}

// Whether a word is something Hive source can write as a name: exactly one
// identifier token, so punctuation and keywords are both rejected. Asking the
// lexer keeps this in step with the real rules.
fn is_usable_name(word: String) -> Bool {
  case lexer.lex(word) {
    Ok([Token(token.Ident(name), _), Token(token.Eof, _)]) -> name == word
    _ -> False
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

// A query body is literal SQL with two things woven through it: `{expression}`
// interpolations, which never enter the text (they become placeholders bound
// alongside it), and `where { ... }` blocks, whose predicates are each present
// or absent at runtime.
//
// The lexer hands the body over as one verbatim string with its braces
// balanced, so the split happens here. A `{` is an interpolation unless the word
// in front of it opened a block.
fn parse_sql_parts(sql: String, line: Int) -> Result(List(ast.SqlPart), String) {
  use #(parts, rest) <- result.try(
    split_sql(string.to_graphemes(sql), line, "", [], False),
  )
  case rest {
    [] -> Ok(parts)
    _ -> Error("unexpected `}` in a query body (line " <> int.to_string(line) <> ")")
  }
}

// Reads SQL until the body ends, or — when `nested` — until the `}` that closes
// the block being read. Returns what it read and whatever is left.
fn split_sql(
  chars: List(String),
  line: Int,
  buf: String,
  acc: List(ast.SqlPart),
  nested: Bool,
) -> Result(#(List(ast.SqlPart), List(String)), String) {
  case chars {
    [] ->
      case nested {
        True ->
          Error(
            "unterminated block in a query body (line "
            <> int.to_string(line)
            <> ")",
          )
        False -> Ok(#(list.reverse(push_sql_lit(buf, acc)), []))
      }
    ["}", ..rest] if nested -> Ok(#(list.reverse(push_sql_lit(buf, acc)), rest))
    ["{", ..rest] -> {
      use #(e, after) <- result.try(take_sql_code(rest, line, ""))
      split_sql(after, line, "", [ast.SqlParam(e), ..push_sql_lit(buf, acc)], nested)
    }
    _ ->
      // A `where` block only starts at a word boundary and only when a `{`
      // follows it — so both `nowhere` and an ordinary `WHERE name = {x}` stay
      // literal SQL.
      case opens_where(chars, buf) {
        True -> {
          let after_kw = list.drop(chars, 5)
          use #(group, rest) <- result.try(parse_group(after_kw, line, True))
          split_sql(
            rest,
            line,
            "",
            [ast.SqlWhere(group), ..push_sql_lit(buf, acc)],
            nested,
          )
        }
        False ->
          case chars {
            [c, ..rest] -> split_sql(rest, line, buf <> c, acc, nested)
            [] -> Ok(#(list.reverse(push_sql_lit(buf, acc)), []))
          }
      }
  }
}

fn opens_where(chars: List(String), buf: String) -> Bool {
  starts_word(chars, "where")
  && ends_word(buf)
  && case skip_space(list.drop(chars, 5)) {
    ["{", ..] -> True
    _ -> False
  }
}

// `{ if <cond> { ... } or { ... } ... }` — the items of one group. `conjunction`
// says how they join; a nested `or`/`and` flips it.
fn parse_group(
  chars: List(String),
  line: Int,
  conjunction: Bool,
) -> Result(#(ast.SqlGroup, List(String)), String) {
  use rest <- result.try(expect_brace(skip_space(chars), line))
  use #(items, after) <- result.try(parse_items(rest, line, []))
  Ok(#(ast.SqlGroup(conjunction, items), after))
}

fn parse_items(
  chars: List(String),
  line: Int,
  acc: List(ast.SqlItem),
) -> Result(#(List(ast.SqlItem), List(String)), String) {
  let chars = skip_space(chars)
  case chars {
    [] ->
      Error(
        "unterminated `where` block in a query body (line "
        <> int.to_string(line)
        <> ")",
      )
    ["}", ..rest] -> Ok(#(list.reverse(acc), rest))
    _ ->
      case starts_word(chars, "if"), starts_word(chars, "or"), starts_word(chars, "and") {
        True, _, _ -> {
          // The condition runs to the `{` that opens the predicate.
          use #(cond_text, after_cond) <- result.try(
            take_until_brace(list.drop(chars, 2), line, ""),
          )
          use cond <- result.try(parse_sub_expr(cond_text, line))
          use #(body, after) <- result.try(
            split_sql(after_cond, line, "", [], True),
          )
          parse_items(after, line, [ast.SqlCond(cond, body), ..acc])
        }
        _, True, _ -> {
          use #(group, after) <- result.try(
            parse_group(list.drop(chars, 2), line, False),
          )
          parse_items(after, line, [ast.SqlNested(group), ..acc])
        }
        _, _, True -> {
          use #(group, after) <- result.try(
            parse_group(list.drop(chars, 3), line, True),
          )
          parse_items(after, line, [ast.SqlNested(group), ..acc])
        }
        _, _, _ ->
          Error(
            "a `where` block holds `if <condition> { ... }` predicates and "
            <> "nested `and { ... }` / `or { ... }` groups; found something "
            <> "else (line "
            <> int.to_string(line)
            <> ")",
          )
      }
  }
}

// The text of an `if` condition: everything up to the `{` that opens its body.
fn take_until_brace(
  chars: List(String),
  line: Int,
  buf: String,
) -> Result(#(String, List(String)), String) {
  case chars {
    [] ->
      Error(
        "expected `{` after an `if` condition in a `where` block (line "
        <> int.to_string(line)
        <> ")",
      )
    ["{", ..rest] -> Ok(#(buf, rest))
    [c, ..rest] -> take_until_brace(rest, line, buf <> c)
  }
}

fn expect_brace(chars: List(String), line: Int) -> Result(List(String), String) {
  case chars {
    ["{", ..rest] -> Ok(rest)
    _ ->
      Error(
        "expected `{` to open a `where` group (line "
        <> int.to_string(line)
        <> ")",
      )
  }
}

fn skip_space(chars: List(String)) -> List(String) {
  case chars {
    [" ", ..rest] | ["\t", ..rest] | ["\n", ..rest] | ["\r", ..rest] ->
      skip_space(rest)
    _ -> chars
  }
}

// Whether `chars` begins with `word` (case-insensitively) followed by something
// that is not a word character — so `and` matches but `android` does not.
fn starts_word(chars: List(String), word: String) -> Bool {
  let n = string.length(word)
  let head =
    chars |> list.take(n) |> string.concat |> string.lowercase
  case head == word {
    False -> False
    True ->
      case list.drop(chars, n) {
        [] -> True
        [c, ..] -> !is_word_char(c)
      }
  }
}

// Whether what has been read so far ends at a word boundary, so a keyword
// starting here really is one.
fn ends_word(buf: String) -> Bool {
  case string.last(buf) {
    Error(_) -> True
    Ok(c) -> !is_word_char(c)
  }
}

fn is_word_char(c: String) -> Bool {
  case c {
    "_" -> True
    _ -> string.lowercase(c) != string.uppercase(c) || is_digit(c)
  }
}

fn is_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn take_sql_code(
  chars: List(String),
  line: Int,
  code: String,
) -> Result(#(ast.Expr, List(String)), String) {
  case chars {
    [] ->
      Error(
        "unterminated `{` interpolation in a query body (line "
        <> int.to_string(line)
        <> ")",
      )
    ["}", ..rest] -> {
      use e <- result.try(parse_sub_expr(code, line))
      Ok(#(e, rest))
    }
    [c, ..rest] -> take_sql_code(rest, line, code <> c)
  }
}

fn push_sql_lit(buf: String, acc: List(ast.SqlPart)) -> List(ast.SqlPart) {
  case buf {
    "" -> acc
    _ -> [ast.SqlLit(buf), ..acc]
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
    // A function type mirrors a declaration with the name dropped:
    // `func(Int, Str): Bool` / `proc(Req): Resp`.
    token.KwFunc -> parse_fn_type(tail(tokens), True)
    token.KwProc -> parse_fn_type(tail(tokens), False)
    _ -> {
      // A dotted, possibly multi-segment qualified name: `Str`, `hive.Table`,
      // `hive.net.HttpRequest`. The last segment is the type; everything
      // before it (joined by `.`) is the package/namespace path.
      use #(first, t1) <- result.try(expect_ident(tokens))
      use #(segments, t2) <- result.try(collect_type_segments(t1, [first]))
      let #(pkg, name) = split_type_path(segments)
      use #(args, t3) <- result.try(parse_type_args(t2))
      let #(dims, t4) = parse_dims(t3, [])
      Ok(#(ast.TName(pkg, name, args, dims), t4))
    }
  }
}

// A function type: the opening keyword is already consumed. Parses
// `(T1, T2, ...): Ret`.
fn parse_fn_type(
  tokens: Toks,
  pure: Bool,
) -> Result(#(ast.TypeExpr, Toks), String) {
  use t1 <- result.try(expect(tokens, token.LParen))
  use #(params, t2) <- result.try(parse_type_list(t1, []))
  use t3 <- result.try(expect(t2, token.Colon))
  use #(ret, t4) <- result.try(parse_type_expr(t3))
  Ok(#(ast.TFunc(pure, params, ret), t4))
}

// A comma-separated list of type expressions ending at `)`.
fn parse_type_list(
  tokens: Toks,
  acc: List(ast.TypeExpr),
) -> Result(#(List(ast.TypeExpr), Toks), String) {
  case kind(tokens) {
    token.RParen -> Ok(#(list.reverse(acc), tail(tokens)))
    _ -> {
      use #(typ, t1) <- result.try(parse_type_expr(tokens))
      case kind(t1) {
        token.Comma -> parse_type_list(tail(t1), [typ, ..acc])
        token.RParen -> Ok(#(list.reverse([typ, ..acc]), tail(t1)))
        other ->
          Error(
            "expected `,` or `)` in a function type's parameters but found "
            <> token.describe(other)
            <> at(t1),
          )
      }
    }
  }
}

// Parses `<A, B>` type arguments, if present. Angle brackets only ever appear in
// a type position, so there is no ambiguity with the comparison operators.
fn parse_type_args(tokens: Toks) -> Result(#(List(ast.TypeExpr), Toks), String) {
  case kind(tokens) {
    token.Lt -> parse_type_args_rest(tail(tokens), [])
    _ -> Ok(#([], tokens))
  }
}

fn parse_type_args_rest(
  tokens: Toks,
  acc: List(ast.TypeExpr),
) -> Result(#(List(ast.TypeExpr), Toks), String) {
  use #(arg, t1) <- result.try(parse_type_expr(tokens))
  case kind(t1) {
    token.Comma -> parse_type_args_rest(tail(t1), [arg, ..acc])
    token.Gt -> Ok(#(list.reverse([arg, ..acc]), tail(t1)))
    other ->
      Error(
        "expected `,` or `>` in type arguments but found "
        <> token.describe(other)
        <> at(t1),
      )
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

// Splits `[hive, net, HttpRequest]` into (Some("hive.net"), "HttpRequest").
fn split_type_path(segments: List(String)) -> #(Option(String), String) {
  case list.reverse(segments) {
    [name] -> #(None, name)
    [name, ..rest] -> #(Some(string.join(list.reverse(rest), ".")), name)
    [] -> #(None, "")
  }
}

// Parses trailing vector markers: `[]`, `[3]` or `[dyn]`. A `[` that doesn't
// start a well-formed marker is left in place (it may be an index expression
// instead).
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
        token.KwDyn ->
          case kind(tail(t1)) {
            token.RBracket -> parse_dims(tail(tail(t1)), [ast.DimDyn, ..acc])
            _ -> #(list.reverse(acc), tokens)
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
    token.KwPanic -> parse_panic(tokens)
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

fn parse_panic(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  use #(value, t1) <- result.try(parse_expr(tail(tokens)))
  Ok(#(ast.SPanic(value), t1))
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
  use #(left, t1) <- result.try(parse_unary(tokens))
  parse_multiplicative_rest(left, t1)
}

fn parse_multiplicative_rest(
  left: ast.Expr,
  tokens: Toks,
) -> Result(#(ast.Expr, Toks), String) {
  case kind(tokens) {
    token.Star -> {
      use #(right, t1) <- result.try(parse_unary(tail(tokens)))
      parse_multiplicative_rest(ast.EBinary(ast.OpMul, left, right), t1)
    }
    token.Slash -> {
      use #(right, t1) <- result.try(parse_unary(tail(tokens)))
      parse_multiplicative_rest(ast.EBinary(ast.OpDiv, left, right), t1)
    }
    token.Percent -> {
      use #(right, t1) <- result.try(parse_unary(tail(tokens)))
      parse_multiplicative_rest(ast.EBinary(ast.OpMod, left, right), t1)
    }
    _ -> Ok(#(left, tokens))
  }
}

// Prefix `-`. It binds tighter than `* / %` but looser than `**`, which is the
// conventional arithmetic reading: `-2 ** 2` is `-(2 ** 2)`, while `2 * -3` and
// `2 ** -3` both put the minus on the operand it is written against.
//
// Applied to a numeric literal the sign is folded straight into the literal, so
// `-3` is one `EInt(-3)` rather than a subtraction — which is what lets a
// negative literal be recognised as one everywhere downstream (the bounds pass
// in particular reasons about literal indexes). Anything else negates by
// subtracting from zero, so no unary node is needed in the AST.
fn parse_unary(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  case kind(tokens) {
    token.Minus -> {
      use #(operand, t1) <- result.try(parse_unary(tail(tokens)))
      case operand {
        ast.EInt(v) -> Ok(#(ast.EInt(0 - v), t1))
        ast.EFloat(v) -> Ok(#(ast.EFloat(0.0 -. v), t1))
        _ -> Ok(#(ast.EBinary(ast.OpSub, ast.EInt(0), operand), t1))
      }
    }
    _ -> parse_power(tokens)
  }
}

// `**` is right-associative: `2 ** 3 ** 2` is `2 ** (3 ** 2)`. Its exponent is
// parsed at the unary level so `2 ** -3` reads the sign as part of the exponent.
fn parse_power(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  use #(base, t1) <- result.try(parse_with_type(tokens))
  case kind(t1) {
    token.StarStar -> {
      use #(exponent, t2) <- result.try(parse_unary(tail(t1)))
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
    token.KwWith ->
      // Two unrelated clauses share the `with` keyword. `with timeout <ms>`
      // bounds an `await`; anything else names a decode target. They are told
      // apart here so `timeout` never gets read as a type name — and so
      // `timeout` stays a perfectly ordinary identifier everywhere else.
      case is_timeout_word(tail(t1)) {
        True -> {
          // Parsed at the arithmetic level, not as a full expression: the clause
          // has to stop before `is` and `&&`, so
          // `await h with timeout 500 is Result.Ok(v)` reads as
          // `(await h with timeout 500) is Result.Ok(v)` rather than folding the
          // comparison into the millisecond count. `with timeout base * 2` still
          // works.
          use #(ms, t2) <- result.try(parse_additive(tail(tail(t1))))
          case value {
            ast.EAwait(inner, None) -> Ok(#(ast.EAwait(inner, Some(ms)), t2))
            ast.EAwait(_, Some(_)) ->
              Error("this `await` already has a `with timeout` clause")
            _ ->
              Error(
                "`with timeout <ms>` may only follow an `await` — it bounds how "
                <> "long the wait may take",
              )
          }
        }
        False -> {
          use #(typ, t2) <- result.try(parse_type_expr(tail(t1)))
          Ok(#(ast.EWith(value, typ), t2))
        }
      }
    _ -> Ok(#(value, t1))
  }
}

// `timeout` in `with timeout <ms>`. Matched case-insensitively like every other
// keyword, but deliberately not lexed as one: making it a reserved word would
// stop anyone naming a variable `timeout`, and this is the only position where
// the spelling means anything.
fn is_timeout_word(tokens: Toks) -> Bool {
  case kind(tokens) {
    token.Ident(name) -> string.lowercase(name) == "timeout"
    _ -> False
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
      Ok(#(ast.EAwait(inner, None), t1))
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

// `using <path>`, `using <path> as csv [separating by <sep>]`,
// `using <path> as xlsx`, `using <path> as ods`, or
// `using <connection> run <query>`.
//
// `as`, `csv`, `xlsx`, `ods`, `separating`, `by` and `run` are matched as plain
// words rather than keywords, so a variable or proc named `run` or `by` still
// works everywhere else in the language.
fn parse_using(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  let t1 = tail(tokens)
  // Operands are parsed at the postfix level so a call (e.g. a `query` producing
  // the SQL for `using conn run theQuery(arg)`) is consumed whole; wrap richer
  // expressions in parentheses. None of the words below is a postfix operator,
  // so the source expression stops cleanly before them.
  use #(source, t2) <- result.try(parse_postfix(t1))
  case kind(t2), word(t2) {
    // `using ... with ...` used to mean both a CSV delimiter and a SQL query,
    // told apart by the source's type. Both now say which they are.
    token.KwWith, _ ->
      Error(
        "`using ... with ...` has been split into two forms that each name what "
        <> "they read: `using <path> as csv separating by <separator>` for a "
        <> "delimited file, and `using <connection> run <query>` for SQL"
        <> at(t2),
      )
    _, Some("as") -> parse_using_format(source, tail(t2))
    _, Some("run") -> {
      let t3 = tail(t2)
      case word(t3) {
        // `run raw <text>` runs SQL assembled at runtime. Saying so is the
        // point: it is the one form whose shape nothing can be known about, and
        // spelling it out makes every such place greppable.
        Some("raw") -> {
          use #(text, t4) <- result.try(parse_postfix(tail(t3)))
          Ok(#(ast.EUsing(source, ast.UsingRaw(text)), t4))
        }
        _ -> {
          use #(query, t4) <- result.try(parse_postfix(t3))
          Ok(#(ast.EUsing(source, ast.UsingQuery(query)), t4))
        }
      }
    }
    // Bare `using <path>` is a comma-separated CSV.
    _, _ -> Ok(#(ast.EUsing(source, ast.UsingCsv(None)), t2))
  }
}

// The format word after `as`, plus `separating by <sep>` when the format is csv.
fn parse_using_format(
  source: ast.Expr,
  tokens: Toks,
) -> Result(#(ast.Expr, Toks), String) {
  case word(tokens) {
    Some("csv") -> {
      let t1 = tail(tokens)
      case word(t1) {
        Some("separating") ->
          case word(tail(t1)) {
            Some("by") -> {
              use #(separator, t2) <- result.try(parse_postfix(tail(tail(t1))))
              Ok(#(ast.EUsing(source, ast.UsingCsv(Some(separator))), t2))
            }
            _ ->
              Error(
                "expected `by` after `separating`"
                <> at(tail(t1)),
              )
          }
        _ -> Ok(#(ast.EUsing(source, ast.UsingCsv(None)), t1))
      }
    }
    Some("xlsx") -> Ok(#(ast.EUsing(source, ast.UsingXlsx), tail(tokens)))
    Some("ods") -> Ok(#(ast.EUsing(source, ast.UsingOds), tail(tokens)))
    Some(other) ->
      Error(
        "`using ... as "
        <> other
        <> "` is not a table format (expected `csv`, `xlsx` or `ods`)"
        <> at(tokens),
      )
    None ->
      Error(
        "expected a table format after `as` (`csv`, `xlsx` or `ods`) but found "
        <> token.describe(kind(tokens))
        <> at(tokens),
      )
  }
}

// The identifier at the front of `tokens`, lowercased — the language matches its
// keywords case-insensitively, and these words follow suit.
fn word(tokens: Toks) -> Option(String) {
  case kind(tokens) {
    token.Ident(name) -> Some(string.lowercase(name))
    _ -> None
  }
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
