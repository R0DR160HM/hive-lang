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
  use _ <- result.try(resolve_sql_deps(build_dir, main_go))

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

/// Compile `entry` to Go and run it directly with `go run`, streaming its
/// output. Returns the program's exit status.
///
/// Unlike `build`, this produces no executable next to the entrypoint — `go
/// run` compiles into Go's build cache and runs from there, so a freshly built
/// binary never lands in the project folder (which is what triggers Windows
/// Defender/SmartScreen scans). Because `go run` executes from inside the
/// build directory, the program's working directory is passed through
/// HIVE_RUN_CWD so relative paths (`using "./test.csv"`) still resolve against
/// the entrypoint's folder — the runtime `chdir`s to it before `main`.
pub fn run(entry: String) -> Result(Int, String) {
  let entry = normalize(entry)

  use source <- result.try(read(entry))
  use main_go <- result.try(compiler.compile(source))

  let dir = dir_of(entry)
  let base = filepath.strip_extension(filepath.base_name(entry))
  let build_dir = filepath.join(dir, base <> ".hive-build")

  use _ <- result.try(prepare_build_dir(build_dir, main_go))
  use _ <- result.try(resolve_sql_deps(build_dir, main_go))

  // Best-effort formatting; ignored if gofmt is unavailable.
  let _ = shellout.command(run: "gofmt", with: ["-w", "."], in: build_dir, opt: [])

  use dir_abs <- result.try(absolute(dir))

  case
    shellout.command(
      run: "go",
      with: ["run", "."],
      in: build_dir,
      opt: [
        shellout.LetBeStdout,
        shellout.LetBeStderr,
        shellout.SetEnvironment([#("HIVE_RUN_CWD", dir_abs)]),
      ],
    )
  {
    Ok(_) -> Ok(0)
    Error(#(code, _)) -> Ok(code)
  }
}

// A program that uses `hive.sql` links external Go drivers, so its
// dependencies must be resolved (fetched on first build, then cached) before
// the Go toolchain runs. Programs that don't stay dependency-free and offline.
fn resolve_sql_deps(build_dir: String, main_go: String) -> Result(Nil, String) {
  case uses_sql(main_go) {
    True ->
      shellout.command(run: "go", with: ["mod", "tidy"], in: build_dir, opt: [])
      |> result.map_error(fn(failure) {
        let #(_code, message) = failure
        "could not resolve the SQL driver dependencies (this needs network "
        <> "access on the first build):\n\n"
        <> message
      })
      |> result.map(fn(_) { Nil })
    False -> Ok(Nil)
  }
}

fn absolute(path: String) -> Result(String, String) {
  case is_absolute(path) {
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

/// Whether a (forward-slash-normalised) path is already absolute: a Unix or
/// UNC root (`/...`), or a Windows drive letter (`C:/...`). Only checking for a
/// leading `/` would treat a Windows absolute path as relative and wrongly
/// join it onto the current directory.
fn is_absolute(path: String) -> Bool {
  case string.starts_with(path, "/"), string.to_graphemes(path) {
    True, _ -> True
    False, [_drive, ":", ..] -> True
    False, _ -> False
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
  use _ <- result.try(write(
    filepath.join(build_dir, "hive/runtime.go"),
    runtime.runtime_go(),
  ))
  // The SQL runtime (and its external drivers) is only pulled in on demand.
  case uses_sql(main_go) {
    True -> write(filepath.join(build_dir, "hive/sql.go"), runtime.sql_go())
    False -> Ok(Nil)
  }
}

/// Whether the generated program references the `hive.sql` runtime, which
/// decides if the SQL driver file and its dependencies are needed.
fn uses_sql(main_go: String) -> Bool {
  string.contains(main_go, "hive.Sql")
  || string.contains(main_go, "hive.DatabaseDriver")
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
