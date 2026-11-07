// Integration testbench: decode -> PRFRename.
//
// What it is for. The unit testbenches check each block against its own
// contract; this one checks that the two contracts MEET. The specific failure
// it exists to catch is the WAW chain inside a bundle: PRFRename derives
// old_tag from the rd_dep mask, and until the Decode produced that mask, two
// writers of the same register in one bundle both reported the pre-bundle tag
// as old_tag. The ROB would then hand the same commit_old_tag back twice --
// that tag enters the free list twice while the intermediate one leaks -- and
// nothing would show until the free list ran dry. No unit test can see it,
// because each block is self-consistent.
//
// How it is checked. A reference map mirrors the rename's speculative
// mapping: arch reg -> tag. For every slot that allocates, in slot order,
//
//     old_tag[k] must equal ref_map[rd[k]]  (and only then ref_map is updated)
//
// With a correct rd_dep the second writer of x5 sees ref_map[x5] already
// pointing at the first writer's dst_tag. With rd_dep missing or wrong it
// would still be the pre-bundle tag, and this fires immediately. A second,
// independent model tracks every physical tag as FREE / ALLOC / AR, so a tag
// allocated twice or freed twice is caught even if the map happened to agree.
//
// The glue between the two blocks (uop_t fields -> rename ports) is what the
// Dispatch will do for real; here it is explicit, in g_glue below.
//
// WIDTH is fixed at 3. Sweeping it is the unit tests' job (decode_tb runs
// 1..4, PRFRename_tb is W = 1, PRFRenameBundle_tb is W = 3); what needs three
// slots is the meaning of "closest earlier writer", which is the whole point
// here.

module decode_rename_tb;

  import execute_pkg::*;

  localparam int WIDTH   = 3;
  localparam int ENTRIES = 64;
  // 3 FUs were decided: ALU, Branch Unit, AGU. The write-back ports are ALU,
  // Branch (the jalr link) and the load return from Memory -- the AGU does not
  // write the PRF, its result is an address.
  localparam int WB_N    = 3;
  localparam int TAG_W   = $clog2(ENTRIES);

  localparam int ST_FREE  = 0;
  localparam int ST_ALLOC = 1;
  localparam int ST_AR    = 2;

  // --- wiring ---------------------------------------------------------------

  logic clk, reset, flush;

  // Fetch -> Decode
  logic                       in_valid, in_ready;
  logic [WIDTH-1:0]           in_slot_valid;
  logic [WIDTH-1:0][31:0]     in_inst;
  logic [WIDTH-1:0][XLEN-1:0] in_pc;

  // Decode -> (glue) -> Rename
  logic                        dec_valid, dec_ready;
  uop_t [WIDTH-1:0]            dec_uop;
  logic [WIDTH-1:0][WIDTH-1:0] dec_dep_rs1, dec_dep_rs2, dec_dep_rd;
  logic                        redirect_valid;
  logic [XLEN-1:0]             redirect_pc;
  logic [WIDTH-1:0]            slot_kill;

  decode #(.WIDTH(WIDTH)) u_decode (
    .clk, .reset, .flush,
    .in_valid, .in_ready, .in_slot_valid, .in_inst, .in_pc,
    .out_valid   (dec_valid),
    .out_ready   (dec_ready),
    .out_uop     (dec_uop),
    .out_dep_rs1 (dec_dep_rs1),
    .out_dep_rs2 (dec_dep_rs2),
    .out_dep_rd  (dec_dep_rd),
    .redirect_valid, .redirect_pc,
    .out_slot_kill (slot_kill)
  );

  logic [WIDTH-1:0]            rn_slot_valid, rn_writes_rd;
  logic [WIDTH-1:0][4:0]       rn_rs1, rn_rs2, rn_rd;
  logic                        rob_ready, rn_dispatch_ready;
  logic [WIDTH-1:0][1:0]       rn_src_ready;
  logic [WIDTH-1:0][XLEN-1:0]  rn_src1_data, rn_src2_data;
  logic [WIDTH-1:0][TAG_W-1:0] rn_src1_tag, rn_src2_tag, rn_dst_tag, rn_old_tag;

  logic [WB_N-1:0]             wb_valid;
  logic [WB_N-1:0][TAG_W-1:0]  wb_tag;
  logic [WB_N-1:0][XLEN-1:0]   wb_data;

  logic [WIDTH-1:0]            cm_valid;
  logic [WIDTH-1:0][4:0]       cm_rd;
  logic [WIDTH-1:0][TAG_W-1:0] cm_tag, cm_old;

  // The glue the Dispatch will own: uop_t fields out, rename ports in. The
  // dependency masks pass straight through -- that is the point of the
  // one-hot format, there is nothing to convert.
  for (genvar k = 0; k < WIDTH; k++) begin : g_glue
    uop_t u;
    assign u = dec_uop[k];
    assign rn_slot_valid[k] = u.valid;
    assign rn_rs1[k]        = u.rs1;
    assign rn_rs2[k]        = u.rs2;
    assign rn_rd[k]         = u.rd;
    assign rn_writes_rd[k]  = u.has_dest;
  end

  // Decode's bundle leaves when the rename takes it: all or nothing
  // (decision 15). rob_ready is the mock ROB below.
  assign dec_ready = rn_dispatch_ready && rob_ready;

  PRFRename #(
    .XLEN(XLEN), .ENTRIES(ENTRIES), .W(WIDTH), .WB_N(WB_N)
  ) u_rename (
    .clk, .reset, .flush,
    .dispatch_valid (dec_valid),
    .slot_valid     (rn_slot_valid),
    .rs1            (rn_rs1),
    .rs2            (rn_rs2),
    .rd             (rn_rd),
    .writes_rd      (rn_writes_rd),
    .rs1_dep        (dec_dep_rs1),
    .rs2_dep        (dec_dep_rs2),
    .rd_dep         (dec_dep_rd),
    .rob_ready      (rob_ready),
    .dispatch_ready (rn_dispatch_ready),
    .src_ready      (rn_src_ready),
    .src1_data      (rn_src1_data),
    .src2_data      (rn_src2_data),
    .src1_tag       (rn_src1_tag),
    .src2_tag       (rn_src2_tag),
    .dst_tag        (rn_dst_tag),
    .old_tag        (rn_old_tag),
    .wb_valid, .wb_tag, .wb_data,
    .commit_valid   (cm_valid),
    .commit_rd      (cm_rd),
    .commit_tag     (cm_tag),
    .commit_old_tag (cm_old)
  );

  // --- unpacked mirrors -----------------------------------------------------
  // Procedural code indexes THESE with a variable, never the packed ports: it
  // keeps every variable index away from a packed multi-dimensional vector
  // (AGENTS.md, Icarus limits).
  logic [TAG_W-1:0] m_dst   [WIDTH];
  logic [TAG_W-1:0] m_old   [WIDTH];
  logic [TAG_W-1:0] m_stag1 [WIDTH];
  logic [TAG_W-1:0] m_stag2 [WIDTH];
  logic [XLEN-1:0]  m_sdat1 [WIDTH];
  logic             m_srdy1 [WIDTH];
  logic             m_srdy2 [WIDTH];
  logic [4:0]       m_rd    [WIDTH];
  logic [4:0]       m_rs1   [WIDTH];
  logic             m_alloc [WIDTH];
  logic             m_live  [WIDTH];
  logic [WIDTH-1:0] m_dep1  [WIDTH];
  logic [WIDTH-1:0] m_depd  [WIDTH];

  for (genvar k = 0; k < WIDTH; k++) begin : g_mirror
    assign m_dst[k]   = rn_dst_tag[k];
    assign m_old[k]   = rn_old_tag[k];
    assign m_stag1[k] = rn_src1_tag[k];
    assign m_stag2[k] = rn_src2_tag[k];
    assign m_sdat1[k] = rn_src1_data[k];
    assign m_srdy1[k] = rn_src_ready[k][0];
    assign m_srdy2[k] = rn_src_ready[k][1];
    assign m_rd[k]    = rn_rd[k];
    assign m_rs1[k]   = rn_rs1[k];
    assign m_live[k]  = rn_slot_valid[k];
    // the rename's own allocation condition, recomputed here
    assign m_alloc[k] = rn_slot_valid[k] && rn_writes_rd[k] && (rn_rd[k] != 5'd0);
    assign m_dep1[k]  = dec_dep_rs1[k];
    assign m_depd[k]  = dec_dep_rd[k];
  end

  // --- reference model ------------------------------------------------------

  int ref_map  [32];        // speculative arch reg -> tag
  int ref_cmap [32];        // committed arch reg -> tag
  int tstate   [ENTRIES];   // ST_FREE / ST_ALLOC / ST_AR

  // mock ROB: one entry per instruction WITH a destination, in program order
  localparam int RQ = 512;
  int rq_rd  [RQ];
  int rq_tag [RQ];
  int rq_old [RQ];
  int rq_head, rq_tail;

  string cur;
  int    checks;
  int    errors;

  task automatic fail(string msg);
    $display("FAIL [%s] %s", cur, msg);
    errors++;
    $fatal(1, "case failed: %s", cur);
  endtask

  task automatic chk(logic cond, string msg);
    checks++;
    if (!cond) fail(msg);
  endtask

  task automatic model_reset();
    for (int i = 0; i < 32; i++) begin
      ref_map[i]  = i;
      ref_cmap[i] = i;
    end
    for (int t = 0; t < ENTRIES; t++) tstate[t] = (t < 32) ? ST_AR : ST_FREE;
    rq_head = 0;
    rq_tail = 0;
  endtask

  // --- clock and driving ----------------------------------------------------

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  initial begin
    #200000;
    $fatal(1, "TIMEOUT during case: %s", cur);
  end

  task automatic tick();
    @(posedge clk);
    @(negedge clk);
  endtask

  task automatic do_reset();
    @(negedge clk);
    reset         = 1'b1;
    flush         = 1'b0;
    in_valid      = 1'b0;
    in_slot_valid = '0;
    in_inst       = '0;
    in_pc         = '0;
    rob_ready     = 1'b1;
    wb_valid      = '0;
    wb_tag        = '0;
    wb_data       = '0;
    cm_valid      = '0;
    cm_rd         = '0;
    cm_tag        = '0;
    cm_old        = '0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    model_reset();
  endtask

  // --- encoders -------------------------------------------------------------

  localparam logic [6:0] OP_OPIMM = 7'b0010011;
  localparam logic [6:0] OP_OP    = 7'b0110011;
  localparam logic [6:0] OP_STORE = 7'b0100011;
  localparam logic [6:0] OP_BR    = 7'b1100011;

  function automatic logic [31:0] addi(logic [4:0] rd, logic [4:0] rs1,
                                       logic [11:0] imm);
    addi = {imm, rs1, 3'b000, rd, OP_OPIMM};
  endfunction

  function automatic logic [31:0] add_(logic [4:0] rd, logic [4:0] rs1,
                                       logic [4:0] rs2);
    add_ = {7'b0000000, rs2, rs1, 3'b000, rd, OP_OP};
  endfunction

  function automatic logic [31:0] sw_(logic [4:0] rs2, logic [4:0] rs1,
                                      logic [11:0] imm);
    sw_ = {imm[11:5], rs2, rs1, 3'b010, imm[4:0], OP_STORE};
  endfunction

  function automatic int oh_idx(logic [WIDTH-1:0] m);
    oh_idx = -1;                       // one-hot, so the single set bit wins
    for (int j = 0; j < WIDTH; j++) if (m[j]) oh_idx = j;
  endfunction

  logic [31:0] b_inst [WIDTH];

  task automatic set_nops();
    for (int i = 0; i < WIDTH; i++) b_inst[i] = addi(5'd0, 5'd0, 12'd0);
  endtask

  // Presents the bundle at the Decode input and returns once Decode has taken
  // it. Does not wait for the rename.
  task automatic feed(logic [WIDTH-1:0] sv);
    bit acc;
    @(negedge clk);
    in_inst = '0;
    in_pc   = '0;
    for (int i = 0; i < WIDTH; i++) begin
      in_inst[i] = b_inst[i];
      in_pc[i]   = 64'h1000 + 64'(4 * i);
    end
    in_slot_valid = sv;
    in_valid      = 1'b1;
    acc           = 1'b0;
    do begin
      @(posedge clk);
      acc = in_ready;
      @(negedge clk);
    end while (!acc);
    in_valid      = 1'b0;
    in_slot_valid = '0;
  endtask

  // Waits until the decoded bundle is on the rename's inputs AND the rename
  // will take it on the coming edge. Leaves the simulation between edges, so
  // the combinational dst_tag/old_tag may be sampled by the caller.
  task automatic await_dispatch();
    while (!(dec_valid && rn_dispatch_ready && rob_ready)) tick();
  endtask

  // The checks that matter, run on the cycle the bundle is being accepted,
  // followed by the model update after the edge.
  task automatic dispatch_and_check();
    int pre_map [32];
    int p, t, o, r;

    await_dispatch();

    for (int i = 0; i < 32; i++) pre_map[i] = ref_map[i];

    // --- sources: either chained to a producer in this bundle, or read from
    // the map as it stood BEFORE the bundle (the rename resolves sources
    // before allocating destinations).
    for (int k = 0; k < WIDTH; k++) begin
      if (m_live[k] && m_rs1[k] != 5'd0) begin
        p = oh_idx(m_dep1[k]);
        if (p >= 0) begin
          chk(m_stag1[k] === TAG_W'(m_dst[p]),
              $sformatf("slot %0d: src1_tag = %0d, expected the dst_tag of slot %0d (%0d)",
                        k, m_stag1[k], p, m_dst[p]));
          chk(m_srdy1[k] === 1'b0,
              $sformatf("slot %0d: src1 cannot be ready, its producer is in the same bundle", k));
        end else begin
          chk(m_stag1[k] === TAG_W'(pre_map[m_rs1[k]]),
              $sformatf("slot %0d: src1_tag = %0d, expected map[x%0d] = %0d",
                        k, m_stag1[k], m_rs1[k], pre_map[m_rs1[k]]));
        end
      end
    end

    // --- THE check: old_tag against the reference map, in slot order.
    for (int k = 0; k < WIDTH; k++) begin
      if (m_alloc[k]) begin
        r = int'(m_rd[k]);
        t = int'(m_dst[k]);
        o = int'(m_old[k]);

        chk(o === ref_map[r],
            $sformatf({"slot %0d writes x%0d: old_tag = %0d, expected %0d. ",
                       "A mismatch here is the WAW chain: rd_dep must point at ",
                       "the closest earlier writer in the bundle, or the ROB ",
                       "frees the same tag twice and leaks another."},
                      k, r, o, ref_map[r]));

        // the one-hot mask must agree with what the map says
        p = oh_idx(m_depd[k]);
        if (p >= 0)
          chk(o === int'(m_dst[p]),
              $sformatf("slot %0d: rd_dep points at slot %0d, so old_tag should be %0d, got %0d",
                        k, p, m_dst[p], o));

        chk(tstate[t] === ST_FREE,
            $sformatf("slot %0d: tag %0d allocated while in state %0d (double allocation)",
                      k, t, tstate[t]));
        chk(o !== t, $sformatf("slot %0d: old_tag equals dst_tag (%0d)", k, t));

        tstate[t]  = ST_ALLOC;
        ref_map[r] = t;

        rq_rd[rq_tail]  = r;
        rq_tag[rq_tail] = t;
        rq_old[rq_tail] = o;
        rq_tail         = rq_tail + 1;
      end else if (m_live[k] && m_rd[k] == 5'd0) begin
        // a writer of x0 allocates nothing (decision 5)
        chk(ref_map[0] === 0, "x0 must stay mapped to tag 0");
      end
    end

    tick();                            // the allocation lands on this edge
  endtask

  // Commits the n oldest ROB entries in one cycle, in program order.
  task automatic commit(int n);
    int t, o, r;
    chk(rq_tail - rq_head >= n, "mock ROB does not hold that many entries");
    @(negedge clk);
    cm_valid = '0;
    for (int j = 0; j < WIDTH; j++) begin
      if (j < n) begin
        cm_valid[j] = 1'b1;
        cm_rd[j]    = 5'(rq_rd[rq_head + j]);
        cm_tag[j]   = TAG_W'(rq_tag[rq_head + j]);
        cm_old[j]   = TAG_W'(rq_old[rq_head + j]);
      end
    end

    // Pre-edge checks. old_tag may be ALLOC rather than AR when an earlier
    // slot of this SAME cycle committed it -- a WAW chain retiring together.
    // What it must never be is FREE: that is the double free.
    for (int j = 0; j < n; j++) begin
      t = rq_tag[rq_head + j];
      o = rq_old[rq_head + j];
      chk(tstate[t] === ST_ALLOC,
          $sformatf("commit %0d: tag %0d is in state %0d, expected ALLOC", j, t, tstate[t]));
      chk(tstate[o] !== ST_FREE,
          $sformatf({"commit %0d: old_tag %0d is already FREE -- it is being ",
                     "returned to the free list a second time"}, j, o));
    end

    // Exactly ONE rising edge with commit_valid asserted. Using tick() here
    // and deasserting after it would hold the commit across two edges and
    // push every old_tag into the free list twice.
    @(posedge clk);
    @(negedge clk);
    cm_valid = '0;

    // Model update in slot order, letting the last write win, exactly as the
    // RTL's non-blocking assignments do.
    for (int j = 0; j < n; j++) begin
      r = rq_rd[rq_head + j];
      t = rq_tag[rq_head + j];
      o = rq_old[rq_head + j];
      tstate[t]   = ST_AR;
      tstate[o]   = ST_FREE;
      ref_cmap[r] = t;
    end
    rq_head = rq_head + n;
  endtask

  // Every tag accounted for: exactly 32 architectural, the rest free, and the
  // architectural ones are precisely the committed mapping. A leaked tag shows
  // up here as an ALLOC with nothing in flight.
  task automatic census();
    int n_ar, n_free, n_alloc;
    n_ar = 0; n_free = 0; n_alloc = 0;
    for (int t = 0; t < ENTRIES; t++) begin
      if (tstate[t] == ST_AR)    n_ar++;
      if (tstate[t] == ST_FREE)  n_free++;
      if (tstate[t] == ST_ALLOC) n_alloc++;
    end
    chk(rq_head === rq_tail, "mock ROB still holds entries: drain before the census");
    chk(n_alloc === 0,
        $sformatf("%0d tag(s) still ALLOC with nothing in flight -- leaked", n_alloc));
    chk(n_ar === 32, $sformatf("%0d architectural tags, expected 32", n_ar));
    chk(n_ar + n_free === ENTRIES,
        $sformatf("%0d tags accounted for, expected %0d", n_ar + n_free, ENTRIES));
    for (int i = 0; i < 32; i++)
      chk(tstate[ref_cmap[i]] === ST_AR,
          $sformatf("x%0d maps to tag %0d, which is not architectural", i, ref_cmap[i]));
  endtask

  // --- cases ----------------------------------------------------------------

  // The case this file exists for.
  task automatic case1_waw_chain();
    cur = "1: three writers of x5 in one bundle (WAW chain)";
    set_nops();
    b_inst[0] = addi(5'd5, 5'd1, 12'd1);
    b_inst[1] = addi(5'd5, 5'd2, 12'd2);
    b_inst[2] = addi(5'd5, 5'd3, 12'd3);
    feed(~WIDTH'(0));
    dispatch_and_check();
    // retire them together: the chain collapses in a single cycle, which is
    // where a double free would bite
    commit(3);
    census();
  endtask

  task automatic case2_raw_and_waw();
    cur = "2: RAW through both sources plus a WAW on rd";
    set_nops();
    b_inst[0] = addi(5'd5, 5'd1, 12'd1);        // x5 = x1 + 1
    b_inst[1] = add_(5'd6, 5'd7, 5'd5);         // x6 = x7 + x5   (RAW via rs2)
    b_inst[2] = add_(5'd5, 5'd5, 5'd6);         // x5 = x5 + x6   (RAW both, WAW on x5)
    feed(~WIDTH'(0));
    dispatch_and_check();
    commit(1);
    commit(1);
    commit(1);
    census();
  endtask

  task automatic case3_store_does_not_break_chain();
    cur = "3: a non-allocating slot between two writers of x5";
    set_nops();
    b_inst[0] = addi(5'd5, 5'd1, 12'd1);
    b_inst[1] = sw_(5'd5, 5'd1, 12'd8);         // store: reads x5, writes nothing
    b_inst[2] = addi(5'd5, 5'd1, 12'd3);
    feed(~WIDTH'(0));
    dispatch_and_check();                        // old_tag[2] must be dst_tag[0]
    commit(2);                                   // only two entries: the store has none
    census();
  endtask

  task automatic case4_x0_allocates_nothing();
    cur = "4: writers of x0 allocate no tag";
    set_nops();
    b_inst[0] = addi(5'd0, 5'd1, 12'd1);
    b_inst[1] = addi(5'd0, 5'd2, 12'd2);
    b_inst[2] = addi(5'd7, 5'd0, 12'd3);        // reads x0: born ready, value 0
    feed(~WIDTH'(0));
    await_dispatch();
    chk(m_srdy1[2] === 1'b1, "a source of x0 must come out ready");
    chk(m_sdat1[2] === 64'd0, "a source of x0 must read zero");
    dispatch_and_check();
    commit(1);
    census();
  endtask

  task automatic case5_writeback_wakes_a_later_bundle();
    cur = "5: writeback, then a later bundle reads the value";
    set_nops();
    b_inst[0] = addi(5'd9, 5'd1, 12'd1);
    feed(WIDTH'(1));
    dispatch_and_check();
    // publish a result on the tag just allocated to x9
    @(negedge clk);
    wb_valid[0] = 1'b1;
    wb_tag[0]   = TAG_W'(ref_map[9]);
    wb_data[0]  = 64'hDEAD_BEEF_0000_0001;
    @(posedge clk);                    // one edge only, as in commit()
    @(negedge clk);
    wb_valid = '0;

    set_nops();
    b_inst[0] = add_(5'd10, 5'd9, 5'd0);        // reads x9
    feed(WIDTH'(1));
    await_dispatch();
    chk(m_stag1[0] === TAG_W'(ref_map[9]), "src1_tag must be the tag x9 maps to");
    chk(m_srdy1[0] === 1'b1, "src1 must be ready: the value was written back");
    chk(m_sdat1[0] === 64'hDEAD_BEEF_0000_0001, "src1_data must be the written-back value");
    dispatch_and_check();
    commit(1);
    commit(1);
    census();
  endtask

  // Many bundles, all of them writing a small set of registers so the WAW
  // chains keep overlapping, with commits trailing behind. This is what finds
  // an accounting error that a single bundle hides.
  task automatic case6_sustained();
    int sent;
    cur = "6: sustained traffic over a small register set";
    sent = 0;
    for (int it = 0; it < 24; it++) begin
      set_nops();
      for (int k = 0; k < WIDTH; k++) begin
        // destinations cycle over x1..x4, sources over x1..x5: deliberate
        // overlap, so most bundles carry both a RAW and a WAW
        b_inst[k] = add_(5'(1 + ((it + k) % 4)),
                         5'(1 + ((it + 2 * k) % 5)),
                         5'(1 + ((it + k + 1) % 5)));
      end
      feed(~WIDTH'(0));
      dispatch_and_check();
      sent = sent + WIDTH;
      // trail the commits by one bundle, so allocations and frees overlap
      if (it > 0) commit(WIDTH);
    end
    while (rq_head < rq_tail) commit((rq_tail - rq_head) > WIDTH ? WIDTH : (rq_tail - rq_head));
    census();
    chk(sent === 24 * WIDTH, "bundle accounting in the case itself");
  endtask

  // Tag reuse after a flush: everything speculative goes back, and a tag that
  // was in flight must be allocatable again without ever being double-counted.
  task automatic case7_flush_then_reuse();
    cur = "7: flush with tags in flight, then reuse";
    set_nops();
    b_inst[0] = addi(5'd12, 5'd1, 12'd1);
    b_inst[1] = addi(5'd12, 5'd2, 12'd2);
    b_inst[2] = addi(5'd13, 5'd3, 12'd3);
    feed(~WIDTH'(0));
    dispatch_and_check();

    @(negedge clk);
    flush = 1'b1;
    tick();
    @(negedge clk);
    flush = 1'b0;

    // Model the flush the way the RTL does: every non-architectural tag goes
    // back to FREE and the speculative map is restored from the committed one.
    // The ROB empties too, so the entries just dispatched are gone.
    for (int t = 0; t < ENTRIES; t++) if (tstate[t] == ST_ALLOC) tstate[t] = ST_FREE;
    for (int i = 0; i < 32; i++) ref_map[i] = ref_cmap[i];
    rq_head = rq_tail;
    census();

    // and the core keeps working afterwards
    set_nops();
    b_inst[0] = addi(5'd12, 5'd1, 12'd7);
    b_inst[1] = addi(5'd12, 5'd1, 12'd8);
    feed(WIDTH'(3));
    dispatch_and_check();
    commit(2);
    census();
  endtask

  // --- sequence -------------------------------------------------------------

  initial begin
    cur    = "init";
    checks = 0;
    errors = 0;
    set_nops();
    do_reset();

    case1_waw_chain();                 do_reset();
    case2_raw_and_waw();               do_reset();
    case3_store_does_not_break_chain();do_reset();
    case4_x0_allocates_nothing();      do_reset();
    case5_writeback_wakes_a_later_bundle(); do_reset();
    case6_sustained();                 do_reset();
    case7_flush_then_reuse();

    if (errors != 0) $fatal(1, "%0d error(s)", errors);
    $display("PASS decode_rename_tb (WIDTH = %0d, %0d checks)", WIDTH, checks);
    $finish;
  end

endmodule
