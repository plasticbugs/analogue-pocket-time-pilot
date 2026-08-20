#!/bin/sh
# Sound board in isolation: sim/run_sound.sh <cmd_hex> [seconds]
set -e
cd "$(dirname "$0")/.."
BUILD=build/sim_sound
verilator --cc --exe --build -j 0 -O2 -Wno-fatal --public-flat-rw \
    --top-module timeplt_sound --Mdir "$BUILD" -o tb_sound \
    -Imodules/cpu-tv80 -Imodules/sound-jt49 \
    rtl/tp_ram.sv rtl/tv80s_cen.v rtl/timeplt_sound.sv \
    modules/cpu-tv80/tv80_core.v modules/cpu-tv80/tv80_alu.v \
    modules/cpu-tv80/tv80_mcode.v modules/cpu-tv80/tv80_reg.v \
    modules/sound-jt49/jt49.v modules/sound-jt49/jt49_div.v \
    modules/sound-jt49/jt49_noise.v modules/sound-jt49/jt49_eg.v \
    modules/sound-jt49/jt49_exp.v modules/sound-jt49/jt49_cen.v \
    sim/tb_sound.cpp >/dev/null
"$BUILD/tb_sound" build/timeplt.rom "$1" "${2:-1.0}" "build/snd_$1.wav"
