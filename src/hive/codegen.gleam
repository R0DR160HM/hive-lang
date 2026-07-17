//// Generates Go source (the `main` package) from an Hive `ast.Module`.
////
//// Hive types map onto Go as follows:
////   * A type with no variants becomes a plain `struct`.
////   * A type with variants becomes an `interface` plus one `struct` per
////     variant (a tagged union). Common fields are appended to every variant,
////     which is also the positional order used by constructors.
////   * `Result` and `Table`/`TableError` are provided by the generated `hive`
////     runtime package.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import hive/ast
import hive/runtime

type Env {
  Env(types: Dict(String, ast.Decl))
}

pub fn generate(module: ast.Module) -> String {
  let env = Env(collect_types(module.decls))

  let type_code =
    module.decls
    |> list.filter_map(fn(d) {
      case d {
        ast.TypeDecl(..) -> Ok(gen_type_decl(d))
        _ -> Error(Nil)
      }
    })
    |> string.join("\n")

  let proc_code =
    module.decls
    |> list.filter_map(fn(d) {
      case d {
        ast.ProcDecl(..) -> Ok(gen_proc_decl(env, d))
        _ -> Error(Nil)
      }
    })
    |> string.join("\n")

  let body = type_code <> "\n" <> proc_code
  gen_header(body) <> "\n" <> body
}

fn collect_types(decls: List(ast.Decl)) -> Dict(String, ast.Decl) {
  list.fold(decls, dict.new(), fn(acc, d) {
    case d {
      ast.TypeDecl(name, _, _) -> dict.insert(acc, name, d)
      _ -> acc
    }
  })
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
// Type declarations
// ---------------------------------------------------------------------------

fn gen_type_decl(d: ast.Decl) -> String {
  case d {
    ast.TypeDecl(name, variants, commons) ->
      case variants {
        [] -> gen_struct_type(name, commons)
        _ -> gen_union_type(name, variants, commons)
      }
    _ -> ""
  }
}

fn gen_struct_type(name: String, fields: List(ast.Field)) -> String {
  "type " <> name <> " struct {\n" <> gen_fields(fields) <> "}\n"
}

fn gen_union_type(
  name: String,
  variants: List(ast.Variant),
  commons: List(ast.Field),
) -> String {
  let iface = "type " <> name <> " interface {\n\tis" <> name <> "()\n}\n"
  let variant_code =
    variants
    |> list.map(fn(v) { gen_variant(name, v, commons) })
    |> string.concat
  iface <> variant_code
}

fn gen_variant(
  type_name: String,
  v: ast.Variant,
  commons: List(ast.Field),
) -> String {
  let struct_name = type_name <> v.name
  let all_fields = list.append(v.fields, commons)
  "type "
  <> struct_name
  <> " struct {\n"
  <> gen_fields(all_fields)
  <> "}\n"
  <> "func ("
  <> struct_name
  <> ") is"
  <> type_name
  <> "() {}\n"
}

fn gen_fields(fields: List(ast.Field)) -> String {
  fields
  |> list.map(fn(f) { "\t" <> exported(f.name) <> " " <> gen_type(f.typ) <> "\n" })
  |> string.concat
}

fn gen_type(t: ast.TypeExpr) -> String {
  case t {
    ast.TVoid -> ""
    ast.TName(pkg, name, dims) -> {
      let prefix = string.repeat("[]", dims)
      let base = case pkg {
        Some(p) -> p <> "." <> name
        None -> map_base_type(name)
      }
      prefix <> base
    }
  }
}

fn map_base_type(name: String) -> String {
  case name {
    "String" -> "string"
    "Int" -> "int"
    "Bool" -> "bool"
    "Float" -> "float64"
    "Table" -> "hive.Table"
    _ -> name
  }
}

// ---------------------------------------------------------------------------
// Procedures / statements
// ---------------------------------------------------------------------------

fn gen_proc_decl(env: Env, d: ast.Decl) -> String {
  case d {
    ast.ProcDecl(name, params, ret, body) -> {
      let param_str =
        params
        |> list.map(fn(p) { p.name <> " " <> gen_type(p.typ) })
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
      <> name
      <> "("
      <> param_str
      <> ")"
      <> ret_str
      <> " {\n"
      <> gen_stmts(env, body, 1)
      <> terminator
      <> "}\n"
    }
    _ -> ""
  }
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

fn gen_stmts(env: Env, stmts: List(ast.Stmt), indent: Int) -> String {
  case stmts {
    [] -> ""
    [s, ..rest] -> gen_stmt(env, s, rest, indent) <> gen_stmts(env, rest, indent)
  }
}

fn gen_stmt(
  env: Env,
  stmt: ast.Stmt,
  following: List(ast.Stmt),
  indent: Int,
) -> String {
  let pad = tabs(indent)
  case stmt {
    ast.SVarDecl(name, value) -> {
      let decl = pad <> name <> " := " <> gen_expr(env, value) <> "\n"
      decl <> guard(following, name, pad)
    }
    ast.STypedDecl(typ, name, value) -> {
      let decl =
        pad <> "var " <> name <> " " <> gen_type(typ) <> " = " <> gen_expr(env, value) <> "\n"
      decl <> guard(following, name, pad)
    }
    ast.SReturn(None) -> pad <> "return\n"
    ast.SReturn(Some(e)) -> pad <> "return " <> gen_expr(env, e) <> "\n"
    ast.SEcho(e) -> pad <> "fmt.Println(" <> gen_expr(env, e) <> ")\n"
    ast.SExpr(e) -> pad <> gen_expr(env, e) <> "\n"
    ast.SIf(branches, else_body) -> gen_if(env, branches, else_body, indent)
  }
}

// Go rejects unused local bindings, so emit a blank assignment when a declared
// name is never referenced in the statements that can see it.
fn guard(scope: List(ast.Stmt), name: String, pad: String) -> String {
  case uses_in_stmts(scope, name) {
    True -> ""
    False -> pad <> "_ = " <> name <> "\n"
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
      opener
      <> cond_str
      <> " {\n"
      <> gen_bindings(binds, b.body, indent + 1)
      <> gen_stmts(env, b.body, indent + 1)
      <> pad
      <> "}"
    })
    |> string.concat

  let else_code = case else_body {
    Some(body) ->
      " else {\n" <> gen_stmts(env, body, indent + 1) <> pad <> "}"
    None -> ""
  }

  branch_code <> else_code <> "\n"
}

fn gen_bindings(
  binds: List(#(String, String)),
  body: List(ast.Stmt),
  indent: Int,
) -> String {
  let pad = tabs(indent)
  binds
  |> list.map(fn(pair) {
    let #(name, rhs) = pair
    pad <> name <> " := " <> rhs <> "\n" <> guard(body, name, pad)
  })
  |> string.concat
}

// ---------------------------------------------------------------------------
// Conditions and `is` patterns
// ---------------------------------------------------------------------------

// Returns the Go boolean condition plus any bindings (name, rhs) that must be
// introduced at the top of the branch body.
fn gen_condition(env: Env, cond: ast.Expr) -> #(String, List(#(String, String))) {
  case cond {
    ast.EIs(subject, pattern) -> gen_is(env, subject, pattern)
    _ -> #(gen_expr(env, cond), [])
  }
}

fn gen_is(
  env: Env,
  subject: ast.Expr,
  pattern: ast.Pattern,
) -> #(String, List(#(String, String))) {
  let subj = gen_expr(env, subject)
  case pattern {
    // Builtin Result patterns.
    ast.PConstructor(["Result", "Ok"], bindings) -> #(
      subj <> ".IsOk()",
      single_binding(bindings, subj <> ".Ok()"),
    )
    ast.PConstructor(["Result", "Error"], bindings) -> #(
      subj <> ".IsError()",
      single_binding(bindings, subj <> ".Err()"),
    )
    // User-defined tagged-union patterns via Go type assertions.
    ast.PConstructor([type_name, variant_name], bindings) ->
      gen_adt_is(env, subj, type_name, variant_name, bindings)
    ast.PConstructor(_, _) -> #(gen_expr(env, subject), [])
  }
}

fn single_binding(
  bindings: List(String),
  rhs: String,
) -> List(#(String, String)) {
  case bindings {
    // A `_` placeholder binds nothing.
    ["_"] -> []
    [name] -> [#(name, rhs)]
    _ -> []
  }
}

fn gen_adt_is(
  env: Env,
  subj: String,
  type_name: String,
  variant_name: String,
  bindings: List(String),
) -> #(String, List(#(String, String))) {
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
      let field = case list_at(fields, i) {
        Some(f) -> exported(f.name)
        None -> "Field" <> int.to_string(i)
      }
      #(name, subj <> ".(" <> struct_name <> ")." <> field)
    })
  #(cond, binds)
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

fn gen_expr(env: Env, e: ast.Expr) -> String {
  case e {
    ast.EInt(v) -> int.to_string(v)
    ast.EString(s) -> gen_string_lit(s)
    ast.EBool(b) ->
      case b {
        True -> "true"
        False -> "false"
      }
    ast.EIdent(name) -> name
    ast.EMember(target, field) -> gen_expr(env, target) <> "." <> field
    ast.EIndex(target, idx) ->
      gen_expr(env, target) <> "[" <> gen_expr(env, idx) <> "]"
    ast.ESlice(target, low, high) -> gen_slice(env, target, low, high)
    ast.EBinary(op, l, r) ->
      "(" <> gen_expr(env, l) <> " " <> gen_binop(op) <> " " <> gen_expr(env, r) <> ")"
    ast.EUsing(path, delim, _) -> gen_using(env, path, delim)
    ast.EIs(subject, pattern) -> {
      let #(cond, _) = gen_is(env, subject, pattern)
      cond
    }
    ast.ECall(callee, args) -> gen_call(env, callee, args)
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
  let delim_str = case delim {
    Some(d) -> gen_expr(env, d)
    None -> "\",\""
  }
  "hive.ReadCSV(" <> gen_expr(env, path) <> ", " <> delim_str <> ")"
}

fn gen_call(env: Env, callee: ast.Expr, args: List(ast.Expr)) -> String {
  case callee {
    ast.EIdent(name) -> gen_ident_call(env, name, args)
    ast.EMember(ast.EIdent(type_name), variant_name) ->
      case dict.get(env.types, type_name) {
        Ok(_) -> gen_constructor(env, type_name, variant_name, args)
        Error(_) -> gen_plain_call(env, callee, args)
      }
    _ -> gen_plain_call(env, callee, args)
  }
}

fn gen_ident_call(env: Env, name: String, args: List(ast.Expr)) -> String {
  case name {
    "len" -> "len(" <> gen_args(env, args) <> ")"
    "now" -> "hive.Now()"
    "print" -> "fmt.Print(" <> gen_args(env, args) <> ")"
    "println" -> "fmt.Println(" <> gen_args(env, args) <> ")"
    _ ->
      case dict.get(env.types, name) {
        // Bare `Type(...)` constructs the first variant (or the struct itself
        // for a variant-less type).
        Ok(ast.TypeDecl(_, [first, ..], _)) ->
          gen_constructor(env, name, first.name, args)
        Ok(ast.TypeDecl(_, [], _)) -> gen_struct_construct(env, name, args)
        _ -> name <> "(" <> gen_args(env, args) <> ")"
      }
  }
}

fn gen_constructor(
  env: Env,
  type_name: String,
  variant_name: String,
  args: List(ast.Expr),
) -> String {
  let struct_name = type_name <> variant_name
  let fields = variant_fields(env, type_name, variant_name)
  struct_name <> "{" <> zip_fields(env, fields, args) <> "}"
}

fn gen_struct_construct(
  env: Env,
  type_name: String,
  args: List(ast.Expr),
) -> String {
  let fields = case dict.get(env.types, type_name) {
    Ok(ast.TypeDecl(_, _, commons)) -> commons
    _ -> []
  }
  type_name <> "{" <> zip_fields(env, fields, args) <> "}"
}

fn zip_fields(env: Env, fields: List(ast.Field), args: List(ast.Expr)) -> String {
  args
  |> list.index_map(fn(arg, i) {
    let field_name = case list_at(fields, i) {
      Some(f) -> exported(f.name)
      None -> "Field" <> int.to_string(i)
    }
    field_name <> ": " <> gen_expr(env, arg)
  })
  |> string.join(", ")
}

fn gen_plain_call(env: Env, callee: ast.Expr, args: List(ast.Expr)) -> String {
  gen_expr(env, callee) <> "(" <> gen_args(env, args) <> ")"
}

fn gen_args(env: Env, args: List(ast.Expr)) -> String {
  args
  |> list.map(fn(a) { gen_expr(env, a) })
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
    ast.SVarDecl(_, value) -> uses_in_expr(value, name)
    ast.STypedDecl(_, _, value) -> uses_in_expr(value, name)
    ast.SReturn(None) -> False
    ast.SReturn(Some(e)) -> uses_in_expr(e, name)
    ast.SEcho(e) -> uses_in_expr(e, name)
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
  }
}

fn uses_in_expr(e: ast.Expr, name: String) -> Bool {
  case e {
    ast.EInt(_) -> False
    ast.EString(_) -> False
    ast.EBool(_) -> False
    ast.EIdent(n) -> n == name
    ast.EMember(t, _) -> uses_in_expr(t, name)
    ast.ECall(callee, args) ->
      uses_in_expr(callee, name) || list.any(args, fn(a) { uses_in_expr(a, name) })
    ast.EIndex(t, idx) -> uses_in_expr(t, name) || uses_in_expr(idx, name)
    ast.ESlice(t, lo, hi) ->
      uses_in_expr(t, name) || uses_in_opt(lo, name) || uses_in_opt(hi, name)
    ast.EBinary(_, l, r) -> uses_in_expr(l, name) || uses_in_expr(r, name)
    ast.EIs(subject, _) -> uses_in_expr(subject, name)
    ast.EUsing(path, delim, _) ->
      uses_in_expr(path, name) || uses_in_opt(delim, name)
  }
}

fn uses_in_opt(o: Option(ast.Expr), name: String) -> Bool {
  case o {
    Some(e) -> uses_in_expr(e, name)
    None -> False
  }
}
