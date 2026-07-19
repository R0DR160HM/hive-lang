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
  /// A `func`: a pure function (no side effects allowed in its body).
  FuncDecl(
    name: String,
    params: List(Field),
    return_type: TypeExpr,
    body: List(Stmt),
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
  /// `name := value` — type-inferred declaration.
  SVarDecl(name: String, value: Expr)
  /// `Type name = value` — declaration with an explicit type annotation.
  STypedDecl(typ: TypeExpr, name: String, value: Expr)
  /// `if ... { } else if ... { } else { }`
  SIf(branches: List(Branch), else_body: Option(List(Stmt)))
  /// `return` or `return value`
  SReturn(value: Option(Expr))
  /// `echo value` — print any value followed by a newline.
  SEcho(value: Expr)
  /// `assert condition` — panic at runtime when the condition is false.
  SAssert(value: Expr)
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
  ECall(callee: Expr, args: List(Expr))
  EIndex(target: Expr, index: Expr)
  /// `target[low:high]` where each bound is optional. Slices are inclusive of
  /// the high bound (per the language spec: `table[1:]` == `table[1:len-1]`).
  ESlice(target: Expr, low: Option(Expr), high: Option(Expr))
  EBinary(op: BinOp, left: Expr, right: Expr)
  /// `subject is Pattern` — a boolean type-check that may bind variables.
  EIs(subject: Expr, pattern: Pattern)
  /// `using <path> [with <delimiter>] [as <name>]`
  EUsing(path: Expr, delimiter: Option(Expr), as_name: Option(String))
}

pub type Pattern {
  /// e.g. `Result.Ok(table)` -> path ["Result", "Ok"], bindings ["table"].
  PConstructor(path: List(String), bindings: List(String))
}
