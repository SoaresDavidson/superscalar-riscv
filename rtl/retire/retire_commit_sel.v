`default_nettype none

module retire_commit_sel #(
    parameter LANES = 3
) (
    input  wire [LANES-1:0] h_valid,
    input  wire [LANES-1:0] h_done,
    input  wire [LANES-1:0] h_exc,
    input  wire [LANES-1:0] h_serial,
    input  wire [LANES-1:0] h_store,
    input  wire             lsu_q,
    input  wire             fl_block,
    input  wire             xredir,
    output wire [LANES-1:0] cm_mask,
    output wire             head_adv,
    output wire [LANES-1:0] exc_lane,
    output wire             exc_at_head
);

  reg [LANES-1:0] cm;
  reg [LANES-1:0] blocked;
  reg [LANES-1:0] rd_ok;
  reg             sel_ok;
  reg             sel_any;
  reg             st_run;
  integer         k;

  always @* begin
    sel_ok  = 1'b1;
    sel_any = 1'b0;
    st_run  = 1'b0;
    cm      = {LANES{1'b0}};
    blocked = {LANES{1'b0}};
    rd_ok   = {LANES{1'b0}};
    for (k = 0; k < LANES; k = k + 1) begin
      blocked[k] = h_serial[k] & sel_any;
      blocked[k] = blocked[k] | (h_store[k] & (st_run | ~lsu_q));
      rd_ok[k]   = h_exc[k] & xredir & ~sel_any;
      cm[k]      = h_valid[k] & h_done[k] & (~h_exc[k] | rd_ok[k]) & ~blocked[k] & sel_ok & ~fl_block;
      sel_ok     = sel_ok & (~h_valid[k] | cm[k]) & ~(cm[k] & (h_serial[k] | h_exc[k]));
      sel_any    = sel_any | cm[k];
      st_run     = st_run | (cm[k] & h_store[k]);
    end
  end

  assign cm_mask  = cm;

  assign head_adv = (|cm) & ~(|(h_valid & ~cm));

  wire [LANES-1:0] lowest = h_valid & (~h_valid + {{(LANES-1){1'b0}}, 1'b1});
  assign exc_lane    = lowest & h_done & h_exc;
  assign exc_at_head = |exc_lane;

endmodule
`default_nettype wire
