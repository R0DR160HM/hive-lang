//// Build/run orchestration: writes the generated Go project to disk, invokes
//// the Go toolchain, and (for `run`) executes the resulting binary.
////
//// The generated project carries only what the program uses: the core runtime
//// always, and each `hive.*` standard library module only when the compiled
//// code references it (see `needed_modules`). That keeps a program that never
//// opens a socket or a database from compiling — or, for `hive.sql`, from
//// downloading — the machinery behind either.

import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import filepath
import shellout
import simplifile
import hive/ast
import hive/compiler
import hive/runtime
import hive/spawn
import hive/testreport
import hive/vendor

/// Compile `entry` to Go, then build a native executable with the Go compiler.
/// On success returns the path to the produced executable.
pub fn build(entry: String) -> Result(String, String) {
  let entry = normalize(entry)

  use program <- result.try(compiler.compile_program(entry))
  let main_go = program.main_go

  let dir = dir_of(entry)
  let base = filepath.strip_extension(filepath.base_name(entry))
  let build_dir = filepath.join(dir, base <> ".hive-build")
  let goexe = go_exe_suffix()
  let artifact = "app" <> goexe

  use _ <- result.try(prepare_build_dir(build_dir, main_go))
  use _ <- result.try(write_foreign(build_dir, program.foreign))
  use _ <- result.try(resolve_deps(build_dir, main_go, program.foreign))

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
pub fn run(entry: String, program_args: List(String)) -> Result(Int, String) {
  let entry = normalize(entry)

  use program <- result.try(compiler.compile_program(entry))
  let main_go = program.main_go

  let dir = dir_of(entry)
  let base = filepath.strip_extension(filepath.base_name(entry))
  let build_dir = filepath.join(dir, base <> ".hive-build")

  use _ <- result.try(prepare_build_dir(build_dir, main_go))
  use _ <- result.try(write_foreign(build_dir, program.foreign))
  use _ <- result.try(resolve_deps(build_dir, main_go, program.foreign))

  // Best-effort formatting; ignored if gofmt is unavailable.
  let _ = shellout.command(run: "gofmt", with: ["-w", "."], in: build_dir, opt: [])

  use dir_abs <- result.try(absolute(dir))

  // Where this program's input is handed over, for one that reads at all —
  // `hive.term.read()` is what lowers to `hive.TermRead`, and
  // `hive.term.readSecret()` to `hive.TermReadSecret`, which reads through it.
  // Nothing is relayed to a program that never reads. The path is absolute
  // because the program is chdir'd to its own folder before `main` runs.
  let reads_input =
    string.contains(main_go, "hive.TermRead(")
    || string.contains(main_go, "hive.TermReadSecret(")
  let input_relay = case reads_input {
    True ->
      filepath.join(
        filepath.join(dir_abs, base <> ".hive-build"),
        "stdin-relay",
      )
    False -> ""
  }

  // Not `shellout`: it closes the standard input of what it spawns, which
  // leaves `hive.term.read()` reading end of file. See `hive/spawn`.
  Ok(spawn.run(
    "go",
    // `go run . <args>` forwards the trailing arguments to the program, so
    // `hive.term.args()` sees the same list a built binary would.
    list.append(["run", "."], program_args),
    build_dir,
    [#("HIVE_RUN_CWD", dir_abs)],
    input_relay,
  ))
}

/// Compile `entry` together with its tests and run them, reporting what passed
/// and how much of the program was exercised. Returns the rendered report and
/// whether every test passed.
///
/// The runner is `go test`, which the generated project is already set up for:
/// `main_test.go` is the same package as `main.go`, so a test reaches everything
/// the program declares without any of it being exported on purpose. Coverage is
/// not a mode — `-coverprofile` is always passed, because a test run that does
/// not say what it missed has answered half the question.
pub fn run_tests(entry: String) -> Result(#(String, Bool), String) {
  let entry = normalize(entry)

  use build <- result.try(compiler.compile_tests_file(entry))

  let dir = dir_of(entry)
  let base = filepath.strip_extension(filepath.base_name(entry))
  let build_dir = filepath.join(dir, base <> ".hive-build")
  let profile = "coverage.out"

  let both = build.main_go <> build.test_go
  use _ <- result.try(prepare_build_dir_for(build_dir, build.main_go, both))
  use _ <- result.try(write(
    filepath.join(build_dir, "main_test.go"),
    build.test_go,
  ))
  use _ <- result.try(write_foreign(build_dir, build.foreign))
  use _ <- result.try(resolve_deps(build_dir, both, build.foreign))

  // Best-effort formatting; ignored if gofmt is unavailable. The coverage report
  // locates each declaration by reading the finished file, so it does not matter
  // whether this ran.
  let _ = shellout.command(run: "gofmt", with: ["-w", "."], in: build_dir, opt: [])

  // A failing suite is a non-zero exit, which `shellout` reports as an error —
  // and its output is the report. So both outcomes carry output and only a
  // missing toolchain is a real failure; `go test` says so on the first line.
  let outcome =
    shellout.command(
      run: "go",
      with: ["test", "-v", "-coverprofile=" <> profile, "."],
      in: build_dir,
      opt: [],
    )
  use #(output, passed) <- result.try(case outcome {
    Ok(output) -> Ok(#(output, True))
    Error(#(_code, output)) ->
      case looks_like_a_run(output) {
        True -> Ok(#(output, False))
        False ->
          Error("the Go toolchain could not run the tests:\n\n" <> output)
      }
  })

  // Read back what was actually compiled: `gofmt` may have moved every line, and
  // the declaration positions have to match the file the profile describes.
  let compiled =
    simplifile.read(filepath.join(build_dir, "main.go"))
    |> result.unwrap(build.main_go)
  let coverage =
    simplifile.read(filepath.join(build_dir, profile))
    |> result.map(fn(text) {
      testreport.parse_coverage(text, compiled, build.origins)
    })
    |> result.unwrap(None)

  let report =
    testreport.Report(
      testreport.parse_results(output, build.test_names),
      coverage,
    )
  use dir_abs <- result.try(absolute(dir))
  Ok(#(testreport.render(testreport.relative_to(report, dir_abs)), passed))
}

// Whether output came from a suite that ran (and failed) rather than from a
// toolchain that could not start one. A run always reports on the package it
// built, whatever the tests did.
fn looks_like_a_run(output: String) -> Bool {
  string.contains(output, "--- FAIL")
  || string.contains(output, "=== RUN")
  || string.contains(output, "FAIL\t")
}

// Each imported Go file, copied into the generated project as a package of its
// own — the directory being the name the generated code imports it under. It is
// copied rather than referred to so the build stays self-contained: what
// compiled is in the build directory, whether the file came from next door or
// out of a clone of somebody's repository.
fn write_foreign(
  build_dir: String,
  foreign: List(ast.Foreign),
) -> Result(Nil, String) {
  use _ <- result.try(remove_stale_foreign(build_dir, foreign))
  list.try_fold(foreign, Nil, fn(_, f) {
    let dir = filepath.join(build_dir, f.package_name)
    use _ <- result.try(mkdir(dir))
    use source <- result.try(
      simplifile.read(f.file)
      |> result.map_error(fn(e) {
        "could not read the imported Go file "
        <> f.file
        <> ": "
        <> simplifile.describe_error(e)
      }),
    )
    write(filepath.join(dir, filepath.base_name(f.file)), source)
  })
  |> result.map(fn(_) { Nil })
}

// A package left behind by an earlier build in this same directory, whose import
// the program no longer has. Nothing would compile it — `go build .` builds the
// main package — but `go mod tidy` reads every package it finds, so one whose own
// dependencies are gone would fail a build that has nothing to do with it.
fn remove_stale_foreign(
  build_dir: String,
  foreign: List(ast.Foreign),
) -> Result(Nil, String) {
  let wanted = list.map(foreign, fn(f) { f.package_name })
  case simplifile.read_directory(build_dir) {
    // Nothing read means nothing to clean: the directory is about to be created.
    Error(_) -> Ok(Nil)
    Ok(entries) ->
      entries
      |> list.filter(fn(entry) {
        string.starts_with(entry, "ffi_") && !list.contains(wanted, entry)
      })
      |> list.try_fold(Nil, fn(_, entry) {
        simplifile.delete_all([filepath.join(build_dir, entry)])
        |> result.map_error(fn(e) {
          "could not remove the stale "
          <> entry
          <> " in "
          <> build_dir
          <> ": "
          <> simplifile.describe_error(e)
        })
      })
      |> result.map(fn(_) { Nil })
  }
}

// A build that links anything from outside the standard library has to resolve
// it before the toolchain runs: `hive.sql`'s drivers, and whatever an imported
// Go file imports for itself. Everything else stays dependency-free and offline.
fn resolve_deps(
  build_dir: String,
  main_go: String,
  foreign: List(ast.Foreign),
) -> Result(Nil, String) {
  let sql = list.contains(runtime.needed_modules(main_go), "sql")
  let go_deps = list.any(foreign, fn(f) { f.third_party })
  case sql || go_deps {
    True ->
      shellout.command(run: "go", with: ["mod", "tidy"], in: build_dir, opt: [])
      |> result.map_error(fn(failure) {
        let #(_code, message) = failure
        case go_deps {
          True ->
            "could not resolve what the imported Go files depend on (this needs "
            <> "network access on the first build):\n\n"
            <> message
          False ->
            "could not resolve the SQL driver dependencies (this needs network "
            <> "access on the first build):\n\n"
            <> message
        }
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
  compiler.compile_file(normalize(entry))
}

/// Run every check on `entry` and throw the generated Go away, which is all an
/// editor asking "is this file good?" needs. It skips the Go toolchain
/// altogether — no build directory, no `go build`, nothing written next to the
/// entrypoint — so it answers in the time the Hive passes take on their own.
pub fn check(entry: String) -> Result(Nil, String) {
  compiler.check_file(normalize(entry))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn prepare_build_dir(build_dir: String, main_go: String) -> Result(Nil, String) {
  prepare_build_dir_for(build_dir, main_go, main_go)
}

// `references` is the generated Go that decides which standard library modules
// get written. It is `main_go` for a build, and `main.go` *plus* `main_test.go`
// for a test run — a `hive.task.sleep` only a test reaches still has to be there.
fn prepare_build_dir_for(
  build_dir: String,
  main_go: String,
  references: String,
) -> Result(Nil, String) {
  use _ <- result.try(mkdir(build_dir))
  use _ <- result.try(mkdir(filepath.join(build_dir, "hive")))
  use _ <- result.try(write(filepath.join(build_dir, "go.mod"), runtime.go_mod()))
  use _ <- result.try(write(filepath.join(build_dir, "main.go"), main_go))
  use _ <- result.try(write(
    filepath.join(build_dir, "hive/runtime.go"),
    runtime.runtime_go(),
  ))
  // Each standard library module is written only when the program actually
  // reaches for it, and any module file left over from an earlier build in this
  // same directory is removed. Everything under `hive/` compiles as one Go
  // package, so a stale file would still be built — and a stale `sql.go` would
  // fail outright, since go.mod is regenerated dependency-free on every build.
  // `delete_all` is a no-op when the file is already absent.
  let needed = runtime.needed_modules(references)
  use _ <- result.try(
    list.try_fold(runtime.modules(), Nil, fn(_, module) {
      let path = filepath.join(build_dir, module.file)
      case list.contains(needed, module.name) {
        True -> write(path, module.source())
        False ->
          simplifile.delete_all([path])
          |> result.map_error(fn(e) {
            "could not remove a stale "
            <> path
            <> ": "
            <> simplifile.describe_error(e)
          })
      }
    }),
  )
  // The one module that is not source: a scene is drawn with three.js, which is
  // fetched once and embedded in the executable (see `hive/vendor`). It sits
  // beside `ui_scene.go` because that is the file that embeds it, and it is
  // removed again the moment the program stops drawing — for the same reason a
  // stale module file is.
  let scene_dir = filepath.join(build_dir, "hive")
  case list.contains(needed, "uiscene") {
    True -> vendor.place_three(scene_dir)
    False -> vendor.clear_three(scene_dir)
  }
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
