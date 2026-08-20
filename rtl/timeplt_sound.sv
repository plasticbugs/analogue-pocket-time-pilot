//------------------------------------------------------------------------------
// Time Pilot sound board (the Pooyan board): Z80 @ 1.789772 MHz, two
// AY-3-8910A at the same clock, and six switchable RC low-pass filters.
//
// docs/hardware.md 5 and 7.6 have the map and what the code does with it. Three
// things matter for it to sound right:
//
//   * AY1 port A reads the command latch; AY1 port B reads a free-running
//     divide-by-512 mod-10 timer off the sound Z80 clock. The engine's main
//     loop spins on that timer, so it *is* the music tempo -- it has to be a
//     real counter, not something derived from instructions executed.
//   * Writing anywhere in 8000-FFFF sets the filters; the *address* is the data.
//   * Each AY channel gets its own RC low-pass. MAME models these as one-pole
//     IIRs at the AY sample rate; the coefficients below are computed from the
//     same resistor and capacitor values rather than approximated.
//
// On the real machine the sound board has its own 14.31818 MHz crystal and is
// asynchronous to the video board. Here it is a clock enable off the system
// clock: 1.789772 MHz is not an integer divisor of 49.152 MHz, so it comes from
// a phase accumulator, accurate to under a part per million with at most one
// system clock of jitter -- far below anything the AY's own divide-by-8 sees.
//------------------------------------------------------------------------------
`default_nettype none

module timeplt_sound (
    input  wire        clk,             //! 49.152 MHz
    input  wire        reset,
    input  wire        pause,

    // ---- from the main board ---------------------------------------------
    input  wire  [7:0] snd_data,        //! command latch (main CPU writes C000)
    input  wire        snd_irq,         //! one clk pulse, LS259 Q2 rising edge
    input  wire        snd_mute,        //! LS259 Q3

    // ---- ROM image download ----------------------------------------------
    input  wire [17:0] dl_addr,
    input  wire  [7:0] dl_data,
    input  wire        dl_we,

    // ---- audio out --------------------------------------------------------
    output logic signed [15:0] audio,
    output logic       audio_ce,        //! one clk pulse per audio sample

    // ---- diagnostics ------------------------------------------------------
    output wire  [7:0] dbg_timer,
    output wire [15:0] dbg_filter
);

    // ------------------------------------------------- 1.789772 MHz enable
    // 2^24 * 1789772 / 49152000 = 610908.6; 610909 gives 1789774.5 Hz, +0.8 ppm.
    localparam [24:0] ACC_STEP = 25'd610909;
    logic [24:0] acc = 25'd0;
    logic        cen_snd;
    always_ff @(posedge clk) begin
        acc     <= {1'b0, acc[23:0]} + ACC_STEP;
        cen_snd <= acc[24];
    end
    wire cen = cen_snd && !pause && !dl_we;

    // ------------------------------------------------------------------ CPU
    wire [15:0] cpu_a;
    wire  [7:0] cpu_do;
    logic [7:0] cpu_di;
    wire        cpu_mreq_n, cpu_rd_n, cpu_wr_n, cpu_m1_n, cpu_rfsh_n, cpu_iorq_n;
    logic       irq_n;

    tv80s_cen u_cpu (
        .reset_n (~reset),
        .clk     (clk),
        .cen     (cen),
        .wait_n  (1'b1),
        .int_n   (irq_n),
        .nmi_n   (1'b1),
        .busrq_n (1'b1),
        .m1_n    (cpu_m1_n),
        .mreq_n  (cpu_mreq_n),
        .iorq_n  (cpu_iorq_n),
        .rd_n    (cpu_rd_n),
        .wr_n    (cpu_wr_n),
        .rfsh_n  (cpu_rfsh_n),
        .halt_n  (),
        .busak_n (),
        .A       (cpu_a),
        .di      (cpu_di),
        .dout    (cpu_do)
    );

    wire mem    = ~cpu_mreq_n && cpu_rfsh_n;
    wire mem_wr = mem && ~cpu_wr_n;

    // IM1 IRQ, held until the CPU acknowledges it (MAME's HOLD_LINE)
    wire int_ack = ~cpu_m1_n && ~cpu_iorq_n;
    logic irq_req;
    always_ff @(posedge clk) begin
        if (reset)        irq_req <= 1'b0;
        else if (snd_irq) irq_req <= 1'b1;
        else if (int_ack) irq_req <= 1'b0;
    end
    assign irq_n = ~irq_req;

    // ------------------------------------------------------------- decode
    wire sel_rom  = (cpu_a[15:12] == 4'h0);                 // 0000-0FFF (4 KB)
    wire sel_dead = (cpu_a[15:14] == 2'b00) && !sel_rom;    // 1000-2FFF: reads 0
    wire sel_ram  = (cpu_a[15:12] == 4'h3);                 // 3000-3FFF, 1 KB mirrored
    wire sel_ay1d = (cpu_a[15:12] == 4'h4);
    wire sel_ay1a = (cpu_a[15:12] == 4'h5);
    wire sel_ay2d = (cpu_a[15:12] == 4'h6);
    wire sel_ay2a = (cpu_a[15:12] == 4'h7);
    wire sel_filt = cpu_a[15];                              // 8000-FFFF

    wire  [7:0] rom_q;
    wire        dl_snd = dl_we && (dl_addr >= 18'h06000) && (dl_addr < 18'h07000);
    wire [17:0] dl_off = dl_addr - 18'h06000;
    tp_spram_dp #(.AW(12), .DW(8)) u_rom (
        .clk(clk), .wa(dl_off[11:0]), .we(dl_snd), .d(dl_data),
        .ra(cpu_a[11:0]), .q(rom_q)
    );

    wire [7:0] ram_q;
    tp_spram_dp #(.AW(10), .DW(8)) u_ram (
        .clk(clk), .wa(cpu_a[9:0]), .we(sel_ram && mem_wr), .d(cpu_do),
        .ra(cpu_a[9:0]), .q(ram_q)
    );

    // ------------------------------------------------------- port B timer
    // "divide by 512, then divide by 10 in a bi-quinary sequence". The engine
    // spins until this reads 0x00, once per 5120 clocks (349.6 Hz).
    logic [8:0] tdiv;
    logic [3:0] tidx;
    logic [7:0] timer_val;
    always_ff @(posedge clk) begin
        if (reset) begin
            tdiv <= 9'd0;
            tidx <= 4'd0;
        end else if (cen_snd) begin
            tdiv <= tdiv + 9'd1;
            if (&tdiv) tidx <= (tidx == 4'd9) ? 4'd0 : (tidx + 4'd1);
        end
    end
    always_comb begin
        case (tidx)
            4'd0: timer_val = 8'h00;
            4'd1: timer_val = 8'h10;
            4'd2: timer_val = 8'h20;
            4'd3: timer_val = 8'h30;
            4'd4: timer_val = 8'h40;
            4'd5: timer_val = 8'h90;
            4'd6: timer_val = 8'ha0;
            4'd7: timer_val = 8'hb0;
            4'd8: timer_val = 8'ha0;
            default: timer_val = 8'hd0;
        endcase
    end
    assign dbg_timer = timer_val;

    // --------------------------------------------------------------- AY x2
    logic [3:0] ay1_addr, ay2_addr;
    always_ff @(posedge clk) begin
        if (sel_ay1a && mem_wr) ay1_addr <= cpu_do[3:0];
        if (sel_ay2a && mem_wr) ay2_addr <= cpu_do[3:0];
    end

    wire [7:0] ay1_dout, ay2_dout;
    wire [7:0] ay1_a, ay1_b, ay1_c, ay2_a, ay2_b, ay2_c;

    jt49 u_ay1 (
        .rst_n   (~reset),
        .clk     (clk),
        .clk_en  (cen),
        .addr    (ay1_addr),
        .cs_n    (~sel_ay1d),
        .wr_n    (~(sel_ay1d && mem_wr)),
        .din     (cpu_do),
        .sel     (1'b1),
        .dout    (ay1_dout),
        .sound   (),
        .A       (ay1_a), .B (ay1_b), .C (ay1_c),
        .sample  (),
        .IOA_in  (snd_data),
        .IOA_out (),
        .IOB_in  (timer_val),
        .IOB_out ()
    );

    jt49 u_ay2 (
        .rst_n   (~reset),
        .clk     (clk),
        .clk_en  (cen),
        .addr    (ay2_addr),
        .cs_n    (~sel_ay2d),
        .wr_n    (~(sel_ay2d && mem_wr)),
        .din     (cpu_do),
        .sel     (1'b1),
        .dout    (ay2_dout),
        .sound   (),
        .A       (ay2_a), .B (ay2_b), .C (ay2_c),
        .sample  (),
        .IOA_in  (8'hff),
        .IOA_out (),
        .IOB_in  (8'hff),
        .IOB_out ()
    );

    always_comb begin
        cpu_di = 8'hff;
        if      (sel_rom)  cpu_di = rom_q;
        else if (sel_dead) cpu_di = 8'h00;
        else if (sel_ram)  cpu_di = ram_q;
        else if (sel_ay1d) cpu_di = ay1_dout;
        else if (sel_ay2d) cpu_di = ay2_dout;
    end

    // -------------------------------------------------------- filter select
    // Writing anywhere in 8000-FFFF loads all six 2-bit selects from the
    // address bits; the data on the bus is ignored.
    logic [11:0] filt;
    always_ff @(posedge clk) begin
        if (reset)                   filt <= 12'd0;
        else if (sel_filt && mem_wr) filt <= cpu_a[11:0];
    end
    assign dbg_filter = {4'd0, filt};

    // -------------------------------------------------------- RC low-pass
    // MAME's filter_rc LOWPASS_3R is a one-pole IIR y += (x - y) * k with
    //   Req = R1*(R2+R3)/(R1+R2+R3) = 1000*5100/6100 = 836.07 ohm
    //   k   = 1 - exp(-1/(Req*C)/fs),  fs = 1789772/8 = 223721.5 Hz
    // Capacitors switch in at 220 nF (bit 0) and 47 nF (bit 1), summed.
    localparam [12:0] K_47N  = 13'd7046;   // 4050 Hz
    localparam [12:0] K_220N = 13'd1573;   //  865 Hz
    localparam [12:0] K_267N = 13'd1299;   //  713 Hz

    // The AY updates its channels at chip clock / 8; run the filters on the
    // same grid so those coefficients mean what MAME means by them.
    logic [2:0] fdiv;
    logic       cen_fs;
    always_ff @(posedge clk) begin
        cen_fs <= 1'b0;
        if (cen) begin
            fdiv <= fdiv + 3'd1;
            if (&fdiv) cen_fs <= 1'b1;
        end
    end
    always_ff @(posedge clk) audio_ce <= cen_fs;

    wire [15:0] f_out [0:5];
    wire  [7:0] ch_in [0:5];
    assign ch_in[0] = ay1_a;
    assign ch_in[1] = ay1_b;
    assign ch_in[2] = ay1_c;
    assign ch_in[3] = ay2_a;
    assign ch_in[4] = ay2_b;
    assign ch_in[5] = ay2_c;

    // filter_w bit order: A[1:0] AY2 chA, A[3:2] AY2 chB, A[5:4] AY2 chC,
    //                     A[7:6] AY1 chA, A[9:8] AY1 chB, A[11:10] AY1 chC
    wire [1:0] sel_bits [0:5];
    assign sel_bits[0] = filt[7:6];
    assign sel_bits[1] = filt[9:8];
    assign sel_bits[2] = filt[11:10];
    assign sel_bits[3] = filt[1:0];
    assign sel_bits[4] = filt[3:2];
    assign sel_bits[5] = filt[5:4];

    generate
        genvar i;
        for (i = 0; i < 6; i = i + 1) begin : g_filter
            tp_rc_lowpass #(.K_47N(K_47N), .K_220N(K_220N), .K_267N(K_267N)) u_f (
                .clk   (clk),
                .reset (reset),
                .cen   (cen_fs),
                .csel  (sel_bits[i]),
                .din   (ch_in[i]),
                .dout  (f_out[i])
            );
        end
    endgenerate

    // ------------------------------------------------------------------ mix
    // Six unipolar Q8 channels summed, then DC-blocked. The absolute level is
    // set by OUT_SHIFT, calibrated against MAME (sim/tb_audio.cpp).
    logic signed [19:0] mix;
    always_ff @(posedge clk) if (cen_fs)
        mix <= $signed({4'd0, f_out[0]}) + $signed({4'd0, f_out[1]})
             + $signed({4'd0, f_out[2]}) + $signed({4'd0, f_out[3]})
             + $signed({4'd0, f_out[4]}) + $signed({4'd0, f_out[5]});

    // one-pole DC blocker, corner around 20 Hz at the mix rate
    logic signed [31:0] dc_acc;
    logic signed [19:0] dc_out;
    always_ff @(posedge clk) begin
        if (reset) begin
            dc_acc <= 32'sd0;
            dc_out <= 20'sd0;
        end else if (cen_fs) begin
            dc_acc <= dc_acc + (((({{12{mix[19]}}, mix}) <<< 12) - dc_acc) >>> 13);
            dc_out <= mix - dc_acc[31:12];
        end
    end

    localparam int OUT_SHIFT = 4;
    always_ff @(posedge clk) begin
        if (reset || snd_mute) audio <= 16'sd0;
        else if (cen_fs)       audio <= clamp16({{4{dc_out[19]}}, dc_out} <<< OUT_SHIFT);
    end

    function automatic signed [15:0] clamp16(input signed [23:0] v);
        if (v > 24'sh007fff)       clamp16 = 16'sh7fff;
        else if (v < -24'sh008000) clamp16 = 16'sh8000;
        else                       clamp16 = v[15:0];
    endfunction

endmodule


//! One-pole low-pass matching MAME's filter_rc LOWPASS_3R.
//! State is Q16 with 8 integer bits. A select of 0 means no capacitor is
//! switched in, which MAME treats as a straight pass-through.
module tp_rc_lowpass #(
    parameter [12:0] K_47N  = 13'd7046,
    parameter [12:0] K_220N = 13'd1573,
    parameter [12:0] K_267N = 13'd1299
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        cen,
    input  wire  [1:0] csel,
    input  wire  [7:0] din,
    output wire [15:0] dout
);
    logic [23:0] y;
    logic [12:0] k;
    always_comb begin
        case (csel)
            2'b00: k = 13'd0;        // no capacitor: pass through
            2'b01: k = K_220N;
            2'b10: k = K_47N;
            2'b11: k = K_267N;
        endcase
    end

    wire signed [24:0] err  = $signed({1'b0, din, 16'd0}) - $signed({1'b0, y});
    wire signed [37:0] prod = err * $signed({1'b0, k});

    always_ff @(posedge clk) begin
        if (reset)    y <= 24'd0;
        else if (cen) y <= (csel == 2'b00) ? {din, 16'd0}
                                           : (y + {{2{prod[37]}}, prod[37:16]});
    end

    assign dout = y[23:8];
endmodule

`default_nettype wire
