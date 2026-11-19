  input  wire                       clk,
  input  wire                       rst_n,

  input  wire                       alloc_valid,
  input  wire [LANES-1:0]           alloc_lane_valid,
  input  wire [PC_W-1:0]            alloc_pc,
  input  wire [LANES*AREG_W-1:0]    alloc_ldst,
  input  wire [LANES-1:0]           alloc_has_dst,
  input  wire [LANES*PREG_W-1:0]    alloc_pdst,
  input  wire [LANES*PREG_W-1:0]    alloc_stale,
  input  wire [LANES*KIND_W-1:0]    alloc_kind,
  input  wire [LANES-1:0]           alloc_done,
  input  wire [LANES-1:0]           alloc_exc_valid,
  input  wire [LANES*CAUSE_W-1:0]   alloc_exc_cause,
  output wire                       alloc_ready,
  output wire [ROB_ROW_W:0]         alloc_tag_base,

  input  wire [WB_PORTS-1:0]        wb_valid,
  input  wire [WB_PORTS*TAG_W-1:0]  wb_tag,

  input  wire [XC_PORTS-1:0]        xc_valid,
  input  wire [XC_PORTS*TAG_W-1:0]  xc_tag,
  input  wire [XC_PORTS*CAUSE_W-1:0] xc_cause,
  input  wire [XC_PORTS*XLEN-1:0]   xc_tval,

  input  wire                       br_kill_valid,
  input  wire [TAG_W-1:0]           br_kill_tag,
  output wire                       squash_valid,
  output wire [TAG_W-1:0]           squash_tag,

  output wire [LANES-1:0]           commit_valid,

  output wire [LANES*AREG_W-1:0]    commit_ldst,
  output wire [LANES*PREG_W-1:0]    commit_pdst,

  output wire [LANES-1:0]           free_valid,
  output wire [LANES*PREG_W-1:0]    free_preg,

  output wire [(NUM_AREGS-1)*PREG_W-1:0]rrat_flat,

  output wire [LANES-1:0]           stcommit_valid,
  output wire [LANES-1:0]           ldcommit_valid,
  input  wire                       commit_lsu_ready,

  output wire                       flush_valid,
  output wire [PC_W-1:0]            flush_pc,

  input  wire [11:0]                csr_rd_addr,
  output wire [XLEN-1:0]            csr_rd_data,
  output wire                       csr_rd_hit,
  input  wire                       mtvec_wr_valid,
  input  wire [XLEN-1:0]            mtvec_wr_data,

  output wire                       rob_empty,
  output wire                       rob_full,
  output wire [TAG_W-1:0]           head_tag,
  output wire                       flush_busy,

  output wire [PC_W-1:0]            trace_row_pc,
  output wire [ROB_ROW_W:0]         trace_row_tag,
  output wire [LANES*AREG_W-1:0]    trace_ldst,
  output wire [LANES*PREG_W-1:0]    trace_pdst,
  output wire [LANES*PREG_W-1:0]    trace_stale,
  output wire [LANES-1:0]           trace_has_dst,
  output wire [LANES-1:0]           trace_is_store,
  output wire [CAUSE_W-1:0]         trace_flush_cause,
  output wire                       trace_trap_valid
