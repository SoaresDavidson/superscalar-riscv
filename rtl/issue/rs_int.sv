// Reservation station INT: holds the instructions for the ALU and the Branch
// Unit until both sources are ready, then issues one per FU per cycle.
// Spec: docs/rs/RS.md.
//
// Tags only: an entry never holds operand values. At issue, the source tags
// of the selected entry go to the PRF read ports and src1/src2 of fu_req_t
// come from the read data, in the same cycle.
//
// STATUS: parts 1 to 4 of 5 (state, reset, free count, allocation,
// select/issue, wakeup). Flush still to come.
/* verilator lint_off UNUSEDSIGNAL */
module rs_int
  import execute_pkg::*;
  import dispatch_pkg::*;
#(
    parameter  int W       = 3,   // bundle width: writes per cycle
    parameter  int ENTRIES = 8,   // RS_INT_ENTRIES
    parameter  int WB_N    = 3,   // write-back buses: ALU, Branch Unit, load
    localparam int CNT_W   = $clog2(ENTRIES + 1),
    localparam int SLOT_W  = (W > 1) ? $clog2(W) : 1,  // index of a slot
    localparam int IDX_W   = $clog2(ENTRIES)            // index of an entry
) (
    input  logic clk,
    input  logic reset,
    input  logic flush,                              // clears every entry

    // Dispatch
    input  logic [W-1:0]               wr,           // int_wr
    input  rs_int_entry_t [W-1:0]      wr_entry,     // int_entry
    output logic [CNT_W-1:0]           free,         // int_free

    // Write-back buses (wakeup)
    input  logic [WB_N-1:0]            wb_valid,
    input  logic [WB_N-1:0][TAG_W-1:0] wb_tag,

    // ALU: request and its two PRF read ports (PRFRename read ports 0 and 1)
    output logic                       alu_req_valid,
    input  logic                       alu_req_ready,
    output fu_req_t                    alu_req,
    output logic [1:0][TAG_W-1:0]      alu_read_tag,
    input  logic [1:0]                 alu_read_valid,
    input  logic [1:0][XLEN-1:0]       alu_read_data,

    // Branch Unit: same shape (PRFRename read ports 2 and 3)
    output logic                       br_req_valid,
    input  logic                       br_req_ready,
    output fu_req_t                    br_req,
    output logic [1:0][TAG_W-1:0]      br_read_tag,
    input  logic [1:0]                 br_read_valid,
    input  logic [1:0][XLEN-1:0]       br_read_data
);

  // ---------------------------------------------------------------------------
  // Part 1: state, reset, free count
  // ---------------------------------------------------------------------------

  // The entries. Unpacked array: each q[i] is one rs_int_entry_t.
  rs_int_entry_t q [ENTRIES];

  // busy bit of every entry, as a plain vector. Icarus cannot read q[i].busy
  // directly, so each entry is copied to a temporary first (one per entry,
  // with a genvar) and the field is read from the copy.
  logic [ENTRIES-1:0] busy;
  logic [ENTRIES-1:0] rdy_alu;   // ready, for the ALU          (part 3)
  logic [ENTRIES-1:0] rdy_br;    // ready, for the Branch Unit  (part 3)

  for (genvar i = 0; i < ENTRIES; i++) begin : g_entry
    rs_int_entry_t e;
    fu_kind_t      f;
    assign e          = q[i];
    assign busy[i]    = e.busy;
    assign f          = fu_of(e.op);
    assign rdy_alu[i] = e.busy && e.src1_ready && e.src2_ready && f == FU_ALU;
    assign rdy_br[i]  = e.busy && e.src1_ready && e.src2_ready && f == FU_BRANCH;
  end

  // free = entries with busy = 0 at the START of the cycle (RS.md, part 4).
  // It reads only the registered busy bits, never what this cycle will
  // allocate or issue.
  always_comb begin
    free = '0;
    for (int i = 0; i < ENTRIES; i++)
      if (!busy[i]) free = free + CNT_W'(1);
  end

  // ---------------------------------------------------------------------------
  // Part 2: allocation
  //
  // The k-th slot with wr = 1 takes the k-th free entry, searching from
  // entry 0 (RS.md, part 1). Slots are visited in order; each one takes the
  // first entry that is free at the start of the cycle and not yet taken by
  // an earlier slot. No `break` (Icarus ignores it): `found` stops a slot
  // from taking a second entry.
  // ---------------------------------------------------------------------------
  logic [ENTRIES-1:0] alloc;                  // entry i is written this cycle
  logic [SLOT_W-1:0]  alloc_slot [ENTRIES];   // ... with the entry of this slot

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

  // The entry that lands in each RS entry, picked from the bundle. Done with
  // a genvar and a continuous assign, outside the always_ff.
  rs_int_entry_t incoming [ENTRIES];

  for (genvar i = 0; i < ENTRIES; i++) begin : g_incoming
    assign incoming[i] = wr_entry[alloc_slot[i]];
  end

  // ---------------------------------------------------------------------------
  // Part 3: select and issue
  //
  // One selector per FU, over disjoint sets of entries (fu_of(op)). Each
  // picks the ready entry with the lowest index: the loop runs from the top
  // down and the last write wins (no `break`). Readiness comes from the
  // registered bits, so an entry woken in this cycle issues in the next one.
  // ---------------------------------------------------------------------------
  logic             alu_found, br_found;
  logic [IDX_W-1:0] alu_idx,   br_idx;

  always_comb begin
    alu_found = 1'b0;  alu_idx = '0;
    br_found  = 1'b0;  br_idx  = '0;
    for (int i = ENTRIES - 1; i >= 0; i--) begin
      if (rdy_alu[i]) begin alu_found = 1'b1; alu_idx = IDX_W'(i); end
      if (rdy_br[i])  begin br_found  = 1'b1; br_idx  = IDX_W'(i); end
    end
  end

  // The selected entries, copied out of q before their fields are read.
  rs_int_entry_t sa, sb;
  assign sa = q[alu_idx];
  assign sb = q[br_idx];

  // fu_req_t from an entry and the two values read from the PRF.
  function automatic fu_req_t make_req(rs_int_entry_t e, xlen_t v1, xlen_t v2);
    fu_req_t r;
    r             = '0;
    r.op          = e.op;
    r.src1        = v1;
    r.src2        = v2;
    r.imm         = e.imm;
    r.use_imm     = e.use_imm;
    r.pc          = e.pc;
    r.dst_tag     = e.dst_tag;
    r.wr_en       = e.wr_en;
    r.age         = e.age;
    r.pred_taken  = e.pred_taken;
    r.pred_target = e.pred_target;
    return r;
  endfunction

  // Operand read: the source tags of the selected entry go to the PRF read
  // ports; the values come back in the same cycle (read_valid is always 1,
  // see RS.md).
  assign alu_read_tag[0] = sa.src1_tag;
  assign alu_read_tag[1] = sa.src2_tag;
  assign br_read_tag[0]  = sb.src1_tag;
  assign br_read_tag[1]  = sb.src2_tag;

  assign alu_req_valid = alu_found;   // part 5: && !flush
  assign br_req_valid  = br_found;    // part 5: && !flush
  assign alu_req       = make_req(sa, alu_read_data[0], alu_read_data[1]);
  assign br_req        = make_req(sb, br_read_data[0],  br_read_data[1]);

  // A transfer happens when the FU accepts the request.
  logic alu_issue, br_issue;
  assign alu_issue = alu_req_valid && alu_req_ready;
  assign br_issue  = br_req_valid  && br_req_ready;

  // ---------------------------------------------------------------------------
  // Part 4: wakeup
  //
  // A waiting source becomes ready at the edge when a write-back bus carries
  // its tag. No value is copied: the same write-back already wrote it into
  // the PRF. wake() only sets ready bits, never clears them.
  // ---------------------------------------------------------------------------

  // Was tag t broadcast on any write-back bus this cycle?
  function automatic logic woke(tag_t                       t,
                                logic [WB_N-1:0]            v,
                                logic [WB_N-1:0][TAG_W-1:0] tg);
    logic r;
    r = 1'b0;
    for (int p = 0; p < WB_N; p++)
      if (v[p] && tg[p] == t) r = 1'b1;
    return r;
  endfunction

  // The entry with every source woken by this cycle's broadcasts.
  function automatic rs_int_entry_t wake(rs_int_entry_t              e,
                                         logic [WB_N-1:0]            v,
                                         logic [WB_N-1:0][TAG_W-1:0] tg);
    rs_int_entry_t o;
    o = e;
    if (woke(e.src1_tag, v, tg)) o.src1_ready = 1'b1;
    if (woke(e.src2_tag, v, tg)) o.src2_ready = 1'b1;
    return o;
  endfunction

  // Next value of each entry if it stays (woken_q) or arrives (woken_in).
  // Computed with a genvar and continuous assigns, outside the always_ff.
  rs_int_entry_t woken_q  [ENTRIES];
  rs_int_entry_t woken_in [ENTRIES];

  for (genvar i = 0; i < ENTRIES; i++) begin : g_wake
    assign woken_q[i]  = wake(q[i],        wb_valid, wb_tag);
    assign woken_in[i] = wake(incoming[i], wb_valid, wb_tag);
  end

  // ---------------------------------------------------------------------------
  // State. Every cycle, each entry either:
  //   - arrives: takes the incoming entry, already woken (a broadcast in the
  //     cycle it is written must not be missed, RS.md part 2);
  //   - is issued: freed;
  //   - stays: keeps its content, plus any source woken this cycle.
  // An entry being allocated was free, so it cannot be the one being issued.
  // Flush is added in part 5.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      for (int i = 0; i < ENTRIES; i++) q[i] <= '0;
    end else begin
      for (int i = 0; i < ENTRIES; i++)
        if (alloc[i]) q[i] <= woken_in[i];
        else if ((alu_issue && alu_idx == IDX_W'(i)) ||
                 (br_issue  && br_idx  == IDX_W'(i)))
          q[i] <= '0;
        else q[i] <= woken_q[i];
    end
  end

  // TODO part 5. See docs/rs/RS.md, section "Funcionamento".

endmodule
/* verilator lint_on UNUSEDSIGNAL */
