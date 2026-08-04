//// Monomorphization: turning generic callables into concrete ones.
////
//// A name in a signature that is neither a builtin nor a declared type is a
//// **type variable**, which makes the callable generic in it:
////
////     func first(v: T[]): Result<T, Bool> { ... }
////
//// This is the notation the builtin table has always used to describe `len`,
//// `indexOf` and `append`; it is now available to ordinary code.
////
//// There is no runtime to any of it. Every call site is resolved here, before
//// any other pass runs: the type arguments are inferred from the argument
//// types, and one concrete copy of the callable is emitted per distinct set of
//// them (`first_Str`, `first_Int`). The generic original is dropped.
////
//// Inference unifies an argument against the parameter's whole type, not just
//// its head, so a variable is pinned down wherever it appears — including inside
//// a parameter that is itself a function. That is what makes a higher-order
//// generic work:
////
////     func filterMap(v: T[], f: func(T): Result<K, E>): K[dyn] { ... }
////
//// `T` comes from the vector, `K` and `E` from the function. A copy substitutes
//// through its *body* as well as its signature, since a body writes types down
//// of its own (`mut K[dyn] out = []`, `for each x: T in v`, `Box<T> b = ...`).
////
//// Doing it as an AST-to-AST pass, rather than inside codegen, is what keeps
//// the guarantees intact — every instantiation is an ordinary Hive declaration
//// that the validation, type and bounds passes then check like any other. Two
//// of those checks get *sharper* for it: an instantiation at `T = Str[3]` is
//// held to that length while one at `T = Str[dyn]` guards its indexes, which
//// is the right answer for both and not something a single runtime-generic
//// function could do.
////
//// The analysis runs to a fixpoint: instantiating a body can reveal calls that
//// need instantiating in turn. A generic that instantiates itself at an
//// ever-larger type would not converge, so the round and total counts are
//// capped and overrunning them is a compile error.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import hive/ast
import hive/codegen

/// How many distinct instantiations a program may have, and how many times the
/// fixpoint may go round. Both exist only to turn a non-terminating expansion
/// into a diagnostic; a real program stays far below either.
const max_instantiations = 256

const max_rounds = 16

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn expand(module: ast.Module) -> Result(ast.Module, String) {
  let types = collect_types(module.decls)
  let generics = collect_generics(types, module.decls)
  let generic_types = collect_generic_types(types, module.decls)
  case dict.is_empty(generics) && dict.is_empty(generic_types) {
    // Nothing generic: the overwhelmingly common case, and it costs one pass
    // over the declarations to find out.
    True -> Ok(module)
    False -> {
      // The generic originals are dropped; only their instantiations survive.
      let concrete =
        list.filter(module.decls, fn(d) {
          case decl_name(d) {
            Some(n) ->
              !dict.has_key(generics, n) && !dict.has_key(generic_types, n)
            None -> True
          }
        })
      run_rounds(module, generics, generic_types, concrete, dict.new(), 0)
    }
  }
}

// A type declaration whose fields mention variables is generic in them, in
// first-appearance order across its variants and then its common fields.
fn collect_generic_types(
  types: Dict(String, ast.Decl),
  decls: List(ast.Decl),
) -> Dict(String, Generic) {
  list.fold(decls, dict.new(), fn(acc, d) {
    case d {
      ast.TypeDecl(name, variants, commons) -> {
        let fields =
          list.append(list.flat_map(variants, fn(v) { v.fields }), commons)
        let vars =
          list.fold(fields, [], fn(seen, f) { vars_in(types, f.typ, seen) })
        case vars {
          [] -> acc
          _ -> dict.insert(acc, name, Generic(d, vars))
        }
      }
      _ -> acc
    }
  })
}

// Walks every concrete declaration, collecting the instantiations its calls
// need; if that turned up anything new, the instantiated copies join the module
// and the walk repeats, since their bodies can call generics of their own.
fn run_rounds(
  module: ast.Module,
  generics: Dict(String, Generic),
  generic_types: Dict(String, Generic),
  concrete: List(ast.Decl),
  wanted: Dict(String, Inst),
  round: Int,
) -> Result(ast.Module, String) {
  use _ <- result.try(case round > max_rounds {
    True ->
      Error(
        "generic expansion did not settle after "
        <> int.to_string(max_rounds)
        <> " rounds — a generic callable is very likely instantiating itself "
        <> "at an ever-larger type.",
      )
    False -> Ok(Nil)
  })

  // The module as it stands this round, so inference can see the signatures of
  // the instantiations already made.
  let staged =
    ast.Module(module.imports, list.append(concrete, instantiated(wanted)))
  let env = codegen.module_env(staged)

  // Instantiated types are ordinary declarations from here on, so they must be
  // visible as such — otherwise `Box_Str` would look like a type variable.
  let st =
    State(
      collect_types(staged.decls),
      generics,
      generic_types,
      wanted,
      [],
      None,
    )
  use #(rewritten, st) <- result.try(walk_decls(st, env, concrete))
  use #(inst_rewritten, st) <- result.try(
    walk_decls(st, env, instantiated(st.wanted)),
  )

  use _ <- result.try(case dict.size(st.wanted) > max_instantiations {
    True ->
      Error(
        "this program needs more than "
        <> int.to_string(max_instantiations)
        <> " generic instantiations, which is almost certainly a generic "
        <> "callable instantiating itself at an ever-larger type.",
      )
    False -> Ok(Nil)
  })

  case dict.size(st.wanted) == dict.size(wanted), st.deferred {
    // A full round added nothing and left nothing unresolved: every call now
    // names a concrete callable.
    True, [] ->
      Ok(ast.Module(module.imports, list.append(rewritten, inst_rewritten)))
    // Nothing new, but something still cannot be resolved — so it never will be.
    True, [why, ..] -> Error(why)
    False, _ ->
      run_rounds(module, generics, generic_types, concrete, st.wanted, round + 1)
  }
}

fn instantiated(wanted: Dict(String, Inst)) -> List(ast.Decl) {
  wanted |> dict.values |> list.map(fn(i) { i.decl })
}

// ---------------------------------------------------------------------------
// What is generic, and at what
// ---------------------------------------------------------------------------

/// A generic callable: its declaration and the type variables of its signature,
/// in first-appearance order.
type Generic {
  Generic(decl: ast.Decl, vars: List(String))
}

/// One instantiation: the specialized declaration, kept under its mangled name.
type Inst {
  Inst(decl: ast.Decl)
}

type State {
  State(
    types: Dict(String, ast.Decl),
    generics: Dict(String, Generic),
    /// Generic type declarations, by name. `type Box { items: T[dyn] }` is
    /// generic in `T` exactly as a callable would be, and is written `Box<Str>`
    /// where it is used.
    generic_types: Dict(String, Generic),
    /// Instantiations wanted so far, by mangled name.
    wanted: Dict(String, Inst),
    /// Calls that could not be resolved yet, with why. A nested generic call
    /// (`outer(inner(v))`) cannot be resolved until `inner`'s own instantiation
    /// exists to be inferred through, so the first round leaves it be and a
    /// later one picks it up. Only a round that adds nothing new *and* still
    /// has deferrals is a real error.
    deferred: List(String),
    /// The return type of the declaration being walked. A constructor written
    /// in a `return` takes its type arguments from here, exactly as one in a
    /// typed declaration takes them from the slot.
    ret_type: Option(ast.TypeExpr),
  )
}

fn collect_types(decls: List(ast.Decl)) -> Dict(String, ast.Decl) {
  list.fold(decls, dict.new(), fn(acc, d) {
    case d {
      ast.TypeDecl(name, _, _) -> dict.insert(acc, name, d)
      _ -> acc
    }
  })
}

fn decl_name(d: ast.Decl) -> Option(String) {
  case d {
    ast.ProcDecl(name, _, _, _)
    | ast.FuncDecl(name, _, _, _, _)
    | ast.QueryDecl(name, _, _, _)
    | ast.TypeDecl(name, _, _) -> Some(name)
  }
}

fn collect_generics(
  types: Dict(String, ast.Decl),
  decls: List(ast.Decl),
) -> Dict(String, Generic) {
  list.fold(decls, dict.new(), fn(acc, d) {
    case d {
      ast.ProcDecl(name, params, ret, _)
      | ast.FuncDecl(name, params, ret, _, _)
      | ast.QueryDecl(name, params, ret, _) -> {
        let vars =
          list.fold(
            list.append(list.map(params, fn(p) { p.typ }), [ret]),
            [],
            fn(seen, t) { vars_in(types, t, seen) },
          )
        case vars {
          [] -> acc
          _ -> dict.insert(acc, name, Generic(d, vars))
        }
      }
      ast.TypeDecl(..) -> acc
    }
  })
}

// Type variables reachable from a type expression, appended to `seen` in
// first-appearance order.
fn vars_in(
  types: Dict(String, ast.Decl),
  t: ast.TypeExpr,
  seen: List(String),
) -> List(String) {
  case t {
    ast.TVoid -> seen
    ast.TFunc(_, params, ret) ->
      list.fold(list.append(params, [ret]), seen, fn(acc, p) {
        vars_in(types, p, acc)
      })
    ast.TName(pkg, name, args, _) -> {
      let seen =
        list.fold(args, seen, fn(acc, a) { vars_in(types, a, acc) })
      case is_variable(types, pkg, name) && !list.contains(seen, name) {
        True -> list.append(seen, [name])
        False -> seen
      }
    }
  }
}

// A bare, unqualified name that names neither a builtin nor a declared type.
fn is_variable(
  types: Dict(String, ast.Decl),
  pkg: Option(String),
  name: String,
) -> Bool {
  case pkg {
    Some(_) -> False
    None ->
      case name {
        "Str"
        | "String"
        | "Int"
        | "Float"
        | "Bool"
        | "Atom"
        | "Table"
        | "Result" -> False
        _ -> !dict.has_key(types, name)
      }
  }
}

// ---------------------------------------------------------------------------
// Substitution
// ---------------------------------------------------------------------------

// Replacing a variable keeps the *slot's* own vector markers outside the
// substituted type's: `T[]` at `T = Str[dyn]` is a vector of `Str[dyn]`, which
// is `Str[][dyn]` — the slot's dimension stays outermost.
fn substitute(
  subst: Dict(String, ast.TypeExpr),
  t: ast.TypeExpr,
) -> ast.TypeExpr {
  case t {
    ast.TVoid -> t
    ast.TFunc(pure, params, ret) ->
      ast.TFunc(
        pure,
        list.map(params, substitute(subst, _)),
        substitute(subst, ret),
      )
    ast.TName(pkg, name, args, dims) -> {
      let args = list.map(args, substitute(subst, _))
      case pkg, dict.get(subst, name) {
        None, Ok(ast.TName(rp, rn, ra, rd)) ->
          ast.TName(rp, rn, ra, list.append(dims, rd))
        None, Ok(other) ->
          case dims {
            // A function type has no dimensions to carry, so a slot that wanted
            // a vector of one cannot be expressed.
            [] -> other
            _ -> ast.TName(pkg, name, args, dims)
          }
        _, _ -> ast.TName(pkg, name, args, dims)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Unification: what the arguments say the variables are
// ---------------------------------------------------------------------------

fn unify(
  param: codegen.Ty,
  arg: codegen.Ty,
  subst: Dict(String, codegen.Ty),
) -> Dict(String, codegen.Ty) {
  case param, arg {
    codegen.TyVar(v), _ ->
      case dict.get(subst, v), arg {
        // Nothing useful to learn from an argument we could not infer.
        _, codegen.TyUnknown -> subst
        Ok(_), _ -> subst
        Error(_), _ -> dict.insert(subst, v, arg)
      }
    codegen.TyVec(p), codegen.TyVec(a) -> unify(p, a, subst)
    // A Table is a vector of vectors of Str, so it matches a `T[]` parameter.
    codegen.TyVec(p), codegen.TyTable ->
      unify(p, codegen.TyVec(codegen.TyStr), subst)
    codegen.TyResult(po, pe), codegen.TyResult(ao, ae) ->
      unify(pe, ae, unify(po, ao, subst))
    codegen.TyFunc(_, pp, pr), codegen.TyFunc(_, ap, ar) ->
      case list.strict_zip(pp, ap) {
        Ok(pairs) ->
          unify(
            pr,
            ar,
            list.fold(pairs, subst, fn(acc, pair) {
              unify(pair.0, pair.1, acc)
            }),
          )
        Error(_) -> unify(pr, ar, subst)
      }
    _, _ -> subst
  }
}

// The concrete spelling of an inferred type, for building the specialized
// declaration. `None` when the type has no surface syntax — an `async` handle,
// a syslink address, or something inference could not pin down.
fn spell(ty: codegen.Ty) -> Option(ast.TypeExpr) {
  case ty {
    codegen.TyStr -> Some(plain("Str"))
    codegen.TyInt -> Some(plain("Int"))
    codegen.TyFloat -> Some(plain("Float"))
    codegen.TyBool -> Some(plain("Bool"))
    codegen.TyAtom -> Some(plain("Atom"))
    codegen.TyTable -> Some(plain("Table"))
    codegen.TyVoid -> Some(ast.TVoid)
    codegen.TyCustom(name) -> Some(plain(name))
    codegen.TyBuiltin(name) ->
      Some(ast.TName(Some(codegen.builtin_qualifier(name)), name, [], []))
    codegen.TyResult(ok, err) ->
      case spell(ok), spell(err) {
        Some(o), Some(e) -> Some(ast.TName(None, "Result", [o, e], []))
        _, _ -> None
      }
    codegen.TyVec(elem) ->
      case spell(elem) {
        Some(ast.TName(pkg, name, args, dims)) ->
          Some(ast.TName(pkg, name, args, [ast.DimDyn, ..dims]))
        _ -> None
      }
    codegen.TyFunc(pure, params, ret) -> {
      let spelled = list.filter_map(params, fn(p) { option.to_result(spell(p), Nil) })
      case list.length(spelled) == list.length(params), spell(ret) {
        True, Some(r) -> Some(ast.TFunc(pure, spelled, r))
        _, _ -> None
      }
    }
    _ -> None
  }
}

fn plain(name: String) -> ast.TypeExpr {
  ast.TName(None, name, [], [])
}

// A Go-safe suffix identifying an instantiation, so `first` at `Str` and at
// `Int` are two different functions with two readable names.
fn mangle(ty: codegen.Ty) -> String {
  case ty {
    codegen.TyStr -> "Str"
    codegen.TyInt -> "Int"
    codegen.TyFloat -> "Float"
    codegen.TyBool -> "Bool"
    codegen.TyAtom -> "Atom"
    codegen.TyTable -> "Table"
    codegen.TyVoid -> "Void"
    codegen.TyCustom(name) -> name
    codegen.TyBuiltin(name) -> name
    codegen.TyVec(elem) -> "Vec" <> mangle(elem)
    codegen.TyResult(ok, err) -> "Result" <> mangle(ok) <> mangle(err)
    codegen.TyFunc(_, params, ret) ->
      "Fn" <> string.concat(list.map(params, mangle)) <> mangle(ret)
    codegen.TyVar(name) -> name
    _ -> "Any"
  }
}

// ---------------------------------------------------------------------------
// Instantiating a generic type
// ---------------------------------------------------------------------------

// `Box<Str>` in any type position becomes a reference to a concrete `Box_Str`,
// which is generated on the spot. The instantiated declaration is an ordinary
// `TypeDecl`, so its clone, its JSON codec and its structural digest are all
// derived exactly as they are for a hand-written type — and two instantiations
// get two digests, which is what keeps `Box<Str>` and `Box<Int>` distinct on the
// wire.
fn rewrite_type(st: State, t: ast.TypeExpr) -> #(ast.TypeExpr, State) {
  case t {
    ast.TVoid -> #(t, st)
    ast.TFunc(pure, params, ret) -> {
      let #(params2, st2) = rewrite_types(st, params)
      let #(ret2, st3) = rewrite_type(st2, ret)
      #(ast.TFunc(pure, params2, ret2), st3)
    }
    ast.TName(pkg, name, args, dims) -> {
      let #(args2, st2) = rewrite_types(st, args)
      case pkg, dict.get(st2.generic_types, name), args2 {
        None, Ok(g), [_, ..] ->
          case instantiate_type(st2, name, g, args2) {
            Ok(#(mangled, st3)) -> #(ast.TName(None, mangled, [], dims), st3)
            Error(why) -> #(t, State(..st2, deferred: [why, ..st2.deferred]))
          }
        None, Ok(g), [] -> #(
          t,
          State(..st2, deferred: [needs_arguments(name, g), ..st2.deferred]),
        )
        _, _, _ -> #(ast.TName(pkg, name, args2, dims), st2)
      }
    }
  }
}

fn rewrite_types(
  st: State,
  types: List(ast.TypeExpr),
) -> #(List(ast.TypeExpr), State) {
  list.fold(types, #([], st), fn(acc, t) {
    let #(seen, st) = acc
    let #(t2, st2) = rewrite_type(st, t)
    #([t2, ..seen], st2)
  })
  |> fn(acc) {
    let #(seen, st) = acc
    #(list.reverse(seen), st)
  }
}

fn needs_arguments(name: String, g: Generic) -> String {
  "`"
  <> name
  <> "` is generic in "
  <> string.join(list.map(g.vars, fn(v) { "`" <> v <> "`" }), ", ")
  <> ", so it needs its type arguments here: write `"
  <> name
  <> "<"
  <> string.join(list.map(g.vars, fn(_) { "..." }), ", ")
  <> ">`."
}

fn instantiate_type(
  st: State,
  name: String,
  g: Generic,
  args: List(ast.TypeExpr),
) -> Result(#(String, State), String) {
  case list.strict_zip(g.vars, args) {
    Error(_) ->
      Error(
        "`"
        <> name
        <> "` takes "
        <> int.to_string(list.length(g.vars))
        <> " type "
        <> plural(list.length(g.vars), "argument")
        <> " but was given "
        <> int.to_string(list.length(args))
        <> ".",
      )
    Ok(pairs) -> {
      let mangled =
        name
        <> "_"
        <> string.join(list.map(args, mangle_type_expr), "_")
      case dict.has_key(st.wanted, mangled) {
        True -> Ok(#(mangled, st))
        False -> {
          let table = dict.from_list(pairs)
          let decl = specialize_type(g.decl, mangled, table)
          Ok(#(
            mangled,
            State(..st, wanted: dict.insert(st.wanted, mangled, Inst(decl))),
          ))
        }
      }
    }
  }
}

fn plural(n: Int, word: String) -> String {
  case n {
    1 -> word
    _ -> word <> "s"
  }
}

fn specialize_type(
  d: ast.Decl,
  mangled: String,
  subst: Dict(String, ast.TypeExpr),
) -> ast.Decl {
  let sub = fn(f: ast.Field) { ast.Field(f.name, substitute(subst, f.typ)) }
  case d {
    ast.TypeDecl(_, variants, commons) ->
      ast.TypeDecl(
        mangled,
        list.map(variants, fn(v) { ast.Variant(v.name, list.map(v.fields, sub)) }),
        list.map(commons, sub),
      )
    _ -> d
  }
}

// A name for an instantiation, taken from the written type rather than an
// inferred one.
fn mangle_type_expr(t: ast.TypeExpr) -> String {
  case t {
    ast.TVoid -> "Void"
    ast.TFunc(_, params, ret) ->
      "Fn"
      <> string.concat(list.map(params, mangle_type_expr))
      <> mangle_type_expr(ret)
    ast.TName(_, name, args, dims) ->
      name
      <> string.concat(list.map(args, mangle_type_expr))
      <> string.concat(list.map(dims, fn(d) {
        case d {
          ast.DimStatic(n) -> "A" <> int.to_string(n)
          _ -> "Vec"
        }
      }))
  }
}

// ---------------------------------------------------------------------------
// Walking and rewriting
// ---------------------------------------------------------------------------

fn walk_decls(
  st: State,
  env: codegen.Env,
  decls: List(ast.Decl),
) -> Result(#(List(ast.Decl), State), String) {
  list.try_fold(decls, #([], st), fn(acc, d) {
    let #(seen, st) = acc
    use #(d2, st2) <- result.try(walk_decl(st, env, d))
    Ok(#([d2, ..seen], st2))
  })
  |> result.map(fn(acc) {
    let #(seen, st) = acc
    #(list.reverse(seen), st)
  })
}

fn walk_decl(
  st: State,
  env: codegen.Env,
  d: ast.Decl,
) -> Result(#(ast.Decl, State), String) {
  case d {
    ast.ProcDecl(name, params, ret, body) -> {
      let #(params, ret, st) = rewrite_signature(st, params, ret)
      let st = State(..st, ret_type: Some(ret))
      let benv = codegen.fn_env(env, params, ret)
      use #(body2, st2) <- result.try(walk_stmts(st, benv, body))
      Ok(#(ast.ProcDecl(name, params, ret, body2), st2))
    }
    ast.FuncDecl(name, params, ret, body, async) -> {
      let #(params, ret, st) = rewrite_signature(st, params, ret)
      let st = State(..st, ret_type: Some(ret))
      let benv = codegen.fn_env(env, params, ret)
      use #(body2, st2) <- result.try(walk_stmts(st, benv, body))
      Ok(#(ast.FuncDecl(name, params, ret, body2, async), st2))
    }
    ast.QueryDecl(name, params, ret, sql) -> {
      let #(params, ret, st) = rewrite_signature(st, params, ret)
      let st = State(..st, ret_type: Some(ret))
      let benv = codegen.fn_env(env, params, ret)
      use #(sql2, st2) <- result.try(walk_sql(st, benv, sql))
      Ok(#(ast.QueryDecl(name, params, ret, sql2), st2))
    }
    ast.TypeDecl(name, variants, commons) -> {
      let #(variants, st) =
        list.fold(variants, #([], st), fn(acc, v) {
          let #(seen, st) = acc
          let #(fields, st2) = rewrite_fields(st, v.fields)
          #([ast.Variant(v.name, fields), ..seen], st2)
        })
      let #(commons, st) = rewrite_fields(st, commons)
      Ok(#(ast.TypeDecl(name, list.reverse(variants), commons), st))
    }
  }
}

fn rewrite_signature(
  st: State,
  params: List(ast.Field),
  ret: ast.TypeExpr,
) -> #(List(ast.Field), ast.TypeExpr, State) {
  let #(params2, st2) = rewrite_fields(st, params)
  let #(ret2, st3) = rewrite_type(st2, ret)
  #(params2, ret2, st3)
}

fn rewrite_fields(
  st: State,
  fields: List(ast.Field),
) -> #(List(ast.Field), State) {
  list.fold(fields, #([], st), fn(acc, f) {
    let #(seen, st) = acc
    let #(t2, st2) = rewrite_type(st, f.typ)
    #([ast.Field(f.name, t2), ..seen], st2)
  })
  |> fn(acc) {
    let #(seen, st) = acc
    #(list.reverse(seen), st)
  }
}

fn walk_stmts(
  st: State,
  env: codegen.Env,
  stmts: List(ast.Stmt),
) -> Result(#(List(ast.Stmt), State), String) {
  list.try_fold(stmts, #([], env, st), fn(acc, s) {
    let #(seen, env, st) = acc
    use #(s2, env2, st2) <- result.try(walk_stmt(st, env, s))
    Ok(#([s2, ..seen], env2, st2))
  })
  |> result.map(fn(acc) {
    let #(seen, _, st) = acc
    #(list.reverse(seen), st)
  })
}

fn walk_stmt(
  st: State,
  env: codegen.Env,
  s: ast.Stmt,
) -> Result(#(ast.Stmt, codegen.Env, State), String) {
  case s {
    ast.SVarDecl(name, value, mutable) -> {
      use #(v2, st2) <- result.try(walk_expr(st, env, value))
      let env2 = codegen.with_local(env, name, codegen.infer(env, v2))
      Ok(#(ast.SVarDecl(name, v2, mutable), env2, st2))
    }
    ast.STypedDecl(typ, name, value, mutable) -> {
      let #(typ, st) = rewrite_type(st, typ)
      let value = retarget(st, typ, value)
      use #(v2, st2) <- result.try(walk_expr(st, env, value))
      let env2 =
        codegen.with_local(
          env,
          name,
          codegen.ty_of_type_expr(codegen.env_types(env), typ),
        )
      Ok(#(ast.STypedDecl(typ, name, v2, mutable), env2, st2))
    }
    ast.SAssign(target, value) -> {
      use #(t2, st2) <- result.try(walk_expr(st, env, target))
      use #(v2, st3) <- result.try(walk_expr(st2, env, value))
      Ok(#(ast.SAssign(t2, v2), env, st3))
    }
    ast.SReturn(Some(e)) -> {
      let e = case st.ret_type {
        Some(t) -> retarget(st, t, e)
        None -> e
      }
      use #(e2, st2) <- result.try(walk_expr(st, env, e))
      Ok(#(ast.SReturn(Some(e2)), env, st2))
    }
    ast.SEcho(e) -> {
      use #(e2, st2) <- result.try(walk_expr(st, env, e))
      Ok(#(ast.SEcho(e2), env, st2))
    }
    ast.SAssert(e) -> {
      use #(e2, st2) <- result.try(walk_expr(st, env, e))
      Ok(#(ast.SAssert(e2), env, st2))
    }
    ast.SPanic(e) -> {
      use #(e2, st2) <- result.try(walk_expr(st, env, e))
      Ok(#(ast.SPanic(e2), env, st2))
    }
    ast.SExpr(e) -> {
      use #(e2, st2) <- result.try(walk_expr(st, env, e))
      Ok(#(ast.SExpr(e2), env, st2))
    }
    ast.SReturn(None) | ast.SBreak | ast.SContinue -> Ok(#(s, env, st))
    ast.SIf(branches, else_body) -> {
      use #(branches2, st2) <- result.try(
        list.try_fold(branches, #([], st), fn(acc, b) {
          let #(seen, st) = acc
          use #(cond2, st2) <- result.try(walk_expr(st, env, b.cond))
          // Whatever the condition binds is in scope in the body.
          let benv =
            list.fold(
              codegen.condition_binds(env, cond2),
              env,
              fn(e, bind) { codegen.with_local(e, bind.0, bind.1) },
            )
          use #(body2, st3) <- result.try(walk_stmts(st2, benv, b.body))
          Ok(#([ast.Branch(cond2, body2), ..seen], st3))
        })
        |> result.map(fn(acc) {
          let #(seen, st) = acc
          #(list.reverse(seen), st)
        }),
      )
      case else_body {
        Some(body) -> {
          use #(body2, st3) <- result.try(walk_stmts(st2, env, body))
          Ok(#(ast.SIf(branches2, Some(body2)), env, st3))
        }
        None -> Ok(#(ast.SIf(branches2, None), env, st2))
      }
    }
    ast.SFor(init, cond, post, body) -> {
      use #(init2, ienv, st2) <- result.try(case init {
        Some(stmt) -> {
          use #(s2, e2, st2) <- result.try(walk_stmt(st, env, stmt))
          Ok(#(Some(s2), e2, st2))
        }
        None -> Ok(#(None, env, st))
      })
      use #(cond2, st3) <- result.try(case cond {
        Some(e) -> {
          use #(e2, st3) <- result.try(walk_expr(st2, ienv, e))
          Ok(#(Some(e2), st3))
        }
        None -> Ok(#(None, st2))
      })
      use #(post2, st4) <- result.try(case post {
        Some(stmt) -> {
          use #(s2, _, st4) <- result.try(walk_stmt(st3, ienv, stmt))
          Ok(#(Some(s2), st4))
        }
        None -> Ok(#(None, st3))
      })
      use #(body2, st5) <- result.try(walk_stmts(st4, ienv, body))
      // The counter is scoped to the loop.
      Ok(#(ast.SFor(init2, cond2, post2, body2), env, st5))
    }
    ast.SForEach(name, elem_type, iterable, body) -> {
      let #(elem_type, st) = case elem_type {
        Some(t) -> {
          let #(t2, st2) = rewrite_type(st, t)
          #(Some(t2), st2)
        }
        None -> #(None, st)
      }
      use #(it2, st2) <- result.try(walk_expr(st, env, iterable))
      let elem = case elem_type {
        Some(t) -> codegen.ty_of_type_expr(codegen.env_types(env), t)
        None -> codegen.elem_ty_of(codegen.infer(env, it2))
      }
      use #(body2, st3) <- result.try(
        walk_stmts(st2, codegen.with_local(env, name, elem), body),
      )
      Ok(#(ast.SForEach(name, elem_type, it2, body2), env, st3))
    }
  }
}

fn walk_parts(
  st: State,
  env: codegen.Env,
  parts: List(ast.IPart),
) -> Result(#(List(ast.IPart), State), String) {
  list.try_fold(parts, #([], st), fn(acc, part) {
    let #(seen, st) = acc
    case part {
      ast.ILit(_) -> Ok(#([part, ..seen], st))
      ast.IExpr(e) -> {
        use #(e2, st2) <- result.try(walk_expr(st, env, e))
        Ok(#([ast.IExpr(e2), ..seen], st2))
      }
    }
  })
  |> result.map(fn(acc) {
    let #(seen, st) = acc
    #(list.reverse(seen), st)
  })
}

fn walk_sql(
  st: State,
  env: codegen.Env,
  parts: List(ast.SqlPart),
) -> Result(#(List(ast.SqlPart), State), String) {
  list.try_fold(parts, #([], st), fn(acc, part) {
    let #(seen, st) = acc
    case part {
      ast.SqlLit(_) -> Ok(#([part, ..seen], st))
      ast.SqlParam(e) -> {
        use #(e2, st2) <- result.try(walk_expr(st, env, e))
        Ok(#([ast.SqlParam(e2), ..seen], st2))
      }
      ast.SqlWhere(group) -> {
        use #(g, st2) <- result.try(walk_group(st, env, group))
        Ok(#([ast.SqlWhere(g), ..seen], st2))
      }
    }
  })
  |> result.map(fn(acc) {
    let #(seen, st) = acc
    #(list.reverse(seen), st)
  })
}

fn walk_group(
  st: State,
  env: codegen.Env,
  group: ast.SqlGroup,
) -> Result(#(ast.SqlGroup, State), String) {
  use #(items, st2) <- result.try(
    list.try_fold(group.items, #([], st), fn(acc, item) {
      let #(seen, st) = acc
      case item {
        ast.SqlCond(cond, body) -> {
          use #(c, st2) <- result.try(walk_expr(st, env, cond))
          use #(b, st3) <- result.try(walk_sql(st2, env, body))
          Ok(#([ast.SqlCond(c, b), ..seen], st3))
        }
        ast.SqlNested(inner) -> {
          use #(g, st2) <- result.try(walk_group(st, env, inner))
          Ok(#([ast.SqlNested(g), ..seen], st2))
        }
      }
    })
    |> result.map(fn(acc) {
      let #(seen, st) = acc
      #(list.reverse(seen), st)
    }),
  )
  Ok(#(ast.SqlGroup(group.conjunction, items), st2))
}

fn walk_exprs(
  st: State,
  env: codegen.Env,
  exprs: List(ast.Expr),
) -> Result(#(List(ast.Expr), State), String) {
  list.try_fold(exprs, #([], st), fn(acc, e) {
    let #(seen, st) = acc
    use #(e2, st2) <- result.try(walk_expr(st, env, e))
    Ok(#([e2, ..seen], st2))
  })
  |> result.map(fn(acc) {
    let #(seen, st) = acc
    #(list.reverse(seen), st)
  })
}

fn walk_expr(
  st: State,
  env: codegen.Env,
  e: ast.Expr,
) -> Result(#(ast.Expr, State), String) {
  case e {
    ast.ECall(ast.EIdent(f), args) -> {
      use #(args2, st2) <- result.try(
        walk_exprs(st, env, list.map(args, fn(a) { a.value })),
      )
      let rebuilt =
        list.map2(args, args2, fn(a, v) { ast.Arg(a.name, v) })
      case dict.get(st2.generics, f) {
        // A generic *type* constructed positionally: `Box(["a"])`. The type
        // arguments come from the fields the values are filling.
        Error(_) ->
          case dict.get(st2.generic_types, f) {
            Error(_) -> Ok(#(ast.ECall(ast.EIdent(f), rebuilt), st2))
            Ok(g) -> {
              let #(resolved, st3) =
                infer_type_args(st2, env, f, g, variant_of(g.decl, None), rebuilt)
              case resolved {
                Some(mangled) ->
                  Ok(#(ast.ECall(ast.EIdent(mangled), rebuilt), st3))
                None -> Ok(#(ast.ECall(ast.EIdent(f), rebuilt), st3))
              }
            }
          }
        Ok(g) -> {
          let #(resolved, st3) = instantiate(st2, env, f, g, rebuilt)
          case resolved {
            Some(mangled) -> Ok(#(ast.ECall(ast.EIdent(mangled), rebuilt), st3))
            // Left alone for a later round, once whatever this call's arguments
            // depend on has been instantiated.
            None -> Ok(#(ast.ECall(ast.EIdent(f), rebuilt), st3))
          }
        }
      }
    }
    // `Box.Full(x)` — a variant of a generic type.
    ast.ECall(ast.EMember(ast.EIdent(tname), variant), args) -> {
      use #(args2, st2) <- result.try(
        walk_exprs(st, env, list.map(args, fn(a) { a.value })),
      )
      let rebuilt = list.map2(args, args2, fn(a, v) { ast.Arg(a.name, v) })
      case dict.get(st2.generic_types, tname) {
        Error(_) ->
          Ok(#(ast.ECall(ast.EMember(ast.EIdent(tname), variant), rebuilt), st2))
        Ok(g) -> {
          let #(resolved, st3) =
            infer_type_args(
              st2,
              env,
              tname,
              g,
              variant_of(g.decl, Some(variant)),
              rebuilt,
            )
          case resolved {
            Some(mangled) ->
              Ok(#(
                ast.ECall(ast.EMember(ast.EIdent(mangled), variant), rebuilt),
                st3,
              ))
            None ->
              Ok(#(
                ast.ECall(ast.EMember(ast.EIdent(tname), variant), rebuilt),
                st3,
              ))
          }
        }
      }
    }
    ast.ECall(callee, args) -> {
      use #(c2, st2) <- result.try(walk_expr(st, env, callee))
      use #(args2, st3) <- result.try(
        walk_exprs(st2, env, list.map(args, fn(a) { a.value })),
      )
      Ok(#(
        ast.ECall(c2, list.map2(args, args2, fn(a, v) { ast.Arg(a.name, v) })),
        st3,
      ))
    }
    // A generic callable has no single concrete type, so there is nothing for a
    // function value to be.
    ast.EIdent(name) ->
      case dict.has_key(st.generics, name) {
        False -> Ok(#(e, st))
        True ->
          Error(
            "`"
            <> name
            <> "` is generic, so it cannot be used as a value: which version "
            <> "of it a call reaches is decided by the argument types, and a "
            <> "value carries none. Call it directly, or give its parameters "
            <> "concrete types.",
          )
      }
    ast.EMember(target, field) -> {
      use #(t2, st2) <- result.try(walk_expr(st, env, target))
      Ok(#(ast.EMember(t2, field), st2))
    }
    ast.EIndex(target, index) -> {
      use #(t2, st2) <- result.try(walk_expr(st, env, target))
      use #(i2, st3) <- result.try(walk_expr(st2, env, index))
      Ok(#(ast.EIndex(t2, i2), st3))
    }
    ast.ESlice(target, low, high) -> {
      use #(t2, st2) <- result.try(walk_expr(st, env, target))
      use #(l2, st3) <- result.try(walk_opt(st2, env, low))
      use #(h2, st4) <- result.try(walk_opt(st3, env, high))
      Ok(#(ast.ESlice(t2, l2, h2), st4))
    }
    ast.EBinary(op, l, r) -> {
      use #(l2, st2) <- result.try(walk_expr(st, env, l))
      use #(r2, st3) <- result.try(walk_expr(st2, env, r))
      Ok(#(ast.EBinary(op, l2, r2), st3))
    }
    ast.EVector(items) -> {
      use #(items2, st2) <- result.try(walk_exprs(st, env, items))
      Ok(#(ast.EVector(items2), st2))
    }
    ast.EInterp(parts) -> {
      use #(parts2, st2) <- result.try(walk_parts(st, env, parts))
      Ok(#(ast.EInterp(parts2), st2))
    }
    ast.EIs(subject, pattern) -> {
      use #(s2, st2) <- result.try(walk_expr(st, env, subject))
      // A pattern names its type (`x is Box.Full(v)`), so once the subject has
      // become a concrete instantiation the pattern has to follow it.
      let pattern2 = case pattern {
        ast.PConstructor([tname, variant], binds) ->
          case dict.has_key(st2.generic_types, tname), codegen.infer(env, s2) {
            True, codegen.TyCustom(actual) ->
              case string.starts_with(actual, tname <> "_") {
                True -> ast.PConstructor([actual, variant], binds)
                False -> pattern
              }
            _, _ -> pattern
          }
        _ -> pattern
      }
      Ok(#(ast.EIs(s2, pattern2), st2))
    }
    ast.EWith(value, typ) -> {
      let #(typ, st) = rewrite_type(st, typ)
      use #(v2, st2) <- result.try(walk_expr(st, env, value))
      Ok(#(ast.EWith(v2, typ), st2))
    }
    ast.EAwait(value, timeout) -> {
      use #(v2, st2) <- result.try(walk_expr(st, env, value))
      use #(t2, st3) <- result.try(walk_opt(st2, env, timeout))
      Ok(#(ast.EAwait(v2, t2), st3))
    }
    ast.EUsing(source, kind) -> {
      use #(s2, st2) <- result.try(walk_expr(st, env, source))
      case kind {
        ast.UsingQuery(q) -> {
          use #(q2, st3) <- result.try(walk_expr(st2, env, q))
          Ok(#(ast.EUsing(s2, ast.UsingQuery(q2)), st3))
        }
        ast.UsingCsv(Some(sep)) -> {
          use #(sep2, st3) <- result.try(walk_expr(st2, env, sep))
          Ok(#(ast.EUsing(s2, ast.UsingCsv(Some(sep2))), st3))
        }
        ast.UsingRaw(text) -> {
          use #(t2, st3) <- result.try(walk_expr(st2, env, text))
          Ok(#(ast.EUsing(s2, ast.UsingRaw(t2)), st3))
        }
        _ -> Ok(#(ast.EUsing(s2, kind), st2))
      }
    }
    ast.EInt(_)
    | ast.EFloat(_)
    | ast.EString(_)
    | ast.EBool(_)
    | ast.EAtom(_) -> Ok(#(e, st))
  }
}

fn walk_opt(
  st: State,
  env: codegen.Env,
  e: Option(ast.Expr),
) -> Result(#(Option(ast.Expr), State), String) {
  case e {
    None -> Ok(#(None, st))
    Some(inner) -> {
      use #(i2, st2) <- result.try(walk_expr(st, env, inner))
      Ok(#(Some(i2), st2))
    }
  }
}

// ---------------------------------------------------------------------------
// Instantiating one call
// ---------------------------------------------------------------------------

fn instantiate(
  st: State,
  env: codegen.Env,
  name: String,
  g: Generic,
  args: List(ast.Arg),
) -> #(Option(String), State) {
  let params = decl_params(g.decl)
  let types = codegen.env_types(env)
  // Pair each argument with the parameter it fills, honouring named arguments.
  let #(assigned, _) =
    codegen.assign_args(args, list.map(params, fn(p) { p.name }))
  let subst =
    list.fold(assigned, dict.new(), fn(acc, pair) {
      let #(pname, value) = pair
      case list.find(params, fn(p) { p.name == pname }) {
        Ok(p) ->
          unify(
            codegen.ty_of_type_expr(types, p.typ),
            codegen.infer(env, value),
            acc,
          )
        Error(_) -> acc
      }
    })

  // Every variable has to be pinned down by an argument; one that only appears
  // in the return has nothing to be inferred from.
  let resolved =
    list.try_map(g.vars, fn(v) {
      case dict.get(subst, v) {
        Error(_) ->
          Error(
            "cannot tell what `"
            <> v
            <> "` is in this call to `"
            <> name
            <> "`: no argument pins it down. A type variable has to appear in "
            <> "a parameter, since that is the only place a call says what it "
            <> "should be.",
          )
        Ok(ty) ->
          case spell(ty) {
            Some(t) -> Ok(#(v, ty, t))
            None ->
              Error(
                "cannot instantiate `"
                <> name
                <> "` with the type this call gives `"
                <> v
                <> "`: it has no name that can be written down.",
              )
          }
      }
    })

  case resolved {
    Error(why) -> #(None, State(..st, deferred: [why, ..st.deferred]))
    Ok(spelled) -> {
      let mangled =
        name
        <> "_"
        <> string.join(list.map(spelled, fn(s) { mangle(s.1) }), "_")
      case dict.has_key(st.wanted, mangled) {
        True -> #(Some(mangled), st)
        False -> {
          let table =
            list.fold(spelled, dict.new(), fn(acc, s) {
              dict.insert(acc, s.0, s.2)
            })
          let decl = specialize(g.decl, mangled, table)
          #(
            Some(mangled),
            State(..st, wanted: dict.insert(st.wanted, mangled, Inst(decl))),
          )
        }
      }
    }
  }
}

// A construction whose type the context already knows is pointed straight at
// that instantiation, rather than having its type arguments guessed from the
// values. It is the only way a variant that mentions some of the variables can
// be built at all: `Either.Left("x")` says what `A` is and nothing about `B`,
// but `Either<Str, Int> a = ...` says both.
//
// `typ` has already been rewritten, so a generic reference in it is now the
// mangled name of a real declaration.
fn retarget(st: State, typ: ast.TypeExpr, value: ast.Expr) -> ast.Expr {
  case typ, value {
    ast.TName(None, mangled, _, []), ast.ECall(ast.EIdent(head), args) ->
      case is_instantiation_of(st, mangled, head) {
        True -> ast.ECall(ast.EIdent(mangled), args)
        False -> value
      }
    ast.TName(None, mangled, _, []),
      ast.ECall(ast.EMember(ast.EIdent(head), variant), args)
    ->
      case is_instantiation_of(st, mangled, head) {
        True ->
          ast.ECall(ast.EMember(ast.EIdent(mangled), variant), args)
        False -> value
      }
    _, _ -> value
  }
}

fn is_instantiation_of(st: State, mangled: String, head: String) -> Bool {
  dict.has_key(st.generic_types, head)
  && string.starts_with(mangled, head <> "_")
}

// The fields a constructor fills: a variant's own then the type's common ones,
// which is the positional order a constructor takes.
fn variant_of(d: ast.Decl, variant: Option(String)) -> List(ast.Field) {
  case d {
    ast.TypeDecl(_, variants, commons) ->
      case variant, variants {
        Some(v), _ ->
          case list.find(variants, fn(x) { x.name == v }) {
            Ok(found) -> list.append(found.fields, commons)
            Error(_) -> commons
          }
        None, [first, ..] -> list.append(first.fields, commons)
        None, [] -> commons
      }
    _ -> []
  }
}

// The type arguments a construction implies, read off the values filling its
// fields — the same unification a generic call uses, against fields instead of
// parameters.
fn infer_type_args(
  st: State,
  env: codegen.Env,
  name: String,
  g: Generic,
  fields: List(ast.Field),
  args: List(ast.Arg),
) -> #(Option(String), State) {
  let types = codegen.env_types(env)
  let #(assigned, _) =
    codegen.assign_args(args, list.map(fields, fn(f) { f.name }))
  let subst =
    list.fold(assigned, dict.new(), fn(acc, pair) {
      let #(fname, value) = pair
      case list.find(fields, fn(f) { f.name == fname }) {
        Ok(f) ->
          unify(
            codegen.ty_of_type_expr(types, f.typ),
            codegen.infer(env, value),
            acc,
          )
        Error(_) -> acc
      }
    })
  let resolved =
    list.try_map(g.vars, fn(v) {
      case dict.get(subst, v) {
        Error(_) ->
          Error(
            "cannot tell what `"
            <> v
            <> "` is in this `"
            <> name
            <> "`: no field pins it down. Write the type arguments out, as in "
            <> "a declaration like `"
            <> name
            <> "<Str> x = ...`.",
          )
        Ok(ty) ->
          case spell(ty) {
            Some(t) -> Ok(t)
            None ->
              Error(
                "cannot build a `"
                <> name
                <> "` at the type this gives `"
                <> v
                <> "`: it has no name that can be written down.",
              )
          }
      }
    })
  case resolved {
    Error(why) -> #(None, State(..st, deferred: [why, ..st.deferred]))
    Ok(args2) ->
      case instantiate_type(st, name, g, args2) {
        Ok(#(mangled, st2)) -> #(Some(mangled), st2)
        Error(why) -> #(None, State(..st, deferred: [why, ..st.deferred]))
      }
  }
}

fn decl_params(d: ast.Decl) -> List(ast.Field) {
  case d {
    ast.ProcDecl(_, params, _, _)
    | ast.FuncDecl(_, params, _, _, _)
    | ast.QueryDecl(_, params, _, _) -> params
    ast.TypeDecl(..) -> []
  }
}

// The concrete copy: the same body under a new name, with every variable
// replaced — in the signature, and in the body too. A body writes types down of
// its own (`mut K[dyn] out = []`, `for each x: T in v`, `parse(s) with T`), and
// those name the same variables the signature does, so leaving them alone would
// emit a declaration mentioning a type that does not exist.
fn specialize(
  d: ast.Decl,
  mangled: String,
  subst: Dict(String, ast.TypeExpr),
) -> ast.Decl {
  let sub = fn(f: ast.Field) { ast.Field(f.name, substitute(subst, f.typ)) }
  case d {
    ast.ProcDecl(_, params, ret, body) ->
      ast.ProcDecl(
        mangled,
        list.map(params, sub),
        substitute(subst, ret),
        substitute_stmts(subst, body),
      )
    ast.FuncDecl(_, params, ret, body, async) ->
      ast.FuncDecl(
        mangled,
        list.map(params, sub),
        substitute(subst, ret),
        substitute_stmts(subst, body),
        async,
      )
    ast.QueryDecl(_, params, ret, sql) ->
      ast.QueryDecl(
        mangled,
        list.map(params, sub),
        substitute(subst, ret),
        substitute_sql(subst, sql),
      )
    ast.TypeDecl(..) -> d
  }
}

// ---------------------------------------------------------------------------
// Substituting through a body
// ---------------------------------------------------------------------------
// Three places in a body write a type down — a typed declaration, a `for each`
// element annotation, and a `with` decode target. Everything else here is the
// traversal that reaches them.

fn substitute_stmts(
  subst: Dict(String, ast.TypeExpr),
  stmts: List(ast.Stmt),
) -> List(ast.Stmt) {
  list.map(stmts, substitute_stmt(subst, _))
}

fn substitute_stmt(
  subst: Dict(String, ast.TypeExpr),
  s: ast.Stmt,
) -> ast.Stmt {
  case s {
    ast.SVarDecl(name, value, mutable) ->
      ast.SVarDecl(name, substitute_expr(subst, value), mutable)
    ast.STypedDecl(typ, name, value, mutable) ->
      ast.STypedDecl(
        substitute(subst, typ),
        name,
        substitute_expr(subst, value),
        mutable,
      )
    ast.SAssign(target, value) ->
      ast.SAssign(
        substitute_expr(subst, target),
        substitute_expr(subst, value),
      )
    ast.SIf(branches, else_body) ->
      ast.SIf(
        list.map(branches, fn(b) {
          ast.Branch(
            substitute_expr(subst, b.cond),
            substitute_stmts(subst, b.body),
          )
        }),
        option.map(else_body, substitute_stmts(subst, _)),
      )
    ast.SFor(init, cond, post, body) ->
      ast.SFor(
        option.map(init, substitute_stmt(subst, _)),
        option.map(cond, substitute_expr(subst, _)),
        option.map(post, substitute_stmt(subst, _)),
        substitute_stmts(subst, body),
      )
    ast.SForEach(name, elem_type, iterable, body) ->
      ast.SForEach(
        name,
        option.map(elem_type, substitute(subst, _)),
        substitute_expr(subst, iterable),
        substitute_stmts(subst, body),
      )
    ast.SReturn(value) ->
      ast.SReturn(option.map(value, substitute_expr(subst, _)))
    ast.SEcho(e) -> ast.SEcho(substitute_expr(subst, e))
    ast.SAssert(e) -> ast.SAssert(substitute_expr(subst, e))
    ast.SPanic(e) -> ast.SPanic(substitute_expr(subst, e))
    ast.SExpr(e) -> ast.SExpr(substitute_expr(subst, e))
    ast.SBreak | ast.SContinue -> s
  }
}

fn substitute_expr(
  subst: Dict(String, ast.TypeExpr),
  e: ast.Expr,
) -> ast.Expr {
  case e {
    ast.EWith(value, typ) ->
      ast.EWith(substitute_expr(subst, value), substitute(subst, typ))
    ast.EVector(items) ->
      ast.EVector(list.map(items, substitute_expr(subst, _)))
    ast.EInterp(parts) ->
      ast.EInterp(
        list.map(parts, fn(part) {
          case part {
            ast.ILit(_) -> part
            ast.IExpr(inner) -> ast.IExpr(substitute_expr(subst, inner))
          }
        }),
      )
    ast.EMember(target, field) ->
      ast.EMember(substitute_expr(subst, target), field)
    ast.ECall(callee, args) ->
      ast.ECall(
        substitute_expr(subst, callee),
        list.map(args, fn(a) { ast.Arg(a.name, substitute_expr(subst, a.value)) }),
      )
    ast.EIndex(target, index) ->
      ast.EIndex(
        substitute_expr(subst, target),
        substitute_expr(subst, index),
      )
    ast.ESlice(target, low, high) ->
      ast.ESlice(
        substitute_expr(subst, target),
        option.map(low, substitute_expr(subst, _)),
        option.map(high, substitute_expr(subst, _)),
      )
    ast.EBinary(op, l, r) ->
      ast.EBinary(op, substitute_expr(subst, l), substitute_expr(subst, r))
    ast.EIs(subject, pattern) ->
      ast.EIs(substitute_expr(subst, subject), pattern)
    ast.EUsing(source, kind) ->
      ast.EUsing(substitute_expr(subst, source), case kind {
        ast.UsingCsv(sep) ->
          ast.UsingCsv(option.map(sep, substitute_expr(subst, _)))
        ast.UsingQuery(q) -> ast.UsingQuery(substitute_expr(subst, q))
        ast.UsingRaw(text) -> ast.UsingRaw(substitute_expr(subst, text))
        ast.UsingXlsx | ast.UsingOds -> kind
      })
    ast.EAwait(value, timeout) ->
      ast.EAwait(
        substitute_expr(subst, value),
        option.map(timeout, substitute_expr(subst, _)),
      )
    ast.EInt(_)
    | ast.EFloat(_)
    | ast.EString(_)
    | ast.EBool(_)
    | ast.EAtom(_)
    | ast.EIdent(_) -> e
  }
}

fn substitute_sql(
  subst: Dict(String, ast.TypeExpr),
  parts: List(ast.SqlPart),
) -> List(ast.SqlPart) {
  list.map(parts, fn(part) {
    case part {
      ast.SqlLit(_) -> part
      ast.SqlParam(e) -> ast.SqlParam(substitute_expr(subst, e))
      ast.SqlWhere(group) -> ast.SqlWhere(substitute_group(subst, group))
    }
  })
}

fn substitute_group(
  subst: Dict(String, ast.TypeExpr),
  group: ast.SqlGroup,
) -> ast.SqlGroup {
  ast.SqlGroup(
    group.conjunction,
    list.map(group.items, fn(item) {
      case item {
        ast.SqlCond(cond, body) ->
          ast.SqlCond(
            substitute_expr(subst, cond),
            substitute_sql(subst, body),
          )
        ast.SqlNested(inner) -> ast.SqlNested(substitute_group(subst, inner))
      }
    }),
  )
}
