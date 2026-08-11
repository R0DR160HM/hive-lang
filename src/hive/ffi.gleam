//// Reading an imported Go file, so Hive can call what it exports.
////
//// `import ./util.go` is not a Hive module: nothing in the file is Hive, and
//// what Hive gets from it is the **signatures** of the functions it exports. The
//// Go toolchain is what reads them — a small program (`godecl`, written into the
//// compiler's cache the first time it is needed) parses the file with Go's own
//// parser and prints one line per declaration. Guessing at Go's grammar from
//// here would be a second, worse Go parser.
////
//// Each exported function becomes an `ast.ForeignDecl`: an ordinary `func` with
//// a Hive signature, so every call to it is checked like any other. Each
//// exported struct it mentions becomes an ordinary `ast.TypeDecl`, so
//// `util.Point` is constructed, annotated and matched like a type the program
//// wrote itself.
////
//// The boundary is deliberately narrow, and everything outside it is a compile
//// error naming the parameter it could not take:
////
////     string           <-> Str
////     int              <-> Int          (int64 is rejected: Hive's Int *is* Go's int)
////     float64          <-> Float
////     bool             <-> Bool
////     []T              <-> T[dyn]
////     map[K]V          <-> hive.map.Map<K, T>   (K a scalar)
////     a struct in the file <-> a Hive type mirroring it
////     (T, error)        -> Result<T, Str>
////     error             -> Result<Bool, Str>
////
//// The narrowness is the point: every type here has the same shape on both
//// sides, so the wrapper codegen emits copies rather than translations, and
//// nothing crosses that Hive could not have made itself.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import filepath
import shellout
import simplifile
import hive/ast
import hive/imports
import hive/naming

/// What one Go file contributes: the declarations Hive reaches in it, and the
/// file itself for the build to compile.
pub type Read {
  Read(decls: List(ast.Decl), foreign: ast.Foreign)
}

// One declaration as `godecl` printed it.
type Line {
  Func(name: String, params: List(#(String, String)), results: List(String))
  Struct(name: String, fields: List(#(String, String)))
  Imported(path: String)
  Package(name: String)
}

/// Read `path` (a `.go` file) and return what Hive can reach in it. `display` is
/// how the file is named in messages.
pub fn read(path: String, display: String) -> Result(Read, String) {
  use text <- result.try(run_godecl(path, display))
  let lines = parse(text)
  let package_name = package_of(path)
  let structs = list.filter_map(lines, as_struct)
  use types <- result.try(
    list.try_map(structs, fn(s) { mirror(s, structs, display) }),
  )
  use funcs <- result.try(
    list.filter_map(lines, as_func)
    |> list.try_map(fn(f) { foreign_fn(f, structs, package_name, display) }),
  )
  use _ <- result.try(case funcs {
    [] ->
      Error(
        display
        <> " exports no functions, so there is nothing in it to call. Go exports "
        <> "a name by capitalising it — `func Slugify(...)` is reachable and "
        <> "`func slugify(...)` is the file's own.",
      )
    _ -> Ok(Nil)
  })
  let third_party =
    lines
    |> list.filter_map(as_import)
    |> list.any(is_third_party)
  Ok(Read(
    list.append(types, funcs),
    ast.Foreign(
      path,
      package_name,
      list.map(structs, fn(s) { #(s.0, s.0) }),
      third_party,
    ),
  ))
}

// ---------------------------------------------------------------------------
// Mapping Go types onto Hive ones
// ---------------------------------------------------------------------------

// One exported struct: its name and its fields as Go rendered them.
type StructInfo =
  #(String, List(#(String, String)))

fn as_struct(line: Line) -> Result(StructInfo, Nil) {
  case line {
    Struct(name, fields) -> Ok(#(name, fields))
    _ -> Error(Nil)
  }
}

fn as_func(
  line: Line,
) -> Result(#(String, List(#(String, String)), List(String)), Nil) {
  case line {
    Func(name, params, results) -> Ok(#(name, params, results))
    _ -> Error(Nil)
  }
}

fn as_import(line: Line) -> Result(String, Nil) {
  case line {
    Imported(path) -> Ok(path)
    _ -> Error(Nil)
  }
}

// A struct in the file, mirrored as a Hive type of the same name and shape. The
// two are the same struct on both sides — same field names, same field types —
// which is what lets the generated converter be a field-by-field copy.
fn mirror(
  info: StructInfo,
  structs: List(StructInfo),
  display: String,
) -> Result(ast.Decl, String) {
  let #(name, fields) = info
  use _ <- result.try(
    naming.check(naming.Type, name)
    |> result.map_error(fn(_) {
      "the struct `"
      <> name
      <> "` in "
      <> display
      <> " cannot be a Hive type: a type is PascalCase here, and this name is "
      <> "not something Hive can spell."
    }),
  )
  use mapped <- result.try(
    list.try_map(fields, fn(field) {
      let #(field_name, go_type) = field
      use typ <- result.try(
        hive_type(go_type, structs)
        |> result.map_error(fn(why) {
          "the field `"
          <> field_name
          <> "` of `"
          <> name
          <> "` in "
          <> display
          <> " "
          <> why
          <> " A struct only crosses the boundary when every one of its fields "
          <> "does."
        }),
      )
      // Go exports a field by capitalising it, and a Hive field is camelCase, so
      // the name is lowered exactly as a function's is.
      let lowered = lower_initial(field_name)
      use _ <- result.try(
        naming.check(naming.Field, lowered)
        |> result.map_error(fn(_) {
          "the field `"
          <> field_name
          <> "` of `"
          <> name
          <> "` in "
          <> display
          <> " cannot be reached from Hive: `"
          <> lowered
          <> "` is not a name Hive can spell."
        }),
      )
      Ok(ast.Field(lowered, typ, False))
    }),
  )
  Ok(ast.TypeDecl(name, [], mapped))
}

// One exported function, as the `func` Hive calls.
fn foreign_fn(
  decl: #(String, List(#(String, String)), List(String)),
  structs: List(StructInfo),
  package_name: String,
  display: String,
) -> Result(ast.Decl, String) {
  let #(symbol, params, results) = decl
  let name = lower_initial(symbol)
  use _ <- result.try(
    naming.check(naming.Callable, name)
    |> result.map_error(fn(_) {
      "`"
      <> symbol
      <> "` in "
      <> display
      <> " cannot be called from Hive: a callable is camelCase here, so the name "
      <> "is reached with its first letter lowered — and `"
      <> name
      <> "` is not a name Hive can spell."
    }),
  )
  use mapped <- result.try(
    list.try_map(params, fn(param) {
      let #(param_name, go_type) = param
      use typ <- result.try(
        hive_type(go_type, structs)
        |> result.map_error(fn(why) {
          "the parameter `"
          <> param_name
          <> "` of `"
          <> symbol
          <> "` in "
          <> display
          <> " "
          <> why
        }),
      )
      let lowered = lower_initial(param_name)
      use _ <- result.try(
        naming.check(naming.Parameter, lowered)
        |> result.map_error(fn(_) {
          "the parameter `"
          <> param_name
          <> "` of `"
          <> symbol
          <> "` in "
          <> display
          <> " cannot be named in Hive, where a parameter is camelCase. Rename "
          <> "it in the Go file."
        }),
      )
      Ok(ast.Field(lowered, typ, False))
    }),
  )
  use ret <- result.try(hive_result(results, structs, symbol, display))
  Ok(ast.ForeignDecl(
    name,
    mapped,
    ret,
    package_name,
    symbol,
    list.length(results),
  ))
}

// What a Go function answers with, as a Hive return type.
//
// Go's second return value is how it reports a failure, and Hive's is a
// `Result`, so the two are the same idea and the mapping says so. What a Go
// `error` carries is a string and nothing else — `err.Error()` — so that is the
// error payload: `Result<T, Str>`.
fn hive_result(
  results: List(String),
  structs: List(StructInfo),
  symbol: String,
  display: String,
) -> Result(ast.TypeExpr, String) {
  case results {
    [] -> Ok(ast.TVoid)
    // A lone `error` is a Go function that either worked or did not. `Ok(true)`
    // is what "it worked" looks like when there was nothing to hand back.
    ["error"] -> Ok(result_of(ast.TName(None, "Bool", [], []), []))
    [only] -> {
      use typ <- result.try(
        hive_type(only, structs)
        |> result.map_error(fn(why) {
          "what `" <> symbol <> "` in " <> display <> " answers with " <> why
        }),
      )
      Ok(typ)
    }
    [value, "error"] -> {
      use typ <- result.try(
        hive_type(value, structs)
        |> result.map_error(fn(why) {
          "what `" <> symbol <> "` in " <> display <> " answers with " <> why
        }),
      )
      Ok(result_of(typ, []))
    }
    _ ->
      Error(
        "`"
        <> symbol
        <> "` in "
        <> display
        <> " answers with "
        <> int.to_string(list.length(results))
        <> " values, and a Hive call answers with one. Go's two-value form is the "
        <> "exception, because `(T, error)` is what a `Result<T, Str>` already "
        <> "means. For anything else, return a struct — every field of it crosses "
        <> "the boundary, and Hive reads it as a type of its own.",
      )
  }
}

fn result_of(ok: ast.TypeExpr, dims: List(ast.Dim)) -> ast.TypeExpr {
  ast.TName(None, "Result", [ok, ast.TName(None, "Str", [], [])], dims)
}

// A Go type as the Hive type it is the same shape as, or why it is not one. The
// message is a clause, so callers can put the parameter it belongs to in front.
fn hive_type(
  go_type: String,
  structs: List(StructInfo),
) -> Result(ast.TypeExpr, String) {
  case go_type {
    "string" -> Ok(plain("Str"))
    "int" -> Ok(plain("Int"))
    "float64" -> Ok(plain("Float"))
    "bool" -> Ok(plain("Bool"))
    // Every other numeric type is a different width from Hive's, and converting
    // one silently is how a value quietly stops being the value it was.
    "int8"
    | "int16"
    | "int32"
    | "int64"
    | "uint"
    | "uint8"
    | "uint16"
    | "uint32"
    | "uint64"
    | "byte"
    | "rune" ->
      Error(
        "is a Go `"
        <> go_type
        <> "`, and Hive's `Int` is Go's `int` — the same 64-bit signed integer, "
        <> "not a conversion away from one. Declare it `int` in the Go file; "
        <> "converting a narrower or unsigned type here would change values "
        <> "without saying so.",
      )
    "float32" ->
      Error(
        "is a Go `float32`, and Hive's `Float` is Go's `float64`. Declare it "
        <> "`float64` in the Go file, so no precision is lost at the boundary.",
      )
    "error" ->
      Error(
        "is a Go `error`, which is how a Go function reports failure rather than "
        <> "a value that travels. It is read as the error half of a `Result` when "
        <> "it is the *last* thing the function answers with, and nowhere else.",
      )
    _ ->
      case string.starts_with(go_type, "[]"), map_parts(go_type) {
        True, _ -> {
          use inner <- result.try(hive_type(
            string.drop_start(go_type, 2),
            structs,
          ))
          vector_of(inner)
        }
        False, Some(#(key, value)) -> {
          use key_type <- result.try(map_key(key, structs))
          use value_type <- result.try(hive_type(value, structs))
          Ok(ast.TName(
            Some("hive.map"),
            "Map",
            [key_type, value_type],
            [],
          ))
        }
        False, None ->
          case string.starts_with(go_type, "unsupported(") {
            True -> Error(unsupported_reason(go_type))
            False ->
              case list.any(structs, fn(s) { s.0 == go_type }) {
                True -> Ok(plain(go_type))
                False ->
                  Error(
                    "is a `"
                    <> go_type
                    <> "`, which this file does not export as a struct. Only a "
                    <> "struct declared and exported in the imported file "
                    <> "crosses the boundary — a type from another package has "
                    <> "no Hive shape to be read as.",
                  )
              }
          }
      }
  }
}

// A vector of something. `[dyn]` is what a Go slice is: a length nothing
// promised, so every index into it is guarded.
fn vector_of(inner: ast.TypeExpr) -> Result(ast.TypeExpr, String) {
  case inner {
    ast.TName(pkg, name, args, dims) ->
      Ok(ast.TName(pkg, name, args, [ast.DimDyn, ..dims]))
    _ ->
      Error(
        "is a slice of something that has no Hive shape, so the slice has none "
        <> "either.",
      )
  }
}

// A map's key is compared and hashed whole on both sides, so it is a scalar. A
// Go map keyed by a struct is legal Go and would be legal Hive, but the order
// its keys come back in is the order they were *set* in — and a Go map has no
// such order to hand over, so they are sorted, and a struct has no sort.
fn map_key(
  go_type: String,
  structs: List(StructInfo),
) -> Result(ast.TypeExpr, String) {
  case go_type {
    "string" | "int" | "float64" | "bool" -> hive_type(go_type, structs)
    _ ->
      Error(
        "is a Go map keyed by `"
        <> go_type
        <> "`, and only a `string`, `int`, `float64` or `bool` key crosses the "
        <> "boundary. A Go map has no order of its own, so its keys arrive "
        <> "sorted — which needs a key that sorts.",
      )
  }
}

// `unsupported(pointer)` -> a clause naming what it was.
fn unsupported_reason(rendered: String) -> String {
  let what =
    rendered
    |> string.replace("unsupported(", "")
    |> string.replace(")", "")
  case what {
    "pointer" ->
      "is a pointer, and a pointer is shared storage — the one thing that cannot "
      <> "cross this boundary, since every value crossing it is copied. Take or "
      <> "return the value itself."
    "variadic" ->
      "is variadic (`...T`), and a Hive call has a fixed parameter list. Take a "
      <> "slice instead, which is what the Go side receives anyway."
    "function" ->
      "is a function value. Hive functions and Go functions are different things "
      <> "at runtime, so neither can be handed to the other; pass the values it "
      <> "would have been called with."
    "channel" ->
      "is a channel, which is shared state Hive has no name for. Hand back what "
      <> "the channel would have carried."
    "interface" | "any" ->
      "is an interface, which says what a value can do rather than what it is — "
      <> "and Hive needs to know what it is to copy it. Take a concrete type."
    "fixed-size array" ->
      "is a fixed-size Go array. Take a slice (`[]T`), which is what a Hive "
      <> "vector is."
    "a type from another package" ->
      "is a type from another package. Only a struct the imported file declares "
      <> "itself crosses the boundary, because that is the only one Hive can see "
      <> "the shape of."
    "unnamed struct" ->
      "is an unnamed struct. Give it a name in the Go file and export it, so "
      <> "Hive has a type to read it as."
    "unexported" ->
      "is unexported, so Hive could neither read it nor set it. Export every "
      <> "field of a struct that crosses the boundary, or keep the struct on the "
      <> "Go side and pass its parts."
    "embedded field" ->
      "is an embedded field. Name it, so the struct has a field Hive can read."
    other -> "is " <> other <> ", which has no Hive shape."
  }
}

fn plain(name: String) -> ast.TypeExpr {
  ast.TName(None, name, [], [])
}

// `map[K]V` split into its two halves, minding a key that is itself a map.
fn map_parts(go_type: String) -> Option(#(String, String)) {
  case string.starts_with(go_type, "map[") {
    False -> None
    True -> {
      let rest = string.drop_start(go_type, 4)
      // The key ends at the `]` that closes the `[` this opened, so nesting is
      // counted rather than assumed away.
      case split_key(string.to_graphemes(rest), 0, []) {
        Some(#(key, value)) -> Some(#(key, value))
        None -> None
      }
    }
  }
}

fn split_key(
  chars: List(String),
  depth: Int,
  taken: List(String),
) -> Option(#(String, String)) {
  case chars {
    [] -> None
    ["]", ..rest] if depth == 0 ->
      Some(#(string.concat(list.reverse(taken)), string.concat(rest)))
    ["]", ..rest] -> split_key(rest, depth - 1, ["]", ..taken])
    ["[", ..rest] -> split_key(rest, depth + 1, ["[", ..taken])
    [c, ..rest] -> split_key(rest, depth, [c, ..taken])
  }
}

/// `Slugify` -> `slugify`: the Go name as Hive spells a callable, a parameter or
/// a field. Go exports by capitalising and Hive names callables in camelCase, so
/// the two differ by exactly this. Two Go names that differ only in their first
/// letter's case cannot both be exported, so nothing collides.
pub fn lower_initial(name: String) -> String {
  case string.to_graphemes(name) {
    [first, ..rest] -> string.lowercase(first) <> string.concat(rest)
    [] -> name
  }
}

// Whether an import path is outside Go's standard library. A standard library
// path has no dot in its first segment — `strings`, `encoding/json` — while
// anything fetched has a host there (`github.com/google/uuid`).
fn is_third_party(path: String) -> Bool {
  case string.split(path, "/") {
    [first, ..] -> string.contains(first, ".")
    [] -> False
  }
}

// ---------------------------------------------------------------------------
// The package a Go file becomes in the generated project
// ---------------------------------------------------------------------------

/// The Go package name an imported file is compiled as inside the generated
/// project — its own directory, so two files never share one, and the alias the
/// generated code imports it under.
///
/// The file's base name makes it readable and a digest of its whole path makes
/// it unique, so two `util.go` from two folders are two packages.
pub fn package_of(path: String) -> String {
  let base =
    path
    |> filepath.base_name
    |> filepath.strip_extension
    |> string.to_graphemes
    |> list.map(fn(c) {
      case is_ident_char(c) {
        True -> string.lowercase(c)
        False -> "_"
      }
    })
    |> string.concat
  "ffi_" <> base <> "_" <> digest(path)
}

fn is_ident_char(c: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
    c,
  )
}

// A short, stable digest of a path (FNV-1a, 32 bits, in hex). It only has to
// tell two paths apart, which is what its every use here asks of it.
fn digest(text: String) -> String {
  text
  |> string.to_graphemes
  |> list.fold(2_166_136_261, fn(hash, c) {
    let code = case string.to_utf_codepoints(c) {
      [point, ..] -> string.utf_codepoint_to_int(point)
      [] -> 0
    }
    let mixed = int.bitwise_exclusive_or(hash, code)
    // × 16777619, kept inside 32 bits.
    int.bitwise_and(mixed * 16_777_619, 4_294_967_295)
  })
  |> int.to_base16
  |> string.lowercase
}

// ---------------------------------------------------------------------------
// Asking the Go toolchain
// ---------------------------------------------------------------------------

// Runs the reader over `path` and returns what it printed.
fn run_godecl(path: String, display: String) -> Result(String, String) {
  use _ <- result.try(
    simplifile.is_file(path)
    |> result.replace_error(Nil)
    |> result.try(fn(yes) {
      case yes {
        True -> Ok(Nil)
        False -> Error(Nil)
      }
    })
    |> result.replace_error(
      "`import` names " <> display <> ", and there is no such file.",
    ),
  )
  use dir <- result.try(install_godecl())
  use absolute <- result.try(absolute(path))
  case
    shellout.command(run: "go", with: ["run", ".", absolute], in: dir, opt: [])
  {
    Ok(output) -> Ok(output)
    Error(#(code, message)) ->
      case code {
        127 ->
          Error(
            "importing a Go file needs the Go toolchain on the PATH, and `go` is "
            <> "not there. It is the same toolchain a build already needs; "
            <> "install it from https://go.dev/dl/.",
          )
        _ ->
          Error(
            "the Go toolchain could not read "
            <> display
            <> ". A Go file has to be valid Go before Hive can call it:\n\n"
            <> message,
          )
      }
  }
}

// Writes the reader into the compiler's cache if it is not already there, and
// answers with its directory. It is written rather than shipped because it has
// to be *compiled* by the toolchain on this machine; after the first run Go's
// build cache makes this near-instant.
fn install_godecl() -> Result(String, String) {
  let dir = filepath.join(imports.hive_dir(), "tool/godecl")
  use _ <- result.try(
    simplifile.create_directory_all(dir)
    |> result.map_error(fn(e) {
      "could not create " <> dir <> ": " <> simplifile.describe_error(e)
    }),
  )
  use _ <- result.try(write_if_changed(
    filepath.join(dir, "go.mod"),
    "module hivegodecl\n\ngo 1.26\n",
  ))
  write_if_changed(filepath.join(dir, "main.go"), godecl_go())
}
// Answers with the directory, so the two writes above read as one step.

fn write_if_changed(path: String, contents: String) -> Result(String, String) {
  let same = simplifile.read(path) == Ok(contents)
  case same {
    True -> Ok(filepath.directory_name(path))
    False ->
      simplifile.write(to: path, contents: contents)
      |> result.map(fn(_) { filepath.directory_name(path) })
      |> result.map_error(fn(e) {
        "could not write " <> path <> ": " <> simplifile.describe_error(e)
      })
  }
}

fn absolute(path: String) -> Result(String, String) {
  case is_absolute(path) {
    True -> Ok(path)
    False ->
      simplifile.current_directory()
      |> result.map(fn(cwd) {
        filepath.join(string.replace(cwd, "\\", "/"), path)
      })
      |> result.map_error(fn(e) {
        "could not resolve the current directory: "
        <> simplifile.describe_error(e)
      })
  }
}

fn is_absolute(path: String) -> Bool {
  case string.starts_with(path, "/"), string.to_graphemes(path) {
    True, _ -> True
    False, [_drive, ":", ..] -> True
    False, _ -> False
  }
}

// ---------------------------------------------------------------------------
// Reading what it printed
// ---------------------------------------------------------------------------

fn parse(text: String) -> List(Line) {
  text
  |> string.replace("\r\n", "\n")
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    case string.split(line, "\t") {
      ["package", name] -> Ok(Package(name))
      ["import", path] -> Ok(Imported(path))
      ["func", name, params, results] ->
        Ok(Func(name, pairs(params), split_nonempty(results, ",")))
      ["type", name, fields] -> Ok(Struct(name, pairs(fields)))
      _ -> Error(Nil)
    }
  })
}

// `s:string|n:int` -> [#("s", "string"), #("n", "int")]
fn pairs(text: String) -> List(#(String, String)) {
  split_nonempty(text, "|")
  |> list.filter_map(fn(part) {
    case string.split_once(part, ":") {
      Ok(pair) -> Ok(pair)
      Error(_) -> Error(Nil)
    }
  })
}

fn split_nonempty(text: String, on: String) -> List(String) {
  case string.trim(text) {
    "" -> []
    trimmed -> string.split(trimmed, on)
  }
}

// ---------------------------------------------------------------------------
// The reader itself
// ---------------------------------------------------------------------------

/// The Go program that reads a Go file. It uses Go's own parser, so what Hive
/// believes a signature says is what Go says it says.
pub fn godecl_go() -> String {
  "// godecl prints what Hive can reach in one Go file: the functions it exports,
// the structs they mention, and what the file imports.
//
// It is written here by the Hive compiler (see hive/ffi.gleam) and run with
// `go run`. The output is one declaration per line, tab-separated, because the
// compiler reading it needs no JSON decoder for this and having one would not
// make it clearer:
//
//     package<TAB>util
//     import<TAB>strings
//     func<TAB>Slugify<TAB>s:string<TAB>string
//     func<TAB>Fetch<TAB>url:string|retries:int<TAB>string,error
//     type<TAB>Point<TAB>X:float64|Y:float64
//
// A type Hive has no shape for is printed as `unsupported(<what>)`, which
// carries none of the separators above — so the line still reads, and the
// compiler can say exactly which parameter it could not take.
package main

import (
	\"fmt\"
	\"go/ast\"
	\"go/parser\"
	\"go/token\"
	\"os\"
	\"strconv\"
	\"strings\"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, \"usage: godecl <file.go>\")
		os.Exit(2)
	}
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, os.Args[1], nil, parser.SkipObjectResolution)
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
	out := &strings.Builder{}
	fmt.Fprintf(out, \"package\\t%s\\n\", file.Name.Name)
	for _, imported := range file.Imports {
		path, err := strconv.Unquote(imported.Path.Value)
		if err != nil {
			continue
		}
		fmt.Fprintf(out, \"import\\t%s\\n\", path)
	}
	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			// A method belongs to its type, and an unexported function is the
			// file's own business.
			if d.Recv != nil || !d.Name.IsExported() {
				continue
			}
			fmt.Fprintf(out, \"func\\t%s\\t%s\\t%s\\n\", d.Name.Name, params(d.Type), results(d.Type))
		case *ast.GenDecl:
			if d.Tok != token.TYPE {
				continue
			}
			for _, spec := range d.Specs {
				ts, ok := spec.(*ast.TypeSpec)
				if !ok || !ts.Name.IsExported() {
					continue
				}
				st, ok := ts.Type.(*ast.StructType)
				if !ok {
					continue
				}
				fmt.Fprintf(out, \"type\\t%s\\t%s\\n\", ts.Name.Name, fields(st))
			}
		}
	}
	fmt.Print(out.String())
}

// params renders a parameter list as `name:type` pairs. A parameter with no name
// of its own is given one, since the Hive side names every parameter.
func params(t *ast.FuncType) string {
	if t.Params == nil {
		return \"\"
	}
	parts := []string{}
	position := 0
	for _, field := range t.Params.List {
		rendered := render(field.Type)
		if len(field.Names) == 0 {
			parts = append(parts, fmt.Sprintf(\"arg%d:%s\", position, rendered))
			position++
			continue
		}
		for _, name := range field.Names {
			parts = append(parts, name.Name+\":\"+rendered)
			position++
		}
	}
	return strings.Join(parts, \"|\")
}

// results renders what a function answers with, in order. Named results are
// counted, not named: what a caller gets is the types.
func results(t *ast.FuncType) string {
	if t.Results == nil {
		return \"\"
	}
	parts := []string{}
	for _, field := range t.Results.List {
		rendered := render(field.Type)
		count := len(field.Names)
		if count == 0 {
			count = 1
		}
		for i := 0; i < count; i++ {
			parts = append(parts, rendered)
		}
	}
	return strings.Join(parts, \",\")
}

// fields renders a struct's fields. An unexported or embedded one is reported as
// what it is rather than skipped: a struct crosses the boundary whole, so the
// compiler has to be able to say why one cannot.
func fields(st *ast.StructType) string {
	parts := []string{}
	for _, field := range st.Fields.List {
		rendered := render(field.Type)
		if len(field.Names) == 0 {
			parts = append(parts, \"embedded:unsupported(embedded field)\")
			continue
		}
		for _, name := range field.Names {
			if !name.IsExported() {
				parts = append(parts, name.Name+\":unsupported(unexported)\")
				continue
			}
			parts = append(parts, name.Name+\":\"+rendered)
		}
	}
	return strings.Join(parts, \"|\")
}

// render is the type as Hive's side reads it. Everything Hive has no shape for
// says so in one token, naming what it was.
func render(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.Ident:
		if t.Name == \"any\" {
			return \"unsupported(interface)\"
		}
		return t.Name
	case *ast.ArrayType:
		if t.Len != nil {
			return \"unsupported(fixed-size array)\"
		}
		return \"[]\" + render(t.Elt)
	case *ast.MapType:
		return \"map[\" + render(t.Key) + \"]\" + render(t.Value)
	case *ast.StarExpr:
		return \"unsupported(pointer)\"
	case *ast.SelectorExpr:
		return \"unsupported(a type from another package)\"
	case *ast.Ellipsis:
		return \"unsupported(variadic)\"
	case *ast.FuncType:
		return \"unsupported(function)\"
	case *ast.ChanType:
		return \"unsupported(channel)\"
	case *ast.InterfaceType:
		return \"unsupported(interface)\"
	case *ast.StructType:
		return \"unsupported(unnamed struct)\"
	}
	return \"unsupported(this type)\"
}
"
}
