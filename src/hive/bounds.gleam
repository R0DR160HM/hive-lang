//// Flow-sensitive vector bounds analysis.
////
//// This pass runs after the main validation pass and before codegen. It
//// proves — at compile time — that every vector index (`v[i]`) and slice
//// (`v[a:b]`) is in range, so the generated Go can never panic with an
//// out-of-bounds error. Anything it cannot prove safe is a compile error.
////
//// It is also where a declared length is *enforced*: a `Str[3]` slot only ever
//// accepts a vector of three, which is what makes the declaration worth
//// trusting when an index into it is decided.
////
//// The rules mirror the language spec:
////   * On a static vector (`Str[3]`) indexed by an integer literal, the check
////     is decided outright: `v[2]` compiles, `v[3]` does not.
////   * On any vector of unknown length, an index must be guarded so the
////     compiler can see it is in range: `if i < len(v) { v[i] }`.
////   * A variable index must additionally be proven `>= 0`
////     (`if i >= 0 && i < len(v) { v[i] }`). Integer literals are always `>= 0`
////     (the lexer never produces a negative literal), so a literal index only
////     needs the upper bound.
////   * An index that came out of `indexOf` needs no guard at all: an `Ok`
////     payload is by construction a position the searched vector has, so
////     narrowing the result (`if r is Result.Ok(i)`) proves both bounds for
////     `i` — on that vector, and only until the vector is rebound.
////   * What is *inferred* about a vector survives writes through it
////     (`v[i] = x` keeps the length; `append(v, x)` only grows it) but not a
////     replacement of the binding (`v = ...`), which may make it shorter —
////     including one in a branch or loop body that may never run.
////   * A *declared* length is instead enforced everywhere a value can reach
////     the slot — initialiser, assignment, argument, return — so it holds for
////     the life of the program and survives a reassignment.
////
//// The analysis is deliberately *sound, not complete*: it never lets a real
//// out-of-bounds access through, but it will reject safe programs whose safety
//// it cannot see (a computed index, an unusual guard shape). The escape is to
//// bind the index to a variable and guard it, or iterate with `for each`,
//// which never indexes.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import hive/ast
import hive/codegen

// ---------------------------------------------------------------------------
// Length classes and facts
// ---------------------------------------------------------------------------

/// What we know about the length of a vector at a program point.
type Len {
  /// A statically-known length: `Str[3]` -> `Static(3)`, `["a", "b"]` ->
  /// `Static(2)`.
  Static(Int)
  /// A length that isn't known at compile time (`Str[dyn]`, a slice, a value
  /// returned from a call, an `is`-binding, ...). Access must be guarded.
  Dyn
}

/// How a local's length is recorded. `FromType` keeps the full declared type
/// so nested indexing (`table[i][j]`) can peel one vector dimension at a time;
/// `LitLen` remembers only the outer length of a vector literal.
type LenInfo {
  FromType(ast.TypeExpr)
  LitLen(Int)
}

/// A fact proven true at the current program point. Operands are normalized
/// keys (see `key`): a variable name (`"i"`), an integer literal (`"#3"`), or a
/// one-level member access (`"req.body"`).
type Fact {
  /// `idx < len(vec)`
  LtLen(idx: String, vec: String)
  /// `idx <= len(vec)`
  LeLen(idx: String, vec: String)
  /// `idx < bound` (a compile-time constant upper bound)
  LtConst(idx: String, bound: Int)
  /// `idx >= 0`
  Ge0(idx: String)
  /// `a <= b` between two index expressions
  LeVar(a: String, b: String)
}

/// What a callable declared about itself, so a call site can be held to its
/// parameter lengths and a call's value can be given its return type.
type Sig {
  Sig(params: List(ast.Field), ret: ast.TypeExpr, async: Bool)
}

type Env {
  Env(
    /// Every declared type, so member/field lengths and custom types resolve.
    types: Dict(String, ast.Decl),
    /// Every callable's signature, by name.
    fns: Dict(String, Sig),
    /// The callable being checked: its name (for error text) and the return
    /// type every `return` in the body has to fit.
    owner: String,
    ret: ast.TypeExpr,
    /// Names the body binds locally. A call through one of them reaches a
    /// value, not the module-level declaration it shadows, so that
    /// declaration's parameter lengths say nothing about it.
    shadowed: List(String),
    /// Length knowledge for the locals currently in scope.
    lengths: Dict(String, LenInfo),
    /// `n := len(v)` records `n -> v` here, so `i < n` proves `i < len(v)`.
    aliases: Dict(String, String),
    /// `r := indexOf(v, x)` records `r -> v` here, so narrowing `r` with
    /// `is Result.Ok(i)` proves `0 <= i < len(v)`.
    searches: Dict(String, String),
    /// The facts proven to hold at this point.
    facts: List(Fact),
  )
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn check(module: ast.Module) -> Result(Nil, String) {
  let types =
    list.fold(module.decls, dict.new(), fn(acc, d) {
      case d {
        ast.TypeDecl(name, _, _) -> dict.insert(acc, name, d)
        _ -> acc
      }
    })
  let fns = signatures(module.decls)
  list.try_fold(module.decls, Nil, fn(_, d) {
    case d {
      ast.ProcDecl(name, params, ret, body)
      | ast.FuncDecl(name, params, ret, body, _) ->
        check_body(types, fns, name, params, ret, body)
      // A query's body is SQL; its interpolations can't index a vector, and
      // the main validation pass already walks them.
      ast.QueryDecl(..) | ast.TypeDecl(..) -> Ok(Nil)
    }
  })
  |> result.map(fn(_) { Nil })
}

fn signatures(decls: List(ast.Decl)) -> Dict(String, Sig) {
  list.fold(decls, dict.new(), fn(acc, d) {
    case d {
      ast.ProcDecl(name, params, ret, _) | ast.QueryDecl(name, params, ret, _) ->
        dict.insert(acc, name, Sig(params, ret, False))
      ast.FuncDecl(name, params, ret, _, async) ->
        dict.insert(acc, name, Sig(params, ret, async))
      ast.TypeDecl(..) -> acc
    }
  })
}

fn check_body(
  types: Dict(String, ast.Decl),
  fns: Dict(String, Sig),
  name: String,
  params: List(ast.Field),
  ret: ast.TypeExpr,
  body: List(ast.Stmt),
) -> Result(Nil, String) {
  let lengths =
    list.fold(params, dict.new(), fn(acc, p) {
      dict.insert(acc, p.name, FromType(p.typ))
    })
  let env =
    Env(
      types,
      fns,
      name,
      ret,
      declared_names(body),
      lengths,
      dict.new(),
      dict.new(),
      [],
    )
  check_stmts(env, body) |> result.map(fn(_) { Nil })
}

// Every name the body binds, anywhere in it — a declaration, a loop variable,
// an `is` binding in a guard.
fn declared_names(stmts: List(ast.Stmt)) -> List(String) {
  list.flat_map(stmts, fn(s) {
    case s {
      ast.SVarDecl(name, _, _) | ast.STypedDecl(_, name, _, _) -> [name]
      ast.SForEach(name, _, _, body) -> [name, ..declared_names(body)]
      ast.SFor(init, cond, post, body) ->
        list.flatten([
          declared_names(option.values([init, post])),
          is_bindings(option.unwrap(cond, ast.EBool(True))),
          declared_names(body),
        ])
      ast.SIf(branches, else_body) ->
        list.flatten([
          list.flat_map(branches, fn(b) {
            list.append(is_bindings(b.cond), declared_names(b.body))
          }),
          declared_names(option.unwrap(else_body, [])),
        ])
      _ -> []
    }
  })
}

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

fn check_stmts(env: Env, stmts: List(ast.Stmt)) -> Result(Env, String) {
  case stmts {
    [] -> Ok(env)
    [s, ..rest] -> {
      use env2 <- result.try(check_stmt(env, s))
      check_stmts(env2, rest)
    }
  }
}

fn check_stmt(env: Env, s: ast.Stmt) -> Result(Env, String) {
  case s {
    ast.SVarDecl(name, value, _) -> {
      use _ <- result.try(check_expr(env, value))
      Ok(record_binding(forget(env, [name]), name, value))
    }
    ast.STypedDecl(typ, name, value, _) -> {
      use _ <- result.try(check_expr(env, value))
      use _ <- result.try(check_fits(env, typ, value, "`" <> name <> "`"))
      let env2 = forget(env, [name])
      Ok(Env(..env2, lengths: dict.insert(env2.lengths, name, FromType(typ))))
    }
    ast.SAssign(target, value) -> {
      // A `v[i] = x` lvalue indexes `v`, so it must be proven in range too.
      use _ <- result.try(check_lvalue(env, target))
      use _ <- result.try(check_expr(env, value))
      // Whatever the target was declared to hold, it still has to hold.
      use _ <- result.try(case type_of(env, target) {
        Some(t) -> check_fits(env, t, value, slot_of(target))
        None -> Ok(Nil)
      })
      // Reassigning the whole variable changes its length; assigning an
      // element (`v[i] = x`) does not. A declared type is not up for revision,
      // and every assignment to it has just been checked against it, so it
      // outlives the rebinding.
      case target {
        ast.EIdent(n) -> {
          let declared = case dict.get(env.lengths, n) {
            Ok(FromType(t)) -> Some(t)
            _ -> None
          }
          let env2 = record_binding(forget(env, [n]), n, value)
          Ok(case declared {
            Some(t) ->
              Env(..env2, lengths: dict.insert(env2.lengths, n, FromType(t)))
            None -> env2
          })
        }
        _ -> Ok(env)
      }
    }
    ast.SReturn(None) -> Ok(env)
    ast.SReturn(Some(e)) -> {
      use _ <- result.try(check_expr(env, e))
      use _ <- result.try(check_fits(
        env,
        env.ret,
        e,
        "the return of `" <> env.owner <> "`",
      ))
      Ok(env)
    }
    ast.SEcho(e) | ast.SAssert(e) | ast.SPanic(e) -> {
      use _ <- result.try(check_expr(env, e))
      Ok(env)
    }
    ast.SExpr(e) -> {
      // `append(v, x)` only ever grows `v`, so any `i < len(v)` fact stays
      // true afterwards — nothing to forget.
      use _ <- result.try(check_expr(env, e))
      Ok(env)
    }
    // `break`/`continue` transfer control out of the current position; they
    // touch no vectors and prove no facts of their own.
    ast.SBreak | ast.SContinue -> Ok(env)
    ast.SIf(branches, else_body) -> check_if(env, branches, else_body)
    ast.SFor(init, cond, post, body) ->
      check_for(env, init, cond, post, body)
    ast.SForEach(name, _, iterable, body) -> {
      use _ <- result.try(check_expr(env, iterable))
      // The element binding is fresh; nothing is known about its length.
      let inner = forget(Env(..env, lengths: dict.delete(env.lengths, name)), [
        name,
      ])
      use _ <- result.try(check_stmts(inner, body))
      Ok(forget_writes(env, body))
    }
  }
}

fn check_if(
  env: Env,
  branches: List(ast.Branch),
  else_body: Option(List(ast.Stmt)),
) -> Result(Env, String) {
  use _ <- result.try(
    list.try_fold(branches, Nil, fn(_, b) {
      use _ <- result.try(check_expr(env, b.cond))
      let benv = narrow(env, b.cond, facts_from(env, b.cond))
      use _ <- result.try(check_stmts(benv, b.body))
      Ok(Nil)
    })
    |> result.map(fn(_) { Nil }),
  )
  use _ <- result.try(case else_body {
    Some(body) -> check_stmts(env, body) |> result.map(fn(_) { Nil })
    None -> Ok(Nil)
  })

  // What a branch may have done to a variable is not reliable in the
  // fall-through, whichever branch ran.
  let taken =
    list.append(
      list.flat_map(branches, fn(b) { b.body }),
      option.unwrap(else_body, []),
    )
  let cont = forget_writes(env, taken)

  // Guard-clause: `if <cond> { return }` (a single branch, no else, that
  // definitely leaves the function) proves `not cond` for everything after it.
  case branches, else_body {
    [b], None ->
      case diverges(b.body) {
        True ->
          Ok(Env(
            ..cont,
            facts: list.append(facts_from_neg(env, b.cond), cont.facts),
          ))
        False -> Ok(cont)
      }
    _, _ -> Ok(cont)
  }
}

fn check_for(
  env: Env,
  init: Option(ast.Stmt),
  cond: Option(ast.Expr),
  post: Option(ast.Stmt),
  body: List(ast.Stmt),
) -> Result(Env, String) {
  // The init clause introduces the loop counter, scoped to the loop.
  use ienv <- result.try(case init {
    Some(s) -> check_stmt(env, s)
    None -> Ok(env)
  })
  use _ <- result.try(case cond {
    Some(e) -> check_expr(ienv, e)
    None -> Ok(Nil)
  })
  use _ <- result.try(case post {
    Some(s) -> check_stmt(ienv, s) |> result.map(fn(_) { Nil })
    None -> Ok(Nil)
  })

  // The condition is re-checked every iteration, so its facts hold at the top
  // of the body. A counter started at a non-negative literal and only ever
  // incremented (or left alone) stays `>= 0`, which lets the idiomatic
  // `for i := 0; i < len(v); i = i + 1 { v[i] }` prove `i >= 0` for free.
  let cond_facts = case cond {
    Some(e) -> facts_from(ienv, e)
    None -> []
  }
  let ge0 = counter_ge0(init, post, body)
  let benv =
    Env(..ienv, facts: list.flatten([ge0, cond_facts, ienv.facts]))
  use _ <- result.try(check_stmts(benv, body))

  // The loop may run zero times and its counter is out of scope afterwards, so
  // nothing it establishes survives; drop what it wrote to.
  Ok(forget_writes(env, list.append(body, option.values([post]))))
}

// Whether the loop counter can be shown to stay `>= 0`: it is initialised to a
// non-negative literal, the body never reassigns it, and the post step only
// increments it (or is absent).
fn counter_ge0(
  init: Option(ast.Stmt),
  post: Option(ast.Stmt),
  body: List(ast.Stmt),
) -> List(Fact) {
  case init {
    Some(ast.SVarDecl(name, ast.EInt(_), _))
    | Some(ast.STypedDecl(_, name, ast.EInt(_), _)) ->
      case list.contains(mutated_in(body), name), post_keeps_nonneg(post, name) {
        False, True -> [Ge0(name)]
        _, _ -> []
      }
    _ -> []
  }
}

fn post_keeps_nonneg(post: Option(ast.Stmt), name: String) -> Bool {
  case post {
    None -> True
    // `i = i + k` / `i = k + i` with a non-negative literal `k`.
    Some(ast.SAssign(ast.EIdent(n), ast.EBinary(ast.OpAdd, l, r))) if n == name ->
      case l, r {
        ast.EIdent(m), ast.EInt(_) -> m == name
        ast.EInt(_), ast.EIdent(m) -> m == name
        _, _ -> False
      }
    // A post step that touches a different variable is fine.
    Some(ast.SAssign(ast.EIdent(n), _)) -> n != name
    Some(_) -> False
  }
}

// ---------------------------------------------------------------------------
// Expressions — walk every sub-expression, checking each index/slice site
// ---------------------------------------------------------------------------

fn check_expr(env: Env, e: ast.Expr) -> Result(Nil, String) {
  case e {
    ast.EIndex(target, idx) -> {
      use _ <- result.try(check_expr(env, target))
      use _ <- result.try(check_expr(env, idx))
      check_index(env, target, idx)
    }
    ast.ESlice(target, low, high) -> {
      use _ <- result.try(check_expr(env, target))
      use _ <- result.try(check_exprs(env, option.values([low, high])))
      check_slice(env, target, low, high)
    }
    // `&&` short-circuits, so the right operand is evaluated only when the left
    // is true: its facts hold while checking the right. `||` is the mirror —
    // the right runs only when the left is false.
    ast.EBinary(ast.OpAnd, l, r) -> {
      use _ <- result.try(check_expr(env, l))
      check_expr(narrow(env, l, facts_from(env, l)), r)
    }
    ast.EBinary(ast.OpOr, l, r) -> {
      use _ <- result.try(check_expr(env, l))
      check_expr(narrow(env, l, facts_from_neg(env, l)), r)
    }
    ast.EBinary(_, l, r) -> check_exprs(env, [l, r])
    ast.ECall(callee, args) -> {
      use _ <- result.try(
        check_exprs(env, [callee, ..list.map(args, fn(a) { a.value })]),
      )
      check_arg_lengths(env, callee, args)
    }
    ast.EMember(target, _) -> check_expr(env, target)
    ast.EInterp(parts) ->
      list.try_fold(parts, Nil, fn(_, p) {
        case p {
          ast.ILit(_) -> Ok(Nil)
          ast.IExpr(inner) -> check_expr(env, inner)
        }
      })
      |> result.map(fn(_) { Nil })
    ast.EVector(items) -> check_exprs(env, items)
    ast.EIs(subject, _) -> check_expr(env, subject)
    ast.EUsing(source, kind) ->
      check_exprs(env, [source, ..ast.using_exprs(kind)])
    ast.EWith(value, _) -> check_expr(env, value)
    ast.EAwait(value) -> check_expr(env, value)
    ast.EInt(_)
    | ast.EFloat(_)
    | ast.EString(_)
    | ast.EBool(_)
    | ast.EAtom(_)
    | ast.EIdent(_) -> Ok(Nil)
  }
}

fn check_exprs(env: Env, exprs: List(ast.Expr)) -> Result(Nil, String) {
  list.try_fold(exprs, Nil, fn(_, e) { check_expr(env, e) })
  |> result.map(fn(_) { Nil })
}

// A `v[i] = x` lvalue: check the index (and recurse into any nested index in
// the target), but do not treat the assignment itself as an rvalue use.
fn check_lvalue(env: Env, target: ast.Expr) -> Result(Nil, String) {
  case target {
    ast.EIndex(t, idx) -> {
      use _ <- result.try(check_lvalue(env, t))
      use _ <- result.try(check_expr(env, idx))
      check_index(env, t, idx)
    }
    ast.ESlice(t, low, high) -> {
      use _ <- result.try(check_lvalue(env, t))
      use _ <- result.try(check_exprs(env, option.values([low, high])))
      check_slice(env, t, low, high)
    }
    ast.EMember(t, _) -> check_lvalue(env, t)
    _ -> Ok(Nil)
  }
}

// ---------------------------------------------------------------------------
// Declared lengths
// ---------------------------------------------------------------------------

// A static dimension is a promise, not a hint: `Str[3]` means *three*, so every
// value that lands in such a slot — an initialiser, a later assignment, an
// argument, a returned value — must be a vector of exactly that many elements.
// Holding the whole program to it is what lets an index into a `Str[3]` be
// decided outright, and what lets that knowledge survive a reassignment.
fn check_fits(
  env: Env,
  typ: ast.TypeExpr,
  value: ast.Expr,
  slot: String,
) -> Result(Nil, String) {
  case outer_dim(typ) {
    // No declared length: nothing was promised, so nothing to keep.
    Dyn -> Ok(Nil)
    Static(n) ->
      case outer_len(env, value) {
        Static(m) if m == n -> check_elements(env, typ, value, slot)
        Static(m) ->
          Error(
            slot
            <> " is declared `"
            <> show_type(typ)
            <> "`, so it takes a vector of exactly "
            <> int.to_string(n)
            <> " "
            <> plural(n, "element")
            <> " — this one has "
            <> int.to_string(m)
            <> ".",
          )
        Dyn ->
          Error(
            slot
            <> " is declared `"
            <> show_type(typ)
            <> "`, but this value's length isn't known at compile time. Give it "
            <> "a value of the same static length, or declare "
            <> slot
            <> " with `[dyn]` and guard its indexes.",
          )
      }
  }
}

// A vector literal shows its inner lengths too, so `Str[2][3]` checks every row.
fn check_elements(
  env: Env,
  typ: ast.TypeExpr,
  value: ast.Expr,
  slot: String,
) -> Result(Nil, String) {
  case value, drop_dim(typ) {
    ast.EVector(items), Some(inner) ->
      list.try_fold(items, Nil, fn(_, item) {
        check_fits(env, inner, item, "an element of " <> slot)
      })
      |> result.map(fn(_) { Nil })
    _, _ -> Ok(Nil)
  }
}

// Every argument that lands in a parameter with a declared length must have
// that length: the callee's body is checked against its own declarations, so
// the call is where the promise is made. A `_` hole passes nothing, and a name
// that is a local (a function value, say) is not the declaration it shadows.
fn check_arg_lengths(
  env: Env,
  callee: ast.Expr,
  args: List(ast.Arg),
) -> Result(Nil, String) {
  case callee {
    ast.EIdent(f) ->
      case list.contains(env.shadowed, f), dict.get(env.fns, f) {
        False, Ok(Sig(params, _, _)) -> {
          let #(assigned, _) =
            codegen.assign_args(args, list.map(params, fn(p) { p.name }))
          list.try_fold(assigned, Nil, fn(_, pair) {
            let #(pname, value) = pair
            case list.find(params, fn(p) { p.name == pname }), value {
              _, ast.EIdent("_") -> Ok(Nil)
              Ok(p), _ ->
                check_fits(
                  env,
                  p.typ,
                  value,
                  "parameter `" <> pname <> "` of `" <> f <> "`",
                )
              Error(_), _ -> Ok(Nil)
            }
          })
          |> result.map(fn(_) { Nil })
        }
        _, _ -> Ok(Nil)
      }
    _ -> Ok(Nil)
  }
}

// How an assignment target is named in the error text.
fn slot_of(target: ast.Expr) -> String {
  case target {
    ast.EIdent(n) -> "`" <> n <> "`"
    ast.EMember(ast.EIdent(o), f) -> "`" <> o <> "." <> f <> "`"
    ast.EIndex(t, _) -> "an element of " <> slot_of(t)
    _ -> "this slot"
  }
}

fn plural(n: Int, word: String) -> String {
  case n {
    1 -> word
    _ -> word <> "s"
  }
}

fn show_type(t: ast.TypeExpr) -> String {
  case t {
    ast.TVoid -> "void"
    ast.TFunc(_, _, _) -> "a function"
    ast.TName(pkg, name, dims) ->
      case pkg {
        Some(p) -> p <> "."
        None -> ""
      }
      <> name
      <> string.concat(list.map(dims, show_dim))
  }
}

fn show_dim(d: ast.Dim) -> String {
  case d {
    ast.DimEmpty -> "[]"
    ast.DimStatic(n) -> "[" <> int.to_string(n) <> "]"
    ast.DimDyn(None) -> "[dyn]"
    ast.DimDyn(Some(n)) -> "[dyn, " <> int.to_string(n) <> "]"
  }
}

// ---------------------------------------------------------------------------
// The index and slice obligations
// ---------------------------------------------------------------------------

fn check_index(env: Env, target: ast.Expr, idx: ast.Expr) -> Result(Nil, String) {
  let len = outer_len(env, target)
  let vec = key(target)
  case idx {
    // A literal index: always `>= 0`, so only the upper bound remains.
    ast.EInt(k) ->
      case len {
        Static(n) ->
          case k < n {
            True -> Ok(Nil)
            False ->
              Error(
                "index "
                <> int.to_string(k)
                <> " is out of range for a vector of length "
                <> int.to_string(n),
              )
          }
        Dyn ->
          case has_lt_len_lit(env, k, vec) {
            True -> Ok(Nil)
            False -> Error(unproven_literal(k, describe(target)))
          }
      }
    _ ->
      case key(idx) {
        None ->
          Error(
            "cannot prove this index is in range: the index is a computed "
            <> "expression. Bind it to a variable and guard it "
            <> "(`if j >= 0 && j < len(...))`.",
          )
        Some(i) -> {
          let lower = has_ge0(env, i)
          let upper = case len {
            Static(n) -> has_lt_len(env, i, vec) || has_lt_const(env, i, n)
            Dyn -> has_lt_len(env, i, vec)
          }
          case lower, upper {
            True, True -> Ok(Nil)
            False, _ ->
              Error(unproven_ge0(i, describe(target)))
            True, False ->
              Error(unproven_upper(i, describe(target)))
          }
        }
      }
  }
}

fn check_slice(
  env: Env,
  target: ast.Expr,
  low: Option(ast.Expr),
  high: Option(ast.Expr),
) -> Result(Nil, String) {
  let len = outer_len(env, target)
  let vec = key(target)
  // Lower bound: an omitted `low` is 0 (always safe). A present `low` must be
  // `>= 0` and `<= len(v)` (Go permits `low == len`, yielding an empty slice).
  use _ <- result.try(case low {
    None -> Ok(Nil)
    Some(e) ->
      case has_ge0_expr(env, e) && has_le_len(env, e, vec, len) {
        True -> Ok(Nil)
        False ->
          Error(
            "cannot prove the low bound of this slice on `"
            <> describe(target)
            <> "` is in range (needs `low >= 0` and `low <= len(...)`)",
          )
      }
  })
  // Upper bound: an omitted `high` is the last index (always safe). A present
  // `high` is inclusive, so it must be `>= 0` and `< len(v)`.
  use _ <- result.try(case high {
    None -> Ok(Nil)
    Some(e) ->
      case has_ge0_expr(env, e) && has_lt_len_expr(env, e, vec, len) {
        True -> Ok(Nil)
        False ->
          Error(
            "cannot prove the high bound of this slice on `"
            <> describe(target)
            <> "` is in range (needs `high >= 0` and `high < len(...)`)",
          )
      }
  })
  // The two bounds must not cross: `low <= high + 1` (an empty slice is fine).
  case low, high {
    Some(lo), Some(hi) ->
      case le_plus_one(env, lo, hi) {
        True -> Ok(Nil)
        False ->
          Error(
            "cannot prove this slice's bounds don't cross on `"
            <> describe(target)
            <> "` (needs `low <= high + 1`)",
          )
      }
    _, _ -> Ok(Nil)
  }
}

// ---------------------------------------------------------------------------
// Discharging obligations against the fact set
// ---------------------------------------------------------------------------

fn has_ge0(env: Env, i: String) -> Bool {
  list.contains(env.facts, Ge0(i))
}

fn has_ge0_expr(env: Env, e: ast.Expr) -> Bool {
  case e {
    ast.EInt(_) -> True
    _ ->
      case key(e) {
        Some(k) -> has_ge0(env, k)
        None -> False
      }
  }
}

fn has_lt_len(env: Env, i: String, vec: Option(String)) -> Bool {
  case vec {
    Some(v) -> list.contains(env.facts, LtLen(i, v))
    None -> False
  }
}

fn has_lt_const(env: Env, i: String, n: Int) -> Bool {
  // `i < m` with `m <= n` implies `i < n`.
  list.any(env.facts, fn(f) {
    case f {
      LtConst(idx, m) -> idx == i && m <= n
      _ -> False
    }
  })
}

// `i < len(v)` for an expression index, dispatched on the vector's length.
fn has_lt_len_expr(env: Env, e: ast.Expr, vec: Option(String), len: Len) -> Bool {
  case e {
    ast.EInt(k) ->
      case len {
        Static(n) -> k < n
        Dyn -> has_lt_len_lit(env, k, vec)
      }
    _ ->
      case key(e) {
        Some(i) ->
          case len {
            Static(n) -> has_lt_len(env, i, vec) || has_lt_const(env, i, n)
            Dyn -> has_lt_len(env, i, vec)
          }
        None -> False
      }
  }
}

// `i <= len(v)`, which `i < len(v)` and an explicit `i <= len(v)` both satisfy.
fn has_le_len(env: Env, e: ast.Expr, vec: Option(String), len: Len) -> Bool {
  case e {
    ast.EInt(k) ->
      case len {
        Static(n) -> k <= n
        Dyn -> has_le_len_lit(env, k, vec)
      }
    _ ->
      case key(e) {
        Some(i) ->
          case len {
            Static(n) ->
              has_lt_len(env, i, vec)
              || has_le_len_fact(env, i, vec)
              || has_lt_const(env, i, n + 1)
            Dyn -> has_lt_len(env, i, vec) || has_le_len_fact(env, i, vec)
          }
        None -> False
      }
  }
}

fn has_le_len_fact(env: Env, i: String, vec: Option(String)) -> Bool {
  case vec {
    Some(v) -> list.contains(env.facts, LeLen(i, v))
    None -> False
  }
}

// Monotonic reasoning for a *literal* index `k < len(v)`: a proof that some
// larger literal fits carries down. If `m < len(v)` is known and `m >= k`,
// then `k <= m < len(v)`; if `m <= len(v)` is known and `m > k`, then
// `k < m <= len(v)`. So `if 1 < len(v) { ... }` alone proves `v[0]` safe too.
fn has_lt_len_lit(env: Env, k: Int, vec: Option(String)) -> Bool {
  case vec {
    None -> False
    Some(v) ->
      list.any(env.facts, fn(f) {
        case f {
          LtLen(idx, fv) -> fv == v && at_least(idx, k)
          LeLen(idx, fv) -> fv == v && greater_than(idx, k)
          _ -> False
        }
      })
      // A non-empty vector (`len(v) >= 1`, see `len_at_least_one`) makes the
      // literal index 0 safe — and only 0, since that is all `len >= 1` gives.
      || { k == 0 && len_at_least_one(env, vec) }
  }
}

// The same monotonicity for `k <= len(v)` (a slice's low bound): any known
// literal bound `m >= k`, strict or not, implies `k <= len(v)`.
fn has_le_len_lit(env: Env, k: Int, vec: Option(String)) -> Bool {
  case vec {
    None -> False
    Some(v) ->
      list.any(env.facts, fn(f) {
        case f {
          LtLen(idx, fv) | LeLen(idx, fv) -> fv == v && at_least(idx, k)
          _ -> False
        }
      })
      // `len(v) >= 1` discharges `k <= len(v)` for k in {0, 1}.
      || { k <= 1 && len_at_least_one(env, vec) }
  }
}

// A variable index proven both `>= 0` and `< len(v)` witnesses that the vector
// is non-empty: `0 <= j < len(v)` forces `len(v) >= 1`. So inside
// `if i >= 0 && i < len(v) { ... }` the literal index 0 is provably safe, even
// though only `i` was named in the guard.
fn len_at_least_one(env: Env, vec: Option(String)) -> Bool {
  case vec {
    None -> False
    Some(v) ->
      list.any(env.facts, fn(f) {
        case f {
          LtLen(j, fv) -> fv == v && has_ge0(env, j)
          _ -> False
        }
      })
  }
}

// Whether a normalized literal key (`"#3"`) denotes a value `>= k` / `> k`.
fn at_least(idx: String, k: Int) -> Bool {
  case parse_lit(idx) {
    Some(m) -> m >= k
    None -> False
  }
}

fn greater_than(idx: String, k: Int) -> Bool {
  case parse_lit(idx) {
    Some(m) -> m > k
    None -> False
  }
}

fn parse_lit(idx: String) -> Option(Int) {
  case idx {
    "#" <> rest -> int.parse(rest) |> option.from_result
    _ -> None
  }
}

// `low <= high + 1`: decided directly for two literals, otherwise proven from a
// `low <= high` (or `low < high`) fact, or when both bounds are the same term.
fn le_plus_one(env: Env, low: ast.Expr, high: ast.Expr) -> Bool {
  case low, high {
    ast.EInt(a), ast.EInt(b) -> a <= b + 1
    _, _ ->
      case key(low), key(high) {
        Some(a), Some(b) ->
          a == b || list.contains(env.facts, LeVar(a, b))
        _, _ -> False
      }
  }
}

// ---------------------------------------------------------------------------
// Fact extraction from conditions
// ---------------------------------------------------------------------------

// The index-safety facts a condition guarantees when it is TRUE. Only the
// positive, conjunctive part is mined; `||`, `==` and `is` yield nothing.
fn facts_from(env: Env, e: ast.Expr) -> List(Fact) {
  case e {
    ast.EBinary(ast.OpAnd, l, r) ->
      list.append(facts_from(env, l), facts_from(env, r))
    ast.EBinary(ast.OpLt, a, b) -> lt_facts(env, a, b)
    // `a > b` is `b < a`.
    ast.EBinary(ast.OpGt, a, b) -> lt_facts(env, b, a)
    ast.EBinary(ast.OpLe, a, b) -> le_facts(env, a, b)
    // `a >= b` is `b <= a`.
    ast.EBinary(ast.OpGe, a, b) -> le_facts(env, b, a)
    // `r is Result.Ok(i)` where `r` searched a vector with `indexOf`: an Ok
    // payload is a position that vector really has, which is the whole point of
    // returning one — so `i` arrives already proven `>= 0` and `< len(v)` and
    // indexes `v` with no guard of its own.
    ast.EIs(subject, ast.PConstructor(["Result", "Ok"], [i])) ->
      case i != "_", searched_vector(env, subject) {
        True, Some(v) -> [Ge0(i), LtLen(i, v)]
        _, _ -> []
      }
    _ -> []
  }
}

// The facts guaranteed when a condition is FALSE — used for guard clauses
// (`if i >= len(v) { return }` proves `i < len(v)` afterwards). Only single
// comparisons are negated; negating `&&`/`||` would be a disjunction, which
// yields no reliable fact.
fn facts_from_neg(env: Env, e: ast.Expr) -> List(Fact) {
  case e {
    ast.EBinary(ast.OpLt, a, b) -> le_facts(env, b, a)
    ast.EBinary(ast.OpGt, a, b) -> le_facts(env, a, b)
    ast.EBinary(ast.OpLe, a, b) -> lt_facts(env, b, a)
    ast.EBinary(ast.OpGe, a, b) -> lt_facts(env, a, b)
    _ -> []
  }
}

// Facts implied by `a < b`.
fn lt_facts(env: Env, a: ast.Expr, b: ast.Expr) -> List(Fact) {
  let base = case as_len(env, b), key(a) {
    // `a < len(v)`
    Some(v), Some(ia) -> [LtLen(ia, v)]
    // `a < k` (constant upper bound)
    None, Some(ia) ->
      case b {
        ast.EInt(k) -> [LtConst(ia, k)]
        _ -> []
      }
    _, _ -> []
  }
  // `k < b` with a non-negative literal `k` proves `b >= 0`.
  let nonneg = case a, key(b) {
    ast.EInt(_), Some(ib) -> [Ge0(ib)]
    _, _ -> []
  }
  // Two plain index terms give `a <= b`.
  let ordered = case as_len(env, a), as_len(env, b), key(a), key(b) {
    None, None, Some(ia), Some(ib) -> [LeVar(ia, ib)]
    _, _, _, _ -> []
  }
  list.flatten([base, nonneg, ordered])
}

// Facts implied by `a <= b`.
fn le_facts(env: Env, a: ast.Expr, b: ast.Expr) -> List(Fact) {
  let base = case as_len(env, b), key(a) {
    // `a <= len(v)`
    Some(v), Some(ia) -> [LeLen(ia, v)]
    None, Some(ia) ->
      case b {
        // `a <= len(v) - 1`  ==  `a < len(v)`
        ast.EBinary(ast.OpSub, sub_l, ast.EInt(1)) ->
          case as_len(env, sub_l) {
            Some(v) -> [LtLen(ia, v)]
            None -> []
          }
        // `a <= k`  ==  `a < k + 1`
        ast.EInt(k) -> [LtConst(ia, k + 1)]
        _ -> []
      }
    _, _ -> []
  }
  // `k <= b` with a non-negative literal `k` proves `b >= 0`.
  let nonneg = case a, key(b) {
    ast.EInt(_), Some(ib) -> [Ge0(ib)]
    _, _ -> []
  }
  let ordered = case as_len(env, a), as_len(env, b), key(a), key(b) {
    None, None, Some(ia), Some(ib) -> [LeVar(ia, ib)]
    _, _, _, _ -> []
  }
  list.flatten([base, nonneg, ordered])
}

// If `e` denotes `len(v)` — either literally `len(v)` or a variable bound to
// it via `n := len(v)` — return `v`'s normalized key.
fn as_len(env: Env, e: ast.Expr) -> Option(String) {
  case e {
    ast.ECall(ast.EIdent("len"), [ast.Arg(_, v)]) -> key(v)
    ast.EIdent(n) -> dict.get(env.aliases, n) |> option.from_result
    _ -> None
  }
}

// The vector an `indexOf` result searched: the call itself when it is matched
// inline (`if indexOf(v, x) is Result.Ok(i)`), otherwise whatever vector the
// name was bound from (`r := indexOf(v, x)`).
fn searched_vector(env: Env, e: ast.Expr) -> Option(String) {
  case e {
    ast.ECall(ast.EIdent("indexOf"), [ast.Arg(_, v), _]) -> key(v)
    ast.EIdent(n) -> dict.get(env.searches, n) |> option.from_result
    _ -> None
  }
}

// ---------------------------------------------------------------------------
// Length resolution
// ---------------------------------------------------------------------------

// The length governing `expr[i]` — i.e. the size of `expr`'s outermost vector
// dimension. Anything we can't pin down is `Dyn`, which forces a guard (sound).
fn outer_len(env: Env, expr: ast.Expr) -> Len {
  case expr {
    ast.EVector(items) -> Static(list.length(items))
    ast.EIdent(name) ->
      case dict.get(env.lengths, name) {
        Ok(LitLen(n)) -> Static(n)
        Ok(FromType(t)) -> outer_dim(t)
        Error(_) -> Dyn
      }
    ast.EIndex(_, _) | ast.EMember(_, _) | ast.ECall(_, _) ->
      case type_of(env, expr) {
        Some(t) -> outer_dim(t)
        None -> Dyn
      }
    // `a + b` concatenates two vectors, so their lengths add.
    ast.EBinary(ast.OpAdd, l, r) ->
      case outer_len(env, l), outer_len(env, r) {
        Static(a), Static(b) -> Static(a + b)
        _, _ -> Dyn
      }
    // Awaiting a vector of handles resolves to a vector of the same arity, and
    // awaiting one call gives that call's value.
    ast.EAwait(ast.ECall(ast.EIdent(f), _)) ->
      case dict.get(env.fns, f) {
        Ok(Sig(_, ret, _)) -> outer_dim(ret)
        Error(_) -> Dyn
      }
    ast.EAwait(inner) -> outer_len(env, inner)
    // A slice's length is not known statically.
    _ -> Dyn
  }
}

// The best-effort declared type of an expression, used to peel dimensions for
// nested indexing (`table[i][j]`) and to read the type of a struct field.
fn type_of(env: Env, expr: ast.Expr) -> Option(ast.TypeExpr) {
  case expr {
    ast.EIdent(name) ->
      case dict.get(env.lengths, name) {
        Ok(FromType(t)) -> Some(t)
        _ -> None
      }
    ast.EIndex(target, _) ->
      case type_of(env, target) {
        Some(t) -> drop_dim(t)
        None -> None
      }
    ast.EMember(target, field) ->
      case type_of(env, target) {
        Some(ast.TName(None, tname, [])) -> field_type(env, tname, field)
        _ -> None
      }
    // A call's value is its declared return — except for a bare call to an
    // `async func`, which is a handle; only `await` reaches the value.
    ast.ECall(ast.EIdent(f), _) ->
      case dict.get(env.fns, f) {
        Ok(Sig(_, ret, False)) -> Some(ret)
        _ -> None
      }
    _ -> None
  }
}

fn field_type(
  env: Env,
  type_name: String,
  field: String,
) -> Option(ast.TypeExpr) {
  case dict.get(env.types, type_name) {
    Ok(ast.TypeDecl(_, variants, commons)) -> {
      let fields =
        list.append(list.flat_map(variants, fn(v) { v.fields }), commons)
      case list.find(fields, fn(f) { f.name == field }) {
        Ok(f) -> Some(f.typ)
        Error(_) -> None
      }
    }
    _ -> None
  }
}

fn outer_dim(t: ast.TypeExpr) -> Len {
  case t {
    ast.TName(_, _, [dim, ..]) ->
      case dim {
        ast.DimStatic(n) -> Static(n)
        ast.DimDyn(_) | ast.DimEmpty -> Dyn
      }
    _ -> Dyn
  }
}

fn drop_dim(t: ast.TypeExpr) -> Option(ast.TypeExpr) {
  case t {
    ast.TName(pkg, name, [_, ..rest]) -> Some(ast.TName(pkg, name, rest))
    _ -> None
  }
}

// ---------------------------------------------------------------------------
// Bindings, aliases and fact invalidation
// ---------------------------------------------------------------------------

// Record what a `:=` or `=` teaches us about the bound name's length. The name's
// stale facts have already been dropped by the caller.
fn record_binding(env: Env, name: String, value: ast.Expr) -> Env {
  let base =
    Env(
      ..env,
      lengths: dict.delete(env.lengths, name),
      aliases: dict.delete(env.aliases, name),
      searches: dict.delete(env.searches, name),
    )
  case value {
    // A vector literal has a known static length.
    ast.EVector(items) ->
      Env(
        ..base,
        lengths: dict.insert(base.lengths, name, LitLen(list.length(items))),
      )
    // `n := len(v)` — remember that `n` is `len(v)`.
    ast.ECall(ast.EIdent("len"), [ast.Arg(_, v)]) ->
      case key(v) {
        Some(vk) -> Env(..base, aliases: dict.insert(base.aliases, name, vk))
        None -> base
      }
    // `r := indexOf(v, x)` — remember which vector `r` searched, so the index
    // it carries can be recognised as one of `v`'s own positions.
    ast.ECall(ast.EIdent("indexOf"), [ast.Arg(_, v), _]) ->
      case key(v) {
        Some(vk) -> Env(..base, searches: dict.insert(base.searches, name, vk))
        None -> base
      }
    // `a := b` copies whatever length knowledge `b` has (assignment copies) —
    // and, for a search result, which vector it came from.
    ast.EIdent(other) -> {
      let lengths = case dict.get(env.lengths, other) {
        Ok(info) -> dict.insert(base.lengths, name, info)
        Error(_) -> base.lengths
      }
      let searches = case dict.get(env.searches, other) {
        Ok(vk) -> dict.insert(base.searches, name, vk)
        Error(_) -> base.searches
      }
      Env(..base, lengths: lengths, searches: searches)
    }
    // Indexing, member access or a call: the declared type says it all, and it
    // keeps the inner dimensions a bare length would lose.
    ast.EIndex(_, _) | ast.EMember(_, _) | ast.ECall(_, _) ->
      case type_of(env, value) {
        Some(t) ->
          Env(..base, lengths: dict.insert(base.lengths, name, FromType(t)))
        None -> base
      }
    // Anything else keeps whatever outer length its shape reveals — a `+`
    // concatenation, an awaited vector of handles.
    _ ->
      case outer_len(env, value) {
        Static(n) -> Env(..base, lengths: dict.insert(base.lengths, name, LitLen(n)))
        Dyn -> base
      }
  }
}

// Drop every fact and alias that mentions any of `names` — used when those
// variables are reassigned (or shadowed), since their old length facts may no
// longer hold.
fn forget(env: Env, names: List(String)) -> Env {
  case names {
    [] -> env
    _ -> {
      let facts =
        list.filter(env.facts, fn(f) { !fact_mentions(f, names) })
      // A record is dropped when either end is touched: the alias/search itself
      // may have been rebound, or the vector it speaks about may have been.
      Env(
        ..env,
        facts: facts,
        aliases: drop_mentions(env.aliases, names),
        searches: drop_mentions(env.searches, names),
      )
    }
  }
}

// The environment a guarded body — or the right operand of `&&`/`||` — is
// analysed in: whatever the condition binds with `is` shadows the name it had
// before, so that name's old length and facts are dropped before the facts the
// condition proves are added.
fn narrow(env: Env, cond: ast.Expr, facts: List(Fact)) -> Env {
  let shadowed = is_bindings(cond)
  let env2 = case shadowed {
    [] -> env
    _ -> forget(env, shadowed) |> drop_lengths(shadowed)
  }
  Env(..env2, facts: list.append(facts, env2.facts))
}

// Every name an `is` in this condition binds.
fn is_bindings(e: ast.Expr) -> List(String) {
  case e {
    ast.EIs(subject, pattern) ->
      list.append(is_bindings(subject), pattern_bindings(pattern))
    ast.EBinary(_, l, r) -> list.append(is_bindings(l), is_bindings(r))
    _ -> []
  }
}

fn pattern_bindings(p: ast.Pattern) -> List(String) {
  let names = case p {
    ast.PConstructor(_, bindings) -> bindings
    ast.PVector(elems, rest) ->
      list.append(
        list.filter_map(elems, fn(el) {
          case el {
            ast.PElemBind(n) -> Ok(n)
            ast.PElemLit(_) -> Error(Nil)
          }
        }),
        option.values([rest]),
      )
    ast.PString(parts) ->
      list.filter_map(parts, fn(part) {
        case part {
          ast.SPatHole(n) -> Ok(n)
          ast.SPatLit(_) -> Error(Nil)
        }
      })
  }
  // `_` binds nothing, so it shadows nothing.
  list.filter(names, fn(n) { n != "_" })
}

// What survives a block whose control flow the analysis does not follow (an
// `if` seen from the fall-through, a loop that may run any number of times):
// facts about anything it wrote to are dropped, and a vector it rebound also
// loses its length — unless that length was *declared*, since every assignment
// has been held to the declaration.
fn forget_writes(env: Env, stmts: List(ast.Stmt)) -> Env {
  let inferred =
    list.filter(reassigned_in(stmts), fn(n) {
      case dict.get(env.lengths, n) {
        Ok(LitLen(_)) -> True
        _ -> False
      }
    })
  forget(env, mutated_in(stmts)) |> drop_lengths(inferred)
}

fn drop_lengths(env: Env, names: List(String)) -> Env {
  Env(..env, lengths: list.fold(names, env.lengths, dict.delete))
}

fn drop_mentions(
  d: Dict(String, String),
  names: List(String),
) -> Dict(String, String) {
  d
  |> dict.to_list
  |> list.filter(fn(pair) {
    !list.contains(names, pair.0) && !list.contains(names, pair.1)
  })
  |> dict.from_list
}

fn fact_mentions(f: Fact, names: List(String)) -> Bool {
  case f {
    LtLen(a, b) | LeLen(a, b) | LeVar(a, b) ->
      list.contains(names, a) || list.contains(names, b)
    LtConst(a, _) | Ge0(a) -> list.contains(names, a)
  }
}

// The root variables reassigned (`x = ...`, `v[i] = ...`) or grown
// (`append(v, ...)`) anywhere in a statement list, including nested blocks.
fn mutated_in(stmts: List(ast.Stmt)) -> List(String) {
  list.flat_map(stmts, mutated_in_stmt)
}

fn mutated_in_stmt(s: ast.Stmt) -> List(String) {
  case s {
    ast.SAssign(target, _) ->
      case assign_root(target) {
        Some(n) -> [n]
        None -> []
      }
    ast.SExpr(ast.ECall(ast.EIdent("append"), [ast.Arg(_, target), ..])) ->
      case assign_root(target) {
        Some(n) -> [n]
        None -> []
      }
    ast.SIf(branches, else_body) ->
      list.append(
        list.flat_map(branches, fn(b) { mutated_in(b.body) }),
        case else_body {
          Some(body) -> mutated_in(body)
          None -> []
        },
      )
    ast.SFor(init, _, post, body) ->
      list.flatten([
        case init {
          Some(st) -> mutated_in_stmt(st)
          None -> []
        },
        case post {
          Some(st) -> mutated_in_stmt(st)
          None -> []
        },
        mutated_in(body),
      ])
    ast.SForEach(_, _, _, body) -> mutated_in(body)
    _ -> []
  }
}

fn assign_root(target: ast.Expr) -> Option(String) {
  case target {
    ast.EIdent(n) -> Some(n)
    ast.EIndex(t, _) | ast.EMember(t, _) | ast.ESlice(t, _, _) ->
      assign_root(t)
    _ -> None
  }
}

// The variables a block *replaces* wholesale (`v = ...`), as opposed to writes
// that go through the name (`v[i] = x`, `v.f = x`, `append(v, x)`). Only a
// replacement can shorten a vector, so only a replacement costs it its known
// length — an element write leaves the length alone and `append` only grows it,
// which keeps every position the analysis already proved.
fn reassigned_in(stmts: List(ast.Stmt)) -> List(String) {
  list.flat_map(stmts, reassigned_in_stmt)
}

fn reassigned_in_stmt(s: ast.Stmt) -> List(String) {
  case s {
    ast.SAssign(ast.EIdent(n), _) -> [n]
    ast.SIf(branches, else_body) ->
      list.append(
        list.flat_map(branches, fn(b) { reassigned_in(b.body) }),
        reassigned_in(option.unwrap(else_body, [])),
      )
    ast.SFor(init, _, post, body) ->
      list.flatten([
        reassigned_in(option.values([init])),
        reassigned_in(option.values([post])),
        reassigned_in(body),
      ])
    ast.SForEach(_, _, _, body) -> reassigned_in(body)
    _ -> []
  }
}

// Whether a block definitely transfers control away from the fall-through (so
// the negation of a guard holds after it). Conservatively: its last statement
// is a `return`, or a `break`/`continue` that leaves the enclosing loop body.
fn diverges(stmts: List(ast.Stmt)) -> Bool {
  case list.last(stmts) {
    Ok(ast.SReturn(_)) | Ok(ast.SBreak) | Ok(ast.SContinue) | Ok(ast.SPanic(_)) ->
      True
    _ -> False
  }
}

// ---------------------------------------------------------------------------
// Normalized keys and error text
// ---------------------------------------------------------------------------

// A canonical string for the expressions the analysis reasons about: a
// variable, an integer literal (`"#3"`), or a one-level member access
// (`"req.body"`). Anything else has no key, so facts about it can't be formed
// and access to it can't be proven (sound).
fn key(e: ast.Expr) -> Option(String) {
  case e {
    ast.EIdent(n) -> Some(n)
    ast.EInt(k) -> Some("#" <> int.to_string(k))
    ast.EMember(ast.EIdent(o), f) -> Some(o <> "." <> f)
    _ -> None
  }
}

fn describe(e: ast.Expr) -> String {
  case key(e) {
    Some(k) ->
      case k {
        "#" <> _ -> "this vector"
        _ -> k
      }
    None -> "this vector"
  }
}

fn unproven_literal(k: Int, vec: String) -> String {
  "cannot prove index "
  <> int.to_string(k)
  <> " is in range for `"
  <> vec
  <> "` (its length isn't known at compile time). Guard the access, e.g. "
  <> "`if "
  <> int.to_string(k)
  <> " < len("
  <> vec
  <> ") { ... }`."
}

fn unproven_ge0(i: String, vec: String) -> String {
  "cannot prove index `"
  <> i
  <> "` is `>= 0` before indexing `"
  <> vec
  <> "`. Guard it, e.g. `if "
  <> i
  <> " >= 0 && "
  <> i
  <> " < len("
  <> vec
  <> ") { ... }`."
}

fn unproven_upper(i: String, vec: String) -> String {
  "cannot prove index `"
  <> i
  <> "` is less than `len("
  <> vec
  <> ")`. Guard it, e.g. `if "
  <> i
  <> " >= 0 && "
  <> i
  <> " < len("
  <> vec
  <> ") { ... }`, or iterate with `for each`."
}
