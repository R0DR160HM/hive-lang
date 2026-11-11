# The scene engine

What draws a `hive.ui.scene`. One C++ program on [Filament](https://github.com/google/filament),
built two ways:

| build | file | who runs it |
| --- | --- | --- |
| native | `hive-scene-windows-amd64.exe`, `hive-scene-linux-amd64` | a window the program draws itself, as a process beside it |
| web | `hive-scene.js`, `hive-scene.wasm` | a page: `webview`, macOS, Android, and any window that fell back to one |

A scene is a value the program packs into a frame (`uiSceneFrame` in
`src/runtime.hive`). The engine is handed each frame and keeps the world it
describes; it knows nothing of Hive, of widgets or of windows.

## Building

```sh
scene/build            # native, for this machine, into ~/.hive/vendor/scene@dev
scene/build web        # the page's
scene/build [web] DIR  # either, left in DIR
```

`scene/build` says what it needs at its top. A compiler built from source embeds
whatever is in `~/.hive/vendor/scene@dev`; a released one fetches its release's
files against digests the workflow wrote into `src/vendor.hive`. `HIVE_SCENE_DIST`
names a directory to take them from instead.

## What is where

```
src/world.*      the world: frames in, pictures out. Everything below serves it
src/shapes.*     the unit geometry of every kind of solid
src/surfaces.*   the nineteen finishes, drawn rather than shipped
src/canvas.*     the little of a 2D canvas those drawings need
src/model.*      a figure's file: a skinned glTF binary
src/sound.*      what a world sounds like, and what hive.audio plays (native; a page uses Web Audio)
src/native.cpp   the process a window starts
src/web.cpp      the functions a page calls
materials/       Filament materials, compiled by matc and baked into the binary
```

## The native engine

Started with no arguments it draws with Vulkan, and with `--opengl` with OpenGL;
the window tries them in that order. Messages go in on standard input and out on
standard output, each a letter, a little-endian `u32` length and that many bytes.
The picture does not go through the pipe: the window names a block of shared
memory, and the engine writes each one into it.

In, from the window:

| | body | |
| --- | --- | --- |
| `S` | a frame, without its leading `S` | the world, or what changed in it |
| `Z` | `u32` sheet wide, tall, drawn wide, tall, then the memory's name | how big the picture is, and where it goes |
| `I` | `u8` count, then `u32` left, top, wide, tall each | where the insets are on the picture |
| `D` | `u32` serial | draw |
| `p` | named path, `u32` wide, tall, RGBA | a picture that was asked for; nought by nought is "there is none" |
| `f` | named path, `u8` found, bytes | a file that was asked for |
| `t` | named id, bytes | a terrain's numbers |
| `l` | named words, named colour, `u32` wide, tall, RGBA | a label, drawn in the window's typeface |
| `V` | `u8` | how loud, of 255 |
| `A` | `u8` what, named stream, the rest | a `hive.audio` stream: 1 opens it at a `u8` volume, 2 is more of its bytes (none: no more are coming), 3 is a new volume, 0 shuts it |
| `Q` | | stop |

Out, to the window:

| | body | |
| --- | --- | --- |
| `R` | | ready |
| `X` | text | could not start |
| `P` | `u32` serial, wide, tall, microseconds | drawn, and in the memory |
| `N` | | that frame was cut from one this never held: send the whole world |
| `C` | | something asked for arrived, and the picture is stale |
| `p` `f` `t` | a path or an id | asking for a picture, a file, a terrain |
| `l` | `u16` length, words, then the colour | asking for a label |
| `a` | a stream's name | that stream has played all it was fed |

"Named" is a `u16` length and that many bytes. Pixels are straight alpha, rows
from the top.

`HIVE_SCENE_RECORD=<file>` keeps everything that came in, and
`hive-scene --replay <file> --times 60 --shot out.ppm` plays it back with no
window: it says how long a frame took as played and standing still, and keeps
the last picture. That is how a change to the engine is measured.

## The web engine

The same world on the page's own canvas, through WebGL 2. `src/web.cpp` exports
what the page's script (`uiSceneJs` in `src/runtime.hive`) calls: `hs_start`,
`hs_frame`, `hs_told`, `hs_sized`, `hs_insets`, `hs_draw`, `hs_stale`, and
`hs_picture`, `hs_file`, `hs_terrain`, `hs_label` for the answers. What it asks
for arrives at `Module.wanted(kind, first, second)`, and is answered between
frames, never from inside the call.

## What it is pinned to

Filament, Emscripten, miniaudio and stb_vorbis, by version and digest at the top
of `scene/build`. Moving one is changing it there.

Two things lean on this Filament in particular, and want looking at when it moves:

- Every engine is built with `material.enable_material_instance_uniform_batching`
  off. With it on, as 1.80 has it, a scene that gave way to another on Vulkan drew
  some materials with another's numbers: a floor all fog, a flag the wrong colour.
- A see-through solid reads `frameUniforms` to work out how bright it will be lit
  (`materials/solid.mat`), which is no part of Filament's promise to a material.
