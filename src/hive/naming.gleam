//// What a name is allowed to look like — and, since the shapes do not
//// overlap, what the way it is written already says it is.
////
////   * `camelCase` — a variable, a parameter, a field, every callable, and the
////     name an `import` is reached through: `userName`, `totalOf`, `main`.
////   * `UPPER_CASE` — a variable that is never reassigned, which is the one
////     thing worth a shape of its own: `MAX_RETRIES` is a constant, and a
////     `mut` variable may not be written that way.
////   * `PascalCase` — a type, a variant of one, and an atom: `User`,
////     `Result.Ok`, `#Ready`. Builtin and declared types are written alike,
////     because there is nothing about `Str` a program should read differently
////     from a type it wrote itself.
////   * lower case — the keywords, and nothing else (see `hive/lexer`).
////
//// So `Str` is a type and `str` is not, `MAX` holds still and `max` may not,
//// and a word in a query body that is neither of these is SQL — which is
//// written in upper case, its own convention rather than Hive's (see
//// `hive/parser`).
////
//// Any name may open with a single `_` — `_scratch`, `_helperOf`, `_MAX` — and
//// what it is written in front of is spelled the same as it would be without
//// it. The compiler asks nothing of the prefix and offers nothing for it: it is
//// a note to whoever reads the name next, saying this one is private, or is
//// here only because something had to be.
////
//// Every rule is enforced where a name is **declared**. That is the one place
//// it can be fixed: a use site spells whatever the declaration did, and a name
//// that was never declared is a different mistake with its own message.

import gleam/list
import gleam/string

const uppers = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

const lowers = "abcdefghijklmnopqrstuvwxyz"

const digits = "0123456789"

/// What a name names. This decides both the shape it must have and how a
/// message about it reads, so there is one of these for each kind of thing
/// Hive lets you name rather than one per shape.
pub type Role {
  /// A `proc`, `func` or `query`.
  Callable
  /// A parameter of one.
  Parameter
  /// A field of a type.
  Field
  /// A variable declared `mut`. It may be reassigned, so it cannot be written
  /// as a constant.
  MutVariable
  /// A variable that is not `mut`: camelCase, or UPPER_CASE for a value the
  /// program treats as a constant.
  Variable
  /// A name bound by a pattern or a `for each`, which is handed a new value
  /// every time it matches or comes round. `_` throws the value away.
  Binding
  /// A type: declared, builtin, or a type variable.
  Type
  /// One variant of a type.
  Variant
  /// An atom, written without its `#`.
  Atom
  /// The name an `import` brings a module in under, and each qualifier segment
  /// in front of a name (`hive.net.HttpRequest`).
  Module
}

/// Check `name` against the shape its role calls for, returning the message to
/// report when it does not fit. The message carries no position: whoever calls
/// this is holding the token, and only they know the line (see
/// `hive/diagnostic`).
pub fn check(role: Role, name: String) -> Result(Nil, String) {
  case fits(role, name) {
    True -> Ok(Nil)
    False -> Error(message(role, name))
  }
}

/// The same question without a message, for a position that accepts more than
/// one role — what stands in front of a name is a module or a type, and either
/// will do.
pub fn fits(role: Role, name: String) -> Bool {
  // The `_` a name may open with says nothing about its shape, so it is set
  // aside before the shape is looked at — and `_` on its own is not a name with
  // a prefix, it is the whole of what a binding says when it wants nothing.
  let bare = unprefixed(name)
  case role {
    Callable | Parameter | Field | MutVariable | Module -> is_camel(bare)
    Variable -> is_camel(bare) || is_screaming(bare)
    Binding -> is_camel(bare) || name == "_"
    Type | Variant | Atom -> is_pascal(bare)
  }
}

fn unprefixed(name: String) -> String {
  case string.starts_with(name, "_") {
    True -> string.drop_start(name, 1)
    False -> name
  }
}

fn message(role: Role, name: String) -> String {
  case role {
    Callable ->
      quoted(name)
      <> " is not how a callable is named. A `proc`, a `func` and a `query` "
      <> "are written in camelCase, like the variable a call's result lands "
      <> "in: "
      <> quoted(to_camel(name))
      <> "."
    Parameter ->
      quoted(name)
      <> " is not how a parameter is named. A parameter is written in "
      <> "camelCase: "
      <> quoted(to_camel(name))
      <> "."
    Field ->
      quoted(name)
      <> " is not how a field is named. A field is written in camelCase: "
      <> quoted(to_camel(name))
      <> "."
    // The one name whose shape is *taken*, rather than merely wrong: it says
    // constant about something the program is about to reassign.
    MutVariable ->
      case is_screaming(name) {
        True ->
          quoted(name)
          <> " is written as a constant, and `mut` says it is not one: "
          <> "UPPER_CASE is for a variable nothing reassigns. Write it in "
          <> "camelCase — "
          <> quoted(to_camel(name))
          <> " — or drop the `mut` if it really does hold still."
        False ->
          quoted(name)
          <> " is not how a variable is named. A variable is written in "
          <> "camelCase: "
          <> quoted(to_camel(name))
          <> "."
      }
    Variable ->
      quoted(name)
      <> " is not how a variable is named. A variable is written in camelCase "
      <> "— "
      <> quoted(to_camel(name))
      <> " — or, when nothing reassigns it, in UPPER_CASE: "
      <> quoted(to_screaming(name))
      <> "."
    Binding ->
      quoted(name)
      <> " is not how a binding is named. A name a pattern or a `for each` "
      <> "binds is written in camelCase — "
      <> quoted(to_camel(name))
      <> " — or `_` to throw the value away."
    Type ->
      quoted(name)
      <> " is not how a type is named. Every type is written in PascalCase, "
      <> "the ones the language declares (`Str`, `Result`) along with your "
      <> "own: "
      <> quoted(to_pascal(name))
      <> "."
    Variant ->
      quoted(name)
      <> " is not how a variant is named. A variant is written in PascalCase, "
      <> "like the type it belongs to: "
      <> quoted(to_pascal(name))
      <> "."
    Atom ->
      "`#"
      <> name
      <> "` is not how an atom is written. An atom is written in PascalCase: "
      <> "`#"
      <> to_pascal(name)
      <> "`."
    Module ->
      quoted(name)
      <> " is not a name a module can be reached through. It is written in "
      <> "camelCase, like the variable it reads as at every use — "
      <> quoted(to_camel(name))
      <> " — which an `import ... as "
      <> to_camel(name)
      <> "` gives it."
  }
}

fn quoted(name: String) -> String {
  "`" <> name <> "`"
}

/// The opening of the message for a keyword written in any casing but its own,
/// which the caller finishes with what its own position can offer instead.
///
/// Two passes report this. The lexer has the keywords it lexes; the parser has
/// the words that are keywords only where they are written (`as`, `run`, `csv`),
/// which never reach the lexer's table at all.
pub fn miscased_keyword(word: String) -> String {
  quoted(word)
  <> " is a keyword written the wrong way: every keyword in Hive is lower case, "
  <> "and only lower case. Write "
  <> quoted(string.lowercase(word))
}

// ---------------------------------------------------------------------------
// The shapes
// ---------------------------------------------------------------------------
// An identifier is only ever ASCII letters, digits and `_` (the lexer takes
// nothing else), so each of these is a first character followed by a rule about
// the rest. `_` is what separates the two conventions: UPPER_CASE is the only
// shape that may hold one.

/// `userName` — a lower-case letter followed by letters and digits.
fn is_camel(name: String) -> Bool {
  case string.to_graphemes(name) {
    [first, ..rest] -> is_lower(first) && list.all(rest, is_alphanumeric)
    [] -> False
  }
}

/// `UserName` — an upper-case letter followed by letters and digits.
fn is_pascal(name: String) -> Bool {
  case string.to_graphemes(name) {
    [first, ..rest] -> is_upper(first) && list.all(rest, is_alphanumeric)
    [] -> False
  }
}

/// `USER_NAME` — upper-case letters, digits and underscores, opening with a
/// letter. A single `A` is both this and PascalCase; nothing needs to tell
/// those two apart, since no position accepts both.
fn is_screaming(name: String) -> Bool {
  case string.to_graphemes(name) {
    [first, ..rest] ->
      is_upper(first)
      && list.all(rest, fn(c) { is_upper(c) || is_digit(c) || c == "_" })
    [] -> False
  }
}

fn is_upper(c: String) -> Bool {
  string.contains(uppers, c)
}

fn is_lower(c: String) -> Bool {
  string.contains(lowers, c)
}

fn is_digit(c: String) -> Bool {
  string.contains(digits, c)
}

fn is_alphanumeric(c: String) -> Bool {
  is_upper(c) || is_lower(c) || is_digit(c)
}

// ---------------------------------------------------------------------------
// Respelling a name
// ---------------------------------------------------------------------------
// What a message offers back. A suggestion only has to be recognisable as the
// name that was written — the point is to show the shape, not to guess at
// better words — so the pieces are whatever the underscores separate, with a
// shouted one quietened first so `MAX_RETRIES` can become `maxRetries`.

/// `user_name` -> `userName`.
pub fn to_camel(name: String) -> String {
  use bare <- respelling(name)
  case pieces(bare) {
    [first, ..rest] ->
      decapitalise(first) <> string.concat(list.map(rest, capitalise))
    [] -> bare
  }
}

/// `user_name` -> `UserName`.
pub fn to_pascal(name: String) -> String {
  use bare <- respelling(name)
  case pieces(bare) {
    [] -> bare
    words -> string.concat(list.map(words, capitalise))
  }
}

/// `userName` -> `USER_NAME`.
pub fn to_screaming(name: String) -> String {
  use bare <- respelling(name)
  list.index_fold(string.to_graphemes(bare), "", fn(acc, c, i) {
    case i > 0 && is_upper(c) && !string.ends_with(acc, "_") {
      True -> acc <> "_" <> c
      False -> acc <> string.uppercase(c)
    }
  })
}

// The `_` a name opens with is part of what was written: a suggestion that
// quietly dropped it would be answering a question nobody asked.
fn respelling(name: String, respell: fn(String) -> String) -> String {
  case string.starts_with(name, "_") {
    True -> "_" <> respell(unprefixed(name))
    False -> respell(name)
  }
}

fn pieces(name: String) -> List(String) {
  name
  |> string.split("_")
  |> list.filter(fn(word) { word != "" })
  |> list.map(quieten)
}

// A piece that is shouted has nothing left to say about where its words divide,
// so it is lower-cased whole and re-cased by whoever asked for it.
fn quieten(word: String) -> String {
  case word == string.uppercase(word) {
    True -> string.lowercase(word)
    False -> word
  }
}

fn capitalise(word: String) -> String {
  case string.pop_grapheme(word) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    Error(_) -> word
  }
}

fn decapitalise(word: String) -> String {
  case string.pop_grapheme(word) {
    Ok(#(first, rest)) -> string.lowercase(first) <> rest
    Error(_) -> word
  }
}
