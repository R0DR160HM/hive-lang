# 17 — Diagnostics

## 17.1 The format

Every error opens with where it happened:

```
code-examples/2 - Types/types.hive:41: expected `]` but found `,`
```

`file:line: message`. That is the shape editors expect, so wiring one up needs
nothing more than a compile command and a pattern to read its output with.

A message that runs on continues on **indented** lines, so one error stays one
entry in a quickfix list:

```
main.hive:12: cannot prove this index is in range: the index is a computed
    expression. Bind it to a variable and guard it (`if j >= 0 && j < len(v)`).
```

A compile error is printed exactly as the compiler wrote it, with **nothing in
front of it** — prefixing it with a program name would put something before the
file name and break the pattern. Only a usage error (`hive build` with no
entrypoint) says who is complaining, because it is not a diagnostic about
anyone's source.

## 17.2 Editor support

In Vim or Neovim:

```vim
setlocal makeprg=hive\ check\ %:S
setlocal errorformat=%-G\ %.%#,%f:%l:\ %m,%-G%.%#
```

`hive check` runs every compiler pass and stops before the Go toolchain, so it
answers as fast as the front end does and writes nothing next to the file — which
is what makes it usable on every save. `:make` then fills the quickfix list, and
`:cn` walks the errors.

The two `%-G` items discard what is not a diagnostic: the first drops the
indented continuation lines of a message that runs on, the last drops everything
else.

## 17.3 Two limits worth knowing

**Errors from the passes after parsing land on a declaration.** Mutability,
bounds, the proc/func split and the type checks all run on a flattened module
whose nodes carry a position on a declaration and nowhere else, so the
declaration the mistake is inside is as precise as they get: its line is what the
message opens with, and its name is what the message says. A pass holding no
declaration at all reports against the file's first line, because `file:0:` is
not somewhere to jump to.

**In a program with imports, those same errors are reported against the
entrypoint**, even when the declaration at fault came from an imported module —
[flattening](12-modules.md#flattening) is what discards which file each
declaration came from. The line is still the declaration's own, which is to say a
line of a file the message does not name. Errors the lexer, parser and import
resolver raise do name the right file and line, because those run per file.

Both limits are consequences of one decision — that the passes after the loader
see one flat program — and both would be lifted by carrying a position on every
node. [18](18-conformance.md) records this as a known gap rather than a
requirement.

## 17.4 What a message should say

Not normative, but it is the standard the language's own messages are held to:

* **Name the thing.** `` `v` is declared `Str[3]` ``, not "type mismatch".
* **Say what to do.** A bounds error that cannot prove an index says how to
  guard it. A `sort` that cannot sort in place names both fixes.
* **Say why, when the why is the point.** `hive.math.max(0, health)` is rejected
  because Hive never widens a number behind your back; a message that only said
  "expected Float, found Int" would leave the reader hunting for the conversion
  they are supposed to have known about.
* **Never guess.** A misspelled keyword is reported as a miscased keyword *and*
  as a name that was taken, because both readings are live and the compiler
  cannot know which was meant.

## 17.5 The one diagnostic that is not an error

A test failure is an answer, not a malfunction, so the report goes to **stdout**
and only a compiler or toolchain failure goes to stderr
([16](16-testing.md)).
