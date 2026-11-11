# What the engine is built from

The engine is linked from other people's work, and a program that draws a
`hive.ui.scene` carries it. Each is used under its own licence:

| | licence | where |
| --- | --- | --- |
| Filament, and the libraries it bundles — abseil, zstd and smol-v among them, and Dawn on Linux | Apache-2.0; the bundled libraries each under their own, which its `third_party/` holds | https://github.com/google/filament |
| miniaudio | public domain, or MIT No Attribution | https://github.com/mackron/miniaudio |
| stb_vorbis | public domain, or MIT | https://github.com/nothings/stb |
| the Emscripten runtime, in the web build | MIT, or University of Illinois/NCSA | https://github.com/emscripten-core/emscripten |

The versions are the ones pinned at the top of [`build`](build).
