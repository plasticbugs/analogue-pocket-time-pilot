# Time Pilot for Analogue Pocket

An openFPGA core for **Time Pilot** (Konami, 1982), reimplementing the arcade
hardware: two Z80s, a 32x32 tilemap with 24 hardware sprites, two AY-3-8910A
sound chips and the six switchable RC filters on the sound board.

The whole 53 KB romset fits in block RAM, so there is no SDRAM in the design —
every access is single cycle and deterministic.

> **ROMs are not included and never will be.** You supply your own MAME
> `timeplt` romset; the core reads one image built from it.

## Installing

1. Copy `Cores/`, `Platforms/` and `Assets/` from the release zip onto the root
   of the Pocket's SD card.
2. Build the ROM image from your own romset and copy it to
   `Assets/timepilot/common/timeplt.rom`:

   ```sh
   python3 mra_build.py timeplt.mra timeplt.zip
   ```

   The builder needs nothing but Python 3. It reads the MAME zip (or a
   directory of loose files) directly, checks every ROM's CRC32, and verifies
   the finished image against a known md5 — so a wrong or bad romset is
   reported rather than silently built into something that half works.

   Already using `pupdate` or the standard `mra` tool? Point it at
   `timeplt.mra` instead; it is an ordinary MRA file.

## Controls

| | |
|---|---|
| Move | D-pad (8 directions) |
| Fire | B or A |
| Insert coin | Select |
| Start | Start |

DIP switches — lives, bonus life, difficulty, demo sounds, free play — are in
the Pocket's Interact menu, along with a diagnostic overlay.

## The screen

Time Pilot's monitor is mounted rotated. The core emits the native 256x224
arcade raster and the Pocket's scaler turns it 90 degrees clockwise, declared
in `video.json`. That costs no logic and, more usefully, keeps the gateware
rendering in the same coordinates the hardware used — which is what makes it
possible to diff frames against MAME pixel for pixel.

## How it is verified

Three gates, all against MAME, described in [docs/verification.md](docs/verification.md):

| gate | what it proves | runtime |
|---|---|---|
| `tools/regress_ref.sh` | the Python model of the video hardware still matches MAME | seconds |
| `sim/run_video.sh` | the video RTL matches that model, pixel for pixel | ~10 s |
| `sim/regress_system.sh` | the whole machine matches MAME's RAM **and** picture, frame by frame | minutes |

Current status: **0 differing pixels** on eight frozen states, and video RAM,
sprite RAM and work RAM **byte-identical to MAME** at every checked frame from
boot through 25 seconds of play. Audio matches MAME's recording of the same
window to within 0.1 dB.

[docs/hardware.md](docs/hardware.md) is the hardware map — memory map, video
timing, colour PROM resolution, and the parts of the game's own code that
constrain the design.

## Building

```sh
./build-local.sh map        # analysis & synthesis only, catches most mistakes
./build-local.sh            # full compile, then package into release/pocket/
```

Needs Docker and the `raetro/quartus:pocket` image. CI does the same on every
push.

## Credits and licences

* [tv80](https://github.com/hutch31/tv80) — Z80, MIT. Used for both simulation
  and synthesis, so what the benches verify is what ships.
* [jt49](https://github.com/jotego/jt49) — AY-3-8910, GPLv3, by Jose Tejada.
* [OpenGateware](https://github.com/opengateware) Pocket platform — MIT/BSD.
* MAME's `timeplt` driver by Nicola Salmoria, used as the oracle throughout.

This core is GPLv3, following jt49.
