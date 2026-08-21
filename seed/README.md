# The seed

Hive builds Hive, so a checkout needs one compiler to make the next one. This
directory says **which** one — and nothing more than that:

```
pinned.txt      the release, the asset, and its SHA-256
```

There is no binary here. A release asset lives outside the git object store,
where replacing it costs nothing; a committed binary lives in every clone of the
repository forever, and a bootstrap that is refreshed a dozen times would be a
hundred megabytes of compilers nobody will ever run again.

## Building from it by hand

```sh
tag=$(awk '$1=="tag:"{print $2}' seed/pinned.txt)
gh release download "$tag" --pattern hivec-linux-amd64 --dir /tmp
sha256sum -c <(printf '%s  /tmp/hivec-linux-amd64\n' \
  "$(awk '$1=="sha256:"{print $2}' seed/pinned.txt)")

chmod +x /tmp/hivec-linux-amd64
HIVEC=/tmp/hivec-linux-amd64 ./bootstrap    # the release builds src/hivec
./bootstrap                                 # and then src/hivec builds itself
```

The second `./bootstrap` is not optional if you care what you have: the compiler
the release produced is one *it* wrote the Go for, and only the second is built
by the thing in `src/`. `./selfhost` is what proves the two agree.

Any compiler that accepts this source will do — a colleague's, one you
cross-compiled, an older release. `HIVEC=` is how you name it.

## Advancing it

Every push to `master` runs [the build workflow](../.github/workflows/build.yml),
which cross-compiles the compiler for six platforms and keeps them as an
artifact. Pushing a **tag** publishes those same binaries as a release, with a
`SHA256SUMS` beside them. To make that release the new seed:

1. take the tag and the `hivec-linux-amd64` line out of its `SHA256SUMS`,
2. put them in `pinned.txt`,
3. commit — two lines, and the next build bootstraps from the new one.

There is no hurry to do it often. A seed only has to be new enough to accept the
source it is asked to compile, and the language changes far less often than the
compiler does.

## Why not the generated Go

It would work: `hive build` leaves a complete Go module in
`src/hivec.hive-build`, and `go build` over it needs no Hive at all. It is also
two and a half megabytes of generated source that would have to be regenerated
and reviewed on every change, and it would say nothing a pinned binary does not.
