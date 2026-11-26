// Core top: every pipeline block that exists, wired together.
//
//   fetch -> PipeFifo -> decode -> dispatch -> PRFRename -> rs_int -> alu
//                                                        -> rs_int -> (Branch Unit port)
//                                                        -> rs_mem -> agu (load)  -> (Memory port)
//                                                                  -> agu (store) -> (Memory port)
//                                           -> retire_team (ROB) -> commit -> PRFRename
//   alu / Branch Unit / agus / Memory -> completion -> PRFRename, RS wakeup, ROB
//
// Blocks that do not exist yet are ports of the core, so a testbench (or the
// future RTL) plays them:
//   - instruction memory: synchronous, one read port per slot (fetch);
//   - Branch Unit: takes br_req from rs_int, answers on br_resp and drives
//     the ROB redirect input;
//   - Memory: takes the responses of the load AGU (agu_ld_*) and of the
//     store AGU (agu_st_*), each with its side fields (op, store/load buffer
//     entry, color for a load, store data for a store; wiki Memory.md,
//     "Alocação no dispatch: interface"), and answers loads on lsu_resp;
//     st_commit/ld_commit tell it what the ROB committed. A response is
//     transferred when its valid is high: the AGU only holds one when the
//     Completion makes it wait for ROB port 2, which happens only to a load
//     with an exception or to a store. The store/load buffer reservation at
//     dispatch is not wired yet: the entries and colors are 0 until it is.
//
// Flush: the ROB flush is total (it empties the pipeline at commit). Every
// block flushes on it. The FUs only know the selective flush by age, so the
// core blocks new requests during the flush instead (req_valid && !flush):
// nothing enters a FU in the flush cycle, Completion drops whatever leaves
// one in that cycle, and the FU output register empties at the edge. The
// PipeFifo also flushes on the Decode redirect (JAL): the bundles behind the
// JAL are on the wrong path.
/* verilator lint_off PINCONNECTEMPTY */
module core
  import execute_pkg::*;
  import dispatch_pkg::*;
#(
    parameter int    W        = 3,      // retire_team requires 3
    parameter xlen_t RESET_PC = '0,
    parameter int    FQ_DEPTH = 4,      // bundles in the Fetch -> Decode FIFO
    parameter bit    DEEP2    = 1'b0    // retire_team variant
) (
    input  logic                    clk,
    input  logic                    reset,   // synchronous, active high

    // Instruction memory (fetch)
    output logic [W-1:0][XLEN-1:0]  imem_addr,
    input  logic [W-1:0][31:0]      imem_rdata,

    // Branch Unit
    output logic                    br_req_valid,
    input  logic                    br_req_ready,
    output fu_req_t                 br_req,
    input  logic                    br_resp_valid,
    output logic                    br_resp_ready,
    input  fu_resp_t                br_resp,
    input  redirect_t               br_redirect,

    // Memory: load AGU
    output logic                    agu_ld_resp_valid,
    output fu_resp_t                agu_ld_resp,     // address in result
    output exec_op_t                agu_ld_op,       // access size and sign
    output lsq_idx_t                agu_ld_lsq_idx,  // load buffer entry
    output sb_ptr_t                 agu_ld_color,    // last older store entry
    // Memory: store AGU
    output logic                    agu_st_resp_valid,
    output fu_resp_t                agu_st_resp,     // address in result
    output xlen_t                   agu_st_store_data,
    output exec_op_t                agu_st_op,       // access size
    output lsq_idx_t                agu_st_lsq_idx,  // store buffer entry
    // Memory: load data and commit
    input  logic                    lsu_resp_valid,
    output logic                    lsu_resp_ready,
    input  fu_resp_t                lsu_resp,
    output logic [W-1:0]            st_commit,
    output logic [W-1:0]            ld_commit,
    input  logic                    lsu_ready,
    output logic                    flush,   // total flush: drop loads in flight

    // Commit stream (observation)
    output logic [W-1:0]            commit_valid,
    output reg_t [W-1:0]            commit_rd,
    output tag_t [W-1:0]            commit_tag,
    output logic                    rob_empty
);

  localparam int WB_N   = 3;   // write-back buses: ALU, Branch Unit, load
  localparam int READ_N = 7;   // PRF read ports: 0-1 ALU, 2-3 Branch Unit, 4 load AGU, 5-6 store AGU
  localparam int ROB_N  = 4;   // ROB response ports: ALU, Branch Unit, AGU, load
  localparam int FQ_W   = W + W * XLEN + W * 32;   // {slot_valid, pc, inst}
  localparam int SB_CNT_W = $clog2(SB_ENTRIES + 1);
  localparam int LB_CNT_W = $clog2(LB_ENTRIES + 1);

  // ---------------------------------------------------------------------------
  // Wires
  // ---------------------------------------------------------------------------
  // fetch -> PipeFifo
  logic                        f_valid, f_ready;
  logic [W-1:0]                f_slot_valid;
  logic [W-1:0][31:0]          f_inst;
  logic [W-1:0][XLEN-1:0]      f_pc;

  // PipeFifo -> decode
  logic                        d_in_valid, d_in_ready;
  logic [FQ_W-1:0]             fq_in, fq_out;
  logic [W-1:0]                d_slot_valid;
  logic [W-1:0][31:0]          d_inst;
  logic [W-1:0][XLEN-1:0]      d_pc;

  // decode -> fetch (JAL)
  logic                        dec_redirect_valid;
  xlen_t                       dec_redirect_pc;

  // ROB -> fetch
  logic                        be_redirect_valid;
  xlen_t                       be_redirect_pc;

  // decode -> dispatch / rename
  logic                        dec_valid, dec_ready;
  uop_t [W-1:0]                dec_uop;
  logic [W-1:0][W-1:0]         dep_rs1, dep_rs2, dep_rd;

  // dispatch <-> rename
  logic                        ren_dispatch_valid, ren_dispatch_ready;
  logic [W-1:0]                ren_slot_valid, ren_writes_rd;
  logic [W-1:0][REG_W-1:0]     ren_rs1, ren_rs2, ren_rd;
  logic                        ren_rob_ready, ren_rs_ready;
  logic [W-1:0][1:0]           ren_src_ready;
  logic [W-1:0][TAG_W-1:0]     ren_src1_tag, ren_src2_tag, ren_dst_tag, ren_old_tag;

  // dispatch <-> ROB
  logic [5:0]                  rob_free;
  age_t [W-1:0]                rob_age;
  logic [W-1:0]                rob_alloc;
  rob_entry_t [W-1:0]          rob_entry;
  uop_t [W-1:0]                rob_uop;

  // dispatch -> RS
  logic [3:0]                  int_free;
  logic [W-1:0]                int_wr;
  rs_int_entry_t [W-1:0]       int_entry;
  logic [2:0]                  mem_free;
  logic [W-1:0]                mem_wr;
  rs_mem_entry_t [W-1:0]       mem_entry;

  // write-back buses
  logic [WB_N-1:0]             wb_valid;
  logic [WB_N-1:0][TAG_W-1:0]  wb_tag;
  logic [WB_N-1:0][XLEN-1:0]   wb_data;

  // PRF read ports
  logic [READ_N-1:0][TAG_W-1:0] rd_tag;
  logic [READ_N-1:0]            rd_valid;
  logic [READ_N-1:0][XLEN-1:0]  rd_data;

  // RS -> FUs
  logic                        alu_rs_valid, alu_req_ready;
  fu_req_t                     alu_req;
  logic                        agu_ld_rs_valid, agu_ld_req_ready;
  fu_req_t                     agu_ld_req;
  lsq_idx_t                    agu_ld_req_lsq_idx;
  sb_ptr_t                     agu_ld_req_color;
  logic                        agu_st_rs_valid, agu_st_req_ready;
  fu_req_t                     agu_st_req;
  lsq_idx_t                    agu_st_req_lsq_idx;

  // FUs -> completion
  logic                        alu_resp_valid, alu_resp_ready;
  fu_resp_t                    alu_resp;
  logic                        agu_ld_resp_ready, agu_st_resp_ready;

  // completion -> ROB
  logic [ROB_N-1:0]            rob_resp_valid;
  fu_resp_t [ROB_N-1:0]        rob_resp;

  // ROB -> rename
  tag_t [W-1:0]                commit_old_tag;

  // ---------------------------------------------------------------------------
  // Front end
  // ---------------------------------------------------------------------------
  fetch #(.WIDTH(W), .RESET_PC(RESET_PC)) u_fetch (
      .clk, .reset,
      .imem_addr, .imem_rdata,
      .out_valid      (f_valid),
      .out_ready      (f_ready),
      .out_slot_valid (f_slot_valid),
      .out_inst       (f_inst),
      .out_pc         (f_pc),
      .dec_redirect_valid, .dec_redirect_pc,
      .be_redirect_valid, .be_redirect_pc
  );

  assign fq_in = {f_slot_valid, f_pc, f_inst};
  assign {d_slot_valid, d_pc, d_inst} = fq_out;

  PipeFifo #(.DATA_W(FQ_W), .DEPTH(FQ_DEPTH)) u_fetch_q (
      .clk, .reset,
      .flush     (flush || dec_redirect_valid),
      .in_valid  (f_valid),
      .in_ready  (f_ready),
      .in_data   (fq_in),
      .out_valid (d_in_valid),
      .out_ready (d_in_ready),
      .out_data  (fq_out)
  );

  decode #(.WIDTH(W)) u_decode (
      .clk, .reset, .flush,
      .in_valid       (d_in_valid),
      .in_ready       (d_in_ready),
      .in_slot_valid  (d_slot_valid),
      .in_inst        (d_inst),
      .in_pc          (d_pc),
      .out_valid      (dec_valid),
      .out_ready      (dec_ready),
      .out_uop        (dec_uop),
      .out_dep_rs1    (dep_rs1),
      .out_dep_rs2    (dep_rs2),
      .out_dep_rd     (dep_rd),
      .redirect_valid (dec_redirect_valid),
      .redirect_pc    (dec_redirect_pc),
      .out_slot_kill  ()     // the killed slots already arrive with uop.valid = 0
  );

  // ---------------------------------------------------------------------------
  // Dispatch and rename
  // ---------------------------------------------------------------------------
  dispatch #(.W(W)) u_dispatch (
      .clk, .reset, .flush,
      .dec_valid, .dec_uop, .dec_ready,
      .ren_dispatch_valid, .ren_slot_valid, .ren_rs1, .ren_rs2, .ren_rd,
      .ren_writes_rd, .ren_rob_ready, .ren_rs_ready,
      .ren_dispatch_ready, .ren_src_ready, .ren_src1_tag, .ren_src2_tag,
      .ren_dst_tag, .ren_old_tag,
      .rob_free, .rob_age, .rob_alloc, .rob_entry, .rob_uop,
      .int_free, .int_wr, .int_entry,
      .mem_free, .mem_wr, .mem_entry,
      // The store buffer and the load buffer do not exist in the core yet
      // (the Memory is a port): they always have room and every reservation
      // gets entry 0. Nothing reads the indices until the Memory is wired.
      .sb_free  (SB_CNT_W'(SB_ENTRIES)), .sb_tail ('0), .sb_alloc (),
      .lb_free  (LB_CNT_W'(LB_ENTRIES)), .lb_tail ('0), .lb_alloc ()
  );

  PRFRename #(.XLEN(XLEN), .ENTRIES(PRF_ENTRIES), .W(W), .WB_N(WB_N), .READ_N(READ_N)) u_rename (
      .clk, .reset, .flush,
      .dispatch_valid (ren_dispatch_valid),
      .slot_valid     (ren_slot_valid),
      .rs1            (ren_rs1),
      .rs2            (ren_rs2),
      .rd             (ren_rd),
      .writes_rd      (ren_writes_rd),
      .rs1_dep        (dep_rs1),
      .rs2_dep        (dep_rs2),
      .rd_dep         (dep_rd),
      .rob_ready      (ren_rob_ready),
      .rs_ready       (ren_rs_ready),
      .dispatch_ready (ren_dispatch_ready),
      .src_ready      (ren_src_ready),
      .src1_tag       (ren_src1_tag),
      .src2_tag       (ren_src2_tag),
      .dst_tag        (ren_dst_tag),
      .old_tag        (ren_old_tag),
      .wb_valid, .wb_tag, .wb_data,
      .read_tag       (rd_tag),
      .read_valid     (rd_valid),
      .read_data      (rd_data),
      .commit_valid, .commit_rd, .commit_tag, .commit_old_tag
  );

  // ---------------------------------------------------------------------------
  // Issue
  // ---------------------------------------------------------------------------
  rs_int #(.W(W), .WB_N(WB_N)) u_rs_int (
      .clk, .reset, .flush,
      .wr (int_wr), .wr_entry (int_entry), .free (int_free),
      .wb_valid, .wb_tag,
      .alu_req_valid  (alu_rs_valid),
      .alu_req_ready,
      .alu_req,
      .alu_read_tag   (rd_tag[1:0]),
      .alu_read_valid (rd_valid[1:0]),
      .alu_read_data  (rd_data[1:0]),
      .br_req_valid, .br_req_ready, .br_req,
      .br_read_tag    (rd_tag[3:2]),
      .br_read_valid  (rd_valid[3:2]),
      .br_read_data   (rd_data[3:2])
  );

  rs_mem #(.W(W), .WB_N(WB_N)) u_rs_mem (
      .clk, .reset, .flush,
      .wr (mem_wr), .wr_entry (mem_entry), .free (mem_free),
      .wb_valid, .wb_tag,
      .agu_ld_req_valid  (agu_ld_rs_valid),
      .agu_ld_req_ready,
      .agu_ld_req,
      .agu_ld_req_lsq_idx, .agu_ld_req_color,
      .agu_ld_read_tag   (rd_tag[4]),
      .agu_ld_read_valid (rd_valid[4]),
      .agu_ld_read_data  (rd_data[4]),
      .agu_st_req_valid  (agu_st_rs_valid),
      .agu_st_req_ready,
      .agu_st_req,
      .agu_st_req_lsq_idx,
      .agu_st_read_tag   (rd_tag[6:5]),
      .agu_st_read_valid (rd_valid[6:5]),
      .agu_st_read_data  (rd_data[6:5])
  );

  // ---------------------------------------------------------------------------
  // Execute. The ROB flush is total, so no request enters a FU during it and
  // flush_age is not used (see the header).
  // ---------------------------------------------------------------------------
  alu u_alu (
      .clk, .reset, .flush, .flush_age ('0),
      .req_valid  (alu_rs_valid && !flush),
      .req_ready  (alu_req_ready),
      .req        (alu_req),
      .resp_valid (alu_resp_valid),
      .resp_ready (alu_resp_ready),
      .resp       (alu_resp)
  );

  // Two AGUs (wiki decision 17): one for loads, one for stores. resp_is_load
  // is not needed: the AGU a response comes from tells its kind.
  agu u_agu_ld (
      .clk, .reset, .flush, .flush_age ('0),
      .req_valid    (agu_ld_rs_valid && !flush),
      .req_ready    (agu_ld_req_ready),
      .req          (agu_ld_req),
      .req_lsq_idx  (agu_ld_req_lsq_idx),
      .req_color    (agu_ld_req_color),
      .resp_valid   (agu_ld_resp_valid),
      .resp_ready   (agu_ld_resp_ready),
      .resp         (agu_ld_resp),
      .resp_is_load (),
      .resp_store_data (),
      .resp_op      (agu_ld_op),
      .resp_lsq_idx (agu_ld_lsq_idx),
      .resp_color   (agu_ld_color)
  );

  agu u_agu_st (
      .clk, .reset, .flush, .flush_age ('0),
      .req_valid    (agu_st_rs_valid && !flush),
      .req_ready    (agu_st_req_ready),
      .req          (agu_st_req),
      .req_lsq_idx  (agu_st_req_lsq_idx),
      .req_color    ('0),
      .resp_valid   (agu_st_resp_valid),
      .resp_ready   (agu_st_resp_ready),
      .resp         (agu_st_resp),
      .resp_is_load (),
      .resp_store_data (agu_st_store_data),
      .resp_op      (agu_st_op),
      .resp_lsq_idx (agu_st_lsq_idx),
      .resp_color   ()
  );

  // ---------------------------------------------------------------------------
  // Completion and ROB
  // ---------------------------------------------------------------------------
  completion u_completion (
      .clk, .reset, .flush,
      .alu_resp_valid, .alu_resp_ready, .alu_resp,
      .br_resp_valid,  .br_resp_ready,  .br_resp,
      .agu_ld_resp_valid, .agu_ld_resp_ready, .agu_ld_resp,
      .agu_st_resp_valid, .agu_st_resp_ready, .agu_st_resp,
      .lsu_resp_valid, .lsu_resp_ready, .lsu_resp,
      .wb_valid, .wb_tag, .wb_data,
      .rob_resp_valid, .rob_resp
  );

  retire_team #(.W(W), .WB_N(ROB_N), .DEEP2(DEEP2)) u_rob (
      .clk, .reset,
      .rob_alloc, .rob_entry, .rob_uop,
      .rob_sys_kind     ('0),            // no sys_kind in uop_t yet
      .rob_free, .rob_age,
      .resp_valid       (rob_resp_valid),
      .resp             (rob_resp),
      .redirect         (br_redirect),
      .commit_valid, .commit_rd, .commit_tag, .commit_old_tag,
      .flush,
      .be_redirect_valid, .be_redirect_pc,
      .st_commit, .ld_commit, .lsu_ready,
      .mtvec_wr_valid   (1'b0),          // no CSR instructions execute yet
      .mtvec_wr_data    ('0),
      .csr_rd_addr      ('0),
      .csr_rd_data      (),
      .csr_rd_hit       (),
      .rob_empty,
      .rob_full         (),
      .flush_busy       ()
  );

endmodule
/* verilator lint_on PINCONNECTEMPTY */
