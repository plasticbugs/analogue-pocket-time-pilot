//------------------------------------------------------------------------------
// Time Pilot: the whole machine.
//
// Two boards that only meet at a command latch and an interrupt line: the video
// board (Z80 @ 3.072 MHz, tilemap, sprites) and the sound board (Z80 @
// 1.789772 MHz, two AY-3-8910A, RC filters).
//
// The entire 53 KB romset lives in block RAM, so every access is single cycle
// and there is no arbiter, no fetch latency and no bandwidth budget to blow.
//------------------------------------------------------------------------------
`default_nettype none

module timeplt_core (
    input  wire        clk,             //! 49.152 MHz = 8x the dot clock
    input  wire        reset,
    input  wire        pause,

    // ---- controls (active low, exactly as the CPU reads them) ------------
    input  wire  [7:0] in0,             //! coin/service/start
    input  wire  [7:0] in1,             //! player 1
    input  wire  [7:0] in2,             //! player 2 (cocktail)
    input  wire  [7:0] dsw0,            //! SW1 coinage
    input  wire  [7:0] dsw1,            //! SW2

    // ---- ROM image download ----------------------------------------------
    input  wire [17:0] dl_addr,
    input  wire  [7:0] dl_data,
    input  wire        dl_we,

    // ---- video -------------------------------------------------------------
    output wire  [7:0] red,
    output wire  [7:0] green,
    output wire  [7:0] blue,
    output wire        hsync,
    output wire        vsync,
    output wire        hblank,
    output wire        vblank,
    output wire        de,
    output wire        ce_pix,
    output wire        vblank_rise,

    // ---- audio -------------------------------------------------------------
    output wire signed [15:0] audio,
    output wire        audio_ce,

    // ---- diagnostics --------------------------------------------------------
    output wire        dbg_spr_overrun,
    output wire        dbg_watchdog,
    output wire [15:0] dbg_pc,
    output wire  [7:0] dbg_snd_timer,
    output wire [15:0] dbg_snd_filter,
    output wire [15:0] dbg_snd_pc,
    output wire [15:0] dbg_ay_writes,
    output wire [15:0] dbg_irqs,
    output wire  [7:0] dbg_ch0,
    output wire [15:0] dbg_snd_cmds,
    output wire [15:0] dbg_main_snd_irqs,
    output wire        dbg_irq_pending,
    output wire        dbg_int_ack
);

    wire [7:0] snd_data;
    wire       snd_irq, snd_mute;

    timeplt_main u_main (
        .clk             (clk),
        .reset           (reset),
        .pause           (pause),
        .in0             (in0),
        .in1             (in1),
        .in2             (in2),
        .dsw0            (dsw0),
        .dsw1            (dsw1),
        .dl_addr         (dl_addr),
        .dl_data         (dl_data),
        .dl_we           (dl_we),
        .snd_data        (snd_data),
        .snd_irq         (snd_irq),
        .snd_mute        (snd_mute),
        .red             (red),
        .green           (green),
        .blue            (blue),
        .hsync           (hsync),
        .vsync           (vsync),
        .hblank          (hblank),
        .vblank          (vblank),
        .de              (de),
        .ce_pix          (ce_pix),
        .vblank_rise_o   (vblank_rise),
        .dbg_spr_overrun (dbg_spr_overrun),
        .dbg_watchdog    (dbg_watchdog),
        .dbg_pc          (dbg_pc),
        .dbg_snd_cmds    (dbg_snd_cmds),
        .dbg_snd_irqs    (dbg_main_snd_irqs)
    );

    timeplt_sound u_sound (
        .clk        (clk),
        .reset      (reset),
        .pause      (pause),
        .snd_data   (snd_data),
        .snd_irq    (snd_irq),
        .snd_mute   (snd_mute),
        .dl_addr    (dl_addr),
        .dl_data    (dl_data),
        .dl_we      (dl_we),
        .audio      (audio),
        .audio_ce   (audio_ce),
        .dbg_timer     (dbg_snd_timer),
        .dbg_filter    (dbg_snd_filter),
        .dbg_pc        (dbg_snd_pc),
        .dbg_ay_writes (dbg_ay_writes),
        .dbg_irqs      (dbg_irqs),
        .dbg_ch0       (dbg_ch0),
        .dbg_irq_pending (dbg_irq_pending),
        .dbg_int_ack     (dbg_int_ack)
    );

endmodule

`default_nettype wire
