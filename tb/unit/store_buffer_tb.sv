// Unit testbench for store_buffer. Spec: wiki Memory.md, "Store buffer:
// interface do bloco" and "Ciclo de vida de uma entrada".
//
// Same scheme as rs_mem_tb: drive inputs 1 time unit after the edge, check
// the outputs of the current cycle, tick() to cross an edge.
//
// The testbench plays four neighbours:
//   Dispatch     : drives sb_alloc.
//   Store AGU    : drives st_valid / st_resp / st_data / st_op / st_idx.
//   ROB          : drives st_commit.
//   Data memory  : drives wr_ready (1 unless a case says so).
// and the load side of the forwarding search (fw_addr, fw_op, fw_color).
//
// Cases:
//   S1  reset                         S7  commit and flush in the same cycle
//   S2  reservation of a bundle       S8  store with an exception
//   S3  out-of-order execution,       S9  full buffer and back to empty
//       in-order write, commit and    S10 wrap of the pointers
//       write in the same cycle       S11 forwarding search
//   S4  write data, address, strobe   S12 two commits in one cycle (robustness:
//   S5  memory busy (wr_ready = 0)        the retire_team never does it)
//   S6  flush: completed entries stay
module store_buffer_tb;
  import execute_pkg::*;

  localparam int W        = 3;
  localparam int SB_CNT_W = $clog2(SB_ENTRIES + 1);

  // ---------------------------------------------------------------------------
  // DUT ports
  // ---------------------------------------------------------------------------
  logic clk = 1'b0, reset, flush;

  logic [W-1:0]        sb_alloc;
  logic [SB_CNT_W-1:0] sb_free;
  sb_ptr_t             sb_tail;

  logic                st_valid;
  fu_resp_t            st_resp;
  xlen_t               st_data;
  exec_op_t            st_op;
  lsq_idx_t            st_idx;

  logic [W-1:0]        st_commit;
  logic                lsu_ready;

  logic                wr_valid, wr_ready;
  xlen_t               wr_addr, wr_data;
  logic [7:0]          wr_strb;

  logic                ret_valid;
  sb_ptr_t             ret_idx;

  xlen_t               fw_addr;
  exec_op_t            fw_op;
  sb_ptr_t             fw_color;
  logic                fw_match, fw_full;
  xlen_t               fw_data;
  sb_ptr_t             fw_idx;

  logic                sb_empty;

  initial forever #5 clk = ~clk;

  store_buffer #(.W(W)) dut (.*);

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

  task automatic settle();
    #1;
  endtask

  function automatic sb_ptr_t sb(logic w, int i);
    return {w, (SB_PTR_W-1)'(i)};
  endfunction

  // ---------------------------------------------------------------------------
  // Neighbours
  // ---------------------------------------------------------------------------
  task automatic idle();
    flush     = 1'b0;
    sb_alloc  = '0;
    st_valid  = 1'b0;
    st_resp   = '0;
    st_data   = '0;
    st_op     = AGU_SD;
    st_idx    = '0;
    st_commit = '0;
    wr_ready  = 1'b1;
    fw_addr   = '0;
    fw_op     = AGU_LD;
    fw_color  = '0;
  endtask

  task automatic do_reset();
    idle();
    reset = 1'b1;
    tick();
    reset = 1'b0;
  endtask

  // Drives one AGU store response for the next edge (does not tick).
  task automatic set_store(sb_ptr_t idx, xlen_t addr, xlen_t data, exec_op_t op, logic exc);
    fu_resp_t r;
    r           = '0;
    r.result    = addr;
    r.exception = exc;
    r.cause     = exc_cause_t'(exc ? CAUSE_STORE_MISALIGNED : CAUSE_NONE);
    st_valid    = 1'b1;
    st_resp     = r;
    st_data     = data;
    st_op       = op;
    st_idx      = lsq_idx_t'(idx);
  endtask

  task automatic alloc(int n);
    sb_alloc = W'((1 << n) - 1);
    tick();
    sb_alloc = '0;
  endtask

  task automatic store(sb_ptr_t idx, xlen_t addr, xlen_t data, exec_op_t op);
    set_store(idx, addr, data, op, 1'b0);
    tick();
    st_valid = 1'b0;
  endtask

  task automatic commit();
    st_commit = 3'b001;
    tick();
    st_commit = '0;
  endtask

  // Expected write of the current cycle.
  task automatic expect_wr(xlen_t addr, xlen_t data, logic [7:0] strb, sb_ptr_t idx, string what);
    chk(wr_valid === 1'b1,  {what, ": a write is offered"});
    chk(wr_addr  === addr,  $sformatf("%s: wr_addr %h, expected %h", what, wr_addr, addr));
    chk(wr_strb  === strb,  $sformatf("%s: wr_strb %b, expected %b", what, wr_strb, strb));
    chk((wr_data & strb_mask(strb)) === (data & strb_mask(strb)),
        $sformatf("%s: wr_data %h, expected %h in the strobed bytes", what, wr_data, data));
    chk(ret_valid === wr_ready, {what, ": ret_valid follows the transfer"});
    chk(ret_idx  === idx,   {what, ": ret_idx is the entry written"});
  endtask

  function automatic xlen_t strb_mask(logic [7:0] strb);
    xlen_t m;
    for (int b = 0; b < 8; b++) m[8*b +: 8] = {8{strb[b]}};
    return m;
  endfunction

  // ---------------------------------------------------------------------------
  // Cases
  // ---------------------------------------------------------------------------
  initial begin
    checks = 0;

    // S1: after reset the buffer is empty.
    cur = "S1 reset";
    do_reset();
    chk(sb_free   === SB_CNT_W'(12), "12 free entries");
    chk(sb_tail   === sb(1'b0, 0),   "tail at entry 0");
    chk(sb_empty  === 1'b1,          "empty");
    chk(wr_valid  === 1'b0,          "no write");
    chk(ret_valid === 1'b0,          "no store leaves");
    chk(lsu_ready === 1'b1,          "lsu_ready is always 1");

    // S2: a bundle with three stores reserves entries 0..2 in one cycle.
    cur = "S2 reservation";
    do_reset();
    sb_alloc = 3'b111;
    settle();
    chk(sb_free === SB_CNT_W'(12), "free counts the start of the cycle");
    tick();
    sb_alloc = '0;
    chk(sb_free  === SB_CNT_W'(9), "three reserved");
    chk(sb_tail  === sb(1'b0, 3),  "tail after the three");
    chk(sb_empty === 1'b0,         "not empty");
    chk(wr_valid === 1'b0,         "reserved entries never write");
    sb_alloc = 3'b101;             // two stores, in slots 0 and 2
    tick();
    sb_alloc = '0;
    chk(sb_tail === sb(1'b0, 5) && sb_free === SB_CNT_W'(7), "the mask counts, not the slot positions");

    // S3: three stores execute out of order (2, 0, 1) but write in program
    // order. A commit and a write of the previous store happen in one cycle.
    cur = "S3 order";
    do_reset();
    alloc(3);
    store(sb(1'b0, 2), 64'h8010, 64'h2222, AGU_SD);
    store(sb(1'b0, 0), 64'h8000, 64'h0000, AGU_SD);
    commit();                                            // entry 0 completed
    expect_wr(64'h8000, 64'h0000, 8'hFF, sb(1'b0, 0), "entry 0 writes first");
    store(sb(1'b0, 1), 64'h8008, 64'h1111, AGU_SD);      // entry 0 written at this edge
    chk(wr_valid === 1'b0, "entry 1 finished but not committed: no write");
    st_commit = 3'b001;                                  // commit entry 1 ...
    settle();
    chk(wr_valid === 1'b0, "... the commit takes effect at the edge");
    tick();
    st_commit = 3'b001;                                  // ... and entry 2, while entry 1 writes
    expect_wr(64'h8008, 64'h1111, 8'hFF, sb(1'b0, 1), "entry 1 next");
    tick();
    st_commit = '0;
    expect_wr(64'h8010, 64'h2222, 8'hFF, sb(1'b0, 2), "entry 2 last");
    tick();
    chk(wr_valid === 1'b0 && sb_empty === 1'b1, "all written, empty");
    chk(sb_free === SB_CNT_W'(12), "all free");

    // S4: data lane, address and strobe for each size and offset.
    cur = "S4 write format";
    do_reset();
    alloc(3);
    store(sb(1'b0, 0), 64'h8003, 64'hFFFF_FFFF_FFFF_FFAB, AGU_SB);
    store(sb(1'b0, 1), 64'h800A, 64'h0000_0000_0000_BEEF, AGU_SH);
    store(sb(1'b0, 2), 64'h8014, 64'h0000_0000_1234_5678, AGU_SW);
    commit();
    expect_wr(64'h8000, 64'h0000_0000_AB00_0000, 8'b0000_1000, sb(1'b0, 0), "SB at byte 3");
    commit();
    expect_wr(64'h8008, 64'h0000_0000_BEEF_0000, 8'b0000_1100, sb(1'b0, 1), "SH at byte 2");
    commit();
    expect_wr(64'h8010, 64'h1234_5678_0000_0000, 8'b1111_0000, sb(1'b0, 2), "SW at byte 4");

    // S5: the memory is busy: the completed entry waits, unchanged, and is
    // written exactly once.
    cur = "S5 memory busy";
    do_reset();
    alloc(1);
    store(sb(1'b0, 0), 64'h8020, 64'h5555, AGU_SD);
    commit();
    wr_ready = 1'b0;
    settle();
    chk(wr_valid === 1'b1 && ret_valid === 1'b0, "offered, not taken");
    tick();
    chk(wr_valid === 1'b1 && wr_addr === 64'h8020, "still offered, same write");
    chk(sb_free === SB_CNT_W'(11), "the entry is still in use");
    wr_ready = 1'b1;
    settle();
    chk(ret_valid === 1'b1 && ret_idx === sb(1'b0, 0), "taken now");
    tick();
    chk(wr_valid === 1'b0 && sb_empty === 1'b1, "written exactly once");

    // S6: flush with 2 completed, 1 finished and 1 reserved. The completed
    // stay and are still written; the others free their entries, and the
    // next reservation reuses them.
    cur = "S6 flush";
    do_reset();
    wr_ready = 1'b0;
    alloc(3);
    alloc(1);
    store(sb(1'b0, 0), 64'h8030, 64'hA0, AGU_SD);
    store(sb(1'b0, 1), 64'h8038, 64'hA1, AGU_SD);
    store(sb(1'b0, 2), 64'h8040, 64'hA2, AGU_SD);        // entry 3 stays reserved
    commit();
    commit();
    chk(sb_free === SB_CNT_W'(8), "four in use");
    flush = 1'b1;
    tick();
    flush = 1'b0;
    chk(sb_free === SB_CNT_W'(10), "the two completed stay");
    chk(sb_tail === sb(1'b0, 2),   "tail back to the completed boundary");
    wr_ready = 1'b1;
    settle();
    expect_wr(64'h8030, 64'hA0, 8'hFF, sb(1'b0, 0), "completed entry 0 written after the flush");
    tick();
    expect_wr(64'h8038, 64'hA1, 8'hFF, sb(1'b0, 1), "completed entry 1 written after the flush");
    tick();
    chk(wr_valid === 1'b0 && sb_empty === 1'b1, "the flushed entries never write");
    alloc(1);
    chk(sb_tail === sb(1'b0, 3), "the next reservation takes entry 2 again");
    store(sb(1'b0, 2), 64'h8048, 64'hB2, AGU_SD);
    commit();
    expect_wr(64'h8048, 64'hB2, 8'hFF, sb(1'b0, 2), "reused entry 2 holds the new store");

    // S7: commit and flush in one cycle (violation flush): the committed
    // store survives and is written.
    cur = "S7 commit and flush together";
    do_reset();
    wr_ready = 1'b0;
    alloc(2);
    store(sb(1'b0, 0), 64'h8050, 64'hC0, AGU_SD);
    store(sb(1'b0, 1), 64'h8058, 64'hC1, AGU_SD);
    st_commit = 3'b001;
    flush     = 1'b1;
    tick();
    st_commit = '0;
    flush     = 1'b0;
    chk(sb_free === SB_CNT_W'(11), "the store committed in the flush cycle stays");
    chk(sb_tail === sb(1'b0, 1),   "tail right after it");
    fw_addr  = 64'h8050;
    fw_op    = AGU_LD;
    fw_color = sb(1'b0, 0);   // a load right after the surviving store
    settle();
    chk(fw_match === 1'b1 && fw_full === 1'b1 && fw_idx === sb(1'b0, 0),
        "the surviving store is still visible to loads");
    wr_ready = 1'b1;
    settle();
    expect_wr(64'h8050, 64'hC0, 8'hFF, sb(1'b0, 0), "and is written");
    tick();
    chk(wr_valid === 1'b0, "the other one was dropped");

    // S8: a store with a misalignment exception fills nothing: its entry
    // stays reserved (no write, not visible to loads) until the trap flush.
    cur = "S8 store with an exception";
    do_reset();
    alloc(1);
    set_store(sb(1'b0, 0), 64'h8061, 64'hDD, AGU_SH, 1'b1);
    tick();
    st_valid = 1'b0;
    fw_addr  = 64'h8060;
    fw_op    = AGU_LD;
    fw_color = sb(1'b0, 0);
    settle();
    chk(fw_match === 1'b0, "a reserved entry is not visible to the search");
    chk(sb_free === SB_CNT_W'(11) && wr_valid === 1'b0, "reserved, no write");
    flush = 1'b1;
    tick();
    flush = 1'b0;
    chk(sb_empty === 1'b1, "the trap flush frees it");

    // S9: twelve reservations fill the buffer; it empties back.
    cur = "S9 full";
    do_reset();
    alloc(3); alloc(3); alloc(3); alloc(3);
    chk(sb_free === SB_CNT_W'(0), "full");
    chk(sb_tail === sb(1'b1, 0),  "tail wrapped to entry 0, wrap bit set");
    for (int i = 0; i < 12; i++) store(sb(1'b0, i), 64'h8100 + 8 * i, 64'(i), AGU_SD);
    for (int i = 0; i < 12; i++) begin
      st_commit = 3'b001;
      settle();
      if (i > 0) expect_wr(64'h8100 + 8 * (i - 1), 64'(i - 1), 8'hFF, sb(1'b0, i - 1), "full: in order");
      tick();
    end
    st_commit = '0;
    expect_wr(64'h8100 + 88, 64'd11, 8'hFF, sb(1'b0, 11), "full: last");
    tick();
    chk(sb_free === SB_CNT_W'(12) && sb_empty === 1'b1, "empty again");

    // S10: the pointers wrap past entry 11 (head 11 -> 0 with the wrap bit).
    cur = "S10 wrap";
    // continues from S9: head = tail = {1, 0}
    alloc(3);
    chk(sb_tail === sb(1'b1, 3), "tail after the wrap");
    store(sb(1'b1, 0), 64'h8200, 64'h10, AGU_SD);
    store(sb(1'b1, 1), 64'h8208, 64'h11, AGU_SD);
    store(sb(1'b1, 2), 64'h8210, 64'h12, AGU_SD);
    commit();
    expect_wr(64'h8200, 64'h10, 8'hFF, sb(1'b1, 0), "entry 0 of the second lap");
    commit();
    commit();
    tick();
    chk(sb_empty === 1'b1, "empty");

    // S11: forwarding search. A (SD at 0x8300) and B (SW at 0x8304) are
    // finished; C is reserved.
    cur = "S11 forwarding";
    do_reset();
    alloc(3);
    store(sb(1'b0, 0), 64'h8300, 64'h1111_2222_3333_4444, AGU_SD);   // A
    store(sb(1'b0, 1), 64'h8304, 64'h0000_0000_AAAA_BBBB, AGU_SW);   // B
    // LD 0x8300, color B: B (younger) overlaps bytes 4..7 but does not
    // cover the load: match, not full, blocked by B.
    fw_addr = 64'h8300; fw_op = AGU_LD; fw_color = sb(1'b0, 1);
    settle();
    chk(fw_match === 1'b1 && fw_full === 1'b0, "LD over A and B: partial cover by B");
    chk(fw_idx === sb(1'b0, 1), "the youngest overlapping store is B");
    // LW 0x8304: B covers it.
    fw_addr = 64'h8304; fw_op = AGU_LW;
    settle();
    chk(fw_match === 1'b1 && fw_full === 1'b1 && fw_idx === sb(1'b0, 1), "LW at 0x8304: B covers");
    chk(fw_data[63:32] === 32'hAAAA_BBBB, "B's data in bytes 4..7");
    // LW 0x8300: only A overlaps (B is bytes 4..7), and A covers it.
    fw_addr = 64'h8300; fw_op = AGU_LW;
    settle();
    chk(fw_match === 1'b1 && fw_full === 1'b1 && fw_idx === sb(1'b0, 0), "LW at 0x8300: A covers");
    chk(fw_data[31:0] === 32'h3333_4444, "A's data in bytes 0..3");
    // LH 0x8306, color A: B is younger than the load, so it does not count.
    fw_addr = 64'h8306; fw_op = AGU_LH; fw_color = sb(1'b0, 0);
    settle();
    chk(fw_match === 1'b1 && fw_idx === sb(1'b0, 0) && fw_full === 1'b1,
        "color A: only A is older; it covers bytes 6..7");
    chk(fw_data[63:48] === 16'h1111, "A's data in bytes 6..7");
    // Color before A: no older store in the buffer.
    fw_color = sb(1'b1, 11);
    settle();
    chk(fw_match === 1'b0, "no store older than the load");
    // Color C (reserved): same answer as color B.
    fw_addr = 64'h8304; fw_op = AGU_LW; fw_color = sb(1'b0, 2);
    settle();
    chk(fw_match === 1'b1 && fw_idx === sb(1'b0, 1), "a reserved entry is skipped");
    // Another doubleword: no match.
    fw_addr = 64'h8308; fw_op = AGU_LB;
    settle();
    chk(fw_match === 1'b0, "different doubleword");
    // Completed entries are searched too, until they leave.
    wr_ready = 1'b0;
    commit();
    fw_addr = 64'h8300; fw_op = AGU_LW; fw_color = sb(1'b0, 0);
    settle();
    chk(fw_match === 1'b1 && fw_idx === sb(1'b0, 0), "a completed store is still searched");
    wr_ready = 1'b1;
    tick();
    chk(fw_match === 1'b0, "after A leaves, a color pointing to A selects nothing");

    // S12: two commits in one cycle (the retire_team commits at most one
    // store per cycle; this checks the buffer does not depend on it).
    cur = "S12 two commits";
    do_reset();
    wr_ready = 1'b0;
    alloc(2);
    store(sb(1'b0, 0), 64'h8400, 64'hE0, AGU_SD);
    store(sb(1'b0, 1), 64'h8408, 64'hE1, AGU_SD);
    st_commit = 3'b011;
    tick();
    st_commit = '0;
    flush = 1'b1;              // both completed: the flush keeps both
    tick();
    flush = 1'b0;
    chk(sb_free === SB_CNT_W'(10), "both committed in one cycle");
    wr_ready = 1'b1;
    settle();
    expect_wr(64'h8400, 64'hE0, 8'hFF, sb(1'b0, 0), "first");
    tick();
    expect_wr(64'h8408, 64'hE1, 8'hFF, sb(1'b0, 1), "second");

    $display("PASS store_buffer_tb (%0d checks)", checks);
    $finish;
  end

  initial begin #100000; $fatal(1, "store_buffer_tb: timeout"); end

endmodule
