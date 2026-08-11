//// A recursive-descent parser turning a token list into an `ast.Module`.
////
//// Each helper consumes tokens from the front of the list and returns the
//// produced node together with the remaining tokens, or an error message.
////
//// It is also where a name's spelling is held to the rules in `hive/naming`.
//// This is the pass that knows what a name *is* — the same identifier token is
//// a type in one position and a field in the next — and the last one holding
//// the line to report it against.

import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import hive/ast
import hive/builtins
import hive/diagnostic
import hive/imports
import hive/lexer
import hive/naming
import hive/token.{type Token, Token}

type Toks =
  List(Token)

pub fn parse(tokens: Toks) -> Result(ast.Module, String) {
  use #(imports, decls) <- result.try(parse_decls(tokens, [], []))
  Ok(ast.Module(imports, decls, dict.new(), []))
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

/// Report `message` against the line the next token starts on. Every error the
/// parser raises goes through here, so each one leaves already carrying its
/// position — see `hive/diagnostic` for the shape and why it is written rather
/// than recovered.
fn at(tokens: Toks, message: String) -> String {
  diagnostic.at(line(tokens), message)
}

fn expect(tokens: Toks, k: token.Kind) -> Result(Toks, String) {
  case kind(tokens) == k {
    True -> Ok(tail(tokens))
    False ->
      Error(at(
        tokens,
        "expected "
          <> token.describe(k)
          <> " but found "
          <> token.describe(kind(tokens)),
      ))
  }
}

fn expect_ident(tokens: Toks) -> Result(#(String, Toks), String) {
  case kind(tokens) {
    token.Ident(name) -> Ok(#(name, tail(tokens)))
    other ->
      Error(at(
        tokens,
        "expected an identifier but found " <> token.describe(other),
      ))
  }
}

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

// The same identifier token is a type in one position and a field in the next,
// so which shape it has to have is decided here, where the position is known —
// and reported against the token itself, which is the last place its line is
// still in hand.
fn expect_name(
  tokens: Toks,
  role: naming.Role,
) -> Result(#(String, Toks), String) {
  use #(name, rest) <- result.try(expect_ident(tokens))
  use _ <- result.try(named(tokens, role, name))
  Ok(#(name, rest))
}

fn named(tokens: Toks, role: naming.Role, name: String) -> Result(Nil, String) {
  naming.check(role, name) |> result.map_error(at(tokens, _))
}

// Every name a type expression carries. Types are checked from here rather than
// inside `parse_type_expr`, which is also asked to read things that turn out not
// to be types at all (see `parse_typed_or_expr`) and whose failure there has to
// stay an ordinary one — so the check happens where the type is committed to.
fn check_type(typ: ast.TypeExpr, tokens: Toks) -> Result(Nil, String) {
  case typ {
    ast.TVoid -> Ok(Nil)
    ast.TFunc(_, params, ret) -> {
      use _ <- result.try(check_types(params, tokens))
      check_type(ret, tokens)
    }
    ast.TName(pkg, name, args, _) -> {
      use _ <- result.try(case pkg {
        Some(path) -> check_qualifier(string.split(path, "."), tokens)
        None -> Ok(Nil)
      })
      use _ <- result.try(named(tokens, naming.Type, name))
      check_types(args, tokens)
    }
  }
}

fn check_types(types: List(ast.TypeExpr), tokens: Toks) -> Result(Nil, String) {
  list.try_map(types, check_type(_, tokens)) |> result.replace(Nil)
}

// What stands in front of a name: the module it was imported as
// (`hive.net.HttpRequest`), and — in a pattern — the type a variant belongs to
// (`Result.Ok`). Both spellings are allowed in front, since only the last
// segment says which of the two the qualifier was.
fn check_qualifier(segments: List(String), tokens: Toks) -> Result(Nil, String) {
  list.try_map(segments, fn(segment) {
    case
      naming.fits(naming.Module, segment) || naming.fits(naming.Type, segment)
    {
      True -> Ok(Nil)
      False ->
        Error(at(
          tokens,
          "`"
            <> segment
            <> "` is neither a module nor a type, and what stands in front of a "
            <> "name is one or the other: a module in camelCase "
            <> "(`hive.sql.SqlError`) or the type a variant belongs to in "
            <> "PascalCase (`Result.Ok`).",
        ))
    }
  })
  |> result.replace(Nil)
}

// A word that is a keyword only where it is written — `as`, `run`, `raw`, `csv`
// — is matched by the parser rather than lexed, which is what keeps `run` and
// `by` usable as names everywhere else. The lexer's rule that a keyword is lower
// case cannot reach those, so it is applied here, in the positions where nothing
// but the keyword could have been meant.
fn miscased(word: String, want: String) -> Bool {
  word != want && string.lowercase(word) == want
}

// What to say about the word standing where `want` had to be: that it is `want`
// shouted, or `otherwise` when it is something else entirely.
fn expected_word(
  found: Option(String),
  want: String,
  otherwise: String,
) -> String {
  case found {
    Some(word) ->
      case miscased(word, want) {
        True -> naming.miscased_keyword(word) <> "."
        False -> otherwise
      }
    None -> otherwise
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
    // `async` used to be a declaration modifier. Nothing about a declaration
    // decides how it runs any more, so the word only means something at a call.
    token.KwAsync ->
      Error(at(
        tokens,
        "`async` is not part of a declaration: every func and proc blocks its "
          <> "caller, and `async` is written at the *call* instead — `async "
          <> "slowThing(x)` runs it on its own virtual thread and does not wait. "
          <> "Declare this one as a plain `func`.",
      ))
    token.KwQuery -> {
      use #(decl, rest) <- result.try(parse_query(tokens))
      parse_decls(rest, imports, [decl, ..acc])
    }
    token.KwType -> {
      use #(decl, rest) <- result.try(parse_type(tokens))
      parse_decls(rest, imports, [decl, ..acc])
    }
    token.KwTest -> {
      use #(decl, rest) <- result.try(parse_test(tokens))
      parse_decls(rest, imports, [decl, ..acc])
    }
    other ->
      Error(at(
        tokens,
        "expected `import`, `proc`, `func`, `query`, `type` or `test` at "
          <> "the top level but found "
          <> token.describe(other),
      ))
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
      Error(at(
        t0,
        "expected a module path after `import` but found "
          <> token.describe(other),
      ))
  })
  case kind(t1) {
    token.Ident(word) ->
      case word {
        "as" -> {
          use #(alias, t2) <- result.try(expect_name(tail(t1), naming.Module))
          Ok(#(ast.Import(path, alias, at_line), t2))
        }
        // Nothing but `as` can follow a path, so a word that is `as` shouted is
        // that, rather than a name that has turned up in an impossible place.
        _ ->
          case miscased(word, "as") {
            True -> Error(at(t1, naming.miscased_keyword(word) <> "."))
            False ->
              Error(at(
                t1,
                "expected `as` or the next declaration after `import "
                  <> path
                  <> "` but found identifier `"
                  <> word
                  <> "`",
              ))
          }
      }
    _ -> {
      use alias <- result.try(default_alias(path, at_line))
      Ok(#(ast.Import(path, alias, at_line), t1))
    }
  }
}

// Without `as`, a module is named after its file: `../lib/strings` -> `strings`.
// A file name Hive source could not spell as a name needs the explicit form.
//
// A standard library module is named after its own last segment instead
// (`import hive.ui` -> `ui`), since it has no file to be named after and that
// segment is already the name every unaliased mention of it uses.
fn default_alias(path: String, at_line: Int) -> Result(String, String) {
  use <- bool.guard(
    builtins.names_stdlib(path),
    // Whether it names a real module is `hive/modules`' question rather than
    // this one's, so even a misspelt one is named here and reported there —
    // where the answer can list the modules that do exist.
    Ok(string.split(path, ".") |> list.last |> result.unwrap(path)),
  )
  // A remote import is named after the file *inside* the repository, not after
  // the repository or its host: `.../hive-lang/src/text` is `text`, the same name
  // `./src/text` next door would have had. Asking what the path names is also
  // where a URL that names no file at all is caught, which is a better answer
  // than a name derived from a path that was never one.
  use inside <- result.try(case imports.classify(path) {
    Ok(imports.RemoteHive(_, inside)) | Ok(imports.RemoteGo(_, inside)) ->
      Ok(inside)
    Ok(_) -> Ok(path)
    Error(why) -> Error(diagnostic.at(at_line, why))
  })
  // A Go import writes its extension (`./util.go`), and the module is named
  // after the file either way — so the extension comes off before the name is
  // read, exactly as a `.hive` one was never written at all.
  let base =
    string.split(inside, "/")
    |> list.last
    |> result.unwrap("")
    |> strip_go
  case is_usable_name(base) {
    True -> {
      // A file whose name is not a name — `String_Utils.hive` — needs the
      // explicit form too: what it would be reached through has to read like
      // any other name in the program.
      use _ <- result.try(
        naming.check(naming.Module, base)
        |> result.map_error(diagnostic.at(at_line, _)),
      )
      Ok(base)
    }
    False ->
      Error(diagnostic.at(
        at_line,
        "`import "
          <> path
          <> "` needs a name of its own: `"
          <> base
          <> "` cannot be used as one — write `import "
          <> path
          <> " as <name>`",
      ))
  }
}

fn strip_go(base: String) -> String {
  case string.ends_with(base, ".go") {
    True -> string.drop_end(base, 3)
    False -> base
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
  use #(name, t2) <- result.try(expect_name(t1, naming.Callable))
  use t3 <- result.try(expect(t2, token.LParen))
  use #(params, t4) <- result.try(parse_params(t3, []))
  use t5 <- result.try(expect(t4, token.RParen))
  use t6 <- result.try(expect(t5, token.Colon))
  use #(ret, t7) <- result.try(parse_type_expr(t6))
  use _ <- result.try(check_type(ret, t6))
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
  Ok(#(ast.FuncDecl(name, params, ret, body), t2))
}

// `test "what should be true" { ... }`. The name is a string rather than an
// identifier because it is prose, not something anything calls: a test takes no
// parameters and returns nothing, so there is no signature to write and no call
// site to write one for.
fn parse_test(tokens: Toks) -> Result(#(ast.Decl, Toks), String) {
  let at_line = line(tokens)
  let t0 = tail(tokens)
  use #(name, t1) <- result.try(case kind(t0) {
    token.StringLit(name) -> Ok(#(name, tail(t0)))
    // An interpolated name would have to be built at runtime, and a test's name
    // is chosen when it is written.
    token.StrInterp(_) ->
      Error(at(
        t0,
        "a test's name is a plain string: it says what should be true, so there "
          <> "is nothing in it to interpolate",
      ))
    other ->
      Error(at(
        t0,
        "expected a test name in quotes (`test \"an empty cart costs nothing\" "
          <> "{ ... }`) but found "
          <> token.describe(other),
      ))
  })
  use #(body, t2) <- result.try(parse_block(t1))
  Ok(#(ast.TestDecl(name, body, "", at_line), t2))
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
      Error(at(
        t1,
        "expected a `{ ...SQL... }` body for query `"
          <> name
          <> "` but found "
          <> token.describe(other),
      ))
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
    [] -> {
      use _ <- result.try(check_sql_case(parts, line))
      Ok(parts)
    }
    _ -> Error(diagnostic.at(line, "unexpected `}` in a query body"))
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
          Error(diagnostic.at(line, "unterminated block in a query body"))
        False -> Ok(#(list.reverse(push_sql_lit(buf, acc)), []))
      }
    ["}", ..rest] if nested -> Ok(#(list.reverse(push_sql_lit(buf, acc)), rest))
    ["{", ..rest] -> {
      use #(e, after) <- result.try(take_sql_code(rest, line, ""))
      split_sql(after, line, "", [ast.SqlParam(e), ..push_sql_lit(buf, acc)], nested)
    }
    _ ->
      // A `WHERE` block only starts at a word boundary and only when a `{`
      // follows it — so both `NOWHERE` and an ordinary `WHERE name = {x}` stay
      // literal SQL.
      case opens_where(chars, buf), miscased_where(chars, buf) {
        True, _ -> {
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
        // A bare word in front of a `{` is nothing SQL has, so this is the
        // block opener and not something that merely reads like one.
        _, True ->
          Error(diagnostic.at(
            line,
            "the block that becomes a `WHERE` clause is written the way the "
              <> "clause is — `WHERE { ... }`, in upper case like the SQL "
              <> "around it. The `if`, `and` and `or` inside it are Hive's own "
              <> "words rather than SQL's, and stay in lower case.",
          ))
        _, _ ->
          case chars {
            [c, ..rest] -> split_sql(rest, line, buf <> c, acc, nested)
            [] -> Ok(#(list.reverse(push_sql_lit(buf, acc)), []))
          }
      }
  }
}

fn opens_where(chars: List(String), buf: String) -> Bool {
  starts_word(chars, "WHERE") && ends_word(buf) && opens_block(chars)
}

fn miscased_where(chars: List(String), buf: String) -> Bool {
  starts_word_anycase(chars, "where") && ends_word(buf) && opens_block(chars)
}

fn opens_block(chars: List(String)) -> Bool {
  case skip_space(list.drop(chars, 5)) {
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
      Error(diagnostic.at(line, "unterminated `where` block in a query body"))
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
        _, _, _ -> {
          let found = head_word(chars)
          case list.contains(["if", "or", "and"], string.lowercase(found)) {
            True ->
              Error(diagnostic.at(
                line,
                naming.miscased_keyword(found)
                  <> ". Inside a `WHERE` block these are Hive's own words, not "
                  <> "SQL's: the block is upper case because it becomes a "
                  <> "clause, and what decides what goes into it is written "
                  <> "like the rest of your program.",
              ))
            False ->
              Error(diagnostic.at(
                line,
                "a `WHERE` block holds `if <condition> { ... }` predicates and "
                  <> "nested `and { ... }` / `or { ... }` groups; found "
                  <> "something else",
              ))
          }
        }
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
      Error(diagnostic.at(
        line,
        "expected `{` after an `if` condition in a `where` block",
      ))
    ["{", ..rest] -> Ok(#(buf, rest))
    [c, ..rest] -> take_until_brace(rest, line, buf <> c)
  }
}

fn expect_brace(chars: List(String), line: Int) -> Result(List(String), String) {
  case chars {
    ["{", ..rest] -> Ok(rest)
    _ ->
      Error(diagnostic.at(line, "expected `{` to open a `where` group"))
  }
}

fn skip_space(chars: List(String)) -> List(String) {
  case chars {
    [" ", ..rest] | ["\t", ..rest] | ["\n", ..rest] | ["\r", ..rest] ->
      skip_space(rest)
    _ -> chars
  }
}

// Whether `chars` begins with `word`, followed by something that is not a word
// character — so `and` matches but `android` does not. The comparison is exact:
// a query body holds two languages, and which one a word belongs to is written
// into it. `WHERE` is the clause it becomes; `if` is Hive's.
fn starts_word(chars: List(String), word: String) -> Bool {
  head_word(chars) == word
}

// The same, ignoring case — for telling a miscased keyword apart from something
// that was never one.
fn starts_word_anycase(chars: List(String), word: String) -> Bool {
  string.lowercase(head_word(chars)) == string.lowercase(word)
}

// The word `chars` opens with, empty when it does not open with one.
fn head_word(chars: List(String)) -> String {
  let #(taken, _) = take_word(chars)
  string.concat(taken)
}

fn take_word(chars: List(String)) -> #(List(String), List(String)) {
  case chars {
    [c, ..rest] ->
      case is_word_char(c) {
        True -> {
          let #(taken, remaining) = take_word(rest)
          #([c, ..taken], remaining)
        }
        False -> #([], chars)
      }
    [] -> #([], [])
  }
}

// ---------------------------------------------------------------------------
// The case of SQL
// ---------------------------------------------------------------------------
// A query body is SQL, and SQL writes its keywords in upper case. Everything
// else in there is a name somebody else chose — a table, a column, an alias —
// and keeps whatever spelling that database gave it, which is why only the words
// below are looked at and why the list holds none of the type names a `CREATE
// TABLE` uses: `text` and `date` are columns far more often than they are
// anything else.
//
// A table or column that really is called `order` says so the way SQL has always
// said it, in quotes — and quoted names are skipped here along with string
// literals and comments, so writing one is all it takes.

/// The words that shape a statement rather than name something in it.
const sql_keywords = [
  "add", "all", "alter", "and", "any", "as", "asc", "autoincrement", "begin",
  "between", "by", "cascade", "case", "check", "collate", "column", "commit",
  "conflict", "constraint", "create", "cross", "default", "delete", "desc",
  "distinct", "do", "drop", "else", "end", "except", "exists", "foreign",
  "from", "full", "group", "having", "if", "in", "index", "inner", "insert",
  "intersect", "into", "is", "join", "key", "left", "like", "limit", "natural",
  "not", "nothing", "null", "offset", "on", "or", "order", "outer", "primary",
  "recursive", "references", "returning", "right", "rollback", "select", "set",
  "table", "then", "transaction", "truncate", "union", "unique", "update",
  "using", "values", "view", "when", "where", "with",
]

fn check_sql_case(parts: List(ast.SqlPart), line: Int) -> Result(Nil, String) {
  list.try_map(parts, fn(part) {
    case part {
      ast.SqlLit(text) -> scan_sql(string.to_graphemes(text), line, False)
      // An interpolated value never enters the text — it becomes a placeholder
      // — and the expression behind it is Hive's, checked as Hive's.
      ast.SqlParam(_) -> Ok(Nil)
      ast.SqlWhere(group) -> check_sql_group(group, line)
    }
  })
  |> result.replace(Nil)
}

fn check_sql_group(group: ast.SqlGroup, line: Int) -> Result(Nil, String) {
  list.try_map(group.items, fn(item) {
    case item {
      ast.SqlCond(_, body) -> check_sql_case(body, line)
      ast.SqlNested(inner) -> check_sql_group(inner, line)
    }
  })
  |> result.replace(Nil)
}

// `qualified` is set by a `.`: what follows one is a column of whatever came
// before it, so `t.order` is left alone.
fn scan_sql(
  chars: List(String),
  line: Int,
  qualified: Bool,
) -> Result(Nil, String) {
  case chars {
    [] -> Ok(Nil)
    ["-", "-", ..rest] -> scan_sql(drop_line(rest), line, False)
    ["/", "*", ..rest] -> scan_sql(drop_block_comment(rest), line, False)
    ["'", ..rest] -> scan_sql(drop_quoted(rest, "'"), line, False)
    ["\"", ..rest] -> scan_sql(drop_quoted(rest, "\""), line, False)
    ["`", ..rest] -> scan_sql(drop_quoted(rest, "`"), line, False)
    [".", ..rest] -> scan_sql(rest, line, True)
    [c, ..rest] ->
      case is_word_char(c) {
        False -> scan_sql(rest, line, False)
        True -> {
          let #(taken, after) = take_word(chars)
          use _ <- result.try(case qualified {
            True -> Ok(Nil)
            False -> check_sql_word(string.concat(taken), line)
          })
          scan_sql(after, line, False)
        }
      }
  }
}

fn check_sql_word(word: String, line: Int) -> Result(Nil, String) {
  case
    word == string.uppercase(word)
    || !list.contains(sql_keywords, string.lowercase(word))
  {
    True -> Ok(Nil)
    False ->
      Error(diagnostic.at(
        line,
        "`"
          <> word
          <> "` is a SQL keyword, and SQL writes its keywords in upper case: `"
          <> string.uppercase(word)
          <> "`. If it is the name of a table or a column, say so the way SQL "
          <> "does — in quotes: \""
          <> word
          <> "\".",
      ))
  }
}

fn drop_line(chars: List(String)) -> List(String) {
  case chars {
    [] -> []
    ["\n", ..rest] -> rest
    [_, ..rest] -> drop_line(rest)
  }
}

fn drop_block_comment(chars: List(String)) -> List(String) {
  case chars {
    [] -> []
    ["*", "/", ..rest] -> rest
    [_, ..rest] -> drop_block_comment(rest)
  }
}

fn drop_quoted(chars: List(String), quote: String) -> List(String) {
  case chars {
    [] -> []
    [c, ..rest] ->
      case c == quote {
        True -> rest
        False -> drop_quoted(rest, quote)
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
      Error(diagnostic.at(
        line,
        "unterminated `{` interpolation in a query body",
      ))
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
      use #(pname, t1) <- result.try(expect_name(tokens, naming.Parameter))
      use t2 <- result.try(expect(t1, token.Colon))
      // `name: mut T` — the parameter is the caller's mutex, not a view of it.
      // This is the one type position where `mut` is part of the spelling, which
      // is why the type parser itself rejects it (see `parse_type_expr`).
      let #(mutable, t2) = case kind(t2) {
        token.KwMut -> #(True, tail(t2))
        _ -> #(False, t2)
      }
      use #(ptype, t3) <- result.try(parse_type_expr(t2))
      use _ <- result.try(check_type(ptype, t2))
      let param = ast.Field(pname, ptype, mutable)
      case kind(t3) {
        token.Comma -> parse_params(tail(t3), [param, ..acc])
        _ -> Ok(#(list.reverse([param, ..acc]), t3))
      }
    }
  }
}

fn parse_type(tokens: Toks) -> Result(#(ast.Decl, Toks), String) {
  use t1 <- result.try(expect(tokens, token.KwType))
  use #(name, t2) <- result.try(expect_name(t1, naming.Type))
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
    // What follows the name says which of the two this is, and the name's own
    // shape says it again: a variant is PascalCase and a field camelCase, so the
    // two never read as each other even at a glance.
    _ -> {
      use #(name, t1) <- result.try(expect_ident(tokens))
      case kind(t1) {
        // `Name { ... }` — a variant carrying fields
        token.LBrace -> {
          use _ <- result.try(named(tokens, naming.Variant, name))
          use #(fields, t2) <- result.try(parse_fields(tail(t1), []))
          parse_type_items(t2, [ast.Variant(name, fields), ..variants], commons)
        }
        // `name: Type` — a common field shared by every variant
        token.Colon -> {
          use _ <- result.try(named(tokens, naming.Field, name))
          use #(ftype, t2) <- result.try(parse_type_expr(tail(t1)))
          use _ <- result.try(check_type(ftype, tail(t1)))
          parse_type_items(t2, variants, [
            ast.Field(name, ftype, False),
            ..commons
          ])
        }
        // `Name` — a bare variant with no fields
        _ -> {
          use _ <- result.try(named(tokens, naming.Variant, name))
          parse_type_items(t1, [ast.Variant(name, []), ..variants], commons)
        }
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
      use #(fname, t1) <- result.try(expect_name(tokens, naming.Field))
      use t2 <- result.try(expect(t1, token.Colon))
      use #(ftype, t3) <- result.try(parse_type_expr(t2))
      use _ <- result.try(check_type(ftype, t2))
      parse_fields(t3, [ast.Field(fname, ftype, False), ..acc])
    }
  }
}

fn parse_type_expr(tokens: Toks) -> Result(#(ast.TypeExpr, Toks), String) {
  case kind(tokens) {
    token.KwVoid -> Ok(#(ast.TVoid, tail(tokens)))
    // `mut` is not part of a type. It marks a *binding* — a declaration, or a
    // `proc` parameter, which `parse_params` reads before handing the rest here.
    // Everywhere else there is no binding for it to describe: a field's
    // mutability is its owner's, a return hands back a value the caller binds
    // however it likes, and a function type names no parameters to bind.
    token.KwMut ->
      Error(at(
        tokens,
        "`mut` is not part of a type. A mutex is a binding: a declaration "
          <> "(`mut Str[dyn] v = ...`) or a `proc` parameter (`v: mut "
          <> "Str[dyn]`). A field, a return type and a function type each bind "
          <> "nothing, so there is nothing here for `mut` to make mutable.",
      ))
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
          Error(at(
            t1,
            "expected `,` or `)` in a function type's parameters but found "
              <> token.describe(other),
          ))
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
      Error(at(
        t1,
        "expected `,` or `>` in type arguments but found "
          <> token.describe(other),
      ))
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
    token.Eof -> Error(at(tokens, "unexpected end of file inside a block"))
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
    token.KwAsync -> parse_async(tokens)
    token.KwMut -> parse_mut(tail(tokens))
    token.Ident(name) ->
      case kind(tail(tokens)) {
        token.ColonEq -> {
          use _ <- result.try(named(tokens, naming.Variable, name))
          use #(value, deferred, t2) <- result.try(parse_init(tail(tail(tokens))))
          Ok(#(ast.SVarDecl(name, value, False, deferred), t2))
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
      use _ <- result.try(named(tokens, naming.MutVariable, name))
      use _ <- result.try(no_mut_async(tail(tail(tokens))))
      use #(value, t2) <- result.try(parse_expr(tail(tail(tokens))))
      Ok(#(ast.SVarDecl(name, value, True, False), t2))
    }
    _, _ -> {
      use #(typ, t1) <- result.try(parse_type_expr(tokens))
      case kind(t1), kind(tail(t1)) {
        token.Ident(vname), token.Assign -> {
          use _ <- result.try(check_type(typ, tokens))
          use _ <- result.try(named(t1, naming.MutVariable, vname))
          use _ <- result.try(no_mut_async(tail(tail(t1))))
          use #(value, t2) <- result.try(parse_expr(tail(tail(t1))))
          Ok(#(ast.STypedDecl(typ, vname, value, True, False), t2))
        }
        _, _ ->
          Error(at(
            tokens,
            "expected `name := value` or `Type name = value` after `mut`",
          ))
      }
    }
  }
}

// `async <call>` as a statement — spawn it and keep nothing.
fn parse_async(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  use #(call, t1) <- result.try(parse_async_call(tokens))
  Ok(#(ast.SAsync(call), t1))
}

// The call an `async` fires off, in either of the two positions the word is
// allowed. The operand is parsed at the postfix level, which is exactly a call
// and nothing more: `async` is not an operator over expressions, so there is no
// larger one for it to sit inside. Anything else that parsed is named here
// rather than left to a later pass, because the mistake is about the shape of
// the statement.
fn parse_async_call(tokens: Toks) -> Result(#(ast.Expr, Toks), String) {
  use #(operand, t1) <- result.try(parse_postfix(tail(tokens)))
  case operand {
    ast.ECall(_, _) -> Ok(#(operand, t1))
    _ ->
      Error(at(
        tokens,
        "`async` takes a call — `async slowThing(x)` runs it on its own virtual "
          <> "thread and does not wait for it. There is nothing else to fire off: "
          <> "every other expression is already finished by the time it is "
          <> "written.",
      ))
  }
}

// The value side of a declaration, and the one position where `async` keeps its
// result: `name := async <call>` starts the call now and lets the *name* do the
// waiting, at the first place it is read. The flag that comes back says which of
// the two it was; everywhere else an initializer is an ordinary expression, and
// `async` in one is caught by `parse_primary`.
fn parse_init(tokens: Toks) -> Result(#(ast.Expr, Bool, Toks), String) {
  case kind(tokens) {
    token.KwAsync -> {
      use #(call, t1) <- result.try(parse_async_call(tokens))
      use _ <- result.try(no_deferred_timeout(t1))
      Ok(#(call, True, t1))
    }
    _ -> {
      use #(value, t1) <- result.try(parse_expr(tokens))
      Ok(#(value, False, t1))
    }
  }
}

// `mut` asks for storage that can be written to; an `async` binding is a value
// still being computed somewhere else. Nothing sensible comes of the two
// together, so the combination is refused where it is written rather than
// half-honoured later.
fn no_mut_async(tokens: Toks) -> Result(Nil, String) {
  case kind(tokens) {
    token.KwAsync ->
      Error(at(
        tokens,
        "`mut` and `async` cannot be combined: `x := async f()` names work that "
          <> "is still running, and the wait for it happens wherever the name is "
          <> "read — there is no storage of its own to assign to afterwards. Drop "
          <> "the `mut`, or wait for the call (`mut x := f()`) and reassign that.",
      ))
    _ -> Ok(Nil)
  }
}

// A bound on an `async` binding would have nothing fixed to measure: the wait
// happens wherever the name is read, so the same variable could answer one read
// with a value and the next with a timeout.
fn no_deferred_timeout(tokens: Toks) -> Result(Nil, String) {
  case kind(tokens), is_timeout_word(tail(tokens)) {
    token.KwWith, True ->
      Error(at(
        tokens,
        "`with timeout` cannot bound an `async` binding: the wait happens "
          <> "wherever the name is read, so there is no one moment for the bound "
          <> "to run from — two reads would get two different answers. Bound the "
          <> "wait itself instead: `r := f(x) with timeout 500`, or "
          <> "`r := await [f(x), g(y)] with timeout 500` for several at once.",
      ))
    _, _ -> Ok(Nil)
  }
}

fn parse_echo(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  use #(value, t1) <- result.try(parse_expr(tail(tokens)))
  Ok(#(ast.SEcho(value), t1))
}

// The `assert` keyword's own line travels with the statement: it is where a
// failure will be reported, and by the time anything reports one the tokens are
// long gone.
fn parse_assert(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  let at_line = line(tokens)
  use #(value, t1) <- result.try(parse_expr(tail(tokens)))
  Ok(#(ast.SAssert(value, at_line), t1))
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
        // Committed: this is a declaration, so the type it names is one too and
        // is held to a type's spelling from here on.
        token.Ident(vname), token.Assign -> {
          use _ <- result.try(check_type(typ, tokens))
          use _ <- result.try(named(t1, naming.Variable, vname))
          use #(value, deferred, t2) <- result.try(parse_init(tail(tail(t1))))
          Ok(#(ast.STypedDecl(typ, vname, value, False, deferred), t2))
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
  use #(name, t1) <- result.try(expect_name(tokens, naming.Binding))
  use #(elem_type, t2) <- result.try(case kind(t1) {
    token.Colon -> {
      use #(typ, t) <- result.try(parse_type_expr(tail(t1)))
      use _ <- result.try(check_type(typ, tail(t1)))
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
  // A loop's init and post clauses run once per iteration around a condition, and
  // fire-and-forget has nothing to contribute to either — nothing it started can
  // be seen by the condition it would be advancing.
  use _ <- result.try(case init, post {
    Some(ast.SAsync(_)), _ | _, Some(ast.SAsync(_)) ->
      Error(at(
        tokens,
        "`async` cannot be a loop's init or post clause: those exist to set up "
          <> "and advance the condition, and a call nothing waits for has no "
          <> "value to advance it with. Put it in the body instead.",
      ))
    _, _ -> Ok(Nil)
  })
  // Nor can an `async` *binding*: a loop counter is advanced by its post clause,
  // and a name whose value arrives from somewhere else is not something this loop
  // can advance.
  use _ <- result.try(case defers(init) || defers(post) {
    True ->
      Error(at(
        tokens,
        "an `async` binding cannot be a loop's init or post clause: the counter "
          <> "those clauses set up is advanced by the loop itself, and work "
          <> "running on another thread is not. Start it before the loop and read "
          <> "the name inside.",
      ))
    False -> Ok(Nil)
  })
  use #(body, t6) <- result.try(parse_block(t5))
  Ok(#(ast.SFor(init, cond, post, body), t6))
}

// The init clause is an ordinary statement, but a variable it declares is
// forced mutable: the loop's post clause advances it (`i = i + 1`), which the
// mutability check would otherwise reject. Its name is checked again for the
// same reason — a counter is not a constant, whatever it looked like when
// `parse_stmt` read it as an ordinary declaration.
fn parse_for_init(tokens: Toks) -> Result(#(ast.Stmt, Toks), String) {
  use #(stmt, rest) <- result.try(parse_stmt(tokens))
  use stmt <- result.try(case stmt {
    ast.SVarDecl(name, value, _, deferred) -> {
      use _ <- result.try(named(tokens, naming.MutVariable, name))
      Ok(ast.SVarDecl(name, value, True, deferred))
    }
    ast.STypedDecl(typ, name, value, _, deferred) -> {
      use _ <- result.try(named(tokens, naming.MutVariable, name))
      Ok(ast.STypedDecl(typ, name, value, True, deferred))
    }
    _ -> Ok(stmt)
  })
  Ok(#(stmt, rest))
}

// Whether a loop clause is an `async` binding — the one declaration shape whose
// value is not in hand by the time the clause has run.
fn defers(clause: Option(ast.Stmt)) -> Bool {
  case clause {
    Some(ast.SVarDecl(_, _, _, deferred)) -> deferred
    Some(ast.STypedDecl(_, _, _, _, deferred)) -> deferred
    _ -> False
  }
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

// The `len` here is written qualified. A desugaring stands in for what the author
// wrote, so it has to mean the same thing in a program that declared a `len` of
// its own as in one that did not — and only `hive.len` does.
fn desugar_bounds(vector: ast.Expr, index: ast.Expr) -> ast.Expr {
  ast.EBinary(
    ast.OpAnd,
    ast.EBinary(ast.OpGe, index, ast.EInt(0)),
    ast.EBinary(
      ast.OpLt,
      index,
      ast.ECall(builtins.qualified("len"), [ast.Arg(None, vector)]),
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
      // bounds a wait; anything else names a decode target. They are told
      // apart here so `timeout` never gets read as a type name — and so
      // `timeout` stays a perfectly ordinary identifier everywhere else.
      case is_timeout_word(tail(t1)) {
        True -> {
          // Parsed at the arithmetic level, not as a full expression: the clause
          // has to stop before `is` and `&&`, so
          // `f(x) with timeout 500 is Result.Ok(v)` reads as
          // `(f(x) with timeout 500) is Result.Ok(v)` rather than folding the
          // comparison into the millisecond count. `with timeout base * 2` still
          // works.
          use #(ms, t2) <- result.try(parse_additive(tail(tail(t1))))
          case value {
            // Anything that waits may be bounded: one blocking call, or the
            // whole barrier of an await-all.
            ast.EAwait(calls, None) -> Ok(#(ast.EAwait(calls, Some(ms)), t2))
            ast.EAwait(_, Some(_)) ->
              Error(at(t1, "this `await` already has a `with timeout` clause"))
            ast.ECall(_, _) -> Ok(#(ast.ETimed(value, ms), t2))
            ast.ETimed(_, _) ->
              Error(at(t1, "this call already has a `with timeout` clause"))
            _ ->
              Error(at(
                t1,
                "`with timeout <ms>` bounds how long a wait may take, so it "
                  <> "belongs on something that waits: a call (`f(x) with "
                  <> "timeout 500`) or an await-all (`await [f(a), f(b)] with "
                  <> "timeout 500`)",
              ))
          }
        }
        False -> {
          use #(typ, t2) <- result.try(parse_type_expr(tail(t1)))
          use _ <- result.try(check_type(typ, tail(t1)))
          Ok(#(ast.EWith(value, typ), t2))
        }
      }
    _ -> Ok(#(value, t1))
  }
}

// `timeout` in `with timeout <ms>`. Lower case like every keyword, but
// deliberately not lexed as one: making it a reserved word would stop anyone
// naming a variable `timeout`, and this is the only position where the spelling
// means anything. It is also the one position where the *other* casings are
// taken: `with Timeout` names a decode target, and a type may well be called
// that.
fn is_timeout_word(tokens: Toks) -> Bool {
  case kind(tokens) {
    token.Ident(name) -> name == "timeout"
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
          Error(at(
            t1,
            "expected `,` or `)` in argument list but found "
              <> token.describe(other),
          ))
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
          Error(at(
            t1,
            "expected `]` or `:` in index/slice but found "
              <> token.describe(other),
          ))
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
    // `await [f(a), g(b)]` — the await-all, and the only `await` there is. A
    // single call needs no keyword (calling it blocks already), so the `[` is
    // required and its absence is worth saying out loud.
    token.KwAwait ->
      case kind(tail(tokens)) {
        token.LBracket -> {
          use #(calls, t1) <- result.try(parse_await_calls(
            tail(tail(tokens)),
            [],
          ))
          Ok(#(ast.EAwait(calls, None), t1))
        }
        other ->
          Error(at(
            tail(tokens),
            "`await` takes a list of calls to run all at once — `await [f(a), "
              <> "f(b)]` — but found "
              <> token.describe(other)
              <> ". One call on its own needs no `await`: calling it already "
              <> "blocks until it answers.",
          ))
      }
    // `async` is not an expression: it says how a call is *run*, and the only
    // places that question can be asked are a statement of its own and the value
    // side of a declaration (`parse_init`). Anywhere else — inside an argument,
    // an operand, a condition — the value is wanted right there, which is what
    // an ordinary call already does.
    token.KwAsync ->
      Error(at(
        tokens,
        "`async` has no value of its own: it says how a call runs, not what it "
          <> "evaluates to, so it cannot sit inside a larger expression. Give it a "
          <> "name and read the name here — `x := async f(a)` starts the call now "
          <> "and waits at the first place `x` is read — or drop the `async` to "
          <> "wait for the result on the spot.",
      ))
    token.KwUsing -> parse_using(tokens)
    token.LBracket -> parse_vector(tail(tokens), [])
    token.LParen -> {
      use #(inner, t1) <- result.try(parse_expr(tail(tokens)))
      use t2 <- result.try(expect(t1, token.RParen))
      Ok(#(inner, t2))
    }
    other ->
      Error(at(
        tokens,
        "unexpected " <> token.describe(other) <> " in an expression",
      ))
  }
}

// The `[...]` of an await-all. It looks like a vector literal and is not one:
// its elements are calls to *start*, so each has to be a call and the list is
// held by the `await` itself rather than becoming a value of its own.
fn parse_await_calls(
  tokens: Toks,
  acc: List(ast.Expr),
) -> Result(#(List(ast.Expr), Toks), String) {
  case kind(tokens) {
    token.RBracket ->
      case acc {
        [] ->
          Error(at(
            tokens,
            "`await []` waits for nothing at all. List the calls to run "
              <> "together: `await [f(a), f(b)]`.",
          ))
        _ -> Ok(#(list.reverse(acc), tail(tokens)))
      }
    _ -> {
      use #(item, t1) <- result.try(parse_expr(tokens))
      use _ <- result.try(case item {
        ast.ECall(_, _) -> Ok(Nil)
        _ ->
          Error(at(
            tokens,
            "`await` runs each of its calls on its own virtual thread, so every "
              <> "entry has to be a call — this one is not. A value that is "
              <> "already in hand has nothing to wait for.",
          ))
      })
      case kind(t1) {
        token.Comma -> parse_await_calls(tail(t1), [item, ..acc])
        token.RBracket -> Ok(#(list.reverse([item, ..acc]), tail(t1)))
        other ->
          Error(at(
            t1,
            "expected `,` or `]` in an `await` list but found "
              <> token.describe(other),
          ))
      }
    }
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
          Error(at(
            t1,
            "expected `,` or `]` in a vector literal but found "
              <> token.describe(other),
          ))
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
      Error(diagnostic.at(
        line,
        "unexpected "
          <> token.describe(other)
          <> " in interpolated expression `"
          <> code
          <> "`",
      ))
  }
}

// `using <path>`, `using <path> as csv [separating by <sep>]`,
// `using <path> as xlsx`, `using <path> as ods`, or
// `using <connection> run <query>`.
//
// `as`, `csv`, `xlsx`, `ods`, `separating`, `by` and `run` are matched as plain
// words rather than keywords, so a variable or proc named `run` or `by` still
// works everywhere else in the language. Each is spelled in lower case, like
// every keyword — and, unlike a lexed one, a different spelling here is simply
// a name, since the next statement may well start with one. The positions that
// admit nothing but the keyword say so instead (see `parse_using_format`).
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
      Error(at(
        t2,
        "`using ... with ...` has been split into two forms that each name what "
          <> "they read: `using <path> as csv separating by <separator>` for a "
          <> "delimited file, and `using <connection> run <query>` for SQL",
      ))
    _, Some("as") -> parse_using_format(source, tail(t2))
    _, Some("run") -> {
      let t3 = tail(t2)
      // Anything else here is the query being run, and a query is camelCase —
      // so `RAW` is this word shouted rather than something to call.
      use _ <- result.try(case word(t3) {
        Some(other) ->
          case miscased(other, "raw") {
            True -> Error(at(t3, naming.miscased_keyword(other) <> "."))
            False -> Ok(Nil)
          }
        None -> Ok(Nil)
      })
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
            // `separating` promises a `by`, so nothing else can be standing
            // here — including this one shouted.
            found ->
              Error(at(
                tail(t1),
                expected_word(found, "by", "expected `by` after `separating`"),
              ))
          }
        _ -> Ok(#(ast.EUsing(source, ast.UsingCsv(None)), t1))
      }
    }
    Some("xlsx") -> Ok(#(ast.EUsing(source, ast.UsingXlsx), tail(tokens)))
    Some("ods") -> Ok(#(ast.EUsing(source, ast.UsingOds), tail(tokens)))
    Some(other) ->
      case list.any(["csv", "xlsx", "ods"], miscased(other, _)) {
        True -> Error(at(tokens, naming.miscased_keyword(other) <> "."))
        False ->
          Error(at(
            tokens,
            "`using ... as "
              <> other
              <> "` is not a table format (expected `csv`, `xlsx` or `ods`)",
          ))
      }
    None ->
      Error(at(
        tokens,
        "expected a table format after `as` (`csv`, `xlsx` or `ods`) but found "
          <> token.describe(kind(tokens)),
      ))
  }
}

// The identifier at the front of `tokens`, spelled the way the source spelled
// it: the words compared against it are keywords, so they are matched exactly.
fn word(tokens: Toks) -> Option(String) {
  case kind(tokens) {
    token.Ident(name) -> Some(name)
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
      use _ <- result.try(check_pattern_path(path, tokens))
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
      use #(name, t1) <- result.try(expect_name(tail(tokens), naming.Binding))
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
          Error(at(
            t1,
            "a `...` rest in a vector pattern must be separated from the "
              <> "previous element by a `,`",
          ))
        other ->
          Error(at(
            t1,
            "expected `,` or `]` in a vector pattern but found "
              <> token.describe(other),
          ))
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
    ast.EIdent(name) -> {
      use _ <- result.try(named(tokens, naming.Binding, name))
      Ok(#(ast.PElemBind(name), t1))
    }
    _ ->
      Error(at(
        tokens,
        "a vector pattern element must be a literal (string, number, boolean "
          <> "or atom) or a binding name",
      ))
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
      Error(diagnostic.at(
        line,
        "an empty `{}` hole is not allowed in a string pattern",
      ))
    trimmed -> {
      use e <- result.try(parse_sub_expr(code, line))
      case e {
        ast.EIdent(name) -> {
          use _ <- result.try(
            naming.check(naming.Binding, name)
            |> result.map_error(diagnostic.at(line, _)),
          )
          Ok(name)
        }
        _ ->
          Error(diagnostic.at(
            line,
            "a `{...}` hole in a string pattern must be a single binding name, "
              <> "but found `"
              <> trimmed
              <> "`",
          ))
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
      Error(diagnostic.at(
        line,
        "two `{...}` holes in a string pattern must be separated by some "
          <> "literal text, otherwise where one ends and the next begins is "
          <> "ambiguous",
      ))
    [_, ..rest] -> check_no_adjacent_holes(rest, line)
    [] -> Ok(Nil)
  }
}

// What a pattern matches is a type or one of its variants, whatever stands in
// front of it: `Result.Ok`, `Str`, `hive.sql.SqlError`. The last segment is the
// one being matched, so it is spelled as a type; the qualifiers in front are a
// module or a type of their own.
fn check_pattern_path(path: List(String), tokens: Toks) -> Result(Nil, String) {
  case list.reverse(path) {
    [matched, ..qualifiers] -> {
      use _ <- result.try(check_qualifier(list.reverse(qualifiers), tokens))
      named(tokens, naming.Type, matched)
    }
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
      use #(name, t1) <- result.try(expect_name(tokens, naming.Binding))
      case kind(t1) {
        token.Comma -> parse_bindings(tail(t1), [name, ..acc])
        token.RParen -> Ok(#(list.reverse([name, ..acc]), tail(t1)))
        other ->
          Error(at(
            t1,
            "expected `,` or `)` in pattern bindings but found "
              <> token.describe(other),
          ))
      }
    }
  }
}
