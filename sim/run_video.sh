#!/bin/sh
# Frozen-state video bench: build once, then render every captured state in
# the RTL and diff it against MAME's snapshot.
set -e
cd "$(dirname "$0")/.."
OUT=${OUT:-artifacts}
BUILD=build/sim_video

verilator --cc --exe --build -j 0 -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-VARHIDDEN -Wno-PROCASSINIT \
    --top-module timeplt_video --Mdir "$BUILD" -o tb_video \
    rtl/tp_ram.sv rtl/timeplt_video.sv sim/tb_video.cpp >/dev/null

fail=0
for s in "$OUT"/state_*.txt; do
    tag=$(basename "$s" .txt); tag=${tag#state_}
    "$BUILD/tb_video" build/timeplt.rom "$s" "build/rtl_$tag.ppm" >/dev/null
    python3 tools/diff_frames.py "build/rtl_$tag.ppm" "$OUT/mame_$tag.png" "build/rtl_${tag}_diff.png" || fail=1
done
[ $fail -eq 0 ] && echo "RTL matches MAME on every state" || echo "FAILURES"
exit $fail
