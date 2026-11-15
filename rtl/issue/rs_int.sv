// Reservation station INT: holds the instructions for the ALU and the Branch
// Unit until both sources are ready, then issues one per FU per cycle.
// Spec: docs/rs/RS.md.
//
// Tags only: an entry never holds operand values. At issue, the source tags
// of the selected entry go to the PRF read ports and src1/src2 of fu_req_t
// come from the read data, in the same cycle.
//
// STATUS: parts 1 and 2 of 5 (state, reset, free count, allocation).
// Select/issue, wakeup and flush still to come; their outputs are tied to
// zero.
/* verilator lint_off UNUSEDSIGNAL */
module rs_int
  import execute_pkg::*;
  import dispatch_pkg::*;
#(
    parameter  int W       = 3,   // bundle width: writes per cycle
    parameter  int ENTRIES = 8,   // RS_INT_ENTRIES
    parameter  int WB_N    = 3,   // write-back buses: ALU, Branch Unit, load
    localparam int CNT_W   = $clog2(ENTRIES + 1),
    localparam int SLOT_W  = (W > 1) ? $clog2(W) : 1   // index of a slot
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

  for (genvar i = 0; i < ENTRIES; i++) begin : g_entry
    rs_int_entry_t e;
    assign e       = q[i];
    assign busy[i] = e.busy;
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
  // State. Reset empties every entry; an allocated entry takes the incoming
  // one. Wakeup, issue and flush are added in parts 3 to 5; until then any
  // other entry keeps its value.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      for (int i = 0; i < ENTRIES; i++) q[i] <= '0;
    end else begin
      for (int i = 0; i < ENTRIES; i++)
        if (alloc[i]) q[i] <= incoming[i];
    end
  end

  // TODO parts 3 to 5. See docs/rs/RS.md, section "Funcionamento".
  assign alu_req_valid = 1'b0;
  assign alu_req       = '0;
  assign alu_read_tag  = '0;
  assign br_req_valid  = 1'b0;
  assign br_req        = '0;
  assign br_read_tag   = '0;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
