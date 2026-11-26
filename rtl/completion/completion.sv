// Completion: takes the responses of the five result sources (ALU, Branch
// Unit, load AGU, store AGU, load data from Memory) and, in the same cycle:
//   - drives the register write-back buses (PRFRename wb_*, RS wakeup), one
//     per source that writes a register: ALU, Branch Unit, load;
//   - drives the ROB response ports (retire_team resp_valid/resp): ALU,
//     Branch Unit, AGU (port 2, shared by the two AGUs), load.
// Wiring table: rtl/issue/README.md. Spec: docs/completion/Completion.md.

// STATUS: v2. Two AGUs (wiki decision 17): the source tells a load from a
// store, so there is no agu_is_load. ROB port 2 takes a store, or a load
// with an exception; when both come in the same cycle the older wins and the
// other gets resp_ready = 0 and comes back the next cycle (Completion.md).
// Unused on purpose: clk and reset (Completion is combinational; every block
// takes them).
module completion
  import execute_pkg::*;
#(
    localparam int WB_N  = 3, // register write-back buses: ALU, Branch Unit, load
    localparam int ROB_N = 4 // ROB response ports: ALU, Branch Unit, AGU, load
) (
    input  logic clk,
    input  logic reset,
    input  logic flush, // total flush from the ROB

    // Result sources (resp_valid / resp_ready / resp of each one)
    input  logic alu_resp_valid,
    output logic alu_resp_ready,
    input  fu_resp_t alu_resp,

    input  logic br_resp_valid,
    output logic br_resp_ready,
    input  fu_resp_t br_resp,

    input  logic agu_ld_resp_valid, // load AGU: answers the ROB only with an exception
    output logic agu_ld_resp_ready,
    input  fu_resp_t agu_ld_resp,

    input  logic agu_st_resp_valid, // store AGU: answers the ROB for every store
    output logic agu_st_resp_ready,
    input  fu_resp_t agu_st_resp,

    input  logic lsu_resp_valid, // load data back from Memory
    output logic lsu_resp_ready,
    input  fu_resp_t lsu_resp,

    // Register write-back: PRFRename wb_* and RS wb_*
    output logic [WB_N-1:0] wb_valid,
    output tag_t [WB_N-1:0] wb_tag, // meaningful only with wb_valid
    output xlen_t [WB_N-1:0] wb_data, // meaningful only with wb_valid

    // ROB responses: retire_team resp_valid / resp
    output logic [ROB_N-1:0] rob_resp_valid,
    output fu_resp_t [ROB_N-1:0] rob_resp
);

  logic unused;
  assign unused = &{1'b0, clk, reset};

  // Always ready, except the loser of a port-2 contest (below): PRFRename has
  // no wb_ready, the ROB has no ready either, and every other source has its
  // own bus. A response is consumed in the cycle it is valid, also during a
  // flush (when it is dropped).
  assign alu_resp_ready = 1'b1;
  assign br_resp_ready  = 1'b1;
  assign lsu_resp_ready = 1'b1;

  // Register write-back: bus 0 ALU, bus 1 Branch Unit, bus 2 load.
  // The AGU has no bus: its result is an address, not a register value.
  logic [WB_N-1:0] wsrc_valid;
  fu_resp_t [WB_N-1:0] wsrc;

  assign wsrc_valid[0] = alu_resp_valid;
  assign wsrc[0] = alu_resp;
  assign wsrc_valid[1] = br_resp_valid;
  assign wsrc[1] = br_resp;
  assign wsrc_valid[2] = lsu_resp_valid;
  assign wsrc[2] = lsu_resp;

  for (genvar p = 0; p < WB_N; p++) begin : g_wb
    // Never read wsrc[p].field (Icarus, AGENTS.md): copy the element first.
    fu_resp_t r;
    logic     unused_r;
    assign r        = wsrc[p];
    assign unused_r = &{1'b0, r.age, r.cause};   // only the ROB needs these

    // Only a real destination writes and wakes up dependents: not a branch or
    // a store (wr_en = 0), not tag 0 (x0, never allocated), not an
    // instruction that raised an exception.
    assign wb_valid[p] = wsrc_valid[p] && !flush && r.wr_en && (r.dst_tag != '0) && !r.exception;
    assign wb_tag[p] = r.dst_tag;
    assign wb_data[p] = r.result;
  end

  // ROB port 2, shared by the two AGUs. The store AGU answers for every store;
  // the load AGU only for an exception. A load without an exception finishes
  // on port 3, when its data arrives: answering on port 2 would let the ROB
  // commit the load before its register has a value.
  // Both candidates in one cycle (a store finishes while a load raises a
  // misalignment): the older goes out, the younger is held by its AGU
  // (resp_ready = 0) and goes out the next cycle. During a flush both are
  // consumed and dropped, as every other source.
  logic ld_cand, st_cand, contest, ld_wins;

  assign ld_cand = agu_ld_resp_valid && agu_ld_resp.exception;
  assign st_cand = agu_st_resp_valid;
  assign contest = ld_cand && st_cand;
  assign ld_wins = ld_cand && (!st_cand || age_is_younger(agu_st_resp.age, agu_ld_resp.age));

  assign agu_ld_resp_ready = flush || !(contest && !ld_wins);
  assign agu_st_resp_ready = flush || !(contest &&  ld_wins);

  // ROB responses: port 0 ALU, 1 Branch Unit, 2 AGU, 3 load.
  logic [ROB_N-1:0] rsrc_valid;

  assign rsrc_valid[0] = alu_resp_valid;
  assign rsrc_valid[1] = br_resp_valid;
  assign rsrc_valid[2] = ld_cand || st_cand;
  assign rsrc_valid[3] = lsu_resp_valid;

  assign rob_resp_valid = flush ? '0 : rsrc_valid;

  assign rob_resp[0] = alu_resp;
  assign rob_resp[1] = br_resp;
  assign rob_resp[2] = ld_wins ? agu_ld_resp : agu_st_resp;
  assign rob_resp[3] = lsu_resp;

endmodule
