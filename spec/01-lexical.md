# 01 — Lexical structure

## 1.1 Source text

A Hive source file is **UTF-8** text with the extension **`.hive`**. There is no
byte-order mark handling: a BOM is an ordinary character and will fail to lex.

Line endings are normalised before lexing: `\r\n` and a lone `\r` both become
`\n`. This happens first, so nothing downstream — line counting, comment
scanning, multiline string capture — ever sees a carriage return.

A file has no header. What it declares is what it holds; see
[04](04-declarations.md).

## 1.2 Whitespace and comments

Spaces, tabs and newlines separate tokens and are otherwise insignificant. Hive
is not indentation-sensitive, and no statement is terminated by a newline.

A comment runs from `//` to the end of the line. The newline itself is not part
of the comment, so line counting is unaffected. There is no block comment
form — inside a `query` body, which is SQL rather than Hive, SQL's own `--` and
`/* */` are recognised instead ([04](04-declarations.md#45-query)).

```hive
// A comment. The whole line, and nothing of the next.
x := 1 // ...or the tail of one.
```

## 1.3 Tokens

The lexer produces a flat token list terminated by `EOF`. It commits to the
first pattern that fits, longest-match first, which is why the two-character
operators are listed before their one-character prefixes below.

### Keywords

Every keyword is lower case **and only lower case**:

```
import   proc     func     query    test     type
if       else     return   is       using    with
void     true     false    echo     assert   panic
dyn      mut      async    await    for      in
each     bounds   break    continue
```

A word that is a keyword in some other casing — `IF`, `Proc`, `VOID` — is
**neither a keyword nor a name**. It is a compile error naming both readings.
The alternative, reading it as an identifier, would hide the mistake somewhere
further on where its shape is no longer visible.

```hive
Proc main(): void { }   // compile error: `Proc` is a keyword written the wrong way
```

This reaches further than it first looks, because it holds of **every**
identifier position, not only the ones where a keyword would make sense. No
name anywhere in a program — a type, a variant, a field, a variable — may
lowercase to a keyword. So a tagged union of statement kinds cannot have a
variant called `Return`, `Break` or `Echo`, and a type cannot have a field
called `type` or `query`:

```hive
type Stmt {
	Return { value: Expr }   // compile error: `Return` is `return` shouted
	ReturnStmt { value: Expr }  // fine
}
```

The rule is worth the cost. A keyword that meant one thing in lower case and
another in Pascal case would make `Is` and `is`, or `Type` and `type`, two
different things that read alike — and the mistake would surface as a parse
error somewhere else entirely.

Three words are keywords **only where they are written**, and are ordinary
identifiers everywhere else: `as` (after an import path), `run` and `raw` (after
a `using` connection), `csv`, `xlsx`, `ods` and `separating`/`by` (in a `using`
clause), and `timeout` (in `with timeout`). Because they are not reserved, a
variable may be called `timeout`.

`raw` is also a keyword when a backtick is **touching** it, where it opens a
verbatim string ([1.3.2](#132-backtick-strings)). The space is what tells the two
apart: `run raw x` reads `raw` as the query keyword, and `` raw`x` `` as the
string prefix.

### Operators and punctuation

| | |
| --- | --- |
| two-character | `:=` `>=` `<=` `==` `!=` `**` `&&` `\|\|` `++` `--` `+=` `-=` `*=` `/=` |
| three-character | `...` (the vector-pattern rest marker) |
| one-character | `{` `}` `(` `)` `[` `]` `:` `;` `,` `.` `>` `<` `=` `+` `-` `*` `/` `%` |

`...` must be matched before `.`, and each two-character operator before its
prefix.

### Literals

**Integers** are decimal digit runs: `0`, `42`. There is no sign in the token —
`-1` is unary minus applied to `1`. An `Int` is 64-bit and signed
([05](05-expressions.md#57-arithmetic-at-the-edges)).

**Floats** are a digit run, a `.`, and a digit run: `1.0`, `3.14`. A trailing or
leading dot is not a float.

**Booleans** are the keywords `true` and `false`.

**Atoms** are `#` followed by a PascalCase name: `#Ready`, `#Nil`. The `#` is not
part of the name. An atom is declared nowhere, so the lexer is the only pass that
ever looks at its spelling, and it is where the PascalCase rule is enforced.

**Strings** come in three forms: `"..."`, `` `...` `` and `` raw`...` ``.

### 1.3.1 Double-quoted strings

A `"..."` string is UTF-8 text with escapes and `{expression}` interpolation.

| escape | means |
| --- | --- |
| `\n` `\t` `\r` | newline, tab, carriage return |
| `\"` | a quote |
| `\\` | a backslash |
| `\{` | a literal `{` — not the start of an interpolation |
| `\X` (any other) | `X` itself |

A `{` that is not escaped opens an **interpolation**, and everything to the
matching `}` is Hive expression source, captured raw for the parser to finish.
A newline inside a string is allowed and is part of it; a string that reaches
end of file unterminated is a compile error, reported at the line it opened on.

```hive
echo "a brace: \{ and {name} interpolated"
```

The resulting token is a plain string literal when there were no interpolations,
and otherwise a sequence of literal and code parts. Lowering is in
[15](15-lowering.md).

### 1.3.2 Backtick strings

A `` `...` `` string is a double-quoted string that **may span lines**. The
escapes are the same, the `{expression}` interpolation is the same
([1.3.1](#131-double-quoted-strings)), and two things are added: a newline in the
source is a newline in the value, and the indentation is removed at compile time.
Neither backtick form can contain a backtick.

```hive
echo `
	loaded {len(rows)} of {total}
	a literal brace: \{
`
```

**`` raw`...` `` is the same string with nothing read out of it**: no escapes and
no interpolation, so every brace is a brace and every backslash a backslash. It
is how text that is already somebody else's syntax — Go, SQL, a shell command, a
Dockerfile — is written, where a `{` or a `\n` is the language being carried
talking and not this one.

The backtick has to be **touching** the `raw`. `run raw` ([04](04-declarations.md#45-query))
is followed by an expression, and the space between them is what keeps that
reading available: `run raw x` is the query keyword, `` raw`x` `` is the prefix.

```hive
func goSource(): Str {
	return raw`
		package hive

		func Assert(ok bool) {
			if !ok { panic("hive: assertion failed") }
		}
	`
}
```

Both forms have their **indentation removed** at compile time: leading and
trailing blank lines are dropped, then the longest common leading whitespace of
every non-blank line is removed from all of them. So the string says what it
looks like, and where it sits in the file is a layout matter rather than part of
the value. The value above opens with `package hive` at column 1. A tab and a
space each count as one character of indentation, so a file that mixes them
within one block dedents by character count, not by visual width.

Dedenting happens **before** the escapes are read and the pieces split apart,
because the common indentation belongs to the body as a whole: a literal run
between two interpolations could not answer for the lines around it. So a `\t`
written in the source is never part of the margin — the margin is the whitespace
that is really there.

### 1.3.3 Two lexer modes

Two constructs are not Hive tokens at all, and the lexer switches into capturing
them the moment their keyword is read:

* After **`query`**, the `{ ... }` that follows is raw SQL. It is captured
  verbatim to its matching close brace (nesting counted), dedented like a
  backtick string, with its own `{param}` interpolations left in place for the
  parser. See [04](04-declarations.md#45-query).
* After **`import`**, what follows is a path, not tokens: `.`, `..` and `/`
  would each otherwise lex as an operator. Leading blanks are skipped and
  everything to the next whitespace is the path. A path may also be quoted
  (`import "./lib/my file"`), in which case everything to the closing quote is
  the path — nothing inside needs escaping — and an `as` after it still reads as
  `as`. A quoted path that reaches a newline is a missing closing quote, not a
  path that spans lines.

## 1.4 Names have shapes

A name's spelling says what it is. The three shapes do not overlap, and each is
enforced **where the name is declared** — that is the one place it can be fixed.

| shape | what it names |
| --- | --- |
| `camelCase` | variables, parameters, fields, every `proc`/`func`/`query`, and the name an `import` is reached through |
| `UPPER_CASE` | a variable nothing reassigns, which is how a constant is written |
| `PascalCase` | types, their variants, and atoms |
| lower case | the keywords, and nothing else |

So `Str` is a type and `str` is not; `MAX` holds still and `max` may not. The
types the language declares are spelled no differently from yours.

Precisely:

* `camelCase` — a lower-case letter followed by ASCII letters and digits.
* `PascalCase` — an upper-case letter followed by ASCII letters and digits.
* `UPPER_CASE` — an upper-case letter followed by upper-case letters, digits and
  underscores. A single `A` fits both this and PascalCase; no position accepts
  both, so nothing has to tell them apart.

A **`mut` variable may not be written `UPPER_CASE`**: that shape says constant
about something the program is about to reassign. A counting loop's counter is
implicitly mutable and is held to the same rule.

Any name may open with a **single `_`** — `_scratch`, `_helperOf`, `_MAX`. What
follows the underscore is spelled exactly as it would be without it. The
compiler asks nothing of the prefix and offers nothing for it: it is a note to
the next reader saying this name is private, or is here only because something
had to be. On its own, `_` is the binding that throws its value away, and is
legal only where a binding is.

Identifiers are ASCII: letters, digits and `_`, opening with a letter or `_`.

## 1.5 SQL keeps its own convention

Inside a `query` body the SQL keywords are **upper case** (`SELECT`, `FROM`,
`WHERE`), which is SQL's convention rather than Hive's. Everything else in there
is a name the database chose and keeps whatever spelling it has. One that
collides with a keyword is quoted, the way SQL has always done it:
`SELECT "order" FROM ...`.
