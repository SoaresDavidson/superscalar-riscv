`default_nettype none

`include "retire/retire_defs.vh"

module retire_rob_bank #(
    parameter ROB_ROWS  = 16,
    parameter ROB_ROW_W = 4,
    parameter AREG_W    = 5,
    parameter PREG_W    = 7,
    parameter KIND_W    = 4,
    parameter XC_PORTS  = 2
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      clr,

    input  wire                      a_we,
    input  wire [ROB_ROW_W-1:0]      a_row,
    input  wire                      a_valid,
    input  wire                      a_done,
    input  wire                      a_exc,
    input  wire [AREG_W-1:0]         a_ldst,
    input  wire                      a_has_dst,
    input  wire [PREG_W-1:0]         a_pdst,
    input  wire [PREG_W-1:0]         a_stale,
    input  wire [KIND_W-1:0]         a_kind,

    input  wire [ROB_ROWS-1:0]       wb_hit,
    input  wire [ROB_ROWS-1:0]       xc_hit,
    input  wire [XC_PORTS*ROB_ROWS-1:0] xc_hit_p_in,
    output wire [XC_PORTS-1:0]       xc_acc,

    input  wire [ROB_ROWS-1:0]       kill_hit,
    input  wire [ROB_ROWS-1:0]       kill_m,
    output wire                      kill_live,

    input  wire [ROB_ROW_W-1:0]      h_row,
    input  wire                      h_clr,
    output wire                      h_valid,
    output wire                      h_done,
    output wire                      h_exc,
    output wire [AREG_W-1:0]         h_ldst,
    output wire                      h_has_dst,
    output wire [PREG_W-1:0]         h_pdst,
    output wire [PREG_W-1:0]         h_stale,
    output wire [`RETIRE_FL_W-1:0]   h_flags
);

  reg [ROB_ROWS-1:0] valid_q;
  reg [ROB_ROWS-1:0] done_q;
  reg [ROB_ROWS-1:0] exc_q;

  reg [AREG_W-1:0]        ldst_m  [0:ROB_ROWS-1];
  reg                     has_m   [0:ROB_ROWS-1];
  reg [PREG_W-1:0]        pdst_m  [0:ROB_ROWS-1];
  reg [PREG_W-1:0]        stale_m [0:ROB_ROWS-1];
  reg [`RETIRE_FL_W-1:0]  flags_m [0:ROB_ROWS-1];

  wire [ROB_ROWS-1:0] row_one = {{(ROB_ROWS-1){1'b0}}, 1'b1};
  wire [ROB_ROWS-1:0] a_oh = a_we  ? (row_one << a_row) : {ROB_ROWS{1'b0}};
  wire [ROB_ROWS-1:0] c_oh = h_clr ? (row_one << h_row) : {ROB_ROWS{1'b0}};

  wire [ROB_ROWS-1:0] set_done = valid_q & (wb_hit | xc_hit);
  wire [ROB_ROWS-1:0] set_exc  = valid_q & xc_hit & ~done_q & ~wb_hit;

  wire [XC_PORTS*ROB_ROWS-1:0] xc_hit_p = xc_hit_p_in & ~{XC_PORTS{kill_m}};

  assign kill_live = |(valid_q & kill_hit);

  genvar gp;
  generate
    for (gp = 0; gp < XC_PORTS; gp = gp + 1) begin : g_acc
      assign xc_acc[gp] = |(xc_hit_p[gp*ROB_ROWS +: ROB_ROWS] & set_exc);
    end
  endgenerate

  wire [`RETIRE_FL_W-1:0] a_flags;
  assign a_flags[`RETIRE_FL_SERIAL] = (a_kind >= `RETIRE_K_CSR) & (a_kind <= `RETIRE_K_FENCEI);
  assign a_flags[`RETIRE_FL_MRET]   = (a_kind == `RETIRE_K_MRET);
  assign a_flags[`RETIRE_FL_STORE]  = (a_kind == `RETIRE_K_STORE);
  assign a_flags[`RETIRE_FL_LOAD]   = (a_kind == `RETIRE_K_LOAD);

  wire [ROB_ROWS-1:0] av = {ROB_ROWS{a_valid}};
  wire [ROB_ROWS-1:0] ad = {ROB_ROWS{a_done}};
  wire [ROB_ROWS-1:0] ae = {ROB_ROWS{a_exc}};
  wire [ROB_ROWS-1:0] keep = ~a_oh & ~c_oh;

  wire [ROB_ROWS-1:0] n_valid = clr ? {ROB_ROWS{1'b0}} : (((a_oh & av) | (keep & valid_q)) & ~kill_m);
  wire [ROB_ROWS-1:0] n_done  = clr ? {ROB_ROWS{1'b0}} : (((a_oh & ad) | (keep & (done_q | set_done))) & ~kill_m);
  wire [ROB_ROWS-1:0] n_exc   = clr ? {ROB_ROWS{1'b0}} : (((a_oh & ae) | (keep & (exc_q | set_exc))) & ~kill_m);

  always @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= {ROB_ROWS{1'b0}};
      done_q  <= {ROB_ROWS{1'b0}};
      exc_q   <= {ROB_ROWS{1'b0}};
    end else begin
      valid_q <= n_valid;
      done_q  <= n_done;
      exc_q   <= n_exc;
    end
  end

  always @(posedge clk) begin
    if (a_we) begin
      ldst_m[a_row]  <= a_ldst;
      has_m[a_row]   <= a_has_dst;
      pdst_m[a_row]  <= a_pdst;
      stale_m[a_row] <= a_stale;
      flags_m[a_row] <= a_flags;
    end
  end

  assign h_valid   = valid_q[h_row];
  assign h_done    = done_q[h_row];
  assign h_exc     = exc_q[h_row];
  assign h_ldst    = ldst_m[h_row];
  assign h_has_dst = has_m[h_row];
  assign h_pdst    = pdst_m[h_row];
  assign h_stale   = stale_m[h_row];
  assign h_flags   = flags_m[h_row];

endmodule
`default_nettype wire
