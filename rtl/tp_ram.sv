//------------------------------------------------------------------------------
// Block RAM primitives for the Time Pilot core.
//
// The whole romset is 53 KB, so everything -- program, gfx, PROMs, work RAM --
// lives in block RAM and every access is single cycle. Reads are registered:
// drive the address on cycle N, the data is valid on cycle N+1.
//------------------------------------------------------------------------------
`default_nettype none

//! One write port, one read port. Read-during-write to the same address
//! returns the old contents, which is what Quartus infers for this style.
module tp_spram_dp #(parameter AW = 8, parameter DW = 8) (
    input  wire           clk,
    input  wire  [AW-1:0] wa,
    input  wire           we,
    input  wire  [DW-1:0] d,
    input  wire  [AW-1:0] ra,
    output logic [DW-1:0] q
);
    logic [DW-1:0] mem [0:(1<<AW)-1];
    initial for (int i = 0; i < (1<<AW); i++) mem[i] = '0;
    always_ff @(posedge clk) begin
        if (we) mem[wa] <= d;
        q <= mem[ra];
    end
endmodule

//! True dual port: two independent read/write ports on one array.
module tp_dpram #(parameter AW = 10, parameter DW = 8) (
    input  wire           clk,
    input  wire  [AW-1:0] a_addr,
    input  wire           a_we,
    input  wire  [DW-1:0] a_d,
    output logic [DW-1:0] a_q,
    input  wire  [AW-1:0] b_addr,
    input  wire           b_we,
    input  wire  [DW-1:0] b_d,
    output logic [DW-1:0] b_q
);
    logic [DW-1:0] mem [0:(1<<AW)-1];
    initial for (int i = 0; i < (1<<AW); i++) mem[i] = '0;
    always_ff @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_d;
        a_q <= mem[a_addr];
        if (b_we) mem[b_addr] <= b_d;
        b_q <= mem[b_addr];
    end
endmodule

`default_nettype wire
