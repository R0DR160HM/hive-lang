//// The lexer turns Hive source text into a flat list of tokens.
////
//// It skips `//` line comments and whitespace, tracks line numbers for error
//// reporting, and matches keywords case-insensitively (identifiers keep their
//// original spelling).

import gleam/int
import gleam/list
import gleam/string
import hive/token.{type Token, Token}

const alpha = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"

const digits = "0123456789"

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
  do_lex(string.to_graphemes(source), 1, [])
}

fn do_lex(
  chars: List(String),
  line: Int,
  acc: List(Token),
) -> Result(List(Token), String) {
  case chars {
    [] -> Ok(list.reverse([Token(token.Eof, line), ..acc]))

    // Whitespace
    ["\n", ..rest] -> do_lex(rest, line + 1, acc)
    [" ", ..rest] -> do_lex(rest, line, acc)
    ["\t", ..rest] -> do_lex(rest, line, acc)
    ["\r", ..rest] -> do_lex(rest, line, acc)

    // Comments run to the end of the line (the newline is left in place so the
    // line counter keeps advancing).
    ["/", "/", ..rest] -> do_lex(skip_line(rest), line, acc)

    // String literals
    ["\"", ..rest] -> lex_string(rest, line, acc, "")

    // Two-character operators (must precede their single-character prefixes)
    [":", "=", ..rest] -> emit(rest, line, acc, token.ColonEq)
    [">", "=", ..rest] -> emit(rest, line, acc, token.Ge)
    ["<", "=", ..rest] -> emit(rest, line, acc, token.Le)
    ["=", "=", ..rest] -> emit(rest, line, acc, token.EqEq)
    ["!", "=", ..rest] -> emit(rest, line, acc, token.NotEq)

    // Single-character punctuation and operators
    ["{", ..rest] -> emit(rest, line, acc, token.LBrace)
    ["}", ..rest] -> emit(rest, line, acc, token.RBrace)
    ["(", ..rest] -> emit(rest, line, acc, token.LParen)
    [")", ..rest] -> emit(rest, line, acc, token.RParen)
    ["[", ..rest] -> emit(rest, line, acc, token.LBracket)
    ["]", ..rest] -> emit(rest, line, acc, token.RBracket)
    [":", ..rest] -> emit(rest, line, acc, token.Colon)
    [";", ..rest] -> emit(rest, line, acc, token.Semicolon)
    [",", ..rest] -> emit(rest, line, acc, token.Comma)
    [".", ..rest] -> emit(rest, line, acc, token.Dot)
    [">", ..rest] -> emit(rest, line, acc, token.Gt)
    ["<", ..rest] -> emit(rest, line, acc, token.Lt)
    ["=", ..rest] -> emit(rest, line, acc, token.Assign)
    ["+", ..rest] -> emit(rest, line, acc, token.Plus)
    ["-", ..rest] -> emit(rest, line, acc, token.Minus)
    ["*", ..rest] -> emit(rest, line, acc, token.Star)
    ["/", ..rest] -> emit(rest, line, acc, token.Slash)

    // Numbers and identifiers/keywords
    [c, ..] ->
      case is_digit(c), is_ident_start(c) {
        True, _ -> lex_number(chars, line, acc)
        _, True -> lex_ident(chars, line, acc)
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
  acc: List(Token),
  kind: token.Kind,
) -> Result(List(Token), String) {
  do_lex(rest, line, [Token(kind, line), ..acc])
}

fn lex_string(
  chars: List(String),
  line: Int,
  acc: List(Token),
  buf: String,
) -> Result(List(Token), String) {
  case chars {
    [] -> Error("unterminated string literal on line " <> int.to_string(line))
    ["\"", ..rest] -> do_lex(rest, line, [Token(token.StringLit(buf), line), ..acc])
    ["\\", "n", ..rest] -> lex_string(rest, line, acc, buf <> "\n")
    ["\\", "t", ..rest] -> lex_string(rest, line, acc, buf <> "\t")
    ["\\", "r", ..rest] -> lex_string(rest, line, acc, buf <> "\r")
    ["\\", "\"", ..rest] -> lex_string(rest, line, acc, buf <> "\"")
    ["\\", "\\", ..rest] -> lex_string(rest, line, acc, buf <> "\\")
    ["\\", other, ..rest] -> lex_string(rest, line, acc, buf <> other)
    ["\n", ..rest] -> lex_string(rest, line + 1, acc, buf <> "\n")
    [c, ..rest] -> lex_string(rest, line, acc, buf <> c)
  }
}

fn lex_number(
  chars: List(String),
  line: Int,
  acc: List(Token),
) -> Result(List(Token), String) {
  let #(taken, rest) = take_while(chars, is_digit)
  case int.parse(string.concat(taken)) {
    Ok(value) -> do_lex(rest, line, [Token(token.IntLit(value), line), ..acc])
    Error(_) -> Error("invalid integer literal on line " <> int.to_string(line))
  }
}

fn lex_ident(
  chars: List(String),
  line: Int,
  acc: List(Token),
) -> Result(List(Token), String) {
  let #(taken, rest) = take_while(chars, is_ident_continue)
  let word = string.concat(taken)
  do_lex(rest, line, [Token(keyword_or_ident(word), line), ..acc])
}

fn keyword_or_ident(word: String) -> token.Kind {
  case string.lowercase(word) {
    "proc" -> token.KwProc
    "type" -> token.KwType
    "if" -> token.KwIf
    "else" -> token.KwElse
    "return" -> token.KwReturn
    "is" -> token.KwIs
    "using" -> token.KwUsing
    "with" -> token.KwWith
    "as" -> token.KwAs
    "void" -> token.KwVoid
    "true" -> token.KwTrue
    "false" -> token.KwFalse
    "echo" -> token.KwEcho
    _ -> token.Ident(word)
  }
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
