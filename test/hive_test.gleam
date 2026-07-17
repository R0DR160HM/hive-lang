import gleam/string
import gleeunit
import gleeunit/should
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
  should.be_true(string.contains(
    go,
    "ParsingResultSuccess{HeaderlessTable: table[1:], Timestamp: hive.Now()}",
  ))
  should.be_true(string.contains(
    go,
    "ParsingResultError{Error: error, Timestamp: hive.Now()}",
  ))
  should.be_true(string.contains(go, "ParsingResultNoData{Timestamp: hive.Now()}"))
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
