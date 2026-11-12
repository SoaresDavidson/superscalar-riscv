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
//   T1..T5  routing: which slot goes to which RS, ROB allocation
//   A1..A8  acceptance: when the bundle enters and which ready signals rise
//           (table-driven: one accept_case line per case)
//   C1..C4  contents: what Dispatch sends to Rename, to each RS and to the ROB

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
  // Copies of one slot's output, so a case can read e.field safely.
  function automatic rs_int_entry_t int_at(int k);
    rs_int_entry_t e;
    e = int_entry[k];
    return e;
  endfunction

  function automatic rs_mem_entry_t mem_at(int k);
    rs_mem_entry_t e;
    e = mem_entry[k];
    return e;
  endfunction

  function automatic rob_entry_t rob_at(int k);
    rob_entry_t e;
    e = rob_entry[k];
    return e;
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

  function automatic uop_t i_addi(logic [4:0] rd, logic [4:0] rs1);
    return mk(ALU_ADD, rd, 1'b1, rs1, 1'b1, 5'd0, 1'b0);
  endfunction

  function automatic uop_t i_lui(logic [4:0] rd);
    return mk(ALU_LUI, rd, 1'b1, 5'd0, 1'b0, 5'd0, 1'b0);
  endfunction

  function automatic uop_t i_beq(logic [4:0] rs1, logic [4:0] rs2);
    return mk(BR_BEQ, 5'd0, 1'b0, rs1, 1'b1, rs2, 1'b1);
  endfunction

  function automatic uop_t i_lw(logic [4:0] rd, logic [4:0] rs1);
    return mk(AGU_LW, rd, 1'b1, rs1, 1'b1, 5'd0, 1'b0);
  endfunction

  function automatic uop_t i_sw(logic [4:0] rs2, logic [4:0] rs1);
    return mk(AGU_SW, 5'd0, 1'b0, rs1, 1'b1, rs2, 1'b1);
  endfunction

  function automatic uop_t i_jalr(logic [4:0] rd, logic [4:0] rs1);
    return mk(BR_JALR, rd, 1'b1, rs1, 1'b1, 5'd0, 1'b0);
  endfunction

  function automatic uop_t i_jal(logic [4:0] rd);
    return mk(ALU_PC4, rd, 1'b1, 5'd0, 1'b0, 5'd0, 1'b0);
  endfunction

  function automatic uop_t i_sd(logic [4:0] rs2, logic [4:0] rs1);
    return mk(AGU_SD, 5'd0, 1'b0, rs1, 1'b1, rs2, 1'b1);
  endfunction

  function automatic uop_t i_illegal();
    uop_t u;
    u = mk(OP_NONE, 5'd0, 1'b0, 5'd0, 1'b0, 5'd0, 1'b0);
    u.illegal = 1'b1;
    return u;
  endfunction

  function automatic uop_t i_ecall();
    uop_t u;
    u = mk(OP_NONE, 5'd0, 1'b0, 5'd0, 1'b0, 5'd0, 1'b0);
    u.serializing = 1'b1;
    return u;
  endfunction

  function automatic uop_t i_ld(logic [4:0] rd, logic [4:0] rs1);
    return mk(AGU_LD, rd, 1'b1, rs1, 1'b1, 5'd0, 1'b0);
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
  // Group A: acceptance. Always the T1 bundle (beq, add, lw), which needs
  // 3 ROB entries, 2 tags, 2 RS INT entries and 1 RS MEM entry. Each case
  // only changes the neighbours' answers and states three expectations:
  //   accept   : the bundle enters (seen as rob_alloc/int_wr/mem_wr)
  //   dec_rdy  : dec_ready, "I have room" (space_ok && tags), to Decode
  //   space_ok : ren_rob_ready, so that Rename only allocates when it fits
  // ---------------------------------------------------------------------------
  task automatic accept_case(string name,
                             int rob, logic tags, int ints, int mems,
                             logic valid, logic fl,
                             logic exp_accept, logic exp_dec_rdy, logic exp_space_ok);
    cur = name;
    env_all_free();
    rob_free           = ROB_CNT_W'(rob);
    ren_dispatch_ready = tags;
    int_free           = INT_CNT_W'(ints);
    mem_free           = MEM_CNT_W'(mems);
    dec_valid          = valid;
    flush              = fl;
    dec_uop[0] = i_beq(5'd5, 5'd0);
    dec_uop[1] = i_add(5'd5, 5'd1, 5'd2);
    dec_uop[2] = i_lw(5'd6, 5'd5);
    #1;
    chk(dec_ready     === exp_dec_rdy,  "dec_ready (out_ready to Decode)");
    chk(ren_rob_ready === exp_space_ok, "ren_rob_ready (space_ok to Rename)");
    chk(rob_alloc === (exp_accept ? 3'b111 : 3'b000), "rob_alloc follows accept");
    chk(int_wr    === (exp_accept ? 3'b011 : 3'b000), "int_wr follows accept");
    chk(mem_wr    === (exp_accept ? 3'b100 : 3'b000), "mem_wr follows accept");
  endtask

  // ---------------------------------------------------------------------------
  // Cases
  // ---------------------------------------------------------------------------
  initial begin
    uop_t          u;
    rs_int_entry_t ei;
    rs_mem_entry_t em;
    rob_entry_t    er;
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

    // T2: sw, jalr, jal in slots 0, 1, 2.
    cur = "T2 sw/jalr/jal";
    env_all_free();
    dec_uop[0] = i_sw(5'd6, 5'd5);    // sw x6, 0(x5)
    dec_uop[1] = i_jalr(5'd1, 5'd5);  // jalr x1, 0(x5)
    dec_uop[2] = i_jal(5'd1);         // jal x1, L
    #1;
    chk(dec_ready === 1'b1,         "bundle must be accepted: everything is free");
    chk(rob_alloc === 3'b111,       "every valid slot allocates a ROB entry");
    chk(int_wr    === 3'b110,       "jalr and jal go to RS INT");
    chk(mem_wr    === 3'b001,       "sw goes to RS MEM");

    // T3: illegal, ecall, sd in slots 0, 1, 2.
    cur = "T3 illegal/ecall/sd";
    env_all_free();
    dec_uop[0] = i_illegal();         // illegal encoding
    dec_uop[1] = i_ecall();           // ecall
    dec_uop[2] = i_sd(5'd7, 5'd5);    // sd x7, 0(x5)
    #1;
    chk(dec_ready === 1'b1,   "bundle must be accepted: everything is free");
    chk(rob_alloc === 3'b111, "FU_NONE slots still allocate a ROB entry");
    chk(int_wr    === 3'b000, "no slot goes to RS INT");
    chk(mem_wr    === 3'b100, "sd goes to RS MEM");

    // T4: add, addi, lui in slots 0, 1, 2 (all three to RS INT).
    cur = "T4 add/addi/lui";
    env_all_free();
    dec_uop[0] = i_add(5'd5, 5'd1, 5'd2);   // add  x5, x1, x2
    dec_uop[1] = i_addi(5'd6, 5'd5);        // addi x6, x5, imm
    dec_uop[2] = i_lui(5'd7);               // lui  x7, imm
    #1;
    chk(dec_ready === 1'b1,         "bundle must be accepted: everything is free");
    chk(rob_alloc === 3'b111,       "every valid slot allocates a ROB entry");
    chk(int_wr    === 3'b111,       "add, addi and lui all go to RS INT");
    chk(mem_wr    === 3'b000,       "no slot goes to RS MEM");

    // T5: ld, invalid, invalid. Slot 2 carries a garbage BR_BEQ.
    cur = "T5 ld/invalid/invalid";
    env_all_free();
    dec_uop[0] = i_ld(5'd8, 5'd5);     // ld x8, 0(x5)
    dec_uop[1] = i_invalid(ALU_ADD);   // invalid slot
    dec_uop[2] = i_invalid(BR_BEQ);    // invalid slot with a garbage BR_BEQ
    #1;
    chk(dec_ready === 1'b1,         "a partly empty bundle is accepted when there is room");
    chk(rob_alloc === 3'b001,       "only the valid slot allocates a ROB entry");
    chk(int_wr    === 3'b000,       "invalid slots never go to RS INT, whatever op says");
    chk(mem_wr    === 3'b001,       "ld (slot 0) goes to RS MEM");

    // A1..A8: acceptance. One line per row of the table in Dispatch.md.
    //            name                    ROB tags INT MEM valid flush | accept dec_rdy space_ok
    accept_case("A1 everything free",      8, 1,   8,  4,  1,    0,      1,     1,      1);
    accept_case("A2 ROB short (2 < 3)",    2, 1,   8,  4,  1,    0,      0,     0,      0);
    accept_case("A3 RS INT short (1 < 2)", 8, 1,   1,  4,  1,    0,      0,     0,      0);
    accept_case("A4 RS MEM full",          8, 1,   8,  0,  1,    0,      0,     0,      0);
    accept_case("A5 no tags",              8, 0,   8,  4,  1,    0,      0,     0,      1);
    accept_case("A6 exact fit",            3, 1,   2,  1,  1,    0,      1,     1,      1);
    accept_case("A7 Decode has nothing",   8, 1,   8,  4,  0,    0,      0,     1,      1);
    accept_case("A8 flush",                8, 1,   8,  4,  1,    1,      0,     1,      1);


    // C1: requests to Rename. A source that is x0 or unused goes as 0, even
    // when the rs field holds garbage; writes_rd only for slots with has_dest.
    cur = "C1 requests to Rename";
    env_all_free();
    dec_uop[0] = i_beq(5'd5, 5'd0);          // beq x5, x0: rs2 is x0
    dec_uop[1] = i_add(5'd5, 5'd1, 5'd2);    // add x5, x1, x2
    u = i_lw(5'd6, 5'd5);                    // lw  x6, 0(x5): no rs2...
    u.rs2 = 5'd31;                           // ...but garbage in the field
    dec_uop[2] = u;
    #1;
    chk(ren_dispatch_valid === 1'b1,  "dispatch_valid = dec_valid && !flush");
    chk(ren_slot_valid === 3'b111,    "slot_valid follows uop.valid");
    chk(ren_rs1[0] === 5'd5,          "beq: rs1 = x5");
    chk(ren_rs2[0] === 5'd0,          "beq: rs2 = x0 goes as 0");
    chk(ren_rs1[1] === 5'd1,          "add: rs1 = x1");
    chk(ren_rs2[1] === 5'd2,          "add: rs2 = x2");
    chk(ren_rs1[2] === 5'd5,          "lw: rs1 = x5");
    chk(ren_rs2[2] === 5'd0,          "lw: unused rs2 goes as 0, not the garbage 31");
    chk(ren_rd[1] === 5'd5,           "add: rd = x5");
    chk(ren_rd[2] === 5'd6,           "lw: rd = x6");
    chk(ren_writes_rd === 3'b110,     "writes_rd only for add and lw");

    // C2: RS INT entry of the add in slot 1. Rename says src1 is ready
    // (with a value) and src2 is still waiting for its tag.
    cur = "C2 RS INT entry";
    env_all_free();
    dec_uop[0] = i_beq(5'd5, 5'd0);
    u = i_add(5'd5, 5'd1, 5'd2);
    u.pc = 64'h1004;
    dec_uop[1] = u;
    dec_uop[2] = i_lw(5'd6, 5'd5);
    ren_src_ready[1] = 2'b01;                // [0] = src1 ready, [1] = src2 waiting
    ren_src1_data[1] = 64'h1111;
    #1;
    ei = int_at(1);
    chk(ei.busy === 1'b1,             "add: busy");
    chk(ei.src1_ready === 1'b1,       "add: src1_ready from Rename");
    chk(ei.src1_tag === TAG_W'(11),   "add: src1_tag from Rename");
    chk(ei.src1_data === 64'h1111,    "add: src1_data from Rename");
    chk(ei.src2_ready === 1'b0,       "add: src2 still waiting");
    chk(ei.src2_tag === TAG_W'(21),   "add: src2_tag = the tag it waits for");
    chk(ei.op === ALU_ADD,            "add: op copied from uop");
    chk(ei.use_imm === 1'b0,          "add: second operand is rs2");
    chk(ei.pc === 64'h1004,           "add: pc copied from uop");
    chk(ei.dst_tag === TAG_W'(41),    "add: dst_tag from Rename");
    chk(ei.wr_en === 1'b1,            "add: writes rd");
    ei = int_at(0);
    chk(ei.op === BR_BEQ,             "beq: op copied from uop");
    chk(ei.wr_en === 1'b0,            "beq: writes no register");

    // C3: RS MEM entry of the lw in slot 2. The base (src1) is waiting; the
    // unused src2 enters ready.
    cur = "C3 RS MEM entry";
    env_all_free();
    dec_uop[0] = i_beq(5'd5, 5'd0);
    dec_uop[1] = i_add(5'd5, 5'd1, 5'd2);
    u = i_lw(5'd6, 5'd5);
    u.imm = 64'd8;                           // lw x6, 8(x5)
    dec_uop[2] = u;
    ren_src_ready[2] = 2'b10;                // src1 waiting, src2 (unused) ready
    #1;
    em = mem_at(2);
    chk(em.busy === 1'b1,             "lw: busy");
    chk(em.src1_ready === 1'b0,       "lw: base still waiting");
    chk(em.src1_tag === TAG_W'(12),   "lw: src1_tag from Rename");
    chk(em.src2_ready === 1'b1,       "lw: unused src2 enters ready");
    chk(em.op === AGU_LW,             "lw: op copied from uop");
    chk(em.imm === 64'd8,             "lw: imm copied from uop");
    chk(em.dst_tag === TAG_W'(42),    "lw: dst_tag from Rename");
    chk(em.wr_en === 1'b1,            "lw: writes rd");

    // C4: ROB entries. FU_NONE slots enter already done, with their flag;
    // a normal instruction carries what commit needs.
    cur = "C4 ROB entries";
    env_all_free();
    u = i_illegal();  u.pc = 64'h2000;  dec_uop[0] = u;
    u = i_ecall();    u.pc = 64'h2004;  dec_uop[1] = u;
    u = i_add(5'd5, 5'd1, 5'd2);  u.pc = 64'h2008;  dec_uop[2] = u;
    #1;
    chk(rob_alloc === 3'b111,         "all three allocate a ROB entry");
    er = rob_at(0);
    chk(er.pc === 64'h2000,           "illegal: pc for the exception");
    chk(er.done === 1'b1,             "illegal: no FU will answer, enters done");
    chk(er.illegal === 1'b1,          "illegal: flag set");
    chk(er.serializing === 1'b0,      "illegal: not serializing");
    chk(er.has_dest === 1'b0,         "illegal: writes no register");
    er = rob_at(1);
    chk(er.done === 1'b1,             "ecall: enters done");
    chk(er.serializing === 1'b1,      "ecall: serializing");
    chk(er.illegal === 1'b0,          "ecall: not illegal");
    er = rob_at(2);
    chk(er.pc === 64'h2008,           "add: pc");
    chk(er.done === 1'b0,             "add: waits for its FU");
    chk(er.has_dest === 1'b1,         "add: writes rd");
    chk(er.rd === 5'd5,               "add: architectural rd");
    chk(er.dst_tag === TAG_W'(42),    "add: dst_tag (slot 2) from Rename");
    chk(er.old_tag === TAG_W'(52),    "add: old_tag (slot 2), freed at commit");

    $display("PASS dispatch_tb (%0d checks)", checks);
    $finish;
  end

endmodule
