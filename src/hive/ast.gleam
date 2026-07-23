//// The Hive abstract syntax tree.

import gleam/option.{type Option}

pub type Module {
  Module(decls: List(Decl))
}

pub type Decl {
  /// A `proc`edure: a function that may perform side effects.
  ProcDecl(
    name: String,
    params: List(Field),
    return_type: TypeExpr,
    body: List(Stmt),
  )
  /// A `func`: a pure function (no side effects allowed in its body). When
  /// `async` is set the func was declared `async func` and runs on its own
  /// virtual thread (goroutine): calling it bare is fire-and-forget, calling
  /// it with `await` blocks for its value.
  FuncDecl(
    name: String,
    params: List(Field),
    return_type: TypeExpr,
    body: List(Stmt),
    async: Bool,
  )
  /// A `query`: a pure function whose body is inline SQL. The body is a
  /// sequence of literal SQL chunks and interpolated expressions; every
  /// interpolated value is sanitized at runtime before entering the SQL.
  QueryDecl(
    name: String,
    params: List(Field),
    return_type: TypeExpr,
    sql: List(IPart),
  )
  /// An algebraic data type. When `variants` is empty the type behaves as a
  /// plain struct made of `common_fields`. When it has variants, each variant
  /// is a struct and the type is a tagged union; `common_fields` are added to
  /// every variant.
  TypeDecl(name: String, variants: List(Variant), common_fields: List(Field))
}

pub type Field {
  Field(name: String, typ: TypeExpr)
}

pub type Variant {
  Variant(name: String, fields: List(Field))
}

/// One `[...]` marker on a vector type.
pub type Dim {
  /// `T[]` — a vector of unspecified length (legacy spelling).
  DimEmpty
  /// `T[3]` — a vector of static length.
  DimStatic(size: Int)
  /// `T[dyn]` or `T[dyn, 2]` — a dynamic vector, optionally with an initial
  /// size hint.
  DimDyn(initial: Option(Int))
}

pub type TypeExpr {
  TVoid
  /// A named type, optionally package-qualified (e.g. `hive.TableError`),
  /// with trailing vector markers (e.g. `Str[dyn][dyn]` -> two dims).
  TName(pkg: Option(String), name: String, dims: List(Dim))
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
  /// `assert condition` — panic at runtime when the condition is false.
  SAssert(value: Expr)
  /// `break` — leave the innermost enclosing loop.
  SBreak
  /// `continue` — skip to the next iteration of the innermost enclosing loop.
  SContinue
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

/// One piece of an interpolated string (or of a query's SQL body): literal
/// text or an embedded expression.
pub type IPart {
  ILit(String)
  IExpr(Expr)
}

pub type Expr {
  EInt(Int)
  EFloat(Float)
  EString(String)
  /// An interpolated string literal, e.g. `"{name} is here"`.
  EInterp(parts: List(IPart))
  /// `true`/`false`, which are aliases for the atoms `#True`/`#False`.
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
  /// `using <path> [with <delimiter>]`
  EUsing(path: Expr, delimiter: Option(Expr))
  /// `hive.json.parse(text) with Type` — gives a decode target type to an
  /// expression. Only valid on `hive.json.parse` calls.
  EWith(value: Expr, typ: TypeExpr)
  /// `await <async call>` — blocks the current virtual thread until the async
  /// function returns its value (a bare call, without `await`, is
  /// fire-and-forget).
  EAwait(value: Expr)
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
