//// The Hive compiler CLI.
////
////   hive build <entrypoint.hive>   Compile to a native executable
////   hive run   <entrypoint.hive>   Compile and run
////   hive emit  <entrypoint.hive>   Print the generated Go source

import argv
import gleam/io
import hive/cli
import shellout

pub fn main() {
  case argv.load().arguments {
    ["build", entry] -> do_build(entry)
    ["run", entry] -> do_run(entry)
    ["emit", entry] -> do_emit(entry)

    ["build", ..] | ["run", ..] | ["emit", ..] ->
      fail("that command takes exactly one entrypoint file")
    _ -> print_usage()
  }
}

fn do_build(entry: String) -> Nil {
  case cli.build(entry) {
    Ok(exe) -> io.println("Compiled " <> entry <> " -> " <> exe)
    Error(message) -> fail(message)
  }
}

fn do_run(entry: String) -> Nil {
  case cli.run(entry) {
    Ok(0) -> Nil
    Ok(code) -> shellout.exit(code)
    Error(message) -> fail(message)
  }
}

fn do_emit(entry: String) -> Nil {
  case cli.emit(entry) {
    Ok(go_source) -> io.println(go_source)
    Error(message) -> fail(message)
  }
}

fn fail(message: String) -> Nil {
  io.println_error("hive: " <> message)
  shellout.exit(1)
}

fn print_usage() -> Nil {
  io.println("Hive — a table-based language that compiles to Go")
  io.println("")
  io.println("Usage:")
  io.println("  hive build <entrypoint.hive>   Compile to a native executable")
  io.println("  hive run   <entrypoint.hive>   Compile and run")
  io.println("  hive emit  <entrypoint.hive>   Print the generated Go source")
}
