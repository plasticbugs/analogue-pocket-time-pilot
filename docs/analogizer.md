# The Analogizer

[Analogizer](https://github.com/RndMnkIII/Analogizer) is RndMnkIII's adapter
for the Pocket's cartridge slot. It gives analog video out of a VGA connector
(RGBS, RGsB, YPbPr, Y/C, and a scandoubled RGBHV) and takes native controllers
through SNAC adapters. Its wiki is the authority on the adapter itself:
[specifications](https://github.com/RndMnkIII/Analogizer/wiki/Analogizer-Specifications),
[how to configure it](https://github.com/RndMnkIII/Analogizer/wiki/Supported-Cores-and-How-to-Configure-Them).

This page covers what this core does with it, for the person using it and for
whoever changes the core next. The pieces come from
[pocket-core-template](https://github.com/plasticbugs/pocket-core-template)
(`docs/analogizer-retrofit.md` there is the order of work this followed).

## For the player

**Settings are in the core's own menu**, under the game's other options,
like RndMnkIII's own "Pocket Menu" Analogizer cores. No `analogizer.bin` is
needed. The Pocket remembers them for this core.

| entry | options |
|---|---|
| Analogizer | Off (the default), On, On, Pocket off (the picture goes to the CRT only) |
| Analogizer Video | RGBS, RGsB, YPbPr, Y/C NTSC, Y/C PAL, Scandoubler, Scandoubler 25% / 50% / 75%, Scandoubler HQ2x |
| SNAC Adapter | None, DB15, NES, SNES, PCE 2-button, PCE 6-button, PCE Multitap, DB15 Fast, SNES A,B<->X,Y, PSX Digital, PSX Digital Fast, PSX Analog, PSX Analog Fast |
| SNAC Assignment | the six below |
| Analogizer H Position | -24 to +8 dots; + moves the picture right |
| Analogizer V Position | -16 to +4 lines; + moves the picture down |

With **Analogizer** off the core behaves exactly as it did without Analogizer
support. The adapter itself is set up as its wiki's
[How to use it](https://github.com/RndMnkIII/Analogizer/wiki/How-to-use-it%3F)
says: SNAC switch in position A, 5 V into its USB-C port, the SCART cable's
audio jack in the Pocket's headphone socket.

**A vertical game: turn the set.** Time Pilot's cabinet monitor is mounted
on its side, and the CRT gets the board's own signal exactly as the board
scans it, unrotated -- only the Pocket's own screen is turned, by its scaler.
On a CRT standing on its side, turned clockwise as you face it (its top to
the right, MAME's ROT90), the picture is upright. On a set left flat it is
sideways.

**Video.** 256 × 224 visible, 384 × 264 dots at 6.144 MHz: 16.0 kHz lines,
60.6 Hz frames, the timing a 15 kHz arcade monitor or a PVM expects (the
scandoubled modes are 32.0 kHz).

| mode | SOG switch | notes |
|---|---|---|
| RGBS | off | VGA-to-SCART or VGA-to-BNC |
| RGsB | on | R2/R3 adapters only |
| YPbPr | on | R2/R3 adapters only |
| Y/C NTSC, Y/C PAL | off | needs an active Y/C adapter on the VGA port |
| SC 0% / 25% / 50% / 75% / HQ2x | off | scandoubled for a VGA monitor |

"On, Pocket off" turns the Pocket's own picture black while the CRT keeps
it.

**Position.** The two sliders move the picture on the CRT, in the board's
own dots and lines (on a turned set, "H" moves it up and down the glass and
"V" across). They move the syncs, not the picture, so nothing is cropped and
every mode follows; the size is still the set's to adjust. 0 is the board's
own timing. The ranges are what the board's blanking allows: it leaves only
8 dots between the end of the picture and hsync, and 4 lines before vsync.

**Controllers.** SNAC pads (DB15, NES, SNES, PC Engine 2/6-button and
multitap, PlayStation) replace the Pocket's controls according to the
**SNAC Assignment** chosen in the menu:

| assignment | pad 1 | pad 2 |
|---|---|---|
| SNAC P1 → Pocket P1 | SNAC 1 | the Pocket's own controls |
| SNAC P1 → Pocket P2 | Pocket | SNAC 1 |
| SNAC P1,P2 → P1,P2 | SNAC 1 | SNAC 2 |
| SNAC P1,P2 → P2,P1 | SNAC 2 | SNAC 1 |

Time Pilot is one stick and one button, and the two players take turns on
the same controls (README, *Controls*), so the core merges the two pads:
either one plays whichever turn is up, and a second pad's Start is the 2
player start. With "SNAC P1 → Pocket P1" the Pocket's own buttons keep
working alongside the SNAC pad. The two remaining assignments (P3,P4 and
P1-P4) put SNAC pads where this game never reads, so they do nothing here.
Buttons map as on the Pocket: B or A fires, Select is coin, Start is start,
Y is 2 player start. A PlayStation pad in analog mode steers with its left
stick. **Cocktail Cabinet** in the menu changes nothing for SNAC: the core
already feeds player 2's port from the same merged controls (README), so on
player 2's turn the picture flips and the same pads play.

**Cart power is on for everyone.** `core.json` declares the cartridge
adapter, so the Pocket powers the slot whether or not an Analogizer is in it.
Do not leave a game cartridge in the slot while this core runs.

**Not yet tried on hardware.** What the bench proves is listed under *What
was measured* below. Send problems with the adapter itself to the Analogizer
project.

## For the developer

### The pieces

| file | what |
|---|---|
| `target/pocket/analogizer/` | RndMnkIII's `openFPGA_Pocket_Analogizer` and what it instantiates, **verbatim**, as the template carries it (from MiraxPocket). Its `analogizer.qip` is the template's: only what is used. |
| `target/pocket/pocket_analogizer.sv` | the wrapper: pixel hand-over, Y/C constants, picture position, SNAC → controller words. Core-agnostic; the template's file, with one fix (below). |
| `target/pocket/core_top.sv` | `USE_ANALOGIZER`, the instance (`LINE_LEN` 384, `CLK_HZ` 49,152,000), `key1..key4` into the `gamepad` helper in place of `cont1..4_key`, the bridge read at `0xF7xxxxxx`, the Pocket-screen blank, and the cart pins' idle levels when it is off. |
| `pkg/.../interact.json` | the entries above: ids 70–73, each a masked field of the word at `0xF7000000`, and 74–75, signed sliders at `0xF7000004` and `0xF7000008`. 14 entries with the game's own 8. |
| `pkg/.../core.json` | `"cartridge_adapter": 0` (powers the slot) |
| `sim/run_analogizer.sh`, `sim/tb_analogizer.sv` | the bench (below), at Time Pilot's raster |
| `tools/check_json.py` | the template's: fails if an entry writes outside its mask, none sets the enable, a position slider is not signed within ±127, a data slot also writes `0xF7000000`, the slot is not powered, or the menu is larger than Analogue allows |

### The settings word

One 32-bit word at `0xF7000000`, the layout RndMnkIII's adapter module (1.4)
decodes. Each menu entry is a list with a mask that keeps every bit but its
own field (or fields), so the four entries share the word:

| bits | field | values |
|---|---|---|
| 4:0 | SNAC type | 0 none, 1 DB15, 2 NES, 3 SNES, 4 PCE 2-button, 5 PCE 6-button, 6 PCE multitap, 9 DB15 fast, 0xB SNES A/B↔X/Y, 0xC–0xF PS/2 keyboard (not in the menu), 0x10/0x11 PSX digital, 0x12/0x13 PSX analog |
| 5 | enable | 0: the port stays idle and nothing else applies |
| 9:6 | SNAC assignment | 0–5 as in the table above |
| 13:10 | video | 0 RGBS, 1 RGsB, 2 YPbPr, 3 Y/C NTSC, 4 Y/C PAL, 5–9 scandoubler 0/25/50/75%/HQ2x |
| 14 | blank the Pocket screen | |
| 15 | OSD on the Analogizer output | not used; no menu entry |

The word is written as a number (the module is told `bridge_endian_little =
1`) and read back from the wrapper's own copy, combinationally: the firmware
merges a masked entry by reading the word back every frame, and the
module's own read-back would hand it the previous read's value.

**Picture position.** `0xF7000004` (horizontal, dots, + right) and
`0xF7000008` (vertical, lines, + down), whole signed slider words. The
wrapper re-makes hsync and vsync from the source's own edges, earlier or
later, as wide as the source's; pixels and blanking pass untouched.

The range is this board's, from its blanking (`rtl/timeplt_video.sv`; the
bench numbers lines from the counter's first value, vcnt 248):

- hsync is dots 272–303, the picture 8–263: 8 dots of front porch, so +8
  right puts hsync on the first blank dot. Leftward, 88 dots of back porch,
  less the Y/C colour burst (about 3.5 µs after hsync, 22 dots at 6.144
  MHz), would allow about -66; -24 is offered.
- vsync is lines 252–254, the picture 24–247: 4 lines of front porch, so +4
  down. Upward there are 33 lines before vsync would reach the picture;
  -16 is offered.

One step past either positive end (+9 dots, +5 lines) the bench fails: a
sync on a picture dot or line.

**The fix to the template's wrapper.** At 0 the template passed the source's
sync straight through, outside the off-time rule that keeps a re-made pulse
from starting until it has been off as long as it was on (the adapter's
`sync_fix` re-reads polarity every period). Here a jump from +4 lines to 0 --
one "large" slider step -- put the source's vsync one line after the last
re-made one, and csync came out inverted for a whole frame: this core's
bench caught it ("V 4 to 0 at once: csync low for 458,752 clocks of
picture"), where the template's and Moo Mesa's ranges never produced that
jump. At 0 the source's pulse now starts only on its own rising edge and
only when the rule allows, and follows the source otherwise. In steady state
it is the source's sync exactly (the bench's 0,0 checks).

### Clocks

`clk_sys` is 49.152 MHz, eight clocks a dot. The shipped Analogizer cores
clock the adapter at 42.95–48 MHz and the retrofit order is to pass a 40–50
MHz `clk_sys` as both the source and the Analogizer clock, so no PLL output
is added and the SDC is unchanged. The hand-over takes each pixel two clocks
after `ce_pix` (`PIX_LAG` 2; the video module registers colour, syncs and
blanks together on `ce_pix`), and the scandoubler, at twice the dot rate,
still has four clocks a dot.

### Using SNAC in the game's inputs

`pocket_analogizer`'s `key1..key4` feed the `gamepad` helper in place of
`cont1..4_key`; nothing else in the core reads the controller words. The
helper runs with two pads in alternate mode, which ORs them into the
cabinet's one set of controls.

### What was measured

- `sim/run_analogizer.sh` (PASS): the wrapper and the vendored module at
  this raster and clock, read at the cartridge pins as the DAC reads them.
  - Menu: all 32 options of the four lists set by read-merge-write at the
    bridge's timing, each seen by the adapter; defaults leave every pin as
    on a core without it and the controller words passing through.
  - RGBS: 57,344 visible dots in 224 lines, 0 differ; 261 csync pulses of
    32 dots.
  - Scandoubler: 528 lines per frame at 1536 clocks, twice the lines at
    half the period.
  - Position +8,+4 and -24,-16: csync moves 64 and -192 clocks (8 and 24
    dots) and 4 and 16 lines, never low while a dot is drawn, the picture
    unchanged; scandoubler unchanged at both; back at 0, where it started.
  - Jumps written just after a pulse: V +4 to 0 and H +8 to -24, csync
    never low in the picture over three frames (V +4 to 0 failed before
    the fix above).
  - One step past (+9 dots, +5 lines): fails, a sync in the picture.
  - YPbPr and Y/C NTSC/PAL without an unknown on any pin; SNAC assignments
    0–5, the analog stick and type none; the blank bit; off again is idle.
- `sim/lint.sh`: clean, with core_top linted with the Analogizer in it and
  the wrapper on its own.
- `sim/run_video.sh`: the 8 frozen states still 0 differing pixels (the
  game's RTL did not change).
- Quartus 18.1: compiles with no negative slack at any corner (worst setup
  +2.483 ns, slow 85C, clk_74a; worst hold +0.119 ns, fast 0C, clk_sys).
  The Analogizer costs 2,054 ALMs (4,544 → 6,598, 36%), 13 RAM blocks
  (80 → 93 of 308) and 3 DSP blocks (15 → 18). The only constraints Quartus
  reports ignored are the ones it ignored before this: `tp_pocket.sdc`'s
  clock groups are read before `sys_constr.sdc` creates the clocks, so the
  platform's own groups are the ones in force (unchanged here).

**Not proven:** anything on hardware; that the firmware writes a signed
slider as a two's-complement word (Analogue documents signed sliders, no
installed core is known to use one); the SNAC serial protocols, which are
the adapter module's and are forced at its outputs in the bench; Y/C and
YPbPr beyond running without unknowns; how a consumer set takes 16.0 kHz
and 60.6 Hz (an arcade monitor or PVM is the board's own load).

### Turning it off

Set `USE_ANALOGIZER = 0` in `core_top.sv`, and take the six menu entries and
`cartridge_adapter: 0` out of the JSON.
