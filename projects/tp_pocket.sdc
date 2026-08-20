# ==============================================================================
# Quartus Prime Synopsys Design Constraint File
# ==============================================================================
# Time Pilot core constraints.
#
# The Pocket BSP (platform/pocket/bsp/pocket/sys_constr.sdc) creates the APF
# clocks; this file describes what is specific to this core.
#
# There is no external memory here at all -- the whole 53 KB romset lives in
# block RAM -- so there are no SDRAM pin constraints to get right.
# ==============================================================================

# ==============================================================================
# Clock groups
#
# core_pll general[0] = clk_sys       49.152 MHz (8x the dot clock)
#          general[1] = clk_vid        6.144 MHz (dot clock)
#          general[2] = clk_vid 90deg  6.144 MHz
#          general[3], general[4]      unused
#
# clk_sys and the two pixel clocks stay in ONE group on purpose. The video
# output is launched on clk_sys and sampled by the APF scaler on clk_vid; they
# are integer-related outputs of the same PLL, so that crossing is synchronous
# by construction and should be verified rather than cut. Cutting it would let
# each build route it blind and make the picture depend on the fitter seed.
#
# clk_74a, clk_74b, the bridge SPI clock and the audio PLL are genuinely
# asynchronous to the machine. The one multi-bit bus that crosses into clk_74b
# -- the audio sample -- is handed over with a toggle flag in core_top, so the
# capture is always of a value that has been still for several cycles.
# ==============================================================================
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

# ==============================================================================
# Z80 multicycle.
#
# Both Z80s advance only on a clock enable: the main CPU every 16 clk_sys
# cycles (49.152 / 16 = 3.072 MHz exactly) and the sound CPU at worst every 27
# (a phase accumulator averaging 1.789772 MHz). Every register-to-register path
# *inside* tv80_core therefore has at least 16 clock periods to settle, and
# tv80's microcode decode is the widest combinational block in the design.
#
# Deliberately scoped to paths that both start and end inside the CPU: the
# address and data buses run to block RAM ports that are clocked every cycle,
# and those must still meet single-cycle timing.
#
# 8 rather than 16: half the provable margin, which is plenty of relief and
# leaves the constraint correct even if the enable generation is ever changed.
# ==============================================================================
set_multicycle_path -setup 8 -from [get_registers {*|tv80_core:*|*}] -to [get_registers {*|tv80_core:*|*}]
set_multicycle_path -hold  7 -from [get_registers {*|tv80_core:*|*}] -to [get_registers {*|tv80_core:*|*}]
