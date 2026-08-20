#!/bin/sh
# Record the sound board in Verilator.
#   sim/run_audio.sh <first_frame> <last_frame>
set -e
cd "$(dirname "$0")/.."
BUILD=build/sim_audio
verilator --cc --exe --build -j 0 -O2 -Wno-fatal \
    --top-module timeplt_core --Mdir "$BUILD" -o tb_audio \
    -Imodules/cpu-tv80 -Imodules/sound-jt49 \
    rtl/tp_ram.sv rtl/timeplt_video.sv rtl/tv80s_cen.v rtl/timeplt_main.sv \
    rtl/timeplt_sound.sv rtl/timeplt_core.sv \
    modules/cpu-tv80/tv80_core.v modules/cpu-tv80/tv80_alu.v \
    modules/cpu-tv80/tv80_mcode.v modules/cpu-tv80/tv80_reg.v \
    modules/sound-jt49/jt49.v modules/sound-jt49/jt49_div.v \
    modules/sound-jt49/jt49_noise.v modules/sound-jt49/jt49_eg.v \
    modules/sound-jt49/jt49_exp.v modules/sound-jt49/jt49_cen.v \
    sim/tb_audio.cpp >/dev/null
f0=${1:-700}; f1=${2:-900}; shift 2 2>/dev/null || true
"$BUILD/tb_audio" build/timeplt.rom "$f0" "$f1" build/rtl_audio.wav "$@"
