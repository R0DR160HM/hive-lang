//// Turns what the Go toolchain said about a test run into what Hive says.
////
//// `hive test` does not implement a test runner. `go test` already isolates each
//// test, keeps going after a failure, filters by name, times what it ran and
//// instruments the code for coverage — so the job here is translation, not
//// mechanism: read its `-v` output and its coverage profile, and report both in
//// the program's own terms.
////
//// Two things need translating, and they are the two places the Go layer would
//// otherwise show through:
////
////   * **Names.** Go slugifies a subtest name (`an empty cart` becomes
////     `an_empty_cart`), and flattening renamed every imported declaration. Both
////     are undone here, against the names the compiler was given.
////   * **Positions.** A coverage profile speaks in lines of the generated
////     `main.go`. Rather than make those lines *be* Hive lines — they cannot be,
////     since a declaration's Go is not the same length as its Hive — each
////     declaration is located in the finished file by its own `func` line. That
////     is exact, and it survives `gofmt` having reformatted everything first.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import hive/ast

/// How one test turned out.
pub type Outcome {
  Passed
  Failed
}

pub type TestResult {
  TestResult(name: String, outcome: Outcome, detail: List(String))
}

/// What a run amounted to: every test in the order it was declared, plus what
/// share of the program it exercised.
pub type Report {
  Report(results: List(TestResult), coverage: Option(Coverage))
}

pub type Coverage {
  Coverage(
    covered: Int,
    total: Int,
    /// Declarations no test reached at all, as the author named them.
    untouched: List(String),
    /// Per file, as the author named it: covered and total statements.
    files: List(#(String, Int, Int)),
  )
}

// ---------------------------------------------------------------------------
// Test results
// ---------------------------------------------------------------------------

/// Read `go test -v` output into one entry per test.
///
/// The shape being read is stable and small: `=== RUN TestHive/<slug>` opens a
/// test, lines indented under it are its output, and a trailing block of
/// `--- PASS/FAIL: TestHive/<slug>` says how each ended. Everything else — the
/// parent test's own line, `ok`/`FAIL` package lines, the coverage line — belongs
/// to the Go layer and is dropped.
///
/// `names` is the tests as declared, which is both the order to report them in
/// and the only way back from a slug to the name someone wrote.
pub fn parse_results(output: String, names: List(String)) -> List(TestResult) {
  // `open` is the test whose output is being read: `go test -v` prints a test's
  // log lines between its `=== RUN` and the summary block at the end, and only
  // one test is open at a time.
  let scan =
    list.fold(
      string.split(output, "\n"),
      Scan(open: None, details: dict.new(), outcomes: dict.new()),
      fn(scan, raw) {
        case classify(raw) {
          Opened(slug) -> Scan(..scan, open: Some(slug))
          Ended(slug, outcome) ->
            Scan(..scan, outcomes: dict.insert(scan.outcomes, slug, outcome))
          Detail(text) ->
            case scan.open {
              None -> scan
              Some(slug) -> {
                let so_far = dict.get(scan.details, slug) |> result.unwrap([])
                Scan(
                  ..scan,
                  details: dict.insert(scan.details, slug, [text, ..so_far]),
                )
              }
            }
          Noise -> scan
        }
      },
    )
  // Reported in declaration order rather than the order Go happened to finish
  // them, so two runs of an unchanged suite read the same.
  list.map(names, fn(name) {
    let key = slug(name)
    TestResult(
      name: name,
      // A test Go never reported on never finished — the run was cut short, and
      // an unfinished test is not a passing one.
      outcome: dict.get(scan.outcomes, key) |> result.unwrap(Failed),
      detail: dict.get(scan.details, key) |> result.unwrap([]) |> list.reverse,
    )
  })
}

type Scan {
  Scan(
    open: Option(String),
    details: Dict(String, List(String)),
    outcomes: Dict(String, Outcome),
  )
}

type Line {
  Opened(slug: String)
  Ended(slug: String, outcome: Outcome)
  Detail(text: String)
  Noise
}

const parent = "TestHive"

fn classify(raw: String) -> Line {
  let trimmed = string.trim_start(raw)
  case trimmed {
    "=== RUN " <> rest ->
      case subtest(string.trim(rest)) {
        Some(slug) -> Opened(slug)
        None -> Noise
      }
    "--- PASS: " <> rest ->
      case subtest(first_word(rest)) {
        Some(slug) -> Ended(slug, Passed)
        None -> Noise
      }
    "--- FAIL: " <> rest ->
      case subtest(first_word(rest)) {
        Some(slug) -> Ended(slug, Failed)
        None -> Noise
      }
    "=== " <> _ -> Noise
    // A log line from a test, which `go test -v` indents under it.
    _ ->
      case raw != trimmed && !is_package_line(trimmed) {
        True -> Detail(string.trim_end(raw))
        False -> Noise
      }
  }
}

// The lines Go prints about the *package* rather than about a test.
fn is_package_line(trimmed: String) -> Bool {
  trimmed == "PASS"
  || trimmed == "FAIL"
  || string.starts_with(trimmed, "ok ")
  || string.starts_with(trimmed, "ok\t")
  || string.starts_with(trimmed, "FAIL\t")
  || string.starts_with(trimmed, "coverage:")
  || string.starts_with(trimmed, "--- ")
}

// `TestHive/an_empty_cart` -> the slug. Anything that is not one of this file's
// subtests (the parent's own line, another package's test) is not ours.
fn subtest(text: String) -> Option(String) {
  case string.split_once(text, "/") {
    Ok(#(head, slug)) if head == parent -> Some(slug)
    _ -> None
  }
}

fn first_word(text: String) -> String {
  case string.split_once(string.trim(text), " ") {
    Ok(#(word, _)) -> word
    Error(_) -> string.trim(text)
  }
}

/// How Go names a subtest: spaces become underscores. Nothing else in a Hive test
/// name is rewritten, so this is the whole of it.
pub fn slug(name: String) -> String {
  string.replace(name, " ", "_")
}

// ---------------------------------------------------------------------------
// Coverage
// ---------------------------------------------------------------------------

/// Read a Go coverage profile against the generated `main.go` it describes.
///
/// A profile line is `<pkg>/<file>:<startL>.<startC>,<endL>.<endC> <stmts>
/// <count>`. `stmts` is how many statements the block holds and `count` how many
/// times it ran, so covered/total is a statement count and needs no line
/// arithmetic — the lines are only used to decide which declaration a block
/// belongs to.
pub fn parse_coverage(
  profile: String,
  main_go: String,
  origins: Dict(String, ast.Origin),
) -> Option(Coverage) {
  let spans = spans_of(main_go, origins)
  let blocks =
    string.split(profile, "\n")
    |> list.filter_map(parse_block)
  // Only what the program declared. The generated file also holds clone helpers,
  // ordering helpers, the atom table and JSON marshalling — none of it written by
  // anyone, so none of it something a test can be said to have missed.
  let blocks =
    list.filter(blocks, fn(b) {
      list.any(spans, fn(span) {
        let #(_, _, start, end) = span
        b.line >= start && b.line <= end
      })
    })
  case blocks {
    [] -> None
    _ -> {
      let covered = sum(list.filter(blocks, fn(b) { b.count > 0 }))
      let total = sum(blocks)
      // A declaration is untouched when nothing in it ever ran. One whose every
      // block is a single unconditional line still has a block, so a declaration
      // with no blocks at all is one the instrumenter found nothing in — not one
      // that went unexercised.
      let untouched =
        spans
        |> list.filter_map(fn(span) {
          let #(name, _file, start, end) = span
          let own = list.filter(blocks, fn(b) { b.line >= start && b.line <= end })
          case own != [] && list.all(own, fn(b) { b.count == 0 }) {
            True -> Ok(name)
            False -> Error(Nil)
          }
        })
        |> list.unique
      Some(Coverage(covered, total, untouched, per_file(spans, blocks)))
    }
  }
}

fn per_file(
  spans: List(#(String, String, Int, Int)),
  blocks: List(Block),
) -> List(#(String, Int, Int)) {
  let files =
    spans |> list.map(fn(s) { s.1 }) |> list.filter(fn(f) { f != "" }) |> list.unique
  list.filter_map(files, fn(file) {
    let own =
      spans
      |> list.filter(fn(s) { s.1 == file })
      |> list.flat_map(fn(s) {
        let #(_, _, start, end) = s
        list.filter(blocks, fn(b) { b.line >= start && b.line <= end })
      })
    case own {
      [] -> Error(Nil)
      _ ->
        Ok(#(file, sum(list.filter(own, fn(b) { b.count > 0 })), sum(own)))
    }
  })
}

type Block {
  Block(line: Int, stmts: Int, count: Int)
}

fn sum(blocks: List(Block)) -> Int {
  list.fold(blocks, 0, fn(acc, b) { acc + b.stmts })
}

fn parse_block(raw: String) -> Result(Block, Nil) {
  // `mode: set` heads the profile and names no block.
  use #(position, rest) <- result.try(string.split_once(string.trim(raw), " "))
  use #(stmts_text, count_text) <- result.try(string.split_once(rest, " "))
  use #(_, range) <- result.try(string.split_once(position, ":"))
  use #(from, _) <- result.try(string.split_once(range, ","))
  use #(line_text, _) <- result.try(string.split_once(from, "."))
  use line <- result.try(int.parse(line_text))
  use stmts <- result.try(int.parse(stmts_text))
  use count <- result.try(int.parse(string.trim(count_text)))
  Ok(Block(line, stmts, count))
}

/// Where each of the program's declarations sits in the generated `main.go`, as
/// `#(written name, file, first line, last line)`.
///
/// Found by reading the file rather than by remembering how it was written: a
/// declaration is a `func <name>(` at column 1 and ends at the closing `}` at
/// column 1. The generated helpers (clone, ordering, atom setup, JSON) are `func`s
/// too and are skipped, since only a name the program declared is in `origins`.
pub fn spans_of(
  main_go: String,
  origins: Dict(String, ast.Origin),
) -> List(#(String, String, Int, Int)) {
  let lines = string.split(main_go, "\n")
  let #(spans, open) =
    list.index_fold(lines, #([], None), fn(acc, raw, index) {
      let #(spans, open) = acc
      let number = index + 1
      case open, raw {
        // A declaration ends at the closing brace in column 1.
        Some(#(written, file, start)), "}" -> #(
          [#(written, file, start, number), ..spans],
          None,
        )
        _, _ ->
          case func_name(raw) {
            Some(flat) ->
              case dict.get(origins, flat) {
                Ok(ast.Origin(written, file)) -> #(
                  spans,
                  Some(#(written, file, number)),
                )
                // A generated helper, not one of the program's own.
                Error(_) -> #(spans, None)
              }
            None -> #(spans, open)
          }
      }
    })
  // A file that does not end in a closing brace is not Go, but the fold has to
  // be total either way.
  let spans = case open {
    Some(#(written, file, start)) -> [
      #(written, file, start, list.length(lines)),
      ..spans
    ]
    None -> spans
  }
  list.reverse(spans)
}

// `func total(v []int) int {` -> `total`.
fn func_name(raw: String) -> Option(String) {
  case raw {
    "func " <> rest ->
      case string.split_once(rest, "(") {
        Ok(#(name, _)) ->
          case string.trim(name) {
            "" -> None
            trimmed -> Some(trimmed)
          }
        Error(_) -> None
      }
    _ -> None
  }
}

/// Shorten every file in a report to its path relative to `dir`.
///
/// A file arrives named the way the compiler was given it, and the entrypoint is
/// resolved to an absolute path before anything else happens — so left alone, a
/// coverage summary is mostly the reader's own home directory.
pub fn relative_to(report: Report, dir: String) -> Report {
  case report.coverage {
    None -> report
    Some(coverage) ->
      Report(
        ..report,
        coverage: Some(
          Coverage(
            ..coverage,
            files: list.map(coverage.files, fn(entry) {
              let #(file, covered, total) = entry
              #(strip_prefix(file, dir), covered, total)
            }),
          ),
        ),
      )
  }
}

fn strip_prefix(file: String, dir: String) -> String {
  case dir {
    "" | "." -> file
    _ ->
      case string.starts_with(file, dir <> "/") {
        True -> string.drop_start(file, string.length(dir) + 1)
        False -> file
      }
  }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// The whole report as `hive test` prints it.
pub fn render(report: Report) -> String {
  let lines =
    list.flat_map(report.results, fn(r) {
      let head = case r.outcome {
        Passed -> "  PASS  " <> r.name
        Failed -> "  FAIL  " <> r.name
      }
      [head, ..list.map(r.detail, fn(d) { "        " <> dedent(d) })]
    })
  let passed =
    list.length(list.filter(report.results, fn(r) { r.outcome == Passed }))
  let total = list.length(report.results)
  let tally =
    "  "
    <> int.to_string(total)
    <> plural(total, " test", " tests")
    <> ": "
    <> int.to_string(passed)
    <> " passed"
    <> case total - passed {
      0 -> ""
      n -> ", " <> int.to_string(n) <> " failed"
    }
  string.join(
    list.flatten([lines, [""], [tally], coverage_lines(report.coverage)]),
    "\n",
  )
  <> "\n"
}

// `go test -v` indents a test's log lines by four spaces per nesting level, and
// a message's own continuation lines are indented further still. Only the
// runner's indentation is dropped, so `left:`/`right:` stay under their `assert`.
fn dedent(line: String) -> String {
  let bare = case line {
    "        " <> rest -> rest
    "    " <> rest -> rest
    _ -> string.trim_start(line)
  }
  strip_generated_position(bare)
}

// Go stamps each log line with where it was written. For an `assert` that is a
// `//line`-remapped `.hive` position and belongs in the output; for anything the
// generator emitted on its own it is a file the reader has no reason to know
// about, so the position goes and the message stays.
fn strip_generated_position(line: String) -> String {
  case string.split_once(line, ": ") {
    Ok(#(position, rest)) ->
      case
        string.starts_with(position, "main.go:")
        || string.starts_with(position, "main_test.go:")
      {
        True -> rest
        False -> line
      }
    Error(_) -> line
  }
}

fn coverage_lines(coverage: Option(Coverage)) -> List(String) {
  case coverage {
    // Only when the toolchain gave us no profile at all; a program whose every
    // statement went unrun still has one.
    None -> []
    Some(Coverage(covered, total, untouched, files)) -> {
      let head =
        "  coverage: "
        <> percent(covered, total)
        <> " of statements ("
        <> int.to_string(covered)
        <> "/"
        <> int.to_string(total)
        <> ")"
      let per_file = case files {
        [_] -> []
        _ ->
          list.map(files, fn(entry) {
            let #(file, c, t) = entry
            "      " <> file <> " " <> percent(c, t)
          })
      }
      let never = case untouched {
        [] -> []
        _ -> [
          "  never exercised: " <> string.join(list.sort(untouched, string.compare), ", "),
        ]
      }
      list.flatten([[head], per_file, never])
    }
  }
}

fn percent(covered: Int, total: Int) -> String {
  case total {
    0 -> "100%"
    _ -> {
      let share = int.to_float(covered) *. 100.0 /. int.to_float(total)
      float.to_string(round1(share)) <> "%"
    }
  }
}

// One decimal place, so a suite that gains a statement can be seen to have.
fn round1(x: Float) -> Float {
  int.to_float(float.round(x *. 10.0)) /. 10.0
}

fn plural(n: Int, one: String, many: String) -> String {
  case n {
    1 -> one
    _ -> many
  }
}
