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

SUPPRESS="DECLFILENAME UNUSEDSIGNAL VARHIDDEN PINCONNECTEMPTY PROCASSINIT TIMESCALEMOD SYNCASYNCNET GENUNNAMED"

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
# Second pass: the Pocket top level. It was not linted at all until an audio
# change went in there unchecked and Quartus in CI was the only thing looking
# at it. Only findings in target/pocket/ count -- the OpenGateware modules it
# instantiates have plenty of optional pins we do not drive, and core_pll is a
# Quartus megafunction Verilator has no way to see. Match that one on its
# message rather than its warning code: 5.050 tags it %Error-MODMISSING and
# 5.020 emits a bare %Error.
out2=$tmp/lint_top.out
set +e
verilator --lint-only $FLAGS -Wno-PINMISSING --top-module core_top \
    -Imodules/cpu-tv80 -Imodules/sound-jt49 \
    -y platform/pocket -y platform/pocket/interface -y platform/pocket/memory \
    -y platform/pocket/video -y platform/pocket/audio -y platform/pocket/helpers \
    -y platform/pocket/peripherals -y platform/pocket/support \
    rtl/tp_ram.sv rtl/timeplt_video.sv rtl/tv80s_cen.v \
    rtl/timeplt_main.sv rtl/timeplt_sound.sv rtl/timeplt_core.sv \
    modules/cpu-tv80/tv80_core.v modules/cpu-tv80/tv80_alu.v \
    modules/cpu-tv80/tv80_mcode.v modules/cpu-tv80/tv80_reg.v \
    modules/sound-jt49/jt49.v modules/sound-jt49/jt49_div.v \
    modules/sound-jt49/jt49_noise.v modules/sound-jt49/jt49_eg.v \
    modules/sound-jt49/jt49_exp.v modules/sound-jt49/jt49_cen.v \
    target/pocket/core_top.sv target/pocket/pocket_analogizer.sv \
    target/pocket/analogizer/*.v target/pocket/analogizer/*.sv sim/ps2_keyboard_stub.v \
    > "$out2" 2>&1
set -e

# RndMnkIII's Analogizer module is vendored verbatim in target/pocket/analogizer/,
# so its findings are his, like modules/'s; the wrapper's are ours.
top=$(grep -E '^%(Warning|Error)' "$out2" | grep -E ': *target/pocket/' \
      | grep -v -E ': *target/pocket/analogizer/' \
      | grep -v 'Cannot find file containing module' || true)
if [ -n "$top" ]; then
    echo
    echo "lint FAILED -- warnings in target/pocket/:"
    echo "$top"
    exit 1
fi

# Third pass: the Analogizer wrapper on its own, with the adapter's vendored
# module behind it and a stand-in for its one VHDL file.  hq2x.sv (MiSTer's)
# assigns its output wire in an always block, which Quartus takes and
# Verilator calls an error: PROCASSWIRE is waived for this pass.
out3=$tmp/lint_ana.out
set +e
verilator --lint-only $FLAGS -Wno-PROCASSWIRE --top-module pocket_analogizer \
    target/pocket/pocket_analogizer.sv platform/pocket/helpers/synch_3.sv \
    target/pocket/analogizer/*.v target/pocket/analogizer/*.sv sim/ps2_keyboard_stub.v \
    > "$out3" 2>&1
set -e
ana=$(grep -E '^%(Warning|Error)' "$out3" | grep -v 'Exiting due to' \
      | grep -v -E '^%Warning[^ ]*: *(target/pocket/analogizer/|platform/pocket/|sim/ps2_keyboard_stub)' || true)
if [ -n "$ana" ]; then
    echo
    echo "lint FAILED -- the Analogizer wrapper:"
    echo "$ana"
    exit 1
fi

echo
echo "lint clean (warnings from vendored modules/, platform/ and target/pocket/analogizer/ ignored)"
