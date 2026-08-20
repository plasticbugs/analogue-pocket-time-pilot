#!/bin/sh
# Lint the core with Verilator.
#
# Warning names come and go between Verilator releases, and naming one the
# installed version does not know is a hard error rather than a warning -- so
# -Wno-fatal cannot rescue it. PROCASSINIT, for instance, does not exist in the
# Verilator that ships with Ubuntu, which broke CI while passing locally.
#
# Each suppression is therefore probed against the installed binary before use,
# and this one script runs both locally and in CI so the two cannot drift.
set -e
cd "$(dirname "$0")/.."

SUPPRESS="DECLFILENAME UNUSEDSIGNAL VARHIDDEN PINCONNECTEMPTY PROCASSINIT"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'module probe; endmodule\n' > "$tmp/probe.v"

FLAGS="-Wall -Wno-fatal"
for w in $SUPPRESS; do
    if verilator --lint-only "-Wno-$w" "$tmp/probe.v" >/dev/null 2>&1; then
        FLAGS="$FLAGS -Wno-$w"
    else
        echo "note: this Verilator has no -Wno-$w, skipping it"
    fi
done

verilator --version
echo "lint flags: $FLAGS"

# -Wno-fatal keeps a warning name this Verilator happens to dislike from
# aborting the run, but it also means verilator always exits 0 -- which would
# make this step decorative. So the output is filtered instead: anything from
# the vendored CPU and sound cores under modules/ is noise we do not control,
# and anything from our own files is a failure.
out=$tmp/lint.out
set +e
verilator --lint-only $FLAGS --top-module timeplt_core \
    -Imodules/cpu-tv80 -Imodules/sound-jt49 \
    rtl/tp_ram.sv rtl/timeplt_video.sv rtl/tv80s_cen.v \
    rtl/timeplt_main.sv rtl/timeplt_sound.sv rtl/timeplt_core.sv \
    modules/cpu-tv80/tv80_core.v modules/cpu-tv80/tv80_alu.v \
    modules/cpu-tv80/tv80_mcode.v modules/cpu-tv80/tv80_reg.v \
    modules/sound-jt49/jt49.v modules/sound-jt49/jt49_div.v \
    modules/sound-jt49/jt49_noise.v modules/sound-jt49/jt49_eg.v \
    modules/sound-jt49/jt49_exp.v modules/sound-jt49/jt49_cen.v \
    > "$out" 2>&1
set -e
cat "$out"

ours=$(grep -E '^%(Warning|Error)' "$out" | grep -vE ': *modules/' || true)
if [ -n "$ours" ]; then
    echo
    echo "lint FAILED -- warnings in our own RTL:"
    echo "$ours"
    exit 1
fi
echo
echo "lint clean (warnings from vendored modules/ ignored)"
