//// Spawning the compiled program for `hive run`.
////
//// Everything else the CLI shells out to — `gofmt`, `go build`, `go mod tidy` —
//// goes through `shellout`, which captures the output it wants and needs no
//// input. The program being run is the one exception: it may read from its
//// standard input, and `shellout` closes the standard input of whatever it
//// spawns. A program calling `hive.term.read()` under it sees end of file
//// instead of the line the user typed, so it returns `""` without ever waiting.
////
//// What replaces it does not write down the program's standard input either,
//// because a pipe cannot be given back to the program cleanly. Two things go
//// wrong with one. A port has no half-close, so there is no way to tell the
//// program its input is over — and a program reading past the end of what was
//// piped into `hive run` would wait on a line that is never coming rather than
//// getting the `""` a real end of file gives it. And input the program has not
//// read by the time it exits stays in the pipe, where it is the *write* that
//// fails: the port dies of it, and takes with it the exit status the program
//// was going to report.
////
//// So the input is handed over as a file instead. The CLI copies its own
//// standard input into it as it arrives and marks the end by creating a second
//// file next to it, and the runtime reads from there — see `TermRead` in
//// `hive/runtime`. Nothing is ever written to the program, so nothing can cost
//// it its exit status.

/// Run `command` with `args` inside `dir`, with `env` set on top of the inherited
/// environment, and return the status it exited with (`127` if `command` is not
/// on the PATH).
///
/// The program gets this terminal: its output is carried through as it arrives,
/// what is typed here reaches it through `input_relay`, and its standard error
/// goes straight to ours. So it prompts and waits exactly as it does when its
/// own executable is run from a shell. Blocks until it exits.
///
/// `input_relay` is the path our standard input is copied to for the program to
/// read, passed to it as `HIVE_RUN_STDIN_FILE`; it is deleted again once the
/// program has exited, so what was typed at its prompts is not left behind. Pass
/// `""` for a program with no `hive.term.read()` in it: nothing is relayed, and
/// our own standard input is left untouched for whatever runs next.
@external(erlang, "hive_spawn_ffi", "run")
pub fn run(
  command: String,
  args: List(String),
  dir: String,
  env: List(#(String, String)),
  input_relay: String,
) -> Int
