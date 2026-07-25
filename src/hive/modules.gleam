//// Resolves a program's `import` graph into the single flat module the rest of
//// the pipeline compiles.
////
//// A Hive program is many files but one Go package, so every module's
//// declarations are merged into one `ast.Module`. The entry module keeps its own
//// names (its `main` has to stay `main`); every other module's declarations are
//// renamed with a prefix of their own, and every reference to them —
//// `text.slugify(...)`, a `text.Style` annotation, a `v is text.Style.Bold`
//// pattern — is rewritten to that flat name. Local bindings still shadow a
//// module-level declaration of the same name, so the rewrite tracks scopes
//// rather than renaming every matching identifier it sees.
////
//// Because the whole program becomes one module, the checks that follow
//// (`hive/compiler`, `hive/bounds`) and codegen need to know nothing about
//// imports at all.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import filepath
import simplifile
import hive/ast
import hive/lexer
import hive/parser

/// One loaded file.
type Source {
  Source(
    /// The module's identity: its absolute path with `.` and `..` collapsed, so
    /// the same file reached through two different relative paths counts once.
    key: String,
    /// The directory this module's own imports resolve against.
    dir: String,
    /// How the module is named in messages — the path as the program spells it.
    display: String,
    module: ast.Module,
  )
}

/// Load the program rooted at `entry` (a path to a `.hive` file) and flatten it,
/// with everything it imports, into one module.
pub fn load(entry: String) -> Result(ast.Module, String) {
  let entry = normalize(entry)
  use text <- result.try(
    simplifile.read(entry)
    |> result.map_error(fn(e) {
      "could not read " <> entry <> ": " <> simplifile.describe_error(e)
    }),
  )
  use module <- result.try(parse_module(text, None))
  use key <- result.try(canonical(entry))
  build(Source(key, directory_of(entry), entry, module), entry)
}

/// Load a program from source text held in memory, resolving any `import` it
/// carries against `dir`. This is the single-file entry point; `display` names
/// the source in messages.
pub fn load_source(
  source: String,
  dir: String,
  display: String,
) -> Result(ast.Module, String) {
  use module <- result.try(parse_module(source, None))
  // The key only has to be distinct from every real file's absolute path, which
  // a bare name never is, and nothing can import the in-memory entry anyway.
  build(Source("<entry>", normalize(dir), display, module), display)
}

fn build(entry: Source, display: String) -> Result(ast.Module, String) {
  use sources <- result.try(resolve(entry, [], []))
  flatten(sources, entry.key, display)
}

// ---------------------------------------------------------------------------
// Loading and cycle detection
// ---------------------------------------------------------------------------

// Depth-first walk of the import graph, returning every module reached with each
// one's dependencies ahead of it. `chain` is the modules currently being
// resolved, which is what makes a cycle visible; `done` is everything already
// loaded, so a diamond (two modules importing the same third) loads it once.
fn resolve(
  src: Source,
  chain: List(Source),
  done: List(Source),
) -> Result(List(Source), String) {
  case list.any(done, fn(s) { s.key == src.key }) {
    True -> Ok(done)
    False -> {
      let chain = [src, ..chain]
      use done <- result.try(
        list.try_fold(src.module.imports, done, fn(acc, imp) {
          use dep <- result.try(load_import(src, imp))
          case list.any(chain, fn(s) { s.key == dep.key }) {
            True -> Error(cycle_error(chain, dep))
            False -> resolve(dep, chain, acc)
          }
        }),
      )
      Ok(list.append(done, [src]))
    }
  }
}

// `chain` is the modules currently being resolved, innermost first, and `dep` is
// the import that closes the loop back onto one of them.
fn cycle_error(chain: List(Source), dep: Source) -> String {
  // Cut the chain at the module the cycle returns to, then read it outermost
  // first so it runs in the direction the imports point.
  let loop =
    chain
    |> list.reverse
    |> list.drop_while(fn(s) { s.key != dep.key })
    |> list.map(fn(s) { s.display })
  "this import forms a cycle:\n\n    "
  <> string.join(list.append(loop, [dep.display]), "\n      -> ")
  <> "\n\nA Hive module may not import itself, directly or through any number "
  <> "of steps. Break the loop by moving what both sides need into a third "
  <> "module they each import."
}

// Resolves one `import` against the importing module's own directory and reads
// the file it names, supplying the `.hive` extension.
fn load_import(from: Source, imp: ast.Import) -> Result(Source, String) {
  let path = import_path(from.dir, imp.path)
  let display = shorten(path)
  use key <- result.try(canonical(path))
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(e) {
      "`import "
      <> imp.path
      <> "` in "
      <> from.display
      <> " (line "
      <> int.to_string(imp.line)
      <> ") does not name a readable file — looked for "
      <> display
      <> ": "
      <> simplifile.describe_error(e)
    }),
  )
  use module <- result.try(parse_module(text, Some(display)))
  Ok(Source(key, directory_of(path), display, module))
}

// The file an import names: relative to the importing module's directory, with
// the omitted `.hive` extension put back.
fn import_path(from_dir: String, path: String) -> String {
  filepath.join(from_dir, normalize(path)) <> ".hive"
}

fn parse_module(
  text: String,
  display: Option(String),
) -> Result(ast.Module, String) {
  lexer.lex(text)
  |> result.try(parser.parse)
  |> result.map_error(fn(message) {
    // An imported module's errors say which file they came from; the entry's
    // do not, since there is only one file it could be.
    case display {
      Some(name) -> "in " <> name <> ": " <> message
      None -> message
    }
  })
}

// ---------------------------------------------------------------------------
// Flattening
// ---------------------------------------------------------------------------

fn flatten(
  sources: List(Source),
  entry_key: String,
  display: String,
) -> Result(ast.Module, String) {
  let prefixes = choose_prefixes(sources, entry_key)
  // Each module's declared names mapped to their flat names. This doubles as the
  // module's export table, which is what an importer looks names up in.
  let exports =
    list.fold(sources, dict.new(), fn(acc, src) {
      let prefix = dict.get(prefixes, src.key) |> result.unwrap("")
      dict.insert(acc, src.key, own_names(src.module, prefix))
    })
  use rewritten <- result.try(
    list.try_map(sources, fn(src) {
      use rw <- result.try(context(src, exports))
      list.try_map(src.module.decls, fn(decl) { rewrite_decl(rw, decl) })
    }),
  )
  // The entry module's declarations come first so the emitted Go opens with the
  // file the author actually wrote.
  let #(entry, rest) =
    list.zip(sources, rewritten)
    |> list.partition(fn(pair) { { pair.0 }.key == entry_key })
  case entry {
    [] -> Error("could not find the entrypoint module " <> display)
    _ ->
      Ok(ast.Module(
        [],
        list.flat_map(list.append(entry, rest), fn(pair) { pair.1 }),
      ))
  }
}

// Builds one module's rewrite context, checking its imports name real modules
// and do not collide with each other or with its own declarations.
fn context(src: Source, exports: Dict(String, Dict(String, String))) {
  let own = dict.get(exports, src.key) |> result.unwrap(dict.new())
  use modules <- result.try(
    list.try_fold(src.module.imports, dict.new(), fn(acc, imp) {
      let at = " (" <> src.display <> " line " <> int.to_string(imp.line) <> ")"
      use _ <- result.try(case imp.alias {
        "hive" ->
          Error(
            "an import cannot be named `hive`: that name belongs to the "
            <> "standard library"
            <> at,
          )
        _ -> Ok(Nil)
      })
      use _ <- result.try(case dict.has_key(acc, imp.alias) {
        True ->
          Error(
            "two imports are both named `"
            <> imp.alias
            <> "` — give one of them a different name with `as`"
            <> at,
          )
        False -> Ok(Nil)
      })
      use _ <- result.try(case dict.has_key(own, imp.alias) {
        True ->
          Error(
            "the import `"
            <> imp.alias
            <> "` has the same name as a declaration in this module — rename "
            <> "one of them, or import with `as`"
            <> at,
          )
        False -> Ok(Nil)
      })
      use key <- result.try(canonical(import_path(src.dir, imp.path)))
      case dict.get(exports, key) {
        Ok(dep) -> Ok(dict.insert(acc, imp.alias, dep))
        Error(_) ->
          Error("could not resolve `import " <> imp.path <> "`" <> at)
      }
    }),
  )
  Ok(Rw(own, modules, src.display))
}

/// Every name a module declares, mapped to the name it carries in the flattened
/// program.
fn own_names(module: ast.Module, prefix: String) -> Dict(String, String) {
  list.fold(module.decls, dict.new(), fn(acc, decl) {
    let name = decl_name(decl)
    dict.insert(acc, name, prefix <> name)
  })
}

fn decl_name(decl: ast.Decl) -> String {
  case decl {
    ast.ProcDecl(name, _, _, _)
    | ast.FuncDecl(name, _, _, _, _)
    | ast.QueryDecl(name, _, _, _)
    | ast.TypeDecl(name, _, _) -> name
  }
}

// A prefix for each module's flattened declarations. The entry module keeps its
// own names — `main` has to stay `main` — and every other module gets one built
// from its file name.
fn choose_prefixes(
  sources: List(Source),
  entry_key: String,
) -> Dict(String, String) {
  let declared =
    list.flat_map(sources, fn(s) { list.map(s.module.decls, decl_name) })
  let #(prefixes, _) =
    list.index_fold(sources, #(dict.new(), []), fn(acc, src, index) {
      let #(map, taken) = acc
      case src.key == entry_key {
        True -> #(dict.insert(map, src.key, ""), taken)
        False -> {
          let prefix = widen(base_prefix(src, index), declared, taken)
          #(dict.insert(map, src.key, prefix), [prefix, ..taken])
        }
      }
    })
  prefixes
}

// The starting point: the module's file name reduced to something identifier-
// shaped, plus its position, so two files that share a base name stay apart.
fn base_prefix(src: Source, index: Int) -> String {
  let base =
    filepath.base_name(src.display)
    |> filepath.strip_extension
    |> string.to_graphemes
    |> list.map(fn(c) {
      case is_name_char(c) {
        True -> c
        False -> "_"
      }
    })
    |> string.concat
  base <> "_" <> int.to_string(index) <> "_"
}

// A prefix is safe once no name declared anywhere in the program starts with it
// — so no prefixed name can land on a real declaration — and it neither contains
// nor is contained by another module's prefix. Trailing underscores push it out
// of the way until both hold.
fn widen(
  prefix: String,
  declared: List(String),
  taken: List(String),
) -> String {
  let clashes =
    list.any(declared, fn(name) { string.starts_with(name, prefix) })
    || list.any(taken, fn(other) {
      string.starts_with(other, prefix) || string.starts_with(prefix, other)
    })
  case clashes {
    True -> widen(prefix <> "_", declared, taken)
    False -> prefix
  }
}

fn is_name_char(c: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
    c,
  )
}

// ---------------------------------------------------------------------------
// The rewrite
// ---------------------------------------------------------------------------

type Rw {
  Rw(
    /// This module's own declared names, mapped to their flat names.
    own: Dict(String, String),
    /// Import name -> that module's export table.
    modules: Dict(String, Dict(String, String)),
    /// The module being rewritten, for error messages.
    where: String,
  )
}

fn unknown_member(rw: Rw, alias: String, member: String) -> String {
  "the module imported as `"
  <> alias
  <> "` has no `"
  <> member
  <> "` (referenced in "
  <> rw.where
  <> ")"
}

fn rewrite_decl(rw: Rw, decl: ast.Decl) -> Result(ast.Decl, String) {
  case decl {
    ast.ProcDecl(name, params, ret, body) -> {
      use params <- result.try(rewrite_fields(rw, params))
      use ret <- result.try(rewrite_type(rw, ret))
      use body <- result.try(rewrite_body(rw, body, field_names(params)))
      Ok(ast.ProcDecl(flat(rw, name), params, ret, body))
    }
    ast.FuncDecl(name, params, ret, body, is_async) -> {
      use params <- result.try(rewrite_fields(rw, params))
      use ret <- result.try(rewrite_type(rw, ret))
      use body <- result.try(rewrite_body(rw, body, field_names(params)))
      Ok(ast.FuncDecl(flat(rw, name), params, ret, body, is_async))
    }
    ast.QueryDecl(name, params, ret, sql) -> {
      use params <- result.try(rewrite_fields(rw, params))
      use ret <- result.try(rewrite_type(rw, ret))
      use sql <- result.try(rewrite_parts(rw, sql, field_names(params)))
      Ok(ast.QueryDecl(flat(rw, name), params, ret, sql))
    }
    ast.TypeDecl(name, variants, commons) -> {
      use variants <- result.try(
        list.try_map(variants, fn(v) {
          use fields <- result.try(rewrite_fields(rw, v.fields))
          Ok(ast.Variant(v.name, fields))
        }),
      )
      use commons <- result.try(rewrite_fields(rw, commons))
      Ok(ast.TypeDecl(flat(rw, name), variants, commons))
    }
  }
}

fn flat(rw: Rw, name: String) -> String {
  dict.get(rw.own, name) |> result.unwrap(name)
}

fn rewrite_fields(
  rw: Rw,
  fields: List(ast.Field),
) -> Result(List(ast.Field), String) {
  list.try_map(fields, fn(f) {
    use typ <- result.try(rewrite_type(rw, f.typ))
    Ok(ast.Field(f.name, typ))
  })
}

// Parameters are locals, so they shadow a module-level name of the same shape
// throughout the body.
fn field_names(fields: List(ast.Field)) -> List(String) {
  list.map(fields, fn(f) { f.name })
}

fn rewrite_body(
  rw: Rw,
  stmts: List(ast.Stmt),
  locals: List(String),
) -> Result(List(ast.Stmt), String) {
  use #(stmts, _) <- result.try(rewrite_stmts(rw, stmts, locals))
  Ok(stmts)
}

// Walks a statement list threading the locals in scope, so a declaration stays
// visible to the statements that follow it. Returns the updated set for the
// caller to keep threading.
fn rewrite_stmts(
  rw: Rw,
  stmts: List(ast.Stmt),
  locals: List(String),
) -> Result(#(List(ast.Stmt), List(String)), String) {
  case stmts {
    [] -> Ok(#([], locals))
    [s, ..rest] -> {
      use #(s, locals) <- result.try(rewrite_stmt(rw, s, locals))
      use #(rest, locals) <- result.try(rewrite_stmts(rw, rest, locals))
      Ok(#([s, ..rest], locals))
    }
  }
}

fn rewrite_stmt(
  rw: Rw,
  stmt: ast.Stmt,
  locals: List(String),
) -> Result(#(ast.Stmt, List(String)), String) {
  case stmt {
    ast.SVarDecl(name, value, mutable) -> {
      use value <- result.try(rewrite_expr(rw, value, locals))
      Ok(#(ast.SVarDecl(name, value, mutable), [name, ..locals]))
    }
    ast.STypedDecl(typ, name, value, mutable) -> {
      use typ <- result.try(rewrite_type(rw, typ))
      use value <- result.try(rewrite_expr(rw, value, locals))
      Ok(#(ast.STypedDecl(typ, name, value, mutable), [name, ..locals]))
    }
    ast.SAssign(target, value) -> {
      use target <- result.try(rewrite_expr(rw, target, locals))
      use value <- result.try(rewrite_expr(rw, value, locals))
      Ok(#(ast.SAssign(target, value), locals))
    }
    ast.SIf(branches, else_body) -> {
      use branches <- result.try(
        list.try_map(branches, fn(b) {
          use cond <- result.try(rewrite_expr(rw, b.cond, locals))
          // What the condition's `is` patterns bind is in scope in the body.
          let inner = list.append(pattern_bindings(b.cond), locals)
          use body <- result.try(rewrite_body(rw, b.body, inner))
          Ok(ast.Branch(cond, body))
        }),
      )
      use else_body <- result.try(case else_body {
        Some(body) -> {
          use body <- result.try(rewrite_body(rw, body, locals))
          Ok(Some(body))
        }
        None -> Ok(None)
      })
      Ok(#(ast.SIf(branches, else_body), locals))
    }
    ast.SFor(init, cond, post, body) -> {
      // The loop variable is scoped to the loop, so the outer set is what the
      // statements after it see.
      use #(init, inner) <- result.try(case init {
        Some(s) -> {
          use #(s, inner) <- result.try(rewrite_stmt(rw, s, locals))
          Ok(#(Some(s), inner))
        }
        None -> Ok(#(None, locals))
      })
      use cond <- result.try(case cond {
        Some(e) -> {
          use e <- result.try(rewrite_expr(rw, e, inner))
          Ok(Some(e))
        }
        None -> Ok(None)
      })
      use post <- result.try(case post {
        Some(s) -> {
          use #(s, _) <- result.try(rewrite_stmt(rw, s, inner))
          Ok(Some(s))
        }
        None -> Ok(None)
      })
      use body <- result.try(rewrite_body(rw, body, inner))
      Ok(#(ast.SFor(init, cond, post, body), locals))
    }
    ast.SForEach(name, elem_type, iterable, body) -> {
      use elem_type <- result.try(case elem_type {
        Some(t) -> {
          use t <- result.try(rewrite_type(rw, t))
          Ok(Some(t))
        }
        None -> Ok(None)
      })
      use iterable <- result.try(rewrite_expr(rw, iterable, locals))
      use body <- result.try(rewrite_body(rw, body, [name, ..locals]))
      Ok(#(ast.SForEach(name, elem_type, iterable, body), locals))
    }
    ast.SReturn(Some(e)) -> {
      use e <- result.try(rewrite_expr(rw, e, locals))
      Ok(#(ast.SReturn(Some(e)), locals))
    }
    ast.SReturn(None) -> Ok(#(stmt, locals))
    ast.SEcho(e) -> {
      use e <- result.try(rewrite_expr(rw, e, locals))
      Ok(#(ast.SEcho(e), locals))
    }
    ast.SAssert(e) -> {
      use e <- result.try(rewrite_expr(rw, e, locals))
      Ok(#(ast.SAssert(e), locals))
    }
    ast.SPanic(e) -> {
      use e <- result.try(rewrite_expr(rw, e, locals))
      Ok(#(ast.SPanic(e), locals))
    }
    ast.SExpr(e) -> {
      use e <- result.try(rewrite_expr(rw, e, locals))
      Ok(#(ast.SExpr(e), locals))
    }
    ast.SBreak | ast.SContinue -> Ok(#(stmt, locals))
  }
}

fn rewrite_expr(
  rw: Rw,
  e: ast.Expr,
  locals: List(String),
) -> Result(ast.Expr, String) {
  case e {
    ast.EIdent(name) -> Ok(ast.EIdent(resolve_name(rw, name, locals)))
    // `text.slugify` / `text.Style` — a name reached through an import becomes
    // the flat name directly, so everything downstream sees a plain reference.
    // A local of the same name shadows the import, in which case this is
    // ordinary field access after all.
    ast.EMember(ast.EIdent(alias), member) ->
      case list.contains(locals, alias), dict.get(rw.modules, alias) {
        False, Ok(members) ->
          case dict.get(members, member) {
            Ok(name) -> Ok(ast.EIdent(name))
            Error(_) -> Error(unknown_member(rw, alias, member))
          }
        _, _ ->
          Ok(ast.EMember(ast.EIdent(resolve_name(rw, alias, locals)), member))
      }
    ast.EMember(target, member) -> {
      use target <- result.try(rewrite_expr(rw, target, locals))
      Ok(ast.EMember(target, member))
    }
    ast.ECall(callee, args) -> {
      use callee <- result.try(rewrite_expr(rw, callee, locals))
      use args <- result.try(
        list.try_map(args, fn(a) {
          use value <- result.try(rewrite_expr(rw, a.value, locals))
          Ok(ast.Arg(a.name, value))
        }),
      )
      Ok(ast.ECall(callee, args))
    }
    ast.EIndex(target, index) -> {
      use target <- result.try(rewrite_expr(rw, target, locals))
      use index <- result.try(rewrite_expr(rw, index, locals))
      Ok(ast.EIndex(target, index))
    }
    ast.ESlice(target, low, high) -> {
      use target <- result.try(rewrite_expr(rw, target, locals))
      use low <- result.try(rewrite_optional(rw, low, locals))
      use high <- result.try(rewrite_optional(rw, high, locals))
      Ok(ast.ESlice(target, low, high))
    }
    // In `a && b`, what `a`'s patterns bind is already in scope in `b`.
    ast.EBinary(ast.OpAnd, left, right) -> {
      use left <- result.try(rewrite_expr(rw, left, locals))
      use right <- result.try(rewrite_expr(
        rw,
        right,
        list.append(pattern_bindings(left), locals),
      ))
      Ok(ast.EBinary(ast.OpAnd, left, right))
    }
    ast.EBinary(op, left, right) -> {
      use left <- result.try(rewrite_expr(rw, left, locals))
      use right <- result.try(rewrite_expr(rw, right, locals))
      Ok(ast.EBinary(op, left, right))
    }
    ast.EVector(items) -> {
      use items <- result.try(
        list.try_map(items, fn(i) { rewrite_expr(rw, i, locals) }),
      )
      Ok(ast.EVector(items))
    }
    ast.EInterp(parts) -> {
      use parts <- result.try(rewrite_parts(rw, parts, locals))
      Ok(ast.EInterp(parts))
    }
    ast.EIs(subject, pattern) -> {
      use subject <- result.try(rewrite_expr(rw, subject, locals))
      use pattern <- result.try(rewrite_pattern(rw, pattern))
      Ok(ast.EIs(subject, pattern))
    }
    ast.EUsing(path, delimiter) -> {
      use path <- result.try(rewrite_expr(rw, path, locals))
      use delimiter <- result.try(rewrite_optional(rw, delimiter, locals))
      Ok(ast.EUsing(path, delimiter))
    }
    ast.EWith(value, typ) -> {
      use value <- result.try(rewrite_expr(rw, value, locals))
      use typ <- result.try(rewrite_type(rw, typ))
      Ok(ast.EWith(value, typ))
    }
    ast.EAwait(value) -> {
      use value <- result.try(rewrite_expr(rw, value, locals))
      Ok(ast.EAwait(value))
    }
    ast.EInt(_)
    | ast.EFloat(_)
    | ast.EString(_)
    | ast.EBool(_)
    | ast.EAtom(_) -> Ok(e)
  }
}

fn rewrite_optional(
  rw: Rw,
  e: Option(ast.Expr),
  locals: List(String),
) -> Result(Option(ast.Expr), String) {
  case e {
    Some(inner) -> {
      use inner <- result.try(rewrite_expr(rw, inner, locals))
      Ok(Some(inner))
    }
    None -> Ok(None)
  }
}

fn rewrite_parts(
  rw: Rw,
  parts: List(ast.IPart),
  locals: List(String),
) -> Result(List(ast.IPart), String) {
  list.try_map(parts, fn(p) {
    case p {
      ast.ILit(_) -> Ok(p)
      ast.IExpr(e) -> {
        use e <- result.try(rewrite_expr(rw, e, locals))
        Ok(ast.IExpr(e))
      }
    }
  })
}

// A bare name is this module's flat name for it, unless a local binding shadows
// it or it is not a module-level declaration at all (a parameter, a builtin,
// the `_` placeholder).
fn resolve_name(rw: Rw, name: String, locals: List(String)) -> String {
  case list.contains(locals, name) {
    True -> name
    False -> flat(rw, name)
  }
}

fn rewrite_type(rw: Rw, typ: ast.TypeExpr) -> Result(ast.TypeExpr, String) {
  case typ {
    ast.TVoid -> Ok(typ)
    ast.TName(None, name, dims) ->
      case dict.get(rw.own, name) {
        Ok(flat) -> Ok(ast.TName(None, flat, dims))
        Error(_) -> Ok(typ)
      }
    ast.TName(Some(pkg), name, dims) ->
      case is_hive_pkg(pkg), dict.get(rw.modules, pkg) {
        // `hive.net.HttpRequest` and friends belong to the standard library.
        True, _ -> Ok(typ)
        False, Ok(members) ->
          case dict.get(members, name) {
            Ok(flat) -> Ok(ast.TName(None, flat, dims))
            Error(_) -> Error(unknown_member(rw, pkg, name))
          }
        False, Error(_) -> Ok(typ)
      }
    ast.TFunc(pure, params, ret) -> {
      use params <- result.try(
        list.try_map(params, fn(p) { rewrite_type(rw, p) }),
      )
      use ret <- result.try(rewrite_type(rw, ret))
      Ok(ast.TFunc(pure, params, ret))
    }
  }
}

fn is_hive_pkg(pkg: String) -> Bool {
  pkg == "hive" || string.starts_with(pkg, "hive.")
}

fn rewrite_pattern(rw: Rw, pattern: ast.Pattern) -> Result(ast.Pattern, String) {
  case pattern {
    ast.PConstructor(path, bindings) -> {
      use path <- result.try(rewrite_pattern_path(rw, path))
      Ok(ast.PConstructor(path, bindings))
    }
    // Vector and string patterns name no types, so there is nothing to resolve.
    ast.PVector(_, _) | ast.PString(_) -> Ok(pattern)
  }
}

// `Result.Ok(v)` is left alone. Two segments are normally a type and one of its
// variants, but they are a module and one of its types when the first segment
// names an import instead; three segments can only be the module form.
fn rewrite_pattern_path(
  rw: Rw,
  path: List(String),
) -> Result(List(String), String) {
  case path {
    ["Result", _] -> Ok(path)
    [first, second] ->
      case dict.get(rw.own, first) {
        Ok(flat) -> Ok([flat, second])
        Error(_) ->
          case dict.get(rw.modules, first) {
            Ok(members) ->
              case dict.get(members, second) {
                Ok(flat) -> Ok([flat])
                Error(_) -> Error(unknown_member(rw, first, second))
              }
            Error(_) -> Ok(path)
          }
      }
    [alias, type_name, variant] ->
      case dict.get(rw.modules, alias) {
        Ok(members) ->
          case dict.get(members, type_name) {
            Ok(flat) -> Ok([flat, variant])
            Error(_) -> Error(unknown_member(rw, alias, type_name))
          }
        Error(_) ->
          Error(
            "`"
            <> string.join(path, ".")
            <> "` does not name a pattern: `"
            <> alias
            <> "` is not an imported module (in "
            <> rw.where
            <> ")",
          )
      }
    _ -> Ok(path)
  }
}

// Every name an `is` pattern inside this expression binds. Those bindings are in
// scope in the guarded body, where they shadow a module-level declaration of the
// same name.
fn pattern_bindings(e: ast.Expr) -> List(String) {
  case e {
    ast.EIs(subject, pattern) ->
      list.append(bound_by(pattern), pattern_bindings(subject))
    ast.EBinary(_, left, right) ->
      list.append(pattern_bindings(left), pattern_bindings(right))
    ast.ECall(callee, args) ->
      list.append(
        pattern_bindings(callee),
        list.flat_map(args, fn(a) { pattern_bindings(a.value) }),
      )
    ast.EMember(target, _) -> pattern_bindings(target)
    ast.EIndex(target, index) ->
      list.append(pattern_bindings(target), pattern_bindings(index))
    ast.ESlice(target, low, high) ->
      list.flatten([
        pattern_bindings(target),
        list.flat_map(option.values([low]), pattern_bindings),
        list.flat_map(option.values([high]), pattern_bindings),
      ])
    ast.EVector(items) -> list.flat_map(items, pattern_bindings)
    ast.EInterp(parts) ->
      list.flat_map(parts, fn(p) {
        case p {
          ast.ILit(_) -> []
          ast.IExpr(inner) -> pattern_bindings(inner)
        }
      })
    ast.EUsing(path, delimiter) ->
      list.append(
        pattern_bindings(path),
        list.flat_map(option.values([delimiter]), pattern_bindings),
      )
    ast.EWith(value, _) -> pattern_bindings(value)
    ast.EAwait(value) -> pattern_bindings(value)
    _ -> []
  }
}

fn bound_by(pattern: ast.Pattern) -> List(String) {
  case pattern {
    ast.PConstructor(_, bindings) -> bindings
    ast.PVector(elems, rest) ->
      list.append(
        list.filter_map(elems, fn(elem) {
          case elem {
            ast.PElemBind(name) -> Ok(name)
            ast.PElemLit(_) -> Error(Nil)
          }
        }),
        option.values([rest]),
      )
    ast.PString(parts) ->
      list.filter_map(parts, fn(part) {
        case part {
          ast.SPatHole(name) -> Ok(name)
          ast.SPatLit(_) -> Error(Nil)
        }
      })
  }
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

// A module's identity: its absolute path with `.` and `..` collapsed, so the
// same file reached through two different relative paths is one module (and
// closes a cycle when it should).
fn canonical(path: String) -> Result(String, String) {
  use absolute <- result.try(absolute(path))
  filepath.expand(absolute)
  |> result.replace_error("could not resolve the module path " <> path)
}

fn absolute(path: String) -> Result(String, String) {
  case is_absolute(path) {
    True -> Ok(path)
    False ->
      simplifile.current_directory()
      |> result.map(fn(cwd) { filepath.join(normalize(cwd), path) })
      |> result.map_error(fn(e) {
        "could not resolve the current directory: "
        <> simplifile.describe_error(e)
      })
  }
}

// A Unix or UNC root (`/...`), or a Windows drive letter (`C:/...`).
fn is_absolute(path: String) -> Bool {
  case string.starts_with(path, "/"), string.to_graphemes(path) {
    True, _ -> True
    False, [_drive, ":", ..] -> True
    False, _ -> False
  }
}

// `code-examples/x/../lib/text.hive` reads better as `code-examples/lib/text.hive`
// in a message. A path that climbs above its own top cannot be collapsed, so it
// is shown as written.
fn shorten(path: String) -> String {
  filepath.expand(path) |> result.unwrap(path)
}

fn directory_of(path: String) -> String {
  case filepath.directory_name(path) {
    "" -> "."
    dir -> dir
  }
}

/// Normalise Windows-style backslashes to forward slashes, so import paths and
/// the `filepath` helpers agree regardless of how a path was written.
fn normalize(path: String) -> String {
  string.replace(path, "\\", "/")
}
