// Unit testbench for rs_mem. Spec: docs/rs/RS.md.
//
// Same scheme as rs_int_tb: drive inputs, check the outputs of the current
// cycle, tick() to cross an edge. Inputs change 1 time unit after the edge;
// inputs changed in the middle of a cycle are followed by settle() before
// any check.
//
// The testbench plays three neighbours:
//   Dispatch : drives wr / wr_entry (built with ld() and st()).
//   AGU      : drives agu_req_ready (1 unless a case says so).
//   PRF      : read_data = data_of(read_tag), always valid.
//
// Loads read only src1 (base); src2 is x0 (tag 0, ready), as Dispatch builds
// it. Stores read src1 (base) and src2 (data).
//
// Cases:
//   M1  reset                    M7  write + broadcast in the same cycle
//   M2  load: write, issue, free M8  selection: lowest index first
//   M3  store fields             M9  back-pressure (agu_req_ready = 0)
//   M4  RS full (4 entries)      M10 free counts the start of the cycle
//   M5  wakeup timing            M11 k-th instruction -> k-th free entry
//   M6  store waits for its data M12 flush (with a write and a held request)
//                                M13 tag reuse after flush
//
// Side fields (lsq_idx, color): ld() and st() derive them from the entry's
// own tags, so a monitor checks on every valid request that agu_req_lsq_idx
// and agu_req_color come from the same entry as agu_req.

// The testbench checks only some fields of agu_req.
/* verilator lint_off UNUSEDSIGNAL */
module rs_mem_tb;
  import execute_pkg::*;
  import dispatch_pkg::*;

  localparam int W       = 3;
  localparam int ENTRIES = 4;
  localparam int WB_N    = 3;
  localparam int CNT_W   = $clog2(ENTRIES + 1);

  // ---------------------------------------------------------------------------
  // DUT ports
  // ---------------------------------------------------------------------------
  logic clk = 1'b0, reset, flush;

  logic [W-1:0]               wr;
  rs_mem_entry_t [W-1:0]      wr_entry;
  logic [CNT_W-1:0]           free;

  logic [WB_N-1:0]            wb_valid;
  logic [WB_N-1:0][TAG_W-1:0] wb_tag;

  logic                       agu_req_valid, agu_req_ready;
  fu_req_t                    agu_req;
  logic [1:0][TAG_W-1:0]      agu_read_tag;
  logic [1:0]                 agu_read_valid;
  logic [1:0][XLEN-1:0]       agu_read_data;
  lsq_idx_t                   agu_req_lsq_idx;
  sb_ptr_t                    agu_req_color;

  initial forever #5 clk = ~clk;

  rs_mem #(.W(W), .ENTRIES(ENTRIES), .WB_N(WB_N)) dut (.*);

  // ---------------------------------------------------------------------------
  // PRF model: every tag reads a distinct, recognisable value.
  // ---------------------------------------------------------------------------
  function automatic xlen_t data_of(tag_t t);
    return 64'h2000_0000 + XLEN'(t);
  endfunction

  assign agu_read_valid   = 2'b11;
  assign agu_read_data[0] = data_of(agu_read_tag[0]);
  assign agu_read_data[1] = data_of(agu_read_tag[1]);

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

  // ---------------------------------------------------------------------------
  // Entries, as Dispatch builds them.
  // ---------------------------------------------------------------------------
  // Side fields, derived from the entry's tags (see the header).
  function automatic lsq_idx_t ld_idx(tag_t dst);   return lsq_idx_t'(dst ^ 6'h15); endfunction
  function automatic sb_ptr_t  ld_color(tag_t dst); return sb_ptr_t'(dst + 6'd3);   endfunction
  function automatic lsq_idx_t st_idx(tag_t data);  return lsq_idx_t'(data ^ 6'h0A); endfunction

  // Monitor: the side fields follow the entry that agu_req comes from.
  always @(negedge clk) begin
    if (!reset && agu_req_valid) begin
      checks++;
      if (agu_req.op == AGU_LD) begin
        if (agu_req_lsq_idx !== ld_idx(agu_req.dst_tag) ||
            agu_req_color   !== ld_color(agu_req.dst_tag))
          $fatal(1, "[%s] load dst %0d: lsq_idx %0d color %0d from another entry",
                 cur, agu_req.dst_tag, agu_req_lsq_idx, agu_req_color);
      end else if (agu_req_lsq_idx !== st_idx(agu_read_tag[1]) || agu_req_color !== '0)
        $fatal(1, "[%s] store data tag %0d: lsq_idx %0d color %0d from another entry",
               cur, agu_read_tag[1], agu_req_lsq_idx, agu_req_color);
    end
  end

  // ld rd, 16(base): writes dst; src2 is x0.
  function automatic rs_mem_entry_t ld(tag_t dst, tag_t base, logic rb);
    rs_mem_entry_t e;
    e            = '0;
    e.busy       = 1'b1;
    e.src1_ready = rb;
    e.src1_tag   = base;
    e.src2_ready = 1'b1;
    e.src2_tag   = '0;
    e.op         = AGU_LD;
    e.imm        = 64'd16;
    e.dst_tag    = dst;
    e.wr_en      = 1'b1;
    e.lsq_idx    = ld_idx(dst);
    e.color      = ld_color(dst);
    return e;
  endfunction

  // sd data, -8(base): writes nothing.
  function automatic rs_mem_entry_t st(tag_t base, logic rb, tag_t data, logic rd);
    rs_mem_entry_t e;
    e            = '0;
    e.busy       = 1'b1;
    e.src1_ready = rb;
    e.src1_tag   = base;
    e.src2_ready = rd;
    e.src2_tag   = data;
    e.op         = AGU_SD;
    e.imm        = -64'sd8;
    e.dst_tag    = '0;
    e.wr_en      = 1'b0;
    e.lsq_idx    = st_idx(data);
    e.color      = '0;
    return e;
  endfunction

  // A load that never wakes during a case (tag 63 is never broadcast).
  function automatic rs_mem_entry_t parked(tag_t dst);
    return ld(dst, TAG_W'(63), 1'b0);
  endfunction

  task automatic idle();
    flush         = 1'b0;
    wr            = '0;
    wr_entry      = '0;
    wb_valid      = '0;
    wb_tag        = '0;
    agu_req_ready = 1'b1;
  endtask

  task automatic do_reset();
    idle();
    reset = 1'b1;
    tick();
    reset = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Cases
  // ---------------------------------------------------------------------------
  initial begin
    checks = 0;

    // M1: after reset the RS is empty and requests nothing.
    cur = "M1 reset";
    do_reset();
    chk(free === CNT_W'(4),     "empty RS: free = 4");
    chk(agu_req_valid === 1'b0, "no AGU request");

    // M2: a load with its base ready issues the cycle after it is written.
    cur = "M2 load: write, issue, free";
    do_reset();
    wr[0]       = 1'b1;
    wr_entry[0] = ld(TAG_W'(40), TAG_W'(11), 1'b1);
    settle();
    chk(free === CNT_W'(4),     "free counts the start of the cycle");
    chk(agu_req_valid === 1'b0, "an entry being written cannot issue yet");
    tick();
    idle();
    chk(free === CNT_W'(3),                   "one entry in use");
    chk(agu_req_valid === 1'b1,               "ready load requests the AGU");
    chk(agu_read_tag[0] === TAG_W'(11),       "read port 0 gets the base tag");
    chk(agu_read_tag[1] === TAG_W'(0),        "read port 1 gets x0");
    chk(agu_req.src1 === data_of(TAG_W'(11)), "src1 = base value");
    chk(agu_req.op === AGU_LD,                "op copied");
    chk(agu_req.imm === 64'd16,               "imm copied");
    chk(agu_req.dst_tag === TAG_W'(40),       "dst_tag copied");
    chk(agu_req.wr_en === 1'b1,               "a load writes its destination");
    chk(agu_req.use_imm === 1'b0,             "use_imm = 0 (not in the entry)");
    chk(agu_req.pc === '0,                    "pc = 0 (not in the entry)");
    chk(agu_req.pred_taken === 1'b0,          "pred_taken = 0 (not in the entry)");
    tick();
    chk(agu_req_valid === 1'b0, "issued once, entry freed");
    chk(free === CNT_W'(4),     "entry back to free");

    // M3: a store carries base and data to the AGU and writes nothing.
    cur = "M3 store fields";
    do_reset();
    wr[1]       = 1'b1;
    wr_entry[1] = st(TAG_W'(12), 1'b1, TAG_W'(13), 1'b1);
    tick();
    idle();
    chk(agu_req_valid === 1'b1,               "ready store requests the AGU");
    chk(agu_read_tag[0] === TAG_W'(12),       "read port 0 gets the base tag");
    chk(agu_read_tag[1] === TAG_W'(13),       "read port 1 gets the data tag");
    chk(agu_req.src1 === data_of(TAG_W'(12)), "src1 = base value");
    chk(agu_req.src2 === data_of(TAG_W'(13)), "src2 = data value");
    chk(agu_req.op === AGU_SD,                "op copied");
    chk(agu_req.imm === -64'sd8,              "negative imm copied");
    chk(agu_req.wr_en === 1'b0,               "a store writes no register");

    // M4: four waiting entries fill the RS; three come in one bundle.
    cur = "M4 RS full";
    do_reset();
    wr = 3'b111;
    wr_entry[0] = parked(TAG_W'(20));
    wr_entry[1] = parked(TAG_W'(21));
    wr_entry[2] = parked(TAG_W'(22));
    tick();
    chk(free === CNT_W'(1), "three in use");
    wr = 3'b001;
    wr_entry[0] = parked(TAG_W'(23));
    tick();
    idle();
    chk(free === CNT_W'(0),     "RS full: free = 0");
    chk(agu_req_valid === 1'b0, "nothing ready, nothing issued");

    // M5: the base wakes on the edge after its broadcast; the load issues in
    // the next cycle, never in the broadcast cycle itself.
    cur = "M5 wakeup timing";
    do_reset();
    wr[0]       = 1'b1;
    wr_entry[0] = ld(TAG_W'(41), TAG_W'(60), 1'b0);
    tick();
    idle();
    chk(agu_req_valid === 1'b0, "base still waiting for tag 60");
    wb_valid[2] = 1'b1;
    wb_tag[2]   = TAG_W'(60);
    settle();
    chk(agu_req_valid === 1'b0, "not issued in the broadcast cycle");
    tick();
    idle();
    chk(agu_req_valid === 1'b1,               "woken: issues the cycle after");
    chk(agu_req.src1 === data_of(TAG_W'(60)), "src1 = value of tag 60");
    tick();
    chk(agu_req_valid === 1'b0, "issued once");

    // M6: a store with its base ready waits for the data; it issues only
    // after the data tag is broadcast.
    cur = "M6 store waits for its data";
    do_reset();
    wr[0]       = 1'b1;
    wr_entry[0] = st(TAG_W'(14), 1'b1, TAG_W'(61), 1'b0);
    tick();
    idle();
    chk(agu_req_valid === 1'b0, "data not ready: the store does not issue");
    tick();
    chk(agu_req_valid === 1'b0, "still waiting");
    wb_valid[0] = 1'b1;
    wb_tag[0]   = TAG_W'(61);
    tick();
    idle();
    chk(agu_req_valid === 1'b1,               "data woke: the store issues");
    chk(agu_req.src2 === data_of(TAG_W'(61)), "src2 = value of tag 61");

    // M7: the base tag is broadcast in the very cycle the load is written.
    cur = "M7 write + broadcast";
    do_reset();
    wr[2]       = 1'b1;
    wr_entry[2] = ld(TAG_W'(44), TAG_W'(51), 1'b0);
    wb_valid[1] = 1'b1;
    wb_tag[1]   = TAG_W'(51);
    tick();
    idle();
    chk(agu_req_valid === 1'b1,         "woke while being written");
    chk(agu_req.dst_tag === TAG_W'(44), "the right entry issues");

    // M8: three ready entries leave in index order, one per cycle.
    cur = "M8 lowest index first";
    do_reset();
    wr = 3'b111;
    wr_entry[0] = ld(TAG_W'(45), TAG_W'(11), 1'b1);
    wr_entry[1] = st(TAG_W'(12), 1'b1, TAG_W'(13), 1'b1);
    wr_entry[2] = ld(TAG_W'(46), TAG_W'(11), 1'b1);
    tick();
    idle();
    chk(agu_req_valid === 1'b1 && agu_req.dst_tag === TAG_W'(45), "entry 0 first");
    tick();
    chk(agu_req_valid === 1'b1 && agu_req.op === AGU_SD,          "entry 1 next");
    tick();
    chk(agu_req_valid === 1'b1 && agu_req.dst_tag === TAG_W'(46), "entry 2 last");
    tick();
    chk(agu_req_valid === 1'b0, "each issued once");

    // M9: the AGU is busy; the ready entry keeps requesting, unchanged, and
    // issues exactly once when the AGU frees.
    cur = "M9 back-pressure";
    do_reset();
    wr[0]       = 1'b1;
    wr_entry[0] = ld(TAG_W'(47), TAG_W'(11), 1'b1);
    tick();
    idle();
    agu_req_ready = 1'b0;
    chk(agu_req_valid === 1'b1 && agu_req.dst_tag === TAG_W'(47), "requesting");
    tick();
    chk(agu_req_valid === 1'b1 && agu_req.dst_tag === TAG_W'(47), "held, same request");
    chk(free === CNT_W'(3), "entry still in use while held");
    agu_req_ready = 1'b1;
    tick();
    chk(agu_req_valid === 1'b0, "issued exactly once");
    chk(free === CNT_W'(4),     "entry freed after the transfer");

    // M10: with the RS full, an issue frees an entry, but free still shows 0
    // in that cycle and 1 in the next.
    cur = "M10 free counts the start of the cycle";
    do_reset();
    agu_req_ready = 1'b0;
    wr = 3'b111;
    wr_entry[0] = ld(TAG_W'(48), TAG_W'(11), 1'b1);
    wr_entry[1] = parked(TAG_W'(30));
    wr_entry[2] = parked(TAG_W'(31));
    tick();
    wr = 3'b001;
    wr_entry[0] = parked(TAG_W'(32));
    tick();
    idle();
    agu_req_ready = 1'b0;
    chk(free === CNT_W'(0),     "RS full");
    chk(agu_req_valid === 1'b1, "the ready load waits for the AGU");
    agu_req_ready = 1'b1;
    settle();
    chk(free === CNT_W'(0),     "issuing now does not raise free in this cycle");
    tick();
    chk(free === CNT_W'(1),     "the freed entry shows up in the next cycle");

    // M11: holes at entries 0 and 2, entry 1 waiting; slots 1 and 2 write.
    // Slot 1 must land in entry 0 and slot 2 in entry 2, never over entry 1.
    cur = "M11 k-th free entry";
    do_reset();
    wr = 3'b111;
    wr_entry[0] = ld(TAG_W'(50), TAG_W'(11), 1'b1);
    wr_entry[1] = ld(TAG_W'(51), TAG_W'(62), 1'b0);
    wr_entry[2] = ld(TAG_W'(52), TAG_W'(11), 1'b1);
    tick();
    idle();
    chk(agu_req.dst_tag === TAG_W'(50), "entry 0 issues");
    tick();
    chk(agu_req.dst_tag === TAG_W'(52), "entry 2 issues; entry 1 waits");
    tick();
    chk(free === CNT_W'(3),     "only entry 1 in use");
    chk(agu_req_valid === 1'b0, "entry 1 still waiting for tag 62");
    wr = 3'b110;
    wr_entry[1] = ld(TAG_W'(53), TAG_W'(11), 1'b1);
    wr_entry[2] = ld(TAG_W'(54), TAG_W'(11), 1'b1);
    tick();
    idle();
    chk(free === CNT_W'(1), "three in use: nothing was overwritten");
    chk(agu_req.dst_tag === TAG_W'(53), "slot 1 landed in entry 0");
    tick();
    chk(agu_req.dst_tag === TAG_W'(54), "slot 2 landed in entry 2");
    wb_valid[0] = 1'b1;
    wb_tag[0]   = TAG_W'(62);
    tick();
    idle();
    chk(agu_req_valid === 1'b1 && agu_req.dst_tag === TAG_W'(51),
        "the instruction in entry 1 survived and issues");

    // M12: flush empties the RS, drops a write of the same cycle and issues
    // nothing in the flush cycle.
    cur = "M12 flush";
    do_reset();
    agu_req_ready = 1'b0;
    wr = 3'b011;
    wr_entry[0] = ld(TAG_W'(55), TAG_W'(11), 1'b1);
    wr_entry[1] = parked(TAG_W'(56));
    tick();
    idle();
    agu_req_ready = 1'b0;
    chk(agu_req_valid === 1'b1, "a ready load is held by the AGU");
    flush       = 1'b1;
    wr[0]       = 1'b1;
    wr_entry[0] = ld(TAG_W'(57), TAG_W'(11), 1'b1);
    settle();
    chk(agu_req_valid === 1'b0, "no request during flush");
    tick();
    idle();
    chk(free === CNT_W'(4),     "flush empties the RS, including the same-cycle write");
    chk(agu_req_valid === 1'b0, "nothing left to issue");

    // M13: a broadcast in the flush cycle must not wake an entry written
    // later that waits for the same (reused) tag.
    cur = "M13 tag reuse after flush";
    do_reset();
    wr[0]       = 1'b1;
    wr_entry[0] = ld(TAG_W'(58), TAG_W'(59), 1'b0);
    tick();
    idle();
    flush       = 1'b1;
    wb_valid[0] = 1'b1;
    wb_tag[0]   = TAG_W'(59);
    tick();
    idle();
    wr[0]       = 1'b1;
    wr_entry[0] = ld(TAG_W'(42), TAG_W'(59), 1'b0);
    tick();
    idle();
    chk(agu_req_valid === 1'b0, "not woken by the old broadcast");
    tick();
    chk(agu_req_valid === 1'b0, "still waiting");
    wb_valid[0] = 1'b1;
    wb_tag[0]   = TAG_W'(59);
    tick();
    idle();
    chk(agu_req_valid === 1'b1 && agu_req.dst_tag === TAG_W'(42),
        "woken by the new broadcast");

    $display("PASS rs_mem_tb (%0d checks)", checks);
    $finish;
  end

endmodule
/* verilator lint_on UNUSEDSIGNAL */
