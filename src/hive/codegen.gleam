//// Generates Go source (the `main` package) from an Hive `ast.Module`.
////
//// Hive types map onto Go as follows:
////   * A type with no variants becomes a plain `struct`.
////   * A type with variants becomes an `interface` plus one `struct` per
////     variant (a tagged union). Common fields are appended to every variant,
////     which is also the positional order used by constructors.
////   * Vectors (`Str[3]`, `Str[dyn]`, ...) all become Go slices.
////   * Atoms become `hive.Atom` values; the compiler assigns each distinct
////     atom a small integer (#False=0, #True=1 first) and registers the name
////     table so `echo` can print an atom's visual form.
////   * `Result` and `Table`/`TableError` are provided by the generated `hive`
////     runtime package.
////
//// A lightweight type inference pass (`Ty`) tracks locals so codegen can pick
//// the right lowering for overloaded syntax: `+` on vectors becomes
//// `hive.Concat`, atoms coerce to their decimal Str form next to strings,
//// division becomes zero-safe, and vector literals get their Go element type.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import hive/ast
import hive/runtime

/// The inferred Hive type of an expression, as far as codegen needs to know.
pub type Ty {
  TyStr
  TyInt
  TyFloat
  TyBool
  TyAtom
  TyTable
  TyResult(ok: Ty, err: Ty)
  TyVec(Ty)
  TyCustom(String)
  /// A struct provided by the runtime (`hive.HttpRequest`, ...); the name is
  /// unqualified, see `builtin_fields`.
  TyBuiltin(String)
  TyUnknown
}

/// The runtime-provided struct types reachable from Hive source as `hive.X`.
/// Field order is the positional-constructor order.
pub fn builtin_fields(name: String) -> Option(List(#(String, Ty))) {
  case name {
    "HttpRequest" ->
      Some([
        #("method", TyStr),
        #("url", TyStr),
        #("headers", TyTable),
        #("body", TyStr),
      ])
    "HttpResponse" ->
      Some([#("status", TyInt), #("headers", TyTable), #("body", TyStr)])
    "HttpError" -> Some([#("url", TyStr), #("message", TyStr)])
    "TableError" -> Some([#("path", TyStr), #("message", TyStr)])
    "JsonError" ->
      Some([#("path", TyStr), #("expected", TyStr), #("found", TyStr)])
    "CryptoError" -> Some([#("reason", TyStr), #("message", TyStr)])
    "ConversionError" -> Some([#("input", TyStr), #("message", TyStr)])
    "EnvironmentError" -> Some([#("key", TyStr), #("message", TyStr)])
    "JwtHeader" ->
      Some([#("alg", TyStr), #("typ", TyStr), #("kid", TyStr)])
    "SqlError" -> Some([#("message", TyStr)])
    "DatabaseDriver" -> Some([#("name", TyStr)])
    _ -> None
  }
}

/// The namespace a builtin type must be referenced through (each stdlib module
/// owns its types). The core types the language uses without a module — the
/// `TableError` that `using` yields — stay directly on `hive`.
pub fn builtin_qualifier(name: String) -> String {
  case name {
    "HttpRequest" | "HttpResponse" | "HttpError" -> "hive.http"
    "JsonError" -> "hive.json"
    "CryptoError" | "JwtHeader" -> "hive.crypto"
    "ConversionError" -> "hive.conv"
    "EnvironmentError" -> "hive.env"
    "SqlError" | "SqlConnection" | "DatabaseDriver" -> "hive.sql"
    _ -> "hive"
  }
}

/// A binding introduced by an `is` pattern: name, the Go expression that
/// produces its value, and its inferred type.
type Bind =
  #(String, String, Ty)

/// Assign call arguments to parameters: named arguments claim their
/// parameter, then the unnamed ones fill whatever is left in declaration
/// order. Returns the provided (name, value) pairs in declaration order plus
/// any leftover positional arguments (validation rejects those earlier for
/// known targets).
pub fn assign_args(
  args: List(ast.Arg),
  names: List(String),
) -> #(List(#(String, ast.Expr)), List(ast.Expr)) {
  let named =
    list.fold(args, dict.new(), fn(acc, a) {
      case a.name {
        Some(n) -> dict.insert(acc, n, a.value)
        None -> acc
      }
    })
  let positional =
    list.filter_map(args, fn(a) {
      case a.name {
        None -> Ok(a.value)
        Some(_) -> Error(Nil)
      }
    })
  let #(assigned, leftover) =
    list.fold(names, #([], positional), fn(acc, name) {
      let #(assigned, pos) = acc
      case dict.get(named, name) {
        Ok(value) -> #([#(name, value), ..assigned], pos)
        Error(_) ->
          case pos {
            [p, ..rest] -> #([#(name, p), ..assigned], rest)
            [] -> #(assigned, [])
          }
      }
    })
  #(list.reverse(assigned), leftover)
}

type Env {
  Env(
    types: Dict(String, ast.Decl),
    /// Signatures of every proc/func/query: named parameter types and the
    /// return type.
    sigs: Dict(String, #(List(#(String, Ty)), Ty)),
    /// Types of the local variables currently in scope.
    locals: Dict(String, Ty),
    /// Active `is`-binding substitutions: while generating the rest of a
    /// condition, a bound name reads through to its Go accessor expression.
    subst: Dict(String, String),
    /// The current function's return type (drives `return` coercions).
    ret: Ty,
    /// The program's atom table: name -> compiled integer value.
    atoms: Dict(String, Int),
    /// Names of the `async func`s: a bare call to one is fire-and-forget (a
    /// goroutine); an `await`ed call blocks for its value.
    asyncs: List(String),
    /// Which in-scope locals were declared `mut`. Used to decide whether a
    /// vector binding may share storage (both sides mutable) or must be cloned
    /// (either side immutable). Names absent here are treated as immutable —
    /// which is correct for params, `for each` bindings and `is`-bindings.
    muts: Dict(String, Bool),
  )
}

pub fn generate(module: ast.Module) -> String {
  let types = collect_types(module.decls)
  let atom_table = collect_atoms(module)
  let atoms =
    atom_table
    |> list.index_map(fn(name, i) { #(name, i) })
    |> dict.from_list
  let sigs = collect_sigs(types, module.decls)
  let asyncs =
    list.filter_map(module.decls, fn(d) {
      case d {
        ast.FuncDecl(name, _, _, _, True) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  let env =
    Env(types, sigs, dict.new(), dict.new(), TyUnknown, atoms, asyncs, dict.new())

  let type_code =
    module.decls
    |> list.filter_map(fn(d) {
      case d {
        ast.TypeDecl(..) -> Ok(gen_type_decl(env, d))
        _ -> Error(Nil)
      }
    })
    |> string.join("\n")

  let atom_code = gen_atom_setup(atom_table)

  let fn_code =
    module.decls
    |> list.filter_map(fn(d) {
      case d {
        ast.ProcDecl(name, params, ret, body)
        | ast.FuncDecl(name, params, ret, body, _) ->
          Ok(gen_fn_decl(env, name, params, ret, body))
        ast.QueryDecl(name, params, ret, sql) ->
          Ok(gen_query_decl(env, name, params, ret, sql))
        ast.TypeDecl(..) -> Error(Nil)
      }
    })
    |> string.join("\n")

  let json_code = gen_json_support(env, module)

  let body = type_code <> "\n" <> atom_code <> json_code <> fn_code
  gen_header(body) <> "\n" <> body
}

// ---------------------------------------------------------------------------
// hive.json usage detection
// ---------------------------------------------------------------------------

fn uses_json_module(module: ast.Module) -> Bool {
  list.any(module.decls, fn(d) {
    case d {
      ast.ProcDecl(_, _, _, body) | ast.FuncDecl(_, _, _, body, _) ->
        uses_json_stmts(body)
      ast.QueryDecl(_, _, _, sql) ->
        list.any(sql, fn(p) {
          case p {
            ast.ILit(_) -> False
            ast.IExpr(e) -> uses_json_expr(e)
          }
        })
      ast.TypeDecl(..) -> False
    }
  })
}

fn uses_json_stmts(stmts: List(ast.Stmt)) -> Bool {
  list.any(stmts, fn(s) {
    case s {
      ast.SVarDecl(_, value, _) -> uses_json_expr(value)
      ast.STypedDecl(_, _, value, _) -> uses_json_expr(value)
      ast.SAssign(target, value) ->
        uses_json_expr(target) || uses_json_expr(value)
      ast.SReturn(None) -> False
      ast.SReturn(Some(e)) -> uses_json_expr(e)
      ast.SEcho(e) -> uses_json_expr(e)
      ast.SAssert(e) -> uses_json_expr(e)
      ast.SBreak | ast.SContinue -> False
      ast.SExpr(e) -> uses_json_expr(e)
      ast.SIf(branches, else_body) ->
        list.any(branches, fn(b) {
          uses_json_expr(b.cond) || uses_json_stmts(b.body)
        })
        || case else_body {
          Some(body) -> uses_json_stmts(body)
          None -> False
        }
      ast.SFor(init, cond, post, body) ->
        uses_json_opt_stmt(init)
        || uses_json_opt(cond)
        || uses_json_opt_stmt(post)
        || uses_json_stmts(body)
      ast.SForEach(_, _, iterable, body) ->
        uses_json_expr(iterable) || uses_json_stmts(body)
    }
  })
}

fn uses_json_opt_stmt(o: Option(ast.Stmt)) -> Bool {
  case o {
    Some(s) -> uses_json_stmts([s])
    None -> False
  }
}

fn uses_json_expr(e: ast.Expr) -> Bool {
  case e {
    ast.EWith(_, _) -> True
    ast.ECall(ast.EMember(ast.EMember(ast.EIdent("hive"), "json"), _), _) ->
      True
    // `hive.crypto.jwtSign` reuses the derived JSON encoders for its claims
    // (jwtVerify/jwtDecode are `EWith`, already covered above).
    ast.ECall(
      ast.EMember(ast.EMember(ast.EIdent("hive"), "crypto"), "jwtSign"),
      _,
    ) -> True
    ast.EInt(_)
    | ast.EFloat(_)
    | ast.EString(_)
    | ast.EBool(_)
    | ast.EAtom(_)
    | ast.EIdent(_) -> False
    ast.EInterp(parts) ->
      list.any(parts, fn(p) {
        case p {
          ast.ILit(_) -> False
          ast.IExpr(inner) -> uses_json_expr(inner)
        }
      })
    ast.EVector(items) -> list.any(items, uses_json_expr)
    ast.EMember(target, _) -> uses_json_expr(target)
    ast.ECall(callee, args) ->
      uses_json_expr(callee)
      || list.any(args, fn(a) { uses_json_expr(a.value) })
    ast.EIndex(target, index) ->
      uses_json_expr(target) || uses_json_expr(index)
    ast.ESlice(target, low, high) ->
      uses_json_expr(target)
      || uses_json_opt(low)
      || uses_json_opt(high)
    ast.EBinary(_, l, r) -> uses_json_expr(l) || uses_json_expr(r)
    ast.EIs(subject, _) -> uses_json_expr(subject)
    ast.EUsing(path, delim) -> uses_json_expr(path) || uses_json_opt(delim)
    ast.EAwait(value) -> uses_json_expr(value)
  }
}

fn uses_json_opt(o: Option(ast.Expr)) -> Bool {
  case o {
    Some(e) -> uses_json_expr(e)
    None -> False
  }
}

fn collect_types(decls: List(ast.Decl)) -> Dict(String, ast.Decl) {
  list.fold(decls, dict.new(), fn(acc, d) {
    case d {
      ast.TypeDecl(name, _, _) -> dict.insert(acc, name, d)
      _ -> acc
    }
  })
}

fn collect_sigs(
  types: Dict(String, ast.Decl),
  decls: List(ast.Decl),
) -> Dict(String, #(List(#(String, Ty)), Ty)) {
  list.fold(decls, dict.new(), fn(acc, d) {
    case d {
      ast.ProcDecl(name, params, ret, _)
      | ast.FuncDecl(name, params, ret, _, _)
      | ast.QueryDecl(name, params, ret, _) -> {
        let ptys =
          list.map(params, fn(p) { #(p.name, ty_of_type_expr(types, p.typ)) })
        dict.insert(acc, name, #(ptys, ty_of_type_expr(types, ret)))
      }
      ast.TypeDecl(..) -> acc
    }
  })
}

// ---------------------------------------------------------------------------
// The atom table
// ---------------------------------------------------------------------------
// Atoms are collected in order of appearance; #False and #True always occupy
// slots 0 and 1 ("the first atoms to be included on the table").

fn collect_atoms(module: ast.Module) -> List(String) {
  let found =
    list.fold(module.decls, [], fn(acc, d) {
      case d {
        ast.ProcDecl(_, _, _, body) | ast.FuncDecl(_, _, _, body, _) ->
          atoms_in_stmts(body, acc)
        ast.QueryDecl(_, _, _, sql) -> atoms_in_parts(sql, acc)
        ast.TypeDecl(..) -> acc
      }
    })
  let customs =
    found
    |> list.reverse
    |> list.filter(fn(name) { name != "False" && name != "True" })
  ["False", "True", ..customs]
}

fn add_atom(acc: List(String), name: String) -> List(String) {
  case list.contains(acc, name) {
    True -> acc
    False -> [name, ..acc]
  }
}

fn atoms_in_stmts(stmts: List(ast.Stmt), acc: List(String)) -> List(String) {
  list.fold(stmts, acc, fn(acc, s) {
    case s {
      ast.SVarDecl(_, value, _) -> atoms_in_expr(value, acc)
      ast.STypedDecl(_, _, value, _) -> atoms_in_expr(value, acc)
      ast.SAssign(target, value) ->
        atoms_in_expr(value, atoms_in_expr(target, acc))
      ast.SReturn(None) -> acc
      ast.SReturn(Some(e)) -> atoms_in_expr(e, acc)
      ast.SEcho(e) -> atoms_in_expr(e, acc)
      ast.SAssert(e) -> atoms_in_expr(e, acc)
      ast.SBreak | ast.SContinue -> acc
      ast.SExpr(e) -> atoms_in_expr(e, acc)
      ast.SIf(branches, else_body) -> {
        let acc =
          list.fold(branches, acc, fn(acc, b) {
            atoms_in_stmts(b.body, atoms_in_expr(b.cond, acc))
          })
        case else_body {
          Some(body) -> atoms_in_stmts(body, acc)
          None -> acc
        }
      }
      ast.SFor(init, cond, post, body) -> {
        let acc = atoms_in_opt_stmt(init, acc)
        let acc = atoms_in_opt(cond, acc)
        let acc = atoms_in_opt_stmt(post, acc)
        atoms_in_stmts(body, acc)
      }
      ast.SForEach(_, _, iterable, body) ->
        atoms_in_stmts(body, atoms_in_expr(iterable, acc))
    }
  })
}

fn atoms_in_opt_stmt(o: Option(ast.Stmt), acc: List(String)) -> List(String) {
  case o {
    Some(s) -> atoms_in_stmts([s], acc)
    None -> acc
  }
}

fn atoms_in_parts(parts: List(ast.IPart), acc: List(String)) -> List(String) {
  list.fold(parts, acc, fn(acc, p) {
    case p {
      ast.ILit(_) -> acc
      ast.IExpr(e) -> atoms_in_expr(e, acc)
    }
  })
}

fn atoms_in_expr(e: ast.Expr, acc: List(String)) -> List(String) {
  case e {
    ast.EAtom(name) -> add_atom(acc, name)
    ast.EInt(_) | ast.EFloat(_) | ast.EString(_) | ast.EBool(_) | ast.EIdent(_) ->
      acc
    ast.EInterp(parts) -> atoms_in_parts(parts, acc)
    ast.EVector(items) -> list.fold(items, acc, fn(acc, i) { atoms_in_expr(i, acc) })
    ast.EMember(target, _) -> atoms_in_expr(target, acc)
    ast.ECall(callee, args) ->
      list.fold(args, atoms_in_expr(callee, acc), fn(acc, a) {
        atoms_in_expr(a.value, acc)
      })
    ast.EIndex(target, index) -> atoms_in_expr(index, atoms_in_expr(target, acc))
    ast.ESlice(target, low, high) ->
      atoms_in_opt(high, atoms_in_opt(low, atoms_in_expr(target, acc)))
    ast.EBinary(_, l, r) -> atoms_in_expr(r, atoms_in_expr(l, acc))
    ast.EIs(subject, _) -> atoms_in_expr(subject, acc)
    ast.EUsing(path, delim) -> atoms_in_opt(delim, atoms_in_expr(path, acc))
    ast.EWith(value, _) -> atoms_in_expr(value, acc)
    ast.EAwait(value) -> atoms_in_expr(value, acc)
  }
}

fn atoms_in_opt(o: Option(ast.Expr), acc: List(String)) -> List(String) {
  case o {
    Some(e) -> atoms_in_expr(e, acc)
    None -> acc
  }
}

// Emits the atom constants and the init that registers the name table. When
// the program only ever uses #True/#False the runtime's default table
// suffices and nothing is emitted.
fn gen_atom_setup(table: List(String)) -> String {
  let customs = list.drop(table, 2)
  case customs {
    [] -> ""
    _ -> {
      let consts =
        customs
        |> list.index_map(fn(name, i) {
          "\tatom_" <> name <> " hive.Atom = " <> int.to_string(i + 2) <> "\n"
        })
        |> string.concat
      let names =
        table
        |> list.map(fn(n) { "\"" <> n <> "\"" })
        |> string.join(", ")
      "const (\n"
      <> consts
      <> ")\n\nfunc init() {\n\thive.InitAtoms([]string{"
      <> names
      <> "})\n}\n"
    }
  }
}

// ---------------------------------------------------------------------------
// Header / imports (inferred by scanning the generated body)
// ---------------------------------------------------------------------------

fn gen_header(body: String) -> String {
  let imports =
    list.flatten([
      case string.contains(body, "fmt.") {
        True -> ["\t\"fmt\""]
        False -> []
      },
      case string.contains(body, "hive.") {
        True -> ["\t\"" <> runtime.go_module <> "/hive\""]
        False -> []
      },
    ])

  let import_block = case imports {
    [] -> ""
    _ -> "import (\n" <> string.join(imports, "\n") <> "\n)\n"
  }

  "package main\n\n" <> import_block
}

// ---------------------------------------------------------------------------
// Types (Hive -> Go, and Hive -> inferred Ty)
// ---------------------------------------------------------------------------

fn ty_of_type_expr(types: Dict(String, ast.Decl), t: ast.TypeExpr) -> Ty {
  case t {
    ast.TVoid -> TyUnknown
    // A builtin type, resolved only through its own namespace
    // (`hive.http.HttpRequest`, `hive.TableError`). A wrong or bare qualifier
    // does not resolve.
    ast.TName(Some(pkg), name, dims) ->
      case builtin_fields(name) {
        Some(_) ->
          case pkg == builtin_qualifier(name) {
            True -> wrap_dims(TyBuiltin(name), dims)
            False -> wrap_dims(TyUnknown, dims)
          }
        None -> wrap_dims(TyUnknown, dims)
      }
    ast.TName(None, name, dims) -> wrap_dims(base_ty(types, name), dims)
  }
}

// Whether a type qualifier names the `hive` standard library (`hive`,
// `hive.http`, `hive.sql`, ...).
fn is_hive_pkg(pkg: String) -> Bool {
  pkg == "hive" || string.starts_with(pkg, "hive.")
}

fn base_ty(types: Dict(String, ast.Decl), name: String) -> Ty {
  case name {
    "Str" | "String" -> TyStr
    "Int" -> TyInt
    "Float" -> TyFloat
    "Bool" -> TyBool
    "Atom" -> TyAtom
    "Table" -> TyTable
    _ ->
      case dict.has_key(types, name) {
        True -> TyCustom(name)
        False -> TyUnknown
      }
  }
}

fn wrap_dims(base: Ty, dims: List(ast.Dim)) -> Ty {
  list.fold(dims, base, fn(t, _) { TyVec(t) })
}

fn gen_type(t: ast.TypeExpr) -> String {
  case t {
    ast.TVoid -> ""
    ast.TName(pkg, name, dims) -> {
      let prefix = string.repeat("[]", list.length(dims))
      let base = case pkg {
        // A `hive.<module>` namespace is only organisational: every builtin
        // type lives in the one Go `hive` package (`hive.http.HttpRequest`
        // -> `hive.HttpRequest`).
        Some(p) ->
          case is_hive_pkg(p) {
            True -> "hive." <> name
            False -> p <> "." <> name
          }
        None -> map_base_type(name)
      }
      prefix <> base
    }
  }
}

fn map_base_type(name: String) -> String {
  case name {
    "Str" | "String" -> "string"
    "Int" -> "int"
    "Bool" -> "bool"
    "Float" -> "float64"
    "Atom" -> "hive.Atom"
    "Table" -> "hive.Table"
    _ -> name
  }
}

/// The Go spelling of an inferred type (used for vector literal elements).
fn ty_to_go(ty: Ty) -> String {
  case ty {
    TyStr -> "string"
    TyInt -> "int"
    TyFloat -> "float64"
    TyBool -> "bool"
    TyAtom -> "hive.Atom"
    TyTable -> "hive.Table"
    TyVec(t) -> "[]" <> ty_to_go(t)
    TyCustom(name) -> name
    TyBuiltin(name) -> "hive." <> name
    TyResult(_, _) -> "any"
    TyUnknown -> "any"
  }
}

// ---------------------------------------------------------------------------
// Type declarations
// ---------------------------------------------------------------------------

fn gen_type_decl(env: Env, d: ast.Decl) -> String {
  case d {
    ast.TypeDecl(name, variants, commons) ->
      case variants {
        [] -> gen_struct_type(env, name, commons)
        _ -> gen_union_type(env, name, variants, commons)
      }
    _ -> ""
  }
}

fn gen_struct_type(env: Env, name: String, fields: List(ast.Field)) -> String {
  "type " <> name <> " struct {\n" <> gen_fields(env, fields) <> "}\n"
}

fn gen_union_type(
  env: Env,
  name: String,
  variants: List(ast.Variant),
  commons: List(ast.Field),
) -> String {
  let iface = "type " <> name <> " interface {\n\tis" <> name <> "()\n}\n"
  let variant_code =
    variants
    |> list.map(fn(v) { gen_variant(env, name, v, commons) })
    |> string.concat
  iface <> variant_code
}

fn gen_variant(
  env: Env,
  type_name: String,
  v: ast.Variant,
  commons: List(ast.Field),
) -> String {
  let struct_name = type_name <> v.name
  let all_fields = list.append(v.fields, commons)
  "type "
  <> struct_name
  <> " struct {\n"
  <> gen_fields(env, all_fields)
  <> "}\n"
  <> "func ("
  <> struct_name
  <> ") is"
  <> type_name
  <> "() {}\n"
}

fn gen_fields(_env: Env, fields: List(ast.Field)) -> String {
  fields
  |> list.map(fn(f) {
    "\t" <> exported(f.name) <> " " <> gen_type(f.typ) <> "\n"
  })
  |> string.concat
}

// ---------------------------------------------------------------------------
// Derived JSON decoders/encoders
// ---------------------------------------------------------------------------
// When a module touches `hive.json`, every user type gets a derived
// `jsonDecode_T` and `jsonEncode_T` in the generated program. Decoding is
// strict: exact keys, exact static vector lengths, and unions read from the
// `{"VariantName": {...}}` shape (JSON null selects the first field-less
// variant when one exists).

fn gen_json_support(env: Env, module: ast.Module) -> String {
  case uses_json_module(module) {
    False -> ""
    True ->
      module.decls
      |> list.filter_map(fn(d) {
        case d {
          ast.TypeDecl(name, variants, commons) ->
            Ok(
              gen_json_decoder_fn(env, name, variants, commons)
              <> gen_json_encoder_fn(env, name, variants, commons),
            )
          _ -> Error(Nil)
        }
      })
      |> string.concat
  }
}

/// A Go expression referencing (or inlining) the decoder for a Hive type:
/// something of type `func(hive.JsonValue, string) (T, *hive.JsonError)`.
fn json_decoder_ref(env: Env, t: ast.TypeExpr) -> String {
  case t {
    ast.TName(None, name, []) ->
      case name {
        "Str" | "String" -> "hive.JsonStr"
        "Int" -> "hive.JsonInt"
        "Float" -> "hive.JsonFloat"
        "Bool" -> "hive.JsonBool"
        "Atom" -> "hive.JsonAtom"
        "Table" -> "hive.JsonFlatten"
        _ ->
          case dict.has_key(env.types, name) {
            True -> "jsonDecode_" <> name
            False -> json_decoder_unsupported(t)
          }
      }
    ast.TName(pkg, name, [dim, ..rest]) -> {
      let inner = ast.TName(pkg, name, rest)
      let call = case dim {
        ast.DimStatic(n) ->
          "hive.JsonVecN(v, p, "
          <> int.to_string(n)
          <> ", "
          <> json_decoder_ref(env, inner)
          <> ")"
        _ -> "hive.JsonVec(v, p, " <> json_decoder_ref(env, inner) <> ")"
      }
      "func(v hive.JsonValue, p string) ("
      <> gen_type(t)
      <> ", *hive.JsonError) { return "
      <> call
      <> " }"
    }
    _ -> json_decoder_unsupported(t)
  }
}

fn json_decoder_unsupported(t: ast.TypeExpr) -> String {
  "func(v hive.JsonValue, p string) ("
  <> gen_type(t)
  <> ", *hive.JsonError) { var zero "
  <> gen_type(t)
  <> "; return zero, &hive.JsonError{Path: p, Expected: \"a decodable type\", Found: \"an unsupported type\"} }"
}

fn gen_json_decoder_fn(
  env: Env,
  name: String,
  variants: List(ast.Variant),
  commons: List(ast.Field),
) -> String {
  case variants {
    [] -> {
      let zero = name <> "{}"
      "func jsonDecode_"
      <> name
      <> "(v hive.JsonValue, path string) ("
      <> name
      <> ", *hive.JsonError) {\n"
      <> "\tobj, jerr := hive.JsonObject(v, path)\n"
      <> gen_json_bail(zero)
      <> gen_json_field_decodes(env, commons, "path", zero, 1)
      <> "\treturn "
      <> name
      <> "{"
      <> json_field_inits(commons)
      <> "}, nil\n}\n"
    }
    _ -> {
      let null_case = case
        commons == [],
        list.find(variants, fn(v) { v.fields == [] })
      {
        True, Ok(empty) ->
          "\tif v.Kind == 'n' {\n\t\treturn "
          <> name
          <> "("
          <> name
          <> empty.name
          <> "{}), nil\n\t}\n"
        _, _ -> ""
      }
      let cases =
        variants
        |> list.map(fn(v) {
          let fields = list.append(v.fields, commons)
          "\tcase "
          <> gen_string_lit(v.name)
          <> ":\n\t\tobj, jerr := hive.JsonObject(inner, path+"
          <> gen_string_lit("." <> v.name)
          <> ")\n"
          <> indent_more(gen_json_bail("nil"))
          <> indent_more(gen_json_field_decodes(
            env,
            fields,
            "path+" <> gen_string_lit("." <> v.name),
            "nil",
            2,
          ))
          <> "\t\treturn "
          <> name
          <> "("
          <> name
          <> v.name
          <> "{"
          <> json_field_inits(fields)
          <> "}), nil\n"
        })
        |> string.concat
      let variant_names =
        variants |> list.map(fn(v) { v.name }) |> string.join(", ")
      "func jsonDecode_"
      <> name
      <> "(v hive.JsonValue, path string) ("
      <> name
      <> ", *hive.JsonError) {\n"
      <> null_case
      <> "\tkey, inner, jerr := hive.JsonVariant(v, path)\n"
      <> gen_json_bail("nil")
      <> "\tswitch key {\n"
      <> cases
      <> "\t}\n\treturn nil, &hive.JsonError{Path: path, Expected: "
      <> gen_string_lit("one of " <> variant_names)
      <> ", Found: hive.JsonEncodeStr(key)}\n}\n"
    }
  }
}

fn gen_json_bail(zero: String) -> String {
  "\tif jerr != nil {\n\t\treturn " <> zero <> ", jerr\n\t}\n"
}

fn indent_more(code: String) -> String {
  code
  |> string.split("\n")
  |> list.map(fn(l) {
    case l {
      "" -> ""
      _ -> "\t" <> l
    }
  })
  |> string.join("\n")
}

// JSON fields the type doesn't declare are simply ignored: only declared
// fields are looked up (and missing ones error via JsonField).
fn gen_json_field_decodes(
  env: Env,
  fields: List(ast.Field),
  path: String,
  zero: String,
  indent: Int,
) -> String {
  let pad = tabs(indent)
  let bail = pad <> "if jerr != nil {\n" <> pad <> "\treturn " <> zero <> ", jerr\n" <> pad <> "}\n"
  let decodes =
    fields
    |> list.map(fn(f) {
      pad
      <> "raw_"
      <> f.name
      <> ", jerr := hive.JsonField(obj, "
      <> gen_string_lit(f.name)
      <> ", "
      <> path
      <> ")\n"
      <> bail
      <> pad
      <> "f_"
      <> f.name
      <> ", jerr := "
      <> json_decoder_ref(env, f.typ)
      <> "(raw_"
      <> f.name
      <> ", "
      <> path
      <> "+"
      <> gen_string_lit("." <> f.name)
      <> ")\n"
      <> bail
    })
    |> string.concat
  // With no declared fields `obj` would be unused, which Go rejects.
  case fields {
    [] -> pad <> "_ = obj\n"
    _ -> decodes
  }
}

fn json_field_inits(fields: List(ast.Field)) -> String {
  fields
  |> list.map(fn(f) { exported(f.name) <> ": f_" <> f.name })
  |> string.join(", ")
}

fn gen_json_encoder_fn(
  env: Env,
  name: String,
  variants: List(ast.Variant),
  commons: List(ast.Field),
) -> String {
  case variants {
    [] ->
      "func jsonEncode_"
      <> name
      <> "(x "
      <> name
      <> ") string {\n\treturn "
      <> gen_json_object_encode(env, commons, "x")
      <> "\n}\n"
    _ -> {
      let cases =
        variants
        |> list.map(fn(v) {
          let fields = list.append(v.fields, commons)
          "\tcase "
          <> name
          <> v.name
          <> ":\n\t\t_ = v\n\t\treturn "
          <> gen_string_lit("{\"" <> v.name <> "\":")
          <> " + "
          <> gen_json_object_encode(env, fields, "v")
          <> " + "
          <> gen_string_lit("}")
          <> "\n"
        })
        |> string.concat
      "func jsonEncode_"
      <> name
      <> "(x "
      <> name
      <> ") string {\n\tswitch v := x.(type) {\n"
      <> cases
      <> "\t}\n\treturn \"null\"\n}\n"
    }
  }
}

fn gen_json_object_encode(
  env: Env,
  fields: List(ast.Field),
  receiver: String,
) -> String {
  case fields {
    [] -> gen_string_lit("{}")
    _ -> {
      let pieces =
        fields
        |> list.index_map(fn(f, i) {
          let sep = case i {
            0 -> "{"
            _ -> ","
          }
          gen_string_lit(sep <> "\"" <> f.name <> "\":")
          <> " + "
          <> gen_json_encode(
            ty_of_type_expr(env.types, f.typ),
            receiver <> "." <> exported(f.name),
            0,
          )
        })
        |> string.join(" + ")
      pieces <> " + " <> gen_string_lit("}")
    }
  }
}

// ---------------------------------------------------------------------------
// Procs, funcs and queries
// ---------------------------------------------------------------------------

fn fn_env(env: Env, params: List(ast.Field), ret: ast.TypeExpr) -> Env {
  let locals =
    list.fold(params, dict.new(), fn(acc, p) {
      dict.insert(acc, p.name, ty_of_type_expr(env.types, p.typ))
    })
  Env(..env, locals: locals, subst: dict.new(), ret: ty_of_type_expr(env.types, ret))
}

fn gen_fn_decl(
  env: Env,
  name: String,
  params: List(ast.Field),
  ret: ast.TypeExpr,
  body: List(ast.Stmt),
) -> String {
  let env = fn_env(env, params, ret)
  let param_str =
    params
    |> list.map(fn(p) { escape_ident(p.name) <> " " <> gen_type(p.typ) })
    |> string.join(", ")
  let ret_str = case ret {
    ast.TVoid -> ""
    _ -> " " <> gen_type(ret)
  }
  let terminator = case ret {
    ast.TVoid -> ""
    _ -> gen_terminator(body)
  }
  "func "
  <> escape_ident(name)
  <> "("
  <> param_str
  <> ")"
  <> ret_str
  <> " {\n"
  <> gen_stmts(env, body, 1)
  <> terminator
  <> "}\n"
}

// A query is a pure function that assembles its inline SQL into a string;
// every interpolated value passes through hive.SqlParam, which quotes and
// sanitizes it at runtime.
fn gen_query_decl(
  env: Env,
  name: String,
  params: List(ast.Field),
  ret: ast.TypeExpr,
  sql: List(ast.IPart),
) -> String {
  let env = fn_env(env, params, ret)
  let param_str =
    params
    |> list.map(fn(p) { escape_ident(p.name) <> " " <> gen_type(p.typ) })
    |> string.join(", ")
  let pieces =
    sql
    |> list.map(fn(p) {
      case p {
        ast.ILit(s) -> gen_string_lit(s)
        ast.IExpr(e) -> "hive.SqlParam(" <> gen_expr(env, e) <> ")"
      }
    })
  let value = case pieces {
    [] -> "\"\""
    _ -> string.join(pieces, " + ")
  }
  "func "
  <> escape_ident(name)
  <> "("
  <> param_str
  <> ") "
  <> gen_type(ret)
  <> " {\n\treturn "
  <> value
  <> "\n}\n"
}

// Go requires every path of a non-void function to return. Hive relies on
// exhaustiveness analysis the compiler doesn't fully model here, so any
// function that doesn't syntactically end in a `return` gets an explicit
// `panic` to satisfy the Go compiler (it is genuinely unreachable at runtime).
fn gen_terminator(body: List(ast.Stmt)) -> String {
  case list.last(body) {
    Ok(ast.SReturn(_)) -> ""
    _ -> "\tpanic(\"hive: unreachable\")\n"
  }
}

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------
// Statement generation threads the environment forward so declarations and
// pattern bindings are visible to the inference of later statements.

fn gen_stmts(env: Env, stmts: List(ast.Stmt), indent: Int) -> String {
  case stmts {
    [] -> ""
    [s, ..rest] -> {
      let #(code, env2) = gen_stmt(env, s, rest, indent)
      code <> gen_stmts(env2, rest, indent)
    }
  }
}

fn gen_stmt(
  env: Env,
  stmt: ast.Stmt,
  following: List(ast.Stmt),
  indent: Int,
) -> #(String, Env) {
  let pad = tabs(indent)
  case stmt {
    ast.SVarDecl(name, value, mutable) -> {
      let ty = infer(env, value)
      let rhs = maybe_clone(env, mutable, value, gen_expr(env, value))
      let decl = pad <> escape_ident(name) <> " := " <> rhs <> "\n"
      let env2 =
        Env(
          ..env,
          locals: dict.insert(env.locals, name, ty),
          muts: dict.insert(env.muts, name, mutable),
        )
      #(decl <> guard(following, name, pad), env2)
    }
    ast.STypedDecl(typ, name, value, mutable) -> {
      let ty = ty_of_type_expr(env.types, typ)
      let rhs = maybe_clone(env, mutable, value, coerce(env, value, ty))
      let decl =
        pad
        <> "var "
        <> escape_ident(name)
        <> " "
        <> gen_type(typ)
        <> " = "
        <> rhs
        <> "\n"
      let env2 =
        Env(
          ..env,
          locals: dict.insert(env.locals, name, ty),
          muts: dict.insert(env.muts, name, mutable),
        )
      #(decl <> guard(following, name, pad), env2)
    }
    ast.SReturn(None) -> #(pad <> "return\n", env)
    ast.SReturn(Some(e)) -> #(
      pad <> "return " <> coerce(env, e, env.ret) <> "\n",
      env,
    )
    ast.SEcho(e) -> #(pad <> "fmt.Println(" <> gen_expr(env, e) <> ")\n", env)
    ast.SAssert(e) -> {
      let #(cond, _) = gen_condition(env, e)
      #(pad <> "hive.Assert(" <> cond <> ")\n", env)
    }
    ast.SBreak -> #(pad <> "break\n", env)
    ast.SContinue -> #(pad <> "continue\n", env)
    ast.SAssign(target, value) -> {
      let ty = infer(env, target)
      // A whole-variable reassignment (`b = a`) is a rebinding, so it copies
      // when the source is immutable (the target must be mutable to be assigned
      // at all). An element/field assignment (`v[i] = ...`) writes into
      // existing storage and must never copy.
      let rendered = coerce(env, value, ty)
      let rhs = case target {
        ast.EIdent(_) -> maybe_clone(env, True, value, rendered)
        _ -> rendered
      }
      #(pad <> gen_expr(env, target) <> " = " <> rhs <> "\n", env)
    }
    // `append(v, x)` used as a statement mutates `v` in place, which Go models
    // by reassigning the (possibly reallocated) slice back to `v`.
    ast.SExpr(ast.ECall(ast.EIdent("append"), args)) -> {
      let target = case args {
        [ast.Arg(_, t), ..] -> gen_expr(env, t)
        [] -> "_"
      }
      #(pad <> target <> " = " <> gen_append(env, args) <> "\n", env)
    }
    ast.SExpr(e) -> {
      let code = gen_expr(env, e)
      // A bare call to an `async func` is fire-and-forget: run it on its own
      // goroutine so it does not block the caller.
      let stmt = case is_async_call(env, e) {
        True -> "go " <> code
        False -> code
      }
      #(pad <> stmt <> "\n", env)
    }
    ast.SIf(branches, else_body) -> #(
      gen_if(env, branches, else_body, indent),
      env,
    )
    // A C-style loop maps straight onto Go's `for init; cond; post { }`. The
    // loop variable is scoped to the loop (env is returned unchanged), matching
    // Go's own scoping.
    ast.SFor(init, cond, post, body) -> {
      let #(init_str, loop_env) = case init {
        Some(s) -> gen_for_clause(env, s)
        None -> #("", env)
      }
      let cond_str = case cond {
        Some(e) -> {
          let #(c, _) = gen_condition(loop_env, e)
          c
        }
        None -> ""
      }
      let #(post_str, _) = case post {
        Some(s) -> gen_for_clause(loop_env, s)
        None -> #("", loop_env)
      }
      let loop_var = case init {
        Some(ast.SVarDecl(name, _, _)) | Some(ast.STypedDecl(_, name, _, _)) ->
          Some(name)
        _ -> None
      }
      // Go rejects a loop variable that is never read; guard the rare case
      // where it appears in none of the condition, post clause or body.
      let body_guard = case loop_var {
        Some(name) ->
          case
            uses_in_opt(cond, name)
            || uses_in_opt_stmt(post, name)
            || uses_in_stmts(body, name)
          {
            True -> ""
            False -> tabs(indent + 1) <> "_ = " <> escape_ident(name) <> "\n"
          }
        None -> ""
      }
      let code =
        pad
        <> "for "
        <> init_str
        <> "; "
        <> cond_str
        <> "; "
        <> post_str
        <> " {\n"
        <> body_guard
        <> gen_stmts(loop_env, body, indent + 1)
        <> pad
        <> "}\n"
      #(code, env)
    }
    // A for-each iterates a vector with Go's `range`, binding the value (the
    // index is discarded).
    ast.SForEach(name, elem_type, iterable, body) -> {
      // The element type comes from an explicit `name: T` annotation when one
      // is given, otherwise it is inferred from the vector being iterated.
      let elem_ty = case elem_type {
        Some(t) -> ty_of_type_expr(env.types, t)
        None -> elem_ty_of(infer(env, iterable))
      }
      let loop_env = Env(..env, locals: dict.insert(env.locals, name, elem_ty))
      let body_guard = case uses_in_stmts(body, name) {
        True -> ""
        False -> tabs(indent + 1) <> "_ = " <> escape_ident(name) <> "\n"
      }
      let code =
        pad
        <> "for _, "
        <> escape_ident(name)
        <> " := range "
        <> gen_expr(env, iterable)
        <> " {\n"
        <> body_guard
        <> gen_stmts(loop_env, body, indent + 1)
        <> pad
        <> "}\n"
      #(code, env)
    }
  }
}

// Generates the inline Go for a for-loop's init or post clause (no leading
// indentation, no trailing newline — it sits inside the `for ( ; ; )` header)
// and threads any variable it declares into the returned environment.
fn gen_for_clause(env: Env, stmt: ast.Stmt) -> #(String, Env) {
  case stmt {
    // A loop-init binding is implicitly mutable (the post clause advances it).
    ast.SVarDecl(name, value, _) -> {
      let ty = infer(env, value)
      let rhs = maybe_clone(env, True, value, gen_expr(env, value))
      #(
        escape_ident(name) <> " := " <> rhs,
        Env(
          ..env,
          locals: dict.insert(env.locals, name, ty),
          muts: dict.insert(env.muts, name, True),
        ),
      )
    }
    ast.STypedDecl(typ, name, value, _) -> {
      let ty = ty_of_type_expr(env.types, typ)
      let rhs = maybe_clone(env, True, value, coerce(env, value, ty))
      #(
        escape_ident(name) <> " := " <> rhs,
        Env(
          ..env,
          locals: dict.insert(env.locals, name, ty),
          muts: dict.insert(env.muts, name, True),
        ),
      )
    }
    ast.SAssign(target, value) -> {
      let ty = infer(env, target)
      let rendered = coerce(env, value, ty)
      let rhs = case target {
        ast.EIdent(_) -> maybe_clone(env, True, value, rendered)
        _ -> rendered
      }
      #(gen_expr(env, target) <> " = " <> rhs, env)
    }
    // `append(v, x)` advances a mutable vector, reassigning the result back.
    ast.SExpr(ast.ECall(ast.EIdent("append"), args)) -> {
      let target = case args {
        [ast.Arg(_, t), ..] -> gen_expr(env, t)
        [] -> "_"
      }
      #(target <> " = " <> gen_append(env, args), env)
    }
    ast.SExpr(e) -> #(gen_expr(env, e), env)
    // Other statement shapes aren't valid init/post clauses; emit nothing.
    _ -> #("", env)
  }
}

// `uses_in_stmt` lifted over an optional statement (for a for loop's post
// clause).
fn uses_in_opt_stmt(o: Option(ast.Stmt), name: String) -> Bool {
  case o {
    Some(s) -> uses_in_stmt(s, name)
    None -> False
  }
}

// The element type produced by iterating a value of the given type: a vector
// yields its element type, and a Table (a `Str[dyn][dyn]`) yields a row.
fn elem_ty_of(ty: Ty) -> Ty {
  case ty {
    TyVec(t) -> t
    TyTable -> TyVec(TyStr)
    _ -> TyUnknown
  }
}

// Whether `e` is a direct call to an `async func` (so a bare-statement call is
// fire-and-forget). An `await`ed call is an `EAwait`, not a bare `ECall`, so it
// never matches here.
fn is_async_call(env: Env, e: ast.Expr) -> Bool {
  case e {
    ast.ECall(ast.EIdent(name), _) -> list.contains(env.asyncs, name)
    _ -> False
  }
}

// Go rejects unused local bindings, so emit a blank assignment when a declared
// name is never referenced in the statements that can see it.
fn guard(scope: List(ast.Stmt), name: String, pad: String) -> String {
  case uses_in_stmts(scope, name) {
    True -> ""
    False -> pad <> "_ = " <> escape_ident(name) <> "\n"
  }
}

fn gen_if(
  env: Env,
  branches: List(ast.Branch),
  else_body: Option(List(ast.Stmt)),
  indent: Int,
) -> String {
  let pad = tabs(indent)
  let branch_code =
    branches
    |> list.index_map(fn(b, i) {
      let opener = case i {
        0 -> pad <> "if "
        _ -> " else if "
      }
      let #(cond_str, binds) = gen_condition(env, b.cond)
      let benv = bind_locals(env, binds)
      opener
      <> cond_str
      <> " {\n"
      <> gen_bindings(binds, b.body, indent + 1)
      <> gen_stmts(benv, b.body, indent + 1)
      <> pad
      <> "}"
    })
    |> string.concat

  let else_code = case else_body {
    Some(body) -> " else {\n" <> gen_stmts(env, body, indent + 1) <> pad <> "}"
    None -> ""
  }

  branch_code <> else_code <> "\n"
}

fn gen_bindings(
  binds: List(Bind),
  body: List(ast.Stmt),
  indent: Int,
) -> String {
  let pad = tabs(indent)
  binds
  |> list.map(fn(b) {
    let #(name, rhs, _) = b
    pad <> escape_ident(name) <> " := " <> rhs <> "\n" <> guard(body, name, pad)
  })
  |> string.concat
}

/// Register bindings as scoped locals (used for branch bodies, where the
/// bindings are re-declared as real variables).
fn bind_locals(env: Env, binds: List(Bind)) -> Env {
  list.fold(binds, env, fn(env, b) {
    let #(name, _, ty) = b
    Env(..env, locals: dict.insert(env.locals, name, ty))
  })
}

/// Register bindings as substitutions (used inside a condition, where later
/// operands of `&&` may reference a binding before it exists as a variable).
fn bind_subst(env: Env, binds: List(Bind)) -> Env {
  list.fold(binds, env, fn(env, b) {
    let #(name, rhs, ty) = b
    Env(
      ..env,
      locals: dict.insert(env.locals, name, ty),
      subst: dict.insert(env.subst, name, rhs),
    )
  })
}

// ---------------------------------------------------------------------------
// Conditions and `is` patterns
// ---------------------------------------------------------------------------

// Returns the Go boolean condition plus any bindings (name, rhs, type) that
// must be introduced at the top of the branch body. In `a is T(x) && p(x)`
// the right operand is generated with `x` substituted by its accessor; Go's
// short-circuiting `&&` guarantees the accessor only runs after the type
// check passed.
fn gen_condition(env: Env, cond: ast.Expr) -> #(String, List(Bind)) {
  case cond {
    ast.EIs(subject, pattern) -> gen_is(env, subject, pattern)
    ast.EBinary(ast.OpAnd, l, r) -> {
      let #(lc, lb) = gen_condition(env, l)
      let #(rc, rb) = gen_condition(bind_subst(env, lb), r)
      #("(" <> lc <> ") && (" <> rc <> ")", list.append(lb, rb))
    }
    ast.EBinary(ast.OpOr, l, r) -> {
      // Bindings must not escape an `||`: either side may be the one that
      // failed to match.
      let #(lc, _) = gen_condition(env, l)
      let #(rc, _) = gen_condition(env, r)
      #("(" <> lc <> ") || (" <> rc <> ")", [])
    }
    _ -> {
      let code = gen_expr(env, cond)
      // A bare atom in boolean position is truthy unless it is #False.
      case infer(env, cond) {
        TyAtom -> #("hive.Bool(" <> code <> ")", [])
        _ -> #(code, [])
      }
    }
  }
}

fn gen_is(
  env: Env,
  subject: ast.Expr,
  pattern: ast.Pattern,
) -> #(String, List(Bind)) {
  let subj = gen_expr(env, subject)
  // Result payload types come from the subject's inferred TyResult (e.g.
  // `using` -> Result<Table, TableError>, `hive.http.request` ->
  // Result<HttpResponse, HttpError>).
  let #(ok_ty, err_ty) = case infer(env, subject) {
    TyResult(ok, err) -> #(ok, err)
    _ -> #(TyUnknown, TyUnknown)
  }
  case pattern {
    ast.PConstructor(["Result", "Ok"], bindings) -> #(
      subj <> ".IsOk()",
      single_binding(bindings, subj <> ".Ok()", ok_ty),
    )
    ast.PConstructor(["Result", "Error"], bindings) -> #(
      subj <> ".IsError()",
      single_binding(bindings, subj <> ".Err()", err_ty),
    )
    // User-defined tagged-union patterns via Go type assertions.
    ast.PConstructor([type_name, variant_name], bindings) ->
      gen_adt_is(env, subj, type_name, variant_name, bindings)
    ast.PConstructor(_, _) -> #(gen_expr(env, subject), [])
  }
}

fn single_binding(bindings: List(String), rhs: String, ty: Ty) -> List(Bind) {
  case bindings {
    // A `_` placeholder binds nothing.
    ["_"] -> []
    [name] -> [#(name, rhs, ty)]
    _ -> []
  }
}

fn gen_adt_is(
  env: Env,
  subj: String,
  type_name: String,
  variant_name: String,
  bindings: List(String),
) -> #(String, List(Bind)) {
  let struct_name = type_name <> variant_name
  let cond =
    "func() bool { _, _ok := "
    <> subj
    <> ".("
    <> struct_name
    <> "); return _ok }()"
  let fields = variant_fields(env, type_name, variant_name)
  // Map each binding positionally onto the variant's fields, dropping `_`
  // placeholders (which bind nothing).
  let binds =
    bindings
    |> list.index_map(fn(name, i) { #(name, i) })
    |> list.filter(fn(pair) { pair.0 != "_" })
    |> list.map(fn(pair) {
      let #(name, i) = pair
      let #(field, ty) = case list_at(fields, i) {
        Some(f) -> #(exported(f.name), ty_of_type_expr(env.types, f.typ))
        None -> #("Field" <> int.to_string(i), TyUnknown)
      }
      #(name, subj <> ".(" <> struct_name <> ")." <> field, ty)
    })
  #(cond, binds)
}

// ---------------------------------------------------------------------------
// Type inference
// ---------------------------------------------------------------------------

fn infer(env: Env, e: ast.Expr) -> Ty {
  case e {
    ast.EInt(_) -> TyInt
    ast.EFloat(_) -> TyFloat
    ast.EString(_) -> TyStr
    ast.EInterp(_) -> TyStr
    // `true`/`false` are Bool literals (Go booleans), distinct from the
    // `#True`/`#False` atoms.
    ast.EBool(_) -> TyBool
    ast.EAtom(_) -> TyAtom
    ast.EIdent(name) ->
      case dict.get(env.locals, name) {
        Ok(ty) -> ty
        Error(_) -> TyUnknown
      }
    ast.EVector(items) ->
      case items {
        [first, ..] -> TyVec(infer(env, first))
        [] -> TyVec(TyUnknown)
      }
    ast.EMember(target, field) ->
      case infer(env, target) {
        TyCustom(type_name) -> field_ty(env, type_name, field)
        TyBuiltin(name) ->
          case builtin_fields(name) {
            Some(fields) ->
              case list.find(fields, fn(f) { f.0 == field }) {
                Ok(#(_, ty)) -> ty
                Error(_) -> TyUnknown
              }
            None -> TyUnknown
          }
        _ -> TyUnknown
      }
    ast.ECall(callee, args) ->
      case callee {
        ast.EIdent("len") -> TyInt
        ast.EIdent("bytes") -> TyInt
        ast.EIdent("now") -> TyInt
        ast.EIdent("join") -> TyStr
        ast.EIdent("split") -> TyVec(TyStr)
        ast.EIdent("row") -> TyVec(TyStr)
        ast.EIdent("column") -> TyVec(TyStr)
        // `append` yields a vector of the same type as its first argument.
        ast.EIdent("append") ->
          case args {
            [ast.Arg(_, first), ..] -> infer(env, first)
            [] -> TyUnknown
          }
        ast.EIdent(name) ->
          case dict.has_key(env.types, name) {
            True -> TyCustom(name)
            False ->
              case dict.get(env.sigs, name) {
                Ok(#(_, ret)) -> ret
                Error(_) -> TyUnknown
              }
          }
        // `hive.sql.DatabaseDriver.SQLite()` and friends build a driver value.
        ast.EMember(
          ast.EMember(
            ast.EMember(ast.EIdent("hive"), "sql"),
            "DatabaseDriver",
          ),
          _,
        ) -> TyBuiltin("DatabaseDriver")
        // A `hive.<ns>.<member>` call: a builtin type constructor if the
        // member names a builtin type, else a stdlib function's result type.
        ast.EMember(ast.EMember(ast.EIdent("hive"), ns), fname) ->
          case builtin_fields(fname) {
            Some(_) -> TyBuiltin(fname)
            None ->
              case ns {
                "http" ->
                  case fname {
                    "request" ->
                      TyResult(TyBuiltin("HttpResponse"), TyBuiltin("HttpError"))
                    _ -> TyUnknown
                  }
                "json" ->
                  case fname {
                    "table" -> TyResult(TyTable, TyBuiltin("JsonError"))
                    "get" -> TyResult(TyStr, TyBuiltin("JsonError"))
                    "encode" -> TyStr
                    _ -> TyUnknown
                  }
                "crypto" ->
                  case fname {
                    "sha256"
                    | "sha512"
                    | "hmacSha256"
                    | "base64Encode"
                    | "randomHex" -> TyStr
                    "base64Decode" -> TyResult(TyStr, TyBuiltin("CryptoError"))
                    "jwtSign" -> TyStr
                    "jwtHeader" ->
                      TyResult(TyBuiltin("JwtHeader"), TyBuiltin("CryptoError"))
                    _ -> TyResult(TyUnknown, TyBuiltin("CryptoError"))
                  }
                "sql" ->
                  case fname {
                    "connect" | "pool" ->
                      TyResult(TyBuiltin("SqlConnection"), TyBuiltin("SqlError"))
                    _ -> TyUnknown
                  }
                "conv" ->
                  case fname {
                    "ceil" | "floor" | "round" -> TyInt
                    "itf" -> TyFloat
                    "its" | "fts" -> TyStr
                    "sti" -> TyResult(TyInt, TyBuiltin("ConversionError"))
                    "stf" -> TyResult(TyFloat, TyBuiltin("ConversionError"))
                    _ -> TyUnknown
                  }
                "env" ->
                  case fname {
                    "get" -> TyResult(TyStr, TyBuiltin("EnvironmentError"))
                    _ -> TyUnknown
                  }
                _ -> TyUnknown
              }
          }
        ast.EMember(ast.EIdent(type_name), _) ->
          case dict.has_key(env.types, type_name) {
            True -> TyCustom(type_name)
            False -> TyUnknown
          }
        _ -> TyUnknown
      }
    ast.EIndex(target, _) ->
      case infer(env, target) {
        TyVec(t) -> t
        TyTable -> TyVec(TyStr)
        _ -> TyUnknown
      }
    ast.ESlice(target, _, _) -> infer(env, target)
    ast.EBinary(op, l, r) ->
      case op {
        ast.OpGt
        | ast.OpLt
        | ast.OpGe
        | ast.OpLe
        | ast.OpEq
        | ast.OpNeq
        | ast.OpAnd
        | ast.OpOr -> TyBool
        ast.OpAdd | ast.OpSub | ast.OpMul | ast.OpDiv | ast.OpMod | ast.OpPow ->
          infer_arith(env, l, r)
      }
    ast.EIs(_, _) -> TyBool
    // `using` is overloaded: a Str path reads a CSV; a SQL connection runs a
    // query. The error type follows the source.
    ast.EUsing(path, _) ->
      case infer(env, path) {
        TyBuiltin("SqlConnection") -> TyResult(TyTable, TyBuiltin("SqlError"))
        _ -> TyResult(TyTable, TyBuiltin("TableError"))
      }
    ast.EWith(value, typ) ->
      case value {
        ast.ECall(
          ast.EMember(ast.EMember(ast.EIdent("hive"), "json"), "parse"),
          _,
        ) ->
          TyResult(ty_of_type_expr(env.types, typ), TyBuiltin("JsonError"))
        ast.ECall(
            ast.EMember(ast.EMember(ast.EIdent("hive"), "crypto"), "jwtVerify"),
            _,
          )
        | ast.ECall(
            ast.EMember(ast.EMember(ast.EIdent("hive"), "crypto"), "jwtDecode"),
            _,
          ) ->
          TyResult(ty_of_type_expr(env.types, typ), TyBuiltin("CryptoError"))
        _ -> infer(env, value)
      }
    // `await e` produces the value the awaited async function returns.
    ast.EAwait(value) -> infer(env, value)
  }
}

fn infer_arith(env: Env, l: ast.Expr, r: ast.Expr) -> Ty {
  let lt = infer(env, l)
  let rt = infer(env, r)
  case lt, rt {
    TyVec(_), _ -> lt
    _, TyVec(_) -> rt
    TyStr, _ | _, TyStr -> TyStr
    TyAtom, _ | _, TyAtom -> TyStr
    TyFloat, _ | _, TyFloat -> TyFloat
    TyInt, _ | _, TyInt -> TyInt
    _, _ -> TyUnknown
  }
}

fn field_ty(env: Env, type_name: String, field: String) -> Ty {
  case dict.get(env.types, type_name) {
    Ok(ast.TypeDecl(_, variants, commons)) -> {
      let all =
        variants
        |> list.flat_map(fn(v) { v.fields })
        |> list.append(commons)
      case list.find(all, fn(f) { f.name == field }) {
        Ok(f) -> ty_of_type_expr(env.types, f.typ)
        Error(_) -> TyUnknown
      }
    }
    _ -> TyUnknown
  }
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

fn gen_expr(env: Env, e: ast.Expr) -> String {
  case e {
    ast.EInt(v) -> int.to_string(v)
    ast.EFloat(v) -> float.to_string(v)
    ast.EString(s) -> gen_string_lit(s)
    ast.EInterp(parts) -> gen_interp(env, parts)
    ast.EBool(b) ->
      case b {
        True -> "true"
        False -> "false"
      }
    ast.EAtom(name) -> gen_atom(name)
    ast.EIdent(name) ->
      // Inside a condition an `is`-binding reads through its accessor.
      case dict.get(env.subst, name) {
        Ok(rhs) -> rhs
        Error(_) -> escape_ident(name)
      }
    ast.EVector(items) -> gen_vector(env, items, TyUnknown)
    ast.EMember(target, field) -> {
      // Hive fields are lowercase but compile to exported Go fields, so
      // capitalize the access whenever the target is a known struct.
      let field = case infer(env, target) {
        TyBuiltin(_) -> exported(field)
        TyCustom(type_name) ->
          case dict.get(env.types, type_name) {
            Ok(ast.TypeDecl(_, [], _)) -> exported(field)
            _ -> field
          }
        _ -> field
      }
      gen_expr(env, target) <> "." <> field
    }
    ast.EIndex(target, idx) ->
      gen_expr(env, target) <> "[" <> gen_expr(env, idx) <> "]"
    ast.ESlice(target, low, high) -> gen_slice(env, target, low, high)
    ast.EBinary(op, l, r) -> gen_binary(env, op, l, r)
    ast.EUsing(path, delim) -> gen_using(env, path, delim)
    ast.EIs(subject, pattern) -> {
      let #(cond, _) = gen_is(env, subject, pattern)
      cond
    }
    ast.ECall(callee, args) -> gen_call(env, callee, args)
    ast.EWith(value, typ) -> gen_with(env, value, typ)
    // An async func lowers to an ordinary Go function, so `await`ing it (i.e.
    // blocking for its value) is just calling it synchronously.
    ast.EAwait(value) -> gen_expr(env, value)
  }
}

// `hive.json.parse(text) with T` — the decoder is derived from T at compile
// time (validation guarantees the value is a parse call).
fn gen_with(env: Env, value: ast.Expr, typ: ast.TypeExpr) -> String {
  case value {
    ast.ECall(
      ast.EMember(ast.EMember(ast.EIdent("hive"), "json"), "parse"),
      args,
    ) -> {
      let text = case assign_args(args, ["text"]) {
        #([#(_, t)], []) -> gen_expr(env, t)
        _ -> gen_args(env, args)
      }
      "hive.JsonParse(" <> text <> ", " <> json_decoder_ref(env, typ) <> ")"
    }
    // `hive.crypto.jwtVerify(token, secret) with T` verifies the token, then
    // decodes its payload with the derived decoder for T.
    ast.ECall(
      ast.EMember(ast.EMember(ast.EIdent("hive"), "crypto"), "jwtVerify"),
      args,
    ) -> {
      let call = case assign_args(args, ["token", "secret"]) {
        #([#(_, token), #(_, secret)], []) ->
          coerce(env, token, TyStr) <> ", " <> coerce(env, secret, TyStr)
        _ -> gen_args(env, args)
      }
      "hive.JwtVerify(" <> call <> ", " <> json_decoder_ref(env, typ) <> ")"
    }
    // `hive.crypto.jwtDecode(token) with T` decodes the payload WITHOUT
    // verifying it.
    ast.ECall(
      ast.EMember(ast.EMember(ast.EIdent("hive"), "crypto"), "jwtDecode"),
      args,
    ) -> {
      let token = case assign_args(args, ["token"]) {
        #([#(_, t)], []) -> coerce(env, t, TyStr)
        _ -> gen_args(env, args)
      }
      "hive.JwtDecode(" <> token <> ", " <> json_decoder_ref(env, typ) <> ")"
    }
    _ -> gen_expr(env, value)
  }
}

fn gen_atom(name: String) -> String {
  case name {
    "False" -> "hive.False"
    "True" -> "hive.True"
    _ -> "atom_" <> name
  }
}

/// Generate an expression that must produce the given type, inserting the
/// coercions the language defines (atoms read as their decimal Str form; a
/// vector literal adopts the expected element type).
fn coerce(env: Env, e: ast.Expr, expect: Ty) -> String {
  case expect, e {
    TyVec(elem), ast.EVector(items) -> gen_vector(env, items, elem)
    TyTable, ast.EVector(items) -> gen_vector(env, items, TyVec(TyStr))
    TyStr, _ ->
      case infer(env, e) {
        TyAtom -> "hive.AtomToStr(" <> gen_expr(env, e) <> ")"
        _ -> gen_expr(env, e)
      }
    _, _ -> gen_expr(env, e)
  }
}

fn gen_vector(env: Env, items: List(ast.Expr), expect_elem: Ty) -> String {
  let elem_ty = case expect_elem {
    TyUnknown ->
      case items {
        [first, ..] -> infer(env, first)
        [] -> TyUnknown
      }
    t -> t
  }
  let rendered =
    items
    |> list.map(fn(i) { coerce(env, i, elem_ty) })
    |> string.join(", ")
  "[]" <> ty_to_go(elem_ty) <> "{" <> rendered <> "}"
}

// An interpolated string becomes plain concatenation; non-Str pieces go
// through hive.ToStr.
fn gen_interp(env: Env, parts: List(ast.IPart)) -> String {
  let pieces =
    parts
    |> list.map(fn(p) {
      case p {
        ast.ILit(s) -> gen_string_lit(s)
        ast.IExpr(e) ->
          case infer(env, e) {
            TyStr -> gen_expr(env, e)
            _ -> "hive.ToStr(" <> gen_expr(env, e) <> ")"
          }
      }
    })
  case pieces {
    [] -> "\"\""
    _ -> "(" <> string.join(pieces, " + ") <> ")"
  }
}

fn gen_binary(env: Env, op: ast.BinOp, l: ast.Expr, r: ast.Expr) -> String {
  case op {
    ast.OpAnd | ast.OpOr -> {
      let #(cond, _) = gen_condition(env, ast.EBinary(op, l, r))
      cond
    }
    ast.OpAdd -> gen_add(env, l, r)
    ast.OpDiv -> gen_div(env, l, r)
    ast.OpMod -> gen_mod(env, l, r)
    ast.OpPow -> gen_pow(env, l, r)
    // `==` / `!=` on vectors: Go can't compare slices, so route to the runtime
    // structural-equality helper (same length, then element-wise).
    ast.OpEq -> gen_equality(env, l, r, True)
    ast.OpNeq -> gen_equality(env, l, r, False)
    _ ->
      "("
      <> gen_expr(env, l)
      <> " "
      <> gen_binop(op)
      <> " "
      <> gen_expr(env, r)
      <> ")"
  }
}

// `==` / `!=` lowers to `hive.VecEq` only when *both* operands are vectors
// (Go can't compare slices), so a vector compared against a scalar — or two
// vectors of different element types — falls through to Go's native `==`/`!=`
// and is rejected by the Go compiler rather than silently returning `false`.
// `positive` is True for `==`, False for `!=`.
fn gen_equality(env: Env, l: ast.Expr, r: ast.Expr, positive: Bool) -> String {
  let is_vec = fn(t) {
    case t {
      TyVec(_) | TyTable -> True
      _ -> False
    }
  }
  case is_vec(infer(env, l)) && is_vec(infer(env, r)) {
    True -> {
      let call =
        "hive.VecEq(" <> gen_expr(env, l) <> ", " <> gen_expr(env, r) <> ")"
      case positive {
        True -> call
        False -> "!" <> call
      }
    }
    False -> {
      let op = case positive {
        True -> " == "
        False -> " != "
      }
      "(" <> gen_expr(env, l) <> op <> gen_expr(env, r) <> ")"
    }
  }
}

// Wraps a rendered vector RHS in `hive.Clone(...)` when the binding must not
// share storage with its source. `target_mutable` is whether the binding being
// created is `mut`.
fn maybe_clone(
  env: Env,
  target_mutable: Bool,
  value: ast.Expr,
  rendered: String,
) -> String {
  case needs_copy(env, target_mutable, value) {
    True -> "hive.Clone(" <> rendered <> ")"
    False -> rendered
  }
}

// A vector binding needs a copy when its RHS refers to existing storage (an
// identifier/index/member/slice rather than a fresh literal or `+`/call result)
// and the two ends are not both mutable. Two mutable bindings are allowed to
// alias (shared mutable state); anything involving an immutable side is an
// independent value and must be copied.
fn needs_copy(env: Env, target_mutable: Bool, value: ast.Expr) -> Bool {
  case is_vec_ty(infer(env, value)) && aliases_storage(value) {
    False -> False
    // Alias source of vector type: copy unless both ends are mutable.
    True ->
      case target_mutable && source_mutable(env, value) {
        True -> False
        False -> True
      }
  }
}

fn is_vec_ty(ty: Ty) -> Bool {
  case ty {
    TyVec(_) | TyTable -> True
    _ -> False
  }
}

fn aliases_storage(e: ast.Expr) -> Bool {
  case e {
    ast.EIdent(_) | ast.EMember(_, _) | ast.EIndex(_, _) | ast.ESlice(_, _, _) ->
      True
    _ -> False
  }
}

fn source_mutable(env: Env, e: ast.Expr) -> Bool {
  case e {
    ast.EIdent(n) ->
      case dict.get(env.muts, n) {
        Ok(m) -> m
        Error(_) -> False
      }
    ast.EMember(t, _) | ast.EIndex(t, _) | ast.ESlice(t, _, _) ->
      source_mutable(env, t)
    _ -> False
  }
}

// `+` is overloaded: numbers add, strings concatenate (atoms coerce to their
// Str form next to a string), vectors concatenate via the runtime.
fn gen_add(env: Env, l: ast.Expr, r: ast.Expr) -> String {
  let lt = infer(env, l)
  let rt = infer(env, r)
  case lt, rt {
    TyVec(_), _ | _, TyVec(_) | TyTable, TyTable ->
      "hive.Concat(" <> gen_expr(env, l) <> ", " <> gen_expr(env, r) <> ")"
    TyStr, TyAtom | TyAtom, TyStr | TyAtom, TyAtom ->
      "(" <> coerce(env, l, TyStr) <> " + " <> coerce(env, r, TyStr) <> ")"
    _, _ -> "(" <> gen_expr(env, l) <> " + " <> gen_expr(env, r) <> ")"
  }
}

// Hive division returns 0 when the divisor is 0, so known numeric divisions
// go through the runtime helpers.
fn gen_div(env: Env, l: ast.Expr, r: ast.Expr) -> String {
  case infer(env, l), infer(env, r) {
    TyInt, TyInt ->
      "hive.DivInt(" <> gen_expr(env, l) <> ", " <> gen_expr(env, r) <> ")"
    TyFloat, TyFloat ->
      "hive.DivFloat(" <> gen_expr(env, l) <> ", " <> gen_expr(env, r) <> ")"
    _, _ -> "(" <> gen_expr(env, l) <> " / " <> gen_expr(env, r) <> ")"
  }
}

// Hive's `%` (remainder) mirrors division's zero-safety: a modulus of 0
// returns 0. Go's `%` is integer-only, so a float remainder goes through
// `math.Mod` in the runtime; unknown numeric types default to integer.
fn gen_mod(env: Env, l: ast.Expr, r: ast.Expr) -> String {
  case infer(env, l), infer(env, r) {
    TyFloat, _ | _, TyFloat ->
      "hive.ModFloat(" <> gen_expr(env, l) <> ", " <> gen_expr(env, r) <> ")"
    _, _ ->
      "hive.ModInt(" <> gen_expr(env, l) <> ", " <> gen_expr(env, r) <> ")"
  }
}

fn gen_pow(env: Env, l: ast.Expr, r: ast.Expr) -> String {
  case infer(env, l), infer(env, r) {
    TyInt, TyInt ->
      "hive.PowInt(" <> gen_expr(env, l) <> ", " <> gen_expr(env, r) <> ")"
    _, _ ->
      "hive.PowFloat(" <> gen_expr(env, l) <> ", " <> gen_expr(env, r) <> ")"
  }
}

fn gen_slice(
  env: Env,
  target: ast.Expr,
  low: Option(ast.Expr),
  high: Option(ast.Expr),
) -> String {
  let low_str = case low {
    Some(e) -> gen_expr(env, e)
    None -> ""
  }
  // Hive slices are inclusive of the high bound; Go's are exclusive, so add 1.
  let high_str = case high {
    Some(e) -> "(" <> gen_expr(env, e) <> ")+1"
    None -> ""
  }
  gen_expr(env, target) <> "[" <> low_str <> ":" <> high_str <> "]"
}

fn gen_using(env: Env, path: ast.Expr, delim: Option(ast.Expr)) -> String {
  case infer(env, path) {
    // `using <connection> with <query>` runs SQL and returns a Table.
    TyBuiltin("SqlConnection") -> {
      let query = case delim {
        Some(q) -> coerce(env, q, TyStr)
        None -> "\"\""
      }
      "hive.SqlQuery(" <> gen_expr(env, path) <> ", " <> query <> ")"
    }
    // `using <path> [with <delimiter>]` reads a CSV.
    _ -> {
      let delim_str = case delim {
        Some(d) -> gen_expr(env, d)
        None -> "\",\""
      }
      "hive.ReadCSV(" <> gen_expr(env, path) <> ", " <> delim_str <> ")"
    }
  }
}

fn gen_call(env: Env, callee: ast.Expr, args: List(ast.Arg)) -> String {
  case callee {
    ast.EIdent(name) -> gen_ident_call(env, name, args)
    // `hive.sql.DatabaseDriver.SQLite()` etc. — driver constructors.
    ast.EMember(
      ast.EMember(ast.EMember(ast.EIdent("hive"), "sql"), "DatabaseDriver"),
      variant,
    ) -> gen_sql_driver(env, variant, args)
    // A `hive.<ns>.<member>` call: a builtin type constructor
    // (`hive.http.HttpRequest(...)`) if the member names a builtin type,
    // otherwise a stdlib function in that namespace.
    ast.EMember(ast.EMember(ast.EIdent("hive"), ns), fname) ->
      case builtin_fields(fname) {
        Some(fields) -> gen_builtin_construct(env, fname, fields, args)
        None ->
          case ns {
            "http" -> gen_http_call(env, fname, args)
            "json" -> gen_json_call(env, fname, args)
            "crypto" -> gen_crypto_call(env, fname, args)
            "sql" -> gen_sql_call(env, fname, args)
            "conv" -> gen_conv_call(env, fname, args)
            "env" -> gen_env_call(env, fname, args)
            _ -> gen_plain_call(env, callee, args)
          }
      }
    ast.EMember(ast.EIdent(type_name), variant_name) ->
      case dict.get(env.types, type_name) {
        Ok(_) -> gen_constructor(env, type_name, variant_name, args)
        // Builtin constructors are namespaced (`hive.http.HttpRequest(...)`),
        // handled above; a bare `hive.X(...)` is rejected by validation.
        Error(_) -> gen_plain_call(env, callee, args)
      }
    _ -> gen_plain_call(env, callee, args)
  }
}

// The validation pass (compiler.check) has already rejected unknown members,
// bad arities and unknown named arguments, so lowering can be
// straightforward here.
fn gen_http_call(env: Env, fname: String, args: List(ast.Arg)) -> String {
  case fname {
    "request" ->
      case assign_args(args, ["request"]) {
        #([#(_, req)], []) ->
          "hive.HttpSend(" <> coerce(env, req, TyBuiltin("HttpRequest")) <> ")"
        _ -> "hive.HttpSend(" <> gen_args(env, args) <> ")"
      }
    "serve" ->
      case assign_args(args, ["port", "handler"]) {
        #([#(_, port), #(_, handler)], []) ->
          "hive.HttpServe("
          <> coerce(env, port, TyInt)
          <> ", "
          <> gen_expr(env, handler)
          <> ")"
        _ -> "hive.HttpServe(" <> gen_args(env, args) <> ")"
      }
    _ -> "hive.Http" <> exported(fname) <> "(" <> gen_args(env, args) <> ")"
  }
}

fn gen_json_call(env: Env, fname: String, args: List(ast.Arg)) -> String {
  case fname {
    "encode" ->
      case assign_args(args, ["value"]) {
        #([#(_, value)], []) ->
          gen_json_encode(infer(env, value), gen_expr(env, value), 0)
        _ -> "hive.JsonEncodeDynamic(" <> gen_args(env, args) <> ")"
      }
    "table" ->
      case assign_args(args, ["text"]) {
        #([#(_, text)], []) -> "hive.JsonTable(" <> gen_expr(env, text) <> ")"
        _ -> "hive.JsonTable(" <> gen_args(env, args) <> ")"
      }
    "get" ->
      case assign_args(args, ["table", "path"]) {
        #([#(_, table), #(_, path)], []) ->
          "hive.JsonGet("
          <> gen_expr(env, table)
          <> ", "
          <> coerce(env, path, TyStr)
          <> ")"
        _ -> "hive.JsonGet(" <> gen_args(env, args) <> ")"
      }
    // `parse` only occurs under `with` (validation enforces it); anything
    // else was rejected by the validation pass.
    _ -> "hive.JsonEncodeDynamic(" <> gen_args(env, args) <> ")"
  }
}

// The `hive.crypto` namespace: hashes, HMAC, base64, random and JWTs.
// jwtVerify/jwtDecode never reach here — they are handled under `with`.
fn gen_crypto_call(env: Env, fname: String, args: List(ast.Arg)) -> String {
  case fname {
    "sha256" -> "hive.Sha256(" <> gen_one(env, args, "input") <> ")"
    "sha512" -> "hive.Sha512(" <> gen_one(env, args, "input") <> ")"
    "base64Encode" ->
      "hive.Base64Encode(" <> gen_one(env, args, "input") <> ")"
    "base64Decode" ->
      "hive.Base64Decode(" <> gen_one(env, args, "input") <> ")"
    "hmacSha256" ->
      case assign_args(args, ["input", "key"]) {
        #([#(_, input), #(_, key)], []) ->
          "hive.HmacSha256("
          <> coerce(env, input, TyStr)
          <> ", "
          <> coerce(env, key, TyStr)
          <> ")"
        _ -> "hive.HmacSha256(" <> gen_args(env, args) <> ")"
      }
    "randomHex" ->
      case assign_args(args, ["bytes"]) {
        #([#(_, n)], []) -> "hive.RandomHex(" <> coerce(env, n, TyInt) <> ")"
        _ -> "hive.RandomHex(" <> gen_args(env, args) <> ")"
      }
    // The claims are JSON-encoded by the derived encoder, then signed.
    "jwtSign" ->
      case assign_args(args, ["claims", "secret"]) {
        #([#(_, claims), #(_, secret)], []) ->
          "hive.JwtSign("
          <> gen_json_encode(infer(env, claims), gen_expr(env, claims), 0)
          <> ", "
          <> coerce(env, secret, TyStr)
          <> ")"
        _ -> "hive.JwtSign(" <> gen_args(env, args) <> ")"
      }
    "jwtHeader" -> "hive.JwtReadHeader(" <> gen_one(env, args, "token") <> ")"
    _ -> "hive." <> exported(fname) <> "(" <> gen_args(env, args) <> ")"
  }
}

// A single `Str` argument, honouring the named-argument form.
fn gen_one(env: Env, args: List(ast.Arg), name: String) -> String {
  case assign_args(args, [name]) {
    #([#(_, arg)], []) -> coerce(env, arg, TyStr)
    _ -> gen_args(env, args)
  }
}

// The `hive.sql` namespace: opening, pooling and closing connections. Queries
// go through `using <conn> with <query>` (see gen_using).
fn gen_sql_call(env: Env, fname: String, args: List(ast.Arg)) -> String {
  case fname {
    "connect" ->
      case assign_args(args, ["driver", "connString"]) {
        #([#(_, driver), #(_, conn)], []) ->
          "hive.SqlConnect("
          <> gen_expr(env, driver)
          <> ", "
          <> coerce(env, conn, TyStr)
          <> ")"
        _ -> "hive.SqlConnect(" <> gen_args(env, args) <> ")"
      }
    "pool" ->
      case assign_args(args, ["driver", "connString", "maxOpen", "maxIdle"]) {
        #([#(_, driver), #(_, conn), #(_, max_open), #(_, max_idle)], []) ->
          "hive.SqlPool("
          <> gen_expr(env, driver)
          <> ", "
          <> coerce(env, conn, TyStr)
          <> ", "
          <> coerce(env, max_open, TyInt)
          <> ", "
          <> coerce(env, max_idle, TyInt)
          <> ")"
        _ -> "hive.SqlPool(" <> gen_args(env, args) <> ")"
      }
    "close" -> "hive.SqlClose(" <> gen_one_raw(env, args, "connection") <> ")"
    _ -> "hive.Sql" <> exported(fname) <> "(" <> gen_args(env, args) <> ")"
  }
}

// A single argument passed through as-is (no Str coercion — used for opaque
// values like a connection handle).
fn gen_one_raw(env: Env, args: List(ast.Arg), name: String) -> String {
  case assign_args(args, [name]) {
    #([#(_, arg)], []) -> gen_expr(env, arg)
    _ -> gen_args(env, args)
  }
}

// The `hive.sql.DatabaseDriver` variant constructors. Each yields a
// `hive.DatabaseDriver` carrying the registered database/sql driver name.
fn gen_sql_driver(env: Env, variant: String, args: List(ast.Arg)) -> String {
  case variant {
    "SQLite" -> "hive.DatabaseDriver{Name: \"sqlite\"}"
    "PostgreSQL" -> "hive.DatabaseDriver{Name: \"postgres\"}"
    "Other" ->
      "hive.DatabaseDriver{Name: " <> gen_one(env, args, "name") <> "}"
    _ -> "hive.DatabaseDriver{Name: \"\"}"
  }
}

// The `hive.conv` namespace: numeric rounding (ceil/floor/round), widening
// (itf), rendering (its/fts) and fallible parsing (sti/stf). Each takes a
// single argument, coerced to the type its Go helper expects.
fn gen_conv_call(env: Env, fname: String, args: List(ast.Arg)) -> String {
  case fname {
    "ceil" -> "hive.Ceil(" <> gen_one_coerced(env, args, "value", TyFloat) <> ")"
    "floor" ->
      "hive.Floor(" <> gen_one_coerced(env, args, "value", TyFloat) <> ")"
    "round" ->
      "hive.Round(" <> gen_one_coerced(env, args, "value", TyFloat) <> ")"
    "itf" ->
      "hive.IntToFloat(" <> gen_one_coerced(env, args, "value", TyInt) <> ")"
    "its" ->
      "hive.IntToStr(" <> gen_one_coerced(env, args, "value", TyInt) <> ")"
    "fts" ->
      "hive.FloatToStr(" <> gen_one_coerced(env, args, "value", TyFloat) <> ")"
    "sti" ->
      "hive.StrToInt(" <> gen_one_coerced(env, args, "value", TyStr) <> ")"
    "stf" ->
      "hive.StrToFloat(" <> gen_one_coerced(env, args, "value", TyStr) <> ")"
    _ -> "hive." <> exported(fname) <> "(" <> gen_args(env, args) <> ")"
  }
}

fn gen_env_call(env: Env, fname: String, args: List(ast.Arg)) -> String {
  case fname {
    "get" -> "hive.EnvGet(" <> gen_one_coerced(env, args, "key", TyStr) <> ")"
    _ -> "hive." <> exported(fname) <> "(" <> gen_args(env, args) <> ")"
  }
}

// A single argument coerced to the given type, honouring the named-argument
// form.
fn gen_one_coerced(
  env: Env,
  args: List(ast.Arg),
  name: String,
  ty: Ty,
) -> String {
  case assign_args(args, [name]) {
    #([#(_, arg)], []) -> coerce(env, arg, ty)
    _ -> gen_args(env, args)
  }
}

// Picks the encoder for a value from its inferred type. Unknown types fall
// back to the runtime's dynamic encoder.
fn gen_json_encode(ty: Ty, value: String, depth: Int) -> String {
  case ty {
    TyStr -> "hive.JsonEncodeStr(" <> value <> ")"
    TyInt -> "hive.JsonEncodeInt(" <> value <> ")"
    TyFloat -> "hive.JsonEncodeFloat(" <> value <> ")"
    TyBool -> "hive.JsonEncodeBool(" <> value <> ")"
    TyAtom -> "hive.JsonEncodeAtom(" <> value <> ")"
    TyTable -> "hive.JsonEncodeTable(" <> value <> ")"
    TyCustom(name) -> "jsonEncode_" <> name <> "(" <> value <> ")"
    TyVec(elem) -> {
      let e = "e" <> int.to_string(depth)
      "hive.JsonEncodeVec("
      <> value
      <> ", func("
      <> e
      <> " "
      <> ty_to_go(elem)
      <> ") string { return "
      <> gen_json_encode(elem, e, depth + 1)
      <> " })"
    }
    _ -> "hive.JsonEncodeDynamic(" <> value <> ")"
  }
}

fn gen_builtin_construct(
  env: Env,
  name: String,
  fields: List(#(String, Ty)),
  args: List(ast.Arg),
) -> String {
  "hive."
  <> name
  <> "{"
  <> gen_field_args(env, args, fields)
  <> "}"
}

// Renders the provided arguments as a Go struct literal body, honouring
// named arguments.
fn gen_field_args(
  env: Env,
  args: List(ast.Arg),
  fields: List(#(String, Ty)),
) -> String {
  let #(assigned, extra) = assign_args(args, list.map(fields, fn(f) { f.0 }))
  let assigned_strs =
    assigned
    |> list.map(fn(pair) {
      let #(fname, value) = pair
      let ty = case list.find(fields, fn(f) { f.0 == fname }) {
        Ok(#(_, t)) -> t
        Error(_) -> TyUnknown
      }
      exported(fname) <> ": " <> coerce(env, value, ty)
    })
  let extra_strs =
    extra
    |> list.index_map(fn(e, i) {
      "Field" <> int.to_string(i) <> ": " <> gen_expr(env, e)
    })
  string.join(list.append(assigned_strs, extra_strs), ", ")
}

fn gen_ident_call(env: Env, name: String, args: List(ast.Arg)) -> String {
  case name {
    // `len` counts elements of a vector but characters (runes) of a Str.
    "len" ->
      case args {
        [ast.Arg(_, arg)] ->
          case infer(env, arg) {
            TyStr -> "hive.StrLen(" <> gen_expr(env, arg) <> ")"
            _ -> "len(" <> gen_expr(env, arg) <> ")"
          }
        _ -> "len(" <> gen_args(env, args) <> ")"
      }
    // `bytes` reports the UTF-8 byte length of a Str, or the byte footprint
    // (element count times element size) of a vector's contiguous storage.
    "bytes" ->
      case args {
        [ast.Arg(_, arg)] ->
          case infer(env, arg) {
            TyStr -> "len(" <> gen_expr(env, arg) <> ")"
            _ -> "hive.Bytes(" <> gen_expr(env, arg) <> ")"
          }
        _ -> "hive.Bytes(" <> gen_args(env, args) <> ")"
      }
    "now" -> "hive.Now()"
    "print" -> "fmt.Print(" <> gen_args(env, args) <> ")"
    "println" -> "fmt.Println(" <> gen_args(env, args) <> ")"
    // `join(vector, sep)` concatenates a Str vector into one Str.
    "join" -> "hive.Join(" <> gen_args(env, args) <> ")"
    // `split(str, sep)` divides a Str into a Str vector.
    "split" -> "hive.Split(" <> gen_args(env, args) <> ")"
    // `row(table, key)` / `column(table, key)` look a row/column up by its
    // first cell.
    "row" -> "hive.Row(" <> gen_args(env, args) <> ")"
    "column" -> "hive.Column(" <> gen_args(env, args) <> ")"
    // `append(v, x...)` grows a vector (see gen_append); as a statement the
    // caller reassigns the result back to `v`.
    "append" -> gen_append(env, args)
    _ ->
      case dict.get(env.types, name) {
        // Bare `Type(...)` constructs the first variant (or the struct itself
        // for a variant-less type).
        Ok(ast.TypeDecl(_, [first, ..], _)) ->
          gen_constructor(env, name, first.name, args)
        Ok(ast.TypeDecl(_, [], _)) -> gen_struct_construct(env, name, args)
        _ ->
          case dict.get(env.sigs, name) {
            Ok(#(params, _)) ->
              escape_ident(name) <> "(" <> gen_sig_args(env, args, params) <> ")"
            Error(_) -> escape_ident(name) <> "(" <> gen_args(env, args) <> ")"
          }
      }
  }
}

// Renders call arguments in the callee's declared parameter order, honouring
// named arguments and coercing each value to its parameter type.
fn gen_sig_args(
  env: Env,
  args: List(ast.Arg),
  params: List(#(String, Ty)),
) -> String {
  let #(assigned, extra) = assign_args(args, list.map(params, fn(p) { p.0 }))
  let assigned_strs =
    assigned
    |> list.map(fn(pair) {
      let #(pname, value) = pair
      let ty = case list.find(params, fn(p) { p.0 == pname }) {
        Ok(#(_, t)) -> t
        Error(_) -> TyUnknown
      }
      coerce(env, value, ty)
    })
  let extra_strs = list.map(extra, fn(e) { gen_expr(env, e) })
  string.join(list.append(assigned_strs, extra_strs), ", ")
}

// Variant constructors produce the union's interface type so the value can be
// type-asserted later regardless of how it was declared.
fn gen_constructor(
  env: Env,
  type_name: String,
  variant_name: String,
  args: List(ast.Arg),
) -> String {
  let struct_name = type_name <> variant_name
  let fields =
    variant_fields(env, type_name, variant_name)
    |> list.map(fn(f) { #(f.name, ty_of_type_expr(env.types, f.typ)) })
  type_name
  <> "("
  <> struct_name
  <> "{"
  <> gen_field_args(env, args, fields)
  <> "})"
}

fn gen_struct_construct(
  env: Env,
  type_name: String,
  args: List(ast.Arg),
) -> String {
  let fields = case dict.get(env.types, type_name) {
    Ok(ast.TypeDecl(_, _, commons)) ->
      list.map(commons, fn(f) { #(f.name, ty_of_type_expr(env.types, f.typ)) })
    _ -> []
  }
  type_name <> "{" <> gen_field_args(env, args, fields) <> "}"
}

fn gen_plain_call(env: Env, callee: ast.Expr, args: List(ast.Arg)) -> String {
  gen_expr(env, callee) <> "(" <> gen_args(env, args) <> ")"
}

// `append(v, a, b, ...)` -> Go's builtin `append`, coercing every appended
// value to the vector's element type.
fn gen_append(env: Env, args: List(ast.Arg)) -> String {
  case args {
    [ast.Arg(_, target), ..rest] -> {
      let elem = case infer(env, target) {
        TyVec(t) -> t
        _ -> TyUnknown
      }
      let items = list.map(rest, fn(a) { coerce(env, a.value, elem) })
      "append("
      <> string.join([gen_expr(env, target), ..items], ", ")
      <> ")"
    }
    [] -> "append()"
  }
}

fn gen_args(env: Env, args: List(ast.Arg)) -> String {
  args
  |> list.map(fn(a) { gen_expr(env, a.value) })
  |> string.join(", ")
}

fn gen_binop(op: ast.BinOp) -> String {
  case op {
    ast.OpGt -> ">"
    ast.OpLt -> "<"
    ast.OpGe -> ">="
    ast.OpLe -> "<="
    ast.OpEq -> "=="
    ast.OpNeq -> "!="
    ast.OpAdd -> "+"
    ast.OpSub -> "-"
    ast.OpMul -> "*"
    ast.OpDiv -> "/"
    ast.OpMod -> "%"
    ast.OpPow -> "**"
    ast.OpAnd -> "&&"
    ast.OpOr -> "||"
  }
}

fn gen_string_lit(s: String) -> String {
  let escaped =
    s
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
    |> string.replace("\n", "\\n")
    |> string.replace("\t", "\\t")
    |> string.replace("\r", "\\r")
  "\"" <> escaped <> "\""
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn variant_fields(
  env: Env,
  type_name: String,
  variant_name: String,
) -> List(ast.Field) {
  case dict.get(env.types, type_name) {
    Ok(ast.TypeDecl(_, variants, commons)) ->
      case list.find(variants, fn(v) { v.name == variant_name }) {
        Ok(v) -> list.append(v.fields, commons)
        Error(_) -> commons
      }
    _ -> []
  }
}

fn exported(name: String) -> String {
  case string.pop_grapheme(name) {
    Ok(#(first, rest)) -> string.uppercase(first) <> rest
    Error(_) -> name
  }
}

// A Hive identifier that happens to be a Go keyword would make the generated
// Go fail to compile, so suffix it with `_`. Go keywords are all lowercase and
// Hive identifiers keep their spelling, so only an exact lowercase match is
// rewritten; the handful that are also Hive keywords (`func`, `for`, ...) can
// never reach here as identifiers anyway. Struct fields and exported names are
// capitalized elsewhere, so they can never collide.
fn escape_ident(name: String) -> String {
  case is_go_keyword(name) {
    True -> name <> "_"
    False -> name
  }
}

fn is_go_keyword(name: String) -> Bool {
  list.contains(
    [
      "break", "case", "chan", "const", "continue", "default", "defer", "else",
      "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
      "map", "package", "range", "return", "select", "struct", "switch", "type",
      "var",
    ],
    name,
  )
}

fn tabs(n: Int) -> String {
  string.repeat("\t", n)
}

fn list_at(items: List(a), i: Int) -> Option(a) {
  case list.drop(items, i) {
    [x, ..] -> Some(x)
    [] -> None
  }
}

// ---------------------------------------------------------------------------
// Use analysis (to satisfy Go's "declared and not used" rule)
// ---------------------------------------------------------------------------

fn uses_in_stmts(stmts: List(ast.Stmt), name: String) -> Bool {
  list.any(stmts, fn(s) { uses_in_stmt(s, name) })
}

fn uses_in_stmt(s: ast.Stmt, name: String) -> Bool {
  case s {
    ast.SVarDecl(_, value, _) -> uses_in_expr(value, name)
    ast.STypedDecl(_, _, value, _) -> uses_in_expr(value, name)
    // Only the assigned value counts as a use: a bare `name = ...` writes to
    // `name` without reading it, and Go's "declared and not used" rule needs a
    // read. Under-counting is safe (it only adds a harmless `_ = name`).
    ast.SAssign(_, value) -> uses_in_expr(value, name)
    ast.SReturn(None) -> False
    ast.SReturn(Some(e)) -> uses_in_expr(e, name)
    ast.SEcho(e) -> uses_in_expr(e, name)
    ast.SAssert(e) -> uses_in_expr(e, name)
    ast.SBreak | ast.SContinue -> False
    ast.SExpr(e) -> uses_in_expr(e, name)
    ast.SIf(branches, else_body) -> {
      let in_branches =
        list.any(branches, fn(b) {
          uses_in_expr(b.cond, name) || uses_in_stmts(b.body, name)
        })
      let in_else = case else_body {
        Some(body) -> uses_in_stmts(body, name)
        None -> False
      }
      in_branches || in_else
    }
    ast.SFor(init, cond, post, body) ->
      uses_in_opt_stmt(init, name)
      || uses_in_opt(cond, name)
      || uses_in_opt_stmt(post, name)
      || uses_in_stmts(body, name)
    ast.SForEach(_, _, iterable, body) ->
      uses_in_expr(iterable, name) || uses_in_stmts(body, name)
  }
}

fn uses_in_expr(e: ast.Expr, name: String) -> Bool {
  case e {
    ast.EInt(_) -> False
    ast.EFloat(_) -> False
    ast.EString(_) -> False
    ast.EBool(_) -> False
    ast.EAtom(_) -> False
    ast.EInterp(parts) ->
      list.any(parts, fn(p) {
        case p {
          ast.ILit(_) -> False
          ast.IExpr(e) -> uses_in_expr(e, name)
        }
      })
    ast.EIdent(n) -> n == name
    ast.EVector(items) -> list.any(items, fn(i) { uses_in_expr(i, name) })
    ast.EMember(t, _) -> uses_in_expr(t, name)
    ast.ECall(callee, args) ->
      uses_in_expr(callee, name)
      || list.any(args, fn(a) { uses_in_expr(a.value, name) })
    ast.EIndex(t, idx) -> uses_in_expr(t, name) || uses_in_expr(idx, name)
    ast.ESlice(t, lo, hi) ->
      uses_in_expr(t, name) || uses_in_opt(lo, name) || uses_in_opt(hi, name)
    ast.EBinary(_, l, r) -> uses_in_expr(l, name) || uses_in_expr(r, name)
    ast.EIs(subject, _) -> uses_in_expr(subject, name)
    ast.EUsing(path, delim) ->
      uses_in_expr(path, name) || uses_in_opt(delim, name)
    ast.EWith(value, _) -> uses_in_expr(value, name)
    ast.EAwait(value) -> uses_in_expr(value, name)
  }
}

fn uses_in_opt(o: Option(ast.Expr), name: String) -> Bool {
  case o {
    Some(e) -> uses_in_expr(e, name)
    None -> False
  }
}
