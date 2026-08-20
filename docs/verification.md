# How this core is checked

Three gates, cheapest first. Everything compares against MAME, which is treated
as a program to interrogate rather than a reference to read.

## 1. Reference renderer — `tools/regress_ref.sh`

`tools/tpvideo.py` is a Python transcription of the video hardware: gfx decode,
PROM colour resolution, tilemap and sprite priority. `tools/render_model.py`
renders a dumped machine state and diffs it against MAME's own snapshot of that
state. Runs in a couple of seconds.

This is the executable spec. When a question comes up about what the hardware
does, the answer is settled here first, then written into RTL.

**Capturing states** — `tools/capture_states.sh` drives MAME to a set of frames
and dumps colour RAM, video RAM, both sprite RAMs and work RAM plus a PNG.

The dumper parks the CPU in a `JR $` loop and masks the NMI before capturing.
That is not tidiness: the game rewrites sprite RAM part way down every frame
(the cloud multiplex, `docs/hardware.md` 7.3), so the frame MAME drew is *not* a
function of the sprite RAM you can read at the end of it. Three of six in-game
states differed until the freeze was added; with it, all eight are exact.

## 2. Frozen-state video bench — `sim/run_video.sh`

Loads the `.rom` and a state dump straight into the video core's block RAMs in
Verilator, renders one frame, and diffs it against MAME's snapshot. About ten
seconds for the whole set of states, so every video change can be checked before
it goes anywhere near hardware.

Current status: **0 differing pixels on all eight states**, attract screen
through the heaviest sprite load found in play.

The bench also fails if `dbg_spr_overrun` is set — the sprite engine has 1024
clocks per line against a 672-clock worst case, and a sprite engine that quietly
runs out of time is the classic cause of flicker.

## 3. Full-system bench — `sim/regress_system.sh`

Boots the actual game on the actual Z80, runs it with a scripted input sequence,
then pauses the CPU and compares **both** the video memories and the picture
against MAME at the same frame.

The RAM comparison is the sharp one. If the CPU, the memory map, the interrupt
logic or the game's own logic were off anywhere, work RAM would diverge long
before anything showed on screen.

### Frame alignment

The two harnesses do not count frames from the same instant, and do not stop at
the same point inside a frame:

* MAME's `register_frame_done` fires at the **end** of a frame, after that
  frame's NMI handler has run. The RTL bench pauses at the **top** of vblank,
  before it. One frame of game state.
* The core's video counters are held in reset during the ROM download, so its
  first vblank arrives a fraction of a frame after the CPU starts — one frame
  earlier in the count than MAME's. The second.

Measured rather than assumed: RTL vblank 302 reproduces MAME frame 300 byte for
byte. `FRAME_SKEW = 2` in `sim/tb_system.cpp` applies that to both the stop
point and the input schedule, so "frame N" means the same game state on both
sides. Before it was applied the two drifted apart during play, because the
scripted inputs landed two frames out and the game legitimately went somewhere
else.

### What is deliberately not compared

Work RAM `0xAFE0-0xAFFF` is stack. The two benches stop the CPU at different
points inside the frame, so bytes *below* the current stack pointer are stale
leftovers from different call depths. Everything at or above SP is compared.

### Clock rates differ from MAME on purpose

The core runs at the measured hardware timing — 6.144 MHz dot clock, 384x264,
60.606 Hz (`docs/hardware.md` 4). MAME's `timeplt` driver still uses a 60.000 Hz
256-line approximation. The two therefore execute different numbers of CPU
cycles per frame, but the game is frame-locked to the vblank NMI, so its state
per frame is unaffected — which is exactly what the byte-identical RAM
comparison demonstrates.

## Sprite line buffer versus MAME's scanline renderer

The core fills the sprite line buffer during the previous line's hblank, which
is what the hardware does and what makes the cloud multiplex land correctly.
MAME samples sprite RAM at the end of the line it is drawing. The two can differ
by one line on the exact frame a cloud is repositioned. Frozen states are
unaffected, and the full-system comparison above has not shown it.
