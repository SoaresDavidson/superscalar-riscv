// Dispatch: takes one bundle from Decode and, all or nothing, allocates a ROB
// entry, a rename tag (if it writes rd) and a reservation-station entry for
// every valid slot.
// Spec: docs/dispatch/Dispatch.md.
//
// STATUS: skeleton. Ports are final for this version; every output is tied to
// zero, so dispatch_tb fails until the logic is written.
/* verilator lint_off UNUSEDSIGNAL */
module dispatch
  import execute_pkg::*;
  import dispatch_pkg::*;
#(
    parameter  int W              = 3,   // bundle width (decision 2)
    parameter  int ROB_ENTRIES    = 32,  // proposal; at most 2**(AGE_W-1) = 128
    parameter  int RS_INT_ENTRIES = 8,
    parameter  int RS_MEM_ENTRIES = 4,
    localparam int ROB_IDX_W = $clog2(ROB_ENTRIES),       // index: 0..ROB_ENTRIES-1
    localparam int ROB_CNT_W = $clog2(ROB_ENTRIES + 1),   // count: 0..ROB_ENTRIES
    localparam int INT_CNT_W = $clog2(RS_INT_ENTRIES + 1),
    localparam int MEM_CNT_W = $clog2(RS_MEM_ENTRIES + 1)
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
    output logic                     ren_rob_ready,    // space_ok: ROB and both RS
    // Rename: answers (same cycle)
    input  logic                     ren_dispatch_ready,
    input  logic [W-1:0][1:0]        ren_src_ready,
    input  logic [W-1:0][XLEN-1:0]   ren_src1_data,
    input  logic [W-1:0][XLEN-1:0]   ren_src2_data,
    input  logic [W-1:0][TAG_W-1:0]  ren_src1_tag,
    input  logic [W-1:0][TAG_W-1:0]  ren_src2_tag,
    input  logic [W-1:0][TAG_W-1:0]  ren_dst_tag,
    input  logic [W-1:0][TAG_W-1:0]  ren_old_tag,

    // ROB
    input  logic [ROB_CNT_W-1:0]     rob_free,
    input  logic [ROB_IDX_W-1:0]     rob_tail,         // index of the next free entry
    output logic [W-1:0]             rob_alloc,
    output rob_entry_t [W-1:0]       rob_entry,

    // RS INT
    input  logic [INT_CNT_W-1:0]     int_free,
    output logic [W-1:0]             int_wr,
    output rs_int_entry_t [W-1:0]    int_entry,

    // RS MEM
    input  logic [MEM_CNT_W-1:0]     mem_free,
    output logic [W-1:0]             mem_wr,
    output rs_mem_entry_t [W-1:0]    mem_entry
);

  // ---------------------------------------------------------------------------
  // Per-slot classification (Dispatch.md, "Regras")
  // ---------------------------------------------------------------------------
  logic [W-1:0] slot_v;     // slot has an instruction
  logic [W-1:0] to_int;     // slot goes to RS INT
  logic [W-1:0] to_mem;     // slot goes to RS MEM
  logic [W-1:0] port0;      // slot is port0_only

  for (genvar k = 0; k < W; k++) begin : g_slot
    uop_t     u;
    fu_kind_t fu;
    assign u  = dec_uop[k];
    assign fu = fu_of(u.op);

    assign slot_v[k] = dec_valid && u.valid;
    assign to_int[k] = slot_v[k] && (fu == FU_ALU || fu == FU_BRANCH);
    assign to_mem[k] = slot_v[k] && (fu == FU_AGU);
    assign port0[k]  = slot_v[k] && (fu == FU_BRANCH);
  end

  // ---------------------------------------------------------------------------
  // Counts (Dispatch.md, "Condição de aceite")
  // ---------------------------------------------------------------------------
  localparam int CNT_W = $clog2(W + 1);
  logic [CNT_W-1:0] n_rob, n_int, n_mem;

  always_comb begin
    n_rob = '0;
    n_int = '0;
    n_mem = '0;
    for (int k = 0; k < W; k++) begin
      n_rob += slot_v[k];
      n_int += to_int[k];
      n_mem += to_mem[k];
    end
  end

  // ---------------------------------------------------------------------------
  // Acceptance
  // ---------------------------------------------------------------------------
  logic space_ok, accept;

  assign space_ok  = (rob_free >= ROB_CNT_W'(n_rob)) &&
                     (int_free >= INT_CNT_W'(n_int)) &&
                     (mem_free >= MEM_CNT_W'(n_mem));
  assign dec_ready = space_ok && ren_dispatch_ready;
  assign accept    = dec_valid && dec_ready && !flush;

  assign ren_rob_ready = space_ok;
  assign rob_alloc     = {W{accept}} & slot_v;
  assign int_wr        = {W{accept}} & to_int;
  assign mem_wr        = {W{accept}} & to_mem;

  // TODO (next steps): Rename requests, RS and ROB entries.
  assign ren_dispatch_valid = 1'b0;
  assign ren_slot_valid     = '0;
  assign ren_rs1            = '0;
  assign ren_rs2            = '0;
  assign ren_rd             = '0;
  assign ren_writes_rd      = '0;
  assign rob_entry          = '0;
  assign int_entry          = '0;
  assign mem_entry          = '0;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
