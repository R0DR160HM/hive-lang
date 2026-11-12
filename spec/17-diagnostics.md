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
entrypoint, a command that does not exist, a flag the command does not take)
says who is complaining — `hive: ...` — because it is not a diagnostic about
anyone's source. Either one exits non-zero.

Every error goes to **standard error**, so `hive emit x.hive > main.go` never
writes one into the Go. What a command was asked for — the Go, a test report,
"No problems found" — goes to standard output.

## 17.2 Editor support

In Vim or Neovim:

```vim
setlocal makeprg=hive\ check\ %:S
setlocal errorformat=%-G\ %.%#,%f:%l:\ %m,%-G%.%#
```

`hive check` runs every pass that can refuse a program and stops there: no Go is
written, let alone compiled. It answers as fast as the front end does and writes
nothing next to the file — which is what makes it usable on every save. `:make`
then fills the quickfix list, and `:cn` walks the errors.

The two `%-G` items discard what is not a diagnostic: the first drops the
indented continuation lines of a message that runs on, the last drops everything
else.

## 17.3 Where an error lands

**On the line of what is wrong.** Every expression, statement and declaration
carries the file, line and column it was written at, through every pass, so a
mistake found by the type checks or the bounds pass is reported where a mistake
found by the parser is: against the thing itself. An index nothing proved in
range is reported at the index, an argument of the wrong type at the argument —
on its own line, where a call is written over several — and a field that does
not exist at the field.

The message still says which declaration it is in — `` in `total`: ... `` —
because that is the first thing a reader of a quickfix list wants to know, and an
error inside an imported module names **that module's file**. Every name in a
message is spelled the way the source spells it: `text.pad`, not the name the
generated Go knows it by. A copy of a generic is reported inside the generic's own
body, under the copy's name, so the message says which instantiation went wrong.

What is printed is `file:line:`. The column is known and carried with every
diagnostic, for a tool that asks the compiler directly; it is left out of the
printed form so the two-part pattern in [17.2](#172-editor-support) keeps
matching. A message about something nobody wrote — a file that could not be
read — is reported against the file's first line, because `file:0:` is not
somewhere to jump to.

## 17.4 What a message should say

Not normative, but it is the standard the language's own messages are held to:

* **Name the thing.** `` `v` is declared `Str[3]` ``, not "type mismatch".
* **Say what to do.** A bounds error that cannot prove an index says how to
  guard it. A `sort` that cannot sort in place names both fixes.
* **Say why, when the why is the point.** `hive.math.max(0, health)` is rejected
  because Hive never widens a number behind your back; a message that only said
  "expected Float, found Int" would leave the reader hunting for the conversion
  they are supposed to have known about.
* **Never guess.** A value computed and then dropped is reported with both
  fixes — keep it with `x := ...`, or discard it with `_ := ...` — because both
  readings are live and the compiler cannot know which was meant.

## 17.5 The one diagnostic that is not an error

A test failure is an answer, not a malfunction, so the report goes to **stdout**
and only a compile error or a toolchain failure goes to stderr
([16](16-testing.md)).
