//// Flow-sensitive vector bounds analysis.
////
//// This pass runs after the main validation pass and before codegen. It
//// proves — at compile time — that every vector index (`v[i]`) and slice
//// (`v[a:b]`) is in range, so the generated Go can never panic with an
//// out-of-bounds error. Anything it cannot prove safe is a compile error.
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
import hive/ast

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

type Env {
  Env(
    /// Every declared type, so member/field lengths and custom types resolve.
    types: Dict(String, ast.Decl),
    /// Length knowledge for the locals currently in scope.
    lengths: Dict(String, LenInfo),
    /// `n := len(v)` records `n -> v` here, so `i < n` proves `i < len(v)`.
    aliases: Dict(String, String),
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
  list.try_fold(module.decls, Nil, fn(_, d) {
    case d {
      ast.ProcDecl(_, params, _, body) | ast.FuncDecl(_, params, _, body, _) ->
        check_body(types, params, body)
      // A query's body is SQL; its interpolations can't index a vector, and
      // the main validation pass already walks them.
      ast.QueryDecl(..) | ast.TypeDecl(..) -> Ok(Nil)
    }
  })
  |> result.map(fn(_) { Nil })
}

fn check_body(
  types: Dict(String, ast.Decl),
  params: List(ast.Field),
  body: List(ast.Stmt),
) -> Result(Nil, String) {
  let lengths =
    list.fold(params, dict.new(), fn(acc, p) {
      dict.insert(acc, p.name, FromType(p.typ))
    })
  let env = Env(types, lengths, dict.new(), [])
  check_stmts(env, body) |> result.map(fn(_) { Nil })
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
      let env2 = forget(env, [name])
      Ok(Env(..env2, lengths: dict.insert(env2.lengths, name, FromType(typ))))
    }
    ast.SAssign(target, value) -> {
      // A `v[i] = x` lvalue indexes `v`, so it must be proven in range too.
      use _ <- result.try(check_lvalue(env, target))
      use _ <- result.try(check_expr(env, value))
      // Reassigning the whole variable changes its length; assigning an
      // element (`v[i] = x`) does not.
      case target {
        ast.EIdent(n) ->
          Ok(record_binding(forget(env, [n]), n, value))
        _ -> Ok(env)
      }
    }
    ast.SReturn(None) -> Ok(env)
    ast.SReturn(Some(e)) -> {
      use _ <- result.try(check_expr(env, e))
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
      Ok(forget(env, mutated_in(body)))
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
      let benv = Env(..env, facts: list.append(facts_from(env, b.cond), env.facts))
      use _ <- result.try(check_stmts(benv, b.body))
      Ok(Nil)
    })
    |> result.map(fn(_) { Nil }),
  )
  use _ <- result.try(case else_body {
    Some(body) -> check_stmts(env, body) |> result.map(fn(_) { Nil })
    None -> Ok(Nil)
  })

  // Facts about any variable a branch reassigns are no longer reliable in the
  // fall-through.
  let mutated =
    list.append(
      list.flat_map(branches, fn(b) { mutated_in(b.body) }),
      case else_body {
        Some(body) -> mutated_in(body)
        None -> []
      },
    )
  let cont = forget(env, mutated)

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
  // nothing it establishes survives; drop facts about anything it mutated.
  Ok(forget(env, list.append(mutated_in(body), post_mutates(post))))
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

fn post_mutates(post: Option(ast.Stmt)) -> List(String) {
  case post {
    Some(s) -> mutated_in([s])
    None -> []
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
      check_expr(Env(..env, facts: list.append(facts_from(env, l), env.facts)), r)
    }
    ast.EBinary(ast.OpOr, l, r) -> {
      use _ <- result.try(check_expr(env, l))
      check_expr(
        Env(..env, facts: list.append(facts_from_neg(env, l), env.facts)),
        r,
      )
    }
    ast.EBinary(_, l, r) -> check_exprs(env, [l, r])
    ast.ECall(callee, args) ->
      check_exprs(env, [callee, ..list.map(args, fn(a) { a.value })])
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
    ast.EUsing(path, delim) ->
      check_exprs(env, [path, ..option.values([delim])])
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
    ast.EIndex(_, _) | ast.EMember(_, _) ->
      case type_of(env, expr) {
        Some(t) -> outer_dim(t)
        None -> Dyn
      }
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
  let lengths = dict.delete(env.lengths, name)
  let aliases = dict.delete(env.aliases, name)
  case value {
    // A vector literal has a known static length.
    ast.EVector(items) ->
      Env(..env, lengths: dict.insert(lengths, name, LitLen(list.length(items))),
        aliases: aliases)
    // `n := len(v)` — remember that `n` is `len(v)`.
    ast.ECall(ast.EIdent("len"), [ast.Arg(_, v)]) ->
      case key(v) {
        Some(vk) -> Env(..env, lengths: lengths, aliases: dict.insert(aliases, name, vk))
        None -> Env(..env, lengths: lengths, aliases: aliases)
      }
    // `a := b` copies whatever length knowledge `b` has (assignment copies).
    ast.EIdent(other) -> {
      let lengths2 = case dict.get(env.lengths, other) {
        Ok(info) -> dict.insert(lengths, name, info)
        Error(_) -> lengths
      }
      Env(..env, lengths: lengths2, aliases: aliases)
    }
    // Indexing/member access that yields a vector keeps its declared type.
    ast.EIndex(_, _) | ast.EMember(_, _) ->
      case type_of(env, value) {
        Some(t) -> Env(..env, lengths: dict.insert(lengths, name, FromType(t)),
          aliases: aliases)
        None -> Env(..env, lengths: lengths, aliases: aliases)
      }
    _ -> Env(..env, lengths: lengths, aliases: aliases)
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
      let aliases =
        env.aliases
        |> dict.to_list
        |> list.filter(fn(pair) {
          !list.contains(names, pair.0) && !list.contains(names, pair.1)
        })
        |> dict.from_list
      Env(..env, facts: facts, aliases: aliases)
    }
  }
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
