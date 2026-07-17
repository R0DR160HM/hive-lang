//// Ties the pipeline together: source text -> tokens -> AST -> Go source.

import gleam/result
import hive/codegen
import hive/lexer
import hive/parser

/// Compile Hive source into the contents of the generated `main.go`.
pub fn compile(source: String) -> Result(String, String) {
  use tokens <- result.try(lexer.lex(source))
  use module <- result.try(parser.parse(tokens))
  Ok(codegen.generate(module))
}
