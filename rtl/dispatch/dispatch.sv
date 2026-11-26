// Dispatch: takes one bundle from Decode and, all or nothing, allocates a ROB
// entry, a rename tag (if it writes rd) and a reservation-station entry for
// every valid slot.
// Spec: docs/dispatch/Dispatch.md.
//
// STATUS: complete for this version. Pending (Dispatch.md, open items):
// prediction fields (item 5) and rob_sys_kind (item 8). The RS hold tags only
// (decision 16). The age of each slot comes from the ROB (rob_age).
// Unused on purpose: clk and reset (Dispatch is combinational; every block
// takes them), and the uop fields each entry builder does not need.
/* verilator lint_off UNUSEDSIGNAL */
module dispatch
  import execute_pkg::*;
  import dispatch_pkg::*;
#(
    parameter  int W              = 3,   // bundle width (decision 2)
    parameter  int ROB_ENTRIES    = 48,  // retire_team: 16 rows x 3 lanes
    parameter  int RS_INT_ENTRIES = 8,
    parameter  int RS_MEM_ENTRIES = 4,
    localparam int ROB_CNT_W = $clog2(ROB_ENTRIES + 1),   // count: 0..ROB_ENTRIES
    localparam int INT_CNT_W = $clog2(RS_INT_ENTRIES + 1),
    localparam int MEM_CNT_W = $clog2(RS_MEM_ENTRIES + 1),
    localparam int SB_CNT_W  = $clog2(SB_ENTRIES + 1),
    localparam int LB_CNT_W  = $clog2(LB_ENTRIES + 1)
) (
    input  logic clk,
    input  logic reset,
    input  logic flush,

    // Decode
    input  logic                     dec_valid,        // Decode out_valid
    input  uop_t [W-1:0]             dec_uop,
    output logic                     dec_ready,        // Decode out_ready

    // Rename: requests
    output logic                     ren_dispatch_valid,
    output logic [W-1:0]             ren_slot_valid,
    output logic [W-1:0][REG_W-1:0]  ren_rs1,          // 0 when rs1_valid = 0
    output logic [W-1:0][REG_W-1:0]  ren_rs2,          // 0 when rs2_valid = 0
    output logic [W-1:0][REG_W-1:0]  ren_rd,
    output logic [W-1:0]             ren_writes_rd,    // valid && has_dest
    output logic                     ren_rob_ready,    // the ROB has room for the bundle
    output logic                     ren_rs_ready,     // both RS have room for the bundle
    // Rename: answers (same cycle)
    input  logic                     ren_dispatch_ready,
    input  logic [W-1:0][1:0]        ren_src_ready,
    input  logic [W-1:0][TAG_W-1:0]  ren_src1_tag,
    input  logic [W-1:0][TAG_W-1:0]  ren_src2_tag,
    input  logic [W-1:0][TAG_W-1:0]  ren_dst_tag,
    input  logic [W-1:0][TAG_W-1:0]  ren_old_tag,

    // ROB
    input  logic [ROB_CNT_W-1:0]     rob_free,
    input  age_t [W-1:0]             rob_age,          // age of the entry slot k would take
    output logic [W-1:0]             rob_alloc,
    output rob_entry_t [W-1:0]       rob_entry,
    output uop_t [W-1:0]             rob_uop,          // retire_team reads the op (load/store)

    // RS INT
    input  logic [INT_CNT_W-1:0]     int_free,
    output logic [W-1:0]             int_wr,
    output rs_int_entry_t [W-1:0]    int_entry,

    // RS MEM
    input  logic [MEM_CNT_W-1:0]     mem_free,
    output logic [W-1:0]             mem_wr,
    output rs_mem_entry_t [W-1:0]    mem_entry,

    // Memory: store buffer and load buffer reservation (decision 17)
    input  logic [SB_CNT_W-1:0]      sb_free,
    input  sb_ptr_t                  sb_tail,          // next store buffer entry
    output logic [W-1:0]             sb_alloc,         // slot k reserves a store buffer entry
    input  logic [LB_CNT_W-1:0]      lb_free,
    input  lb_ptr_t                  lb_tail,          // next load buffer entry
    output logic [W-1:0]             lb_alloc          // slot k reserves a load buffer entry
);

  // ---------------------------------------------------------------------------
  // Entry builders 
  // ---------------------------------------------------------------------------
  function automatic rs_int_entry_t make_int_entry(
      uop_t u, logic [1:0] rdy,
      tag_t t1, tag_t t2, tag_t dst, age_t age);
    rs_int_entry_t e;
    e             = '0;          // pred_taken, pred_target: open item 5
    e.busy        = 1'b1;
    e.src1_ready  = rdy[0];      // rdy[0] = source 1, rdy[1] = source 2
    e.src1_tag    = t1;
    e.src2_ready  = rdy[1];
    e.src2_tag    = t2;
    e.op          = u.op;
    e.imm         = u.imm;
    e.use_imm     = u.use_imm;
    e.pc          = u.pc;
    e.dst_tag     = dst;
    e.wr_en       = u.has_dest;
    e.age         = age;
    return e;
  endfunction

  function automatic rs_mem_entry_t make_mem_entry(
      uop_t u, logic [1:0] rdy,
      tag_t t1, tag_t t2, tag_t dst, age_t age,
      lsq_idx_t lsq_idx, sb_ptr_t color);
    rs_mem_entry_t e;
    e             = '0;
    e.busy        = 1'b1;
    e.src1_ready  = rdy[0];
    e.src1_tag    = t1;
    e.src2_ready  = rdy[1];
    e.src2_tag    = t2;
    e.op          = u.op;
    e.imm         = u.imm;
    e.dst_tag     = dst;
    e.wr_en       = u.has_dest;
    e.age         = age;
    e.lsq_idx     = lsq_idx;
    e.color       = color;
    return e;
  endfunction

function automatic rob_entry_t make_rob_entry(
      uop_t u, tag_t dst, tag_t old, fu_kind_t fu);
    rob_entry_t e;
    e             = '0;
    e.pc          = u.pc;
    e.rd          = u.rd;
    e.has_dest    = u.has_dest;
    e.dst_tag     = dst;
    e.old_tag     = old;
    e.done        = fu == FU_NONE;
    e.illegal     = u.illegal;
    e.serializing  = u.serializing;
    return e;
  endfunction

  // ---------------------------------------------------------------------------
  // Per-slot classification (Dispatch.md, "Regras")
  // ---------------------------------------------------------------------------
  logic [W-1:0] slot_v;     // slot has an instruction
  logic [W-1:0] to_int;     // slot goes to RS INT
  logic [W-1:0] to_mem;     // slot goes to RS MEM
  logic [W-1:0] is_st;      // slot reserves a store buffer entry
  logic [W-1:0] is_ld;      // slot reserves a load buffer entry

  // Stores and loads in the slots before k: the slots reserve in program
  // order, so slot k's entry is the tail plus these counts (Dispatch.md,
  // "Índice no store buffer e no load buffer").
  int unsigned st_before [W];
  int unsigned ld_before [W];

  always_comb begin
    int unsigned ns, nl;
    ns = 0;
    nl = 0;
    for (int k = 0; k < W; k++) begin
      st_before[k] = ns;
      ld_before[k] = nl;
      ns = ns + is_st[k];
      nl = nl + is_ld[k];
    end
  end

  for (genvar k = 0; k < W; k++) begin : g_slot
    uop_t     u;
    fu_kind_t fu;
    assign u  = dec_uop[k];
    assign fu = fu_of(u.op);

    assign slot_v[k] = dec_valid && u.valid;
    assign to_int[k] = slot_v[k] && (fu == FU_ALU || fu == FU_BRANCH);
    assign to_mem[k] = slot_v[k] && (fu == FU_AGU);
    assign is_st[k]  = to_mem[k] && !is_load(u.op);
    assign is_ld[k]  = to_mem[k] &&  is_load(u.op);

    // Store: its store buffer entry. Load: its load buffer entry, and as color
    // the last store allocated before it (the entry before this slot's
    // store buffer position).
    sb_ptr_t  sb_pos;
    lsq_idx_t lsq;
    assign sb_pos = sb_ptr_add(sb_tail, st_before[k]);
    assign lsq    = is_st[k] ? lsq_idx_t'(sb_pos)
                             : lsq_idx_t'(lb_ptr_add(lb_tail, ld_before[k]));

    assign ren_rs1[k]       = u.rs1_valid? u.rs1 : '0;  
    assign ren_rs2[k]       = u.rs2_valid? u.rs2 : '0;   
    assign ren_rd[k]        = u.rd;                      
    assign ren_writes_rd[k] = slot_v[k] && u.has_dest;   

    assign int_entry[k] = make_int_entry(u, ren_src_ready[k],
                                         ren_src1_tag[k], ren_src2_tag[k],
                                         ren_dst_tag[k], rob_age[k]);

    assign mem_entry[k] = make_mem_entry(u, ren_src_ready[k],
                                         ren_src1_tag[k], ren_src2_tag[k],
                                         ren_dst_tag[k], rob_age[k],
                                         lsq, sb_ptr_prev(sb_pos));

    assign rob_entry[k] = make_rob_entry(u, ren_dst_tag[k], ren_old_tag[k], fu);

  end

  assign rob_uop            = dec_uop;
  assign ren_slot_valid     = slot_v;
  assign ren_dispatch_valid = dec_valid && !flush;   

  // ---------------------------------------------------------------------------
  // Counts (Dispatch.md, "Condição de aceite")
  // ---------------------------------------------------------------------------
  localparam int CNT_W = $clog2(W + 1);
  logic [CNT_W-1:0] n_rob, n_int, n_mem, n_st, n_ld;

  always_comb begin
    n_rob = '0;
    n_int = '0;
    n_mem = '0;
    n_st  = '0;
    n_ld  = '0;
    for (int k = 0; k < W; k++) begin
      n_rob += slot_v[k];
      n_int += to_int[k];
      n_mem += to_mem[k];
      n_st  += is_st[k];
      n_ld  += is_ld[k];
    end
  end

  // ---------------------------------------------------------------------------
  // Acceptance
  // ---------------------------------------------------------------------------
  logic rob_ok, rs_ok, lsq_ok, space_ok, accept;

  assign rob_ok    = (rob_free >= ROB_CNT_W'(n_rob));
  assign rs_ok     = (int_free >= INT_CNT_W'(n_int)) &&
                     (mem_free >= MEM_CNT_W'(n_mem));
  assign lsq_ok    = (sb_free >= SB_CNT_W'(n_st)) &&
                     (lb_free >= LB_CNT_W'(n_ld));
  assign space_ok  = rob_ok && rs_ok && lsq_ok;
  assign dec_ready = space_ok && ren_dispatch_ready;
  assign accept    = dec_valid && dec_ready && !flush;

  // Rename allocates tags only with rob_ready && rs_ready, so no tag leaks
  // when the ROB, an RS, the store buffer or the load buffer refuses the
  // bundle. The two buffers ride on rs_ready.
  assign ren_rob_ready = rob_ok;
  assign ren_rs_ready  = rs_ok && lsq_ok;
  assign rob_alloc     = {W{accept}} & slot_v;
  assign int_wr        = {W{accept}} & to_int;
  assign mem_wr        = {W{accept}} & to_mem;
  assign sb_alloc      = {W{accept}} & is_st;
  assign lb_alloc      = {W{accept}} & is_ld;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
