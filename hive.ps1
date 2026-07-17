# Convenience wrapper so you can run, from anywhere:
#
#     .\hive.ps1 build path\to\foo.hive
#     .\hive.ps1 run   path\to\foo.hive
#     .\hive.ps1 emit  path\to\foo.hive
#
# instead of `gleam run -- <args>`. File arguments are resolved to absolute
# paths first, so they keep pointing at the right file after we switch into
# the compiler's own project directory to invoke `gleam`.
#
# NOTE: we deliberately leave $ErrorActionPreference at its default. Under
# 'Stop', Windows PowerShell treats the progress lines `gleam` prints to
# stderr as terminating errors, which would abort the wrapper spuriously.
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# Resolve only entrypoint (*.hive) arguments to absolute paths; leave
# subcommands like `build`/`run` untouched (a bare `build` would otherwise
# collide with Gleam's own build/ directory).
$resolved = @()
foreach ($a in $args) {
  if ($a -like '*.hive' -and (Test-Path -LiteralPath $a)) {
    $resolved += (Resolve-Path -LiteralPath $a).Path
  }
  else {
    $resolved += $a
  }
}

$code = 0
Push-Location $root
try {
  gleam run -- @resolved
  $code = $LASTEXITCODE
}
finally {
  Pop-Location
}
exit $code
