// Unit testbench for rs_int. Spec: docs/rs/RS.md.
//
// The RS holds state, so every case drives the inputs, checks the outputs
// of the current cycle and then calls tick() to cross a clock edge. Inputs
// change 1 time unit after the edge; outputs are checked before the next
// edge. Inputs changed in the middle of a cycle are followed by settle()
// before any check, so combinational outputs have caught up.
//
// The testbench plays three neighbours:
//   Dispatch : drives wr / wr_entry (built with ent()).
//   FUs      : drive alu_req_ready / br_req_ready (1 unless a case says so).
//   PRF      : read_data = data_of(read_tag), always valid, so every source
//              value tells which tag was read.
//
// Cases (RS.md, "Casos para o testbench"):
//   R1  reset               R8  selection: lowest index first
//   R2  write, issue, free  R9  back-pressure (req_ready = 0)
//   R3  RS full             R10 free counts the start of the cycle
//   R4  wakeup timing       R11 k-th instruction -> k-th free entry
//   R5  two buses at once   R12 flush (with a write and a held request)
//   R6  one tag, two FUs    R13 tag reuse after flush
//   R7  write + broadcast in the same cycle

// The testbench checks only some fields of alu_req / br_req.
/* verilator lint_off UNUSEDSIGNAL */
module rs_int_tb;
  import execute_pkg::*;
  import dispatch_pkg::*;

  localparam int W       = 3;
  localparam int ENTRIES = 8;
  localparam int WB_N    = 3;
  localparam int CNT_W   = $clog2(ENTRIES + 1);

  // ---------------------------------------------------------------------------
  // DUT ports
  // ---------------------------------------------------------------------------
  logic clk = 1'b0, reset, flush;

  logic [W-1:0]               wr;
  rs_int_entry_t [W-1:0]      wr_entry;
  logic [CNT_W-1:0]           free;

  logic [WB_N-1:0]            wb_valid;
  logic [WB_N-1:0][TAG_W-1:0] wb_tag;

  logic                       alu_req_valid, alu_req_ready;
  fu_req_t                    alu_req;
  logic [1:0][TAG_W-1:0]      alu_read_tag;
  logic [1:0]                 alu_read_valid;
  logic [1:0][XLEN-1:0]       alu_read_data;

  logic                       br_req_valid, br_req_ready;
  fu_req_t                    br_req;
  logic [1:0][TAG_W-1:0]      br_read_tag;
  logic [1:0]                 br_read_valid;
  logic [1:0][XLEN-1:0]       br_read_data;

  initial forever #5 clk = ~clk;

  rs_int #(.W(W), .ENTRIES(ENTRIES), .WB_N(WB_N)) dut (.*);

  // ---------------------------------------------------------------------------
  // PRF model: every tag reads a distinct, recognisable value.
  // ---------------------------------------------------------------------------
  function automatic xlen_t data_of(tag_t t);
    return 64'h1000_0000 + XLEN'(t);
  endfunction

  assign alu_read_valid   = 2'b11;
  assign br_read_valid    = 2'b11;
  assign alu_read_data[0] = data_of(alu_read_tag[0]);
  assign alu_read_data[1] = data_of(alu_read_tag[1]);
  assign br_read_data[0]  = data_of(br_read_tag[0]);
  assign br_read_data[1]  = data_of(br_read_tag[1]);

  // ---------------------------------------------------------------------------
  // Checking
  // ---------------------------------------------------------------------------
  string cur;
  int    checks;

  task automatic chk(logic cond, string msg);
    checks++;
    if (cond !== 1'b1) $fatal(1, "[%s] %s", cur, msg);
  endtask

  task automatic tick();
    @(posedge clk);
    #1;
  endtask

  // Lets combinational outputs follow inputs changed in the middle of a
  // cycle, before they are checked.
  task automatic settle();
    #1;
  endtask

  // ---------------------------------------------------------------------------
  // Entries, as Dispatch builds them. ALU entries use ALU_ADD and write rd;
  // branch entries use BR_BEQ and write nothing.
  // ---------------------------------------------------------------------------
  function automatic rs_int_entry_t ent(exec_op_t op, tag_t dst,
                                        tag_t t1, logic r1, tag_t t2, logic r2);
    rs_int_entry_t e;
    e            = '0;
    e.busy       = 1'b1;
    e.src1_ready = r1;
    e.src1_tag   = t1;
    e.src2_ready = r2;
    e.src2_tag   = t2;
    e.op         = op;
    e.imm        = 64'd5;
    e.use_imm    = 1'b0;
    e.pc         = 64'h1000;
    e.dst_tag    = dst;
    e.wr_en      = (fu_of(op) == FU_ALU);
    return e;
  endfunction

  function automatic rs_int_entry_t alu(tag_t dst, tag_t t1, logic r1, tag_t t2, logic r2);
    return ent(ALU_ADD, dst, t1, r1, t2, r2);
  endfunction

  function automatic rs_int_entry_t br(tag_t t1, logic r1, tag_t t2, logic r2);
    return ent(BR_BEQ, '0, t1, r1, t2, r2);
  endfunction

  // Inputs at rest: no write, no broadcast, no flush, FUs free.
  task automatic idle();
    flush         = 1'b0;
    wr            = '0;
    wr_entry      = '0;
    wb_valid      = '0;
    wb_tag        = '0;
    alu_req_ready = 1'b1;
    br_req_ready  = 1'b1;
  endtask

  task automatic do_reset();
    idle();
    reset = 1'b1;
    tick();
    reset = 1'b0;
  endtask

  // A waiting ALU entry that never wakes during a case (tag 63 is never
  // broadcast unless a case says so).
  function automatic rs_int_entry_t parked(tag_t dst);
    return alu(dst, TAG_W'(63), 1'b0, TAG_W'(1), 1'b1);
  endfunction

  // ---------------------------------------------------------------------------
  // Cases
  // ---------------------------------------------------------------------------
  initial begin
    checks = 0;

    // R1: after reset the RS is empty and requests nothing.
    cur = "R1 reset";
    do_reset();
    chk(free === CNT_W'(8),    "empty RS: free = 8");
    chk(alu_req_valid === 1'b0, "no ALU request");
    chk(br_req_valid === 1'b0,  "no Branch Unit request");

    // R2: an entry with both sources ready issues the cycle after it is
    // written, with the operands read through its own tags.
    cur = "R2 write, issue, free";
    do_reset();
    wr[0]       = 1'b1;
    wr_entry[0] = alu(TAG_W'(40), TAG_W'(11), 1'b1, TAG_W'(12), 1'b1);
    settle();
    chk(free === CNT_W'(8),     "free counts the start of the cycle");
    chk(alu_req_valid === 1'b0, "an entry being written cannot issue yet");
    tick();
    idle();
    chk(free === CNT_W'(7),                    "one entry in use");
    chk(alu_req_valid === 1'b1,                "ready entry requests the ALU");
    chk(alu_read_tag[0] === TAG_W'(11),        "read port 0 gets src1_tag");
    chk(alu_read_tag[1] === TAG_W'(12),        "read port 1 gets src2_tag");
    chk(alu_req.src1 === data_of(TAG_W'(11)),  "src1 = value read for src1_tag");
    chk(alu_req.src2 === data_of(TAG_W'(12)),  "src2 = value read for src2_tag");
    chk(alu_req.op === ALU_ADD,                "op copied");
    chk(alu_req.imm === 64'd5,                 "imm copied");
    chk(alu_req.pc === 64'h1000,               "pc copied");
    chk(alu_req.dst_tag === TAG_W'(40),        "dst_tag copied");
    chk(alu_req.wr_en === 1'b1,                "wr_en copied");
    chk(br_req_valid === 1'b0,                 "an ALU entry never requests the Branch Unit");
    tick();
    chk(alu_req_valid === 1'b0, "issued once, entry freed");
    chk(free === CNT_W'(8),     "entry back to free");

    // R3: eight waiting entries fill the RS.
    cur = "R3 RS full";
    do_reset();
    wr = 3'b111;
    wr_entry[0] = parked(TAG_W'(20));
    wr_entry[1] = parked(TAG_W'(21));
    wr_entry[2] = parked(TAG_W'(22));
    tick();
    chk(free === CNT_W'(5), "three in use");
    wr_entry[0] = parked(TAG_W'(23));
    wr_entry[1] = parked(TAG_W'(24));
    wr_entry[2] = parked(TAG_W'(25));
    tick();
    chk(free === CNT_W'(2), "six in use");
    wr = 3'b011;
    wr_entry[0] = parked(TAG_W'(26));
    wr_entry[1] = parked(TAG_W'(27));
    tick();
    idle();
    chk(free === CNT_W'(0),     "RS full: free = 0");
    chk(alu_req_valid === 1'b0, "nothing ready, nothing issued");

    // R4: a source wakes on the edge after its broadcast; the entry issues
    // in the next cycle, never in the broadcast cycle itself.
    cur = "R4 wakeup timing";
    do_reset();
    wr[0]       = 1'b1;
    wr_entry[0] = alu(TAG_W'(41), TAG_W'(11), 1'b1, TAG_W'(60), 1'b0);
    tick();
    idle();
    chk(alu_req_valid === 1'b0, "src2 still waiting for tag 60");
    wb_valid[2] = 1'b1;
    wb_tag[2]   = TAG_W'(60);
    settle();
    chk(alu_req_valid === 1'b0, "not issued in the broadcast cycle");
    tick();
    idle();
    chk(alu_req_valid === 1'b1,         "woken: issues the cycle after");
    chk(alu_read_tag[1] === TAG_W'(60), "reads the tag it waited for");
    chk(alu_req.src2 === data_of(TAG_W'(60)), "src2 = value of tag 60");
    tick();
    chk(alu_req_valid === 1'b0, "issued once");

    // R5: both sources wake in the same cycle, through different buses.
    cur = "R5 two buses at once";
    do_reset();
    wr[0]       = 1'b1;
    wr_entry[0] = alu(TAG_W'(42), TAG_W'(61), 1'b0, TAG_W'(62), 1'b0);
    tick();
    idle();
    wb_valid  = 3'b011;
    wb_tag[0] = TAG_W'(61);
    wb_tag[1] = TAG_W'(62);
    tick();
    idle();
    chk(alu_req_valid === 1'b1,         "both sources woke");
    chk(alu_req.dst_tag === TAG_W'(42), "the right entry issues");

    // R6: one broadcast wakes two entries for different FUs; both issue in
    // the same cycle.
    cur = "R6 one tag, two FUs";
    do_reset();
    wr = 3'b011;
    wr_entry[0] = alu(TAG_W'(43), TAG_W'(50), 1'b0, TAG_W'(12), 1'b1);
    wr_entry[1] = br(TAG_W'(13), 1'b1, TAG_W'(50), 1'b0);
    tick();
    idle();
    chk(alu_req_valid === 1'b0 && br_req_valid === 1'b0, "both waiting for tag 50");
    wb_valid[0] = 1'b1;
    wb_tag[0]   = TAG_W'(50);
    tick();
    idle();
    chk(alu_req_valid === 1'b1,               "ALU entry woke");
    chk(br_req_valid === 1'b1,                "branch entry woke, issues in the same cycle");
    chk(alu_req.src1 === data_of(TAG_W'(50)), "ALU src1 = value of tag 50");
    chk(br_req.op === BR_BEQ,                 "branch op copied");
    chk(br_read_tag[0] === TAG_W'(13),        "branch read port 0 gets src1_tag");
    chk(br_read_tag[1] === TAG_W'(50),        "branch read port 1 gets src2_tag");
    chk(br_req.src2 === data_of(TAG_W'(50)),  "branch src2 = value of tag 50");
    chk(br_req.wr_en === 1'b0,                "branch writes no register");

    // R7: the tag a new entry waits for is broadcast in the very cycle the
    // entry is written. The entry must not miss it.
    cur = "R7 write + broadcast";
    do_reset();
    wr[0]       = 1'b1;
    wr_entry[0] = alu(TAG_W'(44), TAG_W'(51), 1'b0, TAG_W'(12), 1'b1);
    wb_valid[1] = 1'b1;
    wb_tag[1]   = TAG_W'(51);
    tick();
    idle();
    chk(alu_req_valid === 1'b1,         "woke while being written");
    chk(alu_req.dst_tag === TAG_W'(44), "the right entry issues");

    // R8: two ready ALU entries; the lower index (slot 0 -> entry 0) goes
    // first, the other in the next cycle.
    cur = "R8 lowest index first";
    do_reset();
    wr = 3'b011;
    wr_entry[0] = alu(TAG_W'(45), TAG_W'(11), 1'b1, TAG_W'(12), 1'b1);
    wr_entry[1] = alu(TAG_W'(46), TAG_W'(11), 1'b1, TAG_W'(12), 1'b1);
    tick();
    idle();
    chk(alu_req.dst_tag === TAG_W'(45) && alu_req_valid === 1'b1, "entry 0 first");
    tick();
    chk(alu_req.dst_tag === TAG_W'(46) && alu_req_valid === 1'b1, "entry 1 next");
    tick();
    chk(alu_req_valid === 1'b0, "both issued once");

    // R9: the ALU is busy; the ready entry keeps requesting, unchanged, and
    // issues exactly once when the ALU frees.
    cur = "R9 back-pressure";
    do_reset();
    wr[0]       = 1'b1;
    wr_entry[0] = alu(TAG_W'(47), TAG_W'(11), 1'b1, TAG_W'(12), 1'b1);
    tick();
    idle();
    alu_req_ready = 1'b0;
    chk(alu_req_valid === 1'b1 && alu_req.dst_tag === TAG_W'(47), "requesting");
    tick();
    chk(alu_req_valid === 1'b1 && alu_req.dst_tag === TAG_W'(47), "held, same request");
    chk(free === CNT_W'(7), "entry still in use while held");
    tick();
    chk(alu_req_valid === 1'b1 && alu_req.dst_tag === TAG_W'(47), "still held");
    alu_req_ready = 1'b1;
    tick();
    chk(alu_req_valid === 1'b0, "issued exactly once");
    chk(free === CNT_W'(8),     "entry freed after the transfer");

    // R10: with the RS full, an issue frees an entry, but free still shows 0
    // in that cycle and 1 in the next.
    cur = "R10 free counts the start of the cycle";
    do_reset();
    alu_req_ready = 1'b0;
    wr = 3'b111;
    wr_entry[0] = alu(TAG_W'(48), TAG_W'(11), 1'b1, TAG_W'(12), 1'b1);
    wr_entry[1] = parked(TAG_W'(30));
    wr_entry[2] = parked(TAG_W'(31));
    tick();
    wr_entry[0] = parked(TAG_W'(32));
    wr_entry[1] = parked(TAG_W'(33));
    wr_entry[2] = parked(TAG_W'(34));
    tick();
    wr = 3'b011;
    wr_entry[0] = parked(TAG_W'(35));
    wr_entry[1] = parked(TAG_W'(36));
    tick();
    idle();
    alu_req_ready = 1'b0;
    chk(free === CNT_W'(0),     "RS full");
    chk(alu_req_valid === 1'b1, "the ready entry is waiting for the ALU");
    alu_req_ready = 1'b1;
    settle();
    chk(free === CNT_W'(0),     "issuing now does not raise free in this cycle");
    tick();
    chk(free === CNT_W'(1),     "the freed entry shows up in the next cycle");

    // R11: the k-th instruction for this RS takes the k-th free entry,
    // whatever its slot. Holes at entries 0 and 2, entry 1 busy; slots 1 and
    // 2 write. Slot 1 must land in entry 0 (not 1, which would overwrite the
    // waiting instruction) and slot 2 in entry 2.
    cur = "R11 k-th free entry";
    do_reset();
    wr = 3'b111;
    wr_entry[0] = alu(TAG_W'(50), TAG_W'(11), 1'b1, TAG_W'(12), 1'b1);
    wr_entry[1] = alu(TAG_W'(51), TAG_W'(62), 1'b0, TAG_W'(12), 1'b1);
    wr_entry[2] = alu(TAG_W'(52), TAG_W'(11), 1'b1, TAG_W'(12), 1'b1);
    tick();
    idle();
    chk(alu_req.dst_tag === TAG_W'(50), "entry 0 issues");
    tick();
    chk(alu_req.dst_tag === TAG_W'(52), "entry 2 issues; entry 1 waits");
    tick();
    chk(free === CNT_W'(7),     "only entry 1 in use");
    chk(alu_req_valid === 1'b0, "entry 1 still waiting for tag 62");
    wr = 3'b110;
    wr_entry[1] = alu(TAG_W'(53), TAG_W'(11), 1'b1, TAG_W'(12), 1'b1);
    wr_entry[2] = alu(TAG_W'(54), TAG_W'(11), 1'b1, TAG_W'(12), 1'b1);
    tick();
    idle();
    chk(free === CNT_W'(5), "three in use: nothing was overwritten");
    chk(alu_req.dst_tag === TAG_W'(53), "slot 1 landed in entry 0");
    tick();
    chk(alu_req.dst_tag === TAG_W'(54), "slot 2 landed in entry 2");
    wb_valid[0] = 1'b1;
    wb_tag[0]   = TAG_W'(62);
    tick();
    idle();
    chk(alu_req_valid === 1'b1 && alu_req.dst_tag === TAG_W'(51),
        "the instruction in entry 1 survived and issues");

    // R12: flush empties the RS, drops a write of the same cycle and issues
    // nothing in the flush cycle.
    cur = "R12 flush";
    do_reset();
    alu_req_ready = 1'b0;
    wr = 3'b011;
    wr_entry[0] = alu(TAG_W'(55), TAG_W'(11), 1'b1, TAG_W'(12), 1'b1);
    wr_entry[1] = parked(TAG_W'(56));
    tick();
    idle();
    alu_req_ready = 1'b0;
    chk(alu_req_valid === 1'b1, "a ready entry is held by the ALU");
    flush       = 1'b1;
    wr[0]       = 1'b1;
    wr_entry[0] = alu(TAG_W'(57), TAG_W'(11), 1'b1, TAG_W'(12), 1'b1);
    settle();
    chk(alu_req_valid === 1'b0, "no request during flush");
    chk(br_req_valid === 1'b0,  "no branch request during flush");
    tick();
    idle();
    chk(free === CNT_W'(8),     "flush empties the RS, including the same-cycle write");
    chk(alu_req_valid === 1'b0, "nothing left to issue");

    // R13: a broadcast in the flush cycle must not wake an entry written
    // later that waits for the same (reused) tag.
    cur = "R13 tag reuse after flush";
    do_reset();
    flush       = 1'b1;
    wb_valid[0] = 1'b1;
    wb_tag[0]   = TAG_W'(58);
    tick();
    idle();
    wr[0]       = 1'b1;
    wr_entry[0] = alu(TAG_W'(59), TAG_W'(58), 1'b0, TAG_W'(12), 1'b1);
    tick();
    idle();
    chk(alu_req_valid === 1'b0, "not woken by the old broadcast");
    tick();
    chk(alu_req_valid === 1'b0, "still waiting");
    wb_valid[0] = 1'b1;
    wb_tag[0]   = TAG_W'(58);
    tick();
    idle();
    chk(alu_req_valid === 1'b1, "woken by the new broadcast");

    $display("PASS rs_int_tb (%0d checks)", checks);
    $finish;
  end

endmodule
/* verilator lint_on UNUSEDSIGNAL */
