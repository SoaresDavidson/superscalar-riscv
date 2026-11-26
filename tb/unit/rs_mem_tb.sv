// Unit testbench for rs_mem. Spec: docs/rs/RS.md.
//
// Same scheme as rs_int_tb: drive inputs, check the outputs of the current
// cycle, tick() to cross an edge. Inputs change 1 time unit after the edge;
// inputs changed in the middle of a cycle are followed by settle() before
// any check.
//
// The testbench plays four neighbours:
//   Dispatch  : drives wr / wr_entry (built with ld() and st()).
//   AGU load  : drives agu_ld_req_ready (1 unless a case says so).
//   AGU store : drives agu_st_req_ready (1 unless a case says so).
//   PRF       : read_data = data_of(read_tag), always valid.
//
// Two selectors (wiki decision 17): loads leave on the agu_ld_* port, stores
// on the agu_st_* port, each the OLDEST ready entry of its kind by age.
// Loads read only src1 (base); stores read src1 (base) and src2 (data).
//
// ld() and st() give each entry the next age, so the order in which a case
// builds entries is program order.
//
// Cases:
//   M1  reset                     M9  back-pressure on one port only
//   M2  load: write, issue, free  M10 free counts the start of the cycle
//   M3  store fields              M11 k-th instruction -> k-th free entry
//   M4  RS full (4 entries)       M12 flush with both ports busy
//   M5  wakeup timing             M13 tag reuse after flush
//   M6  store waits for its data  M14 older entry at a higher index first
//   M7  write + broadcast         M15 oldest first across the age wrap
//   M8  load and store together
//
// Side fields (lsq_idx, color): ld() and st() derive them from the entry's
// own tags, so a monitor checks on every valid request that the side fields
// come from the same entry as the request.

// The testbench checks only some fields of the requests.
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

  logic                       agu_ld_req_valid, agu_ld_req_ready;
  fu_req_t                    agu_ld_req;
  lsq_idx_t                   agu_ld_req_lsq_idx;
  sb_ptr_t                    agu_ld_req_color;
  logic [TAG_W-1:0]           agu_ld_read_tag;
  logic                       agu_ld_read_valid;
  logic [XLEN-1:0]            agu_ld_read_data;

  logic                       agu_st_req_valid, agu_st_req_ready;
  fu_req_t                    agu_st_req;
  lsq_idx_t                   agu_st_req_lsq_idx;
  logic [1:0][TAG_W-1:0]      agu_st_read_tag;
  logic [1:0]                 agu_st_read_valid;
  logic [1:0][XLEN-1:0]       agu_st_read_data;

  initial forever #5 clk = ~clk;

  rs_mem #(.W(W), .ENTRIES(ENTRIES), .WB_N(WB_N)) dut (.*);

  // ---------------------------------------------------------------------------
  // PRF model: every tag reads a distinct, recognisable value.
  // ---------------------------------------------------------------------------
  function automatic xlen_t data_of(tag_t t);
    return 64'h2000_0000 + XLEN'(t);
  endfunction

  assign agu_ld_read_valid   = 1'b1;
  assign agu_ld_read_data    = data_of(agu_ld_read_tag);
  assign agu_st_read_valid   = 2'b11;
  assign agu_st_read_data[0] = data_of(agu_st_read_tag[0]);
  assign agu_st_read_data[1] = data_of(agu_st_read_tag[1]);

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
  // Entries, as Dispatch builds them. Each call takes the next age.
  // ---------------------------------------------------------------------------
  age_t nage = '0;

  // Side fields, derived from the entry's tags (see the header).
  function automatic lsq_idx_t ld_idx(tag_t dst);   return lsq_idx_t'(dst ^ 6'h15); endfunction
  function automatic sb_ptr_t  ld_color(tag_t dst); return sb_ptr_t'(dst + 6'd3);   endfunction
  function automatic lsq_idx_t st_idx(tag_t data);  return lsq_idx_t'(data ^ 6'h0A); endfunction

  // Monitor: the side fields follow the entry each request comes from, and
  // each port carries only its own kind.
  always @(negedge clk) begin
    if (!reset && agu_ld_req_valid) begin
      checks++;
      if (agu_ld_req.op != AGU_LD)
        $fatal(1, "[%s] load port carries op %0d", cur, agu_ld_req.op);
      if (agu_ld_req_lsq_idx !== ld_idx(agu_ld_req.dst_tag) ||
          agu_ld_req_color   !== ld_color(agu_ld_req.dst_tag))
        $fatal(1, "[%s] load dst %0d: lsq_idx %0d color %0d from another entry",
               cur, agu_ld_req.dst_tag, agu_ld_req_lsq_idx, agu_ld_req_color);
    end
    if (!reset && agu_st_req_valid) begin
      checks++;
      if (agu_st_req.op != AGU_SD)
        $fatal(1, "[%s] store port carries op %0d", cur, agu_st_req.op);
      if (agu_st_req_lsq_idx !== st_idx(agu_st_read_tag[1]))
        $fatal(1, "[%s] store data tag %0d: lsq_idx %0d from another entry",
               cur, agu_st_read_tag[1], agu_st_req_lsq_idx);
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
    e.age        = nage;
    e.lsq_idx    = ld_idx(dst);
    e.color      = ld_color(dst);
    nage         = nage + 8'd1;
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
    e.age        = nage;
    e.lsq_idx    = st_idx(data);
    e.color      = '0;
    nage         = nage + 8'd1;
    return e;
  endfunction

  // A load that never wakes during a case (tag 63 is never broadcast).
  function automatic rs_mem_entry_t parked(tag_t dst);
    return ld(dst, TAG_W'(63), 1'b0);
  endfunction

  task automatic idle();
    flush            = 1'b0;
    wr               = '0;
    wr_entry         = '0;
    wb_valid         = '0;
    wb_tag           = '0;
    agu_ld_req_ready = 1'b1;
    agu_st_req_ready = 1'b1;
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
    chk(free === CNT_W'(4),        "empty RS: free = 4");
    chk(agu_ld_req_valid === 1'b0, "no load request");
    chk(agu_st_req_valid === 1'b0, "no store request");

    // M2: a load with its base ready issues the cycle after it is written,
    // on the load port only.
    cur = "M2 load: write, issue, free";
    do_reset();
    wr[0]       = 1'b1;
    wr_entry[0] = ld(TAG_W'(40), TAG_W'(11), 1'b1);
    settle();
    chk(free === CNT_W'(4),        "free counts the start of the cycle");
    chk(agu_ld_req_valid === 1'b0, "an entry being written cannot issue yet");
    tick();
    idle();
    chk(free === CNT_W'(3),                      "one entry in use");
    chk(agu_ld_req_valid === 1'b1,               "ready load requests the load AGU");
    chk(agu_st_req_valid === 1'b0,               "the store port stays idle");
    chk(agu_ld_read_tag === TAG_W'(11),          "load read port gets the base tag");
    chk(agu_ld_req.src1 === data_of(TAG_W'(11)), "src1 = base value");
    chk(agu_ld_req.src2 === '0,                  "src2 = 0 (a load has no data)");
    chk(agu_ld_req.op === AGU_LD,                "op copied");
    chk(agu_ld_req.imm === 64'd16,               "imm copied");
    chk(agu_ld_req.dst_tag === TAG_W'(40),       "dst_tag copied");
    chk(agu_ld_req.wr_en === 1'b1,               "a load writes its destination");
    chk(agu_ld_req.use_imm === 1'b0,             "use_imm = 0 (not in the entry)");
    chk(agu_ld_req.pc === '0,                    "pc = 0 (not in the entry)");
    chk(agu_ld_req.pred_taken === 1'b0,          "pred_taken = 0 (not in the entry)");
    tick();
    chk(agu_ld_req_valid === 1'b0, "issued once, entry freed");
    chk(free === CNT_W'(4),        "entry back to free");

    // M3: a store carries base and data to the store AGU and writes nothing.
    cur = "M3 store fields";
    do_reset();
    wr[1]       = 1'b1;
    wr_entry[1] = st(TAG_W'(12), 1'b1, TAG_W'(13), 1'b1);
    tick();
    idle();
    chk(agu_st_req_valid === 1'b1,               "ready store requests the store AGU");
    chk(agu_ld_req_valid === 1'b0,               "the load port stays idle");
    chk(agu_st_read_tag[0] === TAG_W'(12),       "store read port 0 gets the base tag");
    chk(agu_st_read_tag[1] === TAG_W'(13),       "store read port 1 gets the data tag");
    chk(agu_st_req.src1 === data_of(TAG_W'(12)), "src1 = base value");
    chk(agu_st_req.src2 === data_of(TAG_W'(13)), "src2 = data value");
    chk(agu_st_req.op === AGU_SD,                "op copied");
    chk(agu_st_req.imm === -64'sd8,              "negative imm copied");
    chk(agu_st_req.wr_en === 1'b0,               "a store writes no register");
    tick();
    chk(agu_st_req_valid === 1'b0, "issued once");
    chk(free === CNT_W'(4),        "entry back to free");

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
    chk(free === CNT_W'(0),        "RS full: free = 0");
    chk(agu_ld_req_valid === 1'b0, "nothing ready, nothing issued");
    chk(agu_st_req_valid === 1'b0, "nothing ready, nothing issued");

    // M5: the base wakes on the edge after its broadcast; the load issues in
    // the next cycle, never in the broadcast cycle itself.
    cur = "M5 wakeup timing";
    do_reset();
    wr[0]       = 1'b1;
    wr_entry[0] = ld(TAG_W'(41), TAG_W'(60), 1'b0);
    tick();
    idle();
    chk(agu_ld_req_valid === 1'b0, "base still waiting for tag 60");
    wb_valid[2] = 1'b1;
    wb_tag[2]   = TAG_W'(60);
    settle();
    chk(agu_ld_req_valid === 1'b0, "not issued in the broadcast cycle");
    tick();
    idle();
    chk(agu_ld_req_valid === 1'b1,               "woken: issues the cycle after");
    chk(agu_ld_req.src1 === data_of(TAG_W'(60)), "src1 = value of tag 60");
    tick();
    chk(agu_ld_req_valid === 1'b0, "issued once");

    // M6: a store with its base ready waits for the data; it issues only
    // after the data tag is broadcast.
    cur = "M6 store waits for its data";
    do_reset();
    wr[0]       = 1'b1;
    wr_entry[0] = st(TAG_W'(14), 1'b1, TAG_W'(61), 1'b0);
    tick();
    idle();
    chk(agu_st_req_valid === 1'b0, "data not ready: the store does not issue");
    tick();
    chk(agu_st_req_valid === 1'b0, "still waiting");
    wb_valid[0] = 1'b1;
    wb_tag[0]   = TAG_W'(61);
    tick();
    idle();
    chk(agu_st_req_valid === 1'b1,               "data woke: the store issues");
    chk(agu_st_req.src2 === data_of(TAG_W'(61)), "src2 = value of tag 61");

    // M7: the base tag is broadcast in the very cycle the load is written.
    cur = "M7 write + broadcast";
    do_reset();
    wr[2]       = 1'b1;
    wr_entry[2] = ld(TAG_W'(44), TAG_W'(51), 1'b0);
    wb_valid[1] = 1'b1;
    wb_tag[1]   = TAG_W'(51);
    tick();
    idle();
    chk(agu_ld_req_valid === 1'b1,         "woke while being written");
    chk(agu_ld_req.dst_tag === TAG_W'(44), "the right entry issues");

    // M8: two ready loads and a ready store. The store and the older load
    // leave in the same cycle, one per port; the younger load follows.
    cur = "M8 load and store together";
    do_reset();
    wr = 3'b111;
    wr_entry[0] = ld(TAG_W'(45), TAG_W'(11), 1'b1);
    wr_entry[1] = st(TAG_W'(12), 1'b1, TAG_W'(13), 1'b1);
    wr_entry[2] = ld(TAG_W'(46), TAG_W'(11), 1'b1);
    tick();
    idle();
    chk(agu_ld_req_valid === 1'b1 && agu_ld_req.dst_tag === TAG_W'(45), "older load first");
    chk(agu_st_req_valid === 1'b1 && agu_st_req.op === AGU_SD,          "store in the same cycle");
    tick();
    chk(free === CNT_W'(3), "two entries left in one cycle");
    chk(agu_ld_req_valid === 1'b1 && agu_ld_req.dst_tag === TAG_W'(46), "younger load next");
    chk(agu_st_req_valid === 1'b0, "the store issued once");
    tick();
    chk(agu_ld_req_valid === 1'b0, "each issued once");
    chk(free === CNT_W'(4),        "all free");

    // M9: one AGU is busy; its entry keeps requesting, unchanged, while the
    // other port goes on issuing. Then the other way round.
    cur = "M9 back-pressure on one port";
    do_reset();
    wr = 3'b111;
    wr_entry[0] = ld(TAG_W'(47), TAG_W'(11), 1'b1);
    wr_entry[1] = st(TAG_W'(15), 1'b1, TAG_W'(16), 1'b1);
    wr_entry[2] = st(TAG_W'(15), 1'b1, TAG_W'(17), 1'b1);
    tick();
    idle();
    agu_ld_req_ready = 1'b0;
    chk(agu_ld_req_valid === 1'b1 && agu_ld_req.dst_tag === TAG_W'(47), "load requesting");
    chk(agu_st_req_valid === 1'b1 && agu_st_read_tag[1] === TAG_W'(16), "older store issues");
    tick();
    chk(agu_ld_req_valid === 1'b1 && agu_ld_req.dst_tag === TAG_W'(47), "load held, same request");
    chk(agu_st_req_valid === 1'b1 && agu_st_read_tag[1] === TAG_W'(17), "younger store issues");
    tick();
    chk(agu_ld_req_valid === 1'b1 && agu_ld_req.dst_tag === TAG_W'(47), "load still held");
    chk(agu_st_req_valid === 1'b0, "both stores gone");
    chk(free === CNT_W'(3),        "only the held load in use");
    agu_ld_req_ready = 1'b1;
    tick();
    chk(agu_ld_req_valid === 1'b0, "load issued exactly once");
    chk(free === CNT_W'(4),        "entry freed after the transfer");

    wr = 3'b011;
    wr_entry[0] = st(TAG_W'(18), 1'b1, TAG_W'(19), 1'b1);
    wr_entry[1] = ld(TAG_W'(39), TAG_W'(11), 1'b1);
    tick();
    idle();
    agu_st_req_ready = 1'b0;
    chk(agu_st_req_valid === 1'b1, "store requesting");
    chk(agu_ld_req_valid === 1'b1 && agu_ld_req.dst_tag === TAG_W'(39), "load issues");
    tick();
    chk(agu_st_req_valid === 1'b1 && agu_st_read_tag[1] === TAG_W'(19), "store held, same request");
    chk(agu_ld_req_valid === 1'b0, "load gone, not blocked by the store");
    agu_st_req_ready = 1'b1;
    tick();
    chk(agu_st_req_valid === 1'b0, "store issued exactly once");

    // M10: with the RS full, an issue frees an entry, but free still shows 0
    // in that cycle and 1 in the next.
    cur = "M10 free counts the start of the cycle";
    do_reset();
    agu_ld_req_ready = 1'b0;
    wr = 3'b111;
    wr_entry[0] = ld(TAG_W'(48), TAG_W'(11), 1'b1);
    wr_entry[1] = parked(TAG_W'(30));
    wr_entry[2] = parked(TAG_W'(31));
    tick();
    wr = 3'b001;
    wr_entry[0] = parked(TAG_W'(32));
    tick();
    idle();
    agu_ld_req_ready = 1'b0;
    chk(free === CNT_W'(0),        "RS full");
    chk(agu_ld_req_valid === 1'b1, "the ready load waits for the AGU");
    agu_ld_req_ready = 1'b1;
    settle();
    chk(free === CNT_W'(0),        "issuing now does not raise free in this cycle");
    tick();
    chk(free === CNT_W'(1),        "the freed entry shows up in the next cycle");

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
    chk(agu_ld_req.dst_tag === TAG_W'(50), "entry 0 issues");
    tick();
    chk(agu_ld_req.dst_tag === TAG_W'(52), "entry 2 issues; entry 1 waits");
    tick();
    chk(free === CNT_W'(3),        "only entry 1 in use");
    chk(agu_ld_req_valid === 1'b0, "entry 1 still waiting for tag 62");
    wr = 3'b110;
    wr_entry[1] = ld(TAG_W'(53), TAG_W'(11), 1'b1);
    wr_entry[2] = ld(TAG_W'(54), TAG_W'(11), 1'b1);
    tick();
    idle();
    chk(free === CNT_W'(1), "three in use: nothing was overwritten");
    chk(agu_ld_req.dst_tag === TAG_W'(53), "slot 1 landed in entry 0 (older first)");
    tick();
    chk(agu_ld_req.dst_tag === TAG_W'(54), "slot 2 landed in entry 2");
    wb_valid[0] = 1'b1;
    wb_tag[0]   = TAG_W'(62);
    tick();
    idle();
    chk(agu_ld_req_valid === 1'b1 && agu_ld_req.dst_tag === TAG_W'(51),
        "the instruction in entry 1 survived and issues");

    // M12: flush with both ports holding a request empties the RS, drops a
    // write of the same cycle and issues nothing in the flush cycle.
    cur = "M12 flush";
    do_reset();
    agu_ld_req_ready = 1'b0;
    agu_st_req_ready = 1'b0;
    wr = 3'b111;
    wr_entry[0] = ld(TAG_W'(55), TAG_W'(11), 1'b1);
    wr_entry[1] = st(TAG_W'(12), 1'b1, TAG_W'(20), 1'b1);
    wr_entry[2] = parked(TAG_W'(56));
    tick();
    idle();
    agu_ld_req_ready = 1'b0;
    agu_st_req_ready = 1'b0;
    chk(agu_ld_req_valid === 1'b1, "a ready load is held by its AGU");
    chk(agu_st_req_valid === 1'b1, "a ready store is held by its AGU");
    flush       = 1'b1;
    wr[0]       = 1'b1;
    wr_entry[0] = ld(TAG_W'(57), TAG_W'(11), 1'b1);
    settle();
    chk(agu_ld_req_valid === 1'b0, "no load request during flush");
    chk(agu_st_req_valid === 1'b0, "no store request during flush");
    tick();
    idle();
    chk(free === CNT_W'(4),        "flush empties the RS, including the same-cycle write");
    chk(agu_ld_req_valid === 1'b0, "nothing left to issue");
    chk(agu_st_req_valid === 1'b0, "nothing left to issue");

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
    chk(agu_ld_req_valid === 1'b0, "not woken by the old broadcast");
    tick();
    chk(agu_ld_req_valid === 1'b0, "still waiting");
    wb_valid[0] = 1'b1;
    wb_tag[0]   = TAG_W'(59);
    tick();
    idle();
    chk(agu_ld_req_valid === 1'b1 && agu_ld_req.dst_tag === TAG_W'(42),
        "woken by the new broadcast");

    // M14: an older load sits at a higher index than a younger one. P (ready)
    // takes entry 0 and O (waiting) entry 1; P leaves, and the younger N takes
    // entry 0 in the cycle O wakes. With both ready, O leaves first.
    cur = "M14 older at a higher index";
    do_reset();
    wr = 3'b011;
    wr_entry[0] = ld(TAG_W'(24), TAG_W'(11), 1'b1);   // P, entry 0
    wr_entry[1] = ld(TAG_W'(25), TAG_W'(62), 1'b0);   // O, entry 1, waits
    tick();
    idle();
    chk(agu_ld_req.dst_tag === TAG_W'(24), "P issues");
    tick();
    wr[0]       = 1'b1;
    wr_entry[0] = ld(TAG_W'(26), TAG_W'(11), 1'b1);   // N, younger, entry 0
    wb_valid[2] = 1'b1;
    wb_tag[2]   = TAG_W'(62);                         // O wakes
    tick();
    idle();
    chk(agu_ld_req_valid === 1'b1 && agu_ld_req.dst_tag === TAG_W'(25),
        "the older O leaves before N, despite the higher index");
    tick();
    chk(agu_ld_req_valid === 1'b1 && agu_ld_req.dst_tag === TAG_W'(26), "N next");
    tick();
    chk(agu_ld_req_valid === 1'b0, "each issued once");

    // M15: across the age wrap. A (age 254) waits in entry 1; B (age 0, after
    // the wrap) is ready in entry 0. Once A wakes, A is older and leaves first.
    cur = "M15 oldest first across the age wrap";
    do_reset();
    nage = 8'd253;
    wr = 3'b011;
    wr_entry[0] = ld(TAG_W'(27), TAG_W'(11), 1'b1);   // age 253, entry 0
    wr_entry[1] = ld(TAG_W'(28), TAG_W'(62), 1'b0);   // A: age 254, entry 1
    tick();
    idle();
    chk(agu_ld_req.dst_tag === TAG_W'(27), "age 253 issues");
    tick();
    nage        = 8'd0;
    wr[0]       = 1'b1;
    wr_entry[0] = ld(TAG_W'(29), TAG_W'(11), 1'b1);   // B: age 0, entry 0
    wb_valid[2] = 1'b1;
    wb_tag[2]   = TAG_W'(62);
    tick();
    idle();
    chk(agu_ld_req_valid === 1'b1 && agu_ld_req.dst_tag === TAG_W'(28),
        "age 254 is older than age 0 after the wrap");
    tick();
    chk(agu_ld_req_valid === 1'b1 && agu_ld_req.dst_tag === TAG_W'(29), "age 0 next");

    $display("PASS rs_mem_tb (%0d checks)", checks);
    $finish;
  end

endmodule
/* verilator lint_on UNUSEDSIGNAL */
