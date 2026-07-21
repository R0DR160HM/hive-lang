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
// The vector / string builtins (len, bytes, append, join, split)
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

// ---------------------------------------------------------------------------
// Async funcs and virtual threads
// ---------------------------------------------------------------------------

pub fn async_call_is_fire_and_forget_test() {
  let go =
    compile(
      "proc main(): void {\n\tmut x := \"hi\"\n\twork(x)\n\tx = await work(x)\n\techo x\n}\nasync func work(text: Str): Str {\n\treturn text\n}\n",
    )
  // An async func lowers to an ordinary Go function.
  should.be_true(string.contains(go, "func work(text string) string {"))
  // A bare call runs on its own goroutine; `await` is a plain blocking call.
  should.be_true(string.contains(go, "go work(x)"))
  should.be_true(string.contains(go, "x = work(x)"))
}

pub fn non_async_statement_call_has_no_goroutine_test() {
  let go =
    compile(
      "proc main(): void {\n\twork()\n}\nproc work(): void {\n\techo \"x\"\n}\n",
    )
  // Only async calls become goroutines; ordinary proc calls do not.
  should.be_false(string.contains(go, "go work()"))
  should.be_true(string.contains(go, "work()"))
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
      "proc main(): void {\n\thive.http.serve(handler: h, port: 8080)\n}\nproc h(r: hive.HttpRequest): hive.HttpResponse {\n\treturn hive.HttpResponse(200, body: \"ok\", headers: [])\n}\n",
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
// The hive.http standard library
// ---------------------------------------------------------------------------

pub fn http_request_lowers_test() {
  let go =
    compile(
      "proc f(): Str {\n\tr := hive.http.request(hive.HttpRequest(\"GET\", \"http://x\", [], \"\"))\n\tif r is Result.Ok(response) {\n\t\treturn response.body\n\t} else if r is Result.Error(error) {\n\t\treturn error.message\n\t}\n}\nproc main(): void {}\n",
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
      "proc main(): void {\n\thive.http.serve(8080, handle)\n}\nproc handle(request: hive.HttpRequest): hive.HttpResponse {\n\treturn hive.HttpResponse(200, [], request.body)\n}\n",
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

pub fn func_can_use_http_test() {
  // hive.http is I/O, which funcs may now perform.
  let go =
    compile(
      "func f(): Str {\n\tr := hive.http.request(hive.HttpRequest(\"GET\", \"http://x\", [], \"\"))\n\treturn \"x\"\n}\nproc main(): void {}\n",
    )
  should.be_true(string.contains(go, "hive.HttpSend("))
}

pub fn serve_handler_must_match_signature_test() {
  // Wrong parameter type: the handler must take exactly one hive.HttpRequest.
  let result =
    compiler.compile(
      "proc main(): void {\n\thive.http.serve(8080, bad)\n}\nproc bad(x: Int): hive.HttpResponse {\n\treturn hive.HttpResponse(200, [], \"\")\n}\n",
    )
  should.be_error(result)
}

pub fn serve_handler_must_be_a_proc_test() {
  let result =
    compiler.compile(
      "proc main(): void {\n\thive.http.serve(8080, nowhere)\n}\n",
    )
  should.be_error(result)
}

pub fn unknown_http_builtin_is_rejected_test() {
  let result =
    compiler.compile("proc main(): void {\n\thive.http.download(\"x\")\n}\n")
  should.be_error(result)
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
  // hive.json is allowed inside funcs (unlike hive.http).
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
// The shipped code examples must always compile
// ---------------------------------------------------------------------------

pub fn http_example_compiles_test() {
  let assert Ok(src) = simplifile.read("code-examples/3 - HTTP/http.hive")
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
