# .kkrieger on macOS

A native build of the .kkrieger player for macOS (Apple Silicon and Intel).
It uses only Xcode's clang and the system frameworks. No third-party libraries.

## Build and run

```
cd werkkzeug3_kkrieger/macos
make
./build/kkrieger ../data/kkrieger3383.kx
```

## Status

- Stage 1: content generation. The player loads `data/kkrieger3383.kx` and builds
  all textures, meshes, sounds and the level.
- Stage 2: window (AppKit), keyboard and mouse, sound (AudioQueue with a small
  mixer for the sound effects). The window stays black: there is no renderer yet.

Controls: W/A/S/D, mouse, left button, space. The first click in the window
captures the mouse, switching to another window releases it. Cmd-F toggles
full screen, Cmd-Q quits.

Options:

- `--fullscreen`: start in full screen
- `--headless`: no window and no sound (for tests)
- `--frames n`: run n frames, then exit
- `--press-enter`: press Enter every 0.5 s, which walks through intro and menu
  into the game
- `--dump-textures dir`: write every texture as a TGA file

## What had to change

- `_types.hpp/.cpp`: 64-bit types, x87 assembler replaced with libm,
  printf-style functions use `va_list`.
- Operators are no longer called with an x86 assembler stub (`CallCode` in
  `kdoc.cpp`). `KCallThunk` builds a typed call from each handler's own
  signature. The 5 operators with variable inputs take a pointer to the input
  list instead of `...`.
- Some operators read several by-value parameters as one array (`&s.x` for
  scale, rotate and translate). That only worked with the x86 stack layout.
  These places now copy the parameters into a local array.
- The MMX code of the texture generator is translated instruction by
  instruction with `mmx_emu.hpp`, so the results stay bit-identical.
- `KOp` stored pointers in 32-bit words, and the loader kept a pointer in an
  `int` field. Both are fixed.
- The loader also reads the older export format of `kkrieger3383.kx`
  (no flags word, 8-bit class ids, two operators with fewer parameters).
- Sound: the C++ version of the V2 synth (`../../v2`) through `v2bridge.cpp`.
  The song data is converted from the older synth version on load.
  `V2Synth::init` cleared only `sizeof(this)` bytes, so a second song kept the
  state of the first one and crashed.
- `_start_mac.mm` replaces `_start.cpp`. Fonts use CoreText instead of GDI.
- Compiler flags: `-fno-delete-null-pointer-checks` (the code tests `this`
  against 0) and `-ffp-contract=off` (x87 had no fused multiply-add, and the
  collision code depends on consistent rounding).
