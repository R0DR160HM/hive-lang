# 02 — Grammar

EBNF, over the terminals [01](01-lexical.md) produces. `|` is alternation,
`[x]` optional, `{x}` zero or more, `(x)` grouping, `"x"` a literal token.
Terminals from the lexer are `UPPER_CASE`.

```
IDENT        camelCase, PascalCase or UPPER_CASE identifier (1.4)
INT FLOAT    integer and float literals
STRING       a "...", `...` or raw`...` string with no interpolation
INTERP       a "..." or `...` string holding at least one {expression}
             (a raw`...` string never interpolates, so it is always STRING)
ATOM         #Name
PATH         an import path, captured whole (1.3.3)
SQL          a query body, captured whole (1.3.3)
```

## 2.1 A file

```
file        = { import } { declaration } EOF ;
```

Imports are written outside any callable. A file needs no `main`, and one
holding only tests, or only declarations for another file, is a whole file.

## 2.2 Imports

```
import      = "import" PATH [ "as" IDENT ] ;
```

The path is one of four kinds, and the path itself says which — see
[12](12-modules.md). The `as` name is `camelCase`.

## 2.3 Declarations

```
declaration = type-decl | func-decl | proc-decl | query-decl | test-decl ;

type-decl   = "type" IDENT "{" type-body "}" ;
type-body   = { field } { variant } { field } ;
variant     = IDENT [ "{" { field } "}" ] ;
field       = IDENT ":" type ;

func-decl   = "func" IDENT "(" [ params ] ")" ":" type block ;
proc-decl   = "proc" IDENT "(" [ params ] ")" ":" type block ;
query-decl  = "query" IDENT "(" [ params ] ")" ":" type SQL ;
test-decl   = "test" STRING block ;

params      = param { "," param } ;
param       = IDENT ":" [ "mut" ] type ;
```

A field list and a variant list may be interleaved: a field written outside any
variant is added to **every** variant. A type with no variants is a struct; a
type with variants is a tagged union. `mut` on a parameter is legal only in a
`proc` ([08](08-mutability-and-values.md)).

## 2.4 Types

```
type        = "void"
            | fn-type
            | named-type ;

fn-type     = ( "func" | "proc" ) "(" [ type-list ] ")" ":" type ;
type-list   = type { "," type } ;

named-type  = qualifier IDENT [ type-args ] { dim } ;
qualifier   = { IDENT "." } ;
type-args   = "<" type { "," type } ">" ;

dim         = "[" "]"           (* a parameter spelling: any length *)
            | "[" "dyn" "]"     (* dynamic: guards its indexes *)
            | "[" INT "]" ;     (* static: exactly that many *)
```

`Str[3][2]` is two vectors of three. A `dim` list reads left to right as the
element type gains outer layers; see [03](03-types.md#33-vectors).

## 2.5 Statements

```
block       = "{" { statement } "}" ;

statement   = var-decl
            | typed-decl
            | assign
            | compound-assign
            | step
            | if-stmt
            | for-stmt
            | return-stmt
            | echo-stmt
            | assert-stmt
            | panic-stmt
            | "break"
            | "continue"
            | async-stmt
            | expression ;

var-decl    = [ "mut" ] IDENT ":=" [ "async" ] expression ;
typed-decl  = [ "mut" ] type IDENT "=" [ "async" ] expression ;

assign      = lvalue "=" expression ;
lvalue      = IDENT { "." IDENT | "[" expression "]" } ;

compound-assign
            = lvalue ( "+=" | "-=" | "*=" | "/=" ) expression ;
step        = lvalue ( "++" | "--" ) ;

if-stmt     = "if" expression block { "else" "if" expression block }
                                    [ "else" block ] ;

for-stmt    = "for" [ statement ] ";" [ expression ] ";" [ statement ] block
            | "for" "each" IDENT [ ":" type ] "in" expression block ;

return-stmt = "return" [ expression ] ;
echo-stmt   = "echo" expression ;
assert-stmt = "assert" expression ;
panic-stmt  = "panic" expression ;
async-stmt  = "async" call ;
```

A `;` on its own is skipped, so a statement may be written with one after it.

`var-decl` infers the type, and infers a **static** vector length from the value;
`typed-decl` states it. Only a `typed-decl` can say `[dyn]`
([10](10-bounds.md#103-a-declared-length-is-a-promise)).

A counting loop's init clause declares a variable that is **implicitly
mutable** — the post clause advances it — so `for i := 0; i < 10; i++` needs no
`mut`, and that counter is held to the `mut` naming rule (never `UPPER_CASE`).

## 2.6 Expressions

Loosest to tightest:

| level | operators | associativity |
| --- | --- | --- |
| 1 | `\|\|` | left |
| 2 | `&&` | left |
| 3 | `is`, `bounds` | non-associative |
| 4 | `>` `<` `>=` `<=` `==` `!=` | non-associative |
| 5 | `+` `-` | left |
| 6 | `*` `/` `%` | left |
| 7 | unary `-` | prefix |
| 8 | `**` | right |
| 9 | `with` clause | postfix |
| 10 | call, index, slice, member | postfix, left |
| 11 | primary | — |

Unary `-` binds **tighter** than `* / %` and **looser** than `**`, so `-2 ** 2`
is `-(2 ** 2)` and `2 ** -3` reads the sign as part of the exponent.

```
expression  = or-expr ;
or-expr     = and-expr { "||" and-expr } ;
and-expr    = is-expr { "&&" is-expr } ;

is-expr     = cmp-expr [ "is" pattern ]
            | cmp-expr "bounds" add-expr ;

cmp-expr    = add-expr [ ( ">" | "<" | ">=" | "<=" | "==" | "!=" ) add-expr ] ;
add-expr    = mul-expr { ( "+" | "-" ) mul-expr } ;
mul-expr    = unary-expr { ( "*" | "/" | "%" ) unary-expr } ;
unary-expr  = "-" unary-expr | pow-expr ;
pow-expr    = with-expr [ "**" unary-expr ] ;

with-expr   = postfix-expr [ "with" "timeout" add-expr
                           | "with" type ] ;

postfix-expr= primary { call-suffix | index-suffix | member-suffix } ;
call-suffix = "(" [ args ] ")" ;
index-suffix= "[" expression "]"
            | "[" [ expression ] ":" [ expression ] "]" ;
member-suffix = "." IDENT ;

args        = arg { "," arg } ;
arg         = [ IDENT ":" ] expression ;

primary     = INT | FLOAT | STRING | INTERP | ATOM | "true" | "false"
            | IDENT
            | "_"
            | vector-lit
            | await-all
            | using-expr
            | "(" expression ")" ;

vector-lit  = "[" [ expression { "," expression } ] "]" ;
await-all   = "await" "[" call { "," call } "]" ;
```

`v bounds i` is **sugar** for `i >= 0 && i < hive.len(v)`. The `len` is written
qualified so the guard means the same thing in a program that declared a `len`
of its own ([13](13-builtins.md#a-declaration-of-your-own-wins)).

`_` is a **hole**, legal only as a call argument, where it makes the call a
partial application ([05](05-expressions.md#54-function-values)), and as a
binding that throws its value away.

`async` is **not** an expression. It says how a call is run, not what it
evaluates to, so it appears only as a statement of its own and on the value side
of a declaration. Anywhere else it is a compile error.

Every entry of an `await-all` must be a **call**: a value already in hand has
nothing to wait for. `await []` is a compile error.

A slice's high bound is **inclusive** — `t[1:3]` is three elements.

## 2.7 Patterns

```
pattern     = ctor-pattern | vector-pattern | string-pattern ;

ctor-pattern= path [ "(" [ binding { "," binding } ] ")" ] ;
path        = IDENT { "." IDENT } ;
binding     = IDENT | "_" ;

vector-pattern
            = "[" [ element { "," element } [ "," "..." IDENT ] ] "]" ;
element     = INT | FLOAT | STRING | ATOM | "true" | "false"
            | IDENT | "_" ;

string-pattern = STRING | INTERP ;   (* holes are {name} *)
```

A string pattern's holes must be plain binding names, and two holes may not sit
side by side. See [07](07-patterns.md).

## 2.8 `using`

```
using-expr  = "using" postfix-expr [ using-tail ] ;

using-tail  = "as" "csv" [ "separating" "by" postfix-expr ]
            | "as" "xlsx"
            | "as" "ods"
            | "run" postfix-expr
            | "run" "raw" postfix-expr ;
```

The operand is parsed at the postfix level, so a call is consumed whole and none
of the words above can be mistaken for an operator. A bare `using <path>` is a
comma-separated CSV. See [14](14-stdlib.md#146-reading-tables-using).

## 2.9 Query bodies

A `query` body is SQL, captured whole by the lexer and parsed by its own small
grammar:

```
sql-body    = { sql-literal | sql-param | where-block } ;
sql-param   = "{" expression "}" ;

where-block = "WHERE" "{" { sql-item } "}" ;
sql-item    = "if" expression "{" sql-literal "}"
            | ( "or" | "and" ) "{" { sql-item } "}" ;
```

An interpolated `{param}` never enters the SQL text: it becomes a placeholder
and the value is bound alongside. See
[04](04-declarations.md#45-query).
