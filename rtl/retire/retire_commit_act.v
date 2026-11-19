`default_nettype none

module retire_commit_act #(
    parameter LANES  = 3,
    parameter AREG_W = 5,
    parameter PREG_W = 7
) (
    input  wire [LANES-1:0]         cm_mask,
    input  wire [LANES-1:0]         h_has_dst,
    input  wire [LANES-1:0]         h_store,
    input  wire [LANES-1:0]         h_load,
    input  wire [LANES*AREG_W-1:0]  h_ldst,
    input  wire [LANES*PREG_W-1:0]  h_pdst,
    input  wire [LANES*PREG_W-1:0]  h_stale,
    output wire [LANES-1:0]         act_commit_valid,
    output wire [LANES-1:0]         act_free_valid,
    output wire [LANES*PREG_W-1:0]  act_free_preg,
    output wire [LANES-1:0]         act_st_valid,
    output wire [LANES-1:0]         act_ld_valid,
    output wire [LANES-1:0]         act_is_store,
    output wire [LANES-1:0]         act_rrat_we,
    output wire [LANES*AREG_W-1:0]  act_rrat_ldst,
    output wire [LANES*PREG_W-1:0]  act_rrat_pdst,
    output wire [1:0]               act_instret
);

  assign act_commit_valid = cm_mask;
  assign act_free_valid   = cm_mask & h_has_dst;
  assign act_st_valid     = cm_mask & h_store;
  assign act_ld_valid     = cm_mask & h_load;
  assign act_is_store     = cm_mask & h_store;
  assign act_rrat_we      = cm_mask & h_has_dst;
  assign act_instret      = {1'b0, cm_mask[0]} + {1'b0, cm_mask[1]} + {1'b0, cm_mask[2]};

  assign act_free_preg    = h_stale;
  assign act_rrat_ldst    = h_ldst;
  assign act_rrat_pdst    = h_pdst;

endmodule
`default_nettype wire
