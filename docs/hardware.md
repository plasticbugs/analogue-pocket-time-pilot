# Time Pilot (Konami, 1982) — hardware notes

Source of truth: MAME `src/mame/konami/timeplt.cpp` + `src/mame/shared/timeplt_a.cpp`
(vendored read-only under `ref/mame/`, gitignored), cross-checked with
`mame -listxml timeplt` (MAME 0.288).

Status legend: **[MAME]** taken from the driver, **[XML]** from listxml,
**[ASSUMED]** inferred, needs confirmation, **[VERIFIED]** confirmed by
experiment (Lua/Verilator/reference renderer).

---

## 1. Clocks

| Signal | Frequency | Source |
|---|---|---|
| Master crystal (video board) | 18.432 MHz | [MAME] `MASTER_CLOCK` |
| Main CPU (Z80) | 3.072 MHz = 18.432/6 | [MAME]/[XML] |
| Dot clock | 6.144 MHz = 18.432/3 | [ASSUMED] Konami standard of the era |
| Sound board crystal | 14.31818 MHz | [ASSUMED] from the sound clock below |
| Sound CPU (Z80) | 1.789772 MHz | [XML] (= 14.31818/8) |
| AY-3-8910A ×2 | 1.789772 MHz | [XML] |

The sound board is asynchronous to the video board — its own crystal. The two
Z80s only communicate through a latch plus an IRQ line.

## 2. Main CPU memory map [MAME]

```
0000-5FFF  ROM              24 KB (tm1, tm2, tm3)
A000-A3FF  Colour RAM       1 KB   (tile attributes)
A400-A7FF  Video RAM        1 KB   (tile codes)
A800-AFFF  Work RAM         2 KB
B000-B0FF  Sprite RAM 0     mirror 0x0B00
B400-B4FF  Sprite RAM 1     mirror 0x0B00
```

Memory-mapped I/O (all mirrored — see the mask column, don't-care bits):

| Address | Mirror mask | Read | Write |
|---|---|---|---|
| C000 | 0x0CFF | vertical scan line counter | sound command latch |
| C200 | 0x0CFF | DSW1 (SW2) | watchdog reset |
| C300 | 0x0C9F | IN0 | — |
| C300-C30F | none | — | LS259 latch (B3): A[3:1] selects bit, D0 is data |
| C320 | 0x0C9F | IN1 | — |
| C340 | 0x0C9F | IN2 (cocktail P2) | — |
| C360 | 0x0C9F | DSW0 (SW1) | — |

Decode of the mirrors, expressed as "care" bits:

* C000 group: A[15:12]=C, A[9:8]=00 (A[11:10], A[7:0] don't care)
* C200 group: A[15:12]=C, A[9:8]=10
* C3x0 group: A[15:12]=C, A[9:8]=11, A[6:5] picks IN0/IN1/IN2/DSW0
  (A[11:10], A[7], A[4:0] don't care)

### LS259 (B3) outputs [MAME]

| Q | Function | Note |
|---|---|---|
| 0 | NMI enable | clearing it also clears a pending NMI |
| 1 | flip screen | **inverted**: flip = !Q1 |
| 2 | sound IRQ trigger | rising edge fires IRQ on the sound Z80 |
| 3 | audio mute | LA4460 pin 6 |
| 4 | video enable | blanks the whole screen when 0 |
| 5 | coin counter 1 | |
| 6 | coin counter 2 | |
| 7 | "PAY OUT" — unused | |

The board also has a watchdog, kicked by any write to the C200 group. MAME's
`WATCHDOG_TIMER` is configured with neither a time nor a vblank count, so MAME
never actually fires it; the core implements one with a 1.37 s timeout (2^22
CPU cycles) that resets the CPU and clears this latch. The game kicks it at
least once per frame from the NMI, an 80x margin, and it stops counting while
the core is paused.

### Interrupts [MAME]

Main CPU: NMI at vblank, gated by LS259 Q0. Vector 0x66 (Z80 NMI).
Sound CPU: IM1 IRQ (0x38), triggered by the LS259 Q2 rising edge, HOLD_LINE.

## 3. Inputs [MAME, konamipt.h]

All active low.

**IN0 (C300)** — system
| bit | function |
|---|---|
| 0 | Coin 1 |
| 1 | Coin 2 |
| 2 | Service 1 |
| 3 | Start 1 |
| 4 | Start 2 |
| 5-7 | unused |

**IN1 (C320)** — player 1 (8-way)
| bit | function |
|---|---|
| 0 | Left |
| 1 | Right |
| 2 | Up |
| 3 | Down |
| 4 | Button 1 (fire) |
| 5-7 | unused |

**IN2 (C340)** — player 2 (cocktail), same bit layout as IN1.

**DSW0 (C360)** — SW1, coinage: bits 0-3 coin A, bits 4-7 coin B.
0x0F/0xF0 = 1 coin 1 credit (default), 0x00 = free play.

**DSW1 (C200)** — SW2
| bits | function | default |
|---|---|---|
| 1:0 | Lives: 3/4/5/255 (3,2,1,0) | 3 (0x03) |
| 2 | Cabinet: 0 upright, 1 cocktail | upright |
| 3 | Bonus: 1 = 10k/50k, 0 = 20k/60k | 0x08 |
| 6:4 | Difficulty 1 (easiest, 7) .. 8 (hardest, 0) | 4 (0x40) |
| 7 | Demo sounds: 0 = on | on (0x00) |

Factory default byte: DSW0 = 0xFF, DSW1 = 0x4B.

## 4. Video

### Timing

MAME's `timeplt` driver models the screen as 256×256 @ 60 Hz with the visible
area 0-255 × 16-239 (224 lines) [MAME] — an approximation it never updated.
Sibling drivers on the same Konami hardware carry the real numbers
[VERIFIED — `konami/pooyan.cpp`, whose comment marks them as measured]:

```
screen.set_raw(18.432_MHz_XTAL / 3, 384, 0, 256, 264, 16, 240); // measured ~60.6Hz
```

`konami/tutankhm.cpp` uses the Galaxian-family constants, which are the same
384/264. Time Pilot is the same manufacturer, the same year, the same master
clock and the same visible window, and its own driver header says the sound
board is "same as Pooyan", so the core uses:

```
HTOTAL 384   H visible 0..255    (H blank 256..383)
VTOTAL 264   V visible 16..239   (224 lines)
refresh = 6144000 / (384*264) = 60.606 Hz
```

The vertical counter is 9 bits running 0xF8..0x1FF (264 states); the CPU reads
the low 8 bits at C000, so it sees 248..255 then 0..255. During the visible
area both models agree exactly (16..239), which is what matters for the
scanline-multiplexing trick the game plays with the cloud sprites.

### Tilemap [MAME]

32×32 tiles of 8×8, 2 bpp, no scrolling.

```
index    = ty*32 + tx           (tx = x/8, ty = y/8)
attr     = colorram[index]
code     = videoram[index] + 256*attr[5]        -> 9 bits
color    = attr[4:0]                            -> 5 bits
category = attr[4]                              -> priority
flip X   = attr[6]
flip Y   = attr[7]
```

Note: `color = attr & 0x1f` and `category = (attr & 0x10) >> 4`, so **bit 4 is
used twice** — it is both the top bit of the 5-bit colour and the priority
category. That is not a typo in MAME; the colour PROM is addressed with the
full 5 bits.

Priority: category-0 tiles are drawn, then sprites, then category-1 tiles. The
tilemap is fully **opaque** (MAME never calls `set_transparent_pen`), so a
category-1 tile hides any sprite pixel underneath it.

### Sprites [MAME]

24 sprites, 16×16, 2 bpp, drawn from `offs = 0x3E` down to `0x10` step −2, so
**lower offsets are drawn last and win**.

```
sx     = spriteram0[offs]
code   = spriteram0[offs+1]
sy     = 241 - spriteram1[offs+1]
color  = spriteram1[offs] & 0x3F
flip X = !(spriteram1[offs] & 0x40)      (active when the bit is 0)
flip Y =   spriteram1[offs] & 0x80
```

Transparent pen: 0 (before the lookup PROM).

The game multiplexes the cloud sprites by polling the scanline register at
C000 and rewriting sprite RAM part-way down the frame, drawing them twice
offset by 128 pixels [MAME comment] — so sprite RAM must be sampled per
scanline, not once per frame.

### GFX decode [MAME]

Tiles (`tm6`, 8 KB = 512 tiles × 16 bytes), 2 bpp, planes at bit offsets {4, 0}:

```
byte[y]      -> pixels x=0..3     byte[8+y] -> pixels x=4..7
within a byte: bit(7-k) = LSB plane of pixel k, bit(3-k) = MSB plane of pixel k
```

Sprites (`tm4`+`tm5`, 16 KB = 256 sprites × 64 bytes), 2 bpp, same plane layout:

```
byte index = 8*(x/4) + y + (y >= 8 ? 24 : 0)
within a byte: bit(7-k) = LSB plane, bit(3-k) = MSB plane, k = x mod 4
```

### Colour [MAME]

Four PROMs:

| PROM | Size | Role |
|---|---|---|
| `timeplt.b4` | 32 | palette, low byte |
| `timeplt.b5` | 32 | palette, high byte |
| `timeplt.e9` | 256 | sprite colour lookup |
| `timeplt.e12` | 256 | character colour lookup (only 128 used) |

32 physical colours, each a 5-bit-per-gun resistor DAC with weights
`0x19, 0x24, 0x35, 0x40, 0x4D` (sum 255):

```
R = w . b5[1..5]
G = w . { b5[6], b5[7], b4[0], b4[1], b4[2] }
B = w . b4[3..7]
```

Lookup:

```
character pixel: pen = color*4 + pixel        (color 0..31)  -> palette[(e12[pen] & 0x0F) + 16]
sprite    pixel: pen = color*4 + pixel        (color 0..63)  -> palette[ e9[pen] & 0x0F ]
```

So characters use physical colours 16..31 and sprites use 0..15.

## 5. Sound board [MAME, timeplt_a.cpp]

Z80 @ 1.789772 MHz.

```
0000-2FFF  ROM (only 0000-0FFF populated: tm7, 4 KB)
3000-33FF  RAM  mirror 0x0C00
4000       AY1 data read/write   mirror 0x0FFF
5000       AY1 address write     mirror 0x0FFF
6000       AY2 data read/write   mirror 0x0FFF
7000       AY2 address write     mirror 0x0FFF
8000-FFFF  filter control (the *address* carries the data)
```

Filter control: writing anywhere in 8000-FFFF sets six 2-bit filter selects
from the address bits:

```
A[1:0]   -> AY2 ch A      A[3:2]  -> AY2 ch B      A[5:4]  -> AY2 ch C
A[7:6]   -> AY1 ch A      A[9:8]  -> AY1 ch B      A[11:10]-> AY1 ch C
```

Each 2-bit value switches capacitors: bit0 = 220 nF, bit1 = 47 nF, summed.
MAME models each as `filter_rc LOWPASS_3R` with R1 = 1 kΩ, R2 = 5.1 kΩ, R3 = 0.

AY1 port A (input) = sound command latch (written by the main CPU at C000).
AY1 port B (input) = a free-running timer derived from the sound Z80 clock:

```
portB = timeplt_timer[(cycles / 512) % 10]
timeplt_timer = { 00, 10, 20, 30, 40, 90, A0, B0, A0, D0 }
```

Each AY channel is routed at gain 0.60 into its own RC filter, and the six
filter outputs are summed into a mono speaker at gain 1.0.

## 6. ROM set (`timeplt`) [XML]

| File | Size | CRC32 | Region |
|---|---|---|---|
| tm1 | 8192 | 1551f1b9 | maincpu 0x0000 |
| tm2 | 8192 | 58636cb5 | maincpu 0x2000 |
| tm3 | 8192 | ff4e0d83 | maincpu 0x4000 |
| tm7 | 4096 | d66da813 | sound 0x0000 |
| tm6 | 8192 | c2507f40 | tiles 0x0000 |
| tm4 | 8192 | 7e437c3e | sprites 0x0000 |
| tm5 | 8192 | e8ca87b9 | sprites 0x2000 |
| timeplt.b4 | 32 | 34c91839 | proms 0x0000 |
| timeplt.b5 | 32 | 463b2b07 | proms 0x0020 |
| timeplt.e9 | 256 | 4bbb2150 | proms 0x0040 |
| timeplt.e12 | 256 | f7b7663e | proms 0x0140 |

Total 53,824 bytes — small enough to live entirely in FPGA block RAM.

## 7. What the software actually does (from disassembly)

Ghidra project `/timepilot`, programs `timeplt_main.bin` (tm1+tm2+tm3 at 0x0000)
and `timeplt_snd.bin` (tm7 at 0x0000). Only as much was disassembled as was
needed to pin down hardware behaviour.

### 7.1 Reset — the "protection" at C308 is not protection [VERIFIED]

```
07B1  LD   A,(6000)      ; unmapped -> reads 0xFF (unmap_value_high)
07B4  CP   55
07B6  JP   Z,6000        ; factory/diagnostic ROM hook, never taken in retail
07B9  LD   SP,B000
07BC  LD   (C200),A      ; kick the watchdog
07BF  LD   HL,C300
07C2  LD   B,08
07C4  LD   (HL),00 / INC HL / DJNZ    ; writes C300..C307
07C9  LD   A,(2D4B)      ; = 0x01, a constant buried in unrelated code
07CC  LD   (C308),A      ; video enable = 1
07CF  JP   0069
```

Two things worth having in the core:

* The clear loop only covers C300-C307, which is latch **bits 0-3** (address
  A[3:1] selects the bit). Bits 4-7 are never cleared at reset, so the core
  must not depend on a particular power-on value for them beyond what the
  software then writes.
* C308 is an ordinary LS259 write. The MAME comment's "Protection ??? Stuffs in
  some values computed from ROM content" is just an obfuscated constant load —
  ROM[0x2D4B] happens to be 0x01. **No protection device to emulate.**

Two ROM checksum self-tests do exist and both pass with a genuine dump:
`49C4` sums 256 bytes at 0x27DE and expects 0xC5; `4B72` sums bytes derived
from 0x086D/0x0870 and jumps to 0x6000 (a hang) on mismatch.

### 7.2 The vblank NMI [VERIFIED]

`0066 -> 00D8`. In order:

1. `CALL 0365` — rebuild sprite RAM from the shadow copy in work RAM
   (0xAA10-0xAA6B -> 0xB010/0xB410), and restore the cloud sprites to their
   top-of-screen position (see below).
2. `CALL 5286` — sound engine tick.
3. `XOR A / LD (C300),A` — **NMI disable** for the duration of the handler.
4. `LD (C200),A` — watchdog kick.
5. Latch all five input ports into work RAM, complemented:
   C200->A9AD, C300->A9AE, C320->A9AF, C340->A9B0, C360->A9B1.
6. `LD A,(A987) / LD (C302),A` — flip screen from the cocktail/player-2 flag.
7. ... game logic ...
8. `LD A,(1600) / LD (C300),A` — ROM[0x1600] = 0x01, **NMI re-enable**.

So NMI enable is toggled every frame; the core's LS259 bit 0 must both gate the
NMI and clear a pending one, exactly as MAME does.

### 7.3 Cloud sprite multiplexing — why sprite RAM is per-scanline [VERIFIED]

`0F97` (called from the main loop, polled continuously through the frame)
handles eight sprite slots: offsets 0x10, 0x12, 0x14 and 0x36, 0x38, 0x3A,
0x3C, 0x3E. For each:

```
A = spriteram1[offs+1]          ; the raw Y register
if (A & 0x80) {
    C = A
    A = scanline (C000)
    if (A + C >= 0x100) {       ; beam has reached the sprite's bottom row
        spriteram1[offs+1] = C & 0x7F    ; Y -= 128  -> screen Y += 128
        spriteram0[offs]  += 0x80        ; X += 128
    }
}
```

Since `sy = 241 - ysrc`, the sprite occupies screen rows `sy .. sy+15`, and
`sy + 15 = 256 - ysrc`. The carry condition `scanline + ysrc >= 0x100` is
exactly `scanline >= 256 - ysrc`, i.e. the beam has arrived at the sprite's
**last** row. At that moment the program moves the same sprite 128 pixels down
and right, and it is drawn a second time in the lower half of the screen.
`04BC` (inside the NMI) puts them back by adding 0x80 to both X and Y.

Consequences for the core:

* The scanline register at C000 must be the real vertical counter, and must
  read as the line number during the visible area (16..239).
* **Sprites must be evaluated per scanline**, not once per frame.
* The switch happens while the sprite's last row is being displayed. With a
  line buffer filled during the *previous* line that row is already committed,
  so the sprite is drawn complete. A renderer that samples sprite RAM at the
  end of the current line (which is what MAME's `VIDEO_UPDATE_SCANLINE` does)
  can lose that row. Expect a possible one-line difference from MAME in motion;
  frozen states are unaffected. **[ASSUMED — line buffer; verify against MAME.]**

### 7.4 Mirrored I/O reads are used [VERIFIED]

`5818: LD A,(C327)` reads IN1 through the mirror (A[4:0] don't care). The core
must implement the mirror masks in section 2, not just the base addresses.

### 7.5 Sound command handshake [VERIFIED]

```
55F8  LD   (C000),A      ; command byte
55FB  LD   A,01
55FD  LD   (C304),A      ; LS259 bit 2 -> 1, rising edge fires sound IRQ
5600  NOP x6
5606  LD   A,00
5608  LD   (C304),A
```

### 7.6 Sound CPU [VERIFIED]

Restart vectors are thin AY accessors:

| RST | Code | Meaning |
|---|---|---|
| 08 | `LD (5000),A / LD A,(4000) / RET` | read AY1 register A |
| 10 | `LD (7000),A / LD A,(6000) / RET` | read AY2 register A |
| 18 | `LD (5000),A / LD A,C / LD (4000),A / RET` | AY1 register A := C |
| 20 | `LD (7000),A / LD A,C / LD (6000),A / RET` | AY2 register A := C |
| 38 | `EXX / EX AF,AF' / CALL 0040 / EX AF,AF' / EXX / RET` | IRQ |

The IRQ handler (`0040`) starts `LD A,0E / RST 08` — AY1 **register 14 = port A
= the sound command latch**. A zero command clears all six voice slots.

The main loop is paced by the AY port B timer:

```
00BF  EI
00C0  LD   A,0F
00C2  RST  08            ; read AY1 register 15 = port B
00C3  AND  F0
00C5  JR   NZ,00C0       ; spin until the timer reads 0x00
```

Only index 0 of `{00,10,20,30,40,90,A0,B0,A0,D0}` has a zero high nibble, so
the engine runs one pass per 5120 sound-CPU clocks = **349.6 Hz**. The timer is
a free-running divider off the sound Z80 clock, so it must be built as a
counter in the core (not derived from executed instructions) — get it wrong and
the music tempo is wrong.

Filter control: the sound CPU keeps a 16-bit "filter address" in RAM at 0x300C,
initialised to 0x8000, updates 2-bit fields in it per channel (`01D0`), and
commits with `LD (HL),A` — the *address* is the data. It always stays in
0x8000-0xFFFF.

## 8. Open questions

1. ~~Real H/V timing~~ — settled: 384x264 @ 6.144 MHz, from the measured
   values in `konami/pooyan.cpp`. Note this makes the core run at 60.606 Hz
   while MAME's `timeplt` runs at 60.000 Hz, so the two drift apart in raw
   cycles; the game is frame-locked to the NMI, so its per-frame state is
   unaffected.
2. Sprite line buffer filled during the previous line — assumed (7.3).
3. Flip screen: MAME flips the tilemap only (`flip_screen_set`), not the
   sprites, so cocktail mode is wrong in MAME. Real hardware flips both. The
   core will flip both; verification is done in upright mode.
