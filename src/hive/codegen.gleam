//// Generates Go source (the `main` package) from an Hive `ast.Module`.
////
//// Hive types map onto Go as follows:
////   * A type with no variants becomes a plain `struct`.
////   * A type with variants becomes an `interface` plus one `struct` per
////     variant (a tagged union). Common fields are appended to every variant,
////     which is also the positional order used by constructors.
////   * Vectors (`Str[3]`, `Str[dyn]`, ...) all become Go slices.
////   * Atoms become `hive.Atom` values; the compiler assigns each distinct
////     atom a small integer (#Nil=0 always first) and registers the name
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
import gleam/result
import gleam/string
import hive/ast
import hive/builtins
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
  /// A first-class function value. `pure` is True for a `func`, False for a
  /// `proc`; both lower to the same Go `func(...)` type.
  TyFunc(pure: Bool, params: List(Ty), ret: Ty)
  /// A handle to an `async func` call still running on its own goroutine — the
  /// value a bare async call evaluates to (Hive's `async T`). It has no surface
  /// spelling: it is only ever inferred, held in a local binding, and consumed
  /// by `await` (which unwraps it back to `inner`). Lowers to
  /// `*hive.Async[inner]`.
  TyAsync(inner: Ty)
  /// The address of a `hive.syslink` service, carrying the type of the mailbox
  /// it delivers to. Like `async T` the payload type has no surface spelling:
  /// it is inferred from the handler a service was spawned with, or from the
  /// registry entry a name resolves to, which is what lets `send` be checked
  /// against the mailbox it is addressing. An *annotated*
  /// `hive.syslink.Address` carries `TyUnknown` and is simply unchecked.
  /// Unlike `async T` an address is a plain value: it outlives its scope, can
  /// be stored and sent, and is never awaited.
  TyAddress(msg: Ty)
  /// A `hive.syslink` request in flight — what a kept `send` evaluates to. Like
  /// `async T` it has no surface spelling and is only ever inferred, bound and
  /// consumed by `await`, which resolves it to `Result<msg, SyslinkError>`. A
  /// service answers with one of its own messages, so the reply type *is* the
  /// mailbox type and no annotation is needed anywhere.
  ///
  /// It is not a `TyAsync`: no goroutine is waiting behind it. The answer
  /// arrives on the connection's reader, so the wait happens at the `await`.
  TyPending(msg: Ty)
  /// The absence of a value — only meaningful as a function type's return, so
  /// a `proc(T): void` value lowers to `func(T)` with no Go return type.
  TyVoid
  /// A type variable: a name in a signature that is neither a builtin nor a
  /// declared type, which makes the callable generic in it. Monomorphization
  /// substitutes every one away before any other pass runs, so nothing
  /// downstream ever meets one.
  TyVar(name: String)
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
    "WsError" -> Some([#("reason", TyStr), #("message", TyStr)])
    "SocketError" -> Some([#("reason", TyStr), #("message", TyStr)])
    // What the two calls in the module that name no protocol answer with:
    // resolving a name, and asking where this machine is.
    "NetError" -> Some([#("reason", TyStr), #("message", TyStr)])
    // An open WebSocket and an open TCP stream. Both are opaque — they expose
    // no fields — but registering them here is what lets a parameter or
    // variable be declared `hive.net.WsConnection` / `hive.net.SocketConnection`
    // and resolve to a `TyBuiltin`, which the handler checks rely on.
    "WsConnection" -> Some([])
    "SocketConnection" -> Some([])
    "TableError" -> Some([#("path", TyStr), #("message", TyStr)])
    "JsonError" ->
      Some([#("path", TyStr), #("expected", TyStr), #("found", TyStr)])
    "CryptoError" -> Some([#("reason", TyStr), #("message", TyStr)])
    "ConversionError" -> Some([#("input", TyStr), #("message", TyStr)])
    "EnvironmentError" -> Some([#("key", TyStr), #("message", TyStr)])
    "FileError" ->
      Some([#("path", TyStr), #("reason", TyStr), #("message", TyStr)])
    "JwtHeader" ->
      Some([#("alg", TyStr), #("typ", TyStr), #("kid", TyStr)])
    "SqlError" -> Some([#("reason", TyStr), #("message", TyStr)])
    "DatabaseDriver" -> Some([#("name", TyStr)])
    // An open database connection. It is opaque — it exposes no fields — but it
    // is still a named builtin type, so a parameter or variable can be declared
    // `hive.sql.SqlConnection`. Registering it here is what lets its type
    // resolve to `TyBuiltin("SqlConnection")`, which `using ... with ...` needs
    // in order to run a SQL query rather than read a CSV.
    "SqlConnection" -> Some([])
    // A service address and a turn's envelope. Both are opaque — an address is
    // produced by `spawn`/`at`/`self` and an envelope only ever arrives as a
    // handler's third parameter — but registering them here is what lets a
    // parameter, field or variable be declared `hive.syslink.Address` /
    // `hive.syslink.Envelope` and resolve to a known type, which the handler
    // shape check relies on.
    "Address" -> Some([])
    "Envelope" -> Some([])
    "SyslinkError" -> Some([#("reason", TyStr), #("message", TyStr)])
    // What `await ... with timeout <ms>` yields when the wait runs out.
    "TimeoutError" -> Some([#("waited", TyInt), #("message", TyStr)])
    _ -> None
  }
}

/// The namespace a builtin type must be referenced through (each stdlib module
/// owns its types). The core types the language uses without a module — the
/// `TableError` that `using` yields — stay directly on `hive`.
pub fn builtin_qualifier(name: String) -> String {
  case name {
    "HttpRequest" | "HttpResponse" | "HttpError" -> "hive.net"
    "WsConnection" | "WsError" -> "hive.net"
    "SocketConnection" | "SocketError" -> "hive.net"
    "NetError" -> "hive.net"
    "JsonError" -> "hive.json"
    "CryptoError" | "JwtHeader" -> "hive.crypto"
    "ConversionError" -> "hive.conv"
    "EnvironmentError" -> "hive.env"
    "FileError" -> "hive.file"
    "SqlError" | "SqlConnection" | "DatabaseDriver" -> "hive.sql"
    "Address" | "Envelope" | "SyslinkError" -> "hive.syslink"
    "TimeoutError" -> "hive.task"
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

pub type Env {
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
    /// Locals whose storage is shared with another *mutable* binding (created
    /// by a `mut b = a` where both ends are mutable). Such a variable has a
    /// live mutable alias, so it is not eligible to be *moved* into an
    /// immutable binding (see `aliased_source` / `bind_rhs`): something else
    /// may still mutate it.
    aliased: Dict(String, Bool),
    /// Names that *are* another expression rather than a variable of their own:
    /// what a `mut b = a` between two mutable ends lowers to. Both names render
    /// as the same Go lvalue, which is what makes the sharing survive `append`
    /// (see `shares_storage`).
    renames: Dict(String, String),
    /// Every user-declared proc/func/query, keyed by name: whether it is pure
    /// (a func/query) and its full parameter list and return type. Powers
    /// first-class function values — the closure a partial application lowers
    /// to needs the exact parameter and return types.
    fns: Dict(String, #(Bool, List(ast.Field), ast.TypeExpr)),
    /// The program's service registry, known at compile time: registered name
    /// -> the message type of the mailbox behind it. Registered names come
    /// from a closed set of atoms and cannot be computed, so this table is
    /// complete for every name this program registers — which is what lets
    /// `hive.syslink.at(#Node, #Name)` infer its mailbox type instead of being
    /// told, and lets a `send` to a remote service be type-checked at all.
    mailboxes: Dict(String, ast.TypeExpr),
    /// Every proc/func body, keyed by name. Needed to answer questions about a
    /// callable that are not visible from its signature — such as whether a
    /// service handler ever lets its envelope outlive the turn it arrived in.
    bodies: Dict(String, List(ast.Stmt)),
  )
}

// The module-wide environment: everything known before any body is walked.
// Shared by `generate` and `check_types`, so the check sees exactly the types
// generation will.
pub fn module_env(module: ast.Module) -> Env {
  let types = collect_types(module.decls)
  let atoms =
    collect_atoms(module)
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
  let fns = collect_fns(module.decls)
  Env(
    types,
    sigs,
    dict.new(),
    dict.new(),
    TyUnknown,
    atoms,
    asyncs,
    dict.new(),
    dict.new(),
    dict.new(),
    fns,
    collect_mailboxes(module, fns),
    collect_bodies(module.decls),
  )
}

/// Bind a local into an environment, for passes that walk bodies themselves.
pub fn with_local(env: Env, name: String, ty: Ty) -> Env {
  Env(..env, locals: dict.insert(env.locals, name, ty))
}

/// The declared types of a module, as `ty_of_type_expr` wants them.
pub fn env_types(env: Env) -> Dict(String, ast.Decl) {
  env.types
}

/// The bindings a condition's `is` patterns introduce, with their types.
pub fn condition_binds(env: Env, cond: ast.Expr) -> List(#(String, Ty)) {
  let #(_, binds) = gen_condition(env, cond)
  list.map(binds, fn(b) {
    let #(name, _, ty) = b
    #(name, ty)
  })
}

pub fn generate(module: ast.Module) -> String {
  let atom_table = collect_atoms(module)
  let env = module_env(module)

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

  // Whether the program reached for syslink is decided by the code just
  // generated, the same way `runtime.needed_modules` decides which library
  // modules to write at all.
  let json_code =
    gen_json_support(env, module, string.contains(fn_code, "hive.Syslink"))

  let clone_code = gen_clone_support(env, module)
  let row_code = gen_sql_row_support(env, module)

  let body =
    type_code <> "\n" <> atom_code <> clone_code <> row_code <> json_code <> fn_code
  gen_header(body) <> "\n" <> body
}

// ---------------------------------------------------------------------------
// Checks that need the inferred type of an expression
// ---------------------------------------------------------------------------

/// Rejects the constructs codegen has no honest lowering for. This lives here,
/// rather than in the main validation pass, because deciding it takes the same
/// local inference generation uses: whether `s[0]` indexes a vector or a `Str`
/// is a question about the type of `s`.
pub fn check_types(module: ast.Module) -> Result(Nil, String) {
  let env = module_env(module)
  list.try_fold(module.decls, Nil, fn(_, d) {
    case d {
      ast.ProcDecl(_, params, ret, body)
      | ast.FuncDecl(_, params, ret, body, _) ->
        walk_stmts(fn_env(env, params, ret), body)
        |> result.map(fn(_) { Nil })
      ast.QueryDecl(_, params, ret, sql) -> {
        let qenv = fn_env(env, params, ret)
        use _ <- result.try(
          list.try_fold(ast.sql_exprs(sql), Nil, fn(_, e) { walk_expr(qenv, e) }),
        )
        // A `where { if <cond> { ... } }` predicate is a boolean position too.
        list.try_fold(ast.sql_conds(sql), Nil, fn(_, e) {
          check_condition(qenv, e)
        })
        |> result.map(fn(_) { Nil })
      }
      ast.TypeDecl(..) -> Ok(Nil)
    }
  })
  |> result.map(fn(_) { Nil })
}

// Walks a body the way `gen_stmts` does — threading each declaration into scope
// so later expressions infer against it — and checks every expression on the
// way.
fn walk_stmts(env: Env, stmts: List(ast.Stmt)) -> Result(Env, String) {
  list.try_fold(env, over: stmts, with: fn(env, s) { walk_stmt(env, s) })
}

fn walk_stmt(env: Env, s: ast.Stmt) -> Result(Env, String) {
  case s {
    ast.SVarDecl(name, value, mutable) -> {
      use _ <- result.try(walk_expr(env, value))
      Ok(
        Env(
          ..env,
          locals: dict.insert(env.locals, name, infer(env, value)),
          muts: dict.insert(env.muts, name, mutable),
        ),
      )
    }
    ast.STypedDecl(typ, name, value, mutable) -> {
      use _ <- result.try(walk_expr(env, value))
      Ok(
        Env(
          ..env,
          locals: dict.insert(
            env.locals,
            name,
            ty_of_type_expr(env.types, typ),
          ),
          muts: dict.insert(env.muts, name, mutable),
        ),
      )
    }
    ast.SAssign(target, value) -> {
      use _ <- result.try(walk_expr(env, target))
      use _ <- result.try(walk_expr(env, value))
      Ok(env)
    }
    ast.SAssert(e) -> {
      use _ <- result.try(walk_expr(env, e))
      use _ <- result.try(check_condition(env, e))
      Ok(env)
    }
    ast.SReturn(Some(e)) | ast.SEcho(e) | ast.SPanic(e) | ast.SExpr(e) -> {
      use _ <- result.try(walk_expr(env, e))
      Ok(env)
    }
    ast.SReturn(None) | ast.SBreak | ast.SContinue -> Ok(env)
    ast.SIf(branches, else_body) -> {
      use _ <- result.try(
        list.try_fold(branches, Nil, fn(_, b) {
          use _ <- result.try(walk_expr(env, b.cond))
          use _ <- result.try(check_condition(env, b.cond))
          // Whatever the condition's `is` patterns bind is in scope in the body,
          // with the types the generated accessors have.
          let #(_, binds) = gen_condition(env, b.cond)
          use _ <- result.try(walk_stmts(bind_locals(env, binds), b.body))
          Ok(Nil)
        }),
      )
      use _ <- result.try(
        walk_stmts(env, option.unwrap(else_body, [])) |> result.map(fn(_) { Nil }),
      )
      Ok(env)
    }
    ast.SFor(init, cond, post, body) -> {
      use ienv <- result.try(case init {
        Some(st) -> walk_stmt(env, st)
        None -> Ok(env)
      })
      use _ <- result.try(case cond {
        Some(e) -> {
          use _ <- result.try(walk_expr(ienv, e))
          check_condition(ienv, e)
        }
        None -> Ok(Nil)
      })
      use _ <- result.try(case post {
        Some(st) -> walk_stmt(ienv, st) |> result.map(fn(_) { Nil })
        None -> Ok(Nil)
      })
      use _ <- result.try(walk_stmts(ienv, body))
      // The counter is scoped to the loop.
      Ok(env)
    }
    ast.SForEach(name, elem_type, iterable, body) -> {
      use _ <- result.try(walk_expr(env, iterable))
      let elem_ty = case elem_type {
        Some(t) -> ty_of_type_expr(env.types, t)
        None -> elem_ty_of(infer(env, iterable))
      }
      use _ <- result.try(walk_stmts(
        Env(..env, locals: dict.insert(env.locals, name, elem_ty)),
        body,
      ))
      Ok(env)
    }
  }
}

/// An `Atom` is not a condition. It used to be — truthy unless it was the atom
/// at zero — but that made `if flag` read as a question about which atom it was,
/// answered by a numbering the program never chose. Comparing says what is meant
/// and costs one operator: `if flag == #Ready`.
///
/// `&&` and `||` combine conditions, so each of their sides is a boolean
/// position too, and an `is` test is a condition already.
fn check_condition(env: Env, cond: ast.Expr) -> Result(Nil, String) {
  case cond {
    ast.EBinary(ast.OpAnd, l, r) | ast.EBinary(ast.OpOr, l, r) -> {
      use _ <- result.try(check_condition(env, l))
      check_condition(env, r)
    }
    ast.EIs(_, _) -> Ok(Nil)
    _ ->
      case infer(env, cond) {
        TyAtom ->
          Error(
            "an atom is not a condition: it is a label, not a yes or a no. "
            <> "Compare it with the one you mean (`== #SomeAtom`), or use a "
            <> "`Bool`.",
          )
        _ -> Ok(Nil)
      }
  }
}

fn walk_expr(env: Env, e: ast.Expr) -> Result(Nil, String) {
  use _ <- result.try(check_indexable(env, e))
  use _ <- result.try(check_address_call(env, e))
  use _ <- result.try(check_walk_call(env, e))
  case e {
    ast.EInt(_)
    | ast.EFloat(_)
    | ast.EString(_)
    | ast.EBool(_)
    | ast.EAtom(_)
    | ast.EIdent(_) -> Ok(Nil)
    ast.EMember(target, _) | ast.EIs(target, _) | ast.EWith(target, _) ->
      walk_expr(env, target)
    ast.EIndex(target, index) -> walk_exprs(env, [target, index])
    ast.ESlice(target, low, high) ->
      walk_exprs(env, [target, ..option.values([low, high])])
    ast.EBinary(_, l, r) -> walk_exprs(env, [l, r])
    ast.EVector(items) -> walk_exprs(env, items)
    ast.EInterp(parts) ->
      list.try_fold(parts, Nil, fn(_, part) {
        case part {
          ast.ILit(_) -> Ok(Nil)
          ast.IExpr(inner) -> walk_expr(env, inner)
        }
      })
      |> result.map(fn(_) { Nil })
    ast.ECall(callee, args) ->
      walk_exprs(env, [callee, ..list.map(args, fn(a) { a.value })])
    ast.EUsing(source, kind) ->
      walk_exprs(env, [source, ..ast.using_exprs(kind)])
    ast.EAwait(value, timeout) ->
      walk_exprs(env, [value, ..option.values([timeout])])
  }
}

fn walk_exprs(env: Env, exprs: List(ast.Expr)) -> Result(Nil, String) {
  list.try_fold(exprs, Nil, fn(_, e) { walk_expr(env, e) })
  |> result.map(fn(_) { Nil })
}

// Calling a service address carries exactly one message, and nothing else. The
// address is a mailbox, not a function: there is no second parameter to name, no
// hole to leave for later, and nothing to overload. Every other shape is a
// mistake about what the value is, so each is named rather than lowered.
fn check_address_call(env: Env, e: ast.Expr) -> Result(Nil, String) {
  case e {
    ast.ECall(callee, args) ->
      case address_call_msg(env, callee) {
        None -> Ok(Nil)
        Some(_) ->
          case args {
            [ast.Arg(Some(label), _)] ->
              Error(
                "a service address takes its message as a plain argument, so `"
                <> label
                <> ":` has nothing to name — write `address(message)`. A mailbox "
                <> "has one message per turn, not a parameter list.",
              )
            [ast.Arg(None, ast.EIdent("_"))] ->
              Error(
                "a service address cannot be partially applied: `_` leaves a "
                <> "hole for an argument that arrives later, and a send has "
                <> "nothing to wait for — the message is the whole call. Pass "
                <> "the address itself if you meant to hand the service on; it "
                <> "is an ordinary value and can even travel inside a message.",
              )
            [_] -> Ok(Nil)
            [] ->
              Error(
                "calling a service address sends it a message, so it needs one: "
                <> "`address(message)`. To reach a service without saying "
                <> "anything, give its mailbox a field-less variant and send "
                <> "that.",
              )
            _ ->
              Error(
                "a service address is called with exactly one message, and "
                <> int.to_string(list.length(args))
                <> " were passed. A mailbox handles one message per turn, so a "
                <> "second argument has nowhere to go — put the extra data in "
                <> "the message type instead, which is also what makes it "
                <> "checkable and sendable to another node.",
              )
          }
      }
    _ -> Ok(Nil)
  }
}

// `map`, `filter` and `filterMap` each take a vector and a function over its
// elements, and each is specific about what that function answers with. Getting
// any of it wrong has to be said here: the call lowers to a Go generic helper the
// source never mentions, so a mismatch left to Go reports against `hive.Map[T,
// K]` and names neither the builtin nor the argument that was wrong.
fn check_walk_call(env: Env, e: ast.Expr) -> Result(Nil, String) {
  case walk_called(e) {
    None -> Ok(Nil)
    Some(#(name, [ast.Arg(_, subject), ast.Arg(_, f)])) -> {
      use elem <- result.try(walk_elem_ty(env, name, subject))
      check_walk_fn(env, name, elem, f)
    }
    Some(#(name, args)) ->
      Error(
        "`"
        <> name
        <> "` takes a vector and a function over its elements — "
        <> int.to_string(list.length(args))
        <> " "
        <> plural(list.length(args), "argument")
        <> case list.length(args) {
          1 -> " was"
          _ -> " were"
        }
        <> " passed. Write `"
        <> name
        <> "(values, "
        <> walk_fn_example(name)
        <> ")`.",
      )
  }
}

// The walk an expression calls, with its arguments.
fn walk_called(e: ast.Expr) -> Option(#(String, List(ast.Arg))) {
  case e {
    ast.ECall(callee, args) ->
      case builtins.called(callee) {
        Some(name) ->
          case name {
            "map" | "filter" | "filterMap" -> Some(#(name, args))
            _ -> None
          }
        None -> None
      }
    _ -> None
  }
}

// The element type the function will be handed. A subject that is not a vector
// at all is the mistake, not the function.
fn walk_elem_ty(env: Env, name: String, subject: ast.Expr) -> Result(Ty, String) {
  case infer(env, subject) {
    TyVec(elem) -> Ok(elem)
    // A Table is a vector of rows, so it walks a row at a time.
    TyTable -> Ok(TyVec(TyStr))
    // Nothing was pinned down; there is no mismatch to report.
    TyUnknown -> Ok(TyUnknown)
    TyStr ->
      Error(
        "`"
        <> name
        <> "` walks a vector, and a `Str` is not one — it is a sequence of "
        <> "characters, which `[...]` and `len` treat as a unit. Use "
        <> "`split(s, sep)` to get a vector of its pieces first.",
      )
    other ->
      Error(
        "`"
        <> name
        <> "` walks a vector, and this is a `"
        <> show_ty(other)
        <> "`. Give it the vector whose elements the function should see.",
      )
  }
}

// The function, checked against what the builtin will do with it: it takes one
// element and answers with the one thing this builtin can use.
fn check_walk_fn(
  env: Env,
  name: String,
  elem: Ty,
  f: ast.Expr,
) -> Result(Nil, String) {
  case infer(env, f) {
    TyFunc(pure, params, ret) -> {
      // Every one of the three is a pure walk: nothing about it says in which
      // order, or how many times, the function runs. A `proc` is exactly the
      // thing that would notice, and letting one in would also be a way for a
      // `func` body to reach side effects it may not have.
      use _ <- result.try(case pure {
        True -> Ok(Nil)
        False ->
          Error(
            "`"
            <> name
            <> "` takes a `func` (pure), and this is a `proc`: a walk says "
            <> "nothing about the order its function runs in, or how often, so "
            <> "there is nowhere to hang a side effect. Use `for each` to walk "
            <> "a vector with a proc.",
          )
      })
      use _ <- result.try(case params {
        [param] -> check_walk_param(name, elem, param)
        _ ->
          Error(
            "the function `"
            <> name
            <> "` is given takes one element at a time, and this one takes "
            <> int.to_string(list.length(params))
            <> " "
            <> plural(list.length(params), "parameter")
            <> ". Fix the extra ones in place with a partial application — "
            <> "`f(fixed, _)` leaves the element as the only one left open.",
          )
      })
      check_walk_ret(name, ret)
    }
    // A function value the checker cannot see the shape of; Go still has the
    // real type and will not let a non-function through.
    TyUnknown -> Ok(Nil)
    other ->
      Error(
        "`"
        <> name
        <> "` walks a vector with a function, and this is a `"
        <> show_ty(other)
        <> "`. Pass a `func` by name, or a partial application of one "
        <> "(`f(fixed, _)`).",
      )
  }
}

fn check_walk_param(name: String, elem: Ty, param: Ty) -> Result(Nil, String) {
  case ty_accepts(param, elem) {
    True -> Ok(Nil)
    False ->
      Error(
        "`"
        <> name
        <> "` is walking a vector of `"
        <> show_ty(elem)
        <> "`, so the function has to take one — this one takes a `"
        <> show_ty(param)
        <> "`.",
      )
  }
}

fn check_walk_ret(name: String, ret: Ty) -> Result(Nil, String) {
  case name, ret {
    "filter", TyBool -> Ok(Nil)
    "filter", other ->
      Error(
        "`filter` keeps the elements its function says yes to, so that function "
        <> "answers `Bool` — this one answers `"
        <> show_ty(other)
        <> "`. To transform elements instead, use `map`; to do both at once, "
        <> "return a `Result` and use `filterMap`.",
      )
    "filterMap", TyResult(_, _) -> Ok(Nil)
    "filterMap", other ->
      Error(
        "`filterMap` transforms and selects in one pass, so its function answers "
        <> "a `Result`: an `Ok` carries the element's new value and an `Error` "
        <> "says it has no place in the output. This one answers `"
        <> show_ty(other)
        <> "`. Use `map` when every element has a new value, or `filter` when "
        <> "none of them change.",
      )
    "map", TyVoid ->
      Error(
        "`map` collects what its function returns, and this one returns nothing. "
        <> "A walk that only performs effects is a `for each` loop.",
      )
    _, _ -> Ok(Nil)
  }
}

// Whether a value of type `arg` may land in a slot of type `param`. Only a
// mismatch both sides are known well enough to prove is one: `TyUnknown` stands
// for "could not tell", on either side and at any depth, and a type variable can
// only be left over from a signature monomorphization has yet to reach.
fn ty_accepts(param: Ty, arg: Ty) -> Bool {
  case param, arg {
    TyUnknown, _ | _, TyUnknown -> True
    TyVar(_), _ | _, TyVar(_) -> True
    // An atom renders as its Str form wherever a Str is wanted.
    TyStr, TyAtom -> True
    // A Table *is* a vector of rows of Str, spelled shorter.
    TyTable, TyVec(TyVec(TyStr)) | TyVec(TyVec(TyStr)), TyTable -> True
    TyVec(p), TyVec(a) -> ty_accepts(p, a)
    TyResult(po, pe), TyResult(ao, ae) ->
      ty_accepts(po, ao) && ty_accepts(pe, ae)
    TyAsync(p), TyAsync(a) -> ty_accepts(p, a)
    TyAddress(p), TyAddress(a) -> ty_accepts(p, a)
    TyPending(p), TyPending(a) -> ty_accepts(p, a)
    // A func value widens to a proc slot, never the other way round — so the
    // only rejected pairing is a proc arriving at a pure slot.
    TyFunc(pp, pparams, pret), TyFunc(ap, aparams, aret) ->
      !{ pp && !ap }
      && list.length(pparams) == list.length(aparams)
      && list.all(list.zip(pparams, aparams), fn(pair) {
        ty_accepts(pair.0, pair.1)
      })
      && ty_accepts(pret, aret)
    _, _ -> param == arg
  }
}

// What one of the three builtins would be written with, for the arity message.
fn walk_fn_example(name: String) -> String {
  case name {
    "filter" -> "keep"
    _ -> "transform"
  }
}

// `[...]` on a `Str`. Go would index the string's *bytes*, which is the wrong
// unit twice over: `len` on a Str counts characters, so a guard written against
// it does not bound the access the way it reads, and a byte plucked out of the
// middle of a multi-byte character is not a character at all — slicing one out
// produces a `Str` that is no longer valid UTF-8. Rather than pick a lowering
// that is quietly wrong, the language has no `Str` subscript: reach for
// `split`, `indexOf`, or a string pattern (`s is "{head}/{tail}"`).
fn check_indexable(env: Env, e: ast.Expr) -> Result(Nil, String) {
  let #(target, what) = case e {
    ast.EIndex(t, _) -> #(Some(t), "indexed")
    ast.ESlice(t, _, _) -> #(Some(t), "sliced")
    _ -> #(None, "")
  }
  case target {
    None -> Ok(Nil)
    Some(t) ->
      case infer(env, t) {
        TyStr ->
          Error(
            "a `Str` cannot be "
            <> what
            <> ": `[...]` addresses bytes, while a `Str` is a sequence of "
            <> "characters (`len` counts those), so the two never line up and "
            <> "a byte out of the middle of a character is not text. Use "
            <> "`split(s, sep)` to get at the pieces, `indexOf(s, sub)` to "
            <> "find one, or a string pattern (`s is \"{head}/{tail}\"`) to "
            <> "take it apart.",
          )
        _ -> Ok(Nil)
      }
  }
}

// ---------------------------------------------------------------------------
// The compile-time service registry
// ---------------------------------------------------------------------------
// Registered names are atoms, and an atom cannot be computed: the set of names
// a program uses is closed and known before it runs. That is what makes this
// table possible, and it is what Erlang cannot have — `list_to_atom/1` means a
// registered name there is never knowable at compile time.
//
// The table pairs each registered name with the message type of the mailbox
// behind it, by following `register(#Name, …)` back to the handler the service
// was spawned with. Two shapes are resolved, which between them cover how the
// call is actually written:
//
//     hive.syslink.register(#Inbox, hive.syslink.spawn(inbox, 0))
//     box := hive.syslink.spawn(inbox, 0)
//     hive.syslink.register(#Inbox, box)
//
// Anything else leaves the name unresolved, and an `at` on it needs a `with`
// clause to say what it expects — which is also the escape hatch for a cluster
// whose nodes are not all the same binary.

fn collect_bodies(decls: List(ast.Decl)) -> Dict(String, List(ast.Stmt)) {
  list.fold(decls, dict.new(), fn(acc, d) {
    case d {
      ast.ProcDecl(name, _, _, body) | ast.FuncDecl(name, _, _, body, _) ->
        dict.insert(acc, name, body)
      _ -> acc
    }
  })
}

// ---------------------------------------------------------------------------
// Does a service handler's envelope outlive its turn?
// ---------------------------------------------------------------------------
// The runtime wants to fail a request the moment a turn ends without answering
// it, so that forgetting to reply on one branch reads as "handled but never
// answered" instead of a timeout five seconds later. That is only safe when no
// answer can still be coming — which is a question about where the envelope
// goes, and one the compiler can settle.
//
// The envelope cannot outlive the turn if it appears *only* as the subject of
// `answer`, `self` and `monitor` — the three calls the runtime controls, none of
// which keep the reply token. Anywhere else it might be stored in the returned
// state, captured by a spawned task, or handed to another callable, and the
// answer may genuinely still be on its way, so the automatic reply is switched
// off for that handler.
//
// The analysis is deliberately conservative and per-handler, exactly like the
// copy-vs-alias rule for value semantics: an escape anywhere disables it
// everywhere in that service, and being unsure counts as an escape. Getting it
// wrong that way costs a timeout; the other way would cut off a live request.

fn bool_lit(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

// Whether the runtime may fail an unanswered request as soon as the turn ends.
fn replies_in_turn(env: Env, handler: ast.Expr) -> Bool {
  let name = case handler {
    ast.EIdent(n) -> Some(n)
    ast.ECall(ast.EIdent(n), _) -> Some(n)
    _ -> None
  }
  case name {
    None -> False
    Some(n) ->
      case dict.get(env.fns, n), dict.get(env.bodies, n) {
        Ok(#(_, params, _)), Ok(body) ->
          case envelope_param(params) {
            // No envelope parameter at all: nothing can answer, so an unanswered
            // request is always final.
            None -> True
            Some(envelope) -> !escapes_in_stmts(envelope, body)
          }
        _, _ -> False
      }
  }
}

// The handler's envelope parameter, found by its type rather than its position,
// so a partial application is read the same way as a bare name.
fn envelope_param(params: List(ast.Field)) -> Option(String) {
  params
  |> list.find(fn(p) {
    case p.typ {
      ast.TName(Some("hive.syslink"), "Envelope", _, []) -> True
      _ -> False
    }
  })
  |> option.from_result
  |> option.map(fn(p) { p.name })
}

fn escapes_in_stmts(name: String, stmts: List(ast.Stmt)) -> Bool {
  list.any(stmts, fn(s) { escapes_in_stmt(name, s) })
}

fn escapes_in_stmt(name: String, s: ast.Stmt) -> Bool {
  case s {
    ast.SVarDecl(_, value, _) | ast.STypedDecl(_, _, value, _) ->
      escapes_in_expr(name, value)
    ast.SAssign(target, value) ->
      escapes_in_expr(name, target) || escapes_in_expr(name, value)
    ast.SReturn(Some(e)) -> escapes_in_expr(name, e)
    ast.SReturn(None) | ast.SBreak | ast.SContinue -> False
    ast.SEcho(e) | ast.SAssert(e) | ast.SPanic(e) | ast.SExpr(e) ->
      escapes_in_expr(name, e)
    ast.SIf(branches, else_body) ->
      list.any(branches, fn(b) {
        escapes_in_expr(name, b.cond) || escapes_in_stmts(name, b.body)
      })
      || case else_body {
        Some(body) -> escapes_in_stmts(name, body)
        None -> False
      }
    ast.SFor(init, cond, post, body) ->
      case init {
        Some(i) -> escapes_in_stmt(name, i)
        None -> False
      }
      || case cond {
        Some(c) -> escapes_in_expr(name, c)
        None -> False
      }
      || case post {
        Some(p) -> escapes_in_stmt(name, p)
        None -> False
      }
      || escapes_in_stmts(name, body)
    ast.SForEach(_, _, iterable, body) ->
      escapes_in_expr(name, iterable) || escapes_in_stmts(name, body)
  }
}

fn escapes_in_expr(name: String, e: ast.Expr) -> Bool {
  case e {
    // The three calls that consume an envelope without keeping it. The envelope
    // may be their first argument; everything else is still checked, so
    // `monitor(from, peer, Msg.Watch(self(from)))` reads as no escape while
    // `monitor(from, peer, Msg.Hold(from))` reads as one.
    ast.ECall(
      ast.EMember(ast.EMember(ast.EIdent("hive"), "syslink"), fname),
      args,
    ) if fname == "answer" || fname == "self" || fname == "monitor" -> {
      let params = case fname {
        "answer" -> ["from", "value"]
        "self" -> ["from"]
        _ -> ["from", "target", "message"]
      }
      let #(assigned, extra) = assign_args(args, params)
      case assigned {
        [#(_, first), ..rest] ->
          // Anything more elaborate than the bare name in the envelope slot is
          // not something this pass will vouch for.
          case first {
            ast.EIdent(n) if n == name ->
              list.any(rest, fn(pair) { escapes_in_expr(name, pair.1) })
              || list.any(extra, fn(a) { escapes_in_expr(name, a) })
            _ ->
              escapes_in_expr(name, first)
              || list.any(rest, fn(pair) { escapes_in_expr(name, pair.1) })
              || list.any(extra, fn(a) { escapes_in_expr(name, a) })
          }
        [] -> list.any(extra, fn(a) { escapes_in_expr(name, a) })
      }
    }
    // A bare mention anywhere else: it could be going anywhere.
    ast.EIdent(n) -> n == name
    ast.ECall(callee, args) ->
      escapes_in_expr(name, callee)
      || list.any(args, fn(a) { escapes_in_expr(name, a.value) })
    ast.EMember(target, _) -> escapes_in_expr(name, target)
    ast.EVector(items) -> list.any(items, fn(i) { escapes_in_expr(name, i) })
    ast.EIndex(target, index) ->
      escapes_in_expr(name, target) || escapes_in_expr(name, index)
    ast.ESlice(target, low, high) ->
      escapes_in_expr(name, target)
      || case low {
        Some(l) -> escapes_in_expr(name, l)
        None -> False
      }
      || case high {
        Some(h) -> escapes_in_expr(name, h)
        None -> False
      }
    ast.EBinary(_, l, r) ->
      escapes_in_expr(name, l) || escapes_in_expr(name, r)
    ast.EIs(subject, _) -> escapes_in_expr(name, subject)
    ast.EUsing(source, kind) ->
      escapes_in_expr(name, source)
      || list.any(ast.using_exprs(kind), fn(x) { escapes_in_expr(name, x) })
    ast.EWith(value, _) -> escapes_in_expr(name, value)
    ast.EAwait(value, timeout) ->
      escapes_in_expr(name, value)
      || case timeout {
        Some(ms) -> escapes_in_expr(name, ms)
        None -> False
      }
    ast.EInterp(parts) ->
      list.any(parts, fn(p) {
        case p {
          ast.ILit(_) -> False
          ast.IExpr(inner) -> escapes_in_expr(name, inner)
        }
      })
    ast.EInt(_) | ast.EFloat(_) | ast.EString(_) | ast.EBool(_) | ast.EAtom(_) ->
      False
  }
}

fn collect_mailboxes(
  module: ast.Module,
  fns: Dict(String, #(Bool, List(ast.Field), ast.TypeExpr)),
) -> Dict(String, ast.TypeExpr) {
  module.decls
  |> list.fold(dict.new(), fn(acc, d) {
    case d {
      ast.ProcDecl(_, _, _, body) | ast.FuncDecl(_, _, _, body, _) ->
        mailboxes_in_stmts(body, fns, dict.new(), acc).1
      _ -> acc
    }
  })
}

// Walks a body carrying two tables: `spawned` maps a local variable to the
// message type of the service it holds, and `found` is the registry being
// built.
fn mailboxes_in_stmts(
  stmts: List(ast.Stmt),
  fns: Dict(String, #(Bool, List(ast.Field), ast.TypeExpr)),
  spawned: Dict(String, ast.TypeExpr),
  found: Dict(String, ast.TypeExpr),
) -> #(Dict(String, ast.TypeExpr), Dict(String, ast.TypeExpr)) {
  list.fold(stmts, #(spawned, found), fn(acc, s) {
    let #(sp, fd) = acc
    case s {
      ast.SVarDecl(name, value, _) | ast.STypedDecl(_, name, value, _) ->
        case spawn_msg_type(value, fns) {
          Some(msg) -> #(dict.insert(sp, name, msg), fd)
          None -> #(sp, register_in_expr(value, fns, sp, fd))
        }
      ast.SExpr(e) | ast.SEcho(e) | ast.SAssert(e) | ast.SPanic(e) -> #(
        sp,
        register_in_expr(e, fns, sp, fd),
      )
      ast.SReturn(Some(e)) -> #(sp, register_in_expr(e, fns, sp, fd))
      ast.SReturn(None) | ast.SBreak | ast.SContinue -> acc
      ast.SAssign(_, value) -> #(sp, register_in_expr(value, fns, sp, fd))
      ast.SIf(branches, else_body) -> {
        let after =
          list.fold(branches, acc, fn(inner, b) {
            mailboxes_in_stmts(b.body, fns, inner.0, inner.1)
          })
        case else_body {
          Some(body) -> mailboxes_in_stmts(body, fns, after.0, after.1)
          None -> after
        }
      }
      ast.SFor(_, _, _, body) | ast.SForEach(_, _, _, body) ->
        mailboxes_in_stmts(body, fns, sp, fd)
    }
  })
}

// `hive.syslink.register(#Name, …)` anywhere in an expression.
fn register_in_expr(
  e: ast.Expr,
  fns: Dict(String, #(Bool, List(ast.Field), ast.TypeExpr)),
  spawned: Dict(String, ast.TypeExpr),
  found: Dict(String, ast.TypeExpr),
) -> Dict(String, ast.TypeExpr) {
  case e {
    ast.ECall(
      ast.EMember(ast.EMember(ast.EIdent("hive"), "syslink"), "register"),
      args,
    ) ->
      case assign_args(args, ["name", "address"]) {
        #([#(_, ast.EAtom(name)), #(_, address)], []) ->
          case spawn_msg_type(address, fns) {
            Some(msg) -> dict.insert(found, name, msg)
            None ->
              case address {
                ast.EIdent(v) ->
                  case dict.get(spawned, v) {
                    Ok(msg) -> dict.insert(found, name, msg)
                    Error(_) -> found
                  }
                _ -> found
              }
          }
        _ -> found
      }
    // `register` is normally a statement, but it can sit inside an `if` guard
    // (`if register(...) is Result.Ok(a)`), so keep looking through the shapes
    // that can hold a call.
    ast.ECall(_, args) ->
      list.fold(args, found, fn(acc, a) {
        register_in_expr(a.value, fns, spawned, acc)
      })
    ast.EBinary(_, l, r) ->
      register_in_expr(r, fns, spawned, register_in_expr(l, fns, spawned, found))
    ast.EIs(value, _) | ast.EWith(value, _) | ast.EAwait(value, _) ->
      register_in_expr(value, fns, spawned, found)
    _ -> found
  }
}

// The message type of `hive.syslink.spawn(handler, state)`, read off the
// handler's own declaration.
fn spawn_msg_type(
  e: ast.Expr,
  fns: Dict(String, #(Bool, List(ast.Field), ast.TypeExpr)),
) -> Option(ast.TypeExpr) {
  case e {
    ast.ECall(
      ast.EMember(ast.EMember(ast.EIdent("hive"), "syslink"), "spawn"),
      args,
    ) ->
      case assign_args(args, ["handler", "state"]) {
        #([#(_, handler), #(_, _)], []) -> handler_msg_type(handler, fns)
        _ -> None
      }
    _ -> None
  }
}

/// The message type a spawn handler accepts: the second of the three
/// parameters the runtime fills (state, message, envelope).
pub fn handler_msg_type(
  handler: ast.Expr,
  fns: Dict(String, #(Bool, List(ast.Field), ast.TypeExpr)),
) -> Option(ast.TypeExpr) {
  case handler_params(handler, fns) {
    [_, msg, ..] -> Some(msg)
    _ -> None
  }
}

/// The parameters a handler expression leaves for the runtime to fill: all of
/// them for a bare name, and only the `_` holes for a partial application
/// (`inbox(_, _, _, db)`), which is what makes the shape check see through one.
pub fn handler_params(
  handler: ast.Expr,
  fns: Dict(String, #(Bool, List(ast.Field), ast.TypeExpr)),
) -> List(ast.TypeExpr) {
  case handler {
    ast.EIdent(name) ->
      case dict.get(fns, name) {
        Ok(#(_, params, _)) -> list.map(params, fn(p) { p.typ })
        Error(_) -> []
      }
    ast.ECall(ast.EIdent(name), args) ->
      case dict.get(fns, name) {
        Ok(#(_, params, _)) -> {
          let #(assigned, _) =
            assign_args(args, list.map(params, fn(p) { p.name }))
          list.zip(assigned, params)
          |> list.filter_map(fn(pair) {
            let #(#(_, expr), field) = pair
            case is_hole_expr(expr) {
              True -> Ok(field.typ)
              False -> Error(Nil)
            }
          })
        }
        Error(_) -> []
      }
    _ -> []
  }
}

/// The return type of a handler expression, for the shape check.
pub fn handler_ret(
  handler: ast.Expr,
  fns: Dict(String, #(Bool, List(ast.Field), ast.TypeExpr)),
) -> Option(ast.TypeExpr) {
  let name = case handler {
    ast.EIdent(n) -> Some(n)
    ast.ECall(ast.EIdent(n), _) -> Some(n)
    _ -> None
  }
  case name {
    Some(n) ->
      case dict.get(fns, n) {
        Ok(#(_, _, ret)) -> Some(ret)
        Error(_) -> None
      }
    None -> None
  }
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
        list.any(ast.sql_exprs(sql), uses_json_expr)
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
      ast.SAssert(e) | ast.SPanic(e) -> uses_json_expr(e)
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
    ast.EUsing(source, kind) ->
      uses_json_expr(source) || list.any(ast.using_exprs(kind), uses_json_expr)
    ast.EAwait(value, _) -> uses_json_expr(value)
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

// Records each user callable's purity, parameters and return type for
// first-class function support. A `proc` is impure; a `func`/`query` is pure.
fn collect_fns(
  decls: List(ast.Decl),
) -> Dict(String, #(Bool, List(ast.Field), ast.TypeExpr)) {
  list.fold(decls, dict.new(), fn(acc, d) {
    case d {
      ast.ProcDecl(name, params, ret, _) ->
        dict.insert(acc, name, #(False, params, ret))
      ast.FuncDecl(name, params, ret, _, _) ->
        dict.insert(acc, name, #(True, params, ret))
      ast.QueryDecl(name, params, ret, _) ->
        dict.insert(acc, name, #(True, params, ret))
      ast.TypeDecl(..) -> acc
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
// Atoms are collected in order of appearance. `#Nil` is the one atom the
// compiler provides, and it always occupies slot 0 — so it is the atom a
// program can name without declaring it, and the falsy one in boolean position.
// Everything else is an ordinary atom that exists only because the program
// mentioned it.

fn collect_atoms(module: ast.Module) -> List(String) {
  let found =
    list.fold(module.decls, [], fn(acc, d) {
      case d {
        ast.ProcDecl(_, _, _, body) | ast.FuncDecl(_, _, _, body, _) ->
          atoms_in_stmts(body, acc)
        ast.QueryDecl(_, _, _, sql) ->
          list.fold(ast.sql_exprs(sql), acc, fn(a, e) { atoms_in_expr(e, a) })
        ast.TypeDecl(..) -> acc
      }
    })
  let customs =
    found
    |> list.reverse
    |> list.filter(fn(name) { name != "Nil" })
  ["Nil", ..customs]
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
      ast.SAssert(e) | ast.SPanic(e) -> atoms_in_expr(e, acc)
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
    ast.EIs(subject, pattern) ->
      atoms_in_pattern(pattern, atoms_in_expr(subject, acc))
    ast.EUsing(source, kind) ->
      list.fold(ast.using_exprs(kind), atoms_in_expr(source, acc), fn(a, e) {
        atoms_in_expr(e, a)
      })
    ast.EWith(value, _) -> atoms_in_expr(value, acc)
    ast.EAwait(value, _) -> atoms_in_expr(value, acc)
  }
}

// Atom literals can appear as vector-pattern element literals (`v is [#Ok]`),
// which must still be registered in the program's atom table.
fn atoms_in_pattern(pattern: ast.Pattern, acc: List(String)) -> List(String) {
  case pattern {
    ast.PVector(elems, _) ->
      list.fold(elems, acc, fn(acc, e) {
        case e {
          ast.PElemLit(v) -> atoms_in_expr(v, acc)
          ast.PElemBind(_) -> acc
        }
      })
    ast.PConstructor(_, _) | ast.PString(_) -> acc
  }
}

fn atoms_in_opt(o: Option(ast.Expr), acc: List(String)) -> List(String) {
  case o {
    Some(e) -> atoms_in_expr(e, acc)
    None -> acc
  }
}

// Emits the atom constants and the init that registers the name table. When the
// program names no atom of its own, the runtime's default table (`#Nil` alone)
// suffices and nothing is emitted.
fn gen_atom_setup(table: List(String)) -> String {
  let customs = list.drop(table, 1)
  case customs {
    [] -> ""
    _ -> {
      let consts =
        customs
        |> list.index_map(fn(name, i) {
          "\tatom_" <> name <> " hive.Atom = " <> int.to_string(i + 1) <> "\n"
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

pub fn ty_of_type_expr(types: Dict(String, ast.Decl), t: ast.TypeExpr) -> Ty {
  case t {
    ast.TVoid -> TyUnknown
    // A builtin type, resolved only through its own namespace
    // (`hive.net.HttpRequest`, `hive.TableError`). A wrong or bare qualifier
    // does not resolve.
    ast.TName(Some(pkg), name, _, dims) ->
      case builtin_fields(name) {
        Some(_) ->
          case pkg == builtin_qualifier(name) {
            // An address written out in an annotation has no message type to
            // carry (there is no surface syntax for one), so it is the
            // unchecked form. An address that came from `spawn` or `at` keeps
            // the mailbox type inference gave it.
            True ->
              case name {
                "Address" -> wrap_dims(TyAddress(TyUnknown), dims)
                _ -> wrap_dims(TyBuiltin(name), dims)
              }
            False -> wrap_dims(TyUnknown, dims)
          }
        None -> wrap_dims(TyUnknown, dims)
      }
    // `Result<T, E>` is the one builtin whose arguments say what it holds.
    ast.TName(None, "Result", [ok, err], dims) ->
      wrap_dims(
        TyResult(ty_of_type_expr(types, ok), ty_of_type_expr(types, err)),
        dims,
      )
    ast.TName(None, name, _, dims) -> wrap_dims(base_ty(types, name), dims)
    ast.TFunc(pure, params, ret) ->
      TyFunc(
        pure,
        list.map(params, fn(p) { ty_of_type_expr(types, p) }),
        fn_ret_ty(types, ret),
      )
  }
}

// A function type's return, keeping `void` distinct (so a `proc(T): void` value
// lowers to `func(T)` with no Go return) rather than collapsing it to unknown.
fn fn_ret_ty(types: Dict(String, ast.Decl), ret: ast.TypeExpr) -> Ty {
  case ret {
    ast.TVoid -> TyVoid
    _ -> ty_of_type_expr(types, ret)
  }
}

// Whether a type qualifier names the `hive` standard library (`hive`,
// `hive.net`, `hive.sql`, ...).
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
        // Neither builtin nor declared: a type variable. This is exactly the
        // notation the builtin table has always used — `indexOf(T[], T)`.
        False -> TyVar(name)
      }
  }
}

fn wrap_dims(base: Ty, dims: List(ast.Dim)) -> Ty {
  list.fold(dims, base, fn(t, _) { TyVec(t) })
}

fn gen_type(t: ast.TypeExpr) -> String {
  case t {
    ast.TVoid -> ""
    ast.TFunc(_, params, ret) -> {
      let ps = params |> list.map(gen_type) |> string.join(", ")
      let r = case ret {
        ast.TVoid -> ""
        _ -> " " <> gen_type(ret)
      }
      "func(" <> ps <> ")" <> r
    }
    // `Result<T, E>` lowers to the runtime's generic struct.
    ast.TName(None, "Result", [ok, err], dims) ->
      string.repeat("[]", list.length(dims))
      <> "hive.Result["
      <> gen_type(ok)
      <> ", "
      <> gen_type(err)
      <> "]"
    // Every other type argument is substituted away by monomorphization, so
    // nothing else reaches codegen still carrying one.
    ast.TName(pkg, name, _, dims) -> {
      let prefix = string.repeat("[]", list.length(dims))
      let base = case pkg {
        // A `hive.<module>` namespace is only organisational: every builtin
        // type lives in the one Go `hive` package (`hive.net.HttpRequest`
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
    TyResult(ok, err) ->
      "hive.Result[" <> ty_to_go(ok) <> ", " <> ty_to_go(err) <> "]"
    TyFunc(_, params, ret) -> {
      let ps = params |> list.map(ty_to_go) |> string.join(", ")
      let r = case ret {
        TyVoid -> ""
        _ -> " " <> ty_to_go(ret)
      }
      "func(" <> ps <> ")" <> r
    }
    TyVoid -> ""
    TyUnknown -> "any"
    // Monomorphization substitutes every variable before codegen runs, so one
    // reaching here would be a compiler bug rather than a program error.
    TyVar(name) -> name
    TyAsync(inner) -> "*hive.Async[" <> async_inner_go(inner) <> "]"
    TyAddress(_) -> "hive.Address"
    TyPending(msg) -> "*hive.SyslinkPending[" <> async_inner_go(msg) <> "]"
  }
}

// An inferred type written the way Hive source spells it, for error messages.
// The types with no surface syntax (a task handle, a service address) say what
// they are in words instead, since there is nothing to quote.
fn show_ty(ty: Ty) -> String {
  case ty {
    TyStr -> "Str"
    TyInt -> "Int"
    TyFloat -> "Float"
    TyBool -> "Bool"
    TyAtom -> "Atom"
    TyTable -> "Table"
    TyVoid -> "void"
    TyCustom(name) -> name
    TyBuiltin(name) -> builtin_qualifier(name) <> "." <> name
    TyVec(elem) -> show_ty(elem) <> "[]"
    TyResult(ok, err) -> "Result<" <> show_ty(ok) <> ", " <> show_ty(err) <> ">"
    TyFunc(pure, params, ret) ->
      case pure {
        True -> "func("
        False -> "proc("
      }
      <> string.join(list.map(params, show_ty), ", ")
      <> "): "
      <> show_ty(ret)
    TyAsync(inner) -> "async " <> show_ty(inner)
    TyAddress(_) -> "a service address"
    TyPending(_) -> "a request in flight"
    TyVar(name) -> name
    TyUnknown -> "value of no known type"
  }
}

fn plural(n: Int, word: String) -> String {
  case n {
    1 -> word
    _ -> word <> "s"
  }
}

// The Go spelling of a task's result type. A void `async func` yields no value,
// so its handle carries `hive.Unit` (an empty struct) — awaited only to join on
// its completion.
fn async_inner_go(inner: Ty) -> String {
  case inner {
    TyVoid -> "hive.Unit"
    _ -> ty_to_go(inner)
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

// `force` is set when something other than `hive.json` needs the derived
// codecs: a syslink program encodes messages with exactly the ones a type
// declaration already produces, even if it never mentions `hive.json` itself.
fn gen_json_support(env: Env, module: ast.Module, force: Bool) -> String {
  case force || uses_json_module(module) {
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
    // A service address travels inside a message, so it needs a codec of its
    // own: it is the one builtin whose value means something on another node.
    ast.TName(Some("hive.syslink"), "Address", _, []) -> "hive.JsonAddress"
    ast.TName(None, name, _, []) ->
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
    ast.TName(pkg, name, args, [dim, ..rest]) -> {
      let inner = ast.TName(pkg, name, args, rest)
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

pub fn fn_env(env: Env, params: List(ast.Field), ret: ast.TypeExpr) -> Env {
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
// A query lowers to a Go function returning the SQL text and the values its
// placeholders bind to. Nothing a caller supplies ever enters the text — an
// interpolation becomes a `?` and the value joins the argument slice — so a
// query cannot be made to mean something other than what it says.
//
// A `where { ... }` block is built at runtime from the predicates whose
// conditions hold, which is why the body is statements rather than one
// expression.
fn gen_query_decl(
  env: Env,
  name: String,
  params: List(ast.Field),
  ret: ast.TypeExpr,
  sql: List(ast.SqlPart),
) -> String {
  let env = fn_env(env, params, ret)
  let param_str =
    params
    |> list.map(fn(p) { escape_ident(p.name) <> " " <> gen_type(p.typ) })
    |> string.join(", ")
  let #(body, _) = gen_sql_parts(env, sql, 1, 0)
  "func "
  <> escape_ident(name)
  <> "("
  <> param_str
  <> ") hive.SqlFragment {\n\t_sql := \"\"\n\t_args := []any{}\n"
  <> body
  <> "\treturn hive.SqlFragment{Text: _sql, Args: _args}\n}\n"
}

// Statements appending each piece to `_sql` / `_args`. `n` numbers the
// temporaries so nested groups do not collide.
fn gen_sql_parts(
  env: Env,
  parts: List(ast.SqlPart),
  indent: Int,
  n: Int,
) -> #(String, Int) {
  let pad = tabs(indent)
  list.fold(parts, #("", n), fn(acc, part) {
    let #(code, n) = acc
    case part {
      ast.SqlLit(text) -> #(code <> pad <> "_sql += " <> gen_string_lit(text) <> "\n", n)
      ast.SqlParam(e) -> #(
        code
        <> pad
        <> "_sql += \"?\"\n"
        <> pad
        <> "_args = append(_args, "
        <> gen_expr(env, e)
        <> ")\n",
        n,
      )
      ast.SqlWhere(group) -> {
        let frag = "_w" <> int.to_string(n)
        let #(build, n2) = gen_sql_group(env, group, indent, n + 1, frag)
        #(
          code
          <> build
          <> pad
          <> "if "
          <> frag
          <> ".Text != \"\" {\n"
          <> pad
          <> "\t_sql += \" WHERE \" + "
          <> frag
          <> ".Text\n"
          <> pad
          <> "\t_args = append(_args, "
          <> frag
          <> ".Args...)\n"
          <> pad
          <> "}\n",
          n2,
        )
      }
    }
  })
}

// Collects a group's present predicates into one fragment. A group that
// contributes nothing yields empty text, so it disappears rather than leaving a
// dangling connective; one that contributes more than one predicate is
// parenthesised, so nesting cannot change how the surrounding connective binds.
fn gen_sql_group(
  env: Env,
  group: ast.SqlGroup,
  indent: Int,
  n: Int,
  into: String,
) -> #(String, Int) {
  let pad = tabs(indent)
  let acc = "_p" <> int.to_string(n)
  let #(items, n2) =
    list.fold(group.items, #("", n + 1), fn(state, item) {
      let #(code, n) = state
      case item {
        ast.SqlCond(cond, body) -> {
          let #(cond_str, _) = gen_condition(env, cond)
          let #(text, args, n2) = gen_predicate(env, body, n)
          #(
            code
            <> pad
            <> "if "
            <> cond_str
            <> " {\n"
            <> pad
            <> "\t"
            <> acc
            <> " = append("
            <> acc
            <> ", hive.SqlFragment{Text: "
            <> text
            <> ", Args: []any{"
            <> args
            <> "}})\n"
            <> pad
            <> "}\n",
            n2,
          )
        }
        ast.SqlNested(inner) -> {
          let frag = "_w" <> int.to_string(n)
          let #(build, n2) = gen_sql_group(env, inner, indent, n + 1, frag)
          #(
            code
            <> build
            <> pad
            <> "if "
            <> frag
            <> ".Text != \"\" {\n"
            <> pad
            <> "\t"
            <> acc
            <> " = append("
            <> acc
            <> ", "
            <> frag
            <> ")\n"
            <> pad
            <> "}\n",
            n2,
          )
        }
      }
    })
  let sep = case group.conjunction {
    True -> "\" AND \""
    False -> "\" OR \""
  }
  // The outermost group is the WHERE clause itself, so it needs no parentheses.
  let paren = case string.starts_with(into, "_w0") {
    True -> "false"
    False -> "true"
  }
  #(
    pad
    <> acc
    <> " := []hive.SqlFragment{}\n"
    <> items
    <> pad
    <> into
    <> " := hive.SqlJoin("
    <> acc
    <> ", "
    <> sep
    <> ", "
    <> paren
    <> ")\n",
    n2,
  )
}

// One predicate's text and the values it binds, as two Go expressions.
fn gen_predicate(
  env: Env,
  body: List(ast.SqlPart),
  n: Int,
) -> #(String, String, Int) {
  let texts =
    list.filter_map(body, fn(part) {
      case part {
        ast.SqlLit(t) -> Ok(gen_string_lit(t))
        ast.SqlParam(_) -> Ok("\"?\"")
        ast.SqlWhere(_) -> Error(Nil)
      }
    })
  let args =
    list.filter_map(body, fn(part) {
      case part {
        ast.SqlParam(e) -> Ok(gen_expr(env, e))
        _ -> Error(Nil)
      }
    })
  let text = case texts {
    [] -> "\"\""
    _ -> string.join(texts, " + ")
  }
  #(text, string.join(args, ", "), n)
}

// Go requires every path of a non-void function to return. Hive relies on
// exhaustiveness analysis the compiler doesn't fully model here, so any
// function that doesn't syntactically end in a `return` gets an explicit
// `panic` to satisfy the Go compiler (it is genuinely unreachable at runtime).
fn gen_terminator(body: List(ast.Stmt)) -> String {
  case list.last(body) {
    // A body already ending in `return` or `panic` terminates on its own, so no
    // fallback is needed.
    Ok(ast.SReturn(_)) | Ok(ast.SPanic(_)) -> ""
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
      case shares_storage(env, ty, mutable, value) {
        // Shared mutable state: the name *is* the source, so no variable of its
        // own and nothing to keep in step.
        True -> #("", share_env(env, name, ty, mutable, value))
        False -> {
          let #(rhs, shared) =
            bind_rhs(
              env,
              ty,
              Some(name),
              mutable,
              value,
              gen_expr(env, value),
              following,
            )
          let decl = pad <> escape_ident(name) <> " := " <> rhs <> "\n"
          let env2 =
            Env(
              ..env,
              locals: dict.insert(env.locals, name, ty),
              muts: dict.insert(env.muts, name, mutable),
              aliased: record_alias(env, name, value, shared),
            )
          #(decl <> guard(following, name, pad), env2)
        }
      }
    }
    ast.STypedDecl(typ, name, value, mutable) -> {
      let ty = ty_of_type_expr(env.types, typ)
      case shares_storage(env, ty, mutable, value) {
        True -> #("", share_env(env, name, ty, mutable, value))
        False -> {
          let #(rhs, shared) =
            bind_rhs(
              env,
              ty,
              Some(name),
              mutable,
              value,
              coerce(env, value, ty),
              following,
            )
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
              aliased: record_alias(env, name, value, shared),
            )
          #(decl <> guard(following, name, pad), env2)
        }
      }
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
    // `panic value` renders the value the same way `echo` does (via
    // hive.Show), then aborts.
    ast.SPanic(e) -> #(
      pad <> "panic(hive.Show(" <> gen_expr(env, e) <> "))\n",
      env,
    )
    ast.SBreak -> #(pad <> "break\n", env)
    ast.SContinue -> #(pad <> "continue\n", env)
    ast.SAssign(target, value) -> {
      let ty = infer(env, target)
      // A whole-variable reassignment (`b = a`) rebinds `b`, so it follows the
      // same copy rule as a declaration — the target is mutable by definition,
      // since only `mut` variables can be assigned. An element/field
      // assignment (`v[i] = ...`) writes into existing storage and never copies.
      let rendered = coerce(env, value, ty)
      let #(rhs, aliased2) = case target {
        ast.EIdent(n) -> {
          let #(r, shared) =
            bind_rhs(env, ty, Some(n), True, value, rendered, following)
          #(r, record_alias(env, n, value, shared))
        }
        _ -> #(rendered, env.aliased)
      }
      #(
        pad <> gen_expr(env, target) <> " = " <> rhs <> "\n",
        Env(..env, aliased: aliased2),
      )
    }
    // `append(v, x)` used as a statement mutates `v` in place, which Go models
    // by reassigning the (possibly reallocated) slice back to `v`. The callee is
    // the qualified builtin, which is what a bare `append` became unless the
    // program declared its own (see `hive/builtins`).
    ast.SExpr(ast.ECall(ast.EMember(ast.EIdent("hive"), "append"), args)) -> {
      let target = case args {
        [ast.Arg(_, t), ..] -> gen_expr(env, t)
        [] -> "_"
      }
      #(pad <> target <> " = " <> gen_append(env, args) <> "\n", env)
    }
    // An address called as a bare statement wants no answer, so it lowers to the
    // cast: nothing is registered for a reply and nothing can be awaited. The
    // same call keeping its value is a request instead — the call site decides,
    // just as it does for an `async func` below.
    //
    // A bare call to an `async func` as a statement is fire-and-forget: run it
    // on its own goroutine and discard the result. `go f(x)` is the cheapest
    // lowering (no handle, no channel) — the `hive.Spawn` handle form is only
    // needed when the result is kept (an RHS, a vector element).
    ast.SExpr(ast.ECall(callee, args) as call) ->
      case is_address_call(env, callee), callee {
        True, _ -> #(
          pad <> gen_address_send(env, callee, args, False) <> "\n",
          env,
        )
        False, ast.EIdent(name) ->
          case list.contains(env.asyncs, name) {
            True -> #(
              pad <> "go " <> gen_call(env, ast.EIdent(name), args) <> "\n",
              env,
            )
            False -> #(pad <> gen_expr(env, call) <> "\n", env)
          }
        False, _ -> #(pad <> gen_expr(env, call) <> "\n", env)
      }
    ast.SExpr(e) -> #(pad <> gen_expr(env, e) <> "\n", env)
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

// The environment after a sharing binding: the new name renders as the source's
// lvalue, and both ends are recorded as having a live mutable alias so neither
// can later be *moved* into an immutable binding.
fn share_env(
  env: Env,
  name: String,
  ty: Ty,
  mutable: Bool,
  value: ast.Expr,
) -> Env {
  Env(
    ..env,
    locals: dict.insert(env.locals, name, ty),
    muts: dict.insert(env.muts, name, mutable),
    aliased: record_alias(env, name, value, True),
    renames: dict.insert(env.renames, name, gen_expr(env, value)),
  )
}

// Generates the inline Go for a for-loop's init or post clause (no leading
// indentation, no trailing newline — it sits inside the `for ( ; ; )` header)
// and threads any variable it declares into the returned environment.
fn gen_for_clause(env: Env, stmt: ast.Stmt) -> #(String, Env) {
  case stmt {
    // A loop-init binding is implicitly mutable (the post clause advances it).
    ast.SVarDecl(name, value, _) -> {
      let ty = infer(env, value)
      let rhs = bind_rhs_noscope(env, ty, True, value, gen_expr(env, value))
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
      let rhs = bind_rhs_noscope(env, ty, True, value, coerce(env, value, ty))
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
        ast.EIdent(_) -> bind_rhs_noscope(env, ty, True, value, rendered)
        _ -> rendered
      }
      #(gen_expr(env, target) <> " = " <> rhs, env)
    }
    // `append(v, x)` advances a mutable vector, reassigning the result back.
    ast.SExpr(ast.ECall(ast.EMember(ast.EIdent("hive"), "append"), args)) -> {
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
pub fn elem_ty_of(ty: Ty) -> Ty {
  case ty {
    TyVec(t) -> t
    TyTable -> TyVec(TyStr)
    _ -> TyUnknown
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

// A subject that does work — a call, a `using` read, an `await` — is read once
// to test it and again for every value the pattern binds, so it has to be
// evaluated into a temporary first. Go's `if` has exactly one init slot for that,
// which serves the leftmost test; when a test further right needs one too, one
// slot is not enough, and the operands cannot all be hoisted ahead of the `if`
// either — `&&` short-circuits, so a later subject must not run unless the
// earlier tests held.
//
// Both forms are emitted, and the flat one is chosen whenever it suffices, which
// is nearly always.
fn gen_if(
  env: Env,
  branches: List(ast.Branch),
  else_body: Option(List(ast.Stmt)),
  indent: Int,
) -> String {
  case branches {
    [] ->
      case else_body {
        Some(body) -> gen_stmts(env, body, indent)
        None -> ""
      }
    _ ->
      case list.any(branches, fn(b) { needs_nesting(b.cond) }) {
        False -> gen_if_flat(env, branches, else_body, indent)
        True -> gen_if_nested(env, branches, else_body, indent)
      }
  }
}

// The `&&`-separated tests of a condition, left to right. Only `&&` splits one:
// an `||` operand may or may not run, and no binding escapes one anyway.
fn and_spine(cond: ast.Expr) -> List(ast.Expr) {
  case cond {
    ast.EBinary(ast.OpAnd, l, r) ->
      list.append(and_spine(l), and_spine(r))
    _ -> [cond]
  }
}

// Whether a condition needs a temporary anywhere but its leftmost test — the one
// place the flat form can put one.
fn needs_nesting(cond: ast.Expr) -> Bool {
  case and_spine(cond) {
    [] | [_] -> False
    [_, ..rest] -> list.any(rest, fn(t) { hoistable_subject(t) != None })
  }
}

// One nested `if` per `&&`-separated test, each with an init slot of its own.
// Nesting reproduces the short-circuit exactly, and it turns every pattern's
// bindings into ordinary variables that the tests to their right — and the body —
// read like any other local.
//
// What nesting costs is the `else`: a chain that fails part-way falls out of the
// middle rather than off the end, so anything that has to run when the whole
// condition was false hangs off a flag the innermost body sets.
fn gen_if_nested(
  env: Env,
  branches: List(ast.Branch),
  else_body: Option(List(ast.Stmt)),
  indent: Int,
) -> String {
  let pad = tabs(indent)
  case branches {
    [] ->
      case else_body {
        Some(body) -> gen_stmts(env, body, indent)
        None -> ""
      }
    [b, ..rest] -> {
      // A flag is only needed when something has to run on the false path.
      let has_tail = rest != [] || else_body != None
      let flag = "_m" <> int.to_string(indent)
      let #(open, benv, depth) =
        gen_nested_tests(env, and_spine(b.cond), b.body, indent, 0)
      let inner = tabs(indent + depth)
      let head = case has_tail {
        True -> pad <> flag <> " := false\n"
        False -> ""
      }
      let set = case has_tail {
        True -> inner <> flag <> " = true\n"
        False -> ""
      }
      let tail = case has_tail {
        True ->
          pad
          <> "if !"
          <> flag
          <> " {\n"
          <> gen_if(env, rest, else_body, indent + 1)
          <> pad
          <> "}\n"
        False -> ""
      }
      head
      <> open
      <> set
      <> gen_stmts(benv, b.body, indent + depth)
      <> close_braces(indent, depth)
      <> tail
    }
  }
}

fn gen_nested_tests(
  env: Env,
  tests: List(ast.Expr),
  body: List(ast.Stmt),
  indent: Int,
  level: Int,
) -> #(String, Env, Int) {
  case tests {
    [] -> #("", env, level)
    [t, ..rest] -> {
      let pad = tabs(indent + level)
      let #(init, hoisted) = case hoistable_subject(t) {
        Some(subject) -> {
          let name =
            "_u" <> int.to_string(indent) <> "_" <> int.to_string(level)
          #(name <> " := " <> gen_expr(env, subject) <> "; ", Some(name))
        }
        None -> #("", None)
      }
      let #(cond_str, binds) = gen_condition_as(env, t, hoisted)
      let open =
        pad
        <> "if "
        <> init
        <> cond_str
        <> " {\n"
        <> gen_bindings(binds, body, indent + level + 1)
      let #(more, fenv, depth) =
        gen_nested_tests(bind_locals(env, binds), rest, body, indent, level + 1)
      #(open <> more, fenv, depth)
    }
  }
}

// The closing braces for `depth` nested `if`s opened at `indent`, innermost
// first.
fn close_braces(indent: Int, depth: Int) -> String {
  case depth {
    0 -> ""
    _ -> tabs(indent + depth - 1) <> "}\n" <> close_braces(indent, depth - 1)
  }
}

fn gen_if_flat(
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
      // A subject that does work — a call, a `using` read, an `await` — is read
      // once to test it and again for every value the pattern binds, so it is
      // evaluated into the `if`'s own init statement instead of being repeated.
      // Only the leftmost test can move there: whether anything further right
      // runs at all depends on what came before it.
      let #(init, hoisted) = case hoistable_subject(b.cond) {
        Some(subject) -> {
          let name =
            "_u" <> int.to_string(indent) <> "_" <> int.to_string(i)
          #(name <> " := " <> gen_expr(env, subject) <> "; ", Some(name))
        }
        None -> #("", None)
      }
      let #(cond_str, binds) = gen_condition_as(env, b.cond, hoisted)
      let benv = bind_locals(env, binds)
      opener
      <> init
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
// The leftmost test's subject when it must not be evaluated twice.
fn hoistable_subject(cond: ast.Expr) -> Option(ast.Expr) {
  case leftmost_test(cond) {
    ast.EIs(subject, _) ->
      case ast.repeatable(subject) {
        True -> None
        False -> Some(subject)
      }
    _ -> None
  }
}

// An `&&` only reaches its right side once the left has held, so the left-hand
// spine is the part of a condition that always runs.
fn leftmost_test(cond: ast.Expr) -> ast.Expr {
  case cond {
    ast.EBinary(ast.OpAnd, left, _) -> leftmost_test(left)
    _ -> cond
  }
}

// As `gen_condition`, but `held` names the temporary the leftmost test's subject
// has already been evaluated into.
fn gen_condition_as(
  env: Env,
  cond: ast.Expr,
  held: Option(String),
) -> #(String, List(Bind)) {
  case cond, held {
    ast.EIs(subject, pattern), Some(name) ->
      gen_is_as(env, subject, name, pattern)
    ast.EBinary(ast.OpAnd, l, r), Some(_) -> {
      let #(lc, lb) = gen_condition_as(env, l, held)
      let #(rc, rb) = gen_condition(bind_subst(env, lb), r)
      #("(" <> lc <> ") && (" <> rc <> ")", list.append(lb, rb))
    }
    _, _ -> gen_condition(env, cond)
  }
}

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
    // An atom is not a condition (see `check_condition`), so by the time codegen
    // runs there is nothing left to coerce.
    _ -> #(gen_expr(env, cond), [])
  }
}

fn gen_is(
  env: Env,
  subject: ast.Expr,
  pattern: ast.Pattern,
) -> #(String, List(Bind)) {
  gen_is_as(env, subject, gen_expr(env, subject), pattern)
}

// `subj` is the Go expression the subject reads as — normally the subject itself,
// but the name of a temporary when it was too costly (or too observable) to
// evaluate more than once.
fn gen_is_as(
  env: Env,
  subject: ast.Expr,
  subj: String,
  pattern: ast.Pattern,
) -> #(String, List(Bind)) {
  // Result payload types come from the subject's inferred TyResult (e.g.
  // `using` -> Result<Table, TableError>, `hive.net.httpRequest` ->
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
    ast.PConstructor(_, _) -> #(subj, [])
    ast.PVector(elems, rest) -> gen_vector_is(env, subject, subj, elems, rest)
    ast.PString(parts) -> gen_string_is(subj, parts)
  }
}

// `v is ["a", x, ...tail]` — a length check plus element-wise checks, with
// element and tail bindings introduced in the branch body. Each literal
// element reuses the ordinary equality lowering (so string/number/atom and
// nested-vector literals each compare correctly); each named element binds
// `v[i]` and a trailing `...tail` binds the reslice `v[n:]`. Like every other
// `is`-binding these alias the subject's storage rather than copying it, which
// is sound because bindings are immutable.
fn gen_vector_is(
  env: Env,
  subject: ast.Expr,
  subj: String,
  elems: List(ast.PatElem),
  rest: Option(String),
) -> #(String, List(Bind)) {
  let vec_ty = infer(env, subject)
  let elem_ty = case vec_ty {
    TyVec(t) -> t
    TyTable -> TyVec(TyStr)
    _ -> TyUnknown
  }
  let n = list.length(elems)
  let len_conds = case rest, n {
    // A fixed-length pattern matches only a vector of exactly that length.
    None, _ -> ["len(" <> subj <> ") == " <> int.to_string(n)]
    // `[...tail]` (a bare rest) accepts any vector, so no length check.
    Some(_), 0 -> []
    // `[a, b, ...tail]` needs at least the fixed elements present.
    Some(_), _ -> ["len(" <> subj <> ") >= " <> int.to_string(n)]
  }
  let #(elem_conds, elem_binds) =
    elems
    |> list.index_map(fn(elem, i) { #(elem, i) })
    |> list.fold(#([], []), fn(acc, pair) {
      let #(conds, binds) = acc
      let #(elem, i) = pair
      case elem {
        ast.PElemLit(lit) -> {
          let c =
            gen_equality(env, ast.EIndex(subject, ast.EInt(i)), lit, True)
          #([c, ..conds], binds)
        }
        ast.PElemBind("_") -> #(conds, binds)
        ast.PElemBind(name) -> #(conds, [
          #(name, subj <> "[" <> int.to_string(i) <> "]", elem_ty),
          ..binds
        ])
      }
    })
  let rest_binds = case rest {
    Some("_") | None -> []
    Some(name) -> [#(name, subj <> "[" <> int.to_string(n) <> ":]", vec_ty)]
  }
  let conds = list.append(len_conds, list.reverse(elem_conds))
  let cond = case conds {
    [] -> "true"
    _ -> string.join(conds, " && ")
  }
  #(cond, list.append(list.reverse(elem_binds), rest_binds))
}

// `path is "/api/{id}/{name}/delete"` — a string template match. With no holes
// it is a plain equality; with holes it lowers to `hive.MatchPattern`, which
// returns the captures (nil on no match). Each named hole reads its capture
// back out. The match is recomputed once per binding rather than stashed in a
// temp — it is a pure function of the subject, so this is sound, and real
// patterns hold a handful of holes over short strings.
fn gen_string_is(subj: String, parts: List(ast.StrPat)) -> #(String, List(Bind)) {
  let #(prefix, holes) = split_string_pattern(parts)
  case holes {
    [] -> #(subj <> " == " <> gen_string_lit(prefix), [])
    _ -> {
      let seps_go =
        "[]string{"
        <> string.join(list.map(holes, fn(h) { gen_string_lit(h.1) }), ", ")
        <> "}"
      let match_call =
        "hive.MatchPattern("
        <> subj
        <> ", "
        <> gen_string_lit(prefix)
        <> ", "
        <> seps_go
        <> ")"
      let binds =
        holes
        |> list.index_map(fn(h, i) { #(h.0, i) })
        |> list.filter(fn(pair) { pair.0 != "_" })
        |> list.map(fn(pair) {
          let #(name, i) = pair
          #(name, match_call <> "[" <> int.to_string(i) <> "]", TyStr)
        })
      #(match_call <> " != nil", binds)
    }
  }
}

// Splits a string pattern into its leading literal prefix and, for each hole in
// order, the literal that terminates it — `""` for a hole that runs to the end
// of the string. The parts always alternate literal/hole (the lexer merges
// adjacent literal text and the parser rejects adjacent holes), so a hole is
// followed either by its separator literal or by the end of the pattern.
fn split_string_pattern(
  parts: List(ast.StrPat),
) -> #(String, List(#(String, String))) {
  case parts {
    [ast.SPatLit(s), ..rest] -> #(s, collect_holes(rest, []))
    _ -> #("", collect_holes(parts, []))
  }
}

fn collect_holes(
  parts: List(ast.StrPat),
  acc: List(#(String, String)),
) -> List(#(String, String)) {
  case parts {
    [ast.SPatHole(name), ast.SPatLit(sep), ..rest] ->
      collect_holes(rest, [#(name, sep), ..acc])
    [ast.SPatHole(name), ..rest] -> collect_holes(rest, [#(name, ""), ..acc])
    // A literal that does not follow a hole cannot occur given the parser's
    // guarantees; skip it to stay total.
    [ast.SPatLit(_), ..rest] -> collect_holes(rest, acc)
    [] -> list.reverse(acc)
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

pub fn infer(env: Env, e: ast.Expr) -> Ty {
  case e {
    ast.EInt(_) -> TyInt
    ast.EFloat(_) -> TyFloat
    ast.EString(_) -> TyStr
    ast.EInterp(_) -> TyStr
    // `true`/`false` are Bool literals (Go booleans), never atoms.
    ast.EBool(_) -> TyBool
    ast.EAtom(_) -> TyAtom
    ast.EIdent(name) ->
      case dict.get(env.locals, name) {
        Ok(ty) -> ty
        // A bare reference to a user callable is a function value.
        Error(_) ->
          case dict.get(env.fns, name) {
            Ok(#(pure, params, ret)) ->
              TyFunc(
                pure,
                list.map(params, fn(p) { ty_of_type_expr(env.types, p.typ) }),
                fn_ret_ty(env.types, ret),
              )
            Error(_) -> TyUnknown
          }
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
    // Calling an address is a request in flight, whose answer is the mailbox's
    // own type. Discarded as a statement it is a cast, which never reaches
    // `infer`. The address test comes first so an address-typed local wins over
    // a func of the same name, matching how a local shadows a declaration
    // everywhere else.
    ast.ECall(callee, args) ->
      case address_call_msg(env, callee) {
        Some(_) ->
          case address_call_arg(args) {
            Some(message) -> TyPending(syslink_reply_ty(env, callee, message))
            None -> TyPending(TyUnknown)
          }
        None -> infer_plain_call(env, callee, args)
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
    // Each `using` form names what it reads, so its result type is fixed: a CSV
    // is one Table, a spreadsheet is one per sheet, and a query's failures come
    // from the database rather than the filesystem.
    ast.EUsing(_, kind) ->
      case kind {
        ast.UsingCsv(_) -> TyResult(TyTable, TyBuiltin("TableError"))
        ast.UsingXlsx | ast.UsingOds ->
          TyResult(TyVec(TyTable), TyBuiltin("TableError"))
        // A typed query's rows are whatever it declared them to be; a raw one
        // has no declaration to consult, so it stays a Table.
        ast.UsingQuery(q) ->
          case query_rows(env, q) {
            RowsNone -> TyResult(TyInt, TyBuiltin("SqlError"))
            RowsOf(elem) -> TyResult(TyVec(elem), TyBuiltin("SqlError"))
          }
        ast.UsingRaw(_) -> TyResult(TyTable, TyBuiltin("SqlError"))
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
    // `await` resolves a task to its value: a handle `async T` yields `T`, and
    // a vector of handles `(async T)[]` yields `T[]` (a barrier over all of
    // them). A direct `await asyncCall()` infers `TyAsync(T)` for the inner
    // call and so lands on the same `TyAsync(t) -> t` rule.
    ast.EAwait(value, timeout) ->
      case infer(env, value), timeout {
        // A syslink request answers with a Result either way; a bound on the
        // wait only adds a reason to its error, never a second Result around it.
        TyPending(m), _ -> TyResult(m, TyBuiltin("SyslinkError"))
        TyVec(TyPending(m)), _ ->
          TyVec(TyResult(m, TyBuiltin("SyslinkError")))
        // Bounding the wait on a plain task is what gives it a failure case at
        // all, so the type gains a Result exactly when the clause is written.
        TyAsync(t), Some(_) -> TyResult(t, TyBuiltin("TimeoutError"))
        TyAsync(t), None -> t
        TyVec(TyAsync(t)), Some(_) ->
          TyResult(TyVec(t), TyBuiltin("TimeoutError"))
        TyVec(TyAsync(t)), None -> TyVec(t)
        other, _ -> other
      }
  }
}

// The type of an ordinary call: a builtin, a type constructor, a func-valued
// local, a declared proc/func, or a member of a stdlib namespace. Calling a
// service address is none of these, and `infer` has already settled that case
// before anything reaches here.
fn infer_plain_call(env: Env, callee: ast.Expr, args: List(ast.Arg)) -> Ty {
  // A global builtin arrives written out as `hive.<name>` (see `hive/builtins`),
  // so this is the whole of it: a bare name below is the program's own.
  case builtins.called(callee) {
    Some(name) -> infer_global_builtin(env, name, args)
    None -> infer_other_call(env, callee, args)
  }
}

fn infer_global_builtin(env: Env, name: String, args: List(ast.Arg)) -> Ty {
  case name {
    "len" | "bytes" -> TyInt
    "join" -> TyStr
    "split" | "row" | "column" -> TyVec(TyStr)
    // `indexOf` yields the position it found, or an Error carrying `false`
    // (there is nothing to say about a miss beyond that it missed).
    "indexOf" -> TyResult(TyInt, TyBool)
    // `append` yields a vector of the same type as its first argument.
    "append" ->
      case args {
        [ast.Arg(_, first), ..] -> infer(env, first)
        [] -> TyUnknown
      }
    "map" | "filter" | "filterMap" -> walk_builtin_ty(env, name, args)
    // `print` and `println` are void statements.
    _ -> TyVoid
  }
}

fn infer_other_call(env: Env, callee: ast.Expr, args: List(ast.Arg)) -> Ty {
  case callee {
    ast.EIdent(name) -> infer_ident_call(env, name, args)
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
            "net" ->
              case fname {
                "httpRequest" ->
                  TyResult(TyBuiltin("HttpResponse"), TyBuiltin("HttpError"))
                "wsConnect" ->
                  TyResult(TyBuiltin("WsConnection"), TyBuiltin("WsError"))
                // The Ok payload of a send is the byte count it carried.
                "wsSend" -> TyResult(TyInt, TyBuiltin("WsError"))
                "wsReceive" -> TyResult(TyStr, TyBuiltin("WsError"))
                "wsRequest" -> TyBuiltin("HttpRequest")
                "socketConnect" ->
                  TyResult(
                    TyBuiltin("SocketConnection"),
                    TyBuiltin("SocketError"),
                  )
                "socketSend" -> TyResult(TyInt, TyBuiltin("SocketError"))
                "socketReceive" | "socketReceiveLine" ->
                  TyResult(TyStr, TyBuiltin("SocketError"))
                "socketPeer" -> TyStr
                // A name stands for however many addresses are behind it, so
                // the vector is the honest answer even when there is one.
                "resolve" -> TyResult(TyVec(TyStr), TyBuiltin("NetError"))
                "localAddress" -> TyResult(TyStr, TyBuiltin("NetError"))
                _ -> TyUnknown
              }
            "file" ->
              case fname {
                "read" -> TyResult(TyStr, TyBuiltin("FileError"))
                "lines" | "list" ->
                  TyResult(TyVec(TyStr), TyBuiltin("FileError"))
                "write" | "append" | "size" | "copy" ->
                  TyResult(TyInt, TyBuiltin("FileError"))
                "delete" | "makeDir" | "move" ->
                  TyResult(TyBool, TyBuiltin("FileError"))
                "exists" -> TyBool
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
            "term" ->
              case fname {
                "read" -> TyStr
                "args" -> TyVec(TyStr)
                // `print` is a void statement.
                _ -> TyVoid
              }
            "task" ->
              case fname {
                // `sleep` is a void statement.
                _ -> TyVoid
              }
            "syslink" ->
              case fname {
                // A spawned service's address carries the type of the
                // mailbox behind it, read off the handler it was given.
                "spawn" ->
                  case assign_args(args, ["handler", "state"]) {
                    #([#(_, handler), _], []) ->
                      TyAddress(handler_msg_ty(env, handler))
                    _ -> TyAddress(TyUnknown)
                  }
                // Neither `at` nor `on` needs a `with`: the service name is
                // an atom, so the registry that answers "what does this
                // mailbox take?" is known at compile time. The node is just
                // an endpoint and tells the compiler nothing, which is
                // exactly why it does not need to be an atom.
                "at" ->
                  case assign_args(args, ["name"]) {
                    #([#(_, ast.EAtom(name))], []) ->
                      registered_address(env, name)
                    _ -> TyAddress(TyUnknown)
                  }
                "on" ->
                  case assign_args(args, ["endpoint", "name"]) {
                    #([_, #(_, ast.EAtom(name))], []) ->
                      registered_address(env, name)
                    _ -> TyAddress(TyUnknown)
                  }
                "self" -> TyAddress(TyUnknown)
                "register" ->
                  TyResult(
                    TyAddress(TyUnknown),
                    TyBuiltin("SyslinkError"),
                  )
                "listen" -> TyResult(TyStr, TyBuiltin("SyslinkError"))
                "node" -> TyStr
                "peers" -> TyVec(TyStr)
                // answer, monitor and stop are void statements.
                _ -> TyVoid
              }
            "time" ->
              case fname {
                "now" | "timezoneOffset" -> TyInt
                "timezone" | "format" -> TyStr
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
}

// A bare `name(...)`: a partial application, a func-valued local, a type
// constructor, or a declared callable.
fn infer_ident_call(env: Env, name: String, args: List(ast.Arg)) -> Ty {
  case has_hole(args) {
    // A call with `_` placeholders is a partial application, whose value is a
    // function taking the holes as its parameters.
    True -> partial_ty(env, name, args)
    False ->
      case dict.get(env.locals, name) {
        // Calling a function-valued local yields its return type.
        Ok(TyFunc(_, _, ret)) -> ret
        _ ->
          case dict.has_key(env.types, name) {
            True -> TyCustom(name)
            False ->
              case dict.get(env.sigs, name) {
                // A bare call to an `async func` does not block; it spawns the
                // work and evaluates to a handle (`async T`).
                Ok(#(_, ret)) ->
                  case list.contains(env.asyncs, name) {
                    True -> TyAsync(ret)
                    False -> ret
                  }
                Error(_) -> TyUnknown
              }
          }
      }
  }
}

// ---------------------------------------------------------------------------
// The vector-walking builtins
// ---------------------------------------------------------------------------
// `map`, `filter` and `filterMap` each walk a vector with a function value and
// hand back a new vector. In the notation the builtin table uses:
//
//     map(T[], func(T): K): K[]
//     filter(T[], func(T): Bool): T[]
//     filterMap(T[], func(T): Result<K, E>): K[]
//
// There is no monomorphization to any of them: they lower to one Go generic
// helper each, and Go infers the type arguments from the call. What comes back
// is read off the function that was passed, which is where `K` lives — and for
// `filterMap` it is the *Ok* payload, an Error being how an element says it has
// no place in the output.

// The result type of one of the walks. A call that is not the two-argument shape
// is rejected by `check_walk_call` in its own words; there is nothing to read a
// type off in the meantime.
fn walk_builtin_ty(env: Env, name: String, args: List(ast.Arg)) -> Ty {
  case args {
    [ast.Arg(_, subject), ast.Arg(_, f)] ->
      case name, infer(env, f) {
        // `filter` returns what it was given, minus some of it — a Table stays a
        // Table, and a vector keeps its element type.
        "filter", _ -> infer(env, subject)
        "map", TyFunc(_, _, ret) -> TyVec(ret)
        "filterMap", TyFunc(_, _, TyResult(ok, _)) -> TyVec(ok)
        // The function is not one whose return can be seen from here; the
        // element type is unknown rather than wrong.
        _, _ -> TyVec(TyUnknown)
      }
    _ -> TyVec(TyUnknown)
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
      // Inside a condition an `is`-binding reads through its accessor; a name
      // that shares another's storage reads through to it.
      case dict.get(env.subst, name) {
        Ok(rhs) -> rhs
        Error(_) ->
          case dict.get(env.renames, name) {
            Ok(lvalue) -> lvalue
            Error(_) -> escape_ident(name)
          }
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
    ast.EUsing(source, kind) -> gen_using(env, source, kind)
    ast.EIs(subject, pattern) -> {
      let #(cond, _) = gen_is(env, subject, pattern)
      cond
    }
    // Calling an address in value position is the request form: it registers
    // somewhere for the answer to land and returns without waiting. As a bare
    // statement `gen_stmt` lowers the same call to the cheaper cast instead.
    //
    // Either way the message is copied on its way in, as binding it to a new
    // name would copy it. That is the invariant the whole module rests on: a
    // local send and a remote one are indistinguishable, so the recipient can
    // never observe the sender mutating a message afterwards.
    //
    // A bare async call in value position (an RHS, a vector element, ...)
    // spawns the work on its own goroutine and evaluates to a handle. Used as a
    // statement the handle is simply discarded — that is fire-and-forget, and
    // `gen_stmt` keeps emitting the cheaper `go f(x)` for that case.
    ast.ECall(callee, args) ->
      case is_address_call(env, callee), callee {
        True, _ -> gen_address_send(env, callee, args, True)
        False, ast.EIdent(name) ->
          case list.contains(env.asyncs, name) {
            True -> gen_spawn(env, name, args)
            False -> gen_call(env, ast.EIdent(name), args)
          }
        False, _ -> gen_call(env, callee, args)
      }
    ast.EWith(value, typ) -> gen_with(env, value, typ)
    ast.EAwait(value, timeout) -> gen_await(env, value, timeout)
  }
}

// `spawn f(args)`: run the async func on its own goroutine and hand back a
// handle. The closure captures the exact call so its result type matches the
// declared return; a void async func yields `hive.Unit` so the handle can still
// be joined on.
//
// The arguments have to be evaluated *before* the goroutine starts, not inside
// the closure: for a `mut` argument the evaluation is the copy that keeps the
// task from sharing the caller's storage, and a copy made on the new goroutine
// would race with the caller it is supposed to be protecting against. So when
// any argument needs that treatment the whole spawn is wrapped in a thunk that
// runs in the caller, binds each argument, and only then spawns. (A `go f(x)`
// fire-and-forget statement needs none of this: Go evaluates a `go` statement's
// arguments in the calling goroutine already.)
fn gen_spawn(env: Env, name: String, args: List(ast.Arg)) -> String {
  let ret = case dict.get(env.fns, name) {
    Ok(#(_, _, r)) -> r
    Error(_) -> ast.TVoid
  }
  let spawn = fn(call) {
    case ret {
      ast.TVoid ->
        "hive.Spawn(func() hive.Unit { " <> call <> "; return hive.Unit{} })"
      _ -> "hive.Spawn(func() " <> gen_type(ret) <> " { return " <> call <> " })"
    }
  }
  // Which arguments are copied in — the ones whose evaluation must not be
  // deferred onto the new goroutine.
  let copied =
    list.index_map(args, fn(a, i) { #(i, a) })
    |> list.filter(fn(entry) {
      let #(_, a) = entry
      gen_arg(env, a.value, TyUnknown) != gen_expr(env, a.value)
    })
  case copied {
    [] -> spawn(gen_call(env, ast.EIdent(name), args))
    _ -> {
      // Bind each copied argument to a local in the caller, then hand the
      // locals to the call. `_a<i>` cannot collide: Hive identifiers never
      // start with an underscore.
      let binds =
        copied
        |> list.map(fn(entry) {
          let #(i, a) = entry
          "_a"
          <> int.to_string(i)
          <> " := "
          <> gen_arg(env, a.value, TyUnknown)
          <> "; "
        })
        |> string.concat
      let inner_args =
        list.index_map(args, fn(a, i) {
          case list.key_find(copied, i) {
            Ok(_) -> ast.Arg(a.name, ast.EIdent("_a" <> int.to_string(i)))
            Error(_) -> a
          }
        })
      let handle_ty = case ret {
        ast.TVoid -> "*hive.Async[hive.Unit]"
        _ -> "*hive.Async[" <> async_inner_go(ty_of_type_expr(env.types, ret)) <> "]"
      }
      "func() "
      <> handle_ty
      <> " { "
      <> binds
      <> "return "
      <> spawn(gen_call(env, ast.EIdent(name), inner_args))
      <> " }()"
    }
  }
}

// `await e`, with the optional `with timeout <ms>`. A direct `await asyncCall()`
// needs no handle at all — it is just a synchronous call, so it allocates
// neither goroutine nor channel. A *bounded* one does need a handle, because
// something has to be left running while the wait gives up. Otherwise the
// operand is a held handle, a vector of handles (a barrier that preserves index
// order), or a syslink request in flight.
//
// `0` milliseconds means "no bound of its own": the plain awaits ignore it and
// syslink falls back to its own default patience.
fn gen_await(env: Env, value: ast.Expr, timeout: Option(ast.Expr)) -> String {
  let ms = case timeout {
    Some(e) -> coerce(env, e, TyInt)
    None -> "0"
  }
  case value {
    // An address call is a syslink request, never a task, however it is spelled
    // — so it goes to `await_handle` even where the callee shares a name with an
    // `async func`, matching the shadowing `infer` and `gen_expr` apply.
    ast.ECall(ast.EIdent(name), args) ->
      case is_address_call(env, ast.EIdent(name)) {
        True -> await_handle(env, value, timeout, ms)
        False ->
          case list.contains(env.asyncs, name), timeout {
            True, None -> gen_call(env, ast.EIdent(name), args)
            True, Some(_) ->
              "hive.AwaitTimeout("
              <> gen_spawn(env, name, args)
              <> ", "
              <> ms
              <> ")"
            False, _ -> await_handle(env, value, timeout, ms)
          }
      }
    _ -> await_handle(env, value, timeout, ms)
  }
}

fn await_handle(
  env: Env,
  value: ast.Expr,
  timeout: Option(ast.Expr),
  ms: String,
) -> String {
  let operand = gen_expr(env, value)
  case infer(env, value), timeout {
    // A syslink request already answers with a Result, so a bound on the wait
    // becomes one more reason inside that error rather than a second Result
    // wrapped around the first.
    TyPending(_), _ -> "hive.SyslinkAwait(" <> operand <> ", " <> ms <> ")"
    TyVec(TyPending(_)), _ ->
      "hive.SyslinkAwaitAll(" <> operand <> ", " <> ms <> ")"
    // A plain task has no failure channel at all, so bounding the wait is what
    // introduces one.
    TyVec(TyAsync(_)), Some(_) ->
      "hive.AwaitAllTimeout(" <> operand <> ", " <> ms <> ")"
    TyVec(TyAsync(_)), None -> "hive.AwaitAll(" <> operand <> ")"
    TyAsync(_), Some(_) ->
      "hive.AwaitTimeout(" <> operand <> ", " <> ms <> ")"
    TyAsync(_), None -> operand <> ".Await()"
    // Not actually a task — leave it be; the type checkers reject this shape.
    _, _ -> operand
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
    // The one atom the runtime already knows; everything else is generated.
    "Nil" -> "hive.Nil"
    _ -> "atom_" <> name
  }
}

/// Generate an expression that must produce the given type, inserting the
/// coercions the language defines (atoms read as their decimal Str form; a
/// vector literal adopts the expected element type).
fn coerce(env: Env, e: ast.Expr, expect: Ty) -> String {
  case expect, e {
    // `Result.Ok(v)` / `Result.Error(e)` need both payload types, and the slot
    // the value is landing in is what knows them.
    TyResult(ok, err), ast.ECall(ast.EMember(ast.EIdent("Result"), variant), args) ->
      gen_result_ctor(env, variant, args, ok, err)
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

// ---------------------------------------------------------------------------
// Value-semantics for vectors and structs: copy-on-binding
// ---------------------------------------------------------------------------
// Hive values have value semantics, but vectors/Tables (and structs that
// contain them) lower to Go slices, which share storage. So a binding whose
// RHS aliases existing storage may need a copy to keep the two ends
// independent. The rule preserves one invariant:
//
//   Storage observed by any *immutable* binding is never mutated in place.
//
// The compiler enforces that only `mut` variables can be written through
// (`v[i] = …`, `v.f = …`, `append(v, …)`), so an immutable binding never
// mutates; the copy exists only to stop a *mutable* alias from doing so.
// `bind_rhs` decides, per binding, between an alias (cheap) and a copy.

// An argument that names `mut` storage is copied on its way in.
//
// A parameter is an immutable binding of its own: the callee sees a plain `T`,
// never the caller's `Mutex<T>`. That is only true if the callee cannot observe
// the caller mutating it afterwards, and sharing the backing array makes it
// false two ways over. The mild way is that the callee may keep the slice — in a
// value it returns, a struct it builds, a message it sends — and see later
// writes through it. The severe way is an `async func`, which runs *while* the
// caller carries on: the two then read and write the same array concurrently,
// which is a data race, not merely a surprising read.
//
// So the copy is unconditional on mutability rather than argued away per call
// site. It is still type-directed and still free for anything that owns no
// storage — a scalar, an atom, a struct of scalars — so the cost falls only on
// the arguments that could actually be shared.
fn gen_arg(env: Env, value: ast.Expr, expect: Ty) -> String {
  let rendered = coerce(env, value, expect)
  // A parameter of unknown type (a call through a function value, a leftover
  // positional) is copied at whatever the argument itself is.
  let ty = case expect {
    TyUnknown -> infer(env, value)
    _ -> expect
  }
  case
    aliases_storage(value)
    && source_mutable(env, value)
    && needs_deep_copy_ty(env, ty)
  {
    True -> gen_clone(env, ty, rendered, 0)
    False -> rendered
  }
}

// Two `mut` bindings deliberately share storage: `mut b = a` is how one opts
// into shared mutable state, and every change through either name has to be
// visible through the other.
//
// Two Go variables cannot deliver that. They start out holding the same slice
// header, but `append` returns a *new* header — so `append(a, x)` rebinds `a`
// alone, and from then on the two names are only related by whether Go happened
// to reuse the backing array, which depends on spare capacity. That made
// aliasing hold or break for reasons the source never mentions.
//
// So the second name is not given a variable at all: it renders as the first,
// and there is one header for both. `append(b, x)` then *is* `a = append(a, x)`,
// and an element write through either is seen through both, capacity or no
// capacity.
//
// Two conditions narrow it. The type must own storage — sharing is about a
// backing array, and `mut b = a` on an `Int` is an ordinary independent copy.
// And the source must name the same storage every time it is evaluated, which a
// subscript does not: `i` in `mut b = a[i]` can move, so that binding keeps its
// own header.
fn shares_storage(
  env: Env,
  ty: Ty,
  target_mutable: Bool,
  value: ast.Expr,
) -> Bool {
  target_mutable
  && source_mutable(env, value)
  && stable_lvalue(value)
  && needs_deep_copy_ty(env, ty)
}

// An expression naming the same storage on every evaluation: a variable, or a
// field path rooted at one.
fn stable_lvalue(e: ast.Expr) -> Bool {
  case e {
    ast.EIdent(_) -> True
    ast.EMember(target, _) -> stable_lvalue(target)
    _ -> False
  }
}

// Whether an RHS expression refers to already-existing storage (so a binding
// to it would alias), rather than producing a fresh value (a literal, a
// `+`/`append` result, a call).
fn aliases_storage(e: ast.Expr) -> Bool {
  case e {
    ast.EIdent(_) | ast.EMember(_, _) | ast.EIndex(_, _) | ast.ESlice(_, _, _) ->
      True
    _ -> False
  }
}

// Whether the storage an alias expression reaches belongs to a `mut` variable.
fn source_mutable(env: Env, e: ast.Expr) -> Bool {
  case expr_root(e) {
    Some(n) ->
      case dict.get(env.muts, n) {
        Ok(m) -> m
        Error(_) -> False
      }
    None -> False
  }
}

// The root variable an alias expression is rooted at (`v` in `v`, `v[i]`,
// `v.f`, `v[a:b]`), if any.
fn expr_root(e: ast.Expr) -> Option(String) {
  case e {
    ast.EIdent(n) -> Some(n)
    ast.EMember(t, _) | ast.EIndex(t, _) | ast.ESlice(t, _, _) -> expr_root(t)
    _ -> None
  }
}

// Decides how a binding `target := value` treats an RHS, returning the
// rendered RHS (aliased as-is or wrapped in a copy) and whether it created a
// *shared mutable alias* (so the caller can record it). `ty` is the binding's
// type, `target_name` the bound name (`None` for anonymous assignment
// targets), `target_mutable` whether it is `mut`, and `following` the
// statements that can still see the binding (its scope tail).
fn bind_rhs(
  env: Env,
  ty: Ty,
  target_name: Option(String),
  target_mutable: Bool,
  value: ast.Expr,
  rendered: String,
  following: List(ast.Stmt),
) -> #(String, Bool) {
  // Cheap `aliases_storage` gate first: most RHSs are fresh values, and skipping
  // the type-graph walk for them keeps this off the common path.
  case aliases_storage(value) && needs_deep_copy_ty(env, ty) {
    // A scalar, or a fresh value — nothing is shared, so never copy.
    False -> #(rendered, False)
    True -> {
      // Alias if `keep`, else emit a deep copy. `shared` marks a both-mutable
      // alias so the caller records it.
      let decide = fn(keep, shared) {
        case keep {
          True -> #(rendered, shared)
          False -> #(gen_clone(env, ty, rendered, 0), False)
        }
      }
      // The shared storage stays a stable snapshot only if BOTH ends are frozen
      // after this binding — never mutated and never let escape into a position
      // (a value, a call argument, a container) that could seed a new mutable
      // alias. Computed lazily: the both-mutable arm never needs the scan.
      let ends_frozen = fn() {
        frozen_opt(target_name, following)
        && frozen_opt(expr_root(value), following)
      }
      case target_mutable, source_mutable(env, value) {
        // Both mutable: shared mutable state is intentional; record the alias.
        True, True -> decide(True, True)
        // Immutable source (target mutability is irrelevant): the source is a
        // snapshot both ends read. Alias while it provably stays frozen, else
        // copy — an immutable value must never observe a later change.
        _, False -> decide(ends_frozen(), False)
        // Immutable target, mutable source: a move. Alias only when the source
        // has no pre-existing mutable alias and both ends stay frozen.
        False, True ->
          decide(!aliased_source(env, value) && ends_frozen(), False)
      }
    }
  }
}

// A scope-free copy decision for for-loop init/post clauses, where the loop
// body (the binding's real scope) is not available to scan. Without that scope
// only the mutability-only rule holds: alias when both ends agree on
// mutability (both immutable, or both mutable — the intentional shared case),
// otherwise copy. Because it can't record shared aliases, loop-init bindings
// are simply left out of `aliased`; being loop-scoped, they never outlive the
// loop to be moved elsewhere.
fn bind_rhs_noscope(
  env: Env,
  ty: Ty,
  target_mutable: Bool,
  value: ast.Expr,
  rendered: String,
) -> String {
  case aliases_storage(value) && needs_deep_copy_ty(env, ty) {
    False -> rendered
    True ->
      case target_mutable == source_mutable(env, value) {
        True -> rendered
        False -> gen_clone(env, ty, rendered, 0)
      }
  }
}

// Whether the source alias-expression's root variable already has a live
// mutable alias (recorded from an earlier `mut b = a` sharing). Such a source
// must not be moved into an immutable binding — something else can still
// mutate it.
fn aliased_source(env: Env, value: ast.Expr) -> Bool {
  case expr_root(value) {
    Some(root) ->
      case dict.get(env.aliased, root) {
        Ok(a) -> a
        Error(_) -> False
      }
    None -> True
  }
}

// `frozen`, lifted over an optional variable name — the `None` cases (an
// anonymous assignment LHS, or a source alias-expression with no root) are
// never treated as frozen. Callers pass the target name directly and the
// source through `expr_root`.
fn frozen_opt(name: Option(String), following: List(ast.Stmt)) -> Bool {
  case name {
    Some(n) -> frozen(n, following)
    None -> False
  }
}

// Whether `name`'s storage stays constant throughout `stmts`: it is never
// written through in place (`name[i] = …`, `name.f = …`, `append(name, …)`)
// and never escapes into a position that could seed a new — possibly mutable —
// alias of it (a binding/assignment value, a `return`, a call argument, or a
// container literal). Plain reads (`echo`, `assert`, conditions, indexing for
// a read) leave the storage untouched and are fine.
//
// This is deliberately conservative: a vector that escapes into a function
// call is assumed to gain an alias, because a Go-lowered function may return a
// slice that shares its argument's backing array. Missing such an escape would
// let a mutation leak into a value meant to be independent, so when in doubt
// the binding copies.
fn frozen(name: String, stmts: List(ast.Stmt)) -> Bool {
  !var_mutated_in_stmts(stmts, name) && !may_escape_stmts(stmts, name)
}

// Records a shared mutable alias between a new binding and its source root, so
// later move decisions know the storage still has a live mutable owner.
fn record_alias(
  env: Env,
  name: String,
  value: ast.Expr,
  shared: Bool,
) -> Dict(String, Bool) {
  case shared {
    False -> env.aliased
    True -> {
      let a = dict.insert(env.aliased, name, True)
      case expr_root(value) {
        Some(root) -> dict.insert(a, root, True)
        None -> a
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Type-directed cloning
// ---------------------------------------------------------------------------

// Whether a binding of this type could still share storage after a plain Go
// value-copy — i.e. it is (or contains) a vector/Table. This is the entry
// point every caller uses; `is_deep_ty` carries the recursion's `seen` seed.
fn needs_deep_copy_ty(env: Env, ty: Ty) -> Bool {
  is_deep_ty(env, ty, [])
}

fn is_deep_ty(env: Env, ty: Ty, seen: List(String)) -> Bool {
  case ty {
    TyVec(_) | TyTable -> True
    TyCustom(name) ->
      case list.contains(seen, name) {
        // A recursive field reaches back to a type already being examined; it
        // adds no *new* storage to reason about here.
        True -> False
        False ->
          case dict.get(env.types, name) {
            Ok(ast.TypeDecl(_, variants, commons)) ->
              variants
              |> list.flat_map(fn(v) { v.fields })
              |> list.append(commons)
              |> list.any(fn(f) {
                is_deep_ty(env, ty_of_type_expr(env.types, f.typ), [
                  name,
                  ..seen
                ])
              })
            _ -> False
          }
      }
    // Scalars and atoms own no storage. Builtins and Results are treated as
    // leaves too, by design: they lower to opaque runtime structs whose
    // internals aren't the language's to deep-copy (matching the pre-existing
    // behaviour that never cloned them).
    _ -> False
  }
}

// Emits Go that deep-copies `rendered` (a value of type `ty`) so the result
// shares no storage with it: vectors copy their backing array (recursing into
// element types that own storage), Tables use the runtime helper, and user
// structs/unions delegate to their generated `clone_T`. Leaf types need no
// copy. `depth` keeps nested closure parameter names distinct.
fn gen_clone(env: Env, ty: Ty, rendered: String, depth: Int) -> String {
  case ty {
    TyVec(elem) ->
      case needs_deep_copy_ty(env, elem) {
        False -> "hive.CloneVec(" <> rendered <> ")"
        True -> {
          let e = "e" <> int.to_string(depth)
          let go = ty_to_go(elem)
          "hive.CloneVecFn("
          <> rendered
          <> ", func("
          <> e
          <> " "
          <> go
          <> ") "
          <> go
          <> " { return "
          <> gen_clone(env, elem, e, depth + 1)
          <> " })"
        }
      }
    TyTable -> "hive.CloneTable(" <> rendered <> ")"
    TyCustom(name) ->
      case needs_deep_copy_ty(env, ty) {
        True -> "clone_" <> name <> "(" <> rendered <> ")"
        False -> rendered
      }
    _ -> rendered
  }
}

// A `clone_T` deep-copy function for every user type that owns storage. Types
// with only scalar fields need none (Go's value-copy already isolates them).
// Emitting an unused one is harmless — Go permits unused package-level funcs.
fn gen_clone_support(env: Env, module: ast.Module) -> String {
  module.decls
  |> list.filter_map(fn(d) {
    case d {
      ast.TypeDecl(name, variants, commons) ->
        case needs_deep_copy_ty(env, TyCustom(name)) {
          True -> Ok(gen_clone_fn(env, name, variants, commons))
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
  |> string.join("\n")
}

fn gen_clone_fn(
  env: Env,
  name: String,
  variants: List(ast.Variant),
  commons: List(ast.Field),
) -> String {
  case variants {
    // A plain struct: `x` is a value copy already, so only its storage-owning
    // fields need to be re-copied before it is returned.
    [] ->
      "func clone_"
      <> name
      <> "(x "
      <> name
      <> ") "
      <> name
      <> " {\n"
      <> gen_clone_fields(env, commons, "x", 1)
      <> "\treturn x\n}\n"
    // A tagged union: clone the concrete variant, then re-wrap it.
    _ -> {
      let cases =
        variants
        |> list.map(fn(v) {
          let fields = list.append(v.fields, commons)
          "\tcase "
          <> name
          <> v.name
          <> ":\n"
          <> gen_clone_fields(env, fields, "v", 2)
          <> "\t\treturn "
          <> name
          <> "(v)\n"
        })
        |> string.concat
      "func clone_"
      <> name
      <> "(x "
      <> name
      <> ") "
      <> name
      <> " {\n\tswitch v := x.(type) {\n"
      <> cases
      <> "\t}\n\treturn x\n}\n"
    }
  }
}

fn gen_clone_fields(
  env: Env,
  fields: List(ast.Field),
  receiver: String,
  indent: Int,
) -> String {
  let pad = tabs(indent)
  fields
  |> list.filter_map(fn(f) {
    let fty = ty_of_type_expr(env.types, f.typ)
    case needs_deep_copy_ty(env, fty) {
      False -> Error(Nil)
      True -> {
        let access = receiver <> "." <> exported(f.name)
        Ok(pad <> access <> " = " <> gen_clone(env, fty, access, 0) <> "\n")
      }
    }
  })
  |> string.concat
}

// Whether `name`'s storage is written through anywhere in `stmts` (an element
// or field assignment, or an `append` statement rooted at it). A whole-name
// rebind (`name = …`) is not an in-place write and does not count.
fn var_mutated_in_stmts(stmts: List(ast.Stmt), name: String) -> Bool {
  list.any(stmts, fn(s) { var_mutated_in_stmt(s, name) })
}

// The match is exhaustive on purpose (no catch-all): a new mutating statement
// form should fail to compile here rather than silently weaken the analysis.
fn var_mutated_in_stmt(s: ast.Stmt, name: String) -> Bool {
  case s {
    // An element/field write is the only assignment shape that mutates storage
    // in place; a whole-name rebind (`name = …`) does not.
    ast.SAssign(target, _) ->
      case target {
        ast.EIndex(_, _) | ast.EMember(_, _) | ast.ESlice(_, _, _) ->
          expr_root(target) == Some(name)
        _ -> False
      }
    ast.SExpr(ast.ECall(
      ast.EMember(ast.EIdent("hive"), "append"),
      [ast.Arg(_, target), ..],
    )) -> expr_root(target) == Some(name)
    ast.SExpr(_) -> False
    ast.SIf(branches, else_body) ->
      list.any(branches, fn(b) { var_mutated_in_stmts(b.body, name) })
      || case else_body {
        Some(body) -> var_mutated_in_stmts(body, name)
        None -> False
      }
    ast.SFor(init, _, post, body) ->
      var_mutated_in_opt(init, name)
      || var_mutated_in_opt(post, name)
      || var_mutated_in_stmts(body, name)
    ast.SForEach(_, _, _, body) -> var_mutated_in_stmts(body, name)
    // Bindings, returns and value-only statements don't write through `name`.
    ast.SVarDecl(_, _, _)
    | ast.STypedDecl(_, _, _, _)
    | ast.SReturn(_)
    | ast.SEcho(_)
    | ast.SAssert(_)
    | ast.SPanic(_)
    | ast.SBreak
    | ast.SContinue -> False
  }
}

fn var_mutated_in_opt(o: Option(ast.Stmt), name: String) -> Bool {
  case o {
    Some(s) -> var_mutated_in_stmt(s, name)
    None -> False
  }
}

// Whether `name` could escape into a new alias anywhere in `stmts`: it appears
// in the value of a binding or assignment, in a `return`, or as an argument to
// a call (including `append`) — any position where a lowered Go function might
// capture or hand back a slice that shares its backing array. Reads that keep
// no reference — `echo`, `assert`, loop conditions, the subject a `for each`
// ranges over — do not count. Over-approximating (copying when unsure) keeps
// value semantics intact; under-approximating would let mutations leak.
fn may_escape_stmts(stmts: List(ast.Stmt), name: String) -> Bool {
  list.any(stmts, fn(s) { may_escape_stmt(s, name) })
}

fn may_escape_stmt(s: ast.Stmt, name: String) -> Bool {
  case s {
    // A binding or assignment captures the value under a new (or existing)
    // name; treat any mention as a potential alias.
    ast.SVarDecl(_, value, _)
    | ast.STypedDecl(_, _, value, _)
    | ast.SAssign(_, value) -> uses_in_expr(value, name)
    ast.SReturn(Some(value)) -> uses_in_expr(value, name)
    ast.SReturn(None) -> False
    // Reads that retain no reference.
    ast.SEcho(_) | ast.SAssert(_) | ast.SPanic(_) | ast.SBreak | ast.SContinue ->
      False
    // A call may return or retain a slice aliasing one of its arguments.
    ast.SExpr(e) -> uses_in_expr(e, name)
    ast.SIf(branches, else_body) ->
      list.any(branches, fn(b) { may_escape_stmts(b.body, name) })
      || case else_body {
        Some(body) -> may_escape_stmts(body, name)
        None -> False
      }
    ast.SFor(init, _, post, body) ->
      may_escape_opt(init, name)
      || may_escape_opt(post, name)
      || may_escape_stmts(body, name)
    ast.SForEach(_, _, _, body) -> may_escape_stmts(body, name)
  }
}

fn may_escape_opt(o: Option(ast.Stmt), name: String) -> Bool {
  case o {
    Some(s) -> may_escape_stmt(s, name)
    None -> False
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

// Each `using` form lowers to the reader it names. Because the format is in the
// source rather than sniffed from the path at runtime, a program that never
// reads a spreadsheet never pulls `hive/sheets.go` (and so archive/zip and
// encoding/xml) into its build.
fn gen_using(env: Env, source: ast.Expr, kind: ast.UsingKind) -> String {
  case kind {
    // `run raw <text>` keeps the untyped path: nothing is known about the shape
    // of what comes back, so it comes back as a Table with its header row.
    ast.UsingRaw(text) ->
      "hive.SqlQuery(" <> gen_expr(env, source) <> ", " <> coerce(env, text, TyStr) <> ")"
    ast.UsingQuery(query) -> gen_run_query(env, source, query)
    ast.UsingXlsx -> "hive.ReadXlsx(" <> coerce(env, source, TyStr) <> ")"
    ast.UsingOds -> "hive.ReadOds(" <> coerce(env, source, TyStr) <> ")"
    ast.UsingCsv(separator) -> gen_read_csv(env, source, separator)
  }
}

// What a query's declared rows say to do with it: statements report how many
// rows they touched, single-column results come back as a vector of that
// column, and a row type comes back mapped.
fn gen_run_query(env: Env, source: ast.Expr, query: ast.Expr) -> String {
  let conn = gen_expr(env, source)
  let stmt = gen_expr(env, query)
  case query_rows(env, query) {
    RowsNone -> "hive.SqlExec(" <> conn <> ", " <> stmt <> ")"
    RowsOf(ty) ->
      "hive.SqlRows("
      <> conn
      <> ", "
      <> stmt
      <> ", "
      <> gen_row_mapper(env, ty)
      <> ")"
  }
}

type QueryRows {
  RowsNone
  RowsOf(Ty)
}

fn query_rows(env: Env, query: ast.Expr) -> QueryRows {
  case query {
    ast.ECall(ast.EIdent(name), _) ->
      case dict.get(env.fns, name) {
        Ok(#(_, _, ast.TVoid)) -> RowsNone
        Ok(#(_, _, ret)) ->
          case ty_of_type_expr(env.types, ret) {
            TyVec(elem) -> RowsOf(elem)
            TyTable -> RowsOf(TyVec(TyStr))
            other -> RowsOf(other)
          }
        Error(_) -> RowsOf(TyVec(TyStr))
      }
    _ -> RowsOf(TyVec(TyStr))
  }
}

// A function from one row of cells to a value of the declared type. A cell that
// does not fit its field is an error rather than a zero, which is the same
// answer the derived JSON decoder gives to a value of the wrong shape.
fn gen_row_mapper(_env: Env, ty: Ty) -> String {
  case ty {
    TyCustom(name) -> "sqlRow_" <> name
    _ ->
      "func(_r []string) ("
      <> ty_to_go(ty)
      <> ", error) {\n\tif len(_r) != 1 { var _z "
      <> ty_to_go(ty)
      <> "; return _z, hive.SqlShapeError(1, len(_r)) }\n\treturn "
      <> gen_cell_convert(ty, "_r[0]", gen_string_lit("1"))
      <> "\n}"
  }
}

// Converting one cell. The error names the column so a bad value is traceable.
fn gen_cell_convert(ty: Ty, cell: String, column: String) -> String {
  case ty {
    TyStr -> "hive.SqlCellStr(" <> cell <> ", " <> column <> ")"
    TyInt -> "hive.SqlCellInt(" <> cell <> ", " <> column <> ")"
    TyFloat -> "hive.SqlCellFloat(" <> cell <> ", " <> column <> ")"
    TyBool -> "hive.SqlCellBool(" <> cell <> ", " <> column <> ")"
    // Anything else is handed over as text; a row can only hold scalars.
    _ -> "hive.SqlCellStr(" <> cell <> ", " <> column <> ")"
  }
}

// One `sqlRow_T` per row type reached by a typed query.
fn gen_sql_row_support(env: Env, module: ast.Module) -> String {
  let wanted = list.unique(row_types(env, module.decls))
  wanted
  |> list.filter_map(fn(name) {
    case dict.get(env.types, name) {
      Ok(ast.TypeDecl(_, [], fields)) -> Ok(gen_sql_row_fn(env, name, fields))
      _ -> Error(Nil)
    }
  })
  |> string.concat
}

fn gen_sql_row_fn(env: Env, name: String, fields: List(ast.Field)) -> String {
  let n = list.length(fields)
  let checks =
    fields
    |> list.index_map(fn(f, i) {
      let ty = ty_of_type_expr(env.types, f.typ)
      let idx = int.to_string(i)
      "\tf" <> idx <> ", err" <> idx <> " := "
      <> gen_cell_convert(ty, "_r[" <> idx <> "]", gen_string_lit(f.name))
      <> "\n\tif err" <> idx <> " != nil { return " <> name <> "{}, err" <> idx <> " }\n"
    })
    |> string.concat
  let assigns =
    fields
    |> list.index_map(fn(f, i) { exported(f.name) <> ": f" <> int.to_string(i) })
    |> string.join(", ")
  "func sqlRow_"
  <> name
  <> "(_r []string) ("
  <> name
  <> ", error) {\n\tif len(_r) != "
  <> int.to_string(n)
  <> " { return "
  <> name
  <> "{}, hive.SqlShapeError("
  <> int.to_string(n)
  <> ", len(_r)) }\n"
  <> checks
  <> "\treturn "
  <> name
  <> "{"
  <> assigns
  <> "}, nil\n}\n"
}

// Every custom type a typed query returns rows of.
fn row_types(env: Env, decls: List(ast.Decl)) -> List(String) {
  list.filter_map(decls, fn(d) {
    case d {
      ast.QueryDecl(_, _, ret, _) ->
        case ty_of_type_expr(env.types, ret) {
          TyVec(TyCustom(name)) -> Ok(name)
          _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

fn gen_read_csv(env: Env, path: ast.Expr, delim: Option(ast.Expr)) -> String {
  let separator = case delim {
    Some(d) -> coerce(env, d, TyStr)
    None -> "\",\""
  }
  "hive.ReadCSV(" <> coerce(env, path, TyStr) <> ", " <> separator <> ")"
}

fn gen_call(env: Env, callee: ast.Expr, args: List(ast.Arg)) -> String {
  case builtins.called(callee) {
    Some(name) -> gen_global_builtin(env, name, args)
    None -> gen_other_call(env, callee, args)
  }
}

fn gen_other_call(env: Env, callee: ast.Expr, args: List(ast.Arg)) -> String {
  case callee {
    ast.EIdent(name) -> gen_ident_call(env, name, args)
    // `hive.sql.DatabaseDriver.SQLite()` etc. — driver constructors.
    ast.EMember(
      ast.EMember(ast.EMember(ast.EIdent("hive"), "sql"), "DatabaseDriver"),
      variant,
    ) -> gen_sql_driver(env, variant, args)
    // A `hive.<ns>.<member>` call: a builtin type constructor
    // (`hive.net.HttpRequest(...)`) if the member names a builtin type,
    // otherwise a stdlib function in that namespace.
    ast.EMember(ast.EMember(ast.EIdent("hive"), ns), fname) ->
      case builtin_fields(fname) {
        Some(fields) -> gen_builtin_construct(env, fname, fields, args)
        None ->
          case ns {
            "net" -> gen_net_call(env, fname, args)
            "file" -> gen_file_call(env, fname, args)
            "json" -> gen_json_call(env, fname, args)
            "crypto" -> gen_crypto_call(env, fname, args)
            "sql" -> gen_sql_call(env, fname, args)
            "conv" -> gen_conv_call(env, fname, args)
            "env" -> gen_env_call(env, fname, args)
            "term" -> gen_term_call(env, fname, args)
            "task" -> gen_task_call(env, fname, args)
            "syslink" -> gen_syslink_call(env, fname, args)
            "time" -> gen_time_call(env, fname, args)
            _ -> gen_plain_call(env, callee, args)
          }
      }
    ast.EMember(ast.EIdent("Result"), variant) -> {
      let #(ok, err) = case env.ret {
        TyResult(o, e) -> #(o, e)
        _ ->
          case variant, args {
            "Ok", [ast.Arg(_, v)] -> #(infer(env, v), TyUnknown)
            _, [ast.Arg(_, v)] -> #(TyUnknown, infer(env, v))
            _, _ -> #(TyUnknown, TyUnknown)
          }
      }
      gen_result_ctor(env, variant, args, ok, err)
    }
    ast.EMember(ast.EIdent(type_name), variant_name) ->
      case dict.get(env.types, type_name) {
        Ok(_) -> gen_constructor(env, type_name, variant_name, args)
        // Builtin constructors are namespaced (`hive.net.HttpRequest(...)`),
        // handled above; a bare `hive.X(...)` is rejected by validation.
        Error(_) -> gen_plain_call(env, callee, args)
      }
    _ -> gen_plain_call(env, callee, args)
  }
}

// The `hive.net` namespace: HTTP, WebSockets and raw TCP. The validation pass
// (compiler.check) has already rejected unknown members, bad arities and
// unknown named arguments, so lowering can be straightforward here.
fn gen_net_call(env: Env, fname: String, args: List(ast.Arg)) -> String {
  case fname {
    // --- HTTP ---
    "httpRequest" ->
      case assign_args(args, ["request"]) {
        #([#(_, req)], []) ->
          "hive.HttpSend(" <> coerce(env, req, TyBuiltin("HttpRequest")) <> ")"
        _ -> "hive.HttpSend(" <> gen_args(env, args) <> ")"
      }
    "httpServe" -> gen_serve_call(env, "hive.HttpServe", args)
    // --- WebSockets ---
    "wsConnect" ->
      "hive.WsConnect(" <> gen_one_coerced(env, args, "url", TyStr) <> ")"
    "wsSend" ->
      case assign_args(args, ["connection", "message"]) {
        #([#(_, conn), #(_, message)], []) ->
          "hive.WsSend("
          <> gen_expr(env, conn)
          <> ", "
          <> coerce(env, message, TyStr)
          <> ")"
        _ -> "hive.WsSend(" <> gen_args(env, args) <> ")"
      }
    "wsReceive" -> "hive.WsReceive(" <> gen_connection(env, args) <> ")"
    "wsRequest" -> "hive.WsRequest(" <> gen_connection(env, args) <> ")"
    "wsClose" -> "hive.WsClose(" <> gen_connection(env, args) <> ")"
    "wsServe" -> gen_serve_call(env, "hive.WsServe", args)
    // --- Raw TCP ---
    "socketConnect" ->
      case assign_args(args, ["host", "port"]) {
        #([#(_, host), #(_, port)], []) ->
          "hive.SocketConnect("
          <> coerce(env, host, TyStr)
          <> ", "
          <> coerce(env, port, TyInt)
          <> ")"
        _ -> "hive.SocketConnect(" <> gen_args(env, args) <> ")"
      }
    "socketSend" ->
      case assign_args(args, ["connection", "data"]) {
        #([#(_, conn), #(_, data)], []) ->
          "hive.SocketSend("
          <> gen_expr(env, conn)
          <> ", "
          <> coerce(env, data, TyStr)
          <> ")"
        _ -> "hive.SocketSend(" <> gen_args(env, args) <> ")"
      }
    "socketReceive" ->
      case assign_args(args, ["connection", "bytes"]) {
        #([#(_, conn), #(_, bytes)], []) ->
          "hive.SocketReceive("
          <> gen_expr(env, conn)
          <> ", "
          <> coerce(env, bytes, TyInt)
          <> ")"
        _ -> "hive.SocketReceive(" <> gen_args(env, args) <> ")"
      }
    "socketReceiveLine" ->
      "hive.SocketReceiveLine(" <> gen_connection(env, args) <> ")"
    "socketPeer" -> "hive.SocketPeer(" <> gen_connection(env, args) <> ")"
    "socketClose" -> "hive.SocketClose(" <> gen_connection(env, args) <> ")"
    "socketServe" -> gen_serve_call(env, "hive.SocketServe", args)
    // Neither of these names a protocol, so neither carries one's prefix —
    // which is also what the `hive.Net` module marker matches on.
    "resolve" ->
      "hive.NetResolve(" <> gen_one_coerced(env, args, "name", TyStr) <> ")"
    "localAddress" -> "hive.NetLocalAddress()"
    _ -> "hive." <> exported(fname) <> "(" <> gen_args(env, args) <> ")"
  }
}

// `serve` / `wsServe` / `socketServe` all take the same (port, handler) pair;
// the handler is emitted as-is, since it is already a Go function value (a
// named proc, or the closure a partial application lowers to).
fn gen_serve_call(env: Env, runtime_fn: String, args: List(ast.Arg)) -> String {
  case assign_args(args, ["port", "handler"]) {
    #([#(_, port), #(_, handler)], []) ->
      runtime_fn
      <> "("
      <> coerce(env, port, TyInt)
      <> ", "
      <> gen_expr(env, handler)
      <> ")"
    _ -> runtime_fn <> "(" <> gen_args(env, args) <> ")"
  }
}

// ---------------------------------------------------------------------------
// The `hive.syslink` namespace
// ---------------------------------------------------------------------------
// Every call that puts a message anywhere carries three extra arguments the
// Hive source never mentions: an encoder, a decoder, and the structural digest
// of the message type. They are what let one statement serve a mailbox in this
// process and a service on another machine.

fn gen_syslink_call(env: Env, fname: String, args: List(ast.Arg)) -> String {
  case fname {
    "listen" ->
      "hive.SyslinkListen("
      <> gen_one_coerced(env, args, "endpoint", TyStr)
      <> ")"
    "node" -> "hive.SyslinkNode()"
    "peers" -> "hive.SyslinkPeers()"
    // `spawn` installs the handler as the fold over the mailbox, plus the
    // decoder for messages that arrive from another node.
    "spawn" ->
      case assign_args(args, ["handler", "state"]) {
        #([#(_, handler), #(_, state)], []) -> {
          let msg = handler_msg_type(handler, env.fns)
          "hive.SyslinkSpawn("
          <> gen_expr(env, handler)
          <> ", "
          // The initial state crosses into the service's own thread and is only
          // ever touched there afterwards, so it is copied on the way in for the
          // same reason a message is: nothing the spawner does later may be
          // visible inside the service.
          <> gen_copied(env, state)
          <> ", "
          <> syslink_decoder(env, msg)
          <> ", "
          <> syslink_digest(env, msg)
          <> ", "
          // Whether an unanswered request may be failed the instant the turn
          // ends. See `replies_in_turn`.
          <> bool_lit(replies_in_turn(env, handler))
          <> ")"
        }
        _ -> "hive.SyslinkSpawn(" <> gen_args(env, args) <> ")"
      }
    "register" ->
      case assign_args(args, ["name", "address"]) {
        #([#(_, name), #(_, address)], []) ->
          "hive.SyslinkRegister("
          <> gen_expr(env, name)
          <> ", "
          <> gen_expr(env, address)
          <> ")"
        _ -> "hive.SyslinkRegister(" <> gen_args(env, args) <> ")"
      }
    // `at` is a service on this node, `on` the same service somewhere else. A
    // node is identified by where it is — an endpoint resolvable at runtime
    // through DNS or configuration — so the cluster's size never has to be known
    // when the program is written.
    "at" -> "hive.SyslinkAt(" <> gen_one_raw(env, args, "name") <> ")"
    "on" ->
      case assign_args(args, ["endpoint", "name"]) {
        #([#(_, endpoint), #(_, name)], []) ->
          "hive.SyslinkOn("
          <> coerce(env, endpoint, TyStr)
          <> ", "
          <> gen_expr(env, name)
          <> ")"
        _ -> "hive.SyslinkOn(" <> gen_args(env, args) <> ")"
      }
    "answer" ->
      case assign_args(args, ["from", "value"]) {
        #([#(_, from), #(_, value)], []) ->
          "hive.SyslinkAnswer("
          <> gen_expr(env, from)
          <> ", "
          <> gen_copied(env, value)
          <> ", "
          <> syslink_encoder_ty(infer(env, value))
          <> ")"
        _ -> "hive.SyslinkAnswer(" <> gen_args(env, args) <> ")"
      }
    "self" -> "hive.SyslinkSelf(" <> gen_one_raw(env, args, "from") <> ")"
    "monitor" ->
      case assign_args(args, ["from", "target", "message"]) {
        #([#(_, from), #(_, target), #(_, message)], []) -> {
          let msg = syslink_msg_of(env, ast.EIdent("_"), message)
          "hive.SyslinkMonitor("
          <> gen_expr(env, from)
          <> ", "
          <> gen_expr(env, target)
          <> ", "
          <> gen_copied(env, message)
          <> ", "
          <> syslink_encoder(env, msg)
          <> ", "
          <> syslink_digest(env, msg)
          <> ")"
        }
        _ -> "hive.SyslinkMonitor(" <> gen_args(env, args) <> ")"
      }
    "stop" -> "hive.SyslinkStop(" <> gen_one_raw(env, args, "address") <> ")"
    _ -> "hive.Syslink" <> exported(fname) <> "(" <> gen_args(env, args) <> ")"
  }
}

// ---------------------------------------------------------------------------
// A service address is callable
// ---------------------------------------------------------------------------
// `c(message)` *is* the send — there is no `hive.syslink.send`, exactly as there
// is no `spawn` keyword in front of an `async func` call. What the call site
// does with the value decides what the call means: discarded it is a cast, kept
// it is a request in flight, and `await`ed it is that request's answer.
//
// Dispatch is by the callee's *type*, never by its spelling, so a local, a
// parameter, a vector element and a fresh `at(#Name)` are all callable the same
// way. An address that shares a name with a declared func resolves to the
// address, because a local shadows a declaration everywhere else in the language
// too.
fn address_call_msg(env: Env, callee: ast.Expr) -> Option(Ty) {
  case infer(env, callee) {
    TyAddress(msg) -> Some(msg)
    _ -> None
  }
}

fn is_address_call(env: Env, callee: ast.Expr) -> Bool {
  case address_call_msg(env, callee) {
    Some(_) -> True
    None -> False
  }
}

// The one message an address is called with. `check_address_call` has already
// rejected every other shape, so this only has to name the good one.
fn address_call_arg(args: List(ast.Arg)) -> Option(ast.Expr) {
  case args {
    [ast.Arg(None, message)] -> Some(message)
    _ -> None
  }
}

fn gen_address_send(
  env: Env,
  callee: ast.Expr,
  args: List(ast.Arg),
  awaitable: Bool,
) -> String {
  case address_call_arg(args) {
    Some(message) -> gen_send_parts(env, callee, message, awaitable)
    // Unreachable: `check_address_call` fails the compile first. Codegen stays
    // total rather than crashing on a shape the checker owns.
    None -> gen_send_parts(env, callee, ast.EIdent("_"), awaitable)
  }
}

// `awaitable` distinguishes the two shapes the same call takes: kept, it is a
// request with somewhere for the answer to arrive; discarded, it is a cast that
// allocates nothing.
fn gen_send_parts(
  env: Env,
  address: ast.Expr,
  message: ast.Expr,
  awaitable: Bool,
) -> String {
  let msg = syslink_msg_of(env, address, message)
  let head = case awaitable {
    True -> "hive.SyslinkSendAwaitable("
    False -> "hive.SyslinkSend("
  }
  // A service answers with one of its own messages, so the decoder for the
  // answer is the very same one the mailbox uses. That is what removes the
  // reply-type annotation from the await site entirely.
  let tail = case awaitable {
    True -> ", hive.SyslinkReplyDecoder(" <> syslink_decoder_ref(env, msg) <> ")"
    False -> ""
  }
  head
  <> gen_expr(env, address)
  <> ", "
  <> gen_copied(env, message)
  <> ", "
  <> syslink_encoder(env, msg)
  <> ", "
  <> syslink_digest(env, msg)
  <> tail
  <> ")"
}

fn syslink_decoder_ref(env: Env, msg: Option(ast.TypeExpr)) -> String {
  case msg {
    Some(typ) -> json_decoder_ref(env, typ)
    None -> "hive.JsonFlatten"
  }
}

// The message type a send is carrying: the mailbox type the address resolves
// to when that is known (so the digest matches the recipient's), otherwise the
// message expression's own type.
fn syslink_msg_of(
  env: Env,
  address: ast.Expr,
  message: ast.Expr,
) -> Option(ast.TypeExpr) {
  case infer(env, address) {
    TyAddress(TyUnknown) | TyUnknown -> ty_type_expr(infer(env, message))
    TyAddress(_) ->
      // The address knows its mailbox type, but the digest has to be computed
      // from a type *expression*; the message's own type is the same one when
      // the program type-checks, and it is what is written at the call site.
      ty_type_expr(infer(env, message))
    _ -> ty_type_expr(infer(env, message))
  }
}

// A best-effort type expression for an inferred type, so a derived codec can be
// named for it. Only the shapes a message can actually have need to work.
fn ty_type_expr(ty: Ty) -> Option(ast.TypeExpr) {
  case ty {
    TyStr -> Some(ast.TName(None, "Str", [], []))
    TyInt -> Some(ast.TName(None, "Int", [], []))
    TyFloat -> Some(ast.TName(None, "Float", [], []))
    TyBool -> Some(ast.TName(None, "Bool", [], []))
    TyAtom -> Some(ast.TName(None, "Atom", [], []))
    TyTable -> Some(ast.TName(None, "Table", [], []))
    TyCustom(name) -> Some(ast.TName(None, name, [], []))
    TyVec(inner) ->
      case ty_type_expr(inner) {
        Some(ast.TName(pkg, name, args, dims)) ->
          Some(ast.TName(pkg, name, args, [ast.DimDyn, ..dims]))
        _ -> None
      }
    _ -> None
  }
}

// A message is copied on its way into a mailbox, using the same deep,
// type-directed copy a binding uses — never runtime reflection, and never at all
// when the type owns no storage to share.
fn gen_copied(env: Env, e: ast.Expr) -> String {
  let ty = infer(env, e)
  let rendered = gen_expr(env, e)
  case needs_deep_copy_ty(env, ty) {
    True -> gen_clone(env, ty, rendered, 0)
    False -> rendered
  }
}

// The mailbox type behind a registered service name, when the program registers
// it somewhere. Registered names are atoms and cannot be computed, so this table
// is complete for every name this build publishes.
fn registered_address(env: Env, name: String) -> Ty {
  case dict.get(env.mailboxes, name) {
    Ok(typ) -> TyAddress(ty_of_type_expr(env.types, typ))
    Error(_) -> TyAddress(TyUnknown)
  }
}

// What awaiting a request resolves to. A service answers with one of its own
// messages, so this is the mailbox type — taken from the address when the
// registry knows it, and otherwise from the message being sent, which is the
// same type whenever the program is right.
fn syslink_reply_ty(env: Env, address: ast.Expr, message: ast.Expr) -> Ty {
  case infer(env, address) {
    TyAddress(TyUnknown) -> infer(env, message)
    TyAddress(known) -> known
    _ -> infer(env, message)
  }
}

// The inferred message type of a spawn handler, for the address it produces.
fn handler_msg_ty(env: Env, handler: ast.Expr) -> Ty {
  case handler_msg_type(handler, env.fns) {
    Some(typ) -> ty_of_type_expr(env.types, typ)
    None -> TyUnknown
  }
}

fn syslink_encoder(env: Env, msg: Option(ast.TypeExpr)) -> String {
  case msg {
    Some(typ) -> "hive.SyslinkEncoder(" <> json_encoder_ref(env, typ) <> ")"
    None -> "hive.SyslinkEncoder(hive.JsonEncodeDynamic)"
  }
}

fn syslink_encoder_ty(ty: Ty) -> String {
  case ty_type_expr(ty) {
    Some(_) ->
      "hive.SyslinkEncoder(func(_v "
      <> ty_to_go(ty)
      <> ") string { return "
      <> gen_json_encode(ty, "_v", 0)
      <> " })"
    None -> "hive.SyslinkEncoder(hive.JsonEncodeDynamic)"
  }
}

fn syslink_decoder(env: Env, msg: Option(ast.TypeExpr)) -> String {
  case msg {
    Some(typ) -> "hive.SyslinkDecoder(" <> json_decoder_ref(env, typ) <> ")"
    None -> "nil"
  }
}

// A structural fingerprint of the message type, carried in every frame so a
// peer built from a different declaration fails loudly instead of decoding
// another type's bytes into this one.
fn syslink_digest(env: Env, msg: Option(ast.TypeExpr)) -> String {
  case msg {
    None -> "0"
    Some(typ) ->
      "0x" <> pad_hex(fnv1a(type_signature(env.types, typ)))
  }
}

fn pad_hex(n: Int) -> String {
  let s = int.to_base16(n) |> string.lowercase
  string.repeat("0", int.max(0, 8 - string.length(s))) <> s
}

// The signature a digest is taken over: the type's own spelling plus, for a
// user type, every variant and field it declares, recursively. Two builds whose
// declarations differ in any way a decoder would notice produce different
// digests.
fn type_signature(types: Dict(String, ast.Decl), typ: ast.TypeExpr) -> String {
  type_signature_seen(types, typ, [])
}

fn type_signature_seen(
  types: Dict(String, ast.Decl),
  typ: ast.TypeExpr,
  seen: List(String),
) -> String {
  case typ {
    ast.TVoid -> "void"
    ast.TFunc(_, _, _) -> "func"
    ast.TName(pkg, name, args, dims) -> {
      let base = case pkg {
        Some(p) -> p <> "." <> name
        None -> name
      }
      // Arguments distinguish `Box<Str>` from `Box<Int>` on the wire, so they
      // belong in the signature the digest is taken over.
      let base = case args {
        [] -> base
        _ ->
          base
          <> "<"
          <> string.join(
            list.map(args, fn(a) { type_signature_seen(types, a, seen) }),
            ",",
          )
          <> ">"
      }
      let suffix =
        dims
        |> list.map(fn(d) {
          case d {
            ast.DimStatic(n) -> "[" <> int.to_string(n) <> "]"
            _ -> "[dyn]"
          }
        })
        |> string.concat
      // A recursive type stops at its own name: the cycle adds no information a
      // decoder could differ on, and expanding it would not terminate.
      case dict.get(types, name), list.contains(seen, name) {
        Ok(ast.TypeDecl(_, variants, commons)), False -> {
          let inner = [name, ..seen]
          let fields =
            list.append(
              list.flat_map(variants, fn(v) {
                [v.name, ..list.map(v.fields, fn(f) {
                  f.name <> ":" <> type_signature_seen(types, f.typ, inner)
                })]
              }),
              list.map(commons, fn(f) {
                f.name <> ":" <> type_signature_seen(types, f.typ, inner)
              }),
            )
          base <> "{" <> string.join(fields, ",") <> "}" <> suffix
        }
        _, _ -> base <> suffix
      }
    }
  }
}

// FNV-1a, 32-bit. Small, deterministic and identical in any build of the
// compiler, which is all a digest needs.
fn fnv1a(text: String) -> Int {
  text
  |> string.to_utf_codepoints
  |> list.fold(2_166_136_261, fn(hash, cp) {
    let h = int.bitwise_exclusive_or(hash, string.utf_codepoint_to_int(cp))
    int.bitwise_and(h * 16_777_619, 4_294_967_295)
  })
}

/// A Go expression referencing the encoder for a Hive type: something of type
/// `func(T) string`. The mirror of `json_decoder_ref`.
fn json_encoder_ref(env: Env, t: ast.TypeExpr) -> String {
  let ty = ty_of_type_expr(env.types, t)
  case t {
    ast.TName(None, name, _, []) ->
      case name {
        _ ->
          case dict.has_key(env.types, name) {
            True -> "jsonEncode_" <> name
            False ->
              "func(_v "
              <> ty_to_go(ty)
              <> ") string { return "
              <> gen_json_encode(ty, "_v", 0)
              <> " }"
          }
      }
    _ ->
      "func(_v "
      <> ty_to_go(ty)
      <> ") string { return "
      <> gen_json_encode(ty, "_v", 0)
      <> " }"
  }
}

// The lone `connection` argument shared by most of the WebSocket and socket
// calls. A connection is an opaque handle, so it needs no coercion.
fn gen_connection(env: Env, args: List(ast.Arg)) -> String {
  case assign_args(args, ["connection"]) {
    #([#(_, conn)], []) -> gen_expr(env, conn)
    _ -> gen_args(env, args)
  }
}

// The `hive.file` namespace: general filesystem reads and writes. Contents move
// as Str, which carries bytes, so binary files round-trip unchanged.
fn gen_file_call(env: Env, fname: String, args: List(ast.Arg)) -> String {
  case fname {
    "read" -> "hive.FileRead(" <> gen_one(env, args, "path") <> ")"
    "lines" -> "hive.FileLines(" <> gen_one(env, args, "path") <> ")"
    "exists" -> "hive.FileExists(" <> gen_one(env, args, "path") <> ")"
    "size" -> "hive.FileSize(" <> gen_one(env, args, "path") <> ")"
    "delete" -> "hive.FileDelete(" <> gen_one(env, args, "path") <> ")"
    "list" -> "hive.FileList(" <> gen_one(env, args, "path") <> ")"
    "makeDir" -> "hive.FileMakeDir(" <> gen_one(env, args, "path") <> ")"
    "write" -> gen_two_strs(env, args, "hive.FileWrite", "path", "contents")
    "append" -> gen_two_strs(env, args, "hive.FileAppend", "path", "contents")
    "copy" -> gen_two_strs(env, args, "hive.FileCopy", "from", "to")
    "move" -> gen_two_strs(env, args, "hive.FileMove", "from", "to")
    _ -> "hive.File" <> exported(fname) <> "(" <> gen_args(env, args) <> ")"
  }
}

// Two Str arguments, honouring the named-argument form.
fn gen_two_strs(
  env: Env,
  args: List(ast.Arg),
  runtime_fn: String,
  first: String,
  second: String,
) -> String {
  case assign_args(args, [first, second]) {
    #([#(_, a), #(_, b)], []) ->
      runtime_fn
      <> "("
      <> coerce(env, a, TyStr)
      <> ", "
      <> coerce(env, b, TyStr)
      <> ")"
    _ -> runtime_fn <> "(" <> gen_args(env, args) <> ")"
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

// The `hive.term` namespace: line-oriented terminal I/O.
//   * `print` writes a line to stdout — the same lowering as `echo`.
//   * `read` blocks the calling virtual thread on a line of stdin (only that
//     goroutine parks; others keep running).
//   * `args` is the program's command-line arguments (excluding the program
//     name) as a `Str[dyn]`.
fn gen_term_call(env: Env, fname: String, args: List(ast.Arg)) -> String {
  case fname {
    "print" -> "fmt.Println(" <> gen_one_coerced(env, args, "text", TyStr) <> ")"
    "read" -> "hive.TermRead()"
    "args" -> "hive.TermArgs()"
    _ -> "hive." <> exported(fname) <> "(" <> gen_args(env, args) <> ")"
  }
}

// The `hive.task` namespace: scheduling controls over the virtual threads an
// `async func` runs on.
//   * `sleep` parks the calling goroutine for a number of milliseconds.
fn gen_task_call(env: Env, fname: String, args: List(ast.Arg)) -> String {
  case fname {
    "sleep" -> "hive.Sleep(" <> gen_one_coerced(env, args, "ms", TyInt) <> ")"
    _ -> "hive." <> exported(fname) <> "(" <> gen_args(env, args) <> ")"
  }
}

// The `hive.time` namespace: the wall clock and calendar formatting.
//   * `now` is the current Unix time in seconds.
//   * `timezone` / `timezoneOffset` describe the machine's local zone.
//   * `format` renders a Unix time (local) with a strftime-style template.
fn gen_time_call(env: Env, fname: String, args: List(ast.Arg)) -> String {
  case fname {
    "now" -> "hive.Now()"
    "timezone" -> "hive.Timezone()"
    "timezoneOffset" -> "hive.TimezoneOffset()"
    "format" ->
      case assign_args(args, ["time", "template"]) {
        #([#(_, time), #(_, template)], []) ->
          "hive.TimeFormat("
          <> coerce(env, time, TyInt)
          <> ", "
          <> coerce(env, template, TyStr)
          <> ")"
        _ -> "hive.TimeFormat(" <> gen_args(env, args) <> ")"
      }
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
    TyAddress(_) -> "hive.JsonEncodeAddress(" <> value <> ")"
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
      exported(fname) <> ": " <> gen_arg(env, value, ty)
    })
  let extra_strs =
    extra
    |> list.index_map(fn(e, i) {
      "Field" <> int.to_string(i) <> ": " <> gen_arg(env, e, TyUnknown)
    })
  string.join(list.append(assigned_strs, extra_strs), ", ")
}

fn gen_ident_call(env: Env, name: String, args: List(ast.Arg)) -> String {
  // A call carrying `_` placeholders is a partial application of a user
  // callable: it builds a closure rather than calling. (The compiler has
  // already rejected placeholders anywhere else.)
  case has_hole(args) && dict.has_key(env.fns, name) {
    True -> gen_partial(env, name, args)
    False -> gen_declared_call(env, name, args)
  }
}

// Lowers `f(a, _, c)` to `func(h0 T) R { return f(a, h0, c) }`: each `_`
// becomes a fresh parameter (typed from f's signature, in hole order), each
// supplied argument is captured by value where it is written.
fn gen_partial(env: Env, name: String, args: List(ast.Arg)) -> String {
  let assert Ok(#(_pure, params, ret)) = dict.get(env.fns, name)
  let #(assigned, _) = assign_args(args, list.map(params, fn(p) { p.name }))
  // `assigned` and `params` are both in declaration order; pair them so each
  // argument knows its parameter's type.
  let paired = list.zip(assigned, params)
  let hole_params =
    paired
    |> list.index_map(fn(pair, i) { #(pair, i) })
    |> list.filter_map(fn(entry) {
      let #(#(#(_, expr), field), i) = entry
      case is_hole_expr(expr) {
        True -> Ok("_h" <> int.to_string(i) <> " " <> gen_type(field.typ))
        False -> Error(Nil)
      }
    })
    |> string.join(", ")
  let call_args =
    paired
    |> list.index_map(fn(pair, i) { #(pair, i) })
    |> list.map(fn(entry) {
      let #(#(#(_, expr), field), i) = entry
      case is_hole_expr(expr) {
        True -> "_h" <> int.to_string(i)
        // A captured argument is held by the closure for as long as the value
        // lives, so it is copied in exactly as a direct call's would be.
        False -> gen_arg(env, expr, ty_of_type_expr(env.types, field.typ))
      }
    })
    |> string.join(", ")
  let call = escape_ident(name) <> "(" <> call_args <> ")"
  let #(ret_go, body) = case ret {
    ast.TVoid -> #("", call)
    _ -> #(" " <> gen_type(ret), "return " <> call)
  }
  "func(" <> hole_params <> ")" <> ret_go <> " { " <> body <> " }"
}

fn has_hole(args: List(ast.Arg)) -> Bool {
  list.any(args, fn(a) { is_hole_expr(a.value) })
}

fn is_hole_expr(e: ast.Expr) -> Bool {
  case e {
    ast.EIdent("_") -> True
    _ -> False
  }
}

// The result type of a partial application `name(...)`: a function value whose
// parameters are the hole positions (in order) and whose return matches the
// wrapped callable.
fn partial_ty(env: Env, name: String, args: List(ast.Arg)) -> Ty {
  case dict.get(env.fns, name) {
    Ok(#(pure, params, ret)) -> {
      let #(assigned, _) = assign_args(args, list.map(params, fn(p) { p.name }))
      let hole_tys =
        list.zip(assigned, params)
        |> list.filter_map(fn(pair) {
          let #(#(_, expr), field) = pair
          case is_hole_expr(expr) {
            True -> Ok(ty_of_type_expr(env.types, field.typ))
            False -> Error(Nil)
          }
        })
      TyFunc(pure, hole_tys, fn_ret_ty(env.types, ret))
    }
    Error(_) -> TyUnknown
  }
}

// One of the global builtins, which by this point is always written `hive.<name>`
// (see `hive/builtins`) — so nothing here has to wonder whether the program meant
// its own declaration of the name.
fn gen_global_builtin(env: Env, name: String, args: List(ast.Arg)) -> String {
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
    "print" -> "fmt.Print(" <> gen_args(env, args) <> ")"
    "println" -> "fmt.Println(" <> gen_args(env, args) <> ")"
    // `join(vector, sep)` concatenates a Str vector into one Str.
    "join" -> "hive.Join(" <> gen_args(env, args) <> ")"
    // `split(str, sep)` divides a Str into a Str vector.
    "split" -> "hive.Split(" <> gen_args(env, args) <> ")"
    // `indexOf` searches a vector for an element, or a Str for a substring.
    // The sought value is rendered as the element type the subject holds, so a
    // vector literal (`indexOf(table, ["a", "b"])`) lands as one.
    "indexOf" ->
      case args {
        [ast.Arg(_, subject), ast.Arg(_, value)] -> {
          let subj = gen_expr(env, subject)
          case infer(env, subject) {
            TyStr ->
              "hive.IndexOfStr("
              <> subj
              <> ", "
              <> coerce(env, value, TyStr)
              <> ")"
            TyVec(elem) ->
              "hive.IndexOf(" <> subj <> ", " <> coerce(env, value, elem) <> ")"
            TyTable ->
              "hive.IndexOf("
              <> subj
              <> ", "
              <> coerce(env, value, TyVec(TyStr))
              <> ")"
            _ -> "hive.IndexOf(" <> gen_args(env, args) <> ")"
          }
        }
        _ -> "hive.IndexOf(" <> gen_args(env, args) <> ")"
      }
    // `row(table, key)` / `column(table, key)` look a row/column up by its
    // first cell.
    "row" -> "hive.Row(" <> gen_args(env, args) <> ")"
    "column" -> "hive.Column(" <> gen_args(env, args) <> ")"
    // `append(v, x...)` grows a vector (see gen_append); as a statement the
    // caller reassigns the result back to `v`.
    "append" -> gen_append(env, args)
    // `map`/`filter`/`filterMap` walk a vector with a function value.
    _ -> gen_walk_builtin(env, name, args)
  }
}

// A call to something the program declared: a type constructor, or a
// proc/func/query.
fn gen_declared_call(env: Env, name: String, args: List(ast.Arg)) -> String {
  case dict.get(env.types, name) {
    // Bare `Type(...)` constructs the first variant (or the struct itself for a
    // variant-less type).
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

// `map(v, f)` -> `hive.Map(v, f)`, and likewise for the other two. Go infers the
// helper's type arguments from the two it is handed, so nothing has to be spelled
// out here.
//
// The vector goes in the way it would go into any `T[]` parameter — copied when
// it is storage a `mut` binding can still change — so the elements the new vector
// holds belong to the value that comes back, not to something the caller may
// still be writing to.
fn gen_walk_builtin(env: Env, name: String, args: List(ast.Arg)) -> String {
  let helper = case name {
    "map" -> "hive.Map"
    "filter" -> "hive.Filter"
    _ -> "hive.FilterMap"
  }
  case args {
    [ast.Arg(_, subject), ast.Arg(_, f)] ->
      helper
      <> "("
      <> gen_arg(env, subject, infer(env, subject))
      <> ", "
      <> gen_expr(env, f)
      <> ")"
    // The arity check has already rejected anything else; this only keeps the
    // renderer total.
    _ -> helper <> "(" <> gen_args(env, args) <> ")"
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
      gen_arg(env, value, ty)
    })
  let extra_strs = list.map(extra, fn(e) { gen_arg(env, e, TyUnknown) })
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

// `Result.Ok(v)` -> `hive.Ok[T, E](v)`, `Result.Error(e)` -> `hive.Err[T, E](e)`.
// Go needs both parameters spelled out at the construction, which is why the
// expected type has to reach here rather than being inferred from the payload.
fn gen_result_ctor(
  env: Env,
  variant: String,
  args: List(ast.Arg),
  ok: Ty,
  err: Ty,
) -> String {
  let params = "[" <> ty_to_go(ok) <> ", " <> ty_to_go(err) <> "]"
  case variant, args {
    "Ok", [ast.Arg(_, v)] -> "hive.Ok" <> params <> "(" <> coerce(env, v, ok) <> ")"
    "Error", [ast.Arg(_, v)] ->
      "hive.Err" <> params <> "(" <> coerce(env, v, err) <> ")"
    _, _ ->
      "hive.Ok" <> params <> "(" <> gen_args(env, args) <> ")"
  }
}

fn gen_plain_call(env: Env, callee: ast.Expr, args: List(ast.Arg)) -> String {
  let rendered =
    args
    |> list.map(fn(a) { gen_arg(env, a.value, TyUnknown) })
    |> string.join(", ")
  gen_expr(env, callee) <> "(" <> rendered <> ")"
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
  case is_go_reserved(name) {
    True -> name <> "_"
    False -> name
  }
}

// Names that mean something to Go already, and so cannot be the ones a Hive
// declaration, parameter or local is emitted under.
//
// The keywords would not parse. Go's predeclared *functions* would, and would then
// quietly win: Go lets them be shadowed, so a program declaring its own `len`
// would emit `func len(...)` at package scope and every `len(v)` the compiler
// generated — for a `hive.len`, for a `bounds` guard, for any vector's length —
// would reach that instead. Renaming is what lets a program take `len` or
// `append` for itself and still get the builtin by its long name.
//
// Go's predeclared *types* and constants (`error`, `string`, `nil`) are left
// alone. They are the names a Hive program is most likely to want (`error` above
// all), nothing here generates a call to one, and they were never renamed before.
// A program that declares a top-level `error` still collides with the `error` in
// a generated SQL mapper's signature — that is a hazard of its own, older than
// this list and not one builtin resolution introduced.
fn is_go_reserved(name: String) -> Bool {
  list.contains(
    [
      // Keywords.
      "break", "case", "chan", "const", "continue", "default", "defer", "else",
      "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
      "map", "package", "range", "return", "select", "struct", "switch", "type",
      "var",
      // Predeclared functions.
      "append", "cap", "clear", "close", "complex", "copy", "delete", "imag",
      "len", "make", "max", "min", "new", "panic", "print", "println", "real",
      "recover",
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
    ast.SAssert(e) | ast.SPanic(e) -> uses_in_expr(e, name)
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
    ast.EUsing(source, kind) ->
      uses_in_expr(source, name)
      || list.any(ast.using_exprs(kind), fn(e) { uses_in_expr(e, name) })
    ast.EWith(value, _) -> uses_in_expr(value, name)
    ast.EAwait(value, _) -> uses_in_expr(value, name)
  }
}

fn uses_in_opt(o: Option(ast.Expr), name: String) -> Bool {
  case o {
    Some(e) -> uses_in_expr(e, name)
    None -> False
  }
}
