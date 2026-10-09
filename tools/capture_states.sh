#!/bin/sh
# Capture a spread of frozen states + matching MAME snapshots.
# One MAME run per state: freezing the CPU is a one-way door.
set -e
cd "$(dirname "$0")/.."
OUT=${OUT:-artifacts}
FRAMES=${FRAMES:-"180 420 900 1500 2100 2700 3300 3900"}
rm -rf "$OUT"; mkdir -p "$OUT" build/mamecfg
for f in $FRAMES; do
    tag=$(printf "%04d" "$f")
    # Headless, and nothing may touch the display: `-video none` stops MAME
    # rendering but not creating a window, and its defaults are fullscreen,
    # which on macOS throws the desktop to a new Space on every run.
    # SDL_VIDEODRIVER=dummy keeps SDL off the display (read before MAME
    # parses anything), -videodriver dummy says the same through MAME, and
    # -window -nomaximize keeps any window that is made anyway small.
    # -seconds_to_run is a backstop: dumpstate.lua ends the run at the frame.
    SDL_VIDEODRIVER=dummy \
    TP_OUT="$OUT" TP_FRAME="$f" TP_TAG="$tag" TP_MODE="${TP_MODE:-1p}" \
    mame timeplt -rompath . -video none -videodriver dummy -window -nomaximize \
        -sound none -nothrottle -skip_gameinfo -seconds_to_run $((f / 60 + 60)) \
        -snapshot_directory "$OUT/snap_$tag" -cfg_directory build/mamecfg \
        -nvram_directory build/mamecfg -autoboot_script tools/dumpstate.lua \
        >/dev/null 2>&1
    snap=$(ls "$OUT/snap_$tag"/timeplt/*.png 2>/dev/null | head -1)
    [ -n "$snap" ] || { echo "no snapshot for frame $f"; exit 1; }
    mv "$snap" "$OUT/mame_$tag.png"
    rm -rf "$OUT/snap_$tag"
    echo "captured $tag"
done
