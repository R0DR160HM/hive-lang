//// Tokens produced by the lexer.

/// A token together with the (1-based) source line it starts on, used for
/// error reporting.
pub type Token {
  Token(kind: Kind, line: Int)
}

/// The lexical category of a token.
///
/// Keywords are matched case-insensitively by the lexer (per the language
/// spec: "all keywords are case insensitive"), so by the time a `Kind` is
/// produced the original casing of a keyword no longer matters. Identifiers,
/// on the other hand, keep their original spelling.
pub type Kind {
  // Literals and identifiers
  Ident(String)
  StringLit(String)
  IntLit(Int)

  // Keywords
  KwProc
  KwType
  KwIf
  KwElse
  KwReturn
  KwIs
  KwUsing
  KwWith
  KwAs
  KwVoid
  KwTrue
  KwFalse
  KwEcho

  // Punctuation
  LBrace
  RBrace
  LParen
  RParen
  LBracket
  RBracket
  Colon
  ColonEq
  Semicolon
  Comma
  Dot

  // Operators
  Gt
  Lt
  Ge
  Le
  EqEq
  NotEq
  Assign
  Plus
  Minus
  Star
  Slash

  // End of input
  Eof
}

/// A human-readable description of a token kind, used in parser error
/// messages.
pub fn describe(kind: Kind) -> String {
  case kind {
    Ident(name) -> "identifier `" <> name <> "`"
    StringLit(_) -> "string literal"
    IntLit(_) -> "integer literal"
    KwProc -> "`proc`"
    KwType -> "`type`"
    KwIf -> "`if`"
    KwElse -> "`else`"
    KwReturn -> "`return`"
    KwIs -> "`is`"
    KwUsing -> "`using`"
    KwWith -> "`with`"
    KwAs -> "`as`"
    KwVoid -> "`void`"
    KwTrue -> "`true`"
    KwFalse -> "`false`"
    KwEcho -> "`echo`"
    LBrace -> "`{`"
    RBrace -> "`}`"
    LParen -> "`(`"
    RParen -> "`)`"
    LBracket -> "`[`"
    RBracket -> "`]`"
    Colon -> "`:`"
    ColonEq -> "`:=`"
    Semicolon -> "`;`"
    Comma -> "`,`"
    Dot -> "`.`"
    Gt -> "`>`"
    Lt -> "`<`"
    Ge -> "`>=`"
    Le -> "`<=`"
    EqEq -> "`==`"
    NotEq -> "`!=`"
    Assign -> "`=`"
    Plus -> "`+`"
    Minus -> "`-`"
    Star -> "`*`"
    Slash -> "`/`"
    Eof -> "end of file"
  }
}
