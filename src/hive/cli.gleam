//// Build/run orchestration: writes the generated Go project to disk, invokes
//// the Go toolchain, and (for `run`) executes the resulting binary.

import gleam/result
import gleam/string
import filepath
import shellout
import simplifile
import hive/compiler
import hive/runtime

/// Compile `entry` to Go, then build a native executable with the Go compiler.
/// On success returns the path to the produced executable.
pub fn build(entry: String) -> Result(String, String) {
  let entry = normalize(entry)

  use source <- result.try(read(entry))
  use main_go <- result.try(compiler.compile(source))

  let dir = dir_of(entry)
  let base = filepath.strip_extension(filepath.base_name(entry))
  let build_dir = filepath.join(dir, base <> ".hive-build")
  let goexe = go_exe_suffix()
  let artifact = "app" <> goexe

  use _ <- result.try(prepare_build_dir(build_dir, main_go))

  // Best-effort formatting; ignored if gofmt is unavailable.
  let _ = shellout.command(run: "gofmt", with: ["-w", "."], in: build_dir, opt: [])

  use _ <- result.try(
    shellout.command(
      run: "go",
      with: ["build", "-o", artifact, "."],
      in: build_dir,
      opt: [],
    )
    |> result.map_error(fn(failure) {
      let #(_code, message) = failure
      "the Go compiler rejected the generated code:\n\n" <> message
    }),
  )

  let dest = filepath.join(dir, base <> goexe)
  use _ <- result.try(
    simplifile.copy_file(at: filepath.join(build_dir, artifact), to: dest)
    |> result.map_error(fn(e) {
      "could not place the executable: " <> simplifile.describe_error(e)
    }),
  )

  // copy_file does not preserve the executable bit.
  use _ <- result.try(
    simplifile.set_permissions_octal(dest, 0o755)
    |> result.map_error(fn(e) {
      "could not mark the executable as runnable: "
      <> simplifile.describe_error(e)
    }),
  )

  Ok(dest)
}

/// Build `entry` and then run the resulting executable, streaming its output.
/// Returns the program's exit status.
pub fn run(entry: String) -> Result(Int, String) {
  let entry = normalize(entry)
  use exe <- result.try(build(entry))

  // Run with the working directory set to the entrypoint's directory so that
  // relative paths in the program (e.g. `using "./test.csv"`) resolve as the
  // author expects. The executable path must be absolute: the spawned process
  // changes into `dir` before exec, so a relative path would no longer
  // resolve.
  let dir = dir_of(entry)
  use exe_abs <- result.try(absolute(exe))

  case
    shellout.command(
      run: exe_abs,
      with: [],
      in: dir,
      opt: [shellout.LetBeStdout, shellout.LetBeStderr],
    )
  {
    Ok(_) -> Ok(0)
    Error(#(code, _)) -> Ok(code)
  }
}

fn absolute(path: String) -> Result(String, String) {
  case string.starts_with(path, "/") {
    True -> Ok(path)
    False ->
      simplifile.current_directory()
      |> result.map(fn(cwd) { filepath.join(normalize(cwd), path) })
      |> result.map_error(fn(e) {
        "could not resolve the current directory: "
        <> simplifile.describe_error(e)
      })
  }
}

/// Compile `entry` and return the generated Go `main.go` source (no build).
pub fn emit(entry: String) -> Result(String, String) {
  use source <- result.try(read(normalize(entry)))
  compiler.compile(source)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn read(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(e) {
    "could not read " <> path <> ": " <> simplifile.describe_error(e)
  })
}

fn prepare_build_dir(build_dir: String, main_go: String) -> Result(Nil, String) {
  use _ <- result.try(mkdir(build_dir))
  use _ <- result.try(mkdir(filepath.join(build_dir, "hive")))
  use _ <- result.try(write(filepath.join(build_dir, "go.mod"), runtime.go_mod()))
  use _ <- result.try(write(filepath.join(build_dir, "main.go"), main_go))
  write(filepath.join(build_dir, "hive/runtime.go"), runtime.runtime_go())
}

fn mkdir(path: String) -> Result(Nil, String) {
  simplifile.create_directory_all(path)
  |> result.map_error(fn(e) {
    "could not create " <> path <> ": " <> simplifile.describe_error(e)
  })
}

fn write(path: String, contents: String) -> Result(Nil, String) {
  simplifile.write(to: path, contents: contents)
  |> result.map_error(fn(e) {
    "could not write " <> path <> ": " <> simplifile.describe_error(e)
  })
}

/// Ask the Go toolchain for the platform's executable suffix (".exe" on
/// Windows, "" elsewhere).
fn go_exe_suffix() -> String {
  case shellout.command(run: "go", with: ["env", "GOEXE"], in: ".", opt: []) {
    Ok(out) -> string.trim(out)
    Error(_) -> ""
  }
}

fn dir_of(entry: String) -> String {
  case filepath.directory_name(entry) {
    "" -> "."
    dir -> dir
  }
}

/// Normalise Windows-style backslashes to forward slashes so the (unix-style)
/// `filepath` helpers and the Go toolchain both handle the path consistently.
fn normalize(path: String) -> String {
  string.replace(path, "\\", "/")
}
