//------------------------------------------------------------------------------
// Time Pilot video hardware.
//
// The semantics implemented here are the ones pinned down by tools/tpvideo.py,
// which is pixel-identical to MAME across the captured states -- read that
// alongside this file. In brief:
//
//   * 32x32 tilemap of 8x8 2bpp tiles, no scroll, fully opaque. Attribute bit 4
//     is both the top bit of the 5-bit colour and a priority category.
//   * 24 sprites, 16x16 2bpp, scanned 0x3E down to 0x10 so low offsets win.
//     Pen 0 transparent, sy = 241 - Y register.
//   * Priority: category-0 tiles, then sprites, then category-1 tiles on top.
//   * Colour: pen -> lookup PROM (e12 chars / e9 sprites) -> 4-bit index ->
//     32-entry palette PROM pair (b4/b5) -> 5-bit-per-gun resistor DAC.
//
// Timing (docs/hardware.md 4): 6.144 MHz dot clock, 384 dots per line, 264
// lines, 60.606 Hz. The vertical counter is 9 bits running 248..511; the CPU
// reads its low 8 bits, so visible rows read as 16..239.
//
// Clocked at 8x the dot clock. Two consequences worth knowing:
//
//   * The colour lookup is three chained block RAM reads, but they all settle
//     inside one dot, so they cost no pixel delay -- the addresses are simply
//     wired together and the result is sampled at the dot boundary.
//   * The tilemap is fetched one 8-dot group ahead of where it is displayed,
//     and sprites are rendered into a line buffer during the previous line's
//     hblank. The latter is what makes the game's mid-frame cloud
//     repositioning land on the right scanline (docs/hardware.md 7.3).
//------------------------------------------------------------------------------
`default_nettype none

module timeplt_video (
    input  wire        clk,            //! 8x the dot clock
    input  wire        reset,

    // ---- control ---------------------------------------------------------
    input  wire        video_enable,   //! LS259 Q4
    input  wire        flip,           //! screen flip (LS259 Q1, already inverted)

    // ---- CPU access to the video memories --------------------------------
    input  wire  [9:0] cpu_vaddr,      //! colour RAM / video RAM
    input  wire  [7:0] cpu_vdin,
    input  wire        cram_we,
    input  wire        vram_we,
    output wire  [7:0] cram_q,
    output wire  [7:0] vram_q,
    input  wire  [7:0] cpu_saddr,      //! sprite RAM 0 / 1
    input  wire  [7:0] cpu_sdin,
    input  wire        spr0_we,
    input  wire        spr1_we,
    output wire  [7:0] spr0_q,
    output wire  [7:0] spr1_q,

    // ---- ROM image download (offsets within the .rom) --------------------
    input  wire [17:0] dl_addr,
    input  wire  [7:0] dl_data,
    input  wire        dl_we,

    // ---- video out -------------------------------------------------------
    output logic [7:0] red,
    output logic [7:0] green,
    output logic [7:0] blue,
    output logic       hsync,
    output logic       vsync,
    output logic       hblank,
    output logic       vblank,
    output logic       de,
    output wire        ce_pix,         //! one clk in eight

    // ---- to the CPU ------------------------------------------------------
    output wire  [7:0] vpos,           //! the C000 scanline register
    output logic       vblank_rise,    //! one clk pulse at the top of vblank

    // ---- diagnostics -----------------------------------------------------
    output logic       dbg_spr_overrun //! sticky: a line buffer was not finished in time
);

    // ------------------------------------------------------------- .rom map
    localparam [17:0] OFS_TILES   = 18'h07000;
    localparam [17:0] OFS_SPRITES = 18'h09000;
    localparam [17:0] OFS_B4      = 18'h0D000;
    localparam [17:0] OFS_B5      = 18'h0D020;
    localparam [17:0] OFS_E9      = 18'h0D040;
    localparam [17:0] OFS_E12     = 18'h0D140;
    localparam [17:0] OFS_END     = 18'h0D240;

    wire dl_tiles = dl_we && (dl_addr >= OFS_TILES)   && (dl_addr < OFS_SPRITES);
    wire dl_spr   = dl_we && (dl_addr >= OFS_SPRITES) && (dl_addr < OFS_B4);
    wire dl_b4    = dl_we && (dl_addr >= OFS_B4)      && (dl_addr < OFS_B5);
    wire dl_b5    = dl_we && (dl_addr >= OFS_B5)      && (dl_addr < OFS_E9);
    wire dl_e9    = dl_we && (dl_addr >= OFS_E9)      && (dl_addr < OFS_E12);
    wire dl_e12   = dl_we && (dl_addr >= OFS_E12)     && (dl_addr < OFS_END);

    // The region bases are not powers of two, so the offset has to be
    // subtracted: masking the download address off by hand rotates a region
    // inside its memory instead of loading it straight.
    wire [17:0] dl_off_tiles = dl_addr - OFS_TILES;
    wire [17:0] dl_off_spr   = dl_addr - OFS_SPRITES;
    wire [17:0] dl_off_b4    = dl_addr - OFS_B4;
    wire [17:0] dl_off_b5    = dl_addr - OFS_B5;
    wire [17:0] dl_off_e9    = dl_addr - OFS_E9;
    wire [17:0] dl_off_e12   = dl_addr - OFS_E12;

    // -------------------------------------------------------- video timing
    localparam int HTOTAL = 384;
    localparam int HDISP  = 256;
    localparam int HLEAD  = 8;          // tilemap runs one group ahead
    localparam int HS_BEG = 272, HS_END = 304;

    localparam int VFIRST = 248;        // 9-bit counter runs 248..511
    localparam int VLAST  = 511;
    localparam int VVIS0  = 272;        // low byte 16
    localparam int VVIS1  = 495;        // low byte 239
    localparam int VS_BEG = 500, VS_END = 502;

    logic [2:0] phase = 3'd0;
    logic [8:0] hcnt  = 9'd0;
    logic [8:0] vcnt  = VFIRST[8:0];

    assign ce_pix = (phase == 3'd7);

    wire       h_last    = (hcnt == HTOTAL[8:0] - 9'd1);
    wire [8:0] vcnt_next = (vcnt == VLAST[8:0]) ? VFIRST[8:0] : (vcnt + 9'd1);

    always_ff @(posedge clk) begin
        if (reset) begin
            phase <= 3'd0;
            hcnt  <= 9'd0;
            vcnt  <= VFIRST[8:0];
        end else begin
            phase <= phase + 3'd1;
            if (ce_pix) begin
                hcnt <= h_last ? 9'd0 : (hcnt + 9'd1);
                if (h_last) vcnt <= vcnt_next;
            end
        end
    end

    assign vpos = vcnt[7:0];

    // Source pixel shown this dot. The colour pipeline is sampled at the dot
    // boundary, so the sync flags go through the same register and stay aligned.
    wire [8:0] src_x  = hcnt - HLEAD[8:0];
    wire       h_vis  = (hcnt >= HLEAD[8:0]) && (hcnt < HLEAD[8:0] + HDISP[8:0]);
    wire       v_vis  = (vcnt >= VVIS0[8:0]) && (vcnt <= VVIS1[8:0]);
    wire       de_src = h_vis && v_vis;
    wire       hs_src = (hcnt >= HS_BEG[8:0]) && (hcnt < HS_END[8:0]);
    wire       vs_src = (vcnt >= VS_BEG[8:0]) && (vcnt <= VS_END[8:0]);

    always_ff @(posedge clk)
        vblank_rise <= ce_pix && h_last && (vcnt_next == VVIS1[8:0] + 9'd1);

    // ---------------------------------------------------- tilemap memories
    wire  [9:0] vid_tidx;
    wire  [7:0] cram_vq, vram_vq;

    tp_dpram #(.AW(10), .DW(8)) u_cram (
        .clk(clk),
        .a_addr(cpu_vaddr), .a_we(cram_we), .a_d(cpu_vdin), .a_q(cram_q),
        .b_addr(vid_tidx),  .b_we(1'b0),    .b_d(8'd0),     .b_q(cram_vq)
    );
    tp_dpram #(.AW(10), .DW(8)) u_vram (
        .clk(clk),
        .a_addr(cpu_vaddr), .a_we(vram_we), .a_d(cpu_vdin), .a_q(vram_q),
        .b_addr(vid_tidx),  .b_we(1'b0),    .b_d(8'd0),     .b_q(vram_vq)
    );

    logic [12:0] tile_ra;
    wire   [7:0] tile_q;
    tp_spram_dp #(.AW(13), .DW(8)) u_tilerom (
        .clk(clk), .wa(dl_off_tiles[12:0]), .we(dl_tiles), .d(dl_data),
        .ra(tile_ra), .q(tile_q)
    );

    // ------------------------------------------------------- tilemap fetch
    // One fetch per 8-dot group, issued in the first phases of the group's
    // first dot; the result is handed to the shifter as the next group starts,
    // which is when those pixels reach the screen.
    wire [4:0] f_col = flip ? ~hcnt[7:3] : hcnt[7:3];
    wire [4:0] f_row = flip ? ~vcnt[7:3] : vcnt[7:3];
    wire [2:0] f_ln  = flip ? ~vcnt[2:0] : vcnt[2:0];
    assign vid_tidx = {f_row, f_col};

    wire [7:0] f_attr = cram_vq;                        // valid from phase 1
    wire [8:0] f_code = {f_attr[5], vram_vq};
    wire [2:0] f_rowe = f_attr[7] ? ~f_ln : f_ln;       // tile's own flipy

    always_comb tile_ra = {f_code, (phase == 3'd2), f_rowe};

    logic [7:0] pend_attr, pend_bl, pend_br;
    logic [7:0] act_attr,  act_bl,  act_br;

    wire group_start = ce_pix && (hcnt[2:0] == 3'd7);

    always_ff @(posedge clk) begin
        if (hcnt[2:0] == 3'd0) begin
            if (phase == 3'd1) pend_attr <= f_attr;
            if (phase == 3'd2) pend_bl   <= tile_q;     // left  half, src x 0..3
            if (phase == 3'd3) pend_br   <= tile_q;     // right half, src x 4..7
        end
        if (group_start) begin
            act_attr <= pend_attr;
            act_bl   <= pend_bl;
            act_br   <= pend_br;
        end
    end

    wire [2:0] k        = src_x[2:0];
    wire [2:0] k_scr    = flip ? ~k : k;                // screen flip
    wire [2:0] k_idx    = act_attr[6] ? ~k_scr : k_scr; // tile's own flipx
    wire [7:0] k_byte   = k_idx[2] ? act_br : act_bl;
    wire [1:0] k_nib    = k_idx[1:0];
    wire [1:0] tile_px  = {k_byte[3 - k_nib], k_byte[7 - k_nib]};
    wire [6:0] char_pen = {act_attr[4:0], tile_px};
    wire       tile_cat = act_attr[4];

    // ----------------------------------------------------- sprite memories
    logic [7:0] spr_ra;
    wire  [7:0] spr0_vq, spr1_vq;
    tp_dpram #(.AW(8), .DW(8)) u_spr0 (
        .clk(clk),
        .a_addr(cpu_saddr), .a_we(spr0_we), .a_d(cpu_sdin), .a_q(spr0_q),
        .b_addr(spr_ra),    .b_we(1'b0),    .b_d(8'd0),     .b_q(spr0_vq)
    );
    tp_dpram #(.AW(8), .DW(8)) u_spr1 (
        .clk(clk),
        .a_addr(cpu_saddr), .a_we(spr1_we), .a_d(cpu_sdin), .a_q(spr1_q),
        .b_addr(spr_ra),    .b_we(1'b0),    .b_d(8'd0),     .b_q(spr1_vq)
    );

    logic [13:0] sgfx_ra;
    wire   [7:0] sgfx_q;
    tp_spram_dp #(.AW(14), .DW(8)) u_sprrom (
        .clk(clk), .wa(dl_off_spr[13:0]), .we(dl_spr), .d(dl_data),
        .ra(sgfx_ra), .q(sgfx_q)
    );

    // -------------------------------------------------- sprite line buffer
    // Two 256-byte buffers of {colour[5:0], pen[1:0]}; pen 0 means empty. The
    // buffer on display is cleared as it is read, one entry per dot across the
    // whole line, so it is empty again by the time it is filled next line.
    wire       lb_disp = vcnt[0];
    wire [7:0] rd_addr = src_x[7:0];
    wire       rd_en   = h_vis;

    logic [7:0] clr_addr;
    logic       clr_en;
    always_ff @(posedge clk) if (ce_pix) begin
        clr_addr <= rd_addr;
        clr_en   <= rd_en;
    end

    logic [7:0] lb_wa, lb_d;
    logic       lb_we;

    wire [7:0] lb0_q, lb1_q;
    tp_spram_dp #(.AW(8), .DW(8)) u_lb0 (
        .clk(clk),
        .wa(lb_disp ? lb_wa : clr_addr),
        .we(lb_disp ? lb_we : (clr_en && ce_pix)),
        .d (lb_disp ? lb_d  : 8'd0),
        .ra(rd_addr), .q(lb0_q)
    );
    tp_spram_dp #(.AW(8), .DW(8)) u_lb1 (
        .clk(clk),
        .wa(lb_disp ? clr_addr : lb_wa),
        .we(lb_disp ? (clr_en && ce_pix) : lb_we),
        .d (lb_disp ? 8'd0 : lb_d),
        .ra(rd_addr), .q(lb1_q)
    );
    wire [7:0] spr_pen = lb_disp ? lb1_q : lb0_q;

    // -------------------------------------------------------- sprite engine
    // Runs in the hblank at the end of each line, filling the buffer for the
    // line about to be displayed. Worst case 24 sprites x 28 clocks = 672 of
    // the 1024 clocks between the end of one display window and the start of
    // the next.
    localparam [2:0] S_IDLE = 3'd0, S_A0 = 3'd1, S_A1 = 3'd2, S_A2 = 3'd3,
                     S_CHK  = 3'd4, S_G0 = 3'd5, S_G1 = 3'd6, S_PX = 3'd7;

    logic [2:0] st = S_IDLE;
    logic [5:0] offs;
    logic [7:0] s_sx, s_code, s_attr, s_ysrc, s_byte;
    logic [3:0] s_row;
    logic [1:0] s_grp, s_k;

    // target line: the one displayed next
    wire [7:0] tgt_y   = vcnt_next[7:0];
    wire [7:0] eff_y   = flip ? ~tgt_y : tgt_y;
    wire [9:0] row_sum = {2'b0, eff_y} + {2'b0, s_ysrc};
    wire       row_hit = (row_sum >= 10'd241) && (row_sum <= 10'd256);
    wire [3:0] row_idx = row_sum[3:0] - 4'd1;              // row_sum - 241

    wire [3:0] s_srow = s_attr[7] ? ~s_row : s_row;        // sprite flipy
    wire [3:0] s_col  = {s_grp, s_k};                      // source column
    wire [3:0] s_dcol = s_attr[6] ? s_col : ~s_col;        // flipx when bit 6 = 0
    wire [8:0] s_dx   = {1'b0, s_sx} + {5'b0, s_dcol};
    wire [8:0] s_dxf  = flip ? (9'd255 - s_dx) : s_dx;
    wire [1:0] s_pix  = {s_byte[3 - s_k], s_byte[7 - s_k]};

    wire spr_start = ce_pix && (hcnt == HLEAD[8:0] + HDISP[8:0] - 9'd1);
    wire last_sprite = (offs == 6'h10);

    always_comb begin
        spr_ra  = (st == S_A1) ? ({2'b00, offs} | 8'd1) : {2'b00, offs};
        sgfx_ra = {s_code, s_srow[3], s_grp, s_srow[2:0]};
        lb_we   = (st == S_PX) && (s_pix != 2'b00) && !s_dxf[8];
        lb_wa   = s_dxf[7:0];
        lb_d    = {s_attr[5:0], s_pix};
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            st <= S_IDLE;
        end else case (st)
            S_IDLE: if (spr_start) begin offs <= 6'h3e; st <= S_A0; end
            S_A0:   st <= S_A1;                       // address on the bus
            S_A1: begin                               // sr[offs] valid
                s_sx   <= spr0_vq;
                s_attr <= spr1_vq;
                st     <= S_A2;
            end
            S_A2: begin                               // sr[offs+1] valid
                s_code <= spr0_vq;
                s_ysrc <= spr1_vq;
                st     <= S_CHK;
            end
            S_CHK:
                if (row_hit) begin
                    s_row <= row_idx;
                    s_grp <= 2'd0;
                    st    <= S_G0;
                end else begin
                    offs <= offs - 6'd2;
                    st   <= last_sprite ? S_IDLE : S_A0;
                end
            S_G0: begin s_k <= 2'd0; st <= S_G1; end  // gfx address on the bus
            S_G1: begin s_byte <= sgfx_q; st <= S_PX; end
            S_PX:
                if (s_k != 2'd3) begin
                    s_k <= s_k + 2'd1;
                end else if (s_grp != 2'd3) begin
                    s_grp <= s_grp + 2'd1;
                    st    <= S_G0;
                end else begin
                    offs <= offs - 6'd2;
                    st   <= last_sprite ? S_IDLE : S_A0;
                end
            default: st <= S_IDLE;
        endcase
    end

    // The engine has 1024 clocks between the end of one display window and the
    // start of the next, against a worst case of 24 sprites x 28 = 672. This
    // flag is the cheap proof that the budget is really being met -- a sprite
    // engine that quietly runs out of time is the classic cause of flicker.
    always_ff @(posedge clk) begin
        if (reset) dbg_spr_overrun <= 1'b0;
        else if (ce_pix && (hcnt == HLEAD[8:0]) && (st != S_IDLE)) dbg_spr_overrun <= 1'b1;
    end

    // --------------------------------------------------------- colour PROMs
    // Three chained registered reads, all settling well inside one dot.
    wire       use_spr = !tile_cat && (spr_pen[1:0] != 2'b00);

    wire [7:0] e9_q, e12_q;
    tp_spram_dp #(.AW(8), .DW(8)) u_e9 (
        .clk(clk), .wa(dl_off_e9[7:0]), .we(dl_e9), .d(dl_data),
        .ra(spr_pen), .q(e9_q)
    );
    tp_spram_dp #(.AW(8), .DW(8)) u_e12 (
        .clk(clk), .wa(dl_off_e12[7:0]), .we(dl_e12), .d(dl_data),
        .ra({1'b0, char_pen}), .q(e12_q)
    );

    wire [3:0] col4    = use_spr ? e9_q[3:0] : e12_q[3:0];
    wire [4:0] pal_idx = {~use_spr, col4};      // chars live at 16..31

    wire [7:0] b4_q, b5_q;
    tp_spram_dp #(.AW(5), .DW(8)) u_b4 (
        .clk(clk), .wa(dl_off_b4[4:0]), .we(dl_b4), .d(dl_data),
        .ra(pal_idx), .q(b4_q)
    );
    tp_spram_dp #(.AW(5), .DW(8)) u_b5 (
        .clk(clk), .wa(dl_off_b5[4:0]), .we(dl_b5), .d(dl_data),
        .ra(pal_idx), .q(b5_q)
    );

    // 5-bit resistor DAC, weights summing to 255
    function automatic [7:0] gun(input [4:0] b);
        gun = (b[0] ? 8'h19 : 8'h00) + (b[1] ? 8'h24 : 8'h00)
            + (b[2] ? 8'h35 : 8'h00) + (b[3] ? 8'h40 : 8'h00)
            + (b[4] ? 8'h4d : 8'h00);
    endfunction

    wire [7:0] rgb_r = gun(b5_q[5:1]);
    wire [7:0] rgb_g = gun({b4_q[2:0], b5_q[7:6]});
    wire [7:0] rgb_b = gun(b4_q[7:3]);

    always_ff @(posedge clk) if (ce_pix) begin
        red    <= (video_enable && de_src) ? rgb_r : 8'h00;
        green  <= (video_enable && de_src) ? rgb_g : 8'h00;
        blue   <= (video_enable && de_src) ? rgb_b : 8'h00;
        de     <= de_src;
        hsync  <= hs_src;
        vsync  <= vs_src;
        hblank <= ~h_vis;
        vblank <= ~v_vis;
    end

endmodule

`default_nettype wire
