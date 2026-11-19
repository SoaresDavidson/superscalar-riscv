`default_nettype none

module retire_flush_gen #(
    parameter LANES   = 3,
    parameter PC_W    = 64,
    parameter CAUSE_W = 5
) (
    input  wire                 exc_at_head,
    input  wire [LANES-1:0]     exc_lane,
    input  wire [LANES-1:0]     cm_mask,
    input  wire [LANES-1:0]     h_mret,
    input  wire [PC_W-1:0]      h_rowpc,
    input  wire [CAUSE_W-1:0]   xcause,
    input  wire                 xredir,
    input  wire [PC_W-1:0]      xtval_pc,
    input  wire [PC_W-1:0]      mtvec_pc,
    input  wire [PC_W-1:0]      mepc_pc,
    output wire                 flush_dec,
    output wire                 f_trap,
    output wire                 f_mret,
    output wire [PC_W-1:0]      f_pc,
    output wire [CAUSE_W-1:0]   f_cause,
    output wire [PC_W-1:0]      f_lane_pc
);

  assign f_mret    = |(cm_mask & h_mret);
  assign flush_dec = exc_at_head | f_mret;
  assign f_trap    = exc_at_head & ~xcause[CAUSE_W-1];
  wire   f_replay  = exc_at_head & xcause[CAUSE_W-1] & ~xredir;
  wire   f_redir   = exc_at_head & xredir;

  wire [1:0] lane = exc_lane[2] ? 2'd2 : (exc_lane[1] ? 2'd1 : 2'd0);

  assign f_lane_pc = {h_rowpc[PC_W-1:2] + {{(PC_W-4){1'b0}}, lane}, h_rowpc[1:0]};

  assign f_pc    = f_trap ? mtvec_pc : (f_redir ? xtval_pc : (f_replay ? f_lane_pc : mepc_pc));
  assign f_cause = xcause & {CAUSE_W{exc_at_head}};

  wire unused_ok = &{1'b0, exc_lane[0]};

endmodule
`default_nettype wire
