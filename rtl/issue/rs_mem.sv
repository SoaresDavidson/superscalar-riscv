// Reservation station MEM: holds load and store instructions until both
// sources are ready, then issues at most one load and one store per cycle, to
// the load AGU and the store AGU (wiki decision 17). Spec: docs/rs/RS.md.
//
// Same organization as rs_int (tags only, operands read at issue), with two
// selectors: one among the ready loads, one among the ready stores, each
// picking the OLDEST by age (age_is_younger). The order of issue does not
// affect correctness (the store buffer and the load buffer accept any order),
// but an old store issued late gives younger loads time to read stale data,
// and every such violation costs a full flush.
//
// Loads use src1 (base) only, on one PRF read port; their src2 goes to the
// AGU as 0. Stores use src1 (base) and src2 (data), and issue only with both
// ready. A load's src2 is x0, ready from Dispatch, so the same readiness rule
// covers both. The entry's store/load buffer index and color leave beside each
// request (agu_*_req_lsq_idx, agu_ld_req_color); a store has no color.
module rs_mem
  import execute_pkg::*;
  import dispatch_pkg::*;
#(
    parameter  int W       = 3,   // writes per cycle (bundle width)
    parameter  int ENTRIES = 4,   // RS_MEM_ENTRIES
    parameter  int WB_N    = 3,   // write-back buses: ALU, Branch Unit, load
    localparam int CNT_W   = $clog2(ENTRIES + 1),
    localparam int SLOT_W  = (W > 1) ? $clog2(W) : 1,  // slot index
    localparam int IDX_W   = $clog2(ENTRIES)            // entry index
) (
    input  logic clk,
    input  logic reset,
    input  logic flush,                              // empties the RS

    // Dispatch
    input  logic [W-1:0]               wr,           // mem_wr
    input  rs_mem_entry_t [W-1:0]      wr_entry,     // mem_entry
    output logic [CNT_W-1:0]           free,         // mem_free

    // Write-back buses (wakeup)
    input  logic [WB_N-1:0]            wb_valid,
    input  logic [WB_N-1:0][TAG_W-1:0] wb_tag,

    // Load AGU: request and its PRF read port (base only)
    output logic                       agu_ld_req_valid,
    input  logic                       agu_ld_req_ready,
    output fu_req_t                    agu_ld_req,
    output lsq_idx_t                   agu_ld_req_lsq_idx,  // load buffer entry
    output sb_ptr_t                    agu_ld_req_color,    // last older store entry
    output logic [TAG_W-1:0]           agu_ld_read_tag,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic                       agu_ld_read_valid,   // always 1 at issue, see RS.md
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [XLEN-1:0]            agu_ld_read_data,

    // Store AGU: request and its two PRF read ports (base and data)
    output logic                       agu_st_req_valid,
    input  logic                       agu_st_req_ready,
    output fu_req_t                    agu_st_req,
    output lsq_idx_t                   agu_st_req_lsq_idx,  // store buffer entry
    output logic [1:0][TAG_W-1:0]      agu_st_read_tag,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [1:0]                 agu_st_read_valid,   // always 1 at issue, see RS.md
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [1:0][XLEN-1:0]       agu_st_read_data
);

  // ---------------------------------------------------------------------------
  // Entries
  // ---------------------------------------------------------------------------
  rs_mem_entry_t q [ENTRIES];

  // Per-entry flags. Fields are read from a copy of q[i] (Icarus cannot read
  // q[i].field with a variable index).
  logic [ENTRIES-1:0] busy;
  logic [ENTRIES-1:0] rdy_ld;   // ready load
  logic [ENTRIES-1:0] rdy_st;   // ready store
  age_t               age [ENTRIES];

  for (genvar i = 0; i < ENTRIES; i++) begin : g_entry
    /* verilator lint_off UNUSEDSIGNAL */
    rs_mem_entry_t e;   // only busy, ready, op and age are read here
    /* verilator lint_on UNUSEDSIGNAL */
    logic          rdy;
    assign e         = q[i];
    assign busy[i]   = e.busy;
    assign rdy       = e.busy && e.src1_ready && e.src2_ready;
    assign rdy_ld[i] = rdy &&  is_load(e.op);
    assign rdy_st[i] = rdy && !is_load(e.op);
    assign age[i]    = e.age;
  end

  // Free entries at the start of the cycle. Entries freed by an issue in this
  // cycle are not counted until the next one.
  always_comb begin
    free = '0;
    for (int i = 0; i < ENTRIES; i++)
      if (!busy[i]) free = free + CNT_W'(1);
  end

  // ---------------------------------------------------------------------------
  // Allocation: the k-th slot with wr = 1 takes the k-th entry free at the
  // start of the cycle, counting from entry 0. `found` replaces `break`.
  // ---------------------------------------------------------------------------
  logic [ENTRIES-1:0] alloc;                  // entry i is written this cycle
  logic [SLOT_W-1:0]  alloc_slot [ENTRIES];   // source slot for entry i

  always_comb begin
    logic [ENTRIES-1:0] taken;
    logic               found;
    taken = '0;
    alloc = '0;
    for (int i = 0; i < ENTRIES; i++) alloc_slot[i] = '0;

    for (int k = 0; k < W; k++) begin
      found = 1'b0;
      if (wr[k])
        for (int i = 0; i < ENTRIES; i++)
          if (!busy[i] && !taken[i] && !found) begin
            taken[i]      = 1'b1;
            found         = 1'b1;
            alloc[i]      = 1'b1;
            alloc_slot[i] = SLOT_W'(k);
          end
    end
  end

  // Bundle entry routed to each RS entry. Meaningful only where alloc[i] = 1.
  rs_mem_entry_t incoming [ENTRIES];

  for (genvar i = 0; i < ENTRIES; i++) begin : g_incoming
    assign incoming[i] = wr_entry[alloc_slot[i]];
  end

  // ---------------------------------------------------------------------------
  // Select and issue: two selectors, each the oldest ready entry of its kind.
  // The loop has no break: an entry replaces the best so far when the best is
  // younger than it, so the oldest is left at the end. Ready bits are
  // registered, so an entry woken in this cycle issues in the next one.
  // ---------------------------------------------------------------------------
  logic             found_ld, found_st;
  logic [IDX_W-1:0] idx_ld,   idx_st;

  always_comb begin
    found_ld = 1'b0;
    found_st = 1'b0;
    idx_ld   = '0;
    idx_st   = '0;
    for (int i = 0; i < ENTRIES; i++) begin
      if (rdy_ld[i] && (!found_ld || age_is_younger(age[idx_ld], age[i]))) begin
        found_ld = 1'b1;
        idx_ld   = IDX_W'(i);
      end
      if (rdy_st[i] && (!found_st || age_is_younger(age[idx_st], age[i]))) begin
        found_st = 1'b1;
        idx_st   = IDX_W'(i);
      end
    end
  end

  rs_mem_entry_t sl;   // selected load
  rs_mem_entry_t ss;   // selected store
  assign sl = q[idx_ld];
  assign ss = q[idx_st];

  // Source tags and ready bits stay behind; the rest goes to the FU.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic fu_req_t make_req(rs_mem_entry_t e, xlen_t v1, xlen_t v2);
    fu_req_t r;
    r             = '0;
    r.op          = e.op;
    r.src1        = v1;
    r.src2        = v2;
    r.imm         = e.imm;
    r.dst_tag     = e.dst_tag;
    r.wr_en       = e.wr_en;
    r.age         = e.age;
    return r;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  assign agu_ld_read_tag    = sl.src1_tag;
  assign agu_st_read_tag[0] = ss.src1_tag;
  assign agu_st_read_tag[1] = ss.src2_tag;

  // No request during flush: the selected instructions are on the wrong path.
  assign agu_ld_req_valid = found_ld && !flush;
  assign agu_st_req_valid = found_st && !flush;
  assign agu_ld_req       = make_req(sl, agu_ld_read_data, '0);
  assign agu_st_req       = make_req(ss, agu_st_read_data[0], agu_st_read_data[1]);

  // Memory side fields (wiki decision 17), beside the requests: fu_req_t has
  // no field for them. Valid with the request's valid.
  assign agu_ld_req_lsq_idx = sl.lsq_idx;
  assign agu_ld_req_color   = sl.color;
  assign agu_st_req_lsq_idx = ss.lsq_idx;

  logic ld_issue, st_issue;   // transfers to the AGUs at the next edge
  assign ld_issue = agu_ld_req_valid && agu_ld_req_ready;
  assign st_issue = agu_st_req_valid && agu_st_req_ready;

  // ---------------------------------------------------------------------------
  // Wakeup: a source becomes ready at the edge when a write-back bus carries
  // its tag. No value is copied; the write-back already wrote it to the PRF.
  // ---------------------------------------------------------------------------
  function automatic logic woke(tag_t                       t,
                                logic [WB_N-1:0]            v,
                                logic [WB_N-1:0][TAG_W-1:0] tg);
    logic r;
    r = 1'b0;
    for (int p = 0; p < WB_N; p++)
      if (v[p] && tg[p] == t) r = 1'b1;
    return r;
  endfunction

  // Sets the ready bit of every source woken this cycle; never clears one.
  function automatic rs_mem_entry_t wake(rs_mem_entry_t              e,
                                         logic [WB_N-1:0]            v,
                                         logic [WB_N-1:0][TAG_W-1:0] tg);
    rs_mem_entry_t o;
    o = e;
    if (woke(e.src1_tag, v, tg)) o.src1_ready = 1'b1;
    if (woke(e.src2_tag, v, tg)) o.src2_ready = 1'b1;
    return o;
  endfunction

  // Candidate next values: the entry as it is (woken_q) and the entry being
  // written (woken_in), both after this cycle's wakeup.
  rs_mem_entry_t woken_q  [ENTRIES];
  rs_mem_entry_t woken_in [ENTRIES];

  for (genvar i = 0; i < ENTRIES; i++) begin : g_wake
    assign woken_q[i]  = wake(q[i],        wb_valid, wb_tag);
    assign woken_in[i] = wake(incoming[i], wb_valid, wb_tag);
  end

  // ---------------------------------------------------------------------------
  // State update. Reset and flush empty every entry, including a write of the
  // same cycle. Otherwise each entry is written (alloc), freed (issued by
  // either selector; a load and a store may leave in the same cycle) or kept
  // with its sources woken. An allocated entry was free at the start of the
  // cycle, so it is never one being issued.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset || flush) begin
      for (int i = 0; i < ENTRIES; i++) q[i] <= '0;
    end else begin
      for (int i = 0; i < ENTRIES; i++)
        if (alloc[i]) q[i] <= woken_in[i];
        else if ((ld_issue && idx_ld == IDX_W'(i)) ||
                 (st_issue && idx_st == IDX_W'(i)))
          q[i] <= '0;
        else q[i] <= woken_q[i];
    end
  end

endmodule
