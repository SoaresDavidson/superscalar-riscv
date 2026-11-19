`default_nettype none

`include "retire/retire_params.vh"
`include "retire/retire_defs.vh"

module retire_base #(
`include "retire/retire_param_list.vh"
) (
`include "retire/retire_ports.vh"
);

  generate
    if ((ROB_ROWS & (ROB_ROWS - 1)) != 0) begin : g_assert_rob_rows_pow2
      ERROR_ROB_ROWS_MUST_BE_POWER_OF_TWO u_assert ();
    end
    if (ROB_ROWS < 2) begin : g_assert_rob_rows_min
      ERROR_ROB_ROWS_MUST_BE_AT_LEAST_2 u_assert ();
    end
    if (LANES != 3) begin : g_assert_lanes
      ERROR_LANES_MUST_BE_3 u_assert ();
    end
    if (MTVEC_RESET[1:0] != 2'b00) begin : g_assert_mtvec_align
      ERROR_MTVEC_RESET_MUST_BE_4_BYTE_ALIGNED u_assert ();
    end
    if ((1 << PREG_W) < NUM_PREGS || NUM_AREGS != (1 << AREG_W)
        || KIND_W != 4 || CAUSE_W != 5
        || ROB_ROW_W != $clog2(ROB_ROWS) || TAG_W != ROB_ROW_W + 3) begin : g_assert_derived
      ERROR_INCONSISTENT_DERIVED_PARAMETERS u_assert ();
    end
  endgenerate

  wire                 flush_dec;

  wire                 kill_acc;
  wire [ROB_ROW_W:0]   kill_ptr_c;
  wire                 hook_fl_block   = flush_dec;
  wire                 hook_sel_block  = 1'b0;
  wire                 hook_kill_valid = kill_acc;
  wire [ROB_ROW_W:0]   hook_kill_ptr   = kill_ptr_c;
  wire                 hook_rob_clr    = flush_dec;

  wire                      fire;
  wire [ROB_ROW_W:0]        head_q;
  wire [ROB_ROW_W:0]        tail_q;
  wire                      ready_q;
  wire                      full_q;
  wire                      empty_q;
  wire [LANES*ROB_ROWS-1:0] wb_hit;
  wire [LANES*ROB_ROWS-1:0] xc_hit;
  wire [LANES*XC_PORTS*ROB_ROWS-1:0] xc_hit_pp;
  wire [PC_W-1:0]           h_rowpc;
  wire [LANES-1:0]          cm_mask;
  wire                      head_adv;
  wire                      exc_at_head;
  wire [LANES-1:0]          exc_lane;
  wire [LANES*ROB_ROWS-1:0] kill_hit;
  wire [LANES*ROB_ROWS-1:0] kill_m;
  wire [LANES-1:0]          kill_live;
  wire                      squash_q;
  wire [TAG_W-1:0]          squash_tag_q;
  wire                      lsu_q;

  retire_rob_ctrl #(
      .ROB_ROWS (ROB_ROWS),
      .ROB_ROW_W(ROB_ROW_W),
      .TAG_W    (TAG_W),
      .LANES    (LANES),
      .PC_W     (PC_W),
      .WB_PORTS (WB_PORTS),
      .XC_PORTS (XC_PORTS)
  ) u_ctrl (
      .clk          (clk),
      .rst_n        (rst_n),
      .clr          (hook_rob_clr),
      .fl_block     (hook_fl_block),
      .kill_valid   (hook_kill_valid),
      .kill_ptr     (hook_kill_ptr),

      .alloc_valid  (alloc_valid & (|alloc_lane_valid)),
      .br_kill_valid(br_kill_valid),
      .br_kill_tag  (br_kill_tag),
      .commit_lsu_ready(commit_lsu_ready),
      .kill_live    (kill_live),
      .alloc_pc     (alloc_pc),
      .head_adv     (head_adv),
      .wb_valid     (wb_valid),
      .wb_tag       (wb_tag),
      .xc_valid     (xc_valid),
      .xc_tag       (xc_tag),
      .fire         (fire),
      .head_q       (head_q),
      .tail_q       (tail_q),
      .ready_q      (ready_q),
      .full_q       (full_q),
      .empty_q      (empty_q),
      .wb_hit       (wb_hit),
      .xc_hit       (xc_hit),
      .xc_hit_pp    (xc_hit_pp),
      .h_rowpc      (h_rowpc),
      .kill_hit     (kill_hit),
      .kill_acc     (kill_acc),
      .kill_ptr_c   (kill_ptr_c),
      .kill_m       (kill_m),
      .squash_q     (squash_q),
      .squash_tag_q (squash_tag_q),
      .lsu_q        (lsu_q)
  );

  wire [ROB_ROW_W-1:0]     t_row = tail_q[ROB_ROW_W-1:0];
  wire [ROB_ROW_W-1:0]     h_row = head_q[ROB_ROW_W-1:0];
  wire [LANES-1:0]         h_valid;
  wire [LANES-1:0]         h_done;
  wire [LANES-1:0]         h_exc;
  wire [LANES-1:0]         h_has_dst;
  wire [LANES*AREG_W-1:0]  h_ldst;
  wire [LANES*PREG_W-1:0]  h_pdst;
  wire [LANES*PREG_W-1:0]  h_stale;
  wire [LANES-1:0]         h_serial;
  wire [LANES-1:0]         h_mret;
  wire [LANES-1:0]         h_store;
  wire [LANES-1:0]         h_load;

  wire [LANES-1:0]               a_exc_v;
  wire [LANES*XC_PORTS-1:0]      xc_acc_l;
  wire [XC_PORTS-1:0]            xc_acc_p;

  genvar gk;
  genvar gq;
  generate
    for (gk = 0; gk < LANES; gk = gk + 1) begin : g_bank
      wire [`RETIRE_FL_W-1:0] fl;
      wire                    a_valid = alloc_lane_valid[gk];
      wire                    a_exc   = a_valid & alloc_exc_valid[gk]
                                & ~((alloc_kind[gk*KIND_W +: KIND_W] == `RETIRE_K_MRET)
                                    & alloc_exc_cause[gk*CAUSE_W + CAUSE_W - 1]);
      wire                    a_done  = a_valid & (alloc_done[gk] | alloc_exc_valid[gk]);

      retire_rob_bank #(
          .ROB_ROWS (ROB_ROWS),
          .ROB_ROW_W(ROB_ROW_W),
          .AREG_W   (AREG_W),
          .PREG_W   (PREG_W),
          .KIND_W   (KIND_W),
          .XC_PORTS (XC_PORTS)
      ) u_bank (
          .clk      (clk),
          .rst_n    (rst_n),
          .clr      (hook_rob_clr),
          .a_we     (fire),
          .a_row    (t_row),
          .a_valid  (a_valid),
          .a_done   (a_done),
          .a_exc    (a_exc),
          .a_ldst   (alloc_ldst[gk*AREG_W +: AREG_W]),
          .a_has_dst(alloc_has_dst[gk]),
          .a_pdst   (alloc_pdst[gk*PREG_W +: PREG_W]),
          .a_stale  (alloc_stale[gk*PREG_W +: PREG_W]),
          .a_kind   (alloc_kind[gk*KIND_W +: KIND_W]),
          .wb_hit   (wb_hit[gk*ROB_ROWS +: ROB_ROWS]),
          .xc_hit   (xc_hit[gk*ROB_ROWS +: ROB_ROWS]),
          .xc_hit_p_in(xc_hit_pp[gk*XC_PORTS*ROB_ROWS +: XC_PORTS*ROB_ROWS]),
          .xc_acc   (xc_acc_l[gk*XC_PORTS +: XC_PORTS]),
          .kill_hit (kill_hit[gk*ROB_ROWS +: ROB_ROWS]),
          .kill_m   (kill_m[gk*ROB_ROWS +: ROB_ROWS]),
          .kill_live(kill_live[gk]),
          .h_row    (h_row),
          .h_clr    (cm_mask[gk]),
          .h_valid  (h_valid[gk]),
          .h_done   (h_done[gk]),
          .h_exc    (h_exc[gk]),
          .h_ldst   (h_ldst[gk*AREG_W +: AREG_W]),
          .h_has_dst(h_has_dst[gk]),
          .h_pdst   (h_pdst[gk*PREG_W +: PREG_W]),
          .h_stale  (h_stale[gk*PREG_W +: PREG_W]),
          .h_flags  (fl)
      );

      assign a_exc_v[gk]  = a_exc;
      assign h_serial[gk] = fl[`RETIRE_FL_SERIAL];
      assign h_mret[gk]   = fl[`RETIRE_FL_MRET];
      assign h_store[gk]  = fl[`RETIRE_FL_STORE];
      assign h_load[gk]   = fl[`RETIRE_FL_LOAD];
    end
  endgenerate

  generate
    for (gq = 0; gq < XC_PORTS; gq = gq + 1) begin : g_accp
      assign xc_acc_p[gq] = xc_acc_l[0*XC_PORTS + gq] | xc_acc_l[1*XC_PORTS + gq]
                          | xc_acc_l[2*XC_PORTS + gq];
    end
  endgenerate

  wire [CAUSE_W-1:0] xcause;
  wire [XLEN-1:0]    xtval;

  wire               xredir = (xcause == `RETIRE_XC_REDIR);

  retire_xcpt_track #(
      .TAG_W   (TAG_W),
      .CAUSE_W (CAUSE_W),
      .XLEN    (XLEN),
      .XC_PORTS(XC_PORTS),
      .LANES   (LANES)
  ) u_xt (
      .clk         (clk),
      .rst_n       (rst_n),
      .clr         (flush_dec),
      .cancel_valid(kill_acc),
      .cancel_tag  (br_kill_tag),
      .ab_fire     (fire),
      .ab_exc      (a_exc_v),
      .ab_base     (tail_q),
      .ab_cause    (alloc_exc_cause),
      .xc_acc      (xc_acc_p),
      .xc_tag      (xc_tag),
      .xc_cause    (xc_cause),
      .xc_tval     (xc_tval),
      .xcause      (xcause),
      .xtval       (xtval)
  );

  retire_commit_sel #(
      .LANES(LANES)
  ) u_sel (
      .h_valid    (h_valid),
      .h_done     (h_done),
      .h_exc      (h_exc),
      .h_serial   (h_serial),
      .h_store    (h_store),
      .lsu_q      (lsu_q),
      .fl_block   (hook_sel_block),
      .xredir     (xredir),
      .cm_mask    (cm_mask),
      .head_adv   (head_adv),
      .exc_lane   (exc_lane),
      .exc_at_head(exc_at_head)
  );

  wire            f_trap;
  wire            f_mret;
  wire [PC_W-1:0] f_pc;
  wire [CAUSE_W-1:0] f_cause;
  wire [PC_W-1:0] f_lane_pc;
  wire [PC_W-1:0] mtvec_pc;
  wire [PC_W-1:0] mepc_pc;

  wire [LANES-1:0]        act_commit_valid;
  wire [LANES-1:0]        act_free_valid;
  wire [LANES*PREG_W-1:0] act_free_preg;
  wire [LANES-1:0]        act_st_valid;
  wire [LANES-1:0]        act_ld_valid;
  wire [LANES-1:0]        act_is_store;
  wire [LANES-1:0]        act_rrat_we;
  wire [LANES*AREG_W-1:0] act_rrat_ldst;
  wire [LANES*PREG_W-1:0] act_rrat_pdst;
  wire [1:0]              act_instret;

  retire_commit_act #(
      .LANES (LANES),
      .AREG_W(AREG_W),
      .PREG_W(PREG_W)
  ) u_act (
      .cm_mask         (cm_mask),
      .h_has_dst       (h_has_dst),
      .h_store         (h_store),
      .h_load          (h_load),
      .h_ldst          (h_ldst),
      .h_pdst          (h_pdst),
      .h_stale         (h_stale),
      .act_commit_valid(act_commit_valid),
      .act_free_valid  (act_free_valid),
      .act_free_preg   (act_free_preg),
      .act_st_valid    (act_st_valid),
      .act_ld_valid    (act_ld_valid),
      .act_is_store    (act_is_store),
      .act_rrat_we     (act_rrat_we),
      .act_rrat_ldst   (act_rrat_ldst),
      .act_rrat_pdst   (act_rrat_pdst),
      .act_instret     (act_instret)
  );

  retire_flush_gen #(
      .LANES  (LANES),
      .PC_W   (PC_W),
      .CAUSE_W(CAUSE_W)
  ) u_fg (
      .exc_at_head(exc_at_head),
      .exc_lane   (exc_lane),
      .cm_mask    (cm_mask),
      .h_mret     (h_mret),
      .h_rowpc    (h_rowpc),
      .xcause     (xcause),
      .xredir     (xredir),
      .xtval_pc   (xtval[PC_W-1:0]),
      .mtvec_pc   (mtvec_pc),
      .mepc_pc    (mepc_pc),
      .flush_dec  (flush_dec),
      .f_trap     (f_trap),
      .f_mret     (f_mret),
      .f_pc       (f_pc),
      .f_cause    (f_cause),
      .f_lane_pc  (f_lane_pc)
  );

  retire_csr #(
      .XLEN       (XLEN),
      .PC_W       (PC_W),
      .MTVEC_RESET(MTVEC_RESET)
  ) u_csr (
      .clk           (clk),
      .rst_n         (rst_n),
      .trap_we       (f_trap),
      .trap_pc       (f_lane_pc),
      .trap_cause    (xcause[3:0]),
      .trap_tval     (xtval),
      .mret_we       (f_mret),
      .instret       (act_instret),
      .mtvec_wr_valid(mtvec_wr_valid),
      .mtvec_wr_data (mtvec_wr_data),
      .rd_addr       (csr_rd_addr),
      .mtvec_pc      (mtvec_pc),
      .mepc_pc       (mepc_pc),
      .rd_data       (csr_rd_data),
      .rd_hit        (csr_rd_hit)
  );

  retire_rrat #(
      .NUM_AREGS(NUM_AREGS),
      .AREG_W   (AREG_W),
      .PREG_W   (PREG_W),
      .LANES    (LANES)
  ) u_rrat (
      .clk      (clk),
      .rst_n    (rst_n),
      .we       (act_rrat_we),
      .w_ldst   (act_rrat_ldst),
      .w_pdst   (act_rrat_pdst),
      .rrat_flat(rrat_flat)
  );

  assign alloc_ready    = ready_q & ~flush_dec;
  assign alloc_tag_base = tail_q;
  assign rob_full       = full_q;
  assign rob_empty      = empty_q;
  assign head_tag       = {head_q, 2'b00};
  assign commit_valid   = act_commit_valid;
  assign commit_ldst    = act_rrat_ldst;
  assign commit_pdst    = act_rrat_pdst;
  assign free_valid     = act_free_valid;
  assign free_preg      = act_free_preg;
  assign stcommit_valid = act_st_valid;
  assign ldcommit_valid = act_ld_valid;

  assign squash_valid      = squash_q;
  assign squash_tag        = squash_tag_q;

  assign flush_valid       = flush_dec;
  assign flush_pc          = f_pc;
  assign flush_busy        = flush_dec;

  generate
    if (DBG_EN != 0) begin : g_dbg
      assign trace_row_pc   = h_rowpc;
      assign trace_row_tag  = head_q;
      assign trace_ldst     = h_ldst;
      assign trace_pdst     = h_pdst;
      assign trace_stale    = h_stale;
      assign trace_has_dst  = h_has_dst;
      assign trace_is_store = act_is_store;
      assign trace_flush_cause = f_cause;
      assign trace_trap_valid  = f_trap;
    end else begin : g_nodbg
      assign trace_row_pc   = {PC_W{1'b0}};
      assign trace_row_tag  = {(ROB_ROW_W + 1){1'b0}};
      assign trace_ldst     = {(LANES * AREG_W){1'b0}};
      assign trace_pdst     = {(LANES * PREG_W){1'b0}};
      assign trace_stale    = {(LANES * PREG_W){1'b0}};
      assign trace_has_dst  = {LANES{1'b0}};
      assign trace_is_store = {LANES{1'b0}};
      assign trace_flush_cause = {CAUSE_W{1'b0}};
      assign trace_trap_valid  = 1'b0;
    end
  endgenerate

  wire unused_ok = &{1'b0,
                     NUM_PREGS[0]};

endmodule
`default_nettype wire
