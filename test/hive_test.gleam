import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import hive/ast
import hive/codegen
import hive/compiler
import hive/generics
import hive/modules
import hive/runtime
import hive/testreport

pub fn main() {
  gleeunit.main()
}

const example = "proc main(): void {
\tParsingResult parsedCsv = parse()
\tif parsedCsv is ParsingResult.Success(table, _) {
\t\techo \"Success!\"
\t\techo table
\t} else if parsedCsv is ParsingResult.NoData(_) {
\t\techo \"Empty CSV!\"
\t} if parsedCsv is ParsingResult.Error(error, _) {
\t\techo \"Error!\"
\t\techo error
\t}
}

type ParsingResult {
\tSuccess {
\t\theaderlessTable: String[dyn][dyn]
\t}
\tNoData
\tError {
\t\terror: hive.TableError
\t}
\ttimestamp: Int
}

proc parse(): ParsingResult {
\tcsv := using \"./test.csv\" as csv separating by \";\"
\tif csv is Result.Ok(table) {
\t\tif len(table) > 1 {
\t\t\treturn ParsingResult.Success(table[1:], hive.time.now())
\t\t}
\t\treturn ParsingResult.NoData(hive.time.now());
\t} else if csv is Result.Error(error) {
\t\treturn ParsingResult.Error(error, hive.time.now());
\t}
}
"

fn compile(src: String) -> String {
  let assert Ok(go) = compiler.compile(src)
  go
}

pub fn generates_package_and_import_test() {
  let go = compile(example)
  should.be_true(string.contains(go, "package main"))
  should.be_true(string.contains(go, "\"hiveapp/hive\""))
  // `echo` pulls in fmt.
  should.be_true(string.contains(go, "\"fmt\""))
}

pub fn typed_declaration_test() {
  let go = compile(example)
  should.be_true(string.contains(go, "var parsedCsv ParsingResult = parse()"))
}

pub fn echo_lowers_to_println_test() {
  let go = compile(example)
  should.be_true(string.contains(go, "fmt.Println(\"Success!\")"))
  should.be_true(string.contains(go, "fmt.Println(table)"))
  should.be_true(string.contains(go, "fmt.Println(error)"))
}

pub fn adt_pattern_match_test() {
  let go = compile(example)
  // Variant checks become type assertions; bindings read the asserted field
  // and `_` placeholders bind nothing.
  should.be_true(string.contains(go, "parsedCsv.(ParsingResultSuccess)"))
  should.be_true(string.contains(
    go,
    "table := parsedCsv.(ParsingResultSuccess).HeaderlessTable",
  ))
  should.be_true(string.contains(
    go,
    "error := parsedCsv.(ParsingResultError).Error",
  ))
  // The `_` in NoData(_) means the NoData branch introduces no bindings.
  should.be_false(string.contains(go, "_ := parsedCsv"))
}

pub fn vector_pattern_length_and_element_test() {
  let go =
    compile(
      "proc main(): void {\n\tv := [\"a\", \"b\", \"c\"]\n\tif v is [\"a\", x, ...tail] {\n\t\techo x\n\t\techo tail\n\t}\n}\n",
    )
  // A rest `...tail` makes the length a lower bound, and literal elements
  // compare positionally while `_`/named elements do not add a check.
  should.be_true(string.contains(go, "len(v) >= 2"))
  should.be_true(string.contains(go, "(v[0] == \"a\")"))
  // The named element and the rest bind into the branch body.
  should.be_true(string.contains(go, "x := v[1]"))
  should.be_true(string.contains(go, "tail := v[2:]"))
}

pub fn vector_pattern_fixed_length_test() {
  let go =
    compile(
      "proc main(): void {\n\tv := [\"a\", \"b\"]\n\tif v is [\"a\", \"b\"] {\n\t\techo \"hi\"\n\t}\n}\n",
    )
  // No rest: the length must match exactly.
  should.be_true(string.contains(go, "len(v) == 2"))
  should.be_false(string.contains(go, "len(v) >= 2"))
}

pub fn vector_pattern_wildcard_binds_nothing_test() {
  let go =
    compile(
      "proc main(): void {\n\tv := [\"a\", \"b\"]\n\tif v is [_, x] {\n\t\techo x\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "x := v[1]"))
  // `_` introduces no binding.
  should.be_false(string.contains(go, "_ := v[0]"))
}

pub fn string_pattern_exact_match_test() {
  let go =
    compile(
      "proc main(): void {\n\tp := \"/health\"\n\tif p is \"/health\" {\n\t\techo \"ok\"\n\t}\n}\n",
    )
  // A hole-less string pattern is a plain equality, not a MatchPattern call.
  should.be_true(string.contains(go, "p == \"/health\""))
  should.be_false(string.contains(go, "MatchPattern"))
}

pub fn string_pattern_template_test() {
  let go =
    compile(
      "proc main(): void {\n\tp := \"/api/v1/1/bob/delete\"\n\tif p is \"/api/v1/{id}/{name}/delete\" {\n\t\techo id\n\t\techo name\n\t}\n}\n",
    )
  // The leading literal becomes the prefix; each hole's terminating literal
  // becomes a separator (the last hole here ends on "/delete").
  should.be_true(string.contains(
    go,
    "hive.MatchPattern(p, \"/api/v1/\", []string{\"/\", \"/delete\"})",
  ))
  should.be_true(string.contains(go, "!= nil"))
  // Captures read back positionally in the branch body.
  should.be_true(string.contains(
    go,
    "id := hive.MatchPattern(p, \"/api/v1/\", []string{\"/\", \"/delete\"})[0]",
  ))
  should.be_true(string.contains(
    go,
    "name := hive.MatchPattern(p, \"/api/v1/\", []string{\"/\", \"/delete\"})[1]",
  ))
}

pub fn string_pattern_trailing_hole_captures_to_end_test() {
  let go =
    compile(
      "proc main(): void {\n\tp := \"/files/a/b\"\n\tif p is \"/files/{path}\" {\n\t\techo path\n\t}\n}\n",
    )
  // A hole that is the final piece runs to the end of the string, encoded as
  // an empty terminating separator.
  should.be_true(string.contains(
    go,
    "hive.MatchPattern(p, \"/files/\", []string{\"\"})",
  ))
}

pub fn string_pattern_adjacent_holes_rejected_test() {
  let result =
    compiler.compile(
      "proc main(): void {\n\tp := \"ab\"\n\tif p is \"{a}{b}\" {\n\t\techo a\n\t}\n}\n",
    )
  should.be_error(result)
}

pub fn string_pattern_non_ident_hole_rejected_test() {
  let result =
    compiler.compile(
      "proc main(): void {\n\tp := \"ab\"\n\tif p is \"/{a.b}/\" {\n\t\techo \"x\"\n\t}\n}\n",
    )
  should.be_error(result)
}

pub fn vector_pattern_rest_must_be_last_test() {
  let result =
    compiler.compile(
      "proc main(): void {\n\tv := [\"a\"]\n\tif v is [...tail, \"x\"] {\n\t\techo tail\n\t}\n}\n",
    )
  should.be_error(result)
}

pub fn vector_pattern_bad_element_rejected_test() {
  let result =
    compiler.compile(
      "proc main(): void {\n\tv := [\"a\"]\n\tif v is [x + 1] {\n\t\techo \"x\"\n\t}\n}\n",
    )
  should.be_error(result)
}

pub fn tagged_union_becomes_interface_test() {
  let go = compile(example)
  should.be_true(string.contains(go, "type ParsingResult interface"))
  should.be_true(string.contains(go, "type ParsingResultSuccess struct"))
  should.be_true(string.contains(go, "type ParsingResultNoData struct"))
  should.be_true(string.contains(go, "type ParsingResultError struct"))
}

pub fn common_field_added_to_every_variant_test() {
  let go = compile(example)
  // `timestamp: Int` is declared outside any variant, so every variant struct
  // gets a `Timestamp int` field.
  should.equal(count_occurrences(go, "Timestamp int"), 3)
}

pub fn using_lowers_to_readcsv_test() {
  let go = compile(example)
  should.be_true(string.contains(go, "hive.ReadCSV(\"./test.csv\", \";\")"))
}

pub fn result_pattern_lowers_to_predicates_test() {
  let go = compile(example)
  should.be_true(string.contains(go, "csv.IsOk()"))
  should.be_true(string.contains(go, "table := csv.Ok()"))
  should.be_true(string.contains(go, "csv.IsError()"))
  should.be_true(string.contains(go, "error := csv.Err()"))
}

pub fn positional_constructor_maps_fields_test() {
  let go = compile(example)
  // Constructors produce the union's interface type so the value can be
  // type-asserted later regardless of how it was declared.
  should.be_true(string.contains(
    go,
    "ParsingResult(ParsingResultSuccess{HeaderlessTable: table[1:], Timestamp: hive.Now()})",
  ))
  should.be_true(string.contains(
    go,
    "ParsingResult(ParsingResultError{Error: error, Timestamp: hive.Now()})",
  ))
  should.be_true(string.contains(
    go,
    "ParsingResult(ParsingResultNoData{Timestamp: hive.Now()})",
  ))
}

pub fn open_slice_is_verbatim_test() {
  let go = compile(example)
  // `table[1:]` (open high bound) maps straight to Go's `table[1:]`.
  should.be_true(string.contains(go, "table[1:]"))
}

pub fn void_proc_has_no_return_type_test() {
  let go = compile(example)
  should.be_true(string.contains(go, "func main() {"))
  should.be_true(string.contains(go, "func parse() ParsingResult {"))
}

// ---------------------------------------------------------------------------
// Types example features
// ---------------------------------------------------------------------------

pub fn str_type_and_func_test() {
  let go =
    compile(
      "func greet(name: Str): Str {\n\treturn name\n}\nproc main(): void {\n\techo greet(\"hi\")\n}\n",
    )
  should.be_true(string.contains(go, "func greet(name string) string {"))
}

pub fn string_interpolation_test() {
  let go =
    compile(
      "func f(): Str {\n\ta := \"x\"\n\tn := 2\n\treturn \"{a} has {n}\"\n}\nproc main(): void {}\n",
    )
  // Str pieces concatenate directly; other types go through hive.ToStr.
  should.be_true(string.contains(go, "(a + \" has \" + hive.ToStr(n))"))
}

pub fn multiline_string_is_dedented_test() {
  let go =
    compile(
      "func f(): Str {\n\treturn `\n\t\tThis\n\t\tis\n\t\tit\n\t`\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "\"This\\nis\\nit\""))
}

pub fn vector_types_and_literals_test() {
  let go =
    compile(
      "func f(): Str[3] {\n\tStr[2] a = [\"x\", \"y\"]\n\tStr[dyn] b = [\"x\"]\n\tStr[2] c = [\"x\", \"y\"]\n\treturn a + [\"z\"]\n}\nproc main(): void {}\n",
    )
  // Every vector flavor becomes a Go slice; `+` concatenates via the runtime.
  should.be_true(string.contains(go, "func f() []string {"))
  should.be_true(string.contains(go, "var a []string = []string{\"x\", \"y\"}"))
  should.be_true(string.contains(go, "var b []string = []string{\"x\"}"))
  should.be_true(string.contains(go, "var c []string = []string{\"x\", \"y\"}"))
  should.be_true(string.contains(go, "hive.Concat(a, []string{\"z\"})"))
}

pub fn atoms_get_a_table_and_constants_test() {
  let go =
    compile(
      "func f(): Atom {\n\ta := #Wax\n\treturn a\n}\nproc main(): void {}\n",
    )
  // #Nil always occupies slot 0; the program's own atoms follow.
  should.be_true(string.contains(go, "atom_Wax hive.Atom = 1"))
  should.be_true(string.contains(
    go,
    "hive.InitAtoms([]string{\"Nil\", \"Wax\"})",
  ))
  should.be_true(string.contains(go, "func f() hive.Atom {"))
}

pub fn atom_coerces_to_str_next_to_string_test() {
  let go =
    compile(
      "func f(): void {\n\tassert \"0\" + #Nil == \"00\"\n}\nproc main(): void {}\n",
    )
  // #Nil is the atom at value 0; as a Str it reads \"0\".
  should.be_true(string.contains(
    go,
    "hive.Assert(((\"0\" + hive.AtomToStr(hive.Nil)) == \"00\"))",
  ))
}

pub fn an_atom_is_not_a_condition_test() {
  // An atom is a label, not a yes or a no. It used to be truthy-unless-zero,
  // which made `if flag` a question about a numbering the program never chose.
  let assert Error(msg) =
    compiler.compile(
      "proc main(): void {\n\tflag := #Ready\n\tif flag {\n\t\techo 1\n\t}\n}\n",
    )
  should.be_true(string.contains(msg, "an atom is not a condition"))
}

pub fn an_atom_is_not_a_condition_inside_a_combination_test() {
  // `&&` and `||` combine conditions, so each side is a boolean position.
  let assert Error(msg) =
    compiler.compile(
      "proc main(): void {\n\tflag := #Ready\n\tif true && flag {\n\t\techo 1\n\t}\n}\n",
    )
  should.be_true(string.contains(msg, "an atom is not a condition"))
}

pub fn an_atom_is_not_an_assert_or_a_loop_condition_test() {
  let assert Error(a) =
    compiler.compile("proc main(): void {\n\tassert #Ready\n}\n")
  should.be_true(string.contains(a, "an atom is not a condition"))
  let assert Error(b) =
    compiler.compile(
      "proc main(): void {\n\tfor ; #Ready; {\n\t\techo 1\n\t}\n}\n",
    )
  should.be_true(string.contains(b, "an atom is not a condition"))
}

pub fn atoms_are_compared_with_eq_test() {
  // The replacement, and it lowers to a plain comparison with no coercion.
  let go =
    compile(
      "proc main(): void {\n\tflag := #Ready\n\tif flag == #Ready {\n\t\techo 1\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "if (flag == atom_Ready) {"))
  should.be_false(string.contains(go, "hive.Bool("))
}

pub fn true_and_false_are_ordinary_atoms_test() {
  // Nothing is reserved but #Nil: an atom spelled #True is one the program
  // declared, and it lands wherever its first mention puts it.
  let go =
    compile(
      "func f(): Atom {\n\ta := #Wax\n\tb := #True\n\techo b\n\treturn a\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "atom_Wax hive.Atom = 1"))
  should.be_true(string.contains(go, "atom_True hive.Atom = 2"))
  should.be_true(string.contains(
    go,
    "hive.InitAtoms([]string{\"Nil\", \"Wax\", \"True\"})",
  ))
}

pub fn a_program_naming_no_atom_of_its_own_emits_no_table_test() {
  // #Nil alone is the runtime's default table, so there is nothing to register.
  let go =
    compile("proc main(): void {\n\techo #Nil\n}\n")
  should.be_false(string.contains(go, "hive.InitAtoms"))
  should.be_true(string.contains(go, "hive.Nil"))
}

pub fn bool_literals_are_go_bools_test() {
  // `true`/`false` are the Bool type (Go bool), not atoms, so they fit a
  // `Bool` field/return directly.
  let go =
    compile(
      "type Flag {\n\ton: Bool\n}\nfunc f(): Bool {\n\tx := Flag(true)\n\treturn x.on\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "On bool"))
  should.be_true(string.contains(go, "Flag{On: true}"))
}

pub fn float_and_safe_division_test() {
  let go =
    compile(
      "func f(): Float {\n\ta := 1.5\n\tb := 0.0\n\tn := 4\n\tm := 2\n\tk := n / m\n\tp := n ** m\n\t_unused := k + p\n\treturn a / b\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "a := 1.5"))
  // Division is zero-safe and ** goes through the runtime.
  should.be_true(string.contains(go, "hive.DivFloat(a, b)"))
  should.be_true(string.contains(go, "hive.DivInt(n, m)"))
  should.be_true(string.contains(go, "hive.PowInt(n, m)"))
}

pub fn modulo_operator_lowers_to_runtime_test() {
  let go =
    compile(
      "func f(): Int {\n\tn := 17\n\tm := 5\n\tx := 17.5\n\ty := 5.0\n\t_unused := x % y\n\treturn n % m\n}\nproc main(): void {}\n",
    )
  // `%` is zero-safe like `/`: integers use ModInt, floats use ModFloat.
  should.be_true(string.contains(go, "hive.ModInt(n, m)"))
  should.be_true(string.contains(go, "hive.ModFloat(x, y)"))
}

pub fn modulo_has_multiplicative_precedence_test() {
  // `%` binds tighter than `+`, so `2 + 3 % 2` is `2 + (3 % 2)`.
  let go =
    compile("func f(): Int {\n\treturn 2 + 3 % 2\n}\nproc main(): void {}\n")
  should.be_true(string.contains(go, "(2 + hive.ModInt(3, 2))"))
}

pub fn vector_equality_lowers_to_runtime_test() {
  // Go can't compare slices, so `==` / `!=` on vectors go through hive.VecEq.
  let go =
    compile(
      "func f(): Bool {\n\ta := [\"x\", \"y\"]\n\tb := [\"x\", \"y\"]\n\t_ne := a != b\n\treturn a == b\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.VecEq(a, b)"))
  should.be_true(string.contains(go, "!hive.VecEq(a, b)"))
}

pub fn scalar_equality_stays_native_test() {
  // Non-vector `==` keeps Go's native comparison, not VecEq.
  let go =
    compile(
      "func f(): Bool {\n\ta := \"x\"\n\tb := \"y\"\n\treturn a == b\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "(a == b)"))
  should.be_false(string.contains(go, "VecEq"))
}

pub fn is_binding_usable_in_same_condition_test() {
  let go =
    compile(
      "type T {\n\tA {\n\t\tv: Str\n\t}\n\tB\n}\nfunc f(): Str {\n\tx := T.A(\"ok\")\n\tif x is T.A(v) && v == \"ok\" {\n\t\treturn v\n\t}\n\treturn \"no\"\n}\nproc main(): void {}\n",
    )
  // The right operand of && reads the binding through its accessor (safe
  // because Go's && short-circuits), and the body re-binds it as a variable.
  should.be_true(string.contains(go, "x.(TA)"))
  should.be_true(string.contains(go, "(x.(TA).V == \"ok\")"))
  should.be_true(string.contains(go, "v := x.(TA).V"))
  // Constructors produce the interface type.
  should.be_true(string.contains(go, "T(TA{V: \"ok\"})"))
}

pub fn query_binds_interpolations_as_placeholders_test() {
  // An interpolated value never enters the SQL text: it becomes a placeholder
  // and the value is bound alongside, so nothing a caller supplies can change
  // what the statement means.
  let go =
    compile(
      "type U {\n\tname: Str\n}\nquery q(name: Str): U[dyn] {\n\tSELECT name FROM users u\n\tWHERE u.name = {name}\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "func q(name string) hive.SqlFragment {"))
  should.be_true(string.contains(go, "_sql += \"?\""))
  should.be_true(string.contains(go, "_args = append(_args, name)"))
  // The value is never spliced into the text.
  should.be_false(string.contains(go, "hive.SqlParam(name)"))
}

pub fn a_where_block_builds_its_clause_test() {
  // Present predicates are ANDed; a nested group is ORed and parenthesised;
  // nothing present means no WHERE clause at all.
  let go =
    compile(
      "type U {\n\tname: Str\n}\nquery q(a: Str, b: Int, c: Bool): U[dyn] {\n\tSELECT name FROM users\n\tWHERE {\n\t\tif a != \"\" { name = {a} }\n\t\tor {\n\t\t\tif b > 0 { n >= {b} }\n\t\t\tif c { flag = 1 }\n\t\t}\n\t}\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.SqlJoin(_p3, \" OR \", true)"))
  should.be_true(string.contains(go, "hive.SqlJoin(_p1, \" AND \", false)"))
  should.be_true(string.contains(go, "_sql += \" WHERE \" + _w0.Text"))
}

pub fn where_in_plain_sql_is_still_literal_test() {
  // A `where` block only opens when a `{` follows it, so ordinary SQL is safe.
  let go =
    compile(
      "type U {\n\tname: Str\n}\nquery q(n: Str): U[dyn] {\n\tSELECT name FROM users WHERE name = {n}\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "WHERE name = "))
  should.be_false(string.contains(go, "hive.SqlJoin"))
}

pub fn func_can_echo_test() {
  // Funcs may perform I/O, so echoing from a func is allowed.
  let go =
    compile("func f(): void {\n\techo \"ok\"\n}\nproc main(): void {}\n")
  should.be_true(string.contains(go, "fmt.Println(\"ok\")"))
}

pub fn func_can_read_files_test() {
  // `using` (file I/O) is allowed inside a func too.
  let go =
    compile(
      "func f(): Str {\n\tcsv := using \"./x.csv\"\n\treturn \"ok\"\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.ReadCSV(\"./x.csv\""))
}

pub fn func_cannot_call_proc_test() {
  // The one call restriction that remains: a func may not call a proc.
  let result =
    compiler.compile(
      "proc p(): void {}\nfunc f(): void {\n\tp()\n}\nproc main(): void {}\n",
    )
  should.be_error(result)
}

// ---------------------------------------------------------------------------
// Mutability
// ---------------------------------------------------------------------------

pub fn mut_declaration_and_reassignment_test() {
  let go =
    compile(
      "proc main(): void {\n\tmut x := \"a\"\n\tx = \"b\"\n\techo x\n}\n",
    )
  // A `mut` variable declares like any other but may be reassigned with `=`.
  should.be_true(string.contains(go, "x := \"a\""))
  should.be_true(string.contains(go, "x = \"b\""))
}

pub fn mut_index_assignment_test() {
  let go =
    compile(
      "proc main(): void {\n\tmut v := [\"a\", \"b\"]\n\tv[0] = \"c\"\n\techo v\n}\n",
    )
  should.be_true(string.contains(go, "v[0] = \"c\""))
}

pub fn mut_typed_dynamic_vector_test() {
  let go =
    compile(
      "proc main(): void {\n\tmut Str[dyn] v = [\"a\"]\n\tv = [\"a\", \"b\"]\n\techo v\n}\n",
    )
  should.be_true(string.contains(go, "var v []string = []string{\"a\"}"))
  should.be_true(string.contains(go, "v = []string{\"a\", \"b\"}"))
}

pub fn assign_to_immutable_is_rejected_test() {
  // `x` is immutable (no `mut`), so reassigning it is a compile error.
  let result =
    compiler.compile("proc main(): void {\n\tx := \"a\"\n\tx = \"b\"\n}\n")
  should.be_error(result)
}

pub fn assign_to_parameter_is_rejected_test() {
  // Parameters are immutable, so they cannot be reassigned.
  let result =
    compiler.compile(
      "func f(a: Str): Str {\n\ta = \"b\"\n\treturn a\n}\nproc main(): void {}\n",
    )
  should.be_error(result)
}

// ---------------------------------------------------------------------------
// The vector / string builtins (len, bytes, append, join, split, indexOf)
// ---------------------------------------------------------------------------

pub fn len_of_vector_counts_elements_test() {
  let go =
    compile(
      "func f(): Int {\n\tv := [\"a\", \"b\"]\n\treturn len(v)\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "return len(v)"))
}

pub fn len_of_string_counts_runes_test() {
  let go =
    compile(
      "func f(): Int {\n\ts := \"hi\"\n\treturn len(s)\n}\nproc main(): void {}\n",
    )
  // A Str's length is its character (rune) count, not its Go byte length.
  should.be_true(string.contains(go, "return hive.StrLen(s)"))
}

pub fn bytes_of_string_is_byte_length_test() {
  let go =
    compile(
      "func f(): Int {\n\ts := \"hi\"\n\treturn bytes(s)\n}\nproc main(): void {}\n",
    )
  // A Str's byte length is Go's builtin len over the string.
  should.be_true(string.contains(go, "return len(s)"))
}

pub fn bytes_of_vector_uses_runtime_test() {
  let go =
    compile(
      "func f(): Int {\n\tv := [\"a\", \"b\"]\n\treturn bytes(v)\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "return hive.Bytes(v)"))
}

pub fn split_lowers_to_runtime_test() {
  let go =
    compile(
      "func f(): Str[dyn] {\n\treturn split(\"a,b\", \",\")\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.Split(\"a,b\", \",\")"))
}

pub fn row_lowers_to_runtime_test() {
  let go =
    compile(
      "func f(t: Table): Str[dyn] {\n\treturn row(t, \"I\")\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.Row(t, \"I\")"))
}

pub fn column_lowers_to_runtime_test() {
  let go =
    compile(
      "func f(t: Table): Str[dyn] {\n\treturn column(t, \"B\")\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.Column(t, \"B\")"))
}

pub fn append_reassigns_mutable_vector_test() {
  let go =
    compile(
      "proc main(): void {\n\tmut Str[dyn] v = [\"a\"]\n\tappend(v, \"b\")\n\techo v\n}\n",
    )
  // `append` as a statement grows the slice and writes it back to the variable.
  should.be_true(string.contains(go, "v = append(v, \"b\")"))
}

pub fn append_on_immutable_is_rejected_test() {
  let result =
    compiler.compile(
      "proc main(): void {\n\tStr[dyn] v = [\"a\"]\n\tappend(v, \"b\")\n}\n",
    )
  should.be_error(result)
}

pub fn join_lowers_to_runtime_test() {
  let go =
    compile(
      "func f(): Str {\n\treturn join([\"a\", \"b\"], \"-\")\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.Join([]string{\"a\", \"b\"}, \"-\")"))
}

pub fn index_of_vector_lowers_to_runtime_test() {
  let go =
    compile(
      "proc main(): void {\n\tv := [\"a\", \"b\"]\n\tr := indexOf(v, \"b\")\n\tif r is Result.Ok(i) {\n\t\techo i\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.IndexOf(v, \"b\")"))
  should.be_true(string.contains(go, "r.IsOk()"))
}

pub fn index_of_string_searches_substring_test() {
  // A Str subject picks the substring overload, whose index counts runes.
  let go =
    compile(
      "proc main(): void {\n\ts := \"hello\"\n\tr := indexOf(s, \"ll\")\n\tif r is Result.Ok(i) {\n\t\techo i\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.IndexOfStr(s, \"ll\")"))
}

pub fn index_of_renders_the_sought_value_as_the_element_type_test() {
  // Searching a Table for a row: the literal must land as a []string, not as
  // whatever a bare vector literal would default to.
  let go =
    compile(
      "proc main(): void {\n\tStr[dyn][dyn] t = [[\"a\", \"b\"]]\n\tr := indexOf(t, [\"a\", \"b\"])\n\tif r is Result.Ok(i) {\n\t\techo t[i]\n\t}\n}\n",
    )
  should.be_true(string.contains(
    go,
    "hive.IndexOf(t, []string{\"a\", \"b\"})",
  ))
}

pub fn index_of_miss_carries_false_test() {
  // The Error payload is a plain Bool, so it binds and echoes as one.
  let go =
    compile(
      "proc main(): void {\n\tv := [\"a\"]\n\tr := indexOf(v, \"z\")\n\tif r is Result.Error(missed) {\n\t\techo missed\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "missed := r.Err()"))
}

// ---------------------------------------------------------------------------
// Calls, virtual threads and `async`
// ---------------------------------------------------------------------------

pub fn a_call_blocks_and_async_does_not_test() {
  let go =
    compile(
      "proc main(): void {\n\tmut x := \"hi\"\n\tasync work(x)\n\tx = work(x)\n\techo x\n}\nfunc work(text: Str): Str {\n\treturn text\n}\n",
    )
  // Nothing about the declaration says how it runs.
  should.be_true(string.contains(go, "func work(text string) string {"))
  // `async` at the call site is the goroutine; the plain call blocks.
  should.be_true(string.contains(go, "go work(x)"))
  should.be_true(string.contains(go, "x = work(x)"))
}

pub fn a_statement_call_has_no_goroutine_test() {
  let go =
    compile(
      "proc main(): void {\n\twork()\n}\nproc work(): void {\n\techo \"x\"\n}\n",
    )
  // A call discarded as a statement still waits for it: only `async` spawns.
  should.be_false(string.contains(go, "go work()"))
  should.be_true(string.contains(go, "work()"))
}

pub fn async_is_not_a_declaration_modifier_test() {
  let assert Error(msg) =
    compiler.compile(
      "async func work(): Str {\n\treturn \"x\"\n}\nproc main(): void {\n\techo work()\n}\n",
    )
  should.be_true(string.contains(msg, "`async` is not part of a declaration"))
}

pub fn async_has_no_value_test() {
  let assert Error(msg) =
    compiler.compile(
      "func work(): Str {\n\treturn \"x\"\n}\nproc main(): void {\n\th := async work()\n\techo h\n}\n",
    )
  should.be_true(string.contains(msg, "`async` has no value"))
}

pub fn async_takes_a_call_test() {
  let assert Error(msg) =
    compiler.compile("proc main(): void {\n\tasync \"hi\"\n}\n")
  should.be_true(string.contains(msg, "`async` takes a call"))
}

pub fn async_rejects_a_global_builtin_test() {
  // Firing off a builtin leaves nothing behind: its whole purpose is its value.
  let assert Error(msg) =
    compiler.compile(
      "proc main(): void {\n\tv := [\"a\"]\n\tasync len(v)\n}\n",
    )
  should.be_true(string.contains(msg, "fires a call off and keeps nothing"))
}

pub fn async_rejects_a_partial_application_test() {
  // `f(1, _)` makes a function value; nothing runs until something calls it.
  let assert Error(msg) =
    compiler.compile(
      "func add(a: Int, b: Int): Int {\n\treturn a + b\n}\nproc main(): void {\n\tasync add(1, _)\n}\n",
    )
  should.be_true(string.contains(msg, "makes this a partial application"))
}

pub fn async_rejects_a_constructor_test() {
  // A constructor builds a value and runs no body, so there is nothing to spawn.
  let assert Error(own) =
    compiler.compile(
      "type Box {\n\tn: Int\n}\nproc main(): void {\n\tasync Box(1)\n}\n",
    )
  should.be_true(string.contains(own, "is a constructor"))

  let assert Error(builtin) =
    compiler.compile(
      "proc main(): void {\n\tasync hive.net.HttpRequest(\"GET\", \"http://x\", [], \"\")\n}\n",
    )
  should.be_true(string.contains(builtin, "is a constructor"))
}

pub fn async_is_not_a_loop_clause_test() {
  // A loop's init and post exist to set up and advance the condition, and a call
  // nothing waits for has no value to advance it with.
  let assert Error(msg) =
    compiler.compile(
      "func f(): Int {\n\treturn 1\n}\nproc main(): void {\n\tfor async f(); true; {\n\t\tbreak\n\t}\n}\n",
    )
  should.be_true(string.contains(msg, "cannot be a loop's init or post clause"))
}

pub fn async_works_on_a_proc_and_on_the_standard_library_test() {
  let go =
    compile(
      "proc log(text: Str): void {\n\techo text\n}\nproc main(): void {\n\tasync log(\"x\")\n\tasync hive.task.sleep(10)\n}\n",
    )
  should.be_true(string.contains(go, "go log(\"x\")"))
  should.be_true(string.contains(go, "go hive.Sleep(10)"))
}

// ---------------------------------------------------------------------------
// Named arguments
// ---------------------------------------------------------------------------

pub fn named_args_reorder_call_test() {
  let go =
    compile(
      "func f(a: Str, b: Int): Str {\n\treturn a\n}\nproc main(): void {\n\techo f(b: 1, \"s\")\n}\n",
    )
  // `b` is claimed by name, so the unnamed \"s\" fills `a`.
  should.be_true(string.contains(go, "f(\"s\", 1)"))
}

pub fn named_args_on_constructor_test() {
  let go =
    compile(
      "type T {\n\tA {\n\t\tx: Str\n\t\ty: Int\n\t}\n}\nfunc f(): T {\n\treturn T.A(y: 2, \"s\")\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "T(TA{X: \"s\", Y: 2})"))
}

pub fn named_args_on_builtin_constructor_test() {
  let go =
    compile(
      "proc main(): void {\n\thive.net.httpServe(handler: h, port: 8080)\n}\nproc h(r: hive.net.HttpRequest): hive.net.HttpResponse {\n\treturn hive.net.HttpResponse(200, body: \"ok\", headers: [])\n}\n",
    )
  // Both the builtin call and the builtin constructor resolve named args.
  should.be_true(string.contains(go, "hive.HttpServe(8080, h)"))
  should.be_true(string.contains(
    go,
    "hive.HttpResponse{Status: 200, Headers: [][]string{}, Body: \"ok\"}",
  ))
}

pub fn duplicate_named_arg_is_rejected_test() {
  let result =
    compiler.compile(
      "func f(a: Str): Str {\n\treturn a\n}\nproc main(): void {\n\techo f(a: \"x\", a: \"y\")\n}\n",
    )
  should.be_error(result)
}

pub fn unknown_named_arg_is_rejected_test() {
  let result =
    compiler.compile(
      "func f(a: Str): Str {\n\treturn a\n}\nproc main(): void {\n\techo f(nope: \"x\")\n}\n",
    )
  should.be_error(result)
}

pub fn named_arg_on_unknown_target_is_rejected_test() {
  let result =
    compiler.compile("proc main(): void {\n\techo len(v: [\"a\"])\n}\n")
  should.be_error(result)
}

pub fn incomplete_named_call_is_rejected_test() {
  // Once named arguments are used, the full parameter list must be covered.
  let result =
    compiler.compile(
      "func f(a: Str, b: Int): Str {\n\treturn a\n}\nproc main(): void {\n\techo f(a: \"x\")\n}\n",
    )
  should.be_error(result)
}

// ---------------------------------------------------------------------------
// The hive.net standard library
// ---------------------------------------------------------------------------

pub fn http_request_lowers_test() {
  let go =
    compile(
      "proc f(): Str {\n\tr := hive.net.httpRequest(hive.net.HttpRequest(\"GET\", \"http://x\", [], \"\"))\n\tif r is Result.Ok(response) {\n\t\treturn response.body\n\t} else if r is Result.Error(error) {\n\t\treturn error.message\n\t}\n}\nproc main(): void {}\n",
    )
  // The builtin constructor is positional and the call goes through HttpSend.
  should.be_true(string.contains(
    go,
    "hive.HttpSend(hive.HttpRequest{Method: \"GET\", Url: \"http://x\", Headers: [][]string{}, Body: \"\"})",
  ))
  // Result payloads are typed, so builtin fields capitalize correctly.
  should.be_true(string.contains(go, "return response.Body"))
  should.be_true(string.contains(go, "return error.Message"))
}

pub fn http_serve_lowers_test() {
  let go =
    compile(
      "proc main(): void {\n\thive.net.httpServe(8080, handle)\n}\nproc handle(request: hive.net.HttpRequest): hive.net.HttpResponse {\n\treturn hive.net.HttpResponse(200, [], request.body)\n}\n",
    )
  should.be_true(string.contains(go, "hive.HttpServe(8080, handle)"))
  should.be_true(string.contains(
    go,
    "func handle(request hive.HttpRequest) hive.HttpResponse {",
  ))
  should.be_true(string.contains(
    go,
    "hive.HttpResponse{Status: 200, Headers: [][]string{}, Body: request.Body}",
  ))
}

pub fn bare_builtin_type_is_rejected_test() {
  // The bare `hive.HttpRequest` spelling is gone; the namespaced
  // `hive.net.HttpRequest` is required.
  let result =
    compiler.compile(
      "proc main(): void {\n\techo hive.HttpRequest(\"GET\", \"http://x\", [], \"\")\n}\n",
    )
  should.be_error(result)
}

pub fn func_can_use_net_test() {
  // hive.net is I/O, which funcs may now perform.
  let go =
    compile(
      "func f(): Str {\n\tr := hive.net.httpRequest(hive.net.HttpRequest(\"GET\", \"http://x\", [], \"\"))\n\treturn \"x\"\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.HttpSend("))
}

pub fn serve_handler_must_match_signature_test() {
  // Wrong parameter type: the handler must take exactly one hive.net.HttpRequest.
  let result =
    compiler.compile(
      "proc main(): void {\n\thive.net.httpServe(8080, bad)\n}\nproc bad(x: Int): hive.net.HttpResponse {\n\treturn hive.net.HttpResponse(200, [], \"\")\n}\n",
    )
  should.be_error(result)
}

pub fn serve_handler_must_be_a_proc_test() {
  let result =
    compiler.compile(
      "proc main(): void {\n\thive.net.httpServe(8080, nowhere)\n}\n",
    )
  should.be_error(result)
}

pub fn unknown_net_builtin_is_rejected_test() {
  let result =
    compiler.compile("proc main(): void {\n\thive.net.download(\"x\")\n}\n")
  should.be_error(result)
}

pub fn old_http_namespace_is_rejected_test() {
  // `hive.http` is gone; the module is `hive.net` now.
  let result =
    compiler.compile("proc main(): void {\n\thive.http.serve(8080, h)\n}\n")
  should.be_error(result)
}

pub fn bare_http_call_names_are_rejected_test() {
  // Every `hive.net` call names its protocol, so the old bare spellings point
  // at their replacements instead of reading as unknown members.
  let served =
    compiler.compile("proc main(): void {\n\thive.net.serve(8080, h)\n}\n")
  should.be_error(served)
  case served {
    Error(message) ->
      should.be_true(string.contains(message, "hive.net.httpServe"))
    Ok(_) -> panic as "expected an error"
  }
  let requested =
    compiler.compile(
      "proc main(): void {\n\techo hive.net.request(hive.net.HttpRequest(\"GET\", \"http://x\", [], \"\")) is Result.Ok(_)\n}\n",
    )
  should.be_error(requested)
  case requested {
    Error(message) ->
      should.be_true(string.contains(message, "hive.net.httpRequest"))
    Ok(_) -> panic as "expected an error"
  }
}

// ---------------------------------------------------------------------------
// hive.net: WebSockets
// ---------------------------------------------------------------------------

const ws_example = "proc main(): void {
\thive.net.wsServe(9001, handle)
}
proc handle(connection: hive.net.WsConnection): void {
\topening := hive.net.wsRequest(connection)
\techo opening.url
\tincoming := hive.net.wsReceive(connection)
\tif incoming is Result.Ok(message) {
\t\tsent := hive.net.wsSend(connection, message)
\t\tif sent is Result.Ok(count) {
\t\t\techo count
\t\t}
\t} else if incoming is Result.Error(error) {
\t\techo error.reason
\t}
\thive.net.wsClose(connection)
}
"

pub fn ws_server_lowers_test() {
  let go = compile(ws_example)
  should.be_true(string.contains(go, "hive.WsServe(9001, handle)"))
  // A ws handler is a void proc over an opaque connection.
  should.be_true(string.contains(
    go,
    "func handle(connection hive.WsConnection) {",
  ))
  should.be_true(string.contains(go, "hive.WsRequest(connection)"))
  should.be_true(string.contains(go, "hive.WsReceive(connection)"))
  should.be_true(string.contains(go, "hive.WsSend(connection, message)"))
  should.be_true(string.contains(go, "hive.WsClose(connection)"))
  // `wsRequest` yields an HttpRequest, so its fields capitalize.
  should.be_true(string.contains(go, "opening.Url"))
}

pub fn ws_client_lowers_test() {
  let go =
    compile(
      "proc main(): void {\n\topened := hive.net.wsConnect(\"ws://x/y\")\n\tif opened is Result.Ok(c) {\n\t\thive.net.wsClose(c)\n\t} else if opened is Result.Error(error) {\n\t\techo error.message\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.WsConnect(\"ws://x/y\")"))
  should.be_true(string.contains(go, "echo.Message") == False)
  should.be_true(string.contains(go, "error.Message"))
}

pub fn ws_handler_must_be_void_over_a_connection_test() {
  // An HTTP handler's shape is not a WebSocket handler's shape.
  let result =
    compiler.compile(
      "proc main(): void {\n\thive.net.wsServe(9001, h)\n}\nproc h(r: hive.net.HttpRequest): hive.net.HttpResponse {\n\treturn hive.net.HttpResponse(200, [], \"\")\n}\n",
    )
  should.be_error(result)
}

pub fn ws_send_arity_is_checked_test() {
  let result =
    compiler.compile(
      "proc main(): void {\n\topened := hive.net.wsConnect(\"ws://x\")\n\tif opened is Result.Ok(c) {\n\t\thive.net.wsSend(c)\n\t}\n}\n",
    )
  should.be_error(result)
}

// ---------------------------------------------------------------------------
// hive.net: raw TCP sockets
// ---------------------------------------------------------------------------

const socket_example = "proc main(): void {
\thive.net.socketServe(9002, handle)
}
proc handle(connection: hive.net.SocketConnection): void {
\techo hive.net.socketPeer(connection)
\tline := hive.net.socketReceiveLine(connection)
\tif line is Result.Ok(text) {
\t\thive.net.socketSend(connection, text)
\t} else if line is Result.Error(error) {
\t\techo error.reason
\t}
\thive.net.socketClose(connection)
}
"

pub fn socket_server_lowers_test() {
  let go = compile(socket_example)
  should.be_true(string.contains(go, "hive.SocketServe(9002, handle)"))
  should.be_true(string.contains(
    go,
    "func handle(connection hive.SocketConnection) {",
  ))
  should.be_true(string.contains(go, "hive.SocketPeer(connection)"))
  should.be_true(string.contains(go, "hive.SocketReceiveLine(connection)"))
  should.be_true(string.contains(go, "hive.SocketSend(connection, text)"))
  should.be_true(string.contains(go, "hive.SocketClose(connection)"))
}

pub fn socket_client_lowers_test() {
  let go =
    compile(
      "proc main(): void {\n\topened := hive.net.socketConnect(\"localhost\", 9002)\n\tif opened is Result.Ok(c) {\n\t\tchunk := hive.net.socketReceive(c, 256)\n\t\tif chunk is Result.Ok(text) {\n\t\t\techo text\n\t\t}\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.SocketConnect(\"localhost\", 9002)"))
  should.be_true(string.contains(go, "hive.SocketReceive(c, 256)"))
}

pub fn socket_handler_must_take_a_socket_connection_test() {
  let result =
    compiler.compile(
      "proc main(): void {\n\thive.net.socketServe(9002, h)\n}\nproc h(c: hive.net.WsConnection): void {\n\thive.net.wsClose(c)\n}\n",
    )
  should.be_error(result)
}

// ---------------------------------------------------------------------------
// hive.net: names, and where this machine is
// ---------------------------------------------------------------------------

const addresses_example = "proc main(): void {
\tfound := hive.net.resolve(\"cache-0.internal\")
\tif found is Result.Ok(addresses) {
\t\tfor each address in addresses {
\t\t\techo address
\t\t}
\t} else if found is Result.Error(error) {
\t\techo error.reason
\t\techo error.message
\t}
\there := hive.net.localAddress()
\tif here is Result.Ok(ip) {
\t\techo ip
\t}
}
"

pub fn resolve_and_local_address_lower_test() {
  let go = compile(addresses_example)
  should.be_true(string.contains(go, "hive.NetResolve(\"cache-0.internal\")"))
  should.be_true(string.contains(go, "hive.NetLocalAddress()"))
  // The error is a NetError: `reason` and `message`, like WsError and
  // SocketError next to it.
  should.be_true(string.contains(go, ".Reason"))
  should.be_true(string.contains(go, ".Message"))
}

pub fn resolve_yields_every_address_behind_a_name_test() {
  // A name stands for however many addresses are behind it, so the Ok payload is
  // a vector — walkable without an index, and `len`-able.
  let go =
    compile(
      "proc main(): void {\n\tfound := hive.net.resolve(\"cache-0.internal\")\n\tif found is Result.Ok(addresses) {\n\t\techo len(addresses)\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.NetResolve(\"cache-0.internal\")"))
  should.be_true(string.contains(go, "len("))
}

pub fn resolve_takes_a_name_test() {
  // A resolve with nothing to resolve, and one with a spare argument.
  should.be_error(
    compiler.compile("proc main(): void {\n\thive.net.resolve()\n}\n"),
  )
  should.be_error(compiler.compile(
    "proc main(): void {\n\thive.net.resolve(\"a\", \"b\")\n}\n",
  ))
}

pub fn resolve_accepts_a_named_argument_test() {
  let go =
    compile(
      "proc main(): void {\n\tfound := hive.net.resolve(name: \"cache-0.internal\")\n\tif found is Result.Ok(a) {\n\t\techo len(a)\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.NetResolve(\"cache-0.internal\")"))
}

pub fn local_address_takes_no_arguments_test() {
  should.be_error(compiler.compile(
    "proc main(): void {\n\thive.net.localAddress(\"eth0\")\n}\n",
  ))
}

pub fn net_error_is_reached_through_its_module_test() {
  // Every stdlib module owns its types, so the bare `hive.NetError` is refused
  // and pointed at `hive.net.NetError`.
  should.be_error(compiler.compile(
    "proc main(): void {\n\techo hive.NetError(\"a\", \"b\").reason\n}\n",
  ))
  let go =
    compile(
      "proc report(error: hive.net.NetError): void {\n\techo \"{error.reason}: {error.message}\"\n}\nproc main(): void {\n\tfound := hive.net.resolve(\"nowhere.invalid\")\n\tif found is Result.Error(error) {\n\t\treport(error)\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "func report(error hive.NetError)"))
}

pub fn a_bad_net_member_names_the_new_calls_test() {
  // The "available" list an unknown member is answered with has to name them,
  // or they are undiscoverable from the one place someone looks.
  let assert Error(msg) =
    compiler.compile("proc main(): void {\n\thive.net.lookup(\"x\")\n}\n")
  should.be_true(string.contains(msg, "resolve, localAddress"))
}

pub fn net_calls_accept_named_arguments_test() {
  let go =
    compile(
      "proc main(): void {\n\topened := hive.net.socketConnect(port: 9002, host: \"localhost\")\n\tif opened is Result.Ok(c) {\n\t\tchunk := hive.net.socketReceive(bytes: 64, connection: c)\n\t\tif chunk is Result.Ok(text) {\n\t\t\techo text\n\t\t}\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.SocketConnect(\"localhost\", 9002)"))
  should.be_true(string.contains(go, "hive.SocketReceive(c, 64)"))
}

// ---------------------------------------------------------------------------
// First-class functions and partial application
// ---------------------------------------------------------------------------

const fns_example = "func applyTwice(f: func(Int): Int, x: Int): Int {\n\treturn f(f(x))\n}\nfunc addN(n: Int, x: Int): Int {\n\treturn n + x\n}\nproc main(): void {\n\tadd5 := addN(5, _)\n\techo add5(10)\n\techo applyTwice(add5, 1)\n\tinc := addN(1, _)\n\tg := inc\n\techo g(41)\n}\n"

pub fn partial_application_lowers_to_closure_test() {
  let go = compile(fns_example)
  // `addN(5, _)` fixes the first argument and leaves a hole for the second.
  should.be_true(string.contains(
    go,
    "add5 := func(_h1 int) int { return addN(5, _h1) }",
  ))
}

pub fn function_typed_parameter_renders_test() {
  let go = compile(fns_example)
  // `f: func(Int): Int` lowers to a Go function type.
  should.be_true(string.contains(go, "func applyTwice(f func(int) int, x int) int"))
}

pub fn bare_reference_and_call_of_function_value_test() {
  let go = compile(fns_example)
  // A bare reference is just the value; calling a function-valued local is a
  // plain call.
  should.be_true(string.contains(go, "g := inc"))
  should.be_true(string.contains(go, "g(41)"))
}

pub fn serve_accepts_partial_application_handler_test() {
  let go =
    compile(
      "proc main(): void {\n\tdb := \"d\"\n\thive.net.httpServe(8080, handler(_, db))\n}\nproc handler(req: hive.net.HttpRequest, db: Str): hive.net.HttpResponse {\n\treturn hive.net.HttpResponse(200, [], db)\n}\n",
    )
  should.be_true(string.contains(
    go,
    "hive.HttpServe(8080, func(_h0 hive.HttpRequest) hive.HttpResponse { return handler(_h0, db) })",
  ))
}

pub fn func_typed_param_rejects_a_proc_value_test() {
  // A `func` parameter is pure, so a proc value cannot fill it.
  let result =
    compiler.compile(
      "func callF(f: func(Int): Int): Int {\n\treturn f(1)\n}\nproc impureFn(x: Int): Int {\n\treturn x\n}\nproc main(): void {\n\techo callF(impureFn)\n}\n",
    )
  should.be_error(result)
}

pub fn proc_typed_param_accepts_a_func_value_test() {
  // A `proc` parameter accepts either (a pure func widens to an impure proc).
  compiler.compile(
    "proc callP(f: proc(Int): Int): Int {\n\treturn f(1)\n}\nfunc pureFn(x: Int): Int {\n\treturn x\n}\nproc main(): void {\n\techo callP(pureFn)\n}\n",
  )
  |> should.be_ok
}

pub fn partial_application_of_proc_allowed_in_func_test() {
  // Wrapping a proc into a value does not *call* it, so it stays legal even
  // inside a func body.
  compiler.compile(
    "proc effect(a: Int, b: Int): Int {\n\treturn a + b\n}\nfunc makeAdder(n: Int): proc(Int): Int {\n\treturn effect(n, _)\n}\nproc main(): void {\n\tadd := makeAdder(3)\n\techo add(4)\n}\n",
  )
  |> should.be_ok
}

// ---------------------------------------------------------------------------
// The hive.json standard library
// ---------------------------------------------------------------------------

pub fn json_parse_with_derives_decoder_test() {
  let go =
    compile(
      "type User {\n\tname: Str\n\ttags: Str[3]\n}\nfunc f(text: Str): Str {\n\tparsed := hive.json.parse(text) with User\n\tif parsed is Result.Ok(user) {\n\t\treturn user.name\n\t} else if parsed is Result.Error(error) {\n\t\treturn error.path\n\t}\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.JsonParse(text, jsonDecode_User)"))
  // Static vector lengths are checked; only declared fields are read, so
  // unmapped JSON fields are simply ignored.
  should.be_true(string.contains(go, "hive.JsonVecN(v, p, 3, hive.JsonStr)"))
  should.be_false(string.contains(go, "JsonExactKeys"))
  // Result payloads are typed: bindings capitalize builtin/struct fields.
  should.be_true(string.contains(go, "return user.Name"))
  should.be_true(string.contains(go, "return error.Path"))
}

pub fn json_parse_with_table_flattens_test() {
  let go =
    compile(
      "func f(text: Str): Str {\n\tparsed := hive.json.parse(text) with Table\n\tif parsed is Result.Ok(table) {\n\t\tfound := hive.json.get(table, \"a.b\")\n\t\tif found is Result.Ok(value) {\n\t\t\treturn value\n\t\t}\n\t}\n\treturn \"none\"\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.JsonParse(text, hive.JsonFlatten)"))
}

pub fn json_table_field_is_rejected_test() {
  // Unmapped JSON is ignored, so a Table field has nothing to hold and the
  // decoder derivation refuses it.
  let result =
    compiler.compile(
      "type Bag {\n\tstuff: Table\n}\nfunc f(text: Str): Str {\n\tparsed := hive.json.parse(text) with Bag\n\treturn \"x\"\n}\nproc main(): void {}\n",
    )
  should.be_error(result)
}

pub fn json_variant_decoder_test() {
  let go =
    compile(
      "type Shape {\n\tCircle {\n\t\tradius: Float\n\t}\n\tNothing\n}\nfunc f(text: Str): Str {\n\tparsed := hive.json.parse(text) with Shape\n\treturn \"ok\"\n}\nproc main(): void {}\n",
    )
  // Unions decode from {\"VariantName\": {...}}; null selects the first
  // field-less variant.
  should.be_true(string.contains(go, "key, inner, jerr := hive.JsonVariant(v, path)"))
  should.be_true(string.contains(go, "case \"Circle\":"))
  should.be_true(string.contains(
    go,
    "if v.Kind == 'n' {\n\t\treturn Shape(ShapeNothing{}), nil\n\t}",
  ))
}

pub fn json_encode_derives_encoder_test() {
  let go =
    compile(
      "type Reply {\n\tmessage: Str\n\tcount: Int\n}\nfunc f(): Str {\n\treturn hive.json.encode(Reply(\"hi\", 2))\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "jsonEncode_Reply(Reply{Message: \"hi\", Count: 2})"))
  should.be_true(string.contains(
    go,
    "return \"{\\\"message\\\":\" + hive.JsonEncodeStr(x.Message) + \",\\\"count\\\":\" + hive.JsonEncodeInt(x.Count) + \"}\"",
  ))
}

pub fn json_table_and_get_lower_test() {
  let go =
    compile(
      "func f(text: Str): Str {\n\trows := hive.json.table(text)\n\tif rows is Result.Ok(table) {\n\t\tfound := hive.json.get(table, \"name\")\n\t\tif found is Result.Ok(value) {\n\t\t\treturn value\n\t\t}\n\t}\n\treturn \"none\"\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.JsonTable(text)"))
  should.be_true(string.contains(go, "hive.JsonGet(table, \"name\")"))
}

pub fn json_is_pure_test() {
  // hive.json is allowed inside funcs (unlike hive.net).
  let result =
    compiler.compile(
      "func f(text: Str): Str {\n\treturn hive.json.encode(text)\n}\nproc main(): void {}\n",
    )
  should.be_ok(result)
}

pub fn with_requires_json_parse_test() {
  let result =
    compiler.compile(
      "proc main(): void {\n\tx := len([\"a\"]) with Int\n\techo x\n}\n",
    )
  should.be_error(result)
}

pub fn bare_json_parse_requires_with_test() {
  let result =
    compiler.compile(
      "proc main(): void {\n\tx := hive.json.parse(\"{}\")\n\techo x\n}\n",
    )
  should.be_error(result)
}

pub fn with_unknown_type_is_rejected_test() {
  let result =
    compiler.compile(
      "proc main(): void {\n\tx := hive.json.parse(\"{}\") with Nowhere\n\techo x\n}\n",
    )
  should.be_error(result)
}

pub fn unknown_json_builtin_is_rejected_test() {
  let result =
    compiler.compile("proc main(): void {\n\thive.json.stringify(\"x\")\n}\n")
  should.be_error(result)
}

// ---------------------------------------------------------------------------
// The hive.crypto standard library
// ---------------------------------------------------------------------------

pub fn crypto_hashes_lower_test() {
  let go =
    compile(
      "func f(): Str {\n\treturn hive.crypto.sha256(\"x\")\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.Sha256(\"x\")"))
}

pub fn crypto_hmac_and_base64_lower_test() {
  let go =
    compile(
      "func f(): Str {\n\th := hive.crypto.hmacSha256(\"m\", \"k\")\n\treturn hive.crypto.base64Encode(h)\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.HmacSha256(\"m\", \"k\")"))
  should.be_true(string.contains(go, "hive.Base64Encode(h)"))
}

pub fn crypto_base64_decode_returns_result_test() {
  let go =
    compile(
      "func f(s: Str): Str {\n\td := hive.crypto.base64Decode(s)\n\tif d is Result.Ok(text) {\n\t\treturn text\n\t} else if d is Result.Error(error) {\n\t\treturn error.reason\n\t}\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.Base64Decode(s)"))
  // A Result payload of CryptoError capitalizes its fields.
  should.be_true(string.contains(go, "return error.Reason"))
}

pub fn crypto_jwt_sign_and_verify_lower_test() {
  let go =
    compile(
      "type Claims {\n\tsub: Str\n}\nfunc make(secret: Str): Str {\n\treturn hive.crypto.jwtSign(Claims(\"a\"), secret)\n}\nfunc read(token: Str, secret: Str): Str {\n\tv := hive.crypto.jwtVerify(token, secret) with Claims\n\tif v is Result.Ok(c) {\n\t\treturn c.sub\n\t}\n\treturn \"no\"\n}\nproc main(): void {}\n",
    )
  // sign reuses the derived encoder; verify reuses the derived decoder.
  should.be_true(string.contains(go, "hive.JwtSign(jsonEncode_Claims("))
  should.be_true(string.contains(
    go,
    "hive.JwtVerify(token, secret, jsonDecode_Claims)",
  ))
}

pub fn crypto_jwt_decode_and_header_lower_test() {
  let go =
    compile(
      "type Claims {\n\tsub: Str\n}\nfunc f(token: Str): Str {\n\tpeek := hive.crypto.jwtDecode(token) with Claims\n\thead := hive.crypto.jwtHeader(token)\n\tif head is Result.Ok(h) {\n\t\treturn h.alg\n\t}\n\treturn \"no\"\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.JwtDecode(token, jsonDecode_Claims)"))
  should.be_true(string.contains(go, "hive.JwtReadHeader(token)"))
}

pub fn crypto_jwt_verify_requires_with_test() {
  // Like hive.json.parse, jwtVerify without a decode target is rejected.
  let result =
    compiler.compile(
      "proc main(): void {\n\tx := hive.crypto.jwtVerify(\"t\", \"s\")\n\techo x\n}\n",
    )
  should.be_error(result)
}

pub fn crypto_encrypt_lowers_test() {
  let go =
    compile(
      "func f(secret: Str, password: Str): Str {\n\treturn hive.crypto.encrypt(secret, password)\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.Encrypt(secret, password)"))
}

// The arguments can be named, and naming them says nothing about the order they
// are written in — as everywhere else in the language.
pub fn crypto_encrypt_takes_named_arguments_test() {
  let go =
    compile(
      "proc main(): void {\n\techo hive.crypto.encrypt(password: \"pw\", plaintext: \"secret\")\n}\n",
    )
  should.be_true(string.contains(go, "hive.Encrypt(\"secret\", \"pw\")"))
}

pub fn crypto_decrypt_returns_result_test() {
  let go =
    compile(
      "func f(sealed: Str, password: Str): Str {\n\topened := hive.crypto.decrypt(sealed, password)\n\tif opened is Result.Ok(text) {\n\t\treturn text\n\t} else if opened is Result.Error(error) {\n\t\treturn error.reason\n\t}\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.Decrypt(sealed, password)"))
  should.be_true(string.contains(go, "return error.Reason"))
}

// Every marker the module is linked by has to be one the generated Go actually
// carries: a program encrypting and nothing else would be built without the
// module that encrypts it if this one were spelled differently.
pub fn encrypting_pulls_in_the_crypto_module_test() {
  should.equal(
    used_modules(
      "proc main(): void {\n\techo hive.crypto.encrypt(\"secret\", \"pw\")\n}\n",
    ),
    ["crypto", "json", "time"],
  )
}

pub fn crypto_encrypt_wrong_arity_is_rejected_test() {
  compiler.compile("proc main(): void {\n\techo hive.crypto.encrypt(\"x\")\n}\n")
  |> should.be_error
}

pub fn unknown_crypto_builtin_is_rejected_test() {
  let result =
    compiler.compile("proc main(): void {\n\techo hive.crypto.md5(\"x\")\n}\n")
  should.be_error(result)
}

// ---------------------------------------------------------------------------
// The hive.sql standard library
// ---------------------------------------------------------------------------

pub fn sql_connect_and_query_lower_test() {
  let go =
    compile(
      "proc main(): void {\n\topened := hive.sql.connect(hive.sql.DatabaseDriver.SQLite(), \"./x.db\")\n\tif opened is Result.Ok(db) {\n\t\tresult := using db run raw \"SELECT 1\"\n\t\tif result is Result.Ok(rows) {\n\t\t\techo rows\n\t\t}\n\t}\n}\n",
    )
  should.be_true(string.contains(
    go,
    "hive.SqlConnect(hive.DatabaseDriver{Name: \"sqlite\"}, \"./x.db\")",
  ))
  // `run raw` keeps the untyped path: a Table, not a CSV read.
  should.be_true(string.contains(go, "hive.SqlQuery(db, \"SELECT 1\")"))
}

pub fn running_bare_sql_text_without_raw_is_rejected_test() {
  // A declared query is what knows the shape of the rows; text does not.
  let assert Error(msg) =
    compiler.compile(
      "proc main(): void {\n\topened := hive.sql.connect(hive.sql.DatabaseDriver.SQLite(), \"./x.db\")\n\tif opened is Result.Ok(db) {\n\t\tresult := using db run \"SELECT 1\"\n\t\techo result\n\t}\n}\n",
    )
  should.be_true(string.contains(msg, "run raw"))
}

pub fn sql_pool_close_and_drivers_lower_test() {
  let go =
    compile(
      "proc main(): void {\n\topened := hive.sql.pool(hive.sql.DatabaseDriver.PostgreSQL(), \"conn\", 4, 2)\n\tif opened is Result.Ok(db) {\n\t\thive.sql.close(db)\n\t}\n\tother := hive.sql.DatabaseDriver.Other(\"mysql\")\n}\n",
    )
  should.be_true(string.contains(
    go,
    "hive.SqlPool(hive.DatabaseDriver{Name: \"postgres\"}, \"conn\", 4, 2)",
  ))
  should.be_true(string.contains(go, "hive.SqlClose(db)"))
  should.be_true(string.contains(go, "hive.DatabaseDriver{Name: \"mysql\"}"))
}

pub fn using_string_still_reads_csv_test() {
  // The `using` overload must not disturb CSV reads over a Str path.
  let go =
    compile(
      "proc main(): void {\n\tx := using \"./a.csv\" as csv separating by \";\"\n\tif x is Result.Ok(t) {\n\t\techo t\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.ReadCSV(\"./a.csv\", \";\")"))
}

pub fn unknown_sql_builtin_is_rejected_test() {
  let result =
    compiler.compile("proc main(): void {\n\thive.sql.migrate(\"x\")\n}\n")
  should.be_error(result)
}

// ---------------------------------------------------------------------------
// For loops
// ---------------------------------------------------------------------------

pub fn c_style_for_lowers_test() {
  let go =
    compile(
      "proc main(): void {\n\tmut sum := 0\n\tfor i := 0; i < 3; i = i + 1 {\n\t\tsum = sum + i\n\t}\n\techo sum\n}\n",
    )
  // The three clauses map straight onto Go's `for init; cond; post`.
  should.be_true(string.contains(go, "for i := 0; (i < 3); i = (i + 1) {"))
  should.be_true(string.contains(go, "sum = (sum + i)"))
}

pub fn c_style_for_counter_is_implicitly_mutable_test() {
  // The loop variable declared in `init` may be advanced by `post` (a
  // reassignment) with no `mut` keyword — it is mutable by construction.
  let result =
    compiler.compile(
      "proc main(): void {\n\tfor i := 0; i < 3; i = i + 1 {\n\t\techo i\n\t}\n}\n",
    )
  should.be_ok(result)
}

pub fn c_style_for_typed_init_test() {
  let go =
    compile(
      "proc main(): void {\n\tfor Int i = 0; i < 2; i = i + 1 {\n\t\techo i\n\t}\n}\n",
    )
  // A typed init clause still lowers to a short var decl (Go infers the type).
  should.be_true(string.contains(go, "for i := 0; (i < 2); i = (i + 1) {"))
}

pub fn c_style_for_allows_empty_clauses_test() {
  let go =
    compile(
      "proc main(): void {\n\tmut i := 0\n\tfor ; i < 3; {\n\t\ti = i + 1\n\t}\n\techo i\n}\n",
    )
  // Absent init and post leave their slots empty, like a Go while-style for.
  should.be_true(string.contains(go, "for ; (i < 3);  {"))
}

pub fn for_each_lowers_to_range_test() {
  let go =
    compile(
      "proc main(): void {\n\tnames := [\"a\", \"b\"]\n\tfor each name in names {\n\t\techo name\n\t}\n}\n",
    )
  // Iterating a vector discards the index and binds the value.
  should.be_true(string.contains(go, "for _, name := range names {"))
  should.be_true(string.contains(go, "fmt.Println(name)"))
}

pub fn for_each_infers_binding_type_from_vector_test() {
  // With no annotation the element type is inferred from the vector, so member
  // access on a struct element still capitalizes to the exported Go field.
  let go =
    compile(
      "type User {\n\tname: Str\n}\nproc main(): void {\n\tusers := [User(\"a\"), User(\"b\")]\n\tfor each u in users {\n\t\techo u.name\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "for _, u := range"))
  should.be_true(string.contains(go, "fmt.Println(u.Name)"))
}

pub fn for_each_optional_annotation_still_works_test() {
  // An explicit `name: T` annotation remains valid and overrides inference.
  let go =
    compile(
      "proc main(): void {\n\tnames := [\"a\", \"b\"]\n\tfor each name: Str in names {\n\t\techo name\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "for _, name := range names {"))
}

pub fn for_each_unused_binding_gets_guard_test() {
  let go =
    compile(
      "proc main(): void {\n\tmut c := 0\n\tfor each x in [1, 2, 3] {\n\t\tc = c + 1\n\t}\n\techo c\n}\n",
    )
  // Go rejects an unused range binding, so an unread element gets `_ = x`.
  should.be_true(string.contains(go, "_ = x"))
}

pub fn for_each_binding_is_immutable_test() {
  // The iteration variable is a fresh immutable binding, so reassigning it is
  // a compile error.
  let result =
    compiler.compile(
      "proc main(): void {\n\tfor each x in [1, 2] {\n\t\tx = 5\n\t}\n}\n",
    )
  should.be_error(result)
}

pub fn for_loop_variable_does_not_leak_test() {
  // The counter is scoped to the loop, so a later declaration may reuse the
  // name without clashing.
  let result =
    compiler.compile(
      "proc main(): void {\n\tfor i := 0; i < 2; i = i + 1 {\n\t\techo i\n\t}\n\ti := 99\n\techo i\n}\n",
    )
  should.be_ok(result)
}

// ---------------------------------------------------------------------------
// The hive.conv standard library
// ---------------------------------------------------------------------------

pub fn conv_rounding_lowers_test() {
  let go =
    compile(
      "func f(): Int {\n\treturn hive.conv.ceil(3.2)\n}\nproc main(): void {\n\techo hive.conv.floor(3.8)\n\techo hive.conv.round(2.5)\n}\n",
    )
  should.be_true(string.contains(go, "hive.Ceil(3.2)"))
  should.be_true(string.contains(go, "hive.Floor(3.8)"))
  should.be_true(string.contains(go, "hive.Round(2.5)"))
}

pub fn conv_value_and_string_conversions_lower_test() {
  let go =
    compile(
      "func f(): Str {\n\tx := hive.conv.itf(7)\n\ta := hive.conv.its(42)\n\treturn a + hive.conv.fts(3.14)\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.IntToFloat(7)"))
  should.be_true(string.contains(go, "hive.IntToStr(42)"))
  should.be_true(string.contains(go, "hive.FloatToStr(3.14)"))
}

pub fn conv_parse_returns_result_test() {
  let go =
    compile(
      "func f(s: Str): Int {\n\tparsed := hive.conv.sti(s)\n\tif parsed is Result.Ok(n) {\n\t\treturn n\n\t} else if parsed is Result.Error(e) {\n\t\techo e.message\n\t\techo e.input\n\t}\n\treturn 0\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.StrToInt(s)"))
  should.be_true(string.contains(go, "parsed.IsOk()"))
  // The Ok payload is an Int (so `return n` is a plain int return), and the
  // ConversionError fields capitalize to their exported Go names.
  should.be_true(string.contains(go, "n := parsed.Ok()"))
  should.be_true(string.contains(go, "e.Message"))
  should.be_true(string.contains(go, "e.Input"))
}

pub fn conv_stf_parses_float_test() {
  let go =
    compile(
      "func f(s: Str): Float {\n\tparsed := hive.conv.stf(s)\n\tif parsed is Result.Ok(x) {\n\t\treturn x\n\t}\n\treturn 0.0\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.StrToFloat(s)"))
}

pub fn conv_is_pure_test() {
  // hive.conv is pure, so it is allowed inside a func.
  let result =
    compiler.compile(
      "func f(): Str {\n\treturn hive.conv.its(5)\n}\nproc main(): void {}\n",
    )
  should.be_ok(result)
}

pub fn conv_named_argument_test() {
  let go =
    compile(
      "func f(): Str {\n\treturn hive.conv.its(value: 5)\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.IntToStr(5)"))
}

pub fn unknown_conv_builtin_is_rejected_test() {
  let result =
    compiler.compile("proc main(): void {\n\techo hive.conv.dtoi(3.0)\n}\n")
  should.be_error(result)
}

pub fn conv_wrong_arity_is_rejected_test() {
  let result =
    compiler.compile("proc main(): void {\n\techo hive.conv.ceil(1.0, 2.0)\n}\n")
  should.be_error(result)
}

// ---------------------------------------------------------------------------
// Standard library modules are only built when they are used
// ---------------------------------------------------------------------------

// The module names a program's generated Go pulls into the build.
fn used_modules(source: String) -> List(String) {
  runtime.needed_modules(compile(source))
}

pub fn unused_modules_are_left_out_test() {
  // A program that only echoes needs nothing but the core runtime.
  should.equal(used_modules("proc main(): void {\n\techo \"hi\"\n}\n"), [])
}

pub fn used_module_is_pulled_in_test() {
  should.equal(
    used_modules(
      "proc main(): void {\n\techo hive.conv.its(1)\n\techo hive.time.now()\n}\n",
    ),
    ["conv", "time"],
  )
}

pub fn net_module_is_pulled_in_by_each_protocol_test() {
  let http =
    used_modules(
      "proc main(): void {\n\thive.net.httpServe(80, h)\n}\nproc h(r: hive.net.HttpRequest): hive.net.HttpResponse {\n\treturn hive.net.HttpResponse(200, [], \"\")\n}\n",
    )
  should.be_true(list.contains(http, "net"))
  let ws =
    used_modules(
      "proc main(): void {\n\thive.net.wsServe(80, h)\n}\nproc h(c: hive.net.WsConnection): void {\n\thive.net.wsClose(c)\n}\n",
    )
  should.be_true(list.contains(ws, "net"))
  let socket =
    used_modules(
      "proc main(): void {\n\thive.net.socketServe(80, h)\n}\nproc h(c: hive.net.SocketConnection): void {\n\thive.net.socketClose(c)\n}\n",
    )
  should.be_true(list.contains(socket, "net"))
  // The two calls that name no protocol carry no protocol's prefix either, so
  // they need a marker of their own — without it a program that only resolves a
  // name would be built without the module that resolves it.
  let names =
    used_modules(
      "proc main(): void {\n\tfound := hive.net.resolve(\"cache-0.internal\")\n\tif found is Result.Ok(a) {\n\t\techo len(a)\n\t}\n}\n",
    )
  should.be_true(list.contains(names, "net"))
  let local =
    used_modules(
      "proc main(): void {\n\there := hive.net.localAddress()\n\tif here is Result.Ok(ip) {\n\t\techo ip\n\t}\n}\n",
    )
  should.be_true(list.contains(local, "net"))
}

// The health check shrinks its own period: a probe that goes unanswered brings
// the next one forward by a step, so silence costs 15 + 10 + 5 = 30s rather than
// the 45 three full periods would spend. The schedule lives in the runtime
// rather than in generated code, so this pins the pieces it is derived from.
pub fn syslink_health_check_shrinks_its_period_test() {
  let source = runtime.syslink_net_go()
  should.be_true(string.contains(source, "syslinkTickEvery = 15 * time.Second"))
  should.be_true(string.contains(source, "syslinkTickStep  = 5 * time.Second"))
  // The budget is derived from those two, never written down a third time.
  should.be_true(string.contains(
    source,
    "for wait := syslinkTickEvery; wait > 0; wait -= syslinkTickStep {",
  ))
  // An unanswered probe brings the next one forward...
  should.be_true(string.contains(source, "wait -= syslinkTickStep"))
  // ...and one word from the peer puts the period back to full.
  should.be_true(string.contains(source, "wait = syslinkTickEvery"))
  // A check is a round trip, because "somebody spoke lately" cannot tell a live
  // peer from one whose own period misses the window being watched.
  should.be_true(string.contains(source, "kindPong"))
  should.be_true(string.contains(
    source,
    "s.enqueue(writeFrame(frame{kind: kindPong}))",
  ))
}

pub fn module_requirements_are_pulled_in_test() {
  // hive.crypto's JWTs decode with hive.json and check exp/nbf against
  // hive.time, so both come along even though the source never names them.
  let used =
    used_modules(
      "type Claims {\n\tsub: Str\n}\nproc main(): void {\n\techo hive.crypto.jwtSign(Claims(\"me\"), \"secret\")\n}\n",
    )
  should.be_true(list.contains(used, "crypto"))
  should.be_true(list.contains(used, "json"))
  should.be_true(list.contains(used, "time"))
}

pub fn declaring_a_query_pulls_in_sql_test() {
  // A query builds a hive.SqlFragment, which lives in the SQL module — so
  // declaring one is enough to need it, even without opening a connection.
  let used =
    used_modules(
      "query find(name: Str): Str[dyn] {\n\tSELECT n FROM t WHERE n = {name}\n}\nproc main(): void {\n\techo \"built\"\n}\n",
    )
  should.be_true(list.contains(used, "sql"))
}

pub fn a_program_without_sql_does_not_pull_it_in_test() {
  let used = used_modules("proc main(): void {\n\techo \"built\"\n}\n")
  should.be_false(list.contains(used, "sql"))
}

pub fn sql_module_is_pulled_in_by_a_connection_test() {
  let used =
    used_modules(
      "proc main(): void {\n\tc := hive.sql.connect(hive.sql.DatabaseDriver.SQLite(), \"f.db\")\n\tif c is Result.Ok(conn) {\n\t\thive.sql.close(conn)\n\t} else if c is Result.Error(e) {\n\t\techo e.message\n\t}\n}\n",
    )
  should.be_true(list.contains(used, "sql"))
}

// ---------------------------------------------------------------------------
// Multi-file programs (`import`)
// ---------------------------------------------------------------------------

// Compiles a fixture program under test/modules/, imports and all.
fn compile_program(name: String) -> String {
  let assert Ok(go) = compiler.compile_file("test/modules/" <> name <> ".hive")
  go
}

fn program_error(name: String) -> String {
  let assert Error(message) =
    compiler.compile_file("test/modules/" <> name <> ".hive")
  message
}

pub fn import_brings_in_another_module_test() {
  let go = compile_program("uses-lib")
  // The entrypoint keeps its own names; the imported module's are prefixed.
  should.be_true(string.contains(go, "func main() {"))
  should.be_true(string.contains(go, "func lib_0_shout(word string) string {"))
  should.be_true(string.contains(go, "lib_0_shout(\"hi\")"))
  should.be_true(string.contains(go, "lib_0_decorate("))
}

pub fn imported_types_stay_distinct_from_local_ones_test() {
  // Both files declare a `Style`; they must not collapse into one Go type.
  let go = compile_program("uses-lib")
  should.be_true(string.contains(go, "type Style interface {"))
  should.be_true(string.contains(go, "type lib_0_Style interface {"))
  should.be_true(string.contains(go, "StyleBoxed struct"))
  should.be_true(string.contains(go, "lib_0_StyleLoud struct"))
  // An imported type annotates a local and drives a pattern.
  should.be_true(string.contains(go, "var loud lib_0_Style"))
  should.be_true(string.contains(go, "loud.(lib_0_StyleLoud)"))
}

pub fn transitive_imports_are_loaded_once_test() {
  // diamond.hive imports lib directly and middle.hive imports it too, so lib's
  // declarations must appear exactly once in the flattened program.
  let go = compile_program("diamond")
  should.be_true(string.contains(go, "viaMiddle"))
  let copies =
    string.split(go, "func lib_0_shout(word string) string {")
    |> list.length
  should.equal(copies, 2)
}

pub fn locals_still_shadow_module_level_names_test() {
  // Every name in shadow-lib.hive collides with its own `value` func; the
  // renaming must respect scopes rather than rewriting every match.
  let go = compile_program("shadow")
  // The bare calls reach the renamed module-level func...
  should.be_true(string.contains(go, "return shadow_lib_0_value()"))
  // ...while the local, the parameter and the loop/pattern bindings do not.
  should.be_true(string.contains(go, "value := \"local-var\"\n\treturn value"))
  should.be_true(string.contains(
    go,
    "func shadow_lib_0_useParam(value string) string {\n\treturn value",
  ))
  // A local named like the import is field access, not a module reference.
  should.be_true(string.contains(go, "return helper.Label"))
}

pub fn self_import_is_rejected_test() {
  should.be_true(string.contains(program_error("self"), "cycle"))
}

pub fn two_step_import_cycle_is_rejected_test() {
  let message = program_error("cycle-a")
  should.be_true(string.contains(message, "cycle"))
  should.be_true(string.contains(message, "cycle-a.hive"))
  should.be_true(string.contains(message, "cycle-b.hive"))
}

pub fn three_step_import_cycle_is_rejected_test() {
  let message = program_error("deep-a")
  should.be_true(string.contains(message, "cycle"))
  should.be_true(string.contains(message, "deep-b.hive"))
  should.be_true(string.contains(message, "deep-c.hive"))
}

pub fn unknown_member_of_a_module_is_rejected_test() {
  let message = program_error("missing-member")
  should.be_true(string.contains(message, "has no `nope`"))
}

pub fn missing_module_file_is_rejected_test() {
  let message = program_error("missing-file")
  should.be_true(string.contains(message, "nowhere.hive"))
}

pub fn import_named_hive_is_rejected_test() {
  let message = program_error("named-hive")
  should.be_true(string.contains(message, "standard library"))
}

pub fn import_clashing_with_a_declaration_is_rejected_test() {
  let message = program_error("alias-clash")
  should.be_true(string.contains(message, "same name as a declaration"))
}

pub fn import_path_needs_a_usable_name_test() {
  // `lib-with-dashes` cannot be a name, so `as` is required.
  let result =
    compiler.compile("import ./lib-with-dashes\nproc main(): void {}\n")
  should.be_error(result)
  case result {
    Error(message) -> should.be_true(string.contains(message, "as <name>"))
    Ok(_) -> panic as "expected an error"
  }
}

pub fn in_memory_source_resolves_imports_from_the_cwd_test() {
  // `compile` has no file of its own, so its imports resolve against the
  // working directory.
  let go =
    compile(
      "import ./test/modules/lib as helper\nproc main(): void {\n\techo helper.shout(\"hi\")\n}\n",
    )
  should.be_true(string.contains(go, "lib_0_shout(\"hi\")"))
}

pub fn a_program_without_imports_is_unchanged_test() {
  // Nothing is renamed when there is nothing to merge.
  let go = compile("func helper(): Str {\n\treturn \"x\"\n}\nproc main(): void {\n\techo helper()\n}\n")
  should.be_true(string.contains(go, "func helper() string {"))
  should.be_true(string.contains(go, "fmt.Println(helper())"))
}

// ---------------------------------------------------------------------------
// The `using` forms
// ---------------------------------------------------------------------------

pub fn bare_using_is_a_comma_separated_csv_test() {
  let go = compile("proc main(): void {\n\tt := using \"./a.csv\"\n\techo t\n}\n")
  should.be_true(string.contains(go, "hive.ReadCSV(\"./a.csv\", \",\")"))
}

pub fn using_as_csv_defaults_to_a_comma_test() {
  let go =
    compile("proc main(): void {\n\tt := using \"./a.csv\" as csv\n\techo t\n}\n")
  should.be_true(string.contains(go, "hive.ReadCSV(\"./a.csv\", \",\")"))
}

pub fn using_as_csv_takes_a_separator_test() {
  let go =
    compile(
      "proc main(): void {\n\tt := using \"./a.csv\" as csv separating by \";\"\n\techo t\n}\n",
    )
  should.be_true(string.contains(go, "hive.ReadCSV(\"./a.csv\", \";\")"))
}

pub fn using_as_xlsx_reads_every_sheet_test() {
  let go =
    compile(
      "proc main(): void {\n\tbook := using \"./b.xlsx\" as xlsx\n\tif book is Result.Ok(sheets) {\n\t\techo len(sheets)\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.ReadXlsx(\"./b.xlsx\")"))
}

pub fn using_as_ods_reads_every_sheet_test() {
  let go =
    compile(
      "proc main(): void {\n\tbook := using \"./b.ods\" as ods\n\tif book is Result.Ok(sheets) {\n\t\techo len(sheets)\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.ReadOds(\"./b.ods\")"))
}

pub fn a_spreadsheet_yields_a_vector_of_tables_test() {
  // A sheet indexed out of the result has to infer as a Table, so `column` and
  // `row` apply to it. (The index needs the bounds checker's usual guard.)
  let go =
    compile(
      "proc main(): void {\n\tbook := using \"./b.xlsx\" as xlsx\n\tif book is Result.Ok(sheets) {\n\t\tif 0 < len(sheets) {\n\t\t\techo column(sheets[0], \"item\")\n\t\t}\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.Column(sheets[0], \"item\")"))
  // The Ok payload is a slice of Tables, which is what makes that index a Table.
  should.be_true(string.contains(go, "sheets := "))
}

pub fn using_run_lowers_to_a_sql_query_test() {
  let go =
    compile(
      "proc main(): void {\n\topened := hive.sql.connect(hive.sql.DatabaseDriver.SQLite(), \"./x.db\")\n\tif opened is Result.Ok(db) {\n\t\tresult := using db run raw \"SELECT 1\"\n\t\tif result is Result.Ok(rows) {\n\t\t\techo rows\n\t\t}\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.SqlQuery(db, \"SELECT 1\")"))
}

pub fn old_using_with_syntax_is_rejected_test() {
  // The one form that meant both a delimiter and a query is now two.
  let delimited =
    compiler.compile(
      "proc main(): void {\n\tt := using \"./a.csv\" with \";\"\n\techo t\n}\n",
    )
  should.be_error(delimited)
  case delimited {
    Error(message) -> {
      should.be_true(string.contains(message, "separating by"))
      should.be_true(string.contains(message, "run <query>"))
    }
    Ok(_) -> panic as "expected an error"
  }
}

pub fn unknown_using_format_is_rejected_test() {
  let result =
    compiler.compile(
      "proc main(): void {\n\tt := using \"./a.parquet\" as parquet\n\techo t\n}\n",
    )
  should.be_error(result)
}

pub fn spreadsheet_readers_are_only_built_when_asked_for_test() {
  // A CSV read needs nothing beyond the core runtime; a spreadsheet is what
  // pulls archive/zip and encoding/xml in.
  should.equal(
    used_modules("proc main(): void {\n\tt := using \"./a.csv\"\n\techo t\n}\n"),
    [],
  )
  let sheets =
    used_modules(
      "proc main(): void {\n\tb := using \"./b.xlsx\" as xlsx\n\techo b\n}\n",
    )
  should.equal(sheets, ["sheets"])
  let ods =
    used_modules(
      "proc main(): void {\n\tb := using \"./b.ods\" as ods\n\techo b\n}\n",
    )
  should.equal(ods, ["sheets"])
}

// ---------------------------------------------------------------------------
// hive.file
// ---------------------------------------------------------------------------

pub fn file_calls_lower_to_the_runtime_test() {
  let go =
    compile(
      "proc main(): void {\n\tif hive.file.write(\"a.txt\", \"x\") is Result.Ok(n) {\n\t\techo n\n\t}\n\tif hive.file.read(\"a.txt\") is Result.Ok(text) {\n\t\techo text\n\t}\n\tif hive.file.lines(\"a.txt\") is Result.Ok(lines) {\n\t\techo len(lines)\n\t}\n\techo hive.file.exists(\"a.txt\")\n}\n",
    )
  should.be_true(string.contains(go, "hive.FileWrite(\"a.txt\", \"x\")"))
  should.be_true(string.contains(go, "hive.FileRead(\"a.txt\")"))
  should.be_true(string.contains(go, "hive.FileLines(\"a.txt\")"))
  should.be_true(string.contains(go, "hive.FileExists(\"a.txt\")"))
}

pub fn file_error_fields_are_typed_test() {
  let go =
    compile(
      "proc main(): void {\n\tif hive.file.read(\"a.txt\") is Result.Error(error) {\n\t\techo error.reason\n\t\techo error.path\n\t\techo error.message\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "error.Reason"))
  should.be_true(string.contains(go, "error.Path"))
  should.be_true(string.contains(go, "error.Message"))
}

pub fn file_calls_accept_named_arguments_test() {
  let go =
    compile(
      "proc main(): void {\n\tif hive.file.copy(to: \"b.txt\", from: \"a.txt\") is Result.Ok(n) {\n\t\techo n\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.FileCopy(\"a.txt\", \"b.txt\")"))
}

pub fn unknown_file_builtin_is_rejected_test() {
  let result =
    compiler.compile("proc main(): void {\n\thive.file.chmod(\"a.txt\")\n}\n")
  should.be_error(result)
}

pub fn file_module_is_only_built_when_used_test() {
  should.equal(
    used_modules(
      "proc main(): void {\n\techo hive.file.exists(\"a.txt\")\n}\n",
    ),
    ["file"],
  )
}

// ---------------------------------------------------------------------------
// A pattern's subject is evaluated once
// ---------------------------------------------------------------------------

pub fn a_matched_call_runs_once_test() {
  // Codegen reads a subject to test it and again for each value it binds, so a
  // call has to be held in a temporary first — otherwise the write happens twice.
  let go =
    compile(
      "proc main(): void {\n\tif hive.file.write(\"a.txt\", \"x\") is Result.Ok(n) {\n\t\techo n\n\t}\n}\n",
    )
  should.equal(
    string.split(go, "hive.FileWrite(\"a.txt\", \"x\")") |> list.length,
    2,
  )
  should.be_true(string.contains(go, ":= hive.FileWrite(\"a.txt\", \"x\"); "))
}

pub fn a_matched_using_runs_once_test() {
  let go =
    compile(
      "proc main(): void {\n\tif using \"./a.csv\" is Result.Ok(t) {\n\t\techo t\n\t}\n}\n",
    )
  should.equal(
    string.split(go, "hive.ReadCSV(\"./a.csv\", \",\")") |> list.length,
    2,
  )
}

pub fn a_repeatable_subject_is_not_hoisted_test() {
  // A plain local costs nothing to read twice, so it stays inline.
  let go =
    compile(
      "proc main(): void {\n\tr := using \"./a.csv\"\n\tif r is Result.Ok(t) {\n\t\techo t\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "if r.IsOk() {"))
}

// ---------------------------------------------------------------------------
// The shipped code examples must always compile
// ---------------------------------------------------------------------------

pub fn http_example_compiles_test() {
  let assert Ok(src) = simplifile.read("code-examples/3 - Networking/http.hive")
  let assert Ok(_) = compiler.compile(src)
}

pub fn websockets_example_compiles_test() {
  let assert Ok(src) =
    simplifile.read("code-examples/3 - Networking/websockets.hive")
  let assert Ok(_) = compiler.compile(src)
}

pub fn sockets_example_compiles_test() {
  let assert Ok(src) =
    simplifile.read("code-examples/3 - Networking/sockets.hive")
  let assert Ok(_) = compiler.compile(src)
}

pub fn modules_example_compiles_test() {
  // Read through compile_file, since this one spans three files.
  let assert Ok(_) =
    compiler.compile_file("code-examples/11 - Modules/modules.hive")
}

pub fn files_and_spreadsheets_example_compiles_test() {
  let assert Ok(src) =
    simplifile.read(
      "code-examples/12 - Files and Spreadsheets/files-and-spreadsheets.hive",
    )
  let assert Ok(_) = compiler.compile(src)
}

pub fn basic_io_example_compiles_test() {
  let assert Ok(src) = simplifile.read("code-examples/1 - Basic IO/basic-io.hive")
  let assert Ok(_) = compiler.compile(src)
}

pub fn types_example_compiles_test() {
  let assert Ok(src) = simplifile.read("code-examples/2 - Types/types.hive")
  let assert Ok(_) = compiler.compile(src)
}

pub fn crypto_example_compiles_test() {
  let assert Ok(src) = simplifile.read("code-examples/4 - Crypto/crypto.hive")
  let assert Ok(_) = compiler.compile(src)
}

pub fn sql_example_compiles_test() {
  let assert Ok(src) = simplifile.read("code-examples/5 - SQL/sql.hive")
  let assert Ok(_) = compiler.compile(src)
}

pub fn first_class_functions_example_compiles_test() {
  let assert Ok(src) =
    simplifile.read(
      "code-examples/8 - First-Class Functions/first-class-functions.hive",
    )
  let assert Ok(_) = compiler.compile(src)
}

pub fn generics_example_compiles_test() {
  let assert Ok(src) =
    simplifile.read("code-examples/14 - Generics/generics.hive")
  let assert Ok(_) = compiler.compile(src)
}

// A named address is the only kind that survives its service being replaced: it
// is re-resolved through the registry on every send, so a replacement registered
// under the same atom is picked up by every holder. The fixture exercises that
// across a real restart; here we at least hold the shape to the compiler.
pub fn syslink_named_address_survives_a_restart_test() {
  let assert Ok(src) = simplifile.read("test/fixtures/syslink-restart.hive")
  let assert Ok(_) = compiler.compile(src)
}

// The last argument of the generated `SyslinkSpawn` call: the compiler's verdict
// on whether this handler's envelope can outlive its turn. Read off the text
// rather than matched loosely, so a change in the digest before it cannot make
// the assertion pass or fail by accident.
fn spawn_verdict(go: String) -> String {
  let assert [_, after, ..] = string.split(go, "hive.SyslinkSpawn(")
  let assert [call, ..] = string.split(after, ")\n")
  let assert [verdict, ..] =
    call |> string.split(", ") |> list.reverse
  verdict
}

// ---------------------------------------------------------------------------
// Failing an unanswered request fast
// ---------------------------------------------------------------------------
// The runtime may fail a request the instant a turn ends without answering it —
// but only for a handler whose envelope provably cannot outlive that turn. The
// compiler decides, and passes its verdict as the last argument to spawn.

pub fn syslink_noreply_fixture_compiles_test() {
  let assert Ok(src) = simplifile.read("test/fixtures/syslink-noreply.hive")
  let assert Ok(_) = compiler.compile(src)
}

// An envelope that only ever reaches `answer` cannot outlive its turn.
pub fn syslink_envelope_confined_to_its_turn_test() {
  let assert Ok(go) =
    compiler.compile(
      "type Op {\n\tGo\n}\n\nproc box(n: Int, op: Op, from: hive.syslink.Envelope): Int {\n\thive.syslink.answer(from, Op.Go())\n\treturn n\n}\n\nproc main(): void {\n\thive.syslink.spawn(box, 0)\n}\n",
    )
  spawn_verdict(go) |> should.equal("true")
}

// `self` and `monitor` do not keep the reply token either, so they are not
// escapes — otherwise a service that watches anything would lose the fast
// failure for no reason.
pub fn syslink_self_and_monitor_are_not_escapes_test() {
  let assert Ok(go) =
    compiler.compile(
      "type Op {\n\tGo { peer: hive.syslink.Address }\n}\n\nproc box(n: Int, op: Op, from: hive.syslink.Envelope): Int {\n\tif op is Op.Go(peer) {\n\t\thive.syslink.monitor(from, peer, Op.Go(hive.syslink.self(from)))\n\t}\n\treturn n\n}\n\nproc main(): void {\n\thive.syslink.spawn(box, 0)\n}\n",
    )
  spawn_verdict(go) |> should.equal("true")
}

// Handing the envelope to a call the handler does not wait for lets an answer
// arrive after the turn, so the fast failure has to be switched off or it would
// cut off a live request.
pub fn syslink_envelope_handed_to_a_task_defers_test() {
  let assert Ok(go) =
    compiler.compile(
      "type Op {\n\tGo\n}\n\nfunc later(from: hive.syslink.Envelope): void {\n\thive.syslink.answer(from, Op.Go())\n}\n\nproc box(n: Int, op: Op, from: hive.syslink.Envelope): Int {\n\tasync later(from)\n\treturn n\n}\n\nproc main(): void {\n\thive.syslink.spawn(box, 0)\n}\n",
    )
  spawn_verdict(go) |> should.equal("false")
}

// So does keeping it in the service's own state, which is the other way a reply
// legitimately arrives on a later turn.
pub fn syslink_envelope_kept_in_state_defers_test() {
  let assert Ok(go) =
    compiler.compile(
      "type Op {\n\tGo\n}\n\ntype Held {\n\twaiting: hive.syslink.Envelope\n}\n\nproc box(h: Held, op: Op, from: hive.syslink.Envelope): Held {\n\treturn Held(from)\n}\n\nproc main(): void {\n\thive.syslink.spawn(box, Held(hive.syslink.Envelope()))\n}\n",
    )
  spawn_verdict(go) |> should.equal("false")
}

pub fn distributed_cache_example_compiles_test() {
  let assert Ok(src) =
    simplifile.read(
      "code-examples/9 - EXAMPLE APP - Online Cache/cache.hive",
    )
  let assert Ok(_) = compiler.compile(src)
}

pub fn distributed_actors_example_compiles_test() {
  let assert Ok(src) =
    simplifile.read(
      "code-examples/13 - Distributed Actors/distributed-actors.hive",
    )
  let assert Ok(_) = compiler.compile(src)
}

// ---------------------------------------------------------------------------
// hive.syslink: addressable services, local or on another node
// ---------------------------------------------------------------------------

// A minimal well-formed service, reused by the tests below.
const service_prelude = "type Op {\n\tPut { key: Str }\n\tCount\n}\n\nproc box(seen: Int, op: Op, from: hive.syslink.Envelope): Int {\n\tif op is Op.Put(key) {\n\t\techo key\n\t\treturn seen + 1\n\t}\n\thive.syslink.answer(from, seen)\n\treturn seen\n}\n"

pub fn syslink_spawn_send_and_register_compiles_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\tif hive.syslink.register(#Inbox, b) is Result.Error(e) {\n\t\tpanic e\n\t}\n\tb(Op.Put(\"k\"))\n}\n",
  )
  |> should.be_ok
}

// The handler is the fold over the mailbox, so the state going in and the state
// coming out have to be the same type.
pub fn syslink_handler_must_return_its_state_type_test() {
  compiler.compile(
    "type Op {\n\tPut { key: Str }\n}\n\nproc box(seen: Int, op: Op, from: hive.syslink.Envelope): Str {\n\treturn \"nope\"\n}\n\nproc main(): void {\n\thive.syslink.spawn(box, 0)\n}\n",
  )
  |> should.be_error
}

pub fn syslink_handler_needs_an_envelope_test() {
  compiler.compile(
    "type Op {\n\tPut { key: Str }\n}\n\nproc box(seen: Int, op: Op, extra: Str): Int {\n\treturn seen\n}\n\nproc main(): void {\n\thive.syslink.spawn(box, 0)\n}\n",
  )
  |> should.be_error
}

pub fn syslink_handler_must_be_a_proc_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\thive.syslink.spawn(nosuchproc, 0)\n}\n",
  )
  |> should.be_error
}

// A registered name and a node role come from a closed set of atoms. That is
// what makes the registry knowable at compile time, so a computed name has to be
// rejected rather than silently giving up the checking it buys.
pub fn syslink_names_must_be_atom_literals_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\tname := \"Inbox\"\n\thive.syslink.register(name, b)\n}\n",
  )
  |> should.be_error
}

// A service on this node is reached by name alone; one elsewhere by the endpoint
// its node can be dialed at. Only the service name is an atom — the endpoint is
// ordinary data, so a cluster's size need not be known when the program is
// written.
pub fn syslink_at_and_on_compile_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\thive.syslink.at(#Inbox)(Op.Put(\"k\"))\n\tfor each e in split(\"a:1,b:2\", \",\") {\n\t\thive.syslink.on(e, #Inbox)(Op.Put(\"k\"))\n\t}\n}\n",
  )
  |> should.be_ok
}

// The node roles that `at` used to take were atoms too. Removing them is what
// lets a peer list be computed, so the old two-atom spelling must not silently
// mean something else.
pub fn syslink_node_roles_are_gone_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\thive.syslink.peer(#There, \"127.0.0.1:9100\")\n}\n",
  )
  |> should.be_error
}

pub fn syslink_on_endpoint_may_be_computed_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\thost := \"10.0.0.4\"\n\thive.syslink.on(host + \":9100\", #Inbox)(Op.Put(\"k\"))\n}\n",
  )
  |> should.be_ok
}

// The service name still may not be, since the registry it keys is what the
// compiler knows at compile time.
pub fn syslink_on_service_name_must_be_an_atom_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\tn := \"Inbox\"\n\thive.syslink.on(\"10.0.0.4:9100\", n)(Op.Put(\"k\"))\n}\n",
  )
  |> should.be_error
}

// `peers` is the nodes this one is connected to right now, each as the endpoint
// it advertised — so an entry is exactly what `on` takes, which is what makes it
// the answer to "who can I call later?".
pub fn syslink_peers_lowers_test() {
  let go =
    compile(
      service_prelude
      <> "proc main(): void {\n\tfor each endpoint in hive.syslink.peers() {\n\t\thive.syslink.on(endpoint, #Inbox)(Op.Count())\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.SyslinkPeers()"))
  should.be_true(string.contains(go, "hive.SyslinkOn(endpoint,"))
}

// A vector of endpoints: countable, walkable, and needing no annotation.
pub fn syslink_peers_is_a_vector_of_endpoints_test() {
  let go =
    compile(
      service_prelude
      <> "proc main(): void {\n\tconnected := hive.syslink.peers()\n\techo len(connected)\n\techo join(connected, \", \")\n}\n",
    )
  should.be_true(string.contains(go, "hive.SyslinkPeers()"))
  should.be_true(string.contains(go, "hive.Join("))
}

pub fn syslink_peers_takes_no_arguments_test() {
  // Which node's peers? There is only one answer, so there is nothing to pass.
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\techo len(hive.syslink.peers(\"127.0.0.1:9100\"))\n}\n",
  )
  |> should.be_error
}

pub fn syslink_peers_is_offered_by_name_test() {
  let assert Error(msg) =
    compiler.compile(
      service_prelude
      <> "proc main(): void {\n\thive.syslink.connections()\n}\n",
    )
  should.be_true(string.contains(msg, "listen, node, peers"))
}

// A program that only asks who it is talking to still needs the module.
pub fn syslink_peers_pulls_in_the_module_test() {
  let modules =
    used_modules(
      service_prelude
      <> "proc main(): void {\n\techo len(hive.syslink.peers())\n}\n",
    )
  should.be_true(list.contains(modules, "syslink"))
  should.be_true(list.contains(modules, "syslinknet"))
}

// There is no `send` and no `call`: an address is called directly, and the call
// site decides what the call means. Both old spellings get an error that says so.
pub fn syslink_has_no_call_member_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\thive.syslink.call(b, Op.Count(), 1000)\n}\n",
  )
  |> should.be_error
}

pub fn syslink_has_no_send_member_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\thive.syslink.send(b, Op.Count())\n}\n",
  )
  |> should.be_error
}

// An address is a mailbox, not a function: it carries exactly one message, so
// every other call shape is a mistake about what the value is and is named as
// one rather than lowered.
pub fn syslink_address_call_needs_a_message_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\tb()\n}\n",
  )
  |> should.be_error
}

pub fn syslink_address_call_takes_one_message_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\tb(Op.Count(), Op.Count())\n}\n",
  )
  |> should.be_error
}

pub fn syslink_address_call_has_no_named_argument_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\tb(message: Op.Count())\n}\n",
  )
  |> should.be_error
}

// A hole waits for an argument that arrives later; a send has nothing to wait
// for, so an address cannot be partially applied.
pub fn syslink_address_cannot_be_partially_applied_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\tlater := b(_)\n\tlater(Op.Count())\n}\n",
  )
  |> should.be_error
}

// Dispatch is by the callee's type, never by its spelling — so an address that
// arrived as a parameter is callable exactly like one that was just spawned.
pub fn syslink_address_parameter_is_callable_test() {
  let assert Ok(go) =
    compiler.compile(
      service_prelude
      <> "proc tell(a: hive.syslink.Address): void {\n\tasync a(Op.Put(\"k\"))\n}\n\nproc main(): void {\n\ttell(hive.syslink.spawn(box, 0))\n}\n",
    )
  string.contains(go, "hive.SyslinkSend(") |> should.be_true
}

// The same goes for an address that came out of the registry, called on the spot.
pub fn syslink_at_result_is_callable_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\tif hive.syslink.register(#Inbox, b) is Result.Error(e) {\n\t\tpanic e\n\t}\n\thive.syslink.at(#Inbox)(Op.Put(\"k\"))\n}\n",
  )
  |> should.be_ok
}

// A local address shadows a declared func of the same name, exactly as a local
// shadows a declaration everywhere else in the language.
pub fn syslink_address_shadows_a_func_of_the_same_name_test() {
  let assert Ok(go) =
    compiler.compile(
      service_prelude
      <> "func b(n: Int): Int {\n\treturn n\n}\n\nproc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\tasync b(Op.Put(\"k\"))\n}\n",
    )
  string.contains(go, "hive.SyslinkSend(") |> should.be_true
}

// `async`, a send is a cast: nothing is registered for a reply, so it lowers to
// the cheaper runtime call and cannot fail.
pub fn syslink_discarded_send_is_a_cast_test() {
  let assert Ok(go) =
    compiler.compile(
      service_prelude
      <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\tasync b(Op.Put(\"k\"))\n}\n",
    )
  string.contains(go, "hive.SyslinkSend(") |> should.be_true
  string.contains(go, "hive.SyslinkSendAwaitable(") |> should.be_false
}

// Written plainly, the very same call is a request that waits for the answer —
// and the answer needs no type annotation, because a service replies with one of
// its own messages.
pub fn syslink_awaited_send_is_a_request_test() {
  let assert Ok(go) =
    compiler.compile(
      service_prelude
      <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\tif b(Op.Count()) is Result.Ok(reply) {\n\t\tif reply is Op.Put(k) {\n\t\t\techo k\n\t\t}\n\t}\n}\n",
    )
  string.contains(go, "hive.SyslinkSendAwaitable(") |> should.be_true
  string.contains(go, "hive.SyslinkAwait(") |> should.be_true
}

// The wait can be bounded, and running out of patience folds into syslink's own
// error rather than wrapping a second Result around the first.
pub fn syslink_held_request_compiles_test() {
  compiler.compile(
    service_prelude
    <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\tif b(Op.Count()) with timeout 250 is Result.Error(e) {\n\t\techo e.reason\n\t}\n}\n",
  )
  |> should.be_ok
}

// An await-all over sends needs no goroutine at all: each send registers for its
// answer, and the barrier waits on the connection's reader.
pub fn syslink_await_many_requests_compiles_test() {
  let assert Ok(go) =
    compiler.compile(
      service_prelude
      <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\tboth := await [b(Op.Count()), b(Op.Count())] with timeout 500\n\tif both[0] is Result.Ok(_) {\n\t\techo \"first answered\"\n\t}\n}\n",
    )
  string.contains(go, "hive.SyslinkAwaitAll(") |> should.be_true
  string.contains(go, "hive.Spawn(") |> should.be_false
}

// ---------------------------------------------------------------------------
// `with timeout <ms>`
// ---------------------------------------------------------------------------

const async_prelude = "func slow(text: Str): Str {\n\treturn text\n}\n"

// Bounding a wait is what gives it a failure case, so the call becomes a Result
// exactly when the clause is written.
pub fn await_timeout_yields_a_result_test() {
  compiler.compile(
    async_prelude
    <> "proc main(): void {\n\tif slow(\"x\") with timeout 50 is Result.Error(err) {\n\t\techo err.message\n\t\techo err.waited\n\t}\n}\n",
  )
  |> should.be_ok
}

// Without the clause the same call yields the plain value and waits as long as it
// takes — no goroutine, no channel, nothing to schedule.
pub fn await_without_timeout_yields_the_value_test() {
  let assert Ok(go) =
    compiler.compile(
      async_prelude <> "proc main(): void {\n\techo slow(\"x\")\n}\n",
    )
  string.contains(go, "fmt.Println(slow(\"x\"))") |> should.be_true
  string.contains(go, "AwaitTimeout") |> should.be_false
  string.contains(go, "hive.Spawn(") |> should.be_false
}

// One deadline across a whole await-all, not one per call.
pub fn await_timeout_on_a_vector_compiles_test() {
  let assert Ok(go) =
    compiler.compile(
      async_prelude
      <> "proc main(): void {\n\tif await [slow(\"a\"), slow(\"b\")] with timeout 500 is Result.Ok(done) {\n\t\techo join(done, \",\")\n\t}\n}\n",
    )
  string.contains(go, "hive.AwaitAllTimeout(") |> should.be_true
}

// A bounded call needs a task even though only one call is involved: something
// has to still be running when the wait gives up.
pub fn await_timeout_on_a_direct_call_spawns_a_handle_test() {
  let assert Ok(go) =
    compiler.compile(
      async_prelude
      <> "proc main(): void {\n\tif slow(\"x\") with timeout 50 is Result.Ok(v) {\n\t\techo v\n\t}\n}\n",
    )
  string.contains(go, "hive.AwaitTimeout(hive.Spawn(") |> should.be_true
}

// The clause bounds a wait, so there has to be a wait to bound.
pub fn with_timeout_only_follows_a_wait_test() {
  compiler.compile("proc main(): void {\n\techo 1 with timeout 50\n}\n")
  |> should.be_error
}

// A `void` call has no value for the Result to carry, so bounding one is refused
// rather than lowered to a type with no spelling.
pub fn with_timeout_needs_a_value_to_carry_test() {
  let assert Error(msg) =
    compiler.compile(
      "proc work(): void {\n\techo \"x\"\n}\nproc main(): void {\n\tif work() with timeout 50 is Result.Ok(_) {\n\t\techo \"done\"\n\t}\n}\n",
    )
  should.be_true(string.contains(msg, "there is nothing for it to carry"))
}

// `timeout` is deliberately not a reserved word: it means something only in the
// two-token `with timeout` clause, so it stays usable as an ordinary name.
pub fn timeout_is_still_a_usable_identifier_test() {
  compiler.compile(
    "proc main(): void {\n\ttimeout := 30\n\techo timeout\n}\n",
  )
  |> should.be_ok
}

// The clause stops before `is`, so the comparison is not folded into the
// millisecond count.
pub fn timeout_clause_stops_before_is_test() {
  let assert Ok(go) =
    compiler.compile(
      async_prelude
      <> "proc main(): void {\n\tif slow(\"x\") with timeout 50 is Result.Ok(v) {\n\t\techo v\n\t}\n}\n",
    )
  string.contains(go, "50.IsOk()") |> should.be_false
  string.contains(go, ", 50)") |> should.be_true
}

pub fn syslink_unknown_member_is_rejected_test() {
  compiler.compile(
    "proc main(): void {\n\thive.syslink.broadcast(#Inbox)\n}\n",
  )
  |> should.be_error
}

// A service outlives the scope that spawned it, so its address is an ordinary
// value: it can be a parameter, a field, and travel inside a message.
pub fn syslink_address_is_a_plain_value_test() {
  compiler.compile(
    "type Op {\n\tWatch { peer: hive.syslink.Address }\n}\n\nproc box(n: Int, op: Op, from: hive.syslink.Envelope): Int {\n\tif op is Op.Watch(peer) {\n\t\thive.syslink.monitor(from, peer, Op.Watch(hive.syslink.self(from)))\n\t}\n\treturn n\n}\n\nproc pass(a: hive.syslink.Address): void {\n\ta(Op.Watch(a))\n}\n\nproc main(): void {\n\tpass(hive.syslink.spawn(box, 0))\n}\n",
  )
  |> should.be_ok
}

// The digest travels in every frame so a peer built from a different
// declaration fails loudly instead of decoding another type's bytes. Sender and
// recipient must therefore agree on it within one build.
pub fn syslink_send_and_spawn_agree_on_the_digest_test() {
  let assert Ok(go) =
    compiler.compile(
      service_prelude
      <> "proc main(): void {\n\tb := hive.syslink.spawn(box, 0)\n\tb(Op.Put(\"k\"))\n}\n",
    )
  // Both call sites name the same 32-bit digest, so exactly one distinct value
  // appears across the spawn and the send.
  let digests =
    go
    |> string.split("0x")
    |> list.drop(1)
    |> list.map(fn(rest) { string.slice(rest, 0, 8) })
    |> list.unique
  digests |> list.length |> should.equal(1)
}

// ---------------------------------------------------------------------------
// Vector bounds checking (flow-sensitive out-of-bounds prevention)
// ---------------------------------------------------------------------------

// --- Static vectors: literal index decided at compile time ---

pub fn static_vector_literal_in_range_compiles_test() {
  // `v` has length 3, so `v[2]` is provably safe.
  compiler.compile("proc main(): void {\n\tv := [\"a\", \"b\", \"c\"]\n\techo v[2]\n}\n")
  |> should.be_ok
}

pub fn static_vector_literal_out_of_range_is_rejected_test() {
  // `v` has length 2, so `v[2]` is out of range.
  compiler.compile("proc main(): void {\n\tv := [\"a\", \"b\"]\n\techo v[2]\n}\n")
  |> should.be_error
}

pub fn static_vector_element_assignment_in_range_compiles_test() {
  // The `mutableVector[0] = ...` shape from the types example.
  compiler.compile(
    "proc main(): void {\n\tmut v := [\"a\", \"b\"]\n\tv[0] = \"c\"\n}\n",
  )
  |> should.be_ok
}

pub fn static_vector_element_assignment_out_of_range_is_rejected_test() {
  compiler.compile(
    "proc main(): void {\n\tmut v := [\"a\", \"b\"]\n\tv[2] = \"c\"\n}\n",
  )
  |> should.be_error
}

// --- Dynamic vectors: unguarded access is rejected ---

pub fn dynamic_vector_unguarded_literal_is_rejected_test() {
  // The spec's motivating example: `dynamicVector[3]` must be an error.
  compiler.compile(
    "func f(v: Str[dyn]): Str {\n\treturn v[3]\n}\nproc main(): void {}\n",
  )
  |> should.be_error
}

pub fn dynamic_vector_unguarded_variable_is_rejected_test() {
  compiler.compile(
    "func f(v: Str[dyn], i: Int): Str {\n\treturn v[i]\n}\nproc main(): void {}\n",
  )
  |> should.be_error
}

// --- Dynamic vectors: the guard shapes from the spec ---

pub fn dynamic_vector_guarded_literal_compiles_test() {
  // `if 3 < len(v) { v[3] }` — exactly the spec's accepted form.
  compiler.compile(
    "func f(v: Str[dyn]): Str {\n\tif 3 < len(v) {\n\t\treturn v[3]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_ok
}

pub fn dynamic_vector_guarded_variable_compiles_test() {
  // `if i >= 0 && i < len(v) { v[i] }` — the full guard for a variable index.
  compiler.compile(
    "func f(v: Str[dyn], i: Int): Str {\n\tif i >= 0 && i < len(v) {\n\t\treturn v[i]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_ok
}

pub fn variable_index_without_lower_bound_is_rejected_test() {
  // Upper bound alone is not enough for a variable index: `i >= 0` is required.
  compiler.compile(
    "func f(v: Str[dyn], i: Int): Str {\n\tif i < len(v) {\n\t\treturn v[i]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_error
}

pub fn guard_on_the_wrong_vector_is_rejected_test() {
  // The guard proves `i < len(w)`, but the access is on `v`.
  compiler.compile(
    "func f(v: Str[dyn], w: Str[dyn], i: Int): Str {\n\tif i >= 0 && i < len(w) {\n\t\treturn v[i]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_error
}

pub fn length_bound_in_a_variable_compiles_test() {
  // `n := len(v)` then guarding with `n` must still prove the bound.
  compiler.compile(
    "func f(v: Str[dyn], i: Int): Str {\n\tn := len(v)\n\tif i >= 0 && i < n {\n\t\treturn v[i]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_ok
}

// --- Guard clauses (early return proves the negation afterwards) ---

pub fn guard_clause_early_return_compiles_test() {
  compiler.compile(
    "func f(v: Str[dyn], i: Int): Str {\n\tif i >= len(v) {\n\t\treturn \"\"\n\t}\n\tif i < 0 {\n\t\treturn \"\"\n\t}\n\treturn v[i]\n}\nproc main(): void {}\n",
  )
  |> should.be_ok
}

// --- Counting loops ---

pub fn counting_loop_indexes_safely_test() {
  // `for i := 0; i < len(v); i = i + 1 { v[i] }` — the counter is `>= 0` from
  // its zero start and `< len(v)` from the loop condition.
  compiler.compile(
    "proc main(): void {\n\tv := [\"a\", \"b\", \"c\"]\n\tfor i := 0; i < len(v); i = i + 1 {\n\t\techo v[i]\n\t}\n}\n",
  )
  |> should.be_ok
}

pub fn for_each_needs_no_guard_test() {
  compiler.compile(
    "proc main(): void {\n\tv := [\"a\", \"b\"]\n\tfor each x in v {\n\t\techo x\n\t}\n}\n",
  )
  |> should.be_ok
}

// --- Mutation invalidates a previously-proven bound ---

pub fn reassignment_inside_guard_invalidates_bound_test() {
  // `v` is proven long enough, then reassigned to another vector before the
  // access — the earlier proof no longer holds.
  compiler.compile(
    "proc main(): void {\n\tmut Str[dyn] v = [\"a\"]\n\tmut Str[dyn] w = [\"b\"]\n\ti := 0\n\tif i >= 0 && i < len(v) {\n\t\tv = w\n\t\techo v[i]\n\t}\n}\n",
  )
  |> should.be_error
}

pub fn reassignment_inside_a_branch_invalidates_a_static_length_test() {
  // The branch may or may not have run, and the vector it binds is shorter —
  // so after the `if`, `v`'s length is no longer the literal's.
  compiler.compile(
    "proc main(): void {\n\tmut v := [\"a\", \"b\", \"c\"]\n\tif len(v) > 0 {\n\t\tv = [\"x\"]\n\t}\n\techo v[2]\n}\n",
  )
  |> should.be_error
}

pub fn reassignment_inside_a_loop_invalidates_a_static_length_test() {
  compiler.compile(
    "proc main(): void {\n\tmut v := [\"a\", \"b\", \"c\"]\n\tfor i := 0; i < 2; i = i + 1 {\n\t\tv = [\"x\"]\n\t}\n\techo v[2]\n}\n",
  )
  |> should.be_error
}

pub fn declared_length_survives_a_matching_reassignment_test() {
  // A *declared* length is different: every assignment is held to it, so it is
  // still the vector's length after the branch.
  compiler.compile(
    "proc main(): void {\n\tmut Str[3] v = [\"a\", \"b\", \"c\"]\n\tif len(v) > 0 {\n\t\tv = [\"x\", \"y\", \"z\"]\n\t}\n\techo v[2]\n}\n",
  )
  |> should.be_ok
}

pub fn element_write_inside_a_branch_keeps_the_static_length_test() {
  // Writing *through* the name replaces an element, not the vector, so the
  // length the compiler knows is still the right one.
  compiler.compile(
    "proc main(): void {\n\tmut v := [\"a\", \"b\", \"c\"]\n\tif len(v) > 0 {\n\t\tv[0] = \"x\"\n\t}\n\techo v[2]\n}\n",
  )
  |> should.be_ok
}

pub fn append_inside_a_branch_keeps_a_proven_position_test() {
  // `append` only grows the vector, so a position already proven stays proven.
  compiler.compile(
    "proc main(): void {\n\tmut Str[dyn] v = [\"a\", \"b\", \"c\"]\n\tif 2 < len(v) {\n\t\tappend(v, \"x\")\n\t\techo v[2]\n\t}\n}\n",
  )
  |> should.be_ok
}

pub fn append_needs_a_vector_declared_dyn_test() {
  // A `:=` binding reads its length off the value, and a length read off a value
  // is a static one — so it is not something `append` can grow. Being dynamic has
  // to be declared.
  let assert Error(msg) =
    compiler.compile(
      "proc main(): void {\n\tmut v := [\"a\", \"b\", \"c\"]\n\tappend(v, \"d\")\n}\n",
    )
  should.be_true(string.contains(msg, "requires a dynamic vector"))
  should.be_true(string.contains(msg, "bound with `:=`"))
}

pub fn append_rejects_a_static_length_test() {
  // The other half of the same rule: a declared length is a promise, and a promise
  // cannot be grown out of.
  let assert Error(msg) =
    compiler.compile(
      "proc main(): void {\n\tmut Str[3] v = [\"a\", \"b\", \"c\"]\n\tappend(v, \"d\")\n}\n",
    )
  should.be_true(string.contains(msg, "requires a dynamic vector"))
  should.be_true(string.contains(msg, "static length"))
}

pub fn append_still_grows_a_dyn_field_of_a_mut_struct_test() {
  // A `[dyn]` field is reached through a variable whose own type says nothing
  // about it, so the field keeps working — only the plain-variable form is held
  // to the declaration rule above.
  compiler.compile(
    "type Box { items: Str[dyn] }\nproc main(): void {\n\tmut b := Box([\"a\"])\n\tappend(b.items, \"c\")\n\techo b.items\n}\n",
  )
  |> should.be_ok
}

pub fn append_grows_a_table_test() {
  // `Table` is an alias for `Str[dyn][dyn]`, so a row can be appended to one.
  compiler.compile(
    "proc main(): void {\n\tmut Table t = [[\"a\", \"b\"]]\n\tappend(t, [\"c\", \"d\"])\n\techo t\n}\n",
  )
  |> should.be_ok
}

// --- Declared lengths are promises the whole program is held to ---

pub fn declaration_rejects_a_vector_of_the_wrong_length_test() {
  compiler.compile(
    "proc main(): void {\n\tStr[3] v = [\"a\", \"b\"]\n\techo v[0]\n}\n",
  )
  |> should.be_error
}

pub fn assignment_rejects_a_vector_of_the_wrong_length_test() {
  compiler.compile(
    "proc main(): void {\n\tmut Str[3] v = [\"a\", \"b\", \"c\"]\n\tv = [\"x\"]\n\techo v[0]\n}\n",
  )
  |> should.be_error
}

pub fn argument_rejects_a_vector_of_the_wrong_length_test() {
  // Without this the callee's body would index a `Str[3]` that isn't one.
  compiler.compile(
    "func f(v: Str[3]): Str {\n\treturn v[2]\n}\nproc main(): void {\n\techo f([\"a\"])\n}\n",
  )
  |> should.be_error
}

pub fn return_rejects_a_vector_of_the_wrong_length_test() {
  compiler.compile(
    "func f(): Str[3] {\n\treturn [\"a\", \"b\"]\n}\nproc main(): void {\n\techo f()[0]\n}\n",
  )
  |> should.be_error
}

pub fn element_slot_rejects_a_vector_of_the_wrong_length_test() {
  // `t[0]` is a `Str[2]` slot, so the row written into it must be one.
  compiler.compile(
    "proc main(): void {\n\tmut Str[2][2] t = [[\"a\", \"b\"], [\"c\", \"d\"]]\n\tt[0] = [\"x\"]\n\techo t[0][0]\n}\n",
  )
  |> should.be_error
}

pub fn nested_rows_of_a_literal_are_checked_test() {
  // `Str[2][3]`: two rows of three, and the second row is short.
  compiler.compile(
    "proc main(): void {\n\tStr[2][3] t = [[\"a\", \"b\", \"c\"], [\"d\", \"e\"]]\n\techo t[0][0]\n}\n",
  )
  |> should.be_error
}

pub fn a_length_that_is_not_known_cannot_fill_a_static_slot_test() {
  // `split` can return any number of parts, so it is not a `Str[3]`.
  compiler.compile(
    "proc main(): void {\n\tStr[3] parts = split(\"a,b,c\", \",\")\n\techo parts[2]\n}\n",
  )
  |> should.be_error
}

pub fn declared_length_accepts_a_call_return_and_a_concatenation_test() {
  // A declared return type carries its length to the call site, and `+`
  // concatenates, so both are known well enough to fill a `Str[3]`.
  compiler.compile(
    "func three(): Str[3] {\n\treturn [\"a\", \"b\", \"c\"]\n}\nproc main(): void {\n\tStr[3] a = three()\n\tStr[2] b = [\"x\", \"y\"]\n\tStr[3] c = b + [\"z\"]\n\techo a[2] + c[2]\n}\n",
  )
  |> should.be_ok
}

pub fn dynamic_declarations_promise_nothing_test() {
  // `[dyn]` says the length varies, so any vector fits — and indexing it still
  // needs a guard.
  compiler.compile(
    "proc main(): void {\n\tStr[dyn] v = [\"a\"]\n\tStr[dyn] w = [\"a\", \"b\", \"c\"]\n\techo len(v) + len(w)\n}\n",
  )
  |> should.be_ok
}

pub fn a_local_that_shadows_a_callable_is_not_held_to_its_parameters_test() {
  // `pick` here is a function value, not the `Str[3]`-taking declaration.
  compiler.compile(
    "func pick(v: Str[3]): Str {\n\treturn v[0]\n}\nfunc take(v: Str[dyn]): Str {\n\treturn \"\"\n}\nproc main(): void {\n\tpick := take\n\techo pick([\"a\"])\n}\n",
  )
  |> should.be_ok
}

// --- Computed indices are conservatively rejected ---

pub fn computed_index_is_rejected_test() {
  // `i` is guarded, but `i + 1` is a computed expression the checker won't
  // reason about — it must be extracted and guarded itself.
  compiler.compile(
    "func f(v: Str[dyn], i: Int): Str {\n\tif i >= 0 && i < len(v) {\n\t\treturn v[i + 1]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_error
}

// --- Slices ---

pub fn slice_guarded_low_bound_compiles_test() {
  // `v[1:]` under `if len(v) > 1` — the low bound is proven `<= len(v)`.
  compiler.compile(
    "func f(v: Str[dyn]): Str[dyn] {\n\tif len(v) > 1 {\n\t\treturn v[1:]\n\t}\n\treturn v\n}\nproc main(): void {}\n",
  )
  |> should.be_ok
}

pub fn slice_unguarded_low_bound_is_rejected_test() {
  compiler.compile(
    "func f(v: Str[dyn]): Str[dyn] {\n\treturn v[1:]\n}\nproc main(): void {}\n",
  )
  |> should.be_error
}

pub fn slice_high_bound_out_of_range_is_rejected_test() {
  // `v` has length 2; the inclusive high bound 5 is out of range.
  compiler.compile(
    "proc main(): void {\n\tv := [\"a\", \"b\"]\n\techo v[0:5]\n}\n",
  )
  |> should.be_error
}

// --- Monotonic literal bounds: one check covers all smaller literal indices ---

pub fn proving_one_literal_bound_covers_smaller_indices_test() {
  // `if 1 < len(v)` proves `v[1]` AND `v[0]` — no separate `0 < len(v)` needed.
  compiler.compile(
    "func f(v: Str[dyn]): Str {\n\tif 1 < len(v) {\n\t\techo v[0]\n\t\treturn v[1]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_ok
}

pub fn literal_bound_does_not_cover_larger_indices_test() {
  // `if 1 < len(v)` says nothing about index 2 — still rejected.
  compiler.compile(
    "func f(v: Str[dyn]): Str {\n\tif 1 < len(v) {\n\t\treturn v[2]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_error
}

pub fn variable_guard_proves_index_zero_test() {
  // `if i >= 0 && i < len(v)` forces `len(v) >= 1`, so the literal index 0 is
  // safe even though only `i` was named in the guard.
  compiler.compile(
    "func f(v: Str[dyn], i: Int): Str {\n\tif i >= 0 && i < len(v) {\n\t\techo v[0]\n\t\treturn v[i]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_ok
}

pub fn variable_guard_does_not_prove_index_one_test() {
  // `len(v) >= 1` (from `i >= 0 && i < len(v)`) does not prove `1 < len(v)`.
  compiler.compile(
    "func f(v: Str[dyn], i: Int): Str {\n\tif i >= 0 && i < len(v) {\n\t\treturn v[1]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_error
}

// --- `indexOf`: an Ok payload is a bounded index by construction ---

pub fn index_of_result_needs_no_guard_test() {
  // `i` came out of a search of `v`, so it is a position `v` has: no
  // `i >= 0 && i < len(v)` guard is required to use it.
  compiler.compile(
    "func f(v: Str[dyn]): Str {\n\tr := indexOf(v, \"x\")\n\tif r is Result.Ok(i) {\n\t\treturn v[i]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_ok
}

pub fn index_of_matched_inline_needs_no_guard_test() {
  // The same when the call is narrowed on the spot rather than bound first.
  compiler.compile(
    "func f(v: Str[dyn]): Str {\n\tif indexOf(v, \"x\") is Result.Ok(i) {\n\t\treturn v[i]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_ok
}

pub fn index_of_result_proves_the_vector_is_non_empty_test() {
  // `0 <= i < len(v)` forces `len(v) >= 1`, so the literal index 0 rides along.
  compiler.compile(
    "func f(v: Str[dyn]): Str {\n\tif indexOf(v, \"x\") is Result.Ok(i) {\n\t\techo v[i]\n\t\treturn v[0]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_ok
}

pub fn index_of_index_does_not_license_another_vector_test() {
  // An index found in `v` says nothing about `w`'s length.
  compiler.compile(
    "func f(v: Str[dyn], w: Str[dyn]): Str {\n\tr := indexOf(v, \"x\")\n\tif r is Result.Ok(i) {\n\t\treturn w[i]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_error
}

pub fn index_of_index_is_dropped_when_the_vector_is_rebound_test() {
  // The searched vector is replaced before the result is used, so the position
  // it reported may no longer exist.
  compiler.compile(
    "proc main(): void {\n\tmut v := [\"a\", \"b\", \"c\"]\n\tr := indexOf(v, \"c\")\n\tv = [\"z\"]\n\tif r is Result.Ok(i) {\n\t\techo v[i]\n\t}\n}\n",
  )
  |> should.be_error
}

pub fn index_of_index_survives_an_append_test() {
  // `append` only grows the vector, so a position it already had stays valid.
  compiler.compile(
    "proc main(): void {\n\tmut Str[dyn] v = [\"a\", \"b\"]\n\tr := indexOf(v, \"b\")\n\tappend(v, \"c\")\n\tif r is Result.Ok(i) {\n\t\techo v[i]\n\t}\n}\n",
  )
  |> should.be_ok
}

pub fn is_binding_shadows_an_earlier_bounded_index_test() {
  // The inner `is` rebinds `i` to a position in `b`; what was proven about the
  // outer `i` (a position in `a`) no longer holds for it.
  compiler.compile(
    "func f(a: Str[dyn], b: Str[dyn]): Str {\n\tra := indexOf(a, \"x\")\n\tif ra is Result.Ok(i) {\n\t\trb := indexOf(b, \"y\")\n\t\tif rb is Result.Ok(i) {\n\t\t\treturn a[i]\n\t\t}\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_error
}

// ---------------------------------------------------------------------------
// `bounds` keyword
// ---------------------------------------------------------------------------

pub fn bounds_keyword_desugars_to_guard_test() {
  // `v bounds i` expands to `i >= 0 && i < len(v)` — which also satisfies the
  // index-safety checker, so the guarded access compiles.
  let go =
    compile(
      "func f(v: Str[dyn], i: Int): Str {\n\tif v bounds i {\n\t\treturn v[i]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "(i >= 0)"))
  should.be_true(string.contains(go, "(i < len(v))"))
}

pub fn bounds_keyword_does_not_bypass_safety_test() {
  // Using `bounds` on one vector does not license indexing another.
  compiler.compile(
    "func f(v: Str[dyn], w: Str[dyn], i: Int): Str {\n\tif w bounds i {\n\t\treturn v[i]\n\t}\n\treturn \"\"\n}\nproc main(): void {}\n",
  )
  |> should.be_error
}

// ---------------------------------------------------------------------------
// Go-keyword escaping
// ---------------------------------------------------------------------------

pub fn go_keyword_identifiers_are_escaped_test() {
  // `select` and `map` are Go keywords, not Hive keywords: escape them so the
  // generated Go still compiles, consistently at definition and use.
  let go =
    compile(
      "func select(map: Int): Int {\n\treturn map\n}\nproc main(): void {\n\techo select(1)\n}\n",
    )
  should.be_true(string.contains(go, "func select_(map_ int)"))
  should.be_true(string.contains(go, "return map_"))
  should.be_true(string.contains(go, "select_(1)"))
}

pub fn non_keyword_identifiers_are_left_alone_test() {
  let go =
    compile("proc main(): void {\n\tfoo := 1\n\techo foo\n}\n")
  should.be_true(string.contains(go, "foo := 1"))
  should.be_false(string.contains(go, "foo_"))
}

// ---------------------------------------------------------------------------
// Compound assignment and increment / decrement
// ---------------------------------------------------------------------------

pub fn compound_assignment_operators_test() {
  let go =
    compile(
      "proc main(): void {\n\tmut x := 10\n\tx += 3\n\tx -= 1\n\tx *= 2\n\tx /= 4\n\techo x\n}\n",
    )
  should.be_true(string.contains(go, "x = (x + 3)"))
  should.be_true(string.contains(go, "x = (x - 1)"))
  should.be_true(string.contains(go, "x = (x * 2)"))
  // `/=` keeps division's zero-safety.
  should.be_true(string.contains(go, "x = hive.DivInt(x, 4)"))
}

pub fn increment_and_decrement_operators_test() {
  let go =
    compile(
      "proc main(): void {\n\tmut x := 0\n\tx++\n\tx--\n\techo x\n}\n",
    )
  should.be_true(string.contains(go, "x = (x + 1)"))
  should.be_true(string.contains(go, "x = (x - 1)"))
}

pub fn compound_assignment_to_immutable_is_rejected_test() {
  compiler.compile("proc main(): void {\n\tx := 1\n\tx += 1\n}\n")
  |> should.be_error
}

// ---------------------------------------------------------------------------
// break / continue
// ---------------------------------------------------------------------------

pub fn break_and_continue_lower_to_go_test() {
  let go =
    compile(
      "proc main(): void {\n\tfor i := 0; i < 5; i++ {\n\t\tif i == 1 {\n\t\t\tcontinue\n\t\t}\n\t\tif i == 3 {\n\t\t\tbreak\n\t\t}\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "continue"))
  should.be_true(string.contains(go, "break"))
}

pub fn break_outside_loop_is_rejected_test() {
  compiler.compile("proc main(): void {\n\tbreak\n}\n")
  |> should.be_error
}

pub fn continue_outside_loop_is_rejected_test() {
  compiler.compile("proc main(): void {\n\tcontinue\n}\n")
  |> should.be_error
}

// ---------------------------------------------------------------------------
// hive.env
// ---------------------------------------------------------------------------

pub fn env_get_lowers_to_runtime_test() {
  let go =
    compile(
      "proc main(): void {\n\tr := hive.env.get(\"HOME\")\n\tif r is Result.Ok(v) {\n\t\techo v\n\t} else if r is Result.Error(e) {\n\t\techo e.key\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.EnvGet(\"HOME\")"))
  // `hive.env.get` yields a Result, so the `is Result.Ok/Error` narrowing works
  // and the error's fields lower to their exported Go names.
  should.be_true(string.contains(go, "r.IsOk()"))
  should.be_true(string.contains(go, ".Key"))
}

pub fn env_get_requires_one_argument_test() {
  compiler.compile("proc main(): void {\n\thive.env.get()\n}\n")
  |> should.be_error
}

pub fn unknown_env_builtin_is_rejected_test() {
  compiler.compile("proc main(): void {\n\thive.env.set(\"K\", \"V\")\n}\n")
  |> should.be_error
}

// ---------------------------------------------------------------------------
// Strict vector equality (a vector vs a non-vector no longer silently false)
// ---------------------------------------------------------------------------

pub fn vector_compared_to_scalar_uses_native_equality_test() {
  // Must NOT route to VecEq (which would silently return false); it stays a
  // plain `==` so the Go compiler rejects the type mismatch.
  let go =
    compile("proc main(): void {\n\txs := [1, 2, 3]\n\techo xs == 5\n}\n")
  should.be_true(string.contains(go, "(xs == 5)"))
  should.be_false(string.contains(go, "VecEq"))
}

pub fn vector_vs_vector_still_uses_runtime_equality_test() {
  let go =
    compile(
      "proc main(): void {\n\ta := [1, 2]\n\tb := [1, 2]\n\techo a == b\n}\n",
    )
  should.be_true(string.contains(go, "hive.VecEq(a, b)"))
}

// ---------------------------------------------------------------------------
// Vector copy-on-binding (value semantics unless both sides are mutable)
// ---------------------------------------------------------------------------

pub fn immutable_vector_binding_is_cloned_test() {
  // `ys` is immutable and `xs` is mutated afterwards, so `ys` must be an
  // independent snapshot. The copy is type-directed (no reflection): a flat
  // Int vector clones with hive.CloneVec.
  let go =
    compile(
      "proc main(): void {\n\tmut xs := [1, 2, 3]\n\tys := xs\n\txs[0] = 9\n\techo ys[0]\n}\n",
    )
  should.be_true(string.contains(go, "ys := hive.CloneVec(xs)"))
  // The reflective runtime Clone is gone.
  should.be_false(string.contains(go, "hive.Clone("))
}

pub fn both_mutable_vector_binding_is_shared_test() {
  // Two mutable bindings share storage (shared mutable state is the intent).
  // They share it by *name*: `ys` gets no slice header of its own, so every read
  // and write through it goes to `xs`. Two headers would only stay in step until
  // an `append` reallocated one of them.
  let go =
    compile(
      "proc main(): void {\n\tmut xs := [1, 2, 3]\n\tmut ys := xs\n\txs[0] = 9\n\techo ys[0]\n}\n",
    )
  should.be_false(string.contains(go, "ys"))
  should.be_true(string.contains(go, "fmt.Println(xs[0])"))
  should.be_false(string.contains(go, "Clone"))
}

pub fn append_does_not_sever_a_shared_binding_test() {
  // `append` on either name has to be seen through the other: it lowers to a
  // reassignment of the one shared header, not of a private copy.
  let go =
    compile(
      "proc main(): void {\n\tmut Int[dyn] xs = [1, 2, 3]\n\tmut Int[dyn] ys = xs\n\tappend(ys, 4)\n\tif 0 < len(xs) {\n\t\txs[0] = 9\n\t}\n\tif 0 < len(ys) {\n\t\techo ys[0]\n\t}\n\techo len(xs)\n}\n",
    )
  should.be_true(string.contains(go, "xs = append(xs, 4)"))
  should.be_false(string.contains(go, "ys"))
}

pub fn fresh_vector_binding_is_not_cloned_test() {
  // A vector literal is already fresh — no copy needed.
  let go =
    compile("proc main(): void {\n\tys := [1, 2, 3]\n\techo ys[0]\n}\n")
  should.be_false(string.contains(go, "Clone"))
}

pub fn both_immutable_vector_binding_is_aliased_test() {
  // Neither end can ever mutate the shared storage, so no copy is needed even
  // though `ys` binds an existing vector.
  let go =
    compile(
      "proc main(): void {\n\txs := [1, 2, 3]\n\tys := xs\n\techo xs[0]\n\techo ys[0]\n}\n",
    )
  should.be_true(string.contains(go, "ys := xs"))
  should.be_false(string.contains(go, "Clone"))
}

pub fn unmutated_mutable_target_is_not_cloned_test() {
  // (B) `ys` is `mut` but never written through, so it stays a cheap alias of
  // the immutable `xs` — the shared storage is never mutated.
  let go =
    compile(
      "proc main(): void {\n\txs := [1, 2, 3]\n\tmut ys := xs\n\techo ys[0]\n}\n",
    )
  should.be_true(string.contains(go, "ys := xs"))
  should.be_false(string.contains(go, "Clone"))
}

pub fn mutated_mutable_target_is_cloned_test() {
  // (B) The moment `ys` is written through, it must own its storage.
  let go =
    compile(
      "proc main(): void {\n\txs := [1, 2, 3]\n\tmut ys := xs\n\tys[0] = 9\n\techo xs[0]\n}\n",
    )
  should.be_true(string.contains(go, "ys := hive.CloneVec(xs)"))
}

pub fn mutable_target_aliased_onward_is_cloned_test() {
  // (B) `ys` is never written through directly, but it is handed to another
  // mutable binding that could be — so it is not inert and must be copied.
  let go =
    compile(
      "proc main(): void {\n\txs := [1, 2, 3]\n\tmut ys := xs\n\tmut zs := ys\n\tzs[0] = 9\n\techo xs[0]\n}\n",
    )
  should.be_true(string.contains(go, "ys := hive.CloneVec(xs)"))
}

pub fn dead_mutable_source_is_moved_test() {
  // (C) `xs` is mutable but never mutated again after `ys` binds it, so the
  // immutable `ys` may take it over (a move) instead of copying.
  let go =
    compile(
      "proc main(): void {\n\tmut xs := [1, 2, 3]\n\txs[0] = 5\n\tys := xs\n\techo ys[0]\n}\n",
    )
  should.be_true(string.contains(go, "ys := xs"))
  should.be_false(string.contains(go, "Clone"))
}

pub fn live_mutable_source_is_cloned_test() {
  // (C) When the mutable source keeps being mutated after the binding, the
  // immutable snapshot must be copied.
  let go =
    compile(
      "proc main(): void {\n\tmut xs := [1, 2, 3]\n\tys := xs\n\txs[0] = 5\n\techo ys[0]\n}\n",
    )
  should.be_true(string.contains(go, "ys := hive.CloneVec(xs)"))
}

pub fn table_binding_uses_type_directed_clone_test() {
  // A Table copies through the dedicated deep helper, not reflection.
  let go =
    compile(
      "proc main(): void {\n\tmut t := [[\"a\"], [\"b\"]]\n\tsnap := t\n\tt[0] = [\"z\"]\n\techo snap\n}\n",
    )
  should.be_true(string.contains(go, "hive.CloneVecFn("))
  should.be_false(string.contains(go, "hive.Clone("))
}

pub fn struct_with_vector_field_deep_clones_test() {
  // A struct holding a vector gets a generated clone_T that recurses into the
  // vector field, so mutating the copy cannot leak into the original.
  // `b` is a mutable copy of the immutable `a` and is handed to another
  // mutable binding, so it must own its storage — including the vector field.
  let go =
    compile(
      "type Bag {\n\titems: Int[3]\n}\nproc main(): void {\n\ta := Bag(items: [1, 2, 3])\n\tmut b := a\n\tmut c := b\n\techo c.items\n}\n",
    )
  // The binding delegates to the generated deep-clone function.
  should.be_true(string.contains(go, "b := clone_Bag(a)"))
  // Which itself re-copies the vector field.
  should.be_true(string.contains(go, "func clone_Bag(x Bag) Bag"))
  should.be_true(string.contains(go, "x.Items = hive.CloneVec(x.Items)"))
}

pub fn source_laundered_through_call_is_cloned_test() {
  // A move would be unsound: `row` binds a slice returned from a call on `xs`,
  // which may share xs's backing array, and then writes through it. Because
  // `xs` escapes into that call, the immutable `ys` must be an independent copy
  // rather than a cheap alias.
  let go =
    compile(
      "func firstOf(v: Int[dyn]): Int[dyn] {\n\treturn v\n}\nproc main(): void {\n\tmut xs := [1, 2, 3]\n\tys := xs\n\tmut row := firstOf(xs)\n\tif 0 < len(row) {\n\t\trow[0] = 9\n\t}\n\techo ys\n}\n",
    )
  should.be_true(string.contains(go, "ys := hive.CloneVec(xs)"))
}

pub fn target_laundered_through_call_is_cloned_test() {
  // The both-immutable alias is likewise withheld when the target escapes into
  // a call whose result is mutated — the shared storage would no longer be a
  // stable snapshot.
  let go =
    compile(
      "func firstOf(v: Int[dyn]): Int[dyn] {\n\treturn v\n}\nproc main(): void {\n\txs := [1, 2, 3]\n\tys := xs\n\tmut row := firstOf(ys)\n\tif 0 < len(row) {\n\t\trow[0] = 9\n\t}\n\techo xs\n}\n",
    )
  should.be_true(string.contains(go, "ys := hive.CloneVec(xs)"))
}

pub fn struct_without_vector_field_needs_no_clone_test() {
  // A scalar-only struct is fully isolated by Go's own value copy — no helper.
  let go =
    compile(
      "type Point {\n\tx: Int\n\ty: Int\n}\nproc main(): void {\n\ta := Point(x: 1, y: 2)\n\tmut b := a\n\tb.x = 9\n\techo a.x\n}\n",
    )
  should.be_false(string.contains(go, "clone_Point"))
  should.be_true(string.contains(go, "b := a"))
}

// ---------------------------------------------------------------------------
// Exhaustiveness: non-void proc/func must return on every path
// ---------------------------------------------------------------------------

pub fn non_exhaustive_function_is_rejected_test() {
  compiler.compile(
    "func f(cond: Bool): Int {\n\tif cond {\n\t\treturn 1\n\t}\n}\nproc main(): void {}\n",
  )
  |> should.be_error
}

pub fn assert_tail_counts_as_terminating_test() {
  // `assert` is Hive's panic; it makes a tail a terminating path.
  compiler.compile(
    "func f(cond: Bool): Int {\n\tif cond {\n\t\treturn 1\n\t}\n\tassert false\n}\nproc main(): void {}\n",
  )
  |> should.be_ok
}

pub fn panic_renders_value_like_echo_test() {
  let go =
    compile("proc main(): void {\n\tpanic \"boom\"\n}\n")
  // `panic value` renders via hive.Show (echo's formatting), then aborts.
  should.be_true(string.contains(go, "panic(hive.Show(\"boom\"))"))
}

pub fn panic_accepts_any_value_test() {
  // Unlike `assert` (boolean only), `panic` stringifies whatever it is given.
  let go =
    compile(
      "proc main(): void {\n\tn := 7\n\tpanic \"n is \" + hive.conv.its(n)\n}\n",
    )
  should.be_true(string.contains(go, "panic(hive.Show("))
}

pub fn panic_tail_counts_as_terminating_test() {
  // A branch/tail ending in `panic` is a terminating path, so a value-returning
  // function needs no further `return`.
  compiler.compile(
    "func f(cond: Bool): Int {\n\tif cond {\n\t\treturn 1\n\t}\n\tpanic \"unreachable\"\n}\nproc main(): void {}\n",
  )
  |> should.be_ok
}

pub fn panic_tail_emits_no_unreachable_fallback_test() {
  let go =
    compile(
      "func f(cond: Bool): Int {\n\tif cond {\n\t\treturn 1\n\t}\n\tpanic \"boom\"\n}\nproc main(): void {}\n",
    )
  // The body already terminates in a panic, so codegen adds no synthetic
  // `panic(\"hive: unreachable\")` after it.
  should.be_false(string.contains(go, "hive: unreachable"))
}

pub fn exhaustive_variant_match_needs_no_final_return_test() {
  // Covering every variant of the subject's type is exhaustive without an else.
  compiler.compile(
    "type T {\n\tA\n\tB\n}\nfunc f(x: T): Int {\n\tif x is T.A {\n\t\treturn 1\n\t} else if x is T.B {\n\t\treturn 2\n\t}\n}\nproc main(): void {}\n",
  )
  |> should.be_ok
}

pub fn non_exhaustive_variant_match_is_rejected_test() {
  compiler.compile(
    "type T {\n\tA\n\tB\n}\nfunc f(x: T): Int {\n\tif x is T.A {\n\t\treturn 1\n\t}\n}\nproc main(): void {}\n",
  )
  |> should.be_error
}

// ---------------------------------------------------------------------------
// Concurrency: `async` and the await-all
// ---------------------------------------------------------------------------

// Wraps a `main` body with two ordinary funcs to exercise the call-site forms.
fn async_prog(body: String) -> String {
  "func slowShout(text: Str): Str {\n\treturn text + \"!!!\"\n}\n"
  <> "func lengthOf(text: Str): Int {\n\treturn len(text)\n}\n"
  <> "proc main(): void {\n"
  <> body
  <> "}\n"
}

pub fn async_statement_is_fire_and_forget_test() {
  let go = compile(async_prog("\tasync slowShout(\"hi\")\n"))
  // `async` runs the call on a goroutine and keeps nothing — no handle, no
  // channel.
  should.be_true(string.contains(go, "go slowShout(\"hi\")"))
  should.be_false(string.contains(go, "hive.Spawn"))
}

pub fn a_plain_call_waits_without_scheduling_anything_test() {
  let go = compile(async_prog("\techo slowShout(\"hi\")\n"))
  // Waiting for one call is just calling it: neither goroutine nor channel.
  should.be_true(string.contains(go, "fmt.Println(slowShout(\"hi\"))"))
  should.be_false(string.contains(go, "hive.Spawn"))
  should.be_false(string.contains(go, ".Await()"))
}

pub fn await_all_spawns_each_call_and_joins_them_test() {
  let go =
    compile(async_prog(
      "\tStr[2] r = await [slowShout(\"a\"), slowShout(\"b\")]\n\techo r[0]\n",
    ))
  // Every call is started, then one barrier resolves them in order into a
  // statically-typed vector.
  should.be_true(string.contains(go, "hive.AwaitAll([]*hive.Async[string]{"))
  should.be_true(string.contains(
    go,
    "hive.Spawn(func() string { return slowShout(\"a\") })",
  ))
  should.be_true(string.contains(go, "var r []string ="))
}

pub fn await_all_of_one_is_still_a_barrier_test() {
  let go = compile(async_prog("\techo len(await [slowShout(\"a\")])\n"))
  should.be_true(string.contains(go, "hive.AwaitAll([]*hive.Async[string]{"))
}

pub fn await_all_length_is_how_many_calls_were_written_test() {
  // Three calls make a `Str[3]`, so index 2 is in range and index 3 is not.
  compiler.compile(async_prog(
    "\tr := await [slowShout(\"a\"), slowShout(\"b\"), slowShout(\"c\")]\n\techo r[2]\n",
  ))
  |> should.be_ok
  compiler.compile(async_prog(
    "\tr := await [slowShout(\"a\"), slowShout(\"b\"), slowShout(\"c\")]\n\techo r[3]\n",
  ))
  |> should.be_error
}

pub fn await_all_over_void_calls_waits_for_them_all_test() {
  let go =
    compile(
      "proc log(text: Str): void {\n\techo text\n}\nproc main(): void {\n\tawait [log(\"a\"), log(\"b\")]\n}\n",
    )
  // Nothing to carry, so the task carries `hive.Unit` and the barrier's value is
  // discarded.
  should.be_true(string.contains(go, "hive.AwaitAll([]*hive.Async[hive.Unit]{"))
  should.be_true(string.contains(
    go,
    "hive.Spawn(func() hive.Unit { log(\"a\"); return hive.Unit{} })",
  ))
}

pub fn await_all_needs_calls_test() {
  // A value already in hand has nothing to wait for.
  let assert Error(msg) =
    compiler.compile(async_prog("\tx := \"a\"\n\techo len(await [x])\n"))
  should.be_true(string.contains(msg, "every entry has to be a call"))
}

pub fn await_all_needs_one_type_test() {
  // One barrier resolves to one vector, and a vector holds one type.
  let assert Error(msg) =
    compiler.compile(async_prog(
      "\tr := await [slowShout(\"a\"), lengthOf(\"b\")]\n\techo len(r)\n",
    ))
  should.be_true(string.contains(msg, "has to answer with the same type"))
  should.be_true(string.contains(msg, "Str and Int"))
}

pub fn await_all_is_not_empty_test() {
  let assert Error(msg) =
    compiler.compile(async_prog("\techo len(await [])\n"))
  should.be_true(string.contains(msg, "waits for nothing at all"))
}

pub fn a_single_call_needs_no_await_test() {
  let assert Error(msg) =
    compiler.compile(async_prog("\techo await slowShout(\"a\")\n"))
  should.be_true(string.contains(msg, "takes a list of calls"))
}

// Differently-typed work is waited for one call at a time, and each of those is
// an ordinary blocking call — nothing left to name, nothing left to leak.
pub fn differently_typed_calls_are_waited_for_in_sequence_test() {
  let go =
    compile(async_prog(
      "\tStr s = slowShout(\"y\")\n\tInt n = lengthOf(\"x\")\n\techo s\n\techo n\n",
    ))
  should.be_true(string.contains(go, "var s string = slowShout(\"y\")"))
  should.be_true(string.contains(go, "var n int = lengthOf(\"x\")"))
  should.be_false(string.contains(go, "hive.Spawn"))
}

// Every concurrent form together, to keep the surface honest about what compiles.
pub fn every_concurrent_form_still_compiles_test() {
  compiler.compile(async_prog(
    "\tasync slowShout(\"a\")\n"
    <> "\techo slowShout(\"b\")\n"
    <> "\techo len(await [slowShout(\"d\"), slowShout(\"e\")])\n"
    <> "\tif slowShout(\"f\") with timeout 1000 is Result.Ok(v) {\n\t\techo v\n\t}\n"
    <> "\tif await [slowShout(\"g\")] with timeout 1000 is Result.Ok(all) {\n\t\techo len(all)\n\t}\n",
  ))
  |> should.be_ok
}

// ---------------------------------------------------------------------------
// hive.term
// ---------------------------------------------------------------------------

pub fn term_print_lowers_to_println_test() {
  let go =
    compile("proc main(): void {\n\thive.term.print(\"hi\")\n}\n")
  should.be_true(string.contains(go, "fmt.Println(\"hi\")"))
}

pub fn term_read_lowers_to_runtime_test() {
  let go =
    compile("proc main(): void {\n\tline := hive.term.read()\n\techo line\n}\n")
  should.be_true(string.contains(go, "line := hive.TermRead()"))
}

// `hive run` decides whether to relay its own standard input to the program by
// looking for this call in the generated Go, and hands the input over in the
// file it names in HIVE_RUN_STDIN_FILE (see `hive/spawn` and hive_spawn_ffi).
// Spell either of the two halves differently and a program's reads go back to
// returning "" without ever waiting, which is what these pin down.
pub fn term_read_is_what_hive_run_relays_input_for_test() {
  let go =
    compile("proc main(): void {\n\tline := hive.term.read()\n\techo line\n}\n")
  should.be_true(string.contains(go, "hive.TermRead("))
  should.be_true(string.contains(
    runtime.term_go(),
    "os.Getenv(\"HIVE_RUN_STDIN_FILE\")",
  ))
}

pub fn term_read_secret_lowers_to_runtime_test() {
  let go =
    compile("proc main(): void {\n\tpw := hive.term.readSecret()\n\techo pw\n}\n")
  should.be_true(string.contains(go, "pw := hive.TermReadSecret()"))
}

pub fn term_read_secret_is_a_string_test() {
  compiler.compile(
    "proc main(): void {\n\tStr pw = hive.term.readSecret()\n\techo pw\n}\n",
  )
  |> should.be_ok
}

// A program whose only read is a hidden one still needs `hive run` to relay the
// input to it: `hive.TermReadSecret` reads through the same `TermRead`, and
// nothing reaches that without the relay. `hive/cli` looks for both spellings —
// the second is not a `hive.TermRead(` — and this is the half of that contract
// living in the generated Go.
pub fn term_read_secret_is_what_hive_run_relays_input_for_test() {
  let go =
    compile("proc main(): void {\n\tpw := hive.term.readSecret()\n\techo pw\n}\n")
  should.be_true(string.contains(go, "hive.TermReadSecret("))
  should.be_false(string.contains(go, "hive.TermRead()"))
  should.be_true(string.contains(runtime.term_secret_go(), "TermRead()"))
}

// The echo is turned off per platform, and neither half of that is named in a
// generated `main.go` — so they come along with the module that calls them
// rather than on a marker of their own. Both are written; the build tag at the
// top of each is what leaves one of them out of the build.
pub fn hidden_read_pulls_in_both_halves_of_turning_the_echo_off_test() {
  let hidden =
    used_modules(
      "proc main(): void {\n\tpw := hive.term.readSecret()\n\techo pw\n}\n",
    )
  should.be_true(list.contains(hidden, "term"))
  should.be_true(list.contains(hidden, "term_secret"))
  should.be_true(list.contains(hidden, "term_secret_unix"))
  should.be_true(list.contains(hidden, "term_secret_windows"))
  should.be_true(string.contains(
    runtime.term_secret_unix_go(),
    "//go:build !windows",
  ))
  should.be_true(string.contains(
    runtime.term_secret_windows_go(),
    "//go:build windows",
  ))
}

// A program that only reads visibly is not built with any of it — the terminal
// handling, and the process spawning it does on unix, are what a hidden read
// costs and nothing else should pay it.
pub fn visible_read_leaves_out_the_hiding_test() {
  should.equal(
    used_modules("proc main(): void {\n\tline := hive.term.read()\n\techo line\n}\n"),
    ["term"],
  )
}

pub fn term_read_secret_wrong_arity_is_rejected_test() {
  compiler.compile("proc main(): void {\n\techo hive.term.readSecret(\"pw\")\n}\n")
  |> should.be_error
}

pub fn term_args_is_a_string_vector_test() {
  let go =
    compile(
      "proc main(): void {\n\tas := hive.term.args()\n\techo len(as)\n}\n",
    )
  should.be_true(string.contains(go, "as := hive.TermArgs()"))
}

pub fn term_unknown_member_is_rejected_test() {
  compiler.compile("proc main(): void {\n\thive.term.beep()\n}\n")
  |> should.be_error
}

pub fn term_print_wrong_arity_is_rejected_test() {
  compiler.compile("proc main(): void {\n\thive.term.print(\"a\", \"b\")\n}\n")
  |> should.be_error
}

// ---------------------------------------------------------------------------
// hive.task
// ---------------------------------------------------------------------------

pub fn task_sleep_lowers_to_runtime_test() {
  let go = compile("proc main(): void {\n\thive.task.sleep(250)\n}\n")
  should.be_true(string.contains(go, "hive.Sleep(250)"))
}

pub fn task_unknown_member_is_rejected_test() {
  compiler.compile("proc main(): void {\n\thive.task.nap(5)\n}\n")
  |> should.be_error
}

pub fn task_sleep_wrong_arity_is_rejected_test() {
  compiler.compile("proc main(): void {\n\thive.task.sleep()\n}\n")
  |> should.be_error
}

// ---------------------------------------------------------------------------
// hive.time
// ---------------------------------------------------------------------------

pub fn time_now_lowers_to_runtime_test() {
  let go = compile("proc main(): void {\n\techo hive.time.now()\n}\n")
  should.be_true(string.contains(go, "hive.Now()"))
}

pub fn time_zone_helpers_lower_to_runtime_test() {
  let go =
    compile(
      "proc main(): void {\n\techo hive.time.timezone()\n\techo hive.time.timezoneOffset()\n}\n",
    )
  should.be_true(string.contains(go, "hive.Timezone()"))
  should.be_true(string.contains(go, "hive.TimezoneOffset()"))
}

pub fn time_format_lowers_to_runtime_test() {
  let go =
    compile(
      "proc main(): void {\n\techo hive.time.format(hive.time.now(), \"%Y-%m-%d\")\n}\n",
    )
  should.be_true(string.contains(go, "hive.TimeFormat(hive.Now(), \"%Y-%m-%d\")"))
}

pub fn bare_now_is_rejected_with_migration_hint_test() {
  compiler.compile("proc main(): void {\n\techo now()\n}\n")
  |> should.be_error
}

pub fn user_defined_now_still_works_test() {
  compiler.compile(
    "func now(): Int {\n\treturn 42\n}\nproc main(): void {\n\techo now()\n}\n",
  )
  |> should.be_ok
}

pub fn time_unknown_member_is_rejected_test() {
  compiler.compile("proc main(): void {\n\techo hive.time.epoch()\n}\n")
  |> should.be_error
}

pub fn time_format_wrong_arity_is_rejected_test() {
  compiler.compile("proc main(): void {\n\techo hive.time.format(0)\n}\n")
  |> should.be_error
}

fn count_occurrences(haystack: String, needle: String) -> Int {
  string.split(haystack, needle) |> length_minus_one
}

fn length_minus_one(parts: List(a)) -> Int {
  case parts {
    [] -> 0
    [_, ..rest] -> list_length(rest)
  }
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

// ---------------------------------------------------------------------------
// A `Str` has no subscript
// ---------------------------------------------------------------------------

pub fn indexing_a_str_is_rejected_test() {
  // Go would index the bytes, while `len` counts characters — so the guard and
  // the access would be in different units, and a byte out of the middle of a
  // character is not text.
  let assert Error(msg) =
    compiler.compile(
      "proc main(): void {\n\ts := \"caf\"\n\tn := len(s)\n\tif 0 < n {\n\t\techo s[0]\n\t}\n}\n",
    )
  should.be_true(string.contains(msg, "cannot be indexed"))
}

pub fn slicing_a_str_is_rejected_test() {
  let assert Error(msg) =
    compiler.compile(
      "proc main(): void {\n\ts := \"cafe\"\n\tn := len(s)\n\tif 2 < n {\n\t\techo s[0:2]\n\t}\n}\n",
    )
  should.be_true(string.contains(msg, "cannot be sliced"))
}

pub fn indexing_a_vector_is_still_fine_test() {
  let go =
    compile("proc main(): void {\n\tv := [\"a\", \"b\"]\n\techo v[1]\n}\n")
  should.be_true(string.contains(go, "v[1]"))
}

// ---------------------------------------------------------------------------
// Negative literals
// ---------------------------------------------------------------------------

pub fn negative_literals_parse_test() {
  // `-` binds tighter than `* / %` and looser than `**`.
  let go =
    compile(
      "proc main(): void {\n\techo 2 ** -3\n\techo -7 % 3\n\techo -2 ** 2\n\tx := -5\n\techo x\n}\n",
    )
  should.be_true(string.contains(go, "hive.PowInt(2, -3)"))
  should.be_true(string.contains(go, "hive.ModInt(-7, 3)"))
  // -2 ** 2 is -(2 ** 2), so the negation wraps the power.
  should.be_true(string.contains(go, "(0 - hive.PowInt(2, 2))"))
  should.be_true(string.contains(go, "x := -5"))
}

pub fn a_negative_literal_index_is_rejected_test() {
  // Nothing can bring it into range, so it needs no guard to be refused.
  let assert Error(msg) =
    compiler.compile(
      "proc main(): void {\n\tv := [\"a\", \"b\"]\n\techo v[-1]\n}\n",
    )
  should.be_true(string.contains(msg, "negative"))
}

pub fn a_negative_loop_counter_is_not_assumed_nonneg_test() {
  let assert Error(msg) =
    compiler.compile(
      "proc main(): void {\n\tStr[dyn] v = [\"a\"]\n\tfor i := -3; i < len(v); i = i + 1 {\n\t\techo v[i]\n\t}\n}\n",
    )
  should.be_true(string.contains(msg, ">= 0"))
}

// ---------------------------------------------------------------------------
// `T[]` is a signature spelling: parameters and returns, never storage
// ---------------------------------------------------------------------------

pub fn unsized_vector_is_accepted_as_a_parameter_test() {
  // It promises nothing, so it takes a static vector and a dynamic one alike.
  let go =
    compile(
      "func first(v: Str[]): Str {\n\tif len(v) > 0 {\n\t\treturn v[0]\n\t}\n\treturn \"\"\n}\nproc main(): void {\n\tStr[2] a = [\"a\", \"b\"]\n\tStr[dyn] b = [\"c\"]\n\techo first(a)\n\techo first(b)\n}\n",
    )
  should.be_true(string.contains(go, "func first(v []string) string {"))
}

pub fn unsized_vector_is_rejected_as_a_variable_test() {
  let assert Error(msg) =
    compiler.compile(
      "proc main(): void {\n\tStr[] v = [\"a\"]\n\techo len(v)\n}\n",
    )
  should.be_true(string.contains(msg, "`[]` only says"))
}

pub fn unsized_vector_is_rejected_as_a_return_test() {
  // A return is where the caller is told what it is getting, and `[]`, `[dyn]`
  // and `[3]` are three different answers to them. `[]` and `[dyn]` happen to
  // be the *same* answer, which is the reason to have only one spelling of it:
  // two invite the reader to hunt for a difference that isn't there.
  let assert Error(msg) =
    compiler.compile(
      "func f(): Str[] {\n\treturn [\"a\"]\n}\nproc main(): void {\n\techo len(f())\n}\n",
    )
  should.be_true(string.contains(msg, "the return type of `f` is declared `Str[]`"))
  should.be_true(string.contains(msg, "a return is where the caller is told"))
  should.be_true(string.contains(msg, "`[]` stays available on a parameter"))
}

pub fn a_dynamic_return_is_what_an_unsized_one_meant_test() {
  // `[dyn]` is the spelling that survives, and it promises exactly what `[]`
  // used to: nothing. A static slot cannot be filled from one, and an index
  // into the result needs a guard.
  compile("func f(): Str[dyn] {\n\treturn [\"a\"]\n}\nproc main(): void {\n\techo len(f())\n}\n")
  |> string.contains("func f() []string {")
  |> should.be_true

  let assert Error(static_slot) =
    compiler.compile(
      "func f(): Str[dyn] {\n\treturn [\"a\", \"b\"]\n}\nproc main(): void {\n\tStr[2] v = f()\n\techo v[0]\n}\n",
    )
  should.be_true(string.contains(static_slot, "isn't known at compile time"))

  let assert Error(unguarded) =
    compiler.compile(
      "func f(): Str[dyn] {\n\treturn [\"a\"]\n}\nproc main(): void {\n\tv := f()\n\techo v[0]\n}\n",
    )
  should.be_true(string.contains(unguarded, "cannot prove"))
}

pub fn an_unsized_return_is_rejected_inside_a_function_type_test() {
  // A function type's return is a return position like any other, wherever the
  // type itself appears — including in a parameter, where `[]` is fine for the
  // parameter's own vectors but not for what the function it holds gives back.
  let assert Error(msg) =
    compiler.compile(
      "func pieces(s: Str): Str[dyn] {\n\treturn split(s, \",\")\n}\nfunc count(f: func(Str): Str[], s: Str): Int {\n\treturn len(f(s))\n}\nproc main(): void {\n\techo count(pieces, \"a,b\")\n}\n",
    )
  should.be_true(string.contains(msg, "the return type in parameter `f` of `count`"))

  // Spelled `[dyn]`, the same program is fine — and `[]` still serves the
  // parameter that takes the vector.
  compiler.compile(
    "func pieces(s: Str): Str[dyn] {\n\treturn split(s, \",\")\n}\nfunc count(f: func(Str): Str[dyn], s: Str): Int {\n\treturn len(f(s))\n}\nfunc total(v: Str[]): Int {\n\treturn len(v)\n}\nproc main(): void {\n\techo count(pieces, \"a,b\")\n\techo total([\"a\"])\n}\n",
  )
  |> should.be_ok
}

pub fn unsized_vector_is_rejected_as_a_field_test() {
  let assert Error(msg) =
    compiler.compile(
      "type Box {\n\titems: Str[]\n}\nproc main(): void {\n\tb := Box([\"a\"])\n\techo len(b.items)\n}\n",
    )
  should.be_true(string.contains(msg, "`[]` only says"))
}

// ---------------------------------------------------------------------------
// A vector inside a struct is a vector like any other
// ---------------------------------------------------------------------------

pub fn replacing_a_field_drops_what_was_proven_about_it_test() {
  // The guard proved a length for the *old* vector; assigning a new one to the
  // field says nothing about it, exactly as rebinding a variable would.
  let assert Error(msg) =
    compiler.compile(
      "type Box {\n\titems: Str[dyn]\n}\nproc main(): void {\n\tmut b := Box([\"a\", \"b\", \"c\"])\n\ti := 2\n\tif i >= 0 && i < len(b.items) {\n\t\tb.items = [\"one\"]\n\t\techo b.items[i]\n\t}\n}\n",
    )
  should.be_true(string.contains(msg, "cannot prove"))
}

pub fn replacing_a_field_drops_an_index_of_proof_test() {
  let assert Error(msg) =
    compiler.compile(
      "type Box {\n\titems: Str[dyn]\n}\nproc main(): void {\n\tmut b := Box([\"a\", \"b\", \"c\"])\n\tr := indexOf(b.items, \"c\")\n\tif r is Result.Ok(i) {\n\t\tb.items = [\"one\"]\n\t\techo b.items[i]\n\t}\n}\n",
    )
  should.be_true(string.contains(msg, "cannot prove"))
}

pub fn a_guarded_field_index_is_still_accepted_test() {
  compiler.compile(
    "type Box {\n\titems: Str[dyn]\n}\nproc main(): void {\n\tb := Box([\"a\", \"b\", \"c\"])\n\ti := 2\n\tif i >= 0 && i < len(b.items) {\n\t\techo b.items[i]\n\t}\n}\n",
  )
  |> should.be_ok
}

pub fn a_static_field_length_is_enforced_at_construction_test() {
  // A `Str[3]` field can be indexed unguarded, so every construction has to be
  // held to it — otherwise the trust rests on nothing.
  let assert Error(msg) =
    compiler.compile(
      "type Trio {\n\tthree: Str[3]\n}\nproc main(): void {\n\tt := Trio([\"x\", \"y\"])\n\techo t.three[2]\n}\n",
    )
  should.be_true(string.contains(msg, "exactly 3"))
}

pub fn a_static_field_can_be_indexed_unguarded_test() {
  compiler.compile(
    "type Trio {\n\tthree: Str[3]\n}\nproc main(): void {\n\tt := Trio([\"x\", \"y\", \"z\"])\n\techo t.three[2]\n}\n",
  )
  |> should.be_ok
}

// ---------------------------------------------------------------------------
// A length promise survives being held as a function value
// ---------------------------------------------------------------------------

pub fn a_call_through_a_bound_reference_is_held_to_its_lengths_test() {
  let assert Error(msg) =
    compiler.compile(
      "proc takes(v: Str[3]): void {\n\techo v[2]\n}\nproc main(): void {\n\tf := takes\n\tf([\"a\"])\n}\n",
    )
  should.be_true(string.contains(msg, "exactly 3"))
}

pub fn a_correct_call_through_a_bound_reference_is_accepted_test() {
  compiler.compile(
    "proc takes(v: Str[3]): void {\n\techo v[2]\n}\nproc main(): void {\n\tf := takes\n\tf([\"a\", \"b\", \"c\"])\n}\n",
  )
  |> should.be_ok
}

pub fn a_call_through_a_partial_application_is_held_to_its_lengths_test() {
  let assert Error(msg) =
    compiler.compile(
      "proc takes(v: Str[3], tag: Str): void {\n\techo tag\n\techo v[2]\n}\nproc main(): void {\n\tg := takes(_, \"t\")\n\tg([\"a\"])\n}\n",
    )
  should.be_true(string.contains(msg, "exactly 3"))
}

pub fn handing_on_a_static_length_taker_is_rejected_test() {
  // The eventual call would happen where the promise is not known.
  let assert Error(msg) =
    compiler.compile(
      "proc takes(v: Str[3]): void {\n\techo v[2]\n}\nproc apply(g: proc(Str[dyn]): void, arg: Str[dyn]): void {\n\tg(arg)\n}\nproc main(): void {\n\tmut Str[dyn] one = [\"a\"]\n\tapply(takes, one)\n}\n",
    )
  should.be_true(string.contains(msg, "cannot be used as a value here"))
}

pub fn a_mut_holder_of_a_static_length_taker_is_rejected_test() {
  // A reassignment could point the name at a different callable, leaving calls
  // already checked against the old one checking the wrong signature.
  let assert Error(msg) =
    compiler.compile(
      "proc takes(v: Str[3]): void {\n\techo v[2]\n}\nproc main(): void {\n\tmut f := takes\n\tf([\"a\", \"b\", \"c\"])\n}\n",
    )
  should.be_true(string.contains(msg, "cannot be `mut`"))
}

pub fn passing_a_dyn_taker_as_a_value_is_unaffected_test() {
  // Nothing was promised, so the value travels freely.
  compiler.compile(
    "proc takes(v: Str[dyn]): void {\n\techo len(v)\n}\nproc apply(g: proc(Str[dyn]): void, arg: Str[dyn]): void {\n\tg(arg)\n}\nproc main(): void {\n\tStr[dyn] one = [\"a\"]\n\tapply(takes, one)\n}\n",
  )
  |> should.be_ok
}

// ---------------------------------------------------------------------------
// An `is` subject runs exactly once, wherever it sits in the condition
// ---------------------------------------------------------------------------

pub fn a_non_leftmost_subject_runs_once_test() {
  // The subject is read to test it and again for every value it binds. Only the
  // leftmost test can use Go's single `if` init slot, so a later one gets a
  // nested `if` of its own rather than being emitted twice.
  let go =
    compile(
      "proc main(): void {\n\tok := true\n\tif ok && hive.file.append(\"p\", \"X\") is Result.Ok(n) {\n\t\techo n\n\t}\n}\n",
    )
  should.equal(
    string.split(go, "hive.FileAppend(\"p\", \"X\")") |> list.length,
    2,
  )
}

pub fn a_non_leftmost_subject_keeps_its_else_test() {
  // A nested chain falls out of the middle, so the `else` hangs off a flag.
  let go =
    compile(
      "proc main(): void {\n\tok := true\n\tif ok && hive.file.append(\"p\", \"X\") is Result.Ok(n) {\n\t\techo n\n\t} else {\n\t\techo \"no\"\n\t}\n}\n",
    )
  should.equal(
    string.split(go, "hive.FileAppend(\"p\", \"X\")") |> list.length,
    2,
  )
  should.be_true(string.contains(go, "fmt.Println(\"no\")"))
}

pub fn two_non_leftmost_subjects_each_run_once_test() {
  let go =
    compile(
      "proc main(): void {\n\tok := true\n\tif ok && hive.file.append(\"a\", \"X\") is Result.Ok(n) && hive.file.append(\"b\", \"Y\") is Result.Ok(m) {\n\t\techo n + m\n\t}\n}\n",
    )
  should.equal(string.split(go, "hive.FileAppend(\"a\"") |> list.length, 2)
  should.equal(string.split(go, "hive.FileAppend(\"b\"") |> list.length, 2)
}

pub fn a_leftmost_subject_still_uses_the_init_slot_test() {
  // The flat form is kept wherever it suffices.
  let go =
    compile(
      "proc main(): void {\n\tif hive.file.append(\"p\", \"X\") is Result.Ok(n) && n > 0 {\n\t\techo n\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "if _u1_0 := hive.FileAppend"))
}

// ---------------------------------------------------------------------------
// A mutex is copied into a callee
// ---------------------------------------------------------------------------

pub fn a_mut_argument_is_copied_in_test() {
  // The callee is handed an immutable `T`, which it would not be if the caller
  // could still write through the same backing array.
  let go =
    compile(
      "proc show(v: Str[dyn]): void {\n\techo len(v)\n}\nproc main(): void {\n\tmut v := [\"a\"]\n\tshow(v)\n\tv[0] = \"b\"\n}\n",
    )
  should.be_true(string.contains(go, "show(hive.CloneVec(v))"))
}

pub fn an_immutable_argument_is_not_copied_test() {
  let go =
    compile(
      "proc show(v: Str[dyn]): void {\n\techo len(v)\n}\nproc main(): void {\n\tv := [\"a\"]\n\tshow(v)\n}\n",
    )
  should.be_false(string.contains(go, "Clone"))
}

pub fn a_spawned_task_copies_before_it_starts_test() {
  // A copy made on the new goroutine would race with the caller it exists to
  // protect against, so the arguments are bound in the caller first.
  let go =
    compile(
      "func work(v: Str[dyn]): Int {\n\treturn len(v)\n}\nproc main(): void {\n\tmut v := [\"a\"]\n\tn := await [work(v)]\n\tv[0] = \"b\"\n\techo n[0]\n}\n",
    )
  should.be_true(string.contains(go, "_a0 := hive.CloneVec(v); return hive.Spawn("))
}

pub fn a_fire_and_forget_call_copies_in_the_caller_test() {
  // `go f(x)` evaluates its arguments in the calling goroutine already, so the
  // copy needs no thunk around it — and still happens before the task starts.
  let go =
    compile(
      "func work(v: Str[dyn]): Int {\n\treturn len(v)\n}\nproc main(): void {\n\tmut v := [\"a\"]\n\tasync work(v)\n\tv[0] = \"b\"\n\techo len(v)\n}\n",
    )
  should.be_true(string.contains(go, "go work(hive.CloneVec(v))"))
}

// ---------------------------------------------------------------------------
// A `mut` parameter: the caller's mutex itself
// ---------------------------------------------------------------------------

const grow = "proc grow(vec: mut Str[dyn], tag: Str): Int {
\tappend(vec, tag)
\treturn len(vec)
}
"

pub fn a_mutex_parameter_is_a_pointer_test() {
  // A vector's `append` returns a new slice header, so sharing the backing array
  // is not enough on its own — the callee has to be able to write the header the
  // caller reads.
  let go = compile(grow <> "proc main(): void {
\tmut Str[dyn] v = [\"a\"]
\techo grow(v, \"b\")
}
")
  should.be_true(string.contains(go, "func grow(vec *[]string, tag string) int"))
  should.be_true(string.contains(go, "(*vec) = append((*vec), tag)"))
}

pub fn a_waited_for_call_shares_the_callers_storage_test() {
  let go = compile(grow <> "proc main(): void {
\tmut Str[dyn] v = [\"a\"]
\techo grow(v, \"b\")
}
")
  should.be_true(string.contains(go, "grow(&v, \"b\")"))
  should.be_false(string.contains(go, "Clone"))
}

pub fn a_fired_off_call_gets_a_copy_test() {
  // `async` is the one place the two halves of `mut` come apart: what crosses to
  // another thread is a copy, and the callee is handed *its* address.
  let go = compile(grow <> "proc main(): void {
\tmut Str[dyn] v = [\"a\"]
\tasync grow(v, \"b\")
}
")
  should.be_true(string.contains(
    go,
    "{ _a0 := hive.CloneVec(v); go grow(&_a0, \"b\") }",
  ))
}

pub fn an_awaited_call_gets_a_copy_test() {
  let go = compile(grow <> "proc main(): void {
\tmut Str[dyn] v = [\"a\"]
\techo await [grow(v, \"b\")]
}
")
  should.be_true(string.contains(go, "_a0 := hive.CloneVec(v)"))
  should.be_true(string.contains(go, "grow(&_a0, \"b\")"))
}

pub fn a_mutex_passed_on_stays_the_same_pointer_test() {
  // `&(*vec)` is only `vec` spelled the long way.
  let go =
    compile(
      grow
      <> "proc outer(vec: mut Str[dyn]): void {\n\techo grow(vec, \"x\")\n}\nproc main(): void {\n\tmut Str[dyn] v = [\"a\"]\n\touter(v)\n}\n",
    )
  should.be_true(string.contains(go, "grow(vec, \"x\")"))
  should.be_true(string.contains(go, "outer(&v)"))
}

pub fn a_mutex_call_inside_a_spawned_argument_runs_in_the_caller_test() {
  // Left in the closure, `grow` would write the caller's storage from the new
  // thread while the caller carries on reading it.
  let go =
    compile(
      grow
      <> "func twice(n: Int): Int {\n\treturn n * 2\n}\nproc main(): void {\n\tmut Str[dyn] v = [\"a\"]\n\techo await [twice(grow(v, \"b\"))]\n}\n",
    )
  should.be_true(string.contains(go, "_a0 := grow(&v, \"b\")"))
  should.be_true(string.contains(go, "return twice(_a0)"))
}

pub fn a_mutex_parameter_may_be_reassigned_test() {
  let go =
    compile(
      "proc replace(vec: mut Str[dyn]): void {\n\tvec = [\"only\"]\n}\nproc main(): void {\n\tmut Str[dyn] v = [\"a\"]\n\treplace(v)\n\techo v\n}\n",
    )
  should.be_true(string.contains(go, "(*vec) = []string{\"only\"}"))
}

pub fn a_scalar_mutex_parameter_works_too_test() {
  let go =
    compile(
      "proc bump(n: mut Int): void {\n\tn = n + 1\n}\nproc main(): void {\n\tmut n := 1\n\tbump(n)\n\techo n\n}\n",
    )
  should.be_true(string.contains(go, "func bump(n *int)"))
  should.be_true(string.contains(go, "(*n) = ((*n) + 1)"))
  should.be_true(string.contains(go, "bump(&n)"))
}

pub fn a_struct_mutex_parameter_writes_the_callers_field_test() {
  let go =
    compile(
      "type Box {\n\tcount: Int\n}\nproc fill(b: mut Box): void {\n\tb.count = 7\n}\nproc main(): void {\n\tmut Box b = Box(1)\n\tfill(b)\n\techo b.count\n}\n",
    )
  should.be_true(string.contains(go, "func fill(b *Box)"))
  should.be_true(string.contains(go, "(*b).Count = 7"))
  should.be_true(string.contains(go, "fill(&b)"))
}

pub fn a_binding_off_a_mutex_parameter_shares_it_test() {
  // Two `mut` ends share, exactly as they do for two locals.
  let go =
    compile(
      "proc grow(vec: mut Str[dyn]): void {\n\tmut Str[dyn] also = vec\n\tappend(also, \"x\")\n}\nproc main(): void {\n\tmut Str[dyn] v = [\"a\"]\n\tgrow(v)\n\techo v\n}\n",
    )
  should.be_true(string.contains(go, "(*vec) = append((*vec), \"x\")"))
  should.be_false(string.contains(go, "Clone"))
}

pub fn a_mutex_parameter_passed_to_a_value_slot_is_copied_test() {
  // Going the other way is the ordinary rule: a `T` slot never sees a mutex.
  let go =
    compile(
      "func size(v: Str[dyn]): Int {\n\treturn len(v)\n}\nproc grow(vec: mut Str[dyn]): void {\n\techo size(vec)\n}\nproc main(): void {\n\tmut Str[dyn] v = [\"a\"]\n\tgrow(v)\n}\n",
    )
  should.be_true(string.contains(go, "size(hive.CloneVec((*vec)))"))
}

pub fn mut_is_not_part_of_a_type_test() {
  // A field, a return and a function type each bind nothing.
  should.be_error(compiler.compile(
    "type Box {\n\titems: mut Str[dyn]\n}\nproc main(): void {\n\techo 1\n}\n",
  ))
  should.be_error(compiler.compile(
    "proc f(): mut Str[dyn] {\n\treturn [\"a\"]\n}\nproc main(): void {\n\techo f()\n}\n",
  ))
  should.be_error(compiler.compile(
    "proc run(f: proc(mut Int): void): void {\n\techo 1\n}\nproc main(): void {\n\techo 1\n}\n",
  ))
}

pub fn a_func_cannot_receive_a_mutex_test() {
  let assert Error(msg) =
    compiler.compile(
      "func f(vec: mut Str[dyn]): Int {\n\treturn len(vec)\n}\nproc main(): void {\n\tmut Str[dyn] v = [\"a\"]\n\techo f(v)\n}\n",
    )
  should.be_true(string.contains(msg, "cannot receive a mutex"))
}

pub fn a_query_cannot_receive_a_mutex_test() {
  should.be_error(compiler.compile(
    "query rows(v: mut Str[dyn]): Str[dyn] {\n\tSELECT name FROM t\n}\nproc main(): void {\n\techo 1\n}\n",
  ))
}

pub fn a_mutex_slot_refuses_a_value_test() {
  let assert Error(msg) =
    compiler.compile(
      grow <> "proc main(): void {\n\techo grow([\"a\"], \"b\")\n}\n",
    )
  should.be_true(string.contains(msg, "takes the caller's own storage"))
}

pub fn a_mutex_slot_refuses_an_immutable_binding_test() {
  let assert Error(msg) =
    compiler.compile(
      grow
      <> "proc main(): void {\n\tStr[dyn] v = [\"a\"]\n\techo grow(v, \"b\")\n}\n",
    )
  should.be_true(string.contains(msg, "is immutable"))
}

pub fn a_mutex_slot_accepts_a_path_into_mut_storage_test() {
  let go =
    compile(
      "type Box {\n\titems: Str[dyn]\n}\nproc grow(vec: mut Str[dyn]): void {\n\tappend(vec, \"x\")\n}\nproc main(): void {\n\tmut Box b = Box([\"a\"])\n\tgrow(b.items)\n\techo b.items\n}\n",
    )
  should.be_true(string.contains(go, "grow(&b.Items)"))
}

pub fn a_mutex_callable_cannot_become_a_value_test() {
  let assert Error(partial) =
    compiler.compile(
      grow
      <> "proc main(): void {\n\tmut Str[dyn] v = [\"a\"]\n\tg := grow(v, _)\n\techo g(\"x\")\n}\n",
    )
  should.be_true(string.contains(partial, "cannot be a value"))
  let assert Error(reference) =
    compiler.compile(
      grow
      <> "func apply(f: proc(Str): Int): Int {\n\treturn 0\n}\nproc main(): void {\n\techo apply(grow)\n}\n",
    )
  should.be_true(string.contains(reference, "cannot be a value"))
}

pub fn a_mutex_proc_cannot_serve_http_test() {
  let assert Error(msg) =
    compiler.compile(
      "proc handle(r: mut hive.net.HttpRequest): hive.net.HttpResponse {\n\treturn hive.net.HttpResponse(200, [], \"ok\")\n}\nproc main(): void {\n\thive.net.httpServe(8080, handle)\n}\n",
    )
  should.be_true(string.contains(msg, "is a mutex"))
}

pub fn a_mutex_call_forgets_what_was_proven_test() {
  // The callee can rebind the caller's vector to a shorter one, so a length read
  // off a literal cannot survive the call.
  should.be_true(
    compiler.compile(
      "proc main(): void {\n\tmut v := [\"a\", \"b\"]\n\techo v[1]\n}\n",
    )
    |> result.is_ok,
  )
  should.be_error(compiler.compile(
    "proc replace(vec: mut Str[dyn]): void {\n\tvec = [\"only\"]\n}\nproc main(): void {\n\tmut v := [\"a\", \"b\"]\n\treplace(v)\n\techo v[1]\n}\n",
  ))
}

pub fn a_mut_argument_to_a_constructor_is_copied_in_test() {
  // A constructed value keeps the vector for as long as it lives.
  let go =
    compile(
      "type Box {\n\titems: Str[dyn]\n}\nproc main(): void {\n\tmut v := [\"a\"]\n\tb := Box(v)\n\tv[0] = \"b\"\n\techo len(b.items)\n}\n",
    )
  should.be_true(string.contains(go, "Items: hive.CloneVec(v)"))
}

// ---------------------------------------------------------------------------
// Generics
// ---------------------------------------------------------------------------

pub fn a_generic_func_is_monomorphized_per_call_test() {
  // One copy per distinct set of type arguments, chosen by the argument types.
  let go =
    compile(
      "func first(v: T[], f: T): T {\n\tif len(v) > 0 {\n\t\treturn v[0]\n\t}\n\treturn f\n}\nproc main(): void {\n\tStr[dyn] a = [\"x\"]\n\tInt[dyn] b = [1]\n\techo first(a, \"z\")\n\techo first(b, 0)\n}\n",
    )
  should.be_true(string.contains(go, "func first_Str(v []string, f string) string {"))
  should.be_true(string.contains(go, "func first_Int(v []int, f int) int {"))
  should.be_true(string.contains(go, "first_Str(a, \"z\")"))
  should.be_true(string.contains(go, "first_Int(b, 0)"))
  // The generic original is not emitted.
  should.be_false(string.contains(go, "func first(v"))
}

pub fn a_generic_reused_at_one_type_is_emitted_once_test() {
  let go =
    compile(
      "func id(v: T): T {\n\treturn v\n}\nproc main(): void {\n\techo id(\"a\")\n\techo id(\"b\")\n}\n",
    )
  should.equal(string.split(go, "func id_Str(") |> list.length, 2)
}

pub fn generics_take_two_variables_independently_test() {
  let go =
    compile(
      "func pair(a: A, b: B): Str {\n\treturn \"{a}{b}\"\n}\nproc main(): void {\n\techo pair(1, \"x\")\n\techo pair(1, 2)\n}\n",
    )
  should.be_true(string.contains(go, "func pair_Int_Str("))
  should.be_true(string.contains(go, "func pair_Int_Int("))
}

pub fn a_nested_generic_call_resolves_test() {
  // `outer(inner(v))` cannot be resolved until `inner`'s instantiation exists,
  // so the expansion runs to a fixpoint rather than failing on the first pass.
  let go =
    compile(
      "func id(v: T): T {\n\treturn v\n}\nfunc twice(v: T): T {\n\treturn id(id(v))\n}\nproc main(): void {\n\techo twice(\"a\")\n}\n",
    )
  should.be_true(string.contains(go, "func twice_Str("))
  should.be_true(string.contains(go, "func id_Str("))
}

pub fn an_instantiation_keeps_its_own_length_promise_test() {
  // At Str[3] the length is a promise, so the index is decided outright.
  compiler.compile(
    "func third(v: T[3]): T {\n\treturn v[2]\n}\nproc main(): void {\n\tStr[3] a = [\"x\", \"y\", \"z\"]\n\techo third(a)\n}\n",
  )
  |> should.be_ok
}

pub fn an_instantiation_is_held_to_its_length_promise_test() {
  // A dynamic vector has no length the compiler can see, so it cannot fill a
  // slot that promises three.
  let assert Error(unknown) =
    compiler.compile(
      "func third(v: T[3]): T {\n\treturn v[2]\n}\nproc main(): void {\n\tStr[dyn] a = [\"x\"]\n\techo third(a)\n}\n",
    )
  should.be_true(string.contains(unknown, "isn't known at compile time"))

  // A literal of the wrong length is counted outright.
  let assert Error(wrong) =
    compiler.compile(
      "func third(v: T[3]): T {\n\treturn v[2]\n}\nproc main(): void {\n\techo third([\"x\", \"y\"])\n}\n",
    )
  should.be_true(string.contains(wrong, "exactly 3"))
}

pub fn a_generic_cannot_be_used_as_a_value_test() {
  let assert Error(msg) =
    compiler.compile(
      "func id(v: T): T {\n\treturn v\n}\nproc apply(g: func(Str): Str): Str {\n\treturn g(\"a\")\n}\nproc main(): void {\n\techo apply(id)\n}\n",
    )
  should.be_true(string.contains(msg, "cannot be used as a value"))
}

pub fn a_variable_only_in_the_return_is_rejected_test() {
  let assert Error(msg) =
    compiler.compile(
      "func make(n: Int): T {\n\treturn n\n}\nproc main(): void {\n\techo make(1)\n}\n",
    )
  should.be_true(string.contains(msg, "no argument pins it down"))
}

pub fn a_runaway_instantiation_is_a_compile_error_test() {
  // A generic that instantiates itself at an ever-larger type would never
  // settle; the cap turns that into a diagnostic rather than a hung build.
  let assert Error(msg) =
    compiler.compile(
      "func grow(v: T[]): Int {\n\tinner := [v]\n\treturn len(grow(inner))\n}\nproc main(): void {\n\tStr[dyn] xs = [\"a\"]\n\techo grow(xs)\n}\n",
    )
  should.be_true(
    string.contains(msg, "did not settle") || string.contains(msg, "more than"),
  )
}

pub fn result_is_a_writable_type_test() {
  // `Result<T, E>` had no surface syntax before type arguments existed.
  let go =
    compile(
      "func first(v: T[]): Result<T, Bool> {\n\tif len(v) > 0 {\n\t\treturn Result.Ok(v[0])\n\t}\n\treturn Result.Error(false)\n}\nproc main(): void {\n\tStr[dyn] a = [\"x\"]\n\tif first(a) is Result.Ok(v) {\n\t\techo v\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.Result[string, bool]"))
  should.be_true(string.contains(go, "hive.Ok[string, bool]"))
  should.be_true(string.contains(go, "hive.Err[string, bool]"))
}

pub fn a_generic_type_is_monomorphized_per_use_test() {
  let go =
    compile(
      "type Box {\n\titems: T[dyn]\n}\nproc main(): void {\n\tBox<Str> a = Box([\"x\"])\n\tBox<Int> b = Box([1])\n\techo len(a.items) + len(b.items)\n}\n",
    )
  should.be_true(string.contains(go, "type Box_Str struct {"))
  should.be_true(string.contains(go, "type Box_Int struct {"))
  should.be_true(string.contains(go, "Items []string"))
  should.be_true(string.contains(go, "Items []int"))
}

pub fn a_generic_union_narrows_through_its_instantiation_test() {
  let go =
    compile(
      "type Either {\n\tLeft { left: A }\n\tRight { right: B }\n}\nproc main(): void {\n\tEither<Str, Int> e = Either.Left(\"a\")\n\tif e is Either.Left(v) {\n\t\techo v\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "Either_Str_IntLeft"))
}

pub fn a_generic_type_needs_its_arguments_test() {
  let assert Error(msg) =
    compiler.compile(
      "type Box {\n\titems: T[dyn]\n}\nproc main(): void {\n\tBox b = Box([\"x\"])\n\techo len(b.items)\n}\n",
    )
  should.be_true(string.contains(msg, "needs its type arguments"))
}

pub fn a_generic_body_substitutes_the_types_it_writes_test() {
  // A body writes types down of its own, and they name the same variables the
  // signature does. Leaving them alone would emit `var kept []T`.
  let go =
    compile(
      "func repack(values: T[]): T[dyn] {\n\tmut T[dyn] kept = []\n\tfor each value: T in values {\n\t\tappend(kept, value)\n\t}\n\treturn kept\n}\nproc main(): void {\n\tStr[dyn] a = [\"x\"]\n\tInt[dyn] b = [1]\n\techo len(repack(a)) + len(repack(b))\n}\n",
    )
  should.be_true(string.contains(go, "var kept []string = []string{}"))
  should.be_true(string.contains(go, "var kept []int = []int{}"))
  should.be_false(string.contains(go, "[]T"))
}

pub fn a_generic_body_instantiates_a_generic_type_at_a_variable_test() {
  // `Box<T>` in a body is `Box<Str>` once the copy knows what `T` is, and that
  // instantiation is generated like any other.
  let go =
    compile(
      "type Box {\n\titems: T[dyn]\n}\nfunc boxUp(values: T[]): Box<T> {\n\tBox<T> boxed = Box(values)\n\treturn boxed\n}\nproc main(): void {\n\tStr[dyn] a = [\"x\"]\n\techo len(boxUp(a).items)\n}\n",
    )
  should.be_true(string.contains(go, "type Box_Str struct {"))
  should.be_true(string.contains(go, "func boxUp_Str(values []string) Box_Str {"))
}

pub fn a_variable_is_inferred_through_a_function_parameter_test() {
  // `K` and `E` appear only inside the callback's type, which is still a
  // parameter — so the call pins them down exactly as a plain argument would.
  let go =
    compile(
      "func filterMap(values: T[], transform: func(T): Result<K, E>): K[dyn] {\n\tmut K[dyn] out = []\n\tfor each value in values {\n\t\tif transform(value) is Result.Ok(mapped) {\n\t\t\tappend(out, mapped)\n\t\t}\n\t}\n\treturn out\n}\nfunc parseIt(s: Str): Result<Int, Bool> {\n\treturn Result.Ok(1)\n}\nproc main(): void {\n\tStr[dyn] raw = [\"1\"]\n\tInt[dyn] ones = filterMap(raw, parseIt)\n\techo len(ones)\n}\n",
    )
  should.be_true(string.contains(
    go,
    "func filterMap_Str_Int_Bool(values []string, transform func(string) hive.Result[int, bool]) []int {",
  ))
  should.be_true(string.contains(go, "var out []int = []int{}"))
}

// ---------------------------------------------------------------------------
// `map`, `filter` and `filterMap`
// ---------------------------------------------------------------------------

const walkers = "func double(n: Int): Int {\n\treturn n * 2\n}\nfunc isEven(n: Int): Bool {\n\treturn n % 2 == 0\n}\nfunc show(n: Int): Str {\n\treturn \"{n}\"\n}\nfunc hasOne(row: Str[]): Bool {\n\treturn len(row) == 1\n}\nfunc parseIt(s: Str): Result<Int, Bool> {\n\tif s == \"1\" {\n\t\treturn Result.Ok(1)\n\t}\n\treturn Result.Error(false)\n}\n"

fn walk(body: String) -> Result(String, String) {
  compiler.compile(walkers <> "proc main(): void {\n" <> body <> "}\n")
}

fn walk_go(body: String) -> String {
  let assert Ok(go) = walk(body)
  go
}

fn walk_error(body: String) -> String {
  let assert Error(msg) = walk(body)
  msg
}

pub fn map_yields_what_its_transform_returns_test() {
  let go =
    walk_go(
      "\tInt[dyn] v = [1, 2]\n\tStr[dyn] shown = map(v, show)\n\techo join(shown, \",\")\n",
    )
  should.be_true(string.contains(go, "var shown []string = hive.Map(v, show)"))
}

pub fn filter_keeps_the_vectors_own_type_test() {
  let go =
    walk_go("\tInt[dyn] v = [1, 2]\n\tInt[dyn] evens = filter(v, isEven)\n\techo len(evens)\n")
  should.be_true(string.contains(go, "var evens []int = hive.Filter(v, isEven)"))
}

pub fn filter_map_yields_the_ok_payload_test() {
  let go =
    walk_go(
      "\tStr[dyn] raw = [\"1\", \"x\"]\n\tInt[dyn] ones = filterMap(raw, parseIt)\n\techo len(ones)\n",
    )
  should.be_true(string.contains(
    go,
    "var ones []int = hive.FilterMap(raw, parseIt)",
  ))
}

pub fn a_walk_takes_a_partial_application_test() {
  let go =
    walk_go("\tInt[dyn] v = [1, 2]\n\tInt[dyn] doubled = map(v, double(_))\n\techo len(doubled)\n")
  should.be_true(string.contains(go, "hive.Map(v, func(_h0 int) int {"))
}

pub fn a_walk_copies_a_mutable_vector_in_test() {
  // The vector goes in the way it would go into any `T[]` parameter, so the
  // elements the result holds are not ones the caller can still write to.
  let go =
    walk_go(
      "\tmut Str[dyn][dyn] rows = [[\"a\"]]\n\tStr[dyn][dyn] kept = filter(rows, hasOne)\n\techo len(kept)\n",
    )
  should.be_true(string.contains(go, "hive.Filter(hive.CloneVecFn(rows,"))
}

pub fn a_walk_is_available_in_a_func_body_test() {
  // Every walk is pure, so a `func` may use one — nothing about it is a proc.
  walk("\tInt[dyn] v = [1]\n\techo len(map(v, double))\n") |> should.be_ok
  compiler.compile(
    "func double(n: Int): Int {\n\treturn n * 2\n}\nfunc total(v: Int[]): Int {\n\treturn len(map(v, double))\n}\nproc main(): void {\n\tInt[dyn] v = [1]\n\techo total(v)\n}\n",
  )
  |> should.be_ok
}

pub fn a_walk_rejects_a_proc_test() {
  let assert Error(msg) =
    compiler.compile(
      "proc shout(n: Int): Int {\n\techo n\n\treturn n\n}\nproc main(): void {\n\tInt[dyn] v = [1]\n\techo len(map(v, shout))\n}\n",
    )
  should.be_true(string.contains(msg, "takes a `func` (pure)"))
}

pub fn filter_needs_a_bool_test() {
  let msg = walk_error("\tInt[dyn] v = [1]\n\techo len(filter(v, show))\n")
  should.be_true(string.contains(msg, "answers `Bool`"))
}

pub fn filter_map_needs_a_result_test() {
  let msg = walk_error("\tInt[dyn] v = [1]\n\techo len(filterMap(v, show))\n")
  should.be_true(string.contains(msg, "answers a `Result`"))
}

pub fn map_needs_a_value_back_test() {
  let assert Error(msg) =
    compiler.compile(
      "func nothing(n: Int): void {\n\treturn\n}\nproc main(): void {\n\tInt[dyn] v = [1]\n\techo len(map(v, nothing))\n}\n",
    )
  should.be_true(string.contains(msg, "returns nothing"))
}

pub fn a_walk_needs_a_vector_test() {
  let msg = walk_error("\techo len(map(\"abc\", show))\n")
  should.be_true(string.contains(msg, "walks a vector"))
}

pub fn a_walk_needs_the_right_element_type_test() {
  let assert Error(msg) =
    compiler.compile(
      "func upper(s: Str): Str {\n\treturn s\n}\nproc main(): void {\n\tInt[dyn] v = [1]\n\techo len(map(v, upper))\n}\n",
    )
  should.be_true(string.contains(msg, "walking a vector of `Int`"))
}

pub fn a_walk_needs_a_one_element_function_test() {
  let assert Error(msg) =
    compiler.compile(
      "func addN(a: Int, b: Int): Int {\n\treturn a + b\n}\nproc main(): void {\n\tInt[dyn] v = [1]\n\techo len(map(v, addN))\n}\n",
    )
  should.be_true(string.contains(msg, "one element at a time"))
}

pub fn a_walk_needs_two_arguments_test() {
  let msg = walk_error("\tInt[dyn] v = [1]\n\techo len(map(v))\n")
  should.be_true(string.contains(msg, "1 argument was passed"))
}

pub fn a_walk_takes_no_named_arguments_test() {
  let msg = walk_error("\tInt[dyn] v = [1]\n\techo len(map(values: v, transform: show))\n")
  should.be_true(string.contains(msg, "does not accept named arguments"))
}

// --- a walk is sequential, always ---

const async_walkers = "func label(n: Int): Str {\n\treturn \"#{n}\"\n}\nfunc isEven(n: Int): Bool {\n\treturn n % 2 == 0\n}\nfunc asPort(s: Str): Result<Int, Bool> {\n\treturn Result.Ok(1)\n}\n"

fn async_walk(body: String) -> Result(String, String) {
  compiler.compile(async_walkers <> "proc main(): void {\n" <> body <> "}\n")
}

pub fn a_walk_is_sequential_test() {
  // Concurrency is written where it happens, never hidden inside a builtin whose
  // signature says nothing about it. Each walk has exactly one lowering.
  let assert Ok(m) = async_walk("\tInt[dyn] v = [1]\n\techo len(map(v, label))\n")
  should.be_true(string.contains(m, "hive.Map(v, label)"))
  should.be_false(string.contains(m, "hive.Spawn"))

  let assert Ok(f) =
    async_walk("\tInt[dyn] v = [1]\n\techo len(filter(v, isEven))\n")
  should.be_true(string.contains(f, "hive.Filter(v, isEven)"))

  let assert Ok(fm) =
    async_walk("\tStr[dyn] r = [\"1\"]\n\techo len(filterMap(r, asPort))\n")
  should.be_true(string.contains(fm, "hive.FilterMap(r, asPort)"))
}

pub fn a_walk_preserves_the_length_test() {
  async_walk("\tInt[3] v = [1, 2, 3]\n\tout := map(v, label)\n\techo out[2]\n")
  |> should.be_ok
  let assert Error(msg) =
    async_walk("\tInt[3] v = [1, 2, 3]\n\tout := map(v, label)\n\techo out[3]\n")
  should.be_true(string.contains(msg, "out of range for a vector of length 3"))
}

// To run a batch of calls together you write the await-all yourself, which is
// also where the count of them lives.
pub fn a_batch_of_calls_runs_together_through_await_test() {
  let assert Ok(go) =
    async_walk(
      "\tStr[2] both = await [label(1), label(2)]\n\techo join(both, \",\")\n",
    )
  should.be_true(string.contains(go, "hive.AwaitAll([]*hive.Async[string]{"))
}

// Nothing about a walk is concurrent any more, so a closure that fixes some of
// the arguments is an ordinary function value like any other (see
// `a_walk_takes_a_partial_application_test` above for the lowering).
pub fn a_walk_takes_a_partially_applied_multi_arg_func_test() {
  compiler.compile(
    "func addN(a: Int, b: Int): Int {\n\treturn a + b\n}\nproc main(): void {\n\tInt[dyn] v = [1]\n\techo len(map(v, addN(10, _)))\n}\n",
  )
  |> should.be_ok
}

// --- `map` preserves its input's length; `filter`/`filterMap` cannot ---

pub fn map_preserves_a_static_length_test() {
  // Same length, same order — so a `map` of a `Str[2]` is two elements, and the
  // last one is indexable with no guard.
  walk("\tInt[2] v = [1, 2]\n\tdoubled := map(v, double)\n\techo doubled[1]\n")
  |> should.be_ok
}

pub fn map_preserves_a_length_past_its_end_test() {
  let msg = walk_error("\tInt[2] v = [1, 2]\n\tdoubled := map(v, double)\n\techo doubled[2]\n")
  should.be_true(string.contains(msg, "out of range for a vector of length 2"))
}

pub fn a_mapped_length_fills_a_declared_slot_test() {
  // The length is a real one, so it satisfies a `Str[2]` promise — and fails a
  // `Str[3]` one, rather than being waved through as unknown.
  walk("\tInt[2] v = [1, 2]\n\tInt[2] out = map(v, double)\n\techo out[1]\n")
  |> should.be_ok
  let msg = walk_error("\tInt[2] v = [1, 2]\n\tInt[3] out = map(v, double)\n\techo out[0]\n")
  should.be_true(string.contains(msg, "exactly 3 elements — this one has 2"))
}

pub fn mapped_lengths_chain_and_compose_test() {
  // A map of a map is still that length, and two of them concatenated add up
  // the way any two static vectors do.
  walk(
    "\tInt[2] v = [1, 2]\n\tboth := map(v, double) + map(map(v, double), double)\n\techo both[3]\n",
  )
  |> should.be_ok
  let msg =
    walk_error(
      "\tInt[2] v = [1, 2]\n\tboth := map(v, double) + map(v, double)\n\techo both[4]\n",
    )
  should.be_true(string.contains(msg, "out of range for a vector of length 4"))
}

pub fn map_over_a_dynamic_vector_stays_dynamic_test() {
  // Nothing is invented: a length that was not known going in is not known
  // coming out.
  let msg = walk_error("\tInt[dyn] v = [1, 2]\n\tdoubled := map(v, double)\n\techo doubled[0]\n")
  should.be_true(string.contains(msg, "cannot prove index 0 is in range"))
}

pub fn filter_does_not_preserve_a_length_test() {
  // `filter` and `filterMap` select, so what is knowable about them is a
  // maximum, not a length — and a maximum can never put an index in range,
  // since keeping nothing is always a possibility.
  let kept = walk_error("\tInt[2] v = [1, 2]\n\tevens := filter(v, isEven)\n\techo evens[0]\n")
  should.be_true(string.contains(kept, "cannot prove index 0 is in range"))
  let mapped =
    walk_error("\tStr[2] v = [\"1\", \"x\"]\n\tones := filterMap(v, parseIt)\n\techo ones[0]\n")
  should.be_true(string.contains(mapped, "cannot prove index 0 is in range"))
}

pub fn a_declared_map_promises_no_length_test() {
  // The length comes from the *builtin*. A `map` of your own is an ordinary
  // callable, and its `T[]` return promises nothing.
  let assert Error(msg) =
    compiler.compile(
      "func map(values: Int[], by: Int): Int[dyn] {\n\treturn values\n}\nproc main(): void {\n\tInt[2] v = [1, 2]\n\tc := map(v, 2)\n\techo c[1]\n}\n",
    )
  should.be_true(string.contains(msg, "cannot prove index 1 is in range"))
}

pub fn a_mapped_length_is_a_static_one_test() {
  // Inferred means static, so `append` is refused exactly as it is for any
  // other `:=` binding.
  let msg =
    walk_error("\tInt[2] v = [1, 2]\n\tmut c := map(v, double)\n\tappend(c, 3)\n\techo c[0]\n")
  should.be_true(string.contains(msg, "requires a dynamic vector"))
}

// ---------------------------------------------------------------------------
// `sort`
// ---------------------------------------------------------------------------

const sorters = "func desc(a: Int, b: Int): Bool {\n\treturn a > b\n}\nfunc byLen(a: Str, b: Str): Bool {\n\treturn len(a) < len(b)\n}\nfunc twice(n: Int): Int {\n\treturn n * 2\n}\n"

fn srt(body: String) -> Result(String, String) {
  compiler.compile(sorters <> "proc main(): void {\n" <> body <> "}\n")
}

fn srt_go(body: String) -> String {
  let assert Ok(go) = srt(body)
  go
}

fn srt_error(body: String) -> String {
  let assert Error(msg) = srt(body)
  msg
}

// --- the default ordering, chosen by the element's static type ---

pub fn sort_orders_numbers_and_strings_test() {
  // Everything Go compares with `<` goes through one generic helper.
  let go = srt_go("\tInt[dyn] v = [3, 1]\n\techo len(sort(v))\n")
  should.be_true(string.contains(go, "hive.SortBy(v, hive.LessOrdered[int])"))
  let s = srt_go("\tStr[dyn] v = [\"b\", \"a\"]\n\techo len(sort(v))\n")
  should.be_true(string.contains(s, "hive.SortBy(v, hive.LessOrdered[string])"))
  let f = srt_go("\tFloat[dyn] v = [2.0, 1.0]\n\techo len(sort(v))\n")
  should.be_true(string.contains(
    f,
    "hive.SortBy(v, hive.LessOrdered[float64])",
  ))
}

pub fn sort_orders_bools_false_first_test() {
  let go = srt_go("\tBool[dyn] v = [true, false]\n\techo len(sort(v))\n")
  should.be_true(string.contains(go, "hive.SortBy(v, hive.LessBool)"))
}

pub fn sort_orders_atoms_by_value_test() {
  // By the integer the compiler assigned, not by the name: an atom's name is a
  // thing to log, not a thing to compute with. `hive.Atom` is a defined `int`,
  // so the same ordered helper serves it.
  let go = srt_go("\tAtom[dyn] v = [#Zebra, #Apple]\n\techo len(sort(v))\n")
  should.be_true(string.contains(
    go,
    "hive.SortBy(v, hive.LessOrdered[hive.Atom])",
  ))
}

pub fn sort_orders_vectors_lexicographically_test() {
  let go =
    srt_go("\tStr[dyn][dyn] v = [[\"b\"], [\"a\"]]\n\techo len(sort(v))\n")
  should.be_true(string.contains(
    go,
    "hive.SortBy(v, func(a0, b0 []string) bool { return hive.LessVec(a0, b0, hive.LessOrdered[string]) })",
  ))
}

pub fn sort_orders_a_table_a_row_at_a_time_test() {
  let go = srt_go("\tTable t = [[\"b\"], [\"a\"]]\n\techo len(sort(t))\n")
  should.be_true(string.contains(
    go,
    "hive.SortBy(t, func(a0, b0 []string) bool { return hive.LessVec(a0, b0, hive.LessOrdered[string]) })",
  ))
}

pub fn sort_orders_results_error_first_test() {
  let go =
    srt_go(
      "\tResult<Int, Bool>[dyn] v = [Result.Ok(1)]\n\techo len(sort(v))\n",
    )
  should.be_true(string.contains(
    go,
    "hive.LessResult(a0, b0, hive.LessOrdered[int], hive.LessBool)",
  ))
}

// --- a generated `less_T` for user types ---

pub fn sort_orders_a_struct_field_by_field_test() {
  let assert Ok(go) =
    compiler.compile(
      "type User {\n\tage: Int\n\tname: Str\n}\nproc main(): void {\n\tUser[dyn] v = [User(1, \"a\")]\n\techo len(sort(v))\n}\n",
    )
  should.be_true(string.contains(go, "func less_User(a, b User) bool {"))
  // Fields decide in declaration order: `age` first, `name` only on a tie.
  should.be_true(string.contains(
    go,
    "if l0 := hive.LessOrdered[int]; l0(a.Age, b.Age) {",
  ))
  should.be_true(string.contains(
    go,
    "if l1 := hive.LessOrdered[string]; l1(a.Name, b.Name) {",
  ))
  should.be_true(string.contains(go, "hive.SortBy(v, less_User)"))
}

pub fn sort_orders_a_union_by_declaration_order_test() {
  // The variant decides first, and it does so by the order the author declared
  // them in — the one order they actually chose.
  let assert Ok(go) =
    compiler.compile(
      "type Shape {\n\tCircle { r: Int }\n\tDot\n}\nproc main(): void {\n\tShape[dyn] v = [Shape.Dot()]\n\techo len(sort(v))\n}\n",
    )
  should.be_true(string.contains(go, "func rank_Shape(x Shape) int {"))
  should.be_true(string.contains(go, "case ShapeCircle:\n\t\treturn 0\n"))
  should.be_true(string.contains(go, "case ShapeDot:\n\t\treturn 1\n"))
  should.be_true(string.contains(
    go,
    "if ra, rb := rank_Shape(a), rank_Shape(b); ra != rb {",
  ))
  // A field-less variant compares nothing, so the switch value goes unnamed
  // there rather than being bound and left unused.
  should.be_true(string.contains(go, "case ShapeDot:\n\t\treturn false\n"))
}

pub fn sort_orders_a_recursive_type_through_itself_test() {
  // `less_Node` is what orders a Node's own Node-valued field.
  let assert Ok(go) =
    compiler.compile(
      "type Node {\n\tlabel: Str\n\tkids: Node[dyn]\n}\nproc main(): void {\n\tNode[dyn] v = [Node(\"a\", [])]\n\techo len(sort(v))\n}\n",
    )
  should.be_true(string.contains(go, "func less_Node(a, b Node) bool {"))
  should.be_true(string.contains(go, "hive.LessVec(a0, b0, less_Node)"))
}

// --- the comparator form ---

pub fn sort_takes_a_comparator_test() {
  let go = srt_go("\tInt[dyn] v = [3, 1]\n\techo len(sort(v, desc))\n")
  should.be_true(string.contains(go, "hive.SortBy(v, desc)"))
}

pub fn sort_takes_a_partial_application_test() {
  let assert Ok(go) =
    compiler.compile(
      "func nth(k: Int, a: Str, b: Str): Bool {\n\treturn len(a) + k < len(b)\n}\nproc main(): void {\n\tStr[dyn] v = [\"a\"]\n\techo len(sort(v, nth(0, _, _)))\n}\n",
    )
  should.be_true(string.contains(
    go,
    "hive.SortBy(v, func(_h1 string, _h2 string) bool { return nth(0, _h1, _h2) })",
  ))
}

// --- length is preserved, in both forms ---

pub fn sort_preserves_a_static_length_test() {
  srt("\tInt[3] v = [3, 1, 2]\n\techo sort(v)[2]\n") |> should.be_ok
  srt("\tInt[3] v = [3, 1, 2]\n\techo sort(v, desc)[2]\n") |> should.be_ok
}

pub fn sort_preserves_a_length_past_its_end_test() {
  let msg = srt_error("\tInt[3] v = [3, 1, 2]\n\techo sort(v)[3]\n")
  should.be_true(string.contains(msg, "out of range for a vector of length 3"))
}

pub fn a_sorted_length_composes_with_map_and_concat_test() {
  srt(
    "\tInt[2] v = [2, 1]\n\tboth := sort(v) + map(sort(v, desc), twice)\n\techo both[3]\n",
  )
  |> should.be_ok
  let msg =
    srt_error("\tInt[2] v = [2, 1]\n\tboth := sort(v) + sort(v)\n\techo both[4]\n")
  should.be_true(string.contains(msg, "out of range for a vector of length 4"))
}

pub fn sort_over_a_dynamic_vector_stays_dynamic_test() {
  let msg = srt_error("\tInt[dyn] v = [3, 1]\n\techo sort(v)[0]\n")
  should.be_true(string.contains(msg, "cannot prove index 0 is in range"))
}

// --- what `sort` refuses ---

pub fn sort_needs_a_vector_test() {
  let msg = srt_error("\techo len(sort(\"abc\"))\n")
  should.be_true(string.contains(msg, "orders a vector, and a `Str` is not one"))
  let other = srt_error("\techo len(sort(3))\n")
  should.be_true(string.contains(other, "orders a vector, and this is a `Int`"))
}

pub fn sort_needs_an_orderable_element_test() {
  // The message names the part at fault, not just the outermost type: the
  // one-argument form has to *build* an ordering, so it cannot shrug.
  let assert Error(msg) =
    compiler.compile(
      "func d(n: Int): Int {\n\treturn n\n}\ntype Box {\n\trun: func(Int): Int\n}\nproc main(): void {\n\tBox[dyn] v = [Box(d)]\n\techo len(sort(v))\n}\n",
    )
  should.be_true(string.contains(msg, "`Box` has none"))
  should.be_true(string.contains(
    msg,
    "its field `run` is a `func(Int): Int`, and a function value has no order",
  ))
  should.be_true(string.contains(msg, "sort(values, comesFirst)"))
}

pub fn sort_rejects_a_proc_comparator_test() {
  let assert Error(msg) =
    compiler.compile(
      "proc noisy(a: Int, b: Int): Bool {\n\techo a\n\treturn a < b\n}\nproc main(): void {\n\tInt[dyn] v = [1]\n\techo len(sort(v, noisy))\n}\n",
    )
  should.be_true(string.contains(msg, "takes a `func` (pure), and this is a `proc`"))
}

pub fn sort_needs_one_or_two_arguments_test() {
  let none = srt_error("\techo len(sort())\n")
  should.be_true(string.contains(none, "0 arguments were passed"))
  let three =
    srt_error("\tInt[dyn] v = [1]\n\techo len(sort(v, desc, desc))\n")
  should.be_true(string.contains(three, "3 arguments were passed"))
}

pub fn sort_comparator_takes_two_elements_test() {
  let assert Error(msg) =
    compiler.compile(
      "func one(a: Int): Bool {\n\treturn a > 0\n}\nproc main(): void {\n\tInt[dyn] v = [1]\n\techo len(sort(v, one))\n}\n",
    )
  should.be_true(string.contains(msg, "compares two elements"))
  should.be_true(string.contains(msg, "takes 1 parameter"))
}

pub fn sort_comparator_answers_a_bool_test() {
  let assert Error(msg) =
    compiler.compile(
      "func bad(a: Int, b: Int): Int {\n\treturn a - b\n}\nproc main(): void {\n\tInt[dyn] v = [1]\n\techo len(sort(v, bad))\n}\n",
    )
  should.be_true(string.contains(msg, "answers `Bool` — this one answers `Int`"))
}

pub fn sort_comparator_takes_the_element_type_test() {
  let assert Error(msg) =
    compiler.compile(
      "func strs(a: Str, b: Str): Bool {\n\treturn a < b\n}\nproc main(): void {\n\tInt[dyn] v = [1]\n\techo len(sort(v, strs))\n}\n",
    )
  should.be_true(string.contains(msg, "ordering a vector of `Int`"))
}

// --- the builtin, and a declaration of your own ---

pub fn a_declared_sort_wins_test() {
  // An ordinary callable: its `Int[]` return promises no length, and its second
  // parameter is nothing special.
  let assert Error(msg) =
    compiler.compile(
      "func sort(v: Int[], flag: Bool): Int[dyn] {\n\treturn v\n}\nproc main(): void {\n\tInt[3] v = [3, 1, 2]\n\tc := sort(v, true)\n\techo c[1]\n}\n",
    )
  should.be_true(string.contains(msg, "cannot prove index 1 is in range"))
}

pub fn hive_sort_reaches_the_builtin_test() {
  let assert Ok(go) =
    compiler.compile(
      "func sort(v: Int[], flag: Bool): Int[dyn] {\n\treturn v\n}\nproc main(): void {\n\tInt[3] v = [3, 1, 2]\n\techo hive.sort(v)[2]\n}\n",
    )
  should.be_true(string.contains(go, "hive.SortBy(v, hive.LessOrdered[int])"))
}

// --- discarded, on mut storage: sorted in place ---

pub fn a_discarded_sort_on_a_mut_vector_sorts_in_place_test() {
  // Both conditions met, so there is nothing for a copy to protect: no argument
  // clone and no copy inside the helper.
  let go = srt_go("\tmut Int[dyn] v = [3, 1]\n\tsort(v)\n\techo len(v)\n")
  should.be_true(string.contains(
    go,
    "hive.SortInPlace(v, hive.LessOrdered[int])",
  ))
  should.be_false(string.contains(go, "hive.SortBy"))
}

pub fn a_discarded_sort_in_place_takes_a_comparator_test() {
  let go = srt_go("\tmut Int[dyn] v = [3, 1]\n\tsort(v, desc)\n\techo len(v)\n")
  should.be_true(string.contains(go, "hive.SortInPlace(v, desc)"))
}

pub fn a_discarded_sort_in_place_reaches_a_field_or_element_test() {
  // Any mut storage the subject names, not just a bare variable: a slice header
  // into the same backing array is what makes the reorder land where it should.
  let assert Ok(field) =
    compiler.compile(
      "type Box {\n\titems: Int[dyn]\n}\nproc main(): void {\n\tmut Box b = Box([3, 1])\n\tsort(b.items)\n\techo len(b.items)\n}\n",
    )
  should.be_true(string.contains(field, "hive.SortInPlace(b.Items,"))
}

pub fn a_kept_sort_is_never_in_place_test() {
  // The expression form has to keep answering with a new vector and leaving the
  // subject alone, or every `b := sort(a)` would quietly reorder `a` too.
  let go =
    srt_go("\tmut Int[dyn] v = [3, 1]\n\tout := sort(v)\n\techo len(out) + len(v)\n")
  should.be_true(string.contains(go, "hive.SortBy(hive.CloneVec(v),"))
  should.be_false(string.contains(go, "hive.SortInPlace"))
}

pub fn a_discarded_sort_on_an_immutable_vector_is_rejected_test() {
  // `mut` is what makes writing allowed at all: an immutable binding's storage
  // is never mutated in place, which is what the copy-on-binding analysis rests
  // on. So this cannot sort in place — and a discarded sort that does not sort
  // in place is dead code wearing the shape of the form that does.
  let msg = srt_error("\tInt[dyn] v = [3, 1]\n\tsort(v)\n\techo len(v)\n")
  should.be_true(string.contains(msg, "throws away the vector it answers with"))
  should.be_true(string.contains(msg, "`v` is not `mut`"))
  should.be_true(string.contains(msg, "sorted := sort(...)"))
}

pub fn a_discarded_sort_of_an_unstored_vector_is_rejected_test() {
  // Nothing to write to at all, so the message says that rather than pointing
  // at a `mut` that would not help.
  let msg = srt_error("\tStr[dyn] s = [\"b,a\"]\n\tsort(split(\"b,a\", \",\"))\n\techo len(s)\n")
  should.be_true(string.contains(msg, "not stored anywhere"))
}

pub fn a_discarded_sort_is_fine_in_a_loop_clause_test() {
  // The check runs wherever a statement does, including a `for` init/post.
  let msg =
    srt_error("\tInt[dyn] v = [3, 1]\n\tfor i := 0; i < 1; sort(v) {\n\t\techo i\n\t}\n")
  should.be_true(string.contains(msg, "`v` is not `mut`"))
  srt("\tmut Int[dyn] v = [3, 1]\n\tfor i := 0; i < 1; sort(v) {\n\t\techo i\n\t}\n")
  |> should.be_ok
}

pub fn an_in_place_sort_counts_as_a_write_for_aliasing_test() {
  // The one that would be a silent miscompile: `b := a` may only alias `a` when
  // `a` is never mutated in place afterwards, and a discarded `sort(a)` now is
  // exactly that. Without counting it, `b` would be reordered underneath.
  let go =
    srt_go("\tmut Int[dyn] a = [3, 1]\n\tb := a\n\tsort(a)\n\techo len(b)\n")
  should.be_true(string.contains(go, "b := hive.CloneVec(a)"))
  should.be_true(string.contains(go, "hive.SortInPlace(a,"))
}

pub fn two_mut_bindings_share_an_in_place_sort_test() {
  // Shared mutable state is shared completely: `mut d = c` is one slice header
  // for both names, so sorting through either is seen through both.
  let go =
    srt_go(
      "\tmut Int[dyn] c = [3, 1]\n\tmut Int[dyn] d = c\n\tsort(c)\n\techo len(d)\n",
    )
  should.be_true(string.contains(go, "hive.SortInPlace(c,"))
  // `d` is not given a variable of its own; it renders as `c`.
  should.be_false(string.contains(go, "d :="))
}

pub fn sort_copies_a_mutable_vector_in_test() {
  // The vector goes in as it would into any `T[]` parameter, so the caller can
  // keep writing to theirs without the sorted one changing under it.
  let go = srt_go("\tmut Int[dyn] v = [3, 1]\n\techo len(sort(v))\n")
  should.be_true(string.contains(go, "hive.SortBy(hive.CloneVec(v),"))
}

// ---------------------------------------------------------------------------
// A declaration wins over a builtin; `hive.<name>` always reaches the builtin
// ---------------------------------------------------------------------------

pub fn a_declaration_wins_over_a_builtin_test() {
  // A name you declared is the one your calls mean — including its own arity,
  // which the builtin's would have rejected.
  let go =
    compile(
      "func len(label: Str, extra: Int): Str {
	return \"{label}{extra}\"
}
proc main(): void {
	echo len(\"x\", 2)
}
",
    )
  // `len` is a Go builtin, so the declaration is renamed — left alone it would
  // shadow the `len` every generated vector length uses.
  should.be_true(string.contains(
    go,
    "func len_(label string, extra int) string {",
  ))
  should.be_true(string.contains(go, "len_(\"x\", 2)"))
}

pub fn a_shadowed_builtin_is_reached_by_its_long_name_test() {
  let go =
    compile(
      "func len(label: Str, extra: Int): Str {
	return \"{label}{extra}\"
}
proc main(): void {
	Str[dyn] v = [\"a\", \"b\"]
	echo len(\"x\", 2)
	echo hive.len(v)
	echo hive.join(v, \"-\")
}
",
    )
  should.be_true(string.contains(go, "len_(\"x\", 2)"))
  should.be_true(string.contains(go, "fmt.Println(len(v))"))
  should.be_true(string.contains(go, "hive.Join(v, \"-\")"))
}

pub fn a_local_wins_over_a_builtin_test() {
  let go =
    compile(
      "func addN(a: Int, b: Int): Int {
	return a + b
}
proc main(): void {
	filter := addN(1, _)
	echo filter(41)
}
",
    )
  should.be_false(string.contains(go, "hive.Filter("))
}

pub fn a_program_keeps_its_own_map_test() {
  let go =
    compile(
      "func map(a: Int, b: Int, c: Int): Int {
	return a + b + c
}
proc main(): void {
	echo map(1, 2, 3)
}
",
    )
  should.be_true(string.contains(go, "func map_(a int, b int, c int) int {"))
  should.be_true(string.contains(go, "map_(1, 2, 3)"))
  should.be_false(string.contains(go, "hive.Map("))
}

pub fn a_declared_append_is_an_ordinary_callable_test() {
  // The mutability rule belongs to the builtin: a declared `append` has no
  // special first argument, and an immutable one is nobody's error.
  let go =
    compile(
      "func append(a: Str, b: Str): Str {
	return a + b
}
proc main(): void {
	x := \"a\"
	echo append(x, \"b\")
}
",
    )
  should.be_true(string.contains(
    go,
    "func append_(a string, b string) string {",
  ))
  should.be_true(string.contains(go, "append_(x, \"b\")"))
}

pub fn the_builtin_append_still_needs_a_mut_target_test() {
  let assert Error(msg) =
    compiler.compile(
      "func append(a: Str, b: Str): Str {
	return a + b
}
proc main(): void {
	Str[dyn] v = [\"a\"]
	hive.append(v, \"b\")
}
",
    )
  should.be_true(string.contains(msg, "requires a mutable vector"))
}

pub fn a_bounds_guard_is_not_captured_by_a_declared_len_test() {
  // `v bounds i` desugars to a length check, and a desugaring has to mean the
  // same thing in a program that declared a `len` of its own.
  let go =
    compile(
      "func len(label: Str): Str {
	return label
}
proc main(): void {
	Str[dyn] v = [\"a\", \"b\"]
	i := 1
	if v bounds i {
		echo v[i]
	}
}
",
    )
  should.be_true(string.contains(go, "(i < len(v))"))
}

pub fn a_declared_index_of_carries_no_proof_test() {
  // The bounds pass trusts the *builtin* `indexOf` to hand back a position the
  // vector really has. A program's own says nothing of the kind.
  let assert Error(msg) =
    compiler.compile(
      "func indexOf(v: Str[], x: Str): Result<Int, Bool> {
	return Result.Ok(9999)
}
proc main(): void {
	Str[dyn] v = [\"a\"]
	if indexOf(v, \"a\") is Result.Ok(i) {
		echo v[i]
	}
}
",
    )
  should.be_true(string.contains(msg, "cannot prove"))

  // The builtin's proof survives, reached the long way.
  compiler.compile(
    "func indexOf(v: Str[], x: Str): Result<Int, Bool> {
	return Result.Ok(9999)
}
proc main(): void {
	Str[dyn] v = [\"a\"]
	if hive.indexOf(v, \"a\") is Result.Ok(i) {
		echo v[i]
	}
}
",
  )
  |> should.be_ok
}

pub fn shadowing_is_per_module_test() {
  // The entry declares `map`; the imported module does not, so a bare `map`
  // there is still the builtin. Another module's declarations are only ever
  // reached through its alias, so they cannot shadow anything here.
  let assert Ok(go) =
    compiler.compile_file("test/modules/shadowed-builtin.hive")
  should.be_true(string.contains(go, "func map_(a int, b int) int {"))
  should.be_true(string.contains(go, "map_(6, 7)"))
  // The library module's own `map(v, double)` reached the builtin.
  should.be_true(string.contains(go, "hive.Map(v, "))
}

pub fn an_unknown_hive_member_is_named_test() {
  let assert Error(msg) =
    compiler.compile("proc main(): void {
	echo hive.nope(1)
}
")
  should.be_true(string.contains(msg, "`hive.nope` is not a builtin"))
  should.be_true(string.contains(msg, "lives in a module"))
}

pub fn a_bare_hive_builtin_type_still_points_at_its_module_test() {
  // The older message for `hive.HttpRequest(...)` is not swallowed by the new
  // global-builtin arm.
  let assert Error(msg) =
    compiler.compile(
      "proc main(): void {
	r := hive.HttpRequest(\"GET\")
	echo r.method
}
",
    )
  should.be_true(string.contains(msg, "hive.net.HttpRequest"))
}

pub fn a_walk_composes_with_a_generic_test() {
  // The generic's callback type is what pins `K` and `E` down; once the copy is
  // concrete, `filterMap` reads its result off that same substituted type.
  let go =
    compile(
      "func onlyOk(values: T[], check: func(T): Result<K, E>): K[dyn] {\n\treturn filterMap(values, check)\n}\nfunc parseIt(s: Str): Result<Int, Bool> {\n\treturn Result.Ok(1)\n}\nproc main(): void {\n\tStr[dyn] raw = [\"1\"]\n\tInt[dyn] ones = onlyOk(raw, parseIt)\n\techo len(ones)\n}\n",
    )
  should.be_true(string.contains(
    go,
    "func onlyOk_Str_Int_Bool(values []string, check func(string) hive.Result[int, bool]) []int {",
  ))
  should.be_true(string.contains(go, "return hive.FilterMap(values, check)"))
}

// ---------------------------------------------------------------------------
// Typed queries
// ---------------------------------------------------------------------------

pub fn a_void_query_reports_rows_affected_test() {
  let go =
    compile(
      "query wipe(): void {\n\tDELETE FROM t\n}\nproc main(): void {\n\topened := hive.sql.connect(hive.sql.DatabaseDriver.SQLite(), \"x.db\")\n\tif opened is Result.Ok(db) {\n\t\tif using db run wipe() is Result.Ok(n) {\n\t\t\techo n\n\t\t}\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.SqlExec(db, wipe())"))
}

pub fn a_row_query_maps_through_a_generated_mapper_test() {
  let go =
    compile(
      "type U {\n\tid: Int\n\tname: Str\n}\nquery all(): U[dyn] {\n\tSELECT id, name FROM users\n}\nproc main(): void {\n\topened := hive.sql.connect(hive.sql.DatabaseDriver.SQLite(), \"x.db\")\n\tif opened is Result.Ok(db) {\n\t\tif using db run all() is Result.Ok(rows) {\n\t\t\techo len(rows)\n\t\t}\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.SqlRows(db, all(), sqlRow_U)"))
  should.be_true(string.contains(go, "func sqlRow_U(_r []string) (U, error) {"))
  // Cells are converted to the field's declared type, and a miss is an error.
  should.be_true(string.contains(go, "hive.SqlCellInt(_r[0], \"id\")"))
  should.be_true(string.contains(go, "hive.SqlCellStr(_r[1], \"name\")"))
  should.be_true(string.contains(go, "hive.SqlShapeError(2, len(_r))"))
}

pub fn a_single_column_query_needs_no_row_type_test() {
  let go =
    compile(
      "query names(): Str[dyn] {\n\tSELECT name FROM users\n}\nproc main(): void {\n\topened := hive.sql.connect(hive.sql.DatabaseDriver.SQLite(), \"x.db\")\n\tif opened is Result.Ok(db) {\n\t\tif using db run names() is Result.Ok(ns) {\n\t\t\techo join(ns, \",\")\n\t\t}\n\t}\n}\n",
    )
  should.be_true(string.contains(go, "hive.SqlRows(db, names(),"))
  should.be_true(string.contains(go, "hive.SqlShapeError(1, len(_r))"))
}

// ---------------------------------------------------------------------------
// `SELECT *` against a declared row type
// ---------------------------------------------------------------------------

fn star_query(ret: String, sql: String) -> Result(String, String) {
  compiler.compile(
    "type U {\n\tid: Int\n\tname: Str\n}\nquery q(): "
    <> ret
    <> " {\n\t"
    <> sql
    <> "\n}\nproc main(): void {}\n",
  )
}

pub fn select_star_into_a_row_type_is_rejected_test() {
  let assert Error(msg) = star_query("U[dyn]", "SELECT * FROM users")
  should.be_true(string.contains(msg, "does not say how many columns"))
}

pub fn a_qualified_star_is_rejected_test() {
  let assert Error(msg) = star_query("U[dyn]", "SELECT u.* FROM users u")
  should.be_true(string.contains(msg, "`u.*`"))
}

pub fn distinct_star_is_rejected_test() {
  let assert Error(msg) = star_query("U[dyn]", "SELECT DISTINCT * FROM users")
  should.be_true(string.contains(msg, "does not say how many columns"))
}

pub fn select_star_into_a_scalar_is_rejected_test() {
  let assert Error(msg) = star_query("Str[dyn]", "SELECT * FROM users")
  should.be_true(string.contains(msg, "does not say how many columns"))
}

pub fn select_star_into_a_table_is_allowed_test() {
  // A Table promises nothing about its shape, so there is nothing to break.
  star_query("Table", "SELECT * FROM users") |> should.be_ok
}

pub fn select_star_in_a_void_statement_is_allowed_test() {
  // Its select list is a subquery, not a result.
  star_query("void", "INSERT INTO a SELECT * FROM b") |> should.be_ok
}

pub fn count_star_is_not_a_star_test() {
  star_query("Int[dyn]", "SELECT count(*) FROM users") |> should.be_ok
}

pub fn a_multiplication_is_not_a_star_test() {
  star_query("Int[dyn]", "SELECT a * 2 FROM users") |> should.be_ok
}

pub fn a_star_in_a_subquery_is_not_this_querys_test() {
  star_query("U[dyn]", "SELECT id, name FROM u WHERE x IN (SELECT * FROM y)")
  |> should.be_ok
}

pub fn a_star_inside_a_sql_string_is_not_a_star_test() {
  star_query("Str[dyn]", "SELECT name FROM users WHERE note = '* nope *'")
  |> should.be_ok
}

// ---------------------------------------------------------------------------
// Unit tests: `test` declarations, and the report `hive test` prints
// ---------------------------------------------------------------------------

fn test_go(src: String) -> String {
  let assert Ok(module) = modules.load_source(src, ".", "cart.hive")
  let assert Ok(module) = generics.expand(module)
  let assert Some(go) = codegen.generate_tests(module)
  go
}

pub fn a_test_becomes_a_go_subtest_test() {
  let go =
    test_go(
      "test \"an empty cart costs nothing\" {\n\tassert 1 == 1\n}\n",
    )
  should.be_true(string.contains(go, "func TestHive(t *testing.T)"))
  should.be_true(string.contains(
    go,
    "t.Run(\"an empty cart costs nothing\", func(t *testing.T) {",
  ))
}

pub fn a_test_recovers_from_a_panic_test() {
  // Go's own runner re-panics and aborts the binary, which would let one broken
  // test hide every result after it.
  let go = test_go("test \"boom\" {\n\tpanic \"x\"\n}\n")
  should.be_true(string.contains(go, "defer hiveTestRecover(t)"))
}

pub fn an_assert_in_a_test_records_rather_than_panics_test() {
  let go = test_go("test \"t\" {\n\tassert 1 == 2\n}\n")
  should.be_true(string.contains(go, "hiveTestAssertCmp(t,"))
  should.be_false(string.contains(go, "hive.Assert("))
}

pub fn an_assert_outside_a_test_still_panics_test() {
  let go = compile("proc main(): void {\n\tassert 1 == 1\n}\n")
  should.be_true(string.contains(go, "hive.Assert("))
}

pub fn a_failed_comparison_shows_both_sides_test() {
  let go =
    test_go("func f(): Int {\n\treturn 1\n}\ntest \"t\" {\n\tassert f() == 2\n}\n")
  should.be_true(string.contains(go, "\"f() == 2\""))
  should.be_true(string.contains(go, "hive.Show(f())"))
  should.be_true(string.contains(go, "hive.Show(2)"))
}

pub fn a_quoted_condition_uses_the_authors_names_test() {
  // Two rewrites happen before codegen and neither belongs in a message: a bare
  // builtin becomes `hive.len`, and an imported name becomes its flat name.
  let go = test_go("test \"t\" {\n\tv := [\"a\"]\n\tassert len(v) == 3\n}\n")
  should.be_true(string.contains(go, "\"len(v) == 3\""))
  should.be_false(string.contains(go, "hive.len(v) == 3"))
}

pub fn a_non_comparison_assert_shows_only_the_source_test() {
  // The operands of an `&&` are `true`/`false`, which says nothing the condition
  // did not already say.
  let go =
    test_go("func f(): Bool {\n\treturn true\n}\ntest \"t\" {\n\tassert f()\n}\n")
  should.be_true(string.contains(go, "hiveTestAssert(t,"))
  should.be_false(string.contains(go, "hiveTestAssertCmp(t,"))
}

pub fn a_failure_points_at_the_hive_line_test() {
  let go = test_go("test \"t\" {\n\techo \"a\"\n\tassert 1 == 2\n}\n")
  // `//line` has to start at column 1 to be a directive, and it names the line
  // after itself.
  should.be_true(string.contains(go, "\n//line cart.hive:3\n"))
}

pub fn tests_are_left_out_of_the_program_test() {
  let go =
    compile(
      "proc main(): void {\n\techo \"hi\"\n}\ntest \"t\" {\n\tassert 1 == 1\n}\n",
    )
  should.be_false(string.contains(go, "testing"))
  should.be_false(string.contains(go, "TestHive"))
}

pub fn a_test_may_call_a_proc_test() {
  let go =
    test_go(
      "proc save(): Bool {\n\treturn true\n}\ntest \"t\" {\n\tassert save()\n}\n",
    )
  should.be_true(string.contains(go, "save()"))
}

pub fn an_atom_only_a_test_names_is_in_the_table_test() {
  // There is one atom table for the whole package and the test file reads it.
  let go =
    compile(
      "proc main(): void {\n\techo \"hi\"\n}\ntest \"t\" {\n\tassert #Ready == #Ready\n}\n",
    )
  should.be_true(string.contains(go, "Ready"))
}

pub fn a_func_may_not_be_named_test_test() {
  // `test` is a keyword now, so it cannot also be a declaration's name.
  should.be_error(compiler.compile(
    "func test(): Int {\n\treturn 1\n}\nproc main(): void {\n\techo test()\n}\n",
  ))
}

pub fn a_test_needs_a_quoted_name_test() {
  should.be_error(compiler.check_source("test ok {\n\tassert 1 == 1\n}\n"))
}

pub fn duplicate_test_names_are_rejected_test() {
  let assert Error(msg) =
    compiler.check_source(
      "test \"same\" {\n\tassert 1 == 1\n}\ntest \"same\" {\n\tassert 2 == 2\n}\n",
    )
  should.be_true(string.contains(msg, "both named"))
}

pub fn a_test_cannot_return_a_value_test() {
  let assert Error(msg) =
    compiler.check_source("test \"t\" {\n\treturn 1\n}\n")
  should.be_true(string.contains(msg, "cannot return a value"))
}

pub fn a_test_may_return_early_test() {
  test_go("test \"t\" {\n\tif 1 == 1 {\n\t\treturn\n\t}\n\tassert 1 == 2\n}\n")
  |> string.contains("return")
  |> should.be_true
}

pub fn a_bounds_error_in_a_test_is_still_an_error_test() {
  // A test is ordinary Hive code and every pass applies to it.
  should.be_error(compiler.check_source(
    "test \"t\" {\n\tv := [\"a\"]\n\tassert v[3] == \"a\"\n}\n",
  ))
}

pub fn a_file_of_only_tests_checks_clean_test() {
  // No `main` is needed to be a good file, only to be a runnable one.
  compiler.check_source("test \"t\" {\n\tassert 1 == 1\n}\n") |> should.be_ok
}

pub fn a_file_of_only_tests_cannot_be_run_test() {
  let assert Error(msg) =
    compiler.compile("test \"t\" {\n\tassert 1 == 1\n}\n")
  should.be_true(string.contains(msg, "hive test"))
}

// --- the report ------------------------------------------------------------

const go_test_output = "=== RUN   TestHive
=== RUN   TestHive/an_empty_cart_costs_nothing
=== RUN   TestHive/quantities_multiply
    cart.hive:12: assert total(items) == 6
        left:  5
        right: 6
--- FAIL: TestHive (0.00s)
    --- PASS: TestHive/an_empty_cart_costs_nothing (0.00s)
    --- FAIL: TestHive/quantities_multiply (0.00s)
FAIL
coverage: 57.1% of statements
FAIL\thiveapp\t0.002s
FAIL
"

pub fn the_report_reads_pass_and_fail_per_test_test() {
  let results =
    testreport.parse_results(go_test_output, [
      "an empty cart costs nothing",
      "quantities multiply",
    ])
  should.equal(list.map(results, fn(r) { r.outcome }), [
    testreport.Passed,
    testreport.Failed,
  ])
}

pub fn the_report_keeps_a_failures_detail_test() {
  let results =
    testreport.parse_results(go_test_output, [
      "an empty cart costs nothing",
      "quantities multiply",
    ])
  let assert [_, failed] = results
  should.equal(list.length(failed.detail), 3)
  should.be_true(string.contains(
    string.join(failed.detail, "\n"),
    "cart.hive:12: assert total(items) == 6",
  ))
}

pub fn the_report_reports_in_declaration_order_test() {
  // Not the order Go happened to finish them in.
  let results =
    testreport.parse_results(go_test_output, [
      "quantities multiply",
      "an empty cart costs nothing",
    ])
  should.equal(list.map(results, fn(r) { r.name }), [
    "quantities multiply",
    "an empty cart costs nothing",
  ])
}

pub fn a_test_go_never_reported_on_counts_as_failed_test() {
  let results = testreport.parse_results(go_test_output, ["never ran"])
  should.equal(list.map(results, fn(r) { r.outcome }), [testreport.Failed])
}

const main_go = "package main

func total(v []int) int {
	s := 0
	return s
}

func discount(a int) int {
	return a
}

func clone_Item(x Item) Item {
	return x
}
"

fn origins() {
  dict.from_list([
    #("total", ast.Origin("total", "cart.hive")),
    #("discount", ast.Origin("discount", "cart.hive")),
  ])
}

pub fn coverage_locates_each_declaration_test() {
  should.equal(testreport.spans_of(main_go, origins()), [
    #("total", "cart.hive", 3, 6),
    #("discount", "cart.hive", 8, 10),
  ])
}

pub fn coverage_ignores_generated_helpers_test() {
  // `clone_Item` is not something anyone wrote, so it is not something a test
  // can be said to have missed.
  let profile =
    "mode: set
hiveapp/main.go:3.24,6.2 2 1
hiveapp/main.go:8.23,10.2 1 0
hiveapp/main.go:12.32,14.2 1 0
"
  let assert Some(coverage) =
    testreport.parse_coverage(profile, main_go, origins())
  should.equal(coverage.covered, 2)
  should.equal(coverage.total, 3)
}

pub fn coverage_names_what_was_never_exercised_test() {
  let profile =
    "mode: set
hiveapp/main.go:3.24,6.2 2 1
hiveapp/main.go:8.23,10.2 1 0
"
  let assert Some(coverage) =
    testreport.parse_coverage(profile, main_go, origins())
  should.equal(coverage.untouched, ["discount"])
}

pub fn coverage_is_reported_per_file_test() {
  let profile =
    "mode: set
hiveapp/main.go:3.24,6.2 2 1
hiveapp/main.go:8.23,10.2 1 0
"
  let assert Some(coverage) =
    testreport.parse_coverage(profile, main_go, origins())
  should.equal(coverage.files, [#("cart.hive", 2, 3)])
}

pub fn the_rendered_report_states_the_tally_and_coverage_test() {
  let report =
    testreport.Report(
      testreport.parse_results(go_test_output, [
        "an empty cart costs nothing",
        "quantities multiply",
      ]),
      Some(testreport.Coverage(2, 3, ["discount"], [#("cart.hive", 2, 3)])),
    )
  let text = testreport.render(report)
  should.be_true(string.contains(text, "PASS  an empty cart costs nothing"))
  should.be_true(string.contains(text, "FAIL  quantities multiply"))
  should.be_true(string.contains(text, "2 tests: 1 passed, 1 failed"))
  should.be_true(string.contains(text, "coverage: 66.7% of statements (2/3)"))
  should.be_true(string.contains(text, "never exercised: discount"))
}

// ---------------------------------------------------------------------------
// How a name is spelled
// ---------------------------------------------------------------------------

fn rejected(src: String) -> String {
  let assert Error(message) = compiler.compile(src)
  message
}

pub fn a_keyword_is_lower_case_and_nothing_else_test() {
  let message = rejected("PROC main(): void {}\n")
  should.be_true(string.contains(message, "keyword written the wrong way"))
  should.be_true(string.contains(message, "Write `proc`"))
}

pub fn a_keyword_in_another_casing_is_not_a_name_test() {
  // Reserved however it is spelled: reading `If` as a name of its own would
  // leave the mistake to be found somewhere else entirely.
  let message = rejected("proc main(): void {\n\tIf := 1\n}\n")
  should.be_true(string.contains(message, "keyword written the wrong way"))
}

pub fn a_callable_is_camel_case_test() {
  let message = rejected("proc do_the_thing(): void {}\nproc main(): void {}\n")
  should.be_true(string.contains(message, "is not how a callable is named"))
  should.be_true(string.contains(message, "`doTheThing`"))
}

pub fn a_parameter_is_camel_case_test() {
  let message =
    rejected("proc f(User_Name: Str): void {}\nproc main(): void {}\n")
  should.be_true(string.contains(message, "is not how a parameter is named"))
  should.be_true(string.contains(message, "`userName`"))
}

pub fn a_type_and_its_variants_are_pascal_case_test() {
  let message =
    rejected("type user_row {\n\tid: Int\n}\nproc main(): void {}\n")
  should.be_true(string.contains(message, "is not how a type is named"))
  should.be_true(string.contains(message, "`UserRow`"))

  let message = rejected("type U {\n\tok\n\tError\n}\nproc main(): void {}\n")
  should.be_true(string.contains(message, "is not how a variant is named"))
  should.be_true(string.contains(message, "`Ok`"))
}

pub fn a_field_is_camel_case_test() {
  let message =
    rejected("type U {\n\tcreated_at: Str\n}\nproc main(): void {}\n")
  should.be_true(string.contains(message, "is not how a field is named"))
  should.be_true(string.contains(message, "`createdAt`"))
}

pub fn a_variable_nothing_reassigns_may_be_upper_case_test() {
  let go = compile("proc main(): void {\n\tMAX_TRIES := 3\n\techo MAX_TRIES\n}\n")
  should.be_true(string.contains(go, "MAX_TRIES := 3"))
}

pub fn a_mut_variable_may_not_be_written_as_a_constant_test() {
  let message = rejected("proc main(): void {\n\tmut MAX_TRIES := 3\n}\n")
  should.be_true(string.contains(message, "is written as a constant"))
  should.be_true(string.contains(message, "`maxTries`"))
}

pub fn a_loop_counter_may_not_be_written_as_a_constant_test() {
  // The init clause declares a variable the post clause advances, so it is a
  // `mut` whatever it looked like on the way in.
  let message =
    rejected("proc main(): void {\n\tfor I := 0; I < 3; I++ {\n\t\techo I\n\t}\n}\n")
  should.be_true(string.contains(message, "is written as a constant"))
}

pub fn a_binding_is_camel_case_or_a_discard_test() {
  let message =
    rejected(
      "proc main(): void {\n\tv := [\"a\"]\n\tif v is [First] {\n\t\techo First\n\t}\n}\n",
    )
  should.be_true(string.contains(message, "is not how a binding is named"))
  should.be_true(string.contains(message, "`_` to throw the value away"))

  compile("proc main(): void {\n\tv := [\"a\"]\n\tif v is [_] {\n\t\techo v\n\t}\n}\n")
}

pub fn an_atom_is_pascal_case_test() {
  let message = rejected("proc main(): void {\n\ta := #ready\n\techo a\n}\n")
  should.be_true(string.contains(message, "is not how an atom is written"))
  should.be_true(string.contains(message, "`#Ready`"))
}

pub fn a_name_may_open_with_an_underscore_test() {
  // Informal, and the compiler asks nothing of it: private, or here only
  // because something had to be.
  let go =
    compile(
      "func _helperOf(v: Str): Str {\n\treturn v\n}\nproc main(): void {\n\t_scratch := _helperOf(\"x\")\n\techo _scratch\n}\n",
    )
  should.be_true(string.contains(go, "_scratch := _helperOf"))
}

pub fn a_doubled_underscore_is_not_a_prefix_test() {
  let message = rejected("proc main(): void {\n\t__scratch := 1\n}\n")
  should.be_true(string.contains(message, "is not how a variable is named"))
}

// ---------------------------------------------------------------------------
// The case of SQL
// ---------------------------------------------------------------------------

pub fn sql_keywords_are_upper_case_test() {
  let message =
    rejected("query q(): Str[dyn] {\n\tselect name from users\n}\nproc main(): void {}\n")
  should.be_true(string.contains(message, "`select` is a SQL keyword"))
  should.be_true(string.contains(message, "`SELECT`"))
}

pub fn a_quoted_name_keeps_its_own_spelling_test() {
  // Names are the database's, not Hive's — and one that collides with a keyword
  // says so the way SQL always has.
  let go =
    compile(
      "query q(): Str[dyn] {\n\tSELECT \"order\" FROM users\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "SELECT \\\"order\\\" FROM users"))
}

pub fn a_column_of_something_is_left_alone_test() {
  compile(
    "query q(): Str[dyn] {\n\tSELECT u.key FROM users u\n}\nproc main(): void {}\n",
  )
}

pub fn a_where_block_is_written_like_the_clause_it_becomes_test() {
  let message =
    rejected(
      "type U {\n\tname: Str\n}\nquery q(a: Str): U[dyn] {\n\tSELECT name FROM users\n\twhere {\n\t\tif a != \"\" { name = {a} }\n\t}\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(
    message,
    "the block that becomes a `WHERE` clause",
  ))
}

pub fn the_words_inside_a_where_block_are_hives_own_test() {
  let message =
    rejected(
      "type U {\n\tname: Str\n}\nquery q(a: Str): U[dyn] {\n\tSELECT name FROM users\n\tWHERE {\n\t\tIF a != \"\" { name = {a} }\n\t}\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(message, "keyword written the wrong way"))
  should.be_true(string.contains(message, "Hive's own words"))
}

pub fn a_contextual_keyword_is_lower_case_too_test() {
  let message =
    rejected("proc main(): void {\n\tt := using \"./x.csv\" as CSV\n\techo t\n}\n")
  should.be_true(string.contains(message, "keyword written the wrong way"))
  should.be_true(string.contains(message, "Write `csv`"))
}
