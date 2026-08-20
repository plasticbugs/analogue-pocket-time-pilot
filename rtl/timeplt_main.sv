//------------------------------------------------------------------------------
// Time Pilot main board: Z80 @ 3.072 MHz, program ROM, work RAM, the LS259
// control latch, the I/O decode, and the video hardware.
//
// The memory map and its mirrors are in docs/hardware.md 2. The mirrors are not
// decoration: the game reads IN1 through one of them (LD A,(C327)), so the
// don't-care bits have to be honoured.
//------------------------------------------------------------------------------
`default_nettype none

module timeplt_main (
    input  wire        clk,            //! 49.152 MHz
    input  wire        reset,
    input  wire        pause,          //! freeze the CPU (Analogue OS menu)

    // ---- inputs (active low, as the CPU sees them) -----------------------
    input  wire  [7:0] in0,
    input  wire  [7:0] in1,
    input  wire  [7:0] in2,
    input  wire  [7:0] dsw0,
    input  wire  [7:0] dsw1,

    // ---- ROM image download ----------------------------------------------
    input  wire [17:0] dl_addr,
    input  wire  [7:0] dl_data,
    input  wire        dl_we,

    // ---- to the sound board ----------------------------------------------
    output logic [7:0] snd_data,
    output logic       snd_irq,        //! one clk pulse on the LS259 Q2 rising edge
    output logic       snd_mute,       //! LS259 Q3

    // ---- video out --------------------------------------------------------
    output wire  [7:0] red,
    output wire  [7:0] green,
    output wire  [7:0] blue,
    output wire        hsync,
    output wire        vsync,
    output wire        hblank,
    output wire        vblank,
    output wire        de,
    output wire        ce_pix,
    output wire        vblank_rise_o,  //! top of vblank, one clk

    // ---- diagnostics ------------------------------------------------------
    output wire        dbg_spr_overrun,
    output logic       dbg_watchdog,   //! sticky: the watchdog fired
    output wire [15:0] dbg_pc,
    output logic [15:0] dbg_snd_cmds,  //! sound commands written to C000
    output logic [15:0] dbg_snd_irqs   //! LS259 Q2 rising edges
);

    // ------------------------------------------------------------- CPU clock
    // 49.152 / 16 = 3.072 MHz exactly.
    logic [3:0] cpu_div = 4'd0;
    always_ff @(posedge clk) cpu_div <= cpu_div + 4'd1;
    wire cpu_cen = (cpu_div == 4'd15) && !pause && !dl_we;

    // ------------------------------------------------------------------ CPU
    wire        cpu_reset;      // external reset or a watchdog timeout
    wire [15:0] cpu_a;
    wire  [7:0] cpu_do;
    logic [7:0] cpu_di;
    wire        cpu_mreq_n, cpu_rd_n, cpu_wr_n, cpu_m1_n, cpu_rfsh_n;
    logic       nmi_n;

    tv80s_cen u_cpu (
        .reset_n (~cpu_reset),
        .clk     (clk),
        .cen     (cpu_cen),
        .wait_n  (1'b1),
        .int_n   (1'b1),
        .nmi_n   (nmi_n),
        .busrq_n (1'b1),
        .m1_n    (cpu_m1_n),
        .mreq_n  (cpu_mreq_n),
        .iorq_n  (),
        .rd_n    (cpu_rd_n),
        .wr_n    (cpu_wr_n),
        .rfsh_n  (cpu_rfsh_n),
        .halt_n  (),
        .busak_n (),
        .A       (cpu_a),
        .di      (cpu_di),
        .dout    (cpu_do)
    );
    assign dbg_pc = cpu_a;
    assign vblank_rise_o = vblank_rise;

    // -------------------------------------------------------------- decode
    wire mem    = ~cpu_mreq_n && cpu_rfsh_n;
    wire mem_wr = mem && ~cpu_wr_n;

    wire sel_rom  = (cpu_a[15] == 1'b0) && (cpu_a[14:13] != 2'b11);   // 0000-5FFF
    wire sel_cram = (cpu_a[15:11] == 5'b10100) && (cpu_a[10] == 1'b0); // A000-A3FF
    wire sel_vram = (cpu_a[15:11] == 5'b10100) && (cpu_a[10] == 1'b1); // A400-A7FF
    wire sel_wram = (cpu_a[15:11] == 5'b10101);                        // A800-AFFF
    wire sel_spr  = (cpu_a[15:12] == 4'hb);                            // B000-BFFF
    wire sel_spr0 = sel_spr && (cpu_a[10] == 1'b0);
    wire sel_spr1 = sel_spr && (cpu_a[10] == 1'b1);
    wire sel_io   = (cpu_a[15:12] == 4'hc);                            // C000-CFFF

    wire io_c000  = sel_io && (cpu_a[9:8] == 2'b00);   // scanline r / sound cmd w
    wire io_c200  = sel_io && (cpu_a[9:8] == 2'b10);   // DSW1 r / watchdog w
    wire io_c300  = sel_io && (cpu_a[9:8] == 2'b11);   // input ports
    wire io_latch = sel_io && (cpu_a[11:8] == 4'h3) && (cpu_a[7:4] == 4'h0); // C300-C30F

    // --------------------------------------------------------- program ROM
    wire [7:0] rom_q;
    wire       dl_prog = dl_we && (dl_addr < 18'h06000);
    tp_spram_dp #(.AW(15), .DW(8)) u_prog (
        .clk(clk), .wa(dl_addr[14:0]), .we(dl_prog), .d(dl_data),
        .ra(cpu_a[14:0]), .q(rom_q)
    );

    // ------------------------------------------------------------ work RAM
    wire [7:0] wram_q;
    tp_spram_dp #(.AW(11), .DW(8)) u_wram (
        .clk(clk), .wa(cpu_a[10:0]), .we(sel_wram && mem_wr), .d(cpu_do),
        .ra(cpu_a[10:0]), .q(wram_q)
    );

    // ---------------------------------------------------------------- video
    wire [7:0] cram_q, vram_q, spr0_q, spr1_q, vpos;
    wire       vblank_rise;

    timeplt_video u_video (
        .clk             (clk),
        .reset           (reset),
        .video_enable    (latch[4]),
        .flip            (~latch[1]),
        .cpu_vaddr       (cpu_a[9:0]),
        .cpu_vdin        (cpu_do),
        .cram_we         (sel_cram && mem_wr),
        .vram_we         (sel_vram && mem_wr),
        .cram_q          (cram_q),
        .vram_q          (vram_q),
        .cpu_saddr       (cpu_a[7:0]),
        .cpu_sdin        (cpu_do),
        .spr0_we         (sel_spr0 && mem_wr),
        .spr1_we         (sel_spr1 && mem_wr),
        .spr0_q          (spr0_q),
        .spr1_q          (spr1_q),
        .dl_addr         (dl_addr),
        .dl_data         (dl_data),
        .dl_we           (dl_we),
        .red             (red),
        .green           (green),
        .blue            (blue),
        .hsync           (hsync),
        .vsync           (vsync),
        .hblank          (hblank),
        .vblank          (vblank),
        .de              (de),
        .ce_pix          (ce_pix),
        .vpos            (vpos),
        .vblank_rise     (vblank_rise),
        .dbg_spr_overrun (dbg_spr_overrun)
    );

    // ------------------------------------------------------------ read mux
    // Anything unmapped reads 0xFF: MAME's map.unmap_value_high(), and the
    // reset code depends on it (LD A,(6000) / CP 55 must not match).
    always_comb begin
        cpu_di = 8'hff;
        if      (sel_rom)  cpu_di = rom_q;
        else if (sel_cram) cpu_di = cram_q;
        else if (sel_vram) cpu_di = vram_q;
        else if (sel_wram) cpu_di = wram_q;
        else if (sel_spr0) cpu_di = spr0_q;
        else if (sel_spr1) cpu_di = spr1_q;
        else if (io_c000)  cpu_di = vpos;
        else if (io_c200)  cpu_di = dsw1;
        else if (io_c300)
            case (cpu_a[6:5])
                2'b00: cpu_di = in0;
                2'b01: cpu_di = in1;
                2'b10: cpu_di = in2;
                2'b11: cpu_di = dsw0;
            endcase
    end

    // ------------------------------------------------------- LS259 latch B3
    //  0 NMI enable   1 flip screen (inverted)   2 sound IRQ   3 mute
    //  4 video enable 5 coin counter 1           6 coin counter 2   7 unused
    logic [7:0] latch;
    logic       latch_wr_q;
    wire        latch_wr = io_latch && mem_wr;

    always_ff @(posedge clk) begin
        if (cpu_reset) begin
            latch <= 8'h00;
        end else if (latch_wr && !latch_wr_q) begin
            latch[cpu_a[3:1]] <= cpu_do[0];
        end
        latch_wr_q <= latch_wr;
    end

    assign snd_mute = latch[3];

    // sound IRQ fires on the Q2 rising edge
    logic q2_prev;
    always_ff @(posedge clk) begin
        q2_prev <= latch[2];
        snd_irq <= latch[2] && !q2_prev;
        if (reset) dbg_snd_irqs <= 16'd0;
        else if (latch[2] && !q2_prev) dbg_snd_irqs <= dbg_snd_irqs + 16'd1;
    end

    // ------------------------------------------------------- sound command
    logic snd_wr_q;
    wire  snd_wr = io_c000 && mem_wr;
    always_ff @(posedge clk) begin
        snd_wr_q <= snd_wr;
        if (snd_wr && !snd_wr_q) snd_data <= cpu_do;
        if (reset) dbg_snd_cmds <= 16'd0;
        else if (snd_wr && !snd_wr_q) dbg_snd_cmds <= dbg_snd_cmds + 16'd1;
    end

    // ------------------------------------------------------------------ NMI
    // Raised at the top of vblank when LS259 Q0 is set; clearing Q0 also clears
    // it, which is exactly what the handler does on entry.
    logic nmi_req;
    always_ff @(posedge clk) begin
        if (cpu_reset)      nmi_req <= 1'b0;
        else if (!latch[0]) nmi_req <= 1'b0;
        else if (vblank_rise) nmi_req <= 1'b1;
    end
    assign nmi_n = ~nmi_req;

    // ------------------------------------------------------------ watchdog
    // Kicked by any write to the C200 group; on expiry it resets the CPU and
    // the control latch, which is what the board does. The game kicks it at
    // least once per frame, so 2^22 CPU cycles (1.37 s) leaves an 80x margin --
    // and the flag below has stayed clear across every full-system run,
    // including 25 seconds of play, so that margin is measured rather than
    // assumed. It stops counting while the core is paused, so sitting in the
    // Analogue OS menu cannot trip it.
    logic [21:0] wdog;
    logic  [7:0] wdog_hold;      // reset pulse, 255 clk_sys cycles = 16 CPU clocks
    wire         wdog_kick = (io_c200 && mem_wr) || dl_we;

    always_ff @(posedge clk) begin
        if (reset) begin
            wdog         <= 22'd0;
            wdog_hold    <= 8'd0;
            dbg_watchdog <= 1'b0;
        end else begin
            if (wdog_hold != 8'd0) wdog_hold <= wdog_hold - 8'd1;
            if (wdog_kick) begin
                wdog <= 22'd0;
            end else if (cpu_cen) begin
                if (&wdog) begin
                    wdog         <= 22'd0;
                    wdog_hold    <= 8'hff;
                    dbg_watchdog <= 1'b1;      // sticky, for the overlay
                end else begin
                    wdog <= wdog + 22'd1;
                end
            end
        end
    end

    assign cpu_reset = reset || (wdog_hold != 8'd0);

endmodule

`default_nettype wire
