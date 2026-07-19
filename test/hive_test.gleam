import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import hive/compiler

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
\t\theaderlessTable: String[][]
\t}
\tNoData
\tError {
\t\terror: hive.TableError
\t}
\ttimestamp: Int
}

proc parse(): ParsingResult {
\tcsv := using \"./test.csv\" with \";\"
\tif csv is Result.Ok(table) {
\t\tif len(table) > 1 {
\t\t\treturn ParsingResult.Success(table[1:], now())
\t\t}
\t\treturn ParsingResult.NoData(now());
\t} else if csv is Result.Error(error) {
\t\treturn ParsingResult.Error(error, now());
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
      "func f(): Str[3] {\n\tStr[2] a = [\"x\", \"y\"]\n\tStr[dyn] b = [\"x\"]\n\tStr[dyn, 2] c = [\"x\", \"y\"]\n\treturn a + [\"z\"]\n}\nproc main(): void {}\n",
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
  // #False and #True always occupy slots 0 and 1; custom atoms follow.
  should.be_true(string.contains(go, "atom_Wax hive.Atom = 2"))
  should.be_true(string.contains(
    go,
    "hive.InitAtoms([]string{\"False\", \"True\", \"Wax\"})",
  ))
  should.be_true(string.contains(go, "func f() hive.Atom {"))
}

pub fn atom_coerces_to_str_next_to_string_test() {
  let go =
    compile(
      "func f(): void {\n\tassert \"0\" + True == \"01\"\n}\nproc main(): void {}\n",
    )
  // True is the atom #True (value 1); as a Str it reads \"1\".
  should.be_true(string.contains(
    go,
    "hive.Assert(((\"0\" + hive.AtomToStr(hive.True)) == \"01\"))",
  ))
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

pub fn query_sanitizes_interpolations_test() {
  let go =
    compile(
      "query q(name: Str): Str {\n\tSELECT * FROM users u\n\tWHERE u.name = {name}\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "func q(name string) string {"))
  should.be_true(string.contains(
    go,
    "return \"SELECT * FROM users u\\nWHERE u.name = \" + hive.SqlParam(name)",
  ))
}

pub fn func_cannot_echo_test() {
  let result =
    compiler.compile(
      "func f(): void {\n\techo \"nope\"\n}\nproc main(): void {}\n",
    )
  should.be_error(result)
}

pub fn func_cannot_call_proc_test() {
  let result =
    compiler.compile(
      "proc p(): void {}\nfunc f(): void {\n\tp()\n}\nproc main(): void {}\n",
    )
  should.be_error(result)
}

// ---------------------------------------------------------------------------
// The shipped code examples must always compile
// ---------------------------------------------------------------------------

pub fn basic_io_example_compiles_test() {
  let assert Ok(src) = simplifile.read("code-examples/1 - Basic IO/basic-io.hive")
  let assert Ok(_) = compiler.compile(src)
}

pub fn types_example_compiles_test() {
  let assert Ok(src) = simplifile.read("code-examples/2 - Types/types.hive")
  let assert Ok(_) = compiler.compile(src)
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
