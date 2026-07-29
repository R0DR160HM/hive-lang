//// The one place that decides what a compile error looks like on the way out.
////
//// Every error the compiler reports opens with where it happened:
////
////     code-examples/2 - Types/types.hive:41: expected `]` but found `,`
////
//// which is what lets an editor jump straight to it — `:make` in Vim/Neovim
//// reads exactly this shape, and so would a language server built on these
//// passes later on.
////
//// A position is written where it is known and never read back out of a
//// message. `at` records the line as the message is built (the lexer and parser
//// are holding the token, so they are the only ones who know it) and `in_file`
//// puts the file in front of it once, in the module loader, which is the only
//// place that knows which file those tokens were read from. Nothing parses a
//// message to find its position again.
////
//// The passes after parsing — `hive/compiler`, `hive/codegen`, `hive/bounds` —
//// run on one flattened module whose nodes carry no positions, so they have no
//// line to report. `whole_file` places those against line 1: the message names
//// the declaration it is about, and an editor still opens the right file.

import gleam/int
import gleam/list
import gleam/string

/// Record the source line a message is about, producing everything but the
/// file — which whoever built the message does not yet know.
pub fn at(line: Int, message: String) -> String {
  int.to_string(line) <> ": " <> message
}

/// Finish a partial diagnostic from `at` by naming the file it came from.
pub fn in_file(file: String, partial: String) -> String {
  indent_rest(file <> ":" <> partial)
}

/// A diagnostic for an error with no line of its own, reported against the file
/// as a whole. It lands on line 1, so an editor opens the file at the top.
pub fn whole_file(file: String, message: String) -> String {
  in_file(file, at(1, message))
}

// A message may run to several lines, and only its first is preceded by
// `file:line:`. Indenting the rest is what tells a tool reading the output that
// they continue the line above rather than starting a diagnostic of their own.
fn indent_rest(text: String) -> String {
  case string.split(text, "\n") {
    [] -> text
    [first, ..rest] ->
      [first, ..list.map(rest, indent_line)]
      |> string.join("\n")
  }
}

fn indent_line(line: String) -> String {
  case string.trim(line) {
    "" -> ""
    _ -> "    " <> line
  }
}
