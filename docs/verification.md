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

## 4. Audio — `sim/run_sound.sh` and `sim/run_audio.sh`

`sim/run_sound.sh <cmd>` drives the sound board in isolation: it writes a
command byte into the latch and pulses the IRQ exactly as the main board does,
then records what comes out. `tools/sndcmd.lua` makes MAME play the *same*
command with the main CPU parked, so the two recordings are of the same event.
`tools/compare_audio.py` box-decimates both to 8 kHz — which also discards the
ultrasonic square-wave harmonics MAME's resampler has already removed — and
reports DC-removed RMS plus band energies.

Reading the result matters: a **flat** ratio across the bands is a level error,
a **sloping** one is a filter error. The first measurement came back 21 dB down
with a ratio of 0.08-0.12 across 100 Hz to 4 kHz — dead flat, so the RC filters
were already right and only the output gain was wrong. `OUT_GAIN` in
`rtl/timeplt_sound.sv` was set from that measurement.

Current status:

| window | core / MAME RMS |
|---|---|
| command 0x01, isolated | 1.00 (0.00 dB) |
| command 0x05, isolated | 0.99 |
| command 0x0A, isolated | 1.15 |
| command 0x10, isolated | 1.14 |
| 3 s of gameplay, frames 700-900 | 0.99 (-0.11 dB) |

`sim/run_audio.sh <first_frame> <last_frame>` records the whole machine over a
window given in **frames**, not seconds: the core runs at 60.606 Hz and MAME's
driver at 60.000 Hz, so a window in seconds would slide 1% against MAME's
recording and compare different music.

### The bug this found

The sound board was completely silent. Booting the whole game to reach a point
where it plays takes minutes per run, so the board was lifted out into its own
bench and given counters. That showed the main board raising the IRQ correctly
and the sound Z80 never acknowledging it, with a PC histogram parked in the
boot-time RAM clear loop.

The cause was the memory decode: the unpopulated `1000-2FFF` window was written
as `cpu_a[15:14] == 2'b00 && !sel_rom`, which also covers `3000-3FFF` — the work
RAM — and it was tested before the RAM in the read mux. Every RAM read returned
zero, so the first `RET` popped `0x0000` and the CPU restarted its boot loop
forever, never reaching the `EI`.

## 5. Synthesis — `./build-local.sh map` and `./build-local.sh`

`quartus_map` alone takes about a minute and catches syntax and inference
errors without paying for a fit. It is worth running before every push: it
already caught one error that no amount of Verilator linting would have, because
Verilator does not have the limit — the block RAM zero-initialiser was a `for`
loop, and Quartus caps constant loops at 5000 iterations while the program ROM
is 32768 words.

Full compile, Quartus 18.1, 5CEBA4F23C8:

| resource | used | available |
|---|---|---|
| Logic (ALMs) | 4,527 | 18,480 (24%) |
| Registers | 6,106 | |
| Block memory | 570,817 bits | 3,153,920 (18%) |
| RAM blocks | 80 | 308 (26%) |
| DSP blocks | 15 | 66 (23%) |
| PLLs | 2 | 4 |

Timing closes with margin: every one of the 104 setup and hold corners has
positive slack, the worst being +0.126 ns on a hold path and +6.137 ns setup on
the 49.152 MHz system clock.

## 6. What still needs real hardware

Everything above is simulation against MAME. These cannot be settled without a
Pocket:

* **Screen orientation and aspect.** `video.json` declares rotation 90
  (clockwise) and three `scaler_modes`; the rotation direction is known to be
  right, because the same rotation makes the renders match MAME's snapshots
  pixel for pixel. How the scaler fits each aspect to the panel is not
  simulable, so all three are selectable from the Interact menu at runtime —
  picking the wrong default costs a menu tap rather than a rebuild.
* **Icon and banner colour order.** Analogue documents the 16-bit assets as
  BGRA5551 but the field order only shows up on hardware, so
  `tools/make_images.py` draws both in greys and white: with r == g == b the two
  candidate orders are indistinguishable. Colour can be added once the order is
  confirmed.
* **`display_modes` id `0x10`.** Carried over from a working core; not verified
  for this one.
* **Input remapping.** The `input.json` entry ids are fresh, so no saved
  `input_persist.json` from another layout can override them — but that is only
  provable on a unit that has never seen this core.
* **The watchdog.** It resets the CPU after 1.37 s without a kick. The flag has
  stayed clear across every simulation run including 25 seconds of play, but
  only hardware will show whether anything in a real session ever gets close.
  There is no longer an on-screen overlay to read it from — that was removed on
  request and is one revert away in git if a hardware fault ever needs it.
