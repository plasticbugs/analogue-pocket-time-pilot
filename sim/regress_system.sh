#!/bin/sh
# End-to-end gate: boot the game in Verilator, run it to a set of frames, and
# check both the video memories and the picture against MAME at the same frame.
#
# The RAM comparison is the sharp one -- it is a direct check that our Z80 and
# the game's logic are in step with MAME's, byte for byte. The pixel comparison
# then checks the video path on top of that.
set -e
cd "$(dirname "$0")/.."
OUT=${OUT:-artifacts_sys}
FRAMES=${FRAMES:-"30 60 120 300 600 700 900 1500"}

if [ "$1" != "-nomame" ]; then
    OUT="$OUT" FRAMES="$FRAMES" ./tools/capture_states.sh
fi

BUILD=build/sim_system
verilator --cc --exe --build -j 0 -O2 \
    -Wno-fatal --top-module timeplt_main --Mdir "$BUILD" -o tb_system \
    -Imodules/cpu-tv80 \
    rtl/tp_ram.sv rtl/timeplt_video.sv rtl/tv80s_cen.v rtl/timeplt_main.sv \
    modules/cpu-tv80/tv80_core.v modules/cpu-tv80/tv80_alu.v \
    modules/cpu-tv80/tv80_mcode.v modules/cpu-tv80/tv80_reg.v \
    sim/tb_system.cpp >/dev/null

fail=0
for f in $FRAMES; do
    tag=$(printf "%04d" "$f")
    "$BUILD/tb_system" build/timeplt.rom "$f" "build/sys_$tag.ppm" -ram "build/sys_$tag.txt" -quiet
    python3 tools/diff_state.py "$OUT/state_$tag.txt" "build/sys_$tag.txt" || fail=1
    python3 tools/diff_frames.py "build/sys_$tag.ppm" "$OUT/mame_$tag.png" "build/sys_${tag}_diff.png" || fail=1
done
[ $fail -eq 0 ] && echo "system matches MAME on every frame" || echo "FAILURES"
exit $fail
