# .kkrieger on macOS

A native build of the .kkrieger player for macOS (Apple Silicon and Intel).
It uses only Xcode's clang and the system frameworks. No third-party libraries.

## Build and run

```
cd werkkzeug3_kkrieger/macos
make
./build/kkrieger
```

`data/kkrieger3383.kx` is linked into the binary, like the original player had
its data inside the executable. A `.kx` file on the command line is used
instead. The binary is about 630 KB, or about 500 KB after `strip`, data
included. Generating the content takes a few seconds at start.

To play the 2004 beta release, give the player its executable:

```
./build/kkrieger path/to/pno0001.exe
```

The player unpacks the game data from the executable at start. The data is
not in this repository: the release terms allow passing the archive around
only unmodified.

## Status

- Stage 1: content generation. All 5174 operators of the data are calculated
  (1461 of them build bitmaps), which gives all textures, meshes, sounds and
  the level.
- Stage 2: window (AppKit), keyboard and mouse, sound (AudioQueue with a small
  mixer for the sound effects).
- Stage 3: Metal renderer. The D3D9 shaders of the materials (vs_1_1, ps_1_1)
  are translated to Metal Shading Language at run time.
- Stage 4: the data is linked into the binary.
- Stage 5: the data of the 2004 beta release (`pno0001.exe`).

`kkrieger3383.kx` is a development snapshot from after the 2004 beta. The beta
data is an older export of the same game.

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
- `--screenshot n file.png`: write the back buffer of frame n

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
- Rendering (`render_metal.mm`) keeps the Direct3D 9 model: a render state
  array, material setups with D3D9 shader bytecode, an 800x600 back buffer.
  `d3d9_msl.cpp` translates the shaders, including the ps_1_1 rules (register
  range [-1,1], `_bx2`/`_bias`/`_sat` modifiers, co-issued instructions).
  Pipeline and depth/stencil states are cached by their D3D states.
- Two things were switched off for `sINTRO` builds although the kkrieger player
  needs them: portal processing in `Engine_::ProcessPortals` (the level was not
  painted at all) and font pages in `Bitmap_Text` (no hud text).
- Texture handle 0 is reserved. `GenOverlayManager` uses it as a placeholder
  and released the real texture in that slot (the hud font) while it was in use.
- A stencil-only clear also cleared the depth buffer. After the shadow pass
  of a light, the following passes (light, texture) failed their depth test,
  and the level was drawn without textures.
- Smaller fixes in the shared sources: the light list counted past its four
  entries and drew a fifth light from outside the array; effects (particles)
  were sorted between the light passes; `material11.cpp` dropped the
  "invert alpha" flag of combiner alpha sources (only the ipp "alpha" merge
  sets it); `Exec_IPP_Select` used an output count its convention does not
  pass.
- Sound effects were silent: the effect table stores start positions in
  samples, the C++ V2 player counts 1000 ticks per second. It now runs with
  one tick per sample.
- Compiler flags: `-fno-delete-null-pointer-checks` (the code tests `this`
  against 0) and `-ffp-contract=off` (x87 had no fused multiply-add, and the
  collision code depends on consistent rounding).

## The 2004 beta data

`beta_exe.cpp` unpacks `pno0001.exe` (an early kkrunchy: a range coder with
eight adaptive models and LZ matches) and takes the data block out of the
image. `kdoc.cpp` reads the 2004 export format and converts it to the
operators of these sources:

- The header has no tempo and no root operators. The tempo comes from the
  song (89 beats per minute). The data has one graph, in which `If` operators
  pick intro, menu or game by the game state. The loader puts a `Demo`
  operator on top of its last operator, and the player keeps that one root.
- Events have no time interval. The `Text` operator has 16 unused bytes
  after its strings.
- Operators with changed parameters: bitmap `Rotate` (new size parameters),
  `Text`, `Print` (bit 0 centered the text, now bits 8 and 9), `Monster`,
  `Particle System`, `Viewport`, `Cylinder`, and `KKriegerPara` (now gets the
  environment). Class `0xe0`, which passed a scene to the viewport, becomes a
  scene `Add`.
- A 2004 viewport has only a size. Camera operators in its scene set the
  camera, so it runs the scene first (flag `0x80`). The engine keeps the
  lights until the camera is known, because it culls them against the camera.
  2004 viewports clear to transparent black, and use the 2004 render target
  sizes.
- 2004 material blend mode 6 was an add (later subtract), modes 7 and 8
  were the dest alpha and source alpha adds (later 8 and 9).
- The second `KKriegerPara` operator has no start position, so it does not
  overwrite the first one. The first weapon counts its ammunition.

The ports at https://kznsq.github.io/kkrieger-web/ and
https://masondye.github.io/kkrieger-wasm/ were used as visual references,
and their notes for facts about the 2004 data. No code was taken from them.

The game logic is the later code of these sources, not the 2004 logic.
Collision, monsters and shots work as in the 3383 data, which is not exactly
how the beta played. The renderer is also the later one: the beta lit with
at most four lights per frame and a shadow mask, and drew specular in a
separate pass. The title plate of the intro shows as a plain grey surface
instead of the engraved logo.
