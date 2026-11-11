// Unit testbench for dispatch. Spec: docs/dispatch/Dispatch.md.
//
// Dispatch is combinational between its inputs and outputs: every case sets
// the inputs, waits #1 for the logic to settle and checks the outputs. The
// neighbours (Decode, Rename, ROB, RS) are not instantiated; the testbench
// plays their part by driving the inputs directly.
//
// W is fixed at 3 here: the expected masks are written as 3-bit literals
// (slot 2, slot 1, slot 0, left to right).
//
// Groups:
//   T1..T5  routing: which slot goes to which RS, port0_only, ROB allocation
//   A1..A8  acceptance: when the bundle enters and which ready signals rise

module dispatch_tb;
  import execute_pkg::*;
  import dispatch_pkg::*;

  localparam int W              = 3;
  localparam int ROB_ENTRIES    = 32;
  localparam int RS_INT_ENTRIES = 8;
  localparam int RS_MEM_ENTRIES = 4;
  localparam int ROB_IDX_W = $clog2(ROB_ENTRIES);
  localparam int ROB_CNT_W = $clog2(ROB_ENTRIES + 1);
  localparam int INT_CNT_W = $clog2(RS_INT_ENTRIES + 1);
  localparam int MEM_CNT_W = $clog2(RS_MEM_ENTRIES + 1);

  // ---------------------------------------------------------------------------
  // DUT ports
  // ---------------------------------------------------------------------------
  logic clk = 1'b0, reset, flush;

  logic                     dec_valid;
  uop_t [W-1:0]             dec_uop;
  logic                     dec_ready;

  logic                     ren_dispatch_valid;
  logic [W-1:0]             ren_slot_valid;
  logic [W-1:0][REG_W-1:0]  ren_rs1, ren_rs2, ren_rd;
  logic [W-1:0]             ren_writes_rd;
  logic                     ren_rob_ready;
  logic                     ren_dispatch_ready;
  logic [W-1:0][1:0]        ren_src_ready;
  logic [W-1:0][XLEN-1:0]   ren_src1_data, ren_src2_data;
  logic [W-1:0][TAG_W-1:0]  ren_src1_tag, ren_src2_tag, ren_dst_tag, ren_old_tag;

  logic [ROB_CNT_W-1:0]     rob_free;
  logic [ROB_IDX_W-1:0]     rob_tail;
  logic [W-1:0]             rob_alloc;
  rob_entry_t [W-1:0]       rob_entry;

  logic [INT_CNT_W-1:0]     int_free;
  logic [W-1:0]             int_wr;
  rs_int_entry_t [W-1:0]    int_entry;

  logic [MEM_CNT_W-1:0]     mem_free;
  logic [W-1:0]             mem_wr;
  rs_mem_entry_t [W-1:0]    mem_entry;

  always #5 clk = ~clk;

  dispatch #(
      .W(W),
      .ROB_ENTRIES(ROB_ENTRIES),
      .RS_INT_ENTRIES(RS_INT_ENTRIES),
      .RS_MEM_ENTRIES(RS_MEM_ENTRIES)
  ) dut (.*);

  // ---------------------------------------------------------------------------
  // Checking
  // ---------------------------------------------------------------------------
  string cur;     // name of the running case, printed on failure
  int    checks;

  task automatic chk(logic cond, string msg);
    checks++;
    if (cond !== 1'b1) $fatal(1, "[%s] %s", cur, msg);
  endtask

  // Icarus: never read arr[k].field directly; copy the element first.
  function automatic logic int_port0_only(int k);
    rs_int_entry_t e;
    e = int_entry[k];
    return e.port0_only;
  endfunction

  // ---------------------------------------------------------------------------
  // Building uops. Fields are assigned one by one (Icarus has no '{...}).
  // ---------------------------------------------------------------------------
  // Generic: a valid slot. rs*_valid follows the x0 convention of Decode:
  // a source that is x0, or that the instruction does not use, is invalid.
  function automatic uop_t mk(exec_op_t op, logic [4:0] rd, logic uses_rd,
                              logic [4:0] rs1, logic uses_rs1,
                              logic [4:0] rs2, logic uses_rs2);
    uop_t u;
    u             = '0;
    u.valid       = 1'b1;
    u.op          = op;
    u.rd          = rd;
    u.has_dest    = uses_rd && (rd != 5'd0);
    u.rs1         = rs1;
    u.rs1_valid   = uses_rs1 && (rs1 != 5'd0);
    u.rs2         = rs2;
    u.rs2_valid   = uses_rs2 && (rs2 != 5'd0);
    u.use_imm     = !uses_rs2;
    u.illegal     = 1'b0;
    u.serializing = 1'b0;
    return u;
  endfunction

  // Shortcuts for the instructions of T1. Add more in the same style.
  function automatic uop_t i_add(logic [4:0] rd, logic [4:0] rs1, logic [4:0] rs2);
    return mk(ALU_ADD, rd, 1'b1, rs1, 1'b1, rs2, 1'b1);
  endfunction

  function automatic uop_t i_beq(logic [4:0] rs1, logic [4:0] rs2);
    return mk(BR_BEQ, 5'd0, 1'b0, rs1, 1'b1, rs2, 1'b1);
  endfunction

  function automatic uop_t i_lw(logic [4:0] rd, logic [4:0] rs1);
    return mk(AGU_LW, rd, 1'b1, rs1, 1'b1, 5'd0, 1'b0);
  endfunction

  // An invalid slot that still carries garbage in op: nothing may be
  // allocated for it, whatever op says.
  function automatic uop_t i_invalid(exec_op_t garbage_op);
    uop_t u;
    u       = '0;
    u.valid = 1'b0;
    u.op    = garbage_op;
    return u;
  endfunction

  // ---------------------------------------------------------------------------
  // Environment: every neighbour has room, Rename has tags, no flush.
  // A case starts from here and changes only what it tests.
  // ---------------------------------------------------------------------------
  task automatic env_all_free();
    reset              = 1'b0;
    flush              = 1'b0;
    dec_valid          = 1'b1;
    rob_free           = ROB_CNT_W'(ROB_ENTRIES);
    rob_tail           = '0;
    int_free           = INT_CNT_W'(RS_INT_ENTRIES);
    mem_free           = MEM_CNT_W'(RS_MEM_ENTRIES);
    ren_dispatch_ready = 1'b1;
    ren_src_ready      = '1;
    ren_src1_data      = '0;
    ren_src2_data      = '0;
    for (int k = 0; k < W; k++) begin
      ren_src1_tag[k] = TAG_W'(10 + k);
      ren_src2_tag[k] = TAG_W'(20 + k);
      ren_dst_tag[k]  = TAG_W'(40 + k);
      ren_old_tag[k]  = TAG_W'(50 + k);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Cases
  // ---------------------------------------------------------------------------
  initial begin
    checks = 0;

    // T1: one slot for each RS. beq, add, lw in slots 0, 1, 2.
    cur = "T1 beq/add/lw";
    env_all_free();
    dec_uop[0] = i_beq(5'd5, 5'd0);
    dec_uop[1] = i_add(5'd5, 5'd1, 5'd2);
    dec_uop[2] = i_lw(5'd6, 5'd5);
    #1;
    chk(dec_ready === 1'b1,      "bundle must be accepted: everything is free");
    chk(rob_alloc === 3'b111,    "every valid slot allocates a ROB entry");
    chk(int_wr    === 3'b011,    "beq and add go to RS INT");
    chk(mem_wr    === 3'b100,    "lw goes to RS MEM");
    chk(int_port0_only(0) === 1'b1, "beq (FU_BRANCH) is port0_only");
    chk(int_port0_only(1) === 1'b0, "add can use either port");

    // T2: sw, jalr, jal          -- to write
    // T3: illegal, ecall, sd     -- to write
    // T4: add, addi, lui         -- to write
    // T5: ld, invalid, invalid   -- to write
    // A1..A8: acceptance table   -- to write

    $display("PASS dispatch_tb (%0d checks)", checks);
    $finish;
  end

endmodule
