# Hive in your editor

`hive lsp` is a language server. An editor starts it, and from then on the
editor knows what the compiler knows:

* **what is wrong**, as you type, in the file and in the files it imports;
* **what a name is**: a variable's type, a function's signature, a field, a
  variant, a library call;
* **where a name was declared**, in this file or another;
* **what could come next**: a value's fields, a module's calls, a type's
  variants, the names in scope;
* **the file's outline**, and the file **reindented** as `hive indent` would.

It reads a file as the editor holds it, saved or not, and as a program of its
own, so there is no project to configure and no entrypoint to name.

Checked against Neovim 0.12, VS Code 1.136 and Claude Code 2.1.

## First: a `hive` that has it

The server is the compiler itself, from **v0.3.7** on.

```sh
$ hive version
v0.3.7
```

[INSTALL.md](INSTALL.md) installs it, and `hive use v0.3.7` moves an older one
forward. The editor starts whatever `hive` is on its `PATH`, so open the editor
from a shell where `hive version` answers.

## Neovim

Neovim **0.11 or later** has everything this needs, with no plugin. Put this in
`init.lua` — `~/.config/nvim/init.lua`, or `%LOCALAPPDATA%\nvim\init.lua` on
Windows:

```lua
-- A file ending in .hive is Hive.
vim.filetype.add({ extension = { hive = 'hive' } })

-- Hive files are answered by `hive lsp`.
vim.lsp.config('hive', { cmd = { 'hive', 'lsp' }, filetypes = { 'hive' } })
vim.lsp.enable('hive')
```

Open a `.hive` file and a mistake is underlined a moment after it is typed.
Neovim binds the rest itself, once a server is attached:

| key | what it does |
| --- | --- |
| `K` | what the name under the cursor is |
| `CTRL-]` | go to where it was declared (`CTRL-T` comes back) |
| `gO` | the file's outline |
| `]d` `[d` | the next and the previous error |
| `CTRL-W d` | the error under the cursor, in full |
| `CTRL-X CTRL-O` | in insert mode: what could come next |
| `:lua vim.lsp.buf.format()` | reindent the file |

For completion that opens as you type rather than on `CTRL-X CTRL-O`, add:

```lua
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    vim.lsp.completion.enable(true, args.data.client_id, args.buf, { autotrigger = true })
  end,
})
```

An error is underlined and listed, and its text is shown on `CTRL-W d`. To have
it written beside the line as well: `vim.diagnostic.config({ virtual_text = true })`.

## VS Code

VS Code starts a language server only through an extension, and Hive's is on
the Marketplace as
[Hive Language](https://marketplace.visualstudio.com/items?itemName=R0DR160HM.hive-lang).
Search for that name in the Extensions view, or install it from a shell:

```sh
$ code --install-extension R0DR160HM.hive-lang
```

Open a `.hive` file. It is coloured, the SQL of a `query` body included. Errors
appear in the editor and in the Problems panel; hovering a name says what it
is; `F12` goes to where it was declared; `Ctrl+Space` offers what could come
next, and so does typing a `.`; the Outline view lists the file's declarations;
and **Format Document** reindents it.

If `hive` is not on the `PATH` VS Code was started with, the extension says so,
and the settings name it:

```json
{ "hive.path": "C:\\Users\\you\\bin\\hive.exe" }
```

The extension has a repository of its own,
[hive-vscode](https://github.com/R0DR160HM/hive-vscode), whose README has the
rest: what is coloured, its snippets and its settings.

## A coding agent

An agent that can ask a language server reads far less to find things out: a
hover is one line, where the file that declares the thing is the file. `hive
agents` tells it so in the `AGENTS.md` and the pages it writes, and writes what
connects the server beside them.

**Claude Code** takes a language server from a plugin. `hive agents` writes one
to `.hivedocs/plugin`, and this loads it:

```sh
$ hive agents
$ claude --plugin-dir .hivedocs/plugin
```

From then on Claude Code's LSP tool answers for `.hive` files, and what is wrong
with a file is shown to it after each edit. An agent that runs inside an editor
has whatever the editor has, so the sections above are what set it up.

## Any other editor

Anything that speaks the Language Server Protocol can run it. What an editor's
configuration asks for:

* the command is `hive lsp`, talking over standard input and output;
* it is for files ending in `.hive`;
* a file is sent whole on every change, and positions are counted in UTF-16.

It answers hover, definition, completion (triggered by `.`), document symbols
and formatting, and publishes diagnostics.

## When nothing happens

* **`hive lsp` in a terminal prints nothing and waits.** That is it working: it
  is waiting for an editor to speak. `Ctrl+C` ends it.
* **`` `lsp` is not a command ``** — that `hive` is older than v0.3.7.
* **Neovim:** `:checkhealth vim.lsp` lists the servers attached to the buffer
  and where the log is. No `hive` there means the file's type is not `hive`
  (`:set filetype?`) or `hive` is not on the `PATH` (`:echo exepath('hive')`).
* **VS Code:** the Output panel has a **Hive** channel with what the server
  said. `"hive.trace.server": "verbose"` in the settings writes every message
  there, and **Hive: Restart Language Server** starts it again. In Restricted
  Mode a file is coloured and the server is not started: trusting the workspace
  starts it.

## What it does not do yet

* Find references, rename, and signature help.
* Say what a name is inside a backtick string or a `query` body.
* Read the other open files again on every keystroke: they are read again when
  a file is saved.
