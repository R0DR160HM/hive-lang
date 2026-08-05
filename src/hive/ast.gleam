//// The Hive abstract syntax tree.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Module {
  Module(
    imports: List(Import),
    decls: List(Decl),
    /// Flat declaration name -> the name and file the author actually wrote, for
    /// anything that has to report a declaration back to them. Flattening
    /// renames every imported declaration (`grow` in `helpers.hive` becomes
    /// `helpers_0_grow`), and by the time coverage or a diagnostic wants to name
    /// one, the file it came from is the only place that spelling exists.
    ///
    /// Empty until `hive/modules` flattens; the entry module's own declarations
    /// map to themselves.
    origins: Dict(String, Origin),
  )
}

/// Where a declaration was written, as the author would name it.
pub type Origin {
  Origin(name: String, file: String)
}

/// `import ../lib/strings` or `import ../lib/strings as text` — a module-level
/// declaration bringing another file's declarations into scope under a name.
///
/// `path` is relative to the importing file's own directory, with the `.hive`
/// extension left off. `alias` is the name the module is reached through
/// (`text.slugify(...)`), defaulting to the path's last segment. Imports are
/// resolved and merged away before the rest of the pipeline runs, so only
/// `hive/modules` ever sees them.
pub type Import {
  Import(path: String, alias: String, line: Int)
}

pub type Decl {
  /// A `proc`edure: a function that may perform side effects.
  ProcDecl(
    name: String,
    params: List(Field),
    return_type: TypeExpr,
    body: List(Stmt),
  )
  /// A `func`: a pure function (no side effects allowed in its body).
  ///
  /// Nothing about a declaration says how it runs: every call blocks its
  /// caller, and a call site that does not want to wait says so with `async`
  /// (see `SAsync`).
  FuncDecl(
    name: String,
    params: List(Field),
    return_type: TypeExpr,
    body: List(Stmt),
  )
  /// A `query`: a pure function whose body is inline SQL.
  ///
  /// `return_type` describes the *rows*, not the SQL text: a row type
  /// (`User[dyn]`), a scalar for a single-column result (`Str[dyn]`), or `void`
  /// for a statement that returns none, whose result is the number of rows it
  /// affected.
  QueryDecl(
    name: String,
    params: List(Field),
    return_type: TypeExpr,
    sql: List(SqlPart),
  )
  /// An algebraic data type. When `variants` is empty the type behaves as a
  /// plain struct made of `common_fields`. When it has variants, each variant
  /// is a struct and the type is a tagged union; `common_fields` are added to
  /// every variant.
  TypeDecl(name: String, variants: List(Variant), common_fields: List(Field))
  /// `test "what should be true" { ... }` — one unit test.
  ///
  /// A test is named in prose because that is what a test name is for, and it
  /// takes no parameters and returns nothing: there is no caller to give it
  /// either. The body is an ordinary `proc` body, so it may call procs and do
  /// I/O, and `assert` inside it records a failure rather than aborting (see
  /// `SAssert`).
  ///
  /// `file` and `line` are where the declaration opens — the position a failure
  /// or a panic inside the body is reported against. The parser cannot know the
  /// file (it is handed tokens, not a path), so `file` is filled in by
  /// `hive/modules` while flattening, which is the one pass holding both.
  TestDecl(name: String, body: List(Stmt), file: String, line: Int)
}

/// A named, typed slot: a parameter of a callable, or a field of a type.
///
/// `mutable` is what a parameter written `name: mut T` records — the callee is
/// handed the caller's `Mutex<T>` itself rather than an immutable view of it, so
/// a write in the callee lands on the caller's variable. Only a `proc` may
/// declare one, and only when the call is waited for; an `async` call copies the
/// argument in instead (see `SAsync`). It is always `False` on a type's fields,
/// whose mutability is the binding's, not the field's.
pub type Field {
  Field(name: String, typ: TypeExpr, mutable: Bool)
}

pub type Variant {
  Variant(name: String, fields: List(Field))
}

/// One `[...]` marker on a vector type.
pub type Dim {
  /// `T[]` — a vector whose length is not part of the type. It promises
  /// nothing, so every access into it is guarded, and it accepts *any* vector
  /// of the right element type. Legal only in a parameter position: a variable,
  /// field or return has to say which of the two real kinds it is.
  DimEmpty
  /// `T[3]` — a vector of static length. The length is a promise enforced
  /// everywhere a value can reach the slot.
  DimStatic(size: Int)
  /// `T[dyn]` — a dynamic vector. Its length is not known at compile time.
  DimDyn
}

pub type TypeExpr {
  TVoid
  /// A named type, optionally package-qualified (e.g. `hive.TableError`), with
  /// type arguments (`Result<Int, Bool>`, `Box<Str>`) and trailing vector
  /// markers (e.g. `Str[dyn][dyn]` -> two dims).
  ///
  /// A `name` that is neither a builtin nor a declared type is a **type
  /// variable**: `func first(v: T[]): T` is generic in `T`, which is exactly
  /// how the builtin table has always been written. Variables are substituted
  /// away by monomorphization, so nothing downstream ever sees one.
  TName(
    pkg: Option(String),
    name: String,
    args: List(TypeExpr),
    dims: List(Dim),
  )
  /// A function type, spelled like a declaration without a name:
  /// `func(Int, Str): Bool` (pure) or `proc(Req): Resp` (impure). `pure`
  /// separates the two. A `func` value may be used where a `proc` type is
  /// expected (pure widens to impure), but not the reverse.
  TFunc(pure: Bool, params: List(TypeExpr), ret: TypeExpr)
}

pub type Stmt {
  /// `name := value` — type-inferred declaration. `mutable` records whether it
  /// was declared with `mut`; only mutable variables may be reassigned.
  SVarDecl(name: String, value: Expr, mutable: Bool)
  /// `Type name = value` — declaration with an explicit type annotation.
  /// `mutable` records whether it was declared with `mut`.
  STypedDecl(typ: TypeExpr, name: String, value: Expr, mutable: Bool)
  /// `target = value` — reassignment of a mutable variable (or one of its
  /// elements, e.g. `v[0] = x`).
  SAssign(target: Expr, value: Expr)
  /// `if ... { } else if ... { } else { }`
  SIf(branches: List(Branch), else_body: Option(List(Stmt)))
  /// `for <init>; <cond>; <post> { }` — a C-style counting loop. Any of the
  /// three clauses may be absent. The variable declared in `init` is scoped to
  /// the loop and is implicitly mutable, so `post` may advance it.
  SFor(
    init: Option(Stmt),
    cond: Option(Expr),
    post: Option(Stmt),
    body: List(Stmt),
  )
  /// `for each name in iterable { }` — iterate a vector, binding each element
  /// to `name` for the duration of the body. The element type is inferred from
  /// the vector; an optional `name: T` annotation overrides that inference.
  SForEach(
    name: String,
    elem_type: Option(TypeExpr),
    iterable: Expr,
    body: List(Stmt),
  )
  /// `return` or `return value`
  SReturn(value: Option(Expr))
  /// `echo value` — print any value followed by a newline.
  SEcho(value: Expr)
  /// `assert condition` — the condition must hold. What happens when it does
  /// not is decided by where it is written: in ordinary code it panics, and
  /// inside a `test` it records a failure and lets the rest of the suite run.
  ///
  /// `line` is the only source position in the statement tree, and it is here
  /// because a failed assertion is the one diagnostic a *reader of the output*
  /// has to locate in their own file — every other position the compiler reports
  /// belongs to a pass that runs before this point.
  SAssert(value: Expr, line: Int)
  /// `panic value` — stop the program immediately, showing `value` rendered as
  /// a string (the same conversion `echo` uses). Unlike `assert`, it always
  /// fires and takes any value, not just a boolean.
  SPanic(value: Expr)
  /// `break` — leave the innermost enclosing loop.
  SBreak
  /// `continue` — skip to the next iteration of the innermost enclosing loop.
  SContinue
  /// `async <call>` — run the call on its own virtual thread and carry on
  /// without waiting for it. Fire-and-forget is the whole of what it is: there
  /// is no handle, so nothing is left behind to read a result from, and the
  /// call cannot appear where a value is wanted. Every *other* call blocks its
  /// caller, which is why this is a statement of its own rather than a
  /// modifier on a declaration.
  SAsync(call: Expr)
  /// A bare expression used as a statement (e.g. a call).
  SExpr(expr: Expr)
}

pub type Branch {
  Branch(cond: Expr, body: List(Stmt))
}

pub type BinOp {
  OpGt
  OpLt
  OpGe
  OpLe
  OpEq
  OpNeq
  OpAdd
  OpSub
  OpMul
  OpDiv
  OpMod
  OpPow
  OpAnd
  OpOr
}

/// One piece of an interpolated string: literal text or an embedded
/// expression.
pub type IPart {
  ILit(String)
  IExpr(Expr)
}

/// One piece of a query's SQL body.
pub type SqlPart {
  /// Literal SQL, verbatim.
  SqlLit(String)
  /// An interpolated value. It never enters the SQL text: it becomes a
  /// placeholder, and the value is bound alongside.
  SqlParam(Expr)
  /// A `where { ... }` block — predicates that are each present or absent at
  /// runtime, combined into a `WHERE` clause (or into nothing at all, when none
  /// of them are present).
  SqlWhere(group: SqlGroup)
}

/// A group of conditional predicates and the connective joining them. A `where`
/// block is an `and` group; a nested `or { }` / `and { }` flips it.
pub type SqlGroup {
  SqlGroup(conjunction: Bool, items: List(SqlItem))
}

pub type SqlItem {
  /// `if <cond> { <sql> }` — one predicate, included when `cond` holds.
  SqlCond(cond: Expr, body: List(SqlPart))
  /// A nested group, parenthesised when it contributes more than one predicate.
  SqlNested(group: SqlGroup)
}

/// Every expression a query body carries, for the traversals that only need to
/// reach them.
pub fn sql_exprs(parts: List(SqlPart)) -> List(Expr) {
  list.flat_map(parts, fn(part) {
    case part {
      SqlLit(_) -> []
      SqlParam(e) -> [e]
      SqlWhere(group) -> group_exprs(group)
    }
  })
}

/// Every *condition* a query body carries — the `if <cond>` of each predicate in
/// a `where` block. These sit in boolean position, so they are held to the same
/// rule as an ordinary `if`.
pub fn sql_conds(parts: List(SqlPart)) -> List(Expr) {
  list.flat_map(parts, fn(part) {
    case part {
      SqlLit(_) | SqlParam(_) -> []
      SqlWhere(group) -> group_conds(group)
    }
  })
}

fn group_conds(group: SqlGroup) -> List(Expr) {
  list.flat_map(group.items, fn(item) {
    case item {
      SqlCond(cond, body) -> [cond, ..sql_conds(body)]
      SqlNested(inner) -> group_conds(inner)
    }
  })
}

fn group_exprs(group: SqlGroup) -> List(Expr) {
  list.flat_map(group.items, fn(item) {
    case item {
      SqlCond(cond, body) -> [cond, ..sql_exprs(body)]
      SqlNested(inner) -> group_exprs(inner)
    }
  })
}

pub type Expr {
  EInt(Int)
  EFloat(Float)
  EString(String)
  /// An interpolated string literal, e.g. `"{name} is here"`.
  EInterp(parts: List(IPart))
  /// `true`/`false` — the Bool literals. These are not atoms.
  EBool(Bool)
  /// An atom literal, e.g. `#SomeAtom` (without the `#`).
  EAtom(name: String)
  EIdent(String)
  /// A vector literal, e.g. `["Hello", "World"]`.
  EVector(items: List(Expr))
  EMember(target: Expr, field: String)
  ECall(callee: Expr, args: List(Arg))
  EIndex(target: Expr, index: Expr)
  /// `target[low:high]` where each bound is optional. Slices are inclusive of
  /// the high bound (per the language spec: `table[1:]` == `table[1:len-1]`).
  ESlice(target: Expr, low: Option(Expr), high: Option(Expr))
  EBinary(op: BinOp, left: Expr, right: Expr)
  /// `subject is Pattern` — a boolean type-check that may bind variables.
  EIs(subject: Expr, pattern: Pattern)
  /// `using <source> <kind>` — reads a table. What `source` is, and what comes
  /// back, depends on the kind (see `UsingKind`).
  EUsing(source: Expr, kind: UsingKind)
  /// `hive.json.parse(text) with Type` — gives a decode target type to an
  /// expression. Only valid on `hive.json.parse` calls.
  EWith(value: Expr, typ: TypeExpr)
  /// `await [f(a), g(b), h(c)]` — the *await-all*: every call in the list runs
  /// on its own virtual thread and the whole list is one barrier, resolving in
  /// order to a statically-sized vector of their results (`T[3]` here). It is
  /// the only form of `await` there is: one call on its own needs no keyword,
  /// because calling it already blocks for its value.
  ///
  /// `timeout` is the optional `with timeout <ms>` clause. It is one deadline
  /// across the whole barrier, and it changes what the await yields: without it
  /// the vector, with it a `Result<T[], hive.task.TimeoutError>` — running out
  /// of patience is a value, not a crash. It abandons the waiting, not the
  /// work.
  EAwait(calls: List(Expr), timeout: Option(Expr))
  /// `<call> with timeout <ms>` — a single blocking call, bounded. It yields
  /// `Result<T, hive.task.TimeoutError>` where the plain call yields `T`; on a
  /// `hive.syslink` send the bound folds into that module's own error instead
  /// of wrapping a second `Result` around the first.
  ETimed(call: Expr, ms: Expr)
}

/// Which kind of table a `using` expression reads. Naming the format in the
/// source (rather than inferring it from the path at runtime) is what lets the
/// compiler pick the right reader — and leave the spreadsheet machinery out of a
/// build that never touches a spreadsheet.
pub type UsingKind {
  /// `using <path>` or `using <path> as csv [separating by <sep>]` — a CSV,
  /// comma-separated when no separator is given. Yields
  /// `Result<Table, hive.TableError>`.
  UsingCsv(separator: Option(Expr))
  /// `using <path> as xlsx` — every sheet of an Excel workbook, in workbook
  /// order. Yields `Result<Table[dyn], hive.TableError>`.
  UsingXlsx
  /// `using <path> as ods` — every table of an OpenDocument spreadsheet, in
  /// document order. Yields `Result<Table[dyn], hive.TableError>`.
  UsingOds
  /// `using <connection> run <query>` — runs a declared query on an open
  /// connection. What it yields is what the query declared its rows to be.
  UsingQuery(query: Expr)
  /// `using <connection> run raw <text>` — runs SQL assembled at runtime.
  /// Nothing is known about the shape of what comes back, so it yields
  /// `Result<Table, hive.sql.SqlError>` with the header row intact.
  UsingRaw(text: Expr)
}

/// A type written the way source spells it, for error messages.
pub fn show_type(t: TypeExpr) -> String {
  case t {
    TVoid -> "void"
    TFunc(pure, params, ret) ->
      case pure {
        True -> "func("
        False -> "proc("
      }
      <> string.join(list.map(params, show_type), ", ")
      <> "): "
      <> show_type(ret)
    TName(pkg, name, args, dims) ->
      case pkg {
        Some(p) -> p <> "."
        None -> ""
      }
      <> name
      <> case args {
        [] -> ""
        _ -> "<" <> string.join(list.map(args, show_type), ", ") <> ">"
      }
      <> string.concat(list.map(dims, show_dim))
  }
}

pub fn show_dim(d: Dim) -> String {
  case d {
    DimEmpty -> "[]"
    DimStatic(n) -> "[" <> int.to_string(n) <> "]"
    DimDyn -> "[dyn]"
  }
}

/// An expression written the way its source spelled it.
///
/// This is for quoting an expression *back to the person who wrote it* — a failed
/// `assert` shows the condition that did not hold — so it aims to be recognisable
/// rather than to round-trip. Parentheses are put back around every binary
/// operation, since the tree no longer records which ones were written; a literal
/// is rendered the way Hive spells it, not the way Go does.
pub fn show_expr(e: Expr) -> String {
  case e {
    EInt(n) -> int.to_string(n)
    EFloat(f) -> float_source(f)
    EString(s) -> "\"" <> escape_source(s) <> "\""
    EInterp(parts) ->
      "\""
      <> string.concat(
        list.map(parts, fn(p) {
          case p {
            ILit(text) -> escape_source(text)
            IExpr(inner) -> "{" <> show_expr(inner) <> "}"
          }
        }),
      )
      <> "\""
    EBool(True) -> "true"
    EBool(False) -> "false"
    EAtom(name) -> "#" <> name
    EIdent(name) -> name
    EVector(items) -> "[" <> show_list(items) <> "]"
    EMember(target, field) -> show_expr(target) <> "." <> field
    ECall(callee, args) ->
      show_expr(callee)
      <> "("
      <> string.join(
        list.map(args, fn(a) {
          case a.name {
            Some(name) -> name <> ": " <> show_expr(a.value)
            None -> show_expr(a.value)
          }
        }),
        ", ",
      )
      <> ")"
    EIndex(target, index) ->
      show_expr(target) <> "[" <> show_expr(index) <> "]"
    ESlice(target, low, high) ->
      show_expr(target)
      <> "["
      <> show_bound(low)
      <> ":"
      <> show_bound(high)
      <> "]"
    EBinary(op, left, right) ->
      "(" <> show_expr(left) <> " " <> show_op(op) <> " " <> show_expr(right) <> ")"
    EIs(subject, pattern) ->
      show_expr(subject) <> " is " <> show_pattern(pattern)
    // These carry more than an expression's worth of syntax, and an assertion
    // that leans on one is better read in the file than paraphrased here.
    EUsing(source, _) -> "using " <> show_expr(source)
    EWith(value, typ) -> show_expr(value) <> " with " <> show_type(typ)
    EAwait(calls, timeout) ->
      "await ["
      <> show_list(calls)
      <> "]"
      <> case timeout {
        Some(ms) -> " with timeout " <> show_expr(ms)
        None -> ""
      }
    ETimed(call, ms) -> show_expr(call) <> " with timeout " <> show_expr(ms)
  }
}

fn show_list(items: List(Expr)) -> String {
  string.join(list.map(items, show_expr), ", ")
}

fn show_bound(bound: Option(Expr)) -> String {
  case bound {
    Some(e) -> show_expr(e)
    None -> ""
  }
}

// `1.0` survives Gleam's own float formatting; what needs care is that Hive
// writes a float with a decimal point even when it is whole.
fn float_source(f: Float) -> String {
  let text = float.to_string(f)
  case string.contains(text, ".") || string.contains(text, "e") {
    True -> text
    False -> text <> ".0"
  }
}

// Put back the escapes the lexer took out, so the quoted source reads as source.
fn escape_source(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\t", "\\t")
  |> string.replace("\r", "\\r")
}

fn show_op(op: BinOp) -> String {
  case op {
    OpGt -> ">"
    OpLt -> "<"
    OpGe -> ">="
    OpLe -> "<="
    OpEq -> "=="
    OpNeq -> "!="
    OpAdd -> "+"
    OpSub -> "-"
    OpMul -> "*"
    OpDiv -> "/"
    OpMod -> "%"
    OpPow -> "**"
    OpAnd -> "&&"
    OpOr -> "||"
  }
}

fn show_pattern(p: Pattern) -> String {
  case p {
    PConstructor(path, []) -> string.join(path, ".")
    PConstructor(path, bindings) ->
      string.join(path, ".") <> "(" <> string.join(bindings, ", ") <> ")"
    PVector(elems, rest) -> {
      let parts =
        list.map(elems, fn(el) {
          case el {
            PElemLit(value) -> show_expr(value)
            PElemBind(name) -> name
          }
        })
      let parts = case rest {
        Some(name) -> list.append(parts, ["..." <> name])
        None -> parts
      }
      "[" <> string.join(parts, ", ") <> "]"
    }
    PString(parts) ->
      "\""
      <> string.concat(
        list.map(parts, fn(part) {
          case part {
            SPatLit(text) -> escape_source(text)
            SPatHole(name) -> "{" <> name <> "}"
          }
        }),
      )
      <> "\""
  }
}

/// Whether an expression can be evaluated more than once without changing what
/// the program does: no call, no `using` read, no `with` decode, no `await`, so
/// nothing observable happens and nothing costly is recomputed.
///
/// Codegen reads a pattern's subject once to test it and again for every value it
/// binds, so a subject that is *not* repeatable has to be held in a temporary
/// first — otherwise `if hive.file.write(p, c) is Result.Ok(n)` would write the
/// file twice.
pub fn repeatable(e: Expr) -> Bool {
  case e {
    EInt(_) | EFloat(_) | EString(_) | EBool(_) | EAtom(_) | EIdent(_) -> True
    EMember(target, _) -> repeatable(target)
    EIndex(target, index) -> repeatable(target) && repeatable(index)
    ESlice(target, low, high) ->
      repeatable(target)
      && list.all(option.values([low, high]), repeatable)
    EVector(items) -> list.all(items, repeatable)
    EInterp(parts) -> list.all(parts, repeatable_part)
    EBinary(_, left, right) -> repeatable(left) && repeatable(right)
    EIs(subject, _) -> repeatable(subject)
    // Each of these does work: a call runs a body, `using` reads a file or a
    // database, `with` decodes, and an `await` spawns every call it holds.
    ECall(_, _) | EUsing(_, _) | EWith(_, _) | EAwait(_, _) | ETimed(_, _) ->
      False
  }
}

fn repeatable_part(part: IPart) -> Bool {
  case part {
    ILit(_) -> True
    IExpr(inner) -> repeatable(inner)
  }
}

/// The sub-expressions a `using` kind carries: a CSV's separator, or a query's
/// SQL. The traversals that only need to reach every expression use this instead
/// of matching each kind for themselves.
pub fn using_exprs(kind: UsingKind) -> List(Expr) {
  case kind {
    UsingCsv(Some(separator)) -> [separator]
    UsingCsv(None) | UsingXlsx | UsingOds -> []
    UsingQuery(query) -> [query]
    UsingRaw(text) -> [text]
  }
}

/// One argument in a call. Arguments may be passed by name
/// (`f(port: 80, h)`); only the unnamed ones need to be in order — they fill
/// whichever parameters the named arguments didn't claim, in declaration
/// order.
pub type Arg {
  Arg(name: Option(String), value: Expr)
}

pub type Pattern {
  /// e.g. `Result.Ok(table)` -> path ["Result", "Ok"], bindings ["table"].
  PConstructor(path: List(String), bindings: List(String))
  /// A vector pattern, e.g. `["a", x, ...tail]`: a fixed sequence of element
  /// sub-patterns matched positionally, with an optional `...rest` tail.
  /// `rest` is `None` for a fixed-length pattern (`["a", "b"]`, matches only a
  /// vector of exactly that length) and `Some(name)` when a trailing `...name`
  /// is present (matches a vector of *at least* that length, binding the
  /// leftover elements to `name`; the name is `_` when the tail is discarded).
  PVector(elems: List(PatElem), rest: Option(String))
  /// A string template pattern, e.g. `"/api/{id}/{name}/delete"`: literal text
  /// that must match verbatim interleaved with `{name}` holes that bind the
  /// text spanning to the next literal. A pattern with no holes is a plain
  /// exact-match against the literal.
  PString(parts: List(StrPat))
}

/// One element of a vector pattern.
pub type PatElem {
  /// A literal the corresponding element must equal (a string, number,
  /// boolean, or atom literal).
  PElemLit(value: Expr)
  /// A binding: an identifier that captures the element. The name `_` matches
  /// any element and binds nothing.
  PElemBind(name: String)
}

/// One piece of a string template pattern.
pub type StrPat {
  /// Literal text that must appear verbatim at this position.
  SPatLit(text: String)
  /// A `{name}` hole binding the text that spans to the next literal (or to
  /// the end of the string when it is the final piece). The name `_` matches
  /// but binds nothing.
  SPatHole(name: String)
}
