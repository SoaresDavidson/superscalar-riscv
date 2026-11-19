`include "retire/retire_defs.vh"

module retire_team
  import execute_pkg::*;
  import dispatch_pkg::*;
#(
    parameter  int W        = 3,
    parameter  int WB_N     = 4,
    parameter  int ROB_ROWS = 16,
    parameter  bit DEEP2    = 1'b0,
    parameter  bit DBG_EN   = 1'b1,
    localparam int RTAG_W      = $clog2(ROB_ROWS) + 3,
    localparam int SHIFT       = AGE_W - RTAG_W,
    localparam int ROB_ENTRIES = 3 * ROB_ROWS,
    localparam int ROB_CNT_W   = $clog2(ROB_ENTRIES + 1)
) (
    input  logic clk,
    input  logic reset,

    input  logic [W-1:0]            rob_alloc,
    input  rob_entry_t [W-1:0]      rob_entry,
    input  uop_t [W-1:0]            rob_uop,
    input  logic [W-1:0][2:0]       rob_sys_kind,
    output logic [ROB_CNT_W-1:0]    rob_free,
    output age_t [W-1:0]            rob_age,

    input  logic [WB_N-1:0]         resp_valid,
    input  fu_resp_t [WB_N-1:0]     resp,
    input  redirect_t               redirect,

    output logic [W-1:0]            commit_valid,
    output reg_t [W-1:0]            commit_rd,
    output tag_t [W-1:0]            commit_tag,
    output tag_t [W-1:0]            commit_old_tag,

    output logic                    flush,
    output logic                    be_redirect_valid,
    output xlen_t                   be_redirect_pc,

    output logic [W-1:0]            st_commit,
    output logic [W-1:0]            ld_commit,
    input  logic                    lsu_ready,

    input  logic                    mtvec_wr_valid,
    input  xlen_t                   mtvec_wr_data,
    input  logic [11:0]             csr_rd_addr,
    output xlen_t                   csr_rd_data,
    output logic                    csr_rd_hit,

    output logic                    rob_empty,
    output logic                    rob_full,
    output logic                    flush_busy
);

  localparam logic [2:0] SYS_NONE   = 3'd0;
  localparam logic [2:0] SYS_ECALL  = 3'd1;
  localparam logic [2:0] SYS_EBREAK = 3'd2;
  localparam logic [2:0] SYS_MRET   = 3'd3;
  localparam logic [2:0] SYS_FENCE  = 3'd4;
  localparam logic [2:0] SYS_FENCEI = 3'd5;
  localparam logic [2:0] SYS_CSR    = 3'd6;

  generate
    if (W != 3) begin : g_assert_w
      ERROR_W_MUST_BE_3 u_assert ();
    end
    if (WB_N != 4) begin : g_assert_wb_n
      ERROR_WB_N_MUST_BE_4 u_assert ();
    end
    if (SHIFT < 0) begin : g_assert_shift
      ERROR_AGE_NARROWER_THAN_ROB_TAG u_assert ();
    end
    if (TAG_W != 6) begin : g_assert_tag_w
      ERROR_PHYSICAL_TAG_MUST_BE_6_BITS u_assert ();
    end
  endgenerate

  logic [W-1:0]                 a_lane_valid;
  logic [XLEN-1:0]              a_pc;
  logic [W*REG_W-1:0]           a_ldst;
  logic [W-1:0]                 a_has_dst;
  logic [W*TAG_W-1:0]           a_pdst;
  logic [W*TAG_W-1:0]           a_stale;
  logic [W*4-1:0]               a_kind;
  logic [W-1:0]                 a_done;
  logic [W-1:0]                 a_exc_valid;
  logic [W*5-1:0]               a_exc_cause;

  logic [WB_N-1:0]              r_wb_valid;
  logic [WB_N*RTAG_W-1:0]       r_wb_tag;
  logic [2:0]                   r_xc_valid;
  logic [3*RTAG_W-1:0]          r_xc_tag;
  logic [3*5-1:0]               r_xc_cause;
  logic [3*XLEN-1:0]            r_xc_tval;

  logic                         r_alloc_ready;
  logic [$clog2(ROB_ROWS):0]    r_tag_base;

  logic [W-1:0]                 retire_commit_valid;
  logic [W*REG_W-1:0]           r_commit_ldst;
  logic [W*TAG_W-1:0]           r_commit_pdst;
  logic [W-1:0]                 r_free_valid;
  logic [W*TAG_W-1:0]           r_free_preg;
  logic [W-1:0]                 r_stcommit;
  logic [W-1:0]                 r_ldcommit;
  logic                         r_flush_valid;
  logic [XLEN-1:0]              r_flush_pc;
  logic [XLEN-1:0]              r_csr_rd_data;
  logic                         r_csr_rd_hit;
  logic                         r_rob_empty;
  logic                         r_rob_full;
  logic                         r_flush_busy;

  logic                         r_squash_valid;
  logic [RTAG_W-1:0]            r_squash_tag;
  logic [(32-1)*TAG_W-1:0]      r_rrat_flat;
  logic [RTAG_W-1:0]            r_head_tag;
  logic [XLEN-1:0]              r_trace_row_pc;
  logic [$clog2(ROB_ROWS):0]    r_trace_row_tag;
  logic [W*REG_W-1:0]           r_trace_ldst;
  logic [W*TAG_W-1:0]           r_trace_pdst;
  logic [W*TAG_W-1:0]           r_trace_stale;
  logic [W-1:0]                 r_trace_has_dst;
  logic [W-1:0]                 r_trace_is_store;
  logic [4:0]                   r_trace_flush_cause;
  logic                         r_trace_trap_valid;

  assign a_lane_valid = rob_alloc;

  for (genvar k = 0; k < W; k++) begin : g_slot
    rob_entry_t     e;
    uop_t           u;
    logic [2:0]     sys;
    fu_kind_t       fu;
    logic           ld;
    logic           ill;
    logic           ser;
    logic [3:0]     kind;
    logic           xv;
    logic [4:0]     xcause;
    logic [RTAG_W-1:0] tag;
    logic [AGE_W-1:0]  age_k;
    localparam logic [1:0] LANE = k;
    logic unused_s;

    assign e   = rob_entry[k];
    assign u   = rob_uop[k];
    assign sys = rob_sys_kind[k];
    assign fu  = fu_of(u.op);
    assign ld  = is_load(u.op);
    assign ill = e.illegal;
    assign ser = e.serializing;

    always_comb begin
      kind   = `RETIRE_K_ALU;
      xv     = 1'b0;
      xcause = 5'd0;
      if (ill) begin
        kind   = `RETIRE_K_ALU;
        xv     = 1'b1;
        xcause = 5'd2;
      end else if (fu == FU_ALU) begin
        kind = `RETIRE_K_ALU;
      end else if (fu == FU_BRANCH) begin
        kind = `RETIRE_K_BRANCH;
      end else if (fu == FU_AGU) begin
        kind = ld ? `RETIRE_K_LOAD : `RETIRE_K_STORE;
      end else if (sys == SYS_ECALL) begin
        kind   = `RETIRE_K_ECALL;
        xv     = 1'b1;
        xcause = 5'd11;
      end else if (sys == SYS_EBREAK) begin
        kind   = `RETIRE_K_EBREAK;
        xv     = 1'b1;
        xcause = 5'd3;
      end else if (sys == SYS_MRET) begin
        kind = `RETIRE_K_MRET;
      end else if (sys == SYS_FENCE || sys == SYS_FENCEI) begin
        kind = `RETIRE_K_FENCE;
      end else if (sys == SYS_CSR) begin
        kind   = `RETIRE_K_CSR;
        xv     = 1'b1;
        xcause = 5'd2;
      end else if (sys == SYS_NONE && ser) begin
        kind = `RETIRE_K_FENCE;
      end
    end

    assign a_ldst[k*REG_W +: REG_W]   = e.rd;
    assign a_has_dst[k]               = e.has_dest;
    assign a_pdst[k*TAG_W +: TAG_W]   = e.dst_tag;
    assign a_stale[k*TAG_W +: TAG_W]  = e.old_tag;
    assign a_kind[k*4 +: 4]           = kind;
    assign a_done[k]                  = e.done;
    assign a_exc_valid[k]             = xv;
    assign a_exc_cause[k*5 +: 5]      = xcause;

    assign tag   = {r_tag_base, LANE};
    assign age_k = AGE_W'(tag);
    assign rob_age[k] = age_k << SHIFT;

    if (k == 0) begin : g_pc0
      assign a_pc = e.pc;
    end

    assign unused_s = &{1'b0, |u, |e};

    assign commit_rd[k]      = r_commit_ldst[k*REG_W +: REG_W];
    assign commit_tag[k]     = r_commit_pdst[k*TAG_W +: TAG_W];
    assign commit_old_tag[k] = r_free_preg[k*TAG_W +: TAG_W];
  end

  assign rob_free = r_alloc_ready ? ROB_CNT_W'(W) : '0;

  age_t rd_age;
  assign rd_age = redirect.age;
  for (genvar p = 0; p < WB_N; p++) begin : g_wb
    fu_resp_t r;
    age_t     a;
    logic     redirected;
    logic     unused_r;
    assign r = resp[p];
    assign a = r.age;
    assign unused_r = &{1'b0, |r, |a};
    if (p == 1) begin : g_bru

      assign redirected = redirect.valid & (a == rd_age);
    end else begin : g_other
      assign redirected = 1'b0;
    end
    assign r_wb_valid[p] = resp_valid[p] & ~r.exception & ~redirected;
    assign r_wb_tag[p*RTAG_W +: RTAG_W] = a[AGE_W-1:SHIFT];
  end

  fu_resp_t r_bru;
  fu_resp_t r_agu;
  fu_resp_t r_lsu;
  age_t     bru_age;
  age_t     agu_age;
  age_t     lsu_age;
  logic [3:0] bru_cause;
  logic [3:0] agu_cause;
  logic [3:0] lsu_cause;
  logic     bru_exc;
  assign r_bru     = resp[1];
  assign r_agu     = resp[2];
  assign r_lsu     = resp[3];
  assign bru_age   = r_bru.age;
  assign agu_age   = r_agu.age;
  assign lsu_age   = r_lsu.age;
  assign bru_cause = r_bru.cause;
  assign agu_cause = r_agu.cause;
  assign lsu_cause = r_lsu.cause;
  assign bru_exc   = resp_valid[1] & r_bru.exception;

  assign r_xc_valid[0] = bru_exc | redirect.valid;
  assign r_xc_tag[0*RTAG_W +: RTAG_W]  = bru_exc ? bru_age[AGE_W-1:SHIFT] : rd_age[AGE_W-1:SHIFT];
  assign r_xc_cause[0*5 +: 5]          = bru_exc ? {1'b0, bru_cause} : `RETIRE_XC_REDIR;
  assign r_xc_tval[0*XLEN +: XLEN]     = bru_exc ? r_bru.result : redirect.pc;

  assign r_xc_valid[1] = resp_valid[2] & r_agu.exception;
  assign r_xc_tag[1*RTAG_W +: RTAG_W]  = agu_age[AGE_W-1:SHIFT];
  assign r_xc_cause[1*5 +: 5]          = {1'b0, agu_cause};
  assign r_xc_tval[1*XLEN +: XLEN]     = r_agu.result;

  assign r_xc_valid[2] = resp_valid[3] & r_lsu.exception;
  assign r_xc_tag[2*RTAG_W +: RTAG_W]  = lsu_age[AGE_W-1:SHIFT];
  assign r_xc_cause[2*5 +: 5]          = {1'b0, lsu_cause};
  assign r_xc_tval[2*XLEN +: XLEN]     = r_lsu.result;

  assign commit_valid      = r_free_valid;
  assign flush             = r_flush_valid;
  assign be_redirect_valid = r_flush_valid;
  assign be_redirect_pc    = r_flush_pc;
  assign st_commit         = r_stcommit;
  assign ld_commit         = r_ldcommit;
  assign csr_rd_data       = r_csr_rd_data;
  assign csr_rd_hit        = r_csr_rd_hit;
  assign rob_empty         = r_rob_empty;
  assign rob_full          = r_rob_full;
  assign flush_busy        = r_flush_busy;

  if (DEEP2) begin : g_deep2
    retire_deep2 #(
        .XLEN     (XLEN),
        .PC_W     (XLEN),
        .LANES    (W),
        .ROB_ROWS (ROB_ROWS),
        .AREG_W   (REG_W),
        .NUM_PREGS(PRF_ENTRIES),
        .PREG_W   (TAG_W),
        .WB_PORTS (WB_N),
        .XC_PORTS (3),
        .DBG_EN   (DBG_EN)
    ) u_retire (
        .clk              (clk),
        .rst_n            (~reset),
        .alloc_valid      (|rob_alloc),
        .alloc_lane_valid (a_lane_valid),
        .alloc_pc         (a_pc),
        .alloc_ldst       (a_ldst),
        .alloc_has_dst    (a_has_dst),
        .alloc_pdst       (a_pdst),
        .alloc_stale      (a_stale),
        .alloc_kind       (a_kind),
        .alloc_done       (a_done),
        .alloc_exc_valid  (a_exc_valid),
        .alloc_exc_cause  (a_exc_cause),
        .alloc_ready      (r_alloc_ready),
        .alloc_tag_base   (r_tag_base),
        .wb_valid         (r_wb_valid),
        .wb_tag           (r_wb_tag),
        .xc_valid         (r_xc_valid),
        .xc_tag           (r_xc_tag),
        .xc_cause         (r_xc_cause),
        .xc_tval          (r_xc_tval),
        .br_kill_valid    (1'b0),
        .br_kill_tag      ({RTAG_W{1'b0}}),
        .squash_valid     (r_squash_valid),
        .squash_tag       (r_squash_tag),
        .commit_valid     (retire_commit_valid),
        .commit_ldst      (r_commit_ldst),
        .commit_pdst      (r_commit_pdst),
        .free_valid       (r_free_valid),
        .free_preg        (r_free_preg),
        .rrat_flat        (r_rrat_flat),
        .stcommit_valid   (r_stcommit),
        .ldcommit_valid   (r_ldcommit),
        .commit_lsu_ready (lsu_ready),
        .flush_valid      (r_flush_valid),
        .flush_pc         (r_flush_pc),
        .csr_rd_addr      (csr_rd_addr),
        .csr_rd_data      (r_csr_rd_data),
        .csr_rd_hit       (r_csr_rd_hit),
        .mtvec_wr_valid   (mtvec_wr_valid),
        .mtvec_wr_data    (mtvec_wr_data),
        .rob_empty        (r_rob_empty),
        .rob_full         (r_rob_full),
        .head_tag         (r_head_tag),
        .flush_busy       (r_flush_busy),
        .trace_row_pc     (r_trace_row_pc),
        .trace_row_tag    (r_trace_row_tag),
        .trace_ldst       (r_trace_ldst),
        .trace_pdst       (r_trace_pdst),
        .trace_stale      (r_trace_stale),
        .trace_has_dst    (r_trace_has_dst),
        .trace_is_store   (r_trace_is_store),
        .trace_flush_cause(r_trace_flush_cause),
        .trace_trap_valid (r_trace_trap_valid)
    );
  end else begin : g_base
    retire_base #(
        .XLEN     (XLEN),
        .PC_W     (XLEN),
        .LANES    (W),
        .ROB_ROWS (ROB_ROWS),
        .AREG_W   (REG_W),
        .NUM_PREGS(PRF_ENTRIES),
        .PREG_W   (TAG_W),
        .WB_PORTS (WB_N),
        .XC_PORTS (3),
        .DBG_EN   (DBG_EN)
    ) u_retire (
        .clk              (clk),
        .rst_n            (~reset),
        .alloc_valid      (|rob_alloc),
        .alloc_lane_valid (a_lane_valid),
        .alloc_pc         (a_pc),
        .alloc_ldst       (a_ldst),
        .alloc_has_dst    (a_has_dst),
        .alloc_pdst       (a_pdst),
        .alloc_stale      (a_stale),
        .alloc_kind       (a_kind),
        .alloc_done       (a_done),
        .alloc_exc_valid  (a_exc_valid),
        .alloc_exc_cause  (a_exc_cause),
        .alloc_ready      (r_alloc_ready),
        .alloc_tag_base   (r_tag_base),
        .wb_valid         (r_wb_valid),
        .wb_tag           (r_wb_tag),
        .xc_valid         (r_xc_valid),
        .xc_tag           (r_xc_tag),
        .xc_cause         (r_xc_cause),
        .xc_tval          (r_xc_tval),
        .br_kill_valid    (1'b0),
        .br_kill_tag      ({RTAG_W{1'b0}}),
        .squash_valid     (r_squash_valid),
        .squash_tag       (r_squash_tag),
        .commit_valid     (retire_commit_valid),
        .commit_ldst      (r_commit_ldst),
        .commit_pdst      (r_commit_pdst),
        .free_valid       (r_free_valid),
        .free_preg        (r_free_preg),
        .rrat_flat        (r_rrat_flat),
        .stcommit_valid   (r_stcommit),
        .ldcommit_valid   (r_ldcommit),
        .commit_lsu_ready (lsu_ready),
        .flush_valid      (r_flush_valid),
        .flush_pc         (r_flush_pc),
        .csr_rd_addr      (csr_rd_addr),
        .csr_rd_data      (r_csr_rd_data),
        .csr_rd_hit       (r_csr_rd_hit),
        .mtvec_wr_valid   (mtvec_wr_valid),
        .mtvec_wr_data    (mtvec_wr_data),
        .rob_empty        (r_rob_empty),
        .rob_full         (r_rob_full),
        .head_tag         (r_head_tag),
        .flush_busy       (r_flush_busy),
        .trace_row_pc     (r_trace_row_pc),
        .trace_row_tag    (r_trace_row_tag),
        .trace_ldst       (r_trace_ldst),
        .trace_pdst       (r_trace_pdst),
        .trace_stale      (r_trace_stale),
        .trace_has_dst    (r_trace_has_dst),
        .trace_is_store   (r_trace_is_store),
        .trace_flush_cause(r_trace_flush_cause),
        .trace_trap_valid (r_trace_trap_valid)
    );
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, |rob_uop, |rob_entry, |resp, r_squash_valid, |r_squash_tag, |r_rrat_flat, |r_head_tag,
                       |r_trace_row_pc, |r_trace_row_tag, |r_trace_ldst, |r_trace_pdst, |r_trace_stale,
                       |r_trace_has_dst, |r_trace_is_store, |r_trace_flush_cause, r_trace_trap_valid,
                       |retire_commit_valid, |r_bru, |r_agu, |r_lsu, |redirect, |bru_age, |agu_age, |lsu_age};

endmodule
