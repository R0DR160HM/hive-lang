//// The Hive compiler CLI.
////
////   hive build <entrypoint.hive>   Compile to a native executable
////   hive run   <entrypoint.hive>   Compile and run
////   hive test  <entrypoint.hive>   Run the program's tests, with coverage
////   hive check <entrypoint.hive>   Report any errors, build nothing
////   hive emit  <entrypoint.hive>   Print the generated Go source

import argv
import gleam/io
import hive/cli
import shellout

pub fn main() {
  case argv.load().arguments {
    ["build", entry] -> do_build(entry)
    // Anything after the entrypoint is forwarded to the program as its own
    // command-line arguments (readable via `hive.term.args()`).
    ["run", entry, ..program_args] -> do_run(entry, program_args)
    ["test", entry] -> do_test(entry)
    ["check", entry] -> do_check(entry)
    ["emit", entry] -> do_emit(entry)

    ["build", ..] | ["check", ..] | ["emit", ..] | ["test", ..] ->
      usage_error("that command takes exactly one entrypoint file")
    _ -> print_usage()
  }
}

fn do_build(entry: String) -> Nil {
  case cli.build(entry) {
    Ok(exe) -> io.println("Compiled " <> entry <> " -> " <> exe)
    Error(message) -> fail(message)
  }
}

fn do_run(entry: String, program_args: List(String)) -> Nil {
  case cli.run(entry, program_args) {
    Ok(0) -> Nil
    Ok(code) -> shellout.exit(code)
    Error(message) -> fail(message)
  }
}

// A failing suite is a failing command: `hive test` is the thing a commit hook or
// a CI step runs, and it has to be able to tell. The report is printed either way
// — it is the answer, not an error message — so it goes to stdout, and only a
// compiler or toolchain failure goes to stderr through `fail`.
fn do_test(entry: String) -> Nil {
  case cli.run_tests(entry) {
    Ok(#(report, passed)) -> {
      io.println(report)
      case passed {
        True -> Nil
        False -> shellout.exit(1)
      }
    }
    Error(message) -> fail(message)
  }
}

fn do_check(entry: String) -> Nil {
  case cli.check(entry) {
    Ok(_) -> io.println("No problems found in " <> entry)
    Error(message) -> fail(message)
  }
}

fn do_emit(entry: String) -> Nil {
  case cli.emit(entry) {
    Ok(go_source) -> io.println(go_source)
    Error(message) -> fail(message)
  }
}

// A compile error is printed exactly as the compiler wrote it — it opens with
// `file:line:`, which is what lets an editor jump to it (see `hive/diagnostic`).
// Prefixing it with anything would put something in front of the file name and
// break that, so the program name is left off.
fn fail(message: String) -> Nil {
  io.println_error(message)
  shellout.exit(1)
}

// Getting the command line wrong is not a diagnostic about anyone's source, so
// this one does say who is complaining.
fn usage_error(message: String) -> Nil {
  io.println_error("hive: " <> message)
  shellout.exit(1)
}

fn print_usage() -> Nil {
  io.println("Hive — a table-based language that compiles to Go")
  io.println("")
  io.println("Usage:")
  io.println("  hive build <entrypoint.hive>   Compile to a native executable")
  io.println("  hive run   <entrypoint.hive>   Compile and run")
  io.println("  hive test  <entrypoint.hive>   Run the program's tests, with coverage")
  io.println("  hive check <entrypoint.hive>   Report any errors, build nothing")
  io.println("  hive emit  <entrypoint.hive>   Print the generated Go source")
}
