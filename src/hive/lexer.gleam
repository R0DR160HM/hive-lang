//// The lexer turns Hive source text into a flat list of tokens.
////
//// It skips `//` line comments and whitespace, tracks line numbers for error
//// reporting, and matches keywords case-insensitively (identifiers keep their
//// original spelling).
////
//// Two constructs need light context tracking:
////   * Double-quoted strings may contain `{expression}` interpolations; the
////     expression source is captured raw for the parser to finish.
////   * After the `query` keyword, the `{ ... }` block is raw SQL rather than
////     Hive statements, so it is captured verbatim (dedented, with its own
////     `{param}` interpolations left in place).

import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import hive/token.{type Token, Token}

const alpha = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"

const digits = "0123456789"

/// What the lexer expects next: `AwaitSql` is active between the `query`
/// keyword and its opening `{`, which switches brace handling to raw SQL
/// capture.
type Mode {
  Normal
  AwaitSql
}

/// Lex the whole source. Returns the token list (terminated by `Eof`) or a
/// lexing error message.
pub fn lex(source: String) -> Result(List(Token), String) {
  // Normalise line endings first: Unicode grapheme segmentation treats a CRLF
  // pair as a single grapheme, which would otherwise defeat the newline
  // handling below (and let a `//` comment swallow the whole file).
  let source =
    source
    |> string.replace("\r\n", "\n")
    |> string.replace("\r", "\n")
  do_lex(string.to_graphemes(source), 1, Normal, [])
}

fn do_lex(
  chars: List(String),
  line: Int,
  mode: Mode,
  acc: List(Token),
) -> Result(List(Token), String) {
  case chars {
    [] -> Ok(list.reverse([Token(token.Eof, line), ..acc]))

    // Whitespace
    ["\n", ..rest] -> do_lex(rest, line + 1, mode, acc)
    [" ", ..rest] | ["\t", ..rest] | ["\r", ..rest] ->
      do_lex(rest, line, mode, acc)

    // Comments run to the end of the line (the newline is left in place so the
    // line counter keeps advancing).
    ["/", "/", ..rest] -> do_lex(skip_line(rest), line, mode, acc)

    // String and atom literals
    ["\"", ..rest] -> lex_string(rest, line, mode, acc, [], "")
    ["`", ..rest] -> lex_backtick(rest, line, line, mode, acc, "")
    ["#", ..rest] -> lex_atom(rest, line, mode, acc)

    // A `{` right after a query header opens the raw SQL body.
    ["{", ..rest] ->
      case mode {
        AwaitSql -> lex_sql(rest, line, acc, 1, "")
        Normal -> emit(rest, line, mode, acc, token.LBrace)
      }

    // Two-character operators (must precede their single-character prefixes)
    [":", "=", ..rest] -> emit(rest, line, mode, acc, token.ColonEq)
    [">", "=", ..rest] -> emit(rest, line, mode, acc, token.Ge)
    ["<", "=", ..rest] -> emit(rest, line, mode, acc, token.Le)
    ["=", "=", ..rest] -> emit(rest, line, mode, acc, token.EqEq)
    ["!", "=", ..rest] -> emit(rest, line, mode, acc, token.NotEq)
    ["*", "*", ..rest] -> emit(rest, line, mode, acc, token.StarStar)
    ["&", "&", ..rest] -> emit(rest, line, mode, acc, token.AmpAmp)
    ["|", "|", ..rest] -> emit(rest, line, mode, acc, token.PipePipe)

    // Single-character punctuation and operators
    ["}", ..rest] -> emit(rest, line, mode, acc, token.RBrace)
    ["(", ..rest] -> emit(rest, line, mode, acc, token.LParen)
    [")", ..rest] -> emit(rest, line, mode, acc, token.RParen)
    ["[", ..rest] -> emit(rest, line, mode, acc, token.LBracket)
    ["]", ..rest] -> emit(rest, line, mode, acc, token.RBracket)
    [":", ..rest] -> emit(rest, line, mode, acc, token.Colon)
    [";", ..rest] -> emit(rest, line, mode, acc, token.Semicolon)
    [",", ..rest] -> emit(rest, line, mode, acc, token.Comma)
    [".", ..rest] -> emit(rest, line, mode, acc, token.Dot)
    [">", ..rest] -> emit(rest, line, mode, acc, token.Gt)
    ["<", ..rest] -> emit(rest, line, mode, acc, token.Lt)
    ["=", ..rest] -> emit(rest, line, mode, acc, token.Assign)
    ["+", ..rest] -> emit(rest, line, mode, acc, token.Plus)
    ["-", ..rest] -> emit(rest, line, mode, acc, token.Minus)
    ["*", ..rest] -> emit(rest, line, mode, acc, token.Star)
    ["/", ..rest] -> emit(rest, line, mode, acc, token.Slash)

    // Numbers and identifiers/keywords
    [c, ..] ->
      case is_digit(c), is_ident_start(c) {
        True, _ -> lex_number(chars, line, mode, acc)
        _, True -> lex_ident(chars, line, mode, acc)
        _, _ ->
          Error(
            "unexpected character `"
            <> c
            <> "` on line "
            <> int.to_string(line),
          )
      }
  }
}

fn emit(
  rest: List(String),
  line: Int,
  mode: Mode,
  acc: List(Token),
  kind: token.Kind,
) -> Result(List(Token), String) {
  do_lex(rest, line, mode, [Token(kind, line), ..acc])
}

// ---------------------------------------------------------------------------
// Strings (with `{expression}` interpolation)
// ---------------------------------------------------------------------------

fn lex_string(
  chars: List(String),
  line: Int,
  mode: Mode,
  acc: List(Token),
  parts: List(token.StrPart),
  buf: String,
) -> Result(List(Token), String) {
  case chars {
    [] -> Error("unterminated string literal on line " <> int.to_string(line))
    ["\"", ..rest] -> {
      let tok = case parts {
        [] -> token.StringLit(buf)
        _ -> token.StrInterp(list.reverse(push_lit(parts, buf)))
      }
      do_lex(rest, line, mode, [Token(tok, line), ..acc])
    }
    ["\\", "n", ..rest] -> lex_string(rest, line, mode, acc, parts, buf <> "\n")
    ["\\", "t", ..rest] -> lex_string(rest, line, mode, acc, parts, buf <> "\t")
    ["\\", "r", ..rest] -> lex_string(rest, line, mode, acc, parts, buf <> "\r")
    ["\\", "\"", ..rest] ->
      lex_string(rest, line, mode, acc, parts, buf <> "\"")
    ["\\", "\\", ..rest] ->
      lex_string(rest, line, mode, acc, parts, buf <> "\\")
    // `\{` is a literal brace, not the start of an interpolation.
    ["\\", other, ..rest] ->
      lex_string(rest, line, mode, acc, parts, buf <> other)
    ["{", ..rest] ->
      lex_interp_code(rest, line, mode, acc, push_lit(parts, buf), "")
    ["\n", ..rest] ->
      lex_string(rest, line + 1, mode, acc, parts, buf <> "\n")
    [c, ..rest] -> lex_string(rest, line, mode, acc, parts, buf <> c)
  }
}

fn push_lit(parts: List(token.StrPart), buf: String) -> List(token.StrPart) {
  case buf {
    "" -> parts
    _ -> [token.SLit(buf), ..parts]
  }
}

fn lex_interp_code(
  chars: List(String),
  line: Int,
  mode: Mode,
  acc: List(Token),
  parts: List(token.StrPart),
  code: String,
) -> Result(List(Token), String) {
  case chars {
    [] ->
      Error(
        "unterminated `{` interpolation in a string on line "
        <> int.to_string(line),
      )
    ["}", ..rest] ->
      lex_string(rest, line, mode, acc, [token.SCode(code), ..parts], "")
    ["\n", ..rest] ->
      lex_interp_code(rest, line + 1, mode, acc, parts, code <> "\n")
    [c, ..rest] -> lex_interp_code(rest, line, mode, acc, parts, code <> c)
  }
}

// ---------------------------------------------------------------------------
// Backtick multiline strings
// ---------------------------------------------------------------------------

fn lex_backtick(
  chars: List(String),
  start_line: Int,
  line: Int,
  mode: Mode,
  acc: List(Token),
  buf: String,
) -> Result(List(Token), String) {
  case chars {
    [] ->
      Error(
        "unterminated multiline string starting on line "
        <> int.to_string(start_line),
      )
    ["`", ..rest] ->
      do_lex(rest, line, mode, [
        Token(token.StringLit(dedent(buf)), start_line),
        ..acc
      ])
    ["\n", ..rest] ->
      lex_backtick(rest, start_line, line + 1, mode, acc, buf <> "\n")
    [c, ..rest] -> lex_backtick(rest, start_line, line, mode, acc, buf <> c)
  }
}

// ---------------------------------------------------------------------------
// Atoms
// ---------------------------------------------------------------------------

fn lex_atom(
  chars: List(String),
  line: Int,
  mode: Mode,
  acc: List(Token),
) -> Result(List(Token), String) {
  let #(taken, rest) = take_while(chars, is_ident_continue)
  case taken {
    [] ->
      Error("expected an atom name after `#` on line " <> int.to_string(line))
    _ ->
      do_lex(rest, line, mode, [
        Token(token.AtomLit(string.concat(taken)), line),
        ..acc
      ])
  }
}

// ---------------------------------------------------------------------------
// Query SQL bodies
// ---------------------------------------------------------------------------

// Captures everything between the query's braces verbatim, tracking nested
// braces so `{param}` interpolations stay inside the body.
fn lex_sql(
  chars: List(String),
  line: Int,
  acc: List(Token),
  depth: Int,
  buf: String,
) -> Result(List(Token), String) {
  case chars {
    [] -> Error("unterminated query body on line " <> int.to_string(line))
    ["{", ..rest] -> lex_sql(rest, line, acc, depth + 1, buf <> "{")
    ["}", ..rest] ->
      case depth {
        1 ->
          do_lex(rest, line, Normal, [
            Token(token.SqlBody(dedent(strip_comment_lines(buf))), line),
            ..acc
          ])
        _ -> lex_sql(rest, line, acc, depth - 1, buf <> "}")
      }
    ["\n", ..rest] -> lex_sql(rest, line + 1, acc, depth, buf <> "\n")
    [c, ..rest] -> lex_sql(rest, line, acc, depth, buf <> c)
  }
}

// Hive `//` comments are still allowed inside a query body, but only as whole
// lines: SQL text can legitimately contain `//` mid-line (e.g. inside a URL
// literal), so only lines that *start* with `//` are dropped.
fn strip_comment_lines(text: String) -> String {
  text
  |> string.split("\n")
  |> list.filter(fn(l) { !string.starts_with(string.trim(l), "//") })
  |> string.join("\n")
}

// ---------------------------------------------------------------------------
// Numbers, identifiers, helpers
// ---------------------------------------------------------------------------

fn lex_number(
  chars: List(String),
  line: Int,
  mode: Mode,
  acc: List(Token),
) -> Result(List(Token), String) {
  let #(taken, rest) = take_while(chars, is_digit)
  case rest {
    // A `.` followed by a digit continues into a float literal; any other `.`
    // (e.g. member access) is left for the main loop.
    [".", next, ..] ->
      case is_digit(next) {
        True -> {
          let #(frac, rest2) = take_while(list.drop(rest, 1), is_digit)
          let text = string.concat(taken) <> "." <> string.concat(frac)
          case float.parse(text) {
            Ok(value) ->
              do_lex(rest2, line, mode, [
                Token(token.FloatLit(value), line),
                ..acc
              ])
            Error(_) ->
              Error("invalid float literal on line " <> int.to_string(line))
          }
        }
        False -> lex_int(taken, rest, line, mode, acc)
      }
    _ -> lex_int(taken, rest, line, mode, acc)
  }
}

fn lex_int(
  taken: List(String),
  rest: List(String),
  line: Int,
  mode: Mode,
  acc: List(Token),
) -> Result(List(Token), String) {
  case int.parse(string.concat(taken)) {
    Ok(value) ->
      do_lex(rest, line, mode, [Token(token.IntLit(value), line), ..acc])
    Error(_) -> Error("invalid integer literal on line " <> int.to_string(line))
  }
}

fn lex_ident(
  chars: List(String),
  line: Int,
  mode: Mode,
  acc: List(Token),
) -> Result(List(Token), String) {
  let #(taken, rest) = take_while(chars, is_ident_continue)
  let word = string.concat(taken)
  let kind = keyword_or_ident(word)
  // The body that follows a `query` header is raw SQL, not statements.
  let mode = case kind {
    token.KwQuery -> AwaitSql
    _ -> mode
  }
  do_lex(rest, line, mode, [Token(kind, line), ..acc])
}

fn keyword_or_ident(word: String) -> token.Kind {
  case string.lowercase(word) {
    "proc" -> token.KwProc
    "func" -> token.KwFunc
    "query" -> token.KwQuery
    "type" -> token.KwType
    "if" -> token.KwIf
    "else" -> token.KwElse
    "return" -> token.KwReturn
    "is" -> token.KwIs
    "using" -> token.KwUsing
    "with" -> token.KwWith
    "void" -> token.KwVoid
    "true" -> token.KwTrue
    "false" -> token.KwFalse
    "echo" -> token.KwEcho
    "assert" -> token.KwAssert
    "dyn" -> token.KwDyn
    "mut" -> token.KwMut
    "async" -> token.KwAsync
    "await" -> token.KwAwait
    _ -> token.Ident(word)
  }
}

/// Remove the common leading indentation from every line, dropping leading
/// and trailing blank lines. Used for backtick multiline strings and query
/// bodies, whose indentation is a source-layout artifact ("indentation is
/// removed from multiline strings at compile time").
pub fn dedent(text: String) -> String {
  let lines = string.split(text, "\n")
  let lines = case lines {
    [first, ..rest] ->
      case string.trim(first) {
        "" -> rest
        _ -> lines
      }
    [] -> []
  }
  let lines = case list.reverse(lines) {
    [last, ..rest] ->
      case string.trim(last) {
        "" -> list.reverse(rest)
        _ -> lines
      }
    [] -> []
  }
  let indent =
    lines
    |> list.filter(fn(l) { string.trim(l) != "" })
    |> list.map(leading_ws)
    |> list.reduce(int.min)
    |> result.unwrap(0)
  lines
  |> list.map(fn(l) {
    case string.trim(l) {
      "" -> ""
      _ -> string.drop_start(l, indent)
    }
  })
  |> string.join("\n")
}

fn leading_ws(line: String) -> Int {
  let #(ws, _) =
    take_while(string.to_graphemes(line), fn(c) { c == " " || c == "\t" })
  list.length(ws)
}

fn skip_line(chars: List(String)) -> List(String) {
  case chars {
    [] -> []
    ["\n", ..] -> chars
    [_, ..rest] -> skip_line(rest)
  }
}

fn take_while(
  chars: List(String),
  pred: fn(String) -> Bool,
) -> #(List(String), List(String)) {
  case chars {
    [c, ..rest] ->
      case pred(c) {
        True -> {
          let #(taken, remaining) = take_while(rest, pred)
          #([c, ..taken], remaining)
        }
        False -> #([], chars)
      }
    [] -> #([], [])
  }
}

fn is_digit(c: String) -> Bool {
  string.contains(digits, c)
}

fn is_ident_start(c: String) -> Bool {
  string.contains(alpha, c)
}

fn is_ident_continue(c: String) -> Bool {
  is_ident_start(c) || is_digit(c)
}
