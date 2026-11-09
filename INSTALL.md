# Installing Hive

The compiler is one executable, published as `hivec-<os>-<arch>` and installed as
`hive`. It carries the Go it compiles against as source text, so there is nothing
to install beside it: put it on your `PATH`. Every release has one for each
platform Go targets, on the [releases page](../../releases).

| also needed | for |
| --- | --- |
| **Go 1.24+**, on the `PATH` | `build`, `run` and `test`. `check` and `emit` need nothing |
| `git` | an import that names a repository |
| a network | the first build of a program that opens a database or draws a scene; both cache under `~/.hive` |

## Linux and macOS

```sh
chmod +x hivec-linux-amd64
mkdir -p ~/.local/bin && mv hivec-linux-amd64 ~/.local/bin/hive
```

If `~/.local/bin` is not on your `PATH`, add `export PATH="$HOME/.local/bin:$PATH"`
to your shell's startup file.

On macOS, pick `arm64` for Apple silicon and `amd64` for Intel, and clear the
download's quarantine or Gatekeeper refuses it:
`xattr -d com.apple.quarantine ~/.local/bin/hive`.

## Windows

Run [`hive-windows.msi`](../../releases/latest/download/hive-windows.msi). It needs
no administrator: it downloads `hive.exe` for this machine (x64 or Arm64) into
`%LOCALAPPDATA%\Programs\Hive`, or a folder you pick, and adds that folder to your
`PATH` unless it is there already.
When Go 1.24 or newer is missing, it offers to install it as it finishes. If
SmartScreen asks, choose *More info → Run anyway*.

Unattended, with no questions asked: `msiexec /i hive-windows.msi /qn`, adding
`INSTALLFOLDER=D:\Tools\Hive` to choose the folder.

By hand instead, in PowerShell:

```powershell
$dir = "$env:LOCALAPPDATA\Programs\Hive"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Move-Item .\hivec-windows-amd64.exe "$dir\hive.exe"
Unblock-File "$dir\hive.exe"
$user = [Environment]::GetEnvironmentVariable("Path", "User")
[Environment]::SetEnvironmentVariable("Path", "$user;$dir", "User")
```

Open a new terminal afterwards.

## Checking that it worked

```sh
$ hive version
v0.3.3
$ printf 'proc main(): void {\n\techo "it works"\n}\n' > hello.hive
$ hive run hello.hive
it works
```

## Switching versions

`hive use v0.3.4` replaces the compiler with that release's, once it matches the
release's `SHA256SUMS`. It reaches back to v0.3.3, the first release with
`hive use`.

If `run` says `go` is not on the `PATH`, the compiler is installed and Go is not:
[go.dev/dl](https://go.dev/dl/) has it.

## What it reads and writes

| variable | effect |
| --- | --- |
| `PATH` | where `go` and `git` are found |
| `HOME` (`USERPROFILE` on Windows) | where the cache goes: `~/.hive` |
| `HIVE_PROGRESS` | `1` always reports progress, `0` never; unset, only when standard error is a terminal |
| `GOTOOLCHAIN`, `GOFLAGS`, `GOPROXY`, … | Go's own, since a build runs Go |

```
~/.hive/pkg/<repo>@<commit>/   remote imports, cloned once
~/.hive/vendor/three@0.180.0/  the three.js a scene is drawn with
~/.hive/tool/godecl/           the reader for imported Go files
~/.hive/syslink.key            the cluster key hive.syslink nodes share
~/.hive/android.key            the key hive export signs apps with
```

The first three are fetched again if deleted. The keys are not: two nodes must
share one `syslink.key` (or the same `HIVE_SYSLINK_KEY`), and an app signed with a
new `android.key` will not install over one signed with the old.

## Building from source

Hive builds Hive, so `./bootstrap` needs a compiler to start from: `src/hivec` from
an earlier build, or one named with `HIVEC=/path/to/hivec`. A clean checkout
starts from the release [`seed/pinned.txt`](seed/pinned.txt) names, checked
against its digest:

```sh
tag=$(awk '$1=="tag:"{print $2}' seed/pinned.txt)
gh release download "$tag" --pattern hivec-linux-amd64 --dir /tmp
sha256sum -c <(printf '%s  /tmp/hivec-linux-amd64\n' \
  "$(awk '$1=="sha256:"{print $2}' seed/pinned.txt)")

chmod +x /tmp/hivec-linux-amd64
HIVEC=/tmp/hivec-linux-amd64 ./bootstrap    # the release builds src/hivec
./bootstrap                                 # which then builds itself
```

After that, `./hive` (`hive.cmd` on Windows) runs the compiler in `src/`. The
compiler imports a Go file, so even `./hive check src/hivec.hive` needs Go.
[`seed/README.md`](seed/README.md) says how a release becomes the next seed.

### For another platform

A build leaves the Go module it compiled in `src/hivec.hive-build`, so Go can
cross-compile the compiler for anywhere it targets:

```sh
cd src/hivec.hive-build
GOOS=windows GOARCH=amd64 go build -o hivec.exe .
GOOS=darwin  GOARCH=arm64 go build -o hivec-macos-arm64 .
```
