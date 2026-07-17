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

pub type TypeExpr {
  TVoid
  /// A named type, optionally package-qualified (e.g. `hive.TableError`),
  /// with `dims` trailing `[]` array markers (e.g. `String[][]` -> dims 2).
  TName(pkg: Option(String), name: String, dims: Int)
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
}

pub type Expr {
  EInt(Int)
  EString(String)
  EBool(Bool)
  EIdent(String)
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
