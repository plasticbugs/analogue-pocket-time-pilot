#!/bin/sh
# Full-system bench: build the main board and boot the game.
#   sim/run_system.sh <frame> [more frames...]
set -e
cd "$(dirname "$0")/.."
BUILD=build/sim_system
verilator --cc --exe --build -j 0 -O2 \
    -Wno-fatal --top-module timeplt_main --Mdir "$BUILD" -o tb_system \
    -Imodules/cpu-tv80 \
    rtl/tp_ram.sv rtl/timeplt_video.sv rtl/tv80s_cen.v rtl/timeplt_main.sv \
    modules/cpu-tv80/tv80_core.v modules/cpu-tv80/tv80_alu.v \
    modules/cpu-tv80/tv80_mcode.v modules/cpu-tv80/tv80_reg.v \
    sim/tb_system.cpp >/dev/null
for f in "$@"; do
    tag=$(printf "%04d" "$f")
    "$BUILD/tb_system" build/timeplt.rom "$f" "build/sys_$tag.ppm" -ram "build/sys_$tag.txt"
done
