//// Tokens produced by the lexer.

/// A token together with the (1-based) source line it starts on, used for
/// error reporting.
pub type Token {
  Token(kind: Kind, line: Int)
}

/// One piece of an interpolated string literal: either literal text or the
/// raw source of an embedded `{expression}`, which the parser finishes
/// parsing.
pub type StrPart {
  SLit(String)
  SCode(String)
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
  StrInterp(List(StrPart))
  IntLit(Int)
  FloatLit(Float)
  AtomLit(String)
  /// The raw body of a `query` declaration: SQL text (already dedented) with
  /// its `{expression}` interpolation markers still in place.
  SqlBody(String)

  // Keywords
  KwProc
  KwFunc
  KwQuery
  KwType
  KwIf
  KwElse
  KwReturn
  KwIs
  KwUsing
  KwWith
  KwVoid
  KwTrue
  KwFalse
  KwEcho
  KwAssert
  KwDyn
  KwMut
  KwAsync
  KwAwait
  KwFor
  KwIn
  KwEach
  KwBounds
  KwBreak
  KwContinue

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
  /// `...` — the rest marker in a vector pattern (`[a, ...tail]`).
  Ellipsis

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
  Percent
  StarStar
  AmpAmp
  PipePipe
  PlusEq
  MinusEq
  StarEq
  SlashEq
  PlusPlus
  MinusMinus

  // End of input
  Eof
}

/// A human-readable description of a token kind, used in parser error
/// messages.
pub fn describe(kind: Kind) -> String {
  case kind {
    Ident(name) -> "identifier `" <> name <> "`"
    StringLit(_) -> "string literal"
    StrInterp(_) -> "interpolated string literal"
    IntLit(_) -> "integer literal"
    FloatLit(_) -> "float literal"
    AtomLit(name) -> "atom `#" <> name <> "`"
    SqlBody(_) -> "query body"
    KwProc -> "`proc`"
    KwFunc -> "`func`"
    KwQuery -> "`query`"
    KwType -> "`type`"
    KwIf -> "`if`"
    KwElse -> "`else`"
    KwReturn -> "`return`"
    KwIs -> "`is`"
    KwUsing -> "`using`"
    KwWith -> "`with`"
    KwVoid -> "`void`"
    KwTrue -> "`true`"
    KwFalse -> "`false`"
    KwEcho -> "`echo`"
    KwAssert -> "`assert`"
    KwDyn -> "`dyn`"
    KwMut -> "`mut`"
    KwAsync -> "`async`"
    KwAwait -> "`await`"
    KwFor -> "`for`"
    KwIn -> "`in`"
    KwEach -> "`each`"
    KwBounds -> "`bounds`"
    KwBreak -> "`break`"
    KwContinue -> "`continue`"
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
    Ellipsis -> "`...`"
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
    Percent -> "`%`"
    StarStar -> "`**`"
    AmpAmp -> "`&&`"
    PipePipe -> "`||`"
    PlusEq -> "`+=`"
    MinusEq -> "`-=`"
    StarEq -> "`*=`"
    SlashEq -> "`/=`"
    PlusPlus -> "`++`"
    MinusMinus -> "`--`"
    Eof -> "end of file"
  }
}
