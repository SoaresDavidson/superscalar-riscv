// Store buffer (wiki decision 17). Holds the stores that have not written
// memory yet, in program order: reserved at dispatch, filled when the store
// AGU executes (finished), committed by the ROB (completed) and written to the
// data memory from the head, one per cycle (retired).
// Spec: wiki Memory.md, "Store buffer: interface do bloco" and "Ciclo de vida
// de uma entrada".
//
// Three pointers, each an index counted modulo SB_ENTRIES plus a wrap bit
// (sb_ptr_t, execute_pkg): tail (next entry to reserve), cmt (first entry not
// completed) and head (next entry to write). Valid entries go from head to
// tail - 1; the completed ones from head to cmt - 1.
//
// The commit only moves cmt: the write to memory happens later, from the head,
// when the data memory takes it. The retire_team commits at most one store
// per cycle; the buffer counts the bits of st_commit anyway.
//
// The forwarding search is combinational: among the finished and completed
// entries from the head up to the load's color, the youngest that overlaps
// the load. A reserved entry has no address yet and is skipped (the load
// speculates; the load buffer checks later).
module store_buffer
  import execute_pkg::*;
#(
    parameter  int W        = 3,   // bundle width: reservations and commits per cycle
    localparam int SB_CNT_W = $clog2(SB_ENTRIES + 1),
    localparam int N        = SB_ENTRIES
) (
    input  logic clk,
    input  logic reset,
    input  logic flush,                  // drops what is not completed

    // Dispatch
    input  logic [W-1:0]        sb_alloc,
    output logic [SB_CNT_W-1:0] sb_free,
    output sb_ptr_t             sb_tail,

    // Store AGU
    input  logic                st_valid,
    input  fu_resp_t            st_resp,   // address in result; exception
    input  xlen_t               st_data,
    input  exec_op_t            st_op,
    input  lsq_idx_t            st_idx,

    // ROB
    input  logic [W-1:0]        st_commit,
    output logic                lsu_ready,

    // Data memory: write port
    output logic                wr_valid,
    input  logic                wr_ready,
    output xlen_t               wr_addr,   // aligned to 8 bytes
    output xlen_t               wr_data,   // bytes already in place
    output logic [7:0]          wr_strb,

    // A store left the buffer (for the load buffer)
    output logic                ret_valid,
    output sb_ptr_t             ret_idx,

    // Forwarding search (from the load side)
    input  xlen_t               fw_addr,
    input  exec_op_t            fw_op,
    input  sb_ptr_t             fw_color,
    output logic                fw_match,
    output logic                fw_full,
    output xlen_t               fw_data,
    output sb_ptr_t             fw_idx,

    output logic                sb_empty
);

  localparam logic [1:0] S_FREE = 2'd0;
  localparam logic [1:0] S_RES  = 2'd1;   // reserved: no address or data yet
  localparam logic [1:0] S_FIN  = 2'd2;   // finished: address and data, speculative
  localparam logic [1:0] S_COMP = 2'd3;   // completed: committed, waiting to write

  // ---------------------------------------------------------------------------
  // Helpers. Selects stay inside functions or continuous assigns (Icarus).
  // ---------------------------------------------------------------------------
  function automatic int unsigned idx_of(sb_ptr_t p);
    return int'(p[SB_PTR_W-2:0]);
  endfunction

  // Position on the 2N circle: index, plus N on odd laps.
  function automatic int unsigned ord(sb_ptr_t p);
    return idx_of(p) + (p[SB_PTR_W-1] ? N : 0);
  endfunction

  // How far a is after b, in entries (0..2N-1).
  function automatic int unsigned ptr_dist(sb_ptr_t a, sb_ptr_t b);
    return (ord(a) + 2 * N - ord(b)) % (2 * N);
  endfunction

  // Bytes of the doubleword that an access touches.
  function automatic logic [7:0] byte_mask(xlen_t a, exec_op_t op);
    logic [7:0] m;
    case (op)
      AGU_LB, AGU_LBU, AGU_SB: m = 8'b0000_0001;
      AGU_LH, AGU_LHU, AGU_SH: m = 8'b0000_0011;
      AGU_LW, AGU_LWU, AGU_SW: m = 8'b0000_1111;
      default:                 m = 8'b1111_1111;
    endcase
    return m << a[2:0];
  endfunction

  function automatic xlen_t lane(xlen_t a, xlen_t d);
    return d << {a[2:0], 3'b000};
  endfunction

  // ---------------------------------------------------------------------------
  // State. The ent_ prefix marks a per-entry array: ent_x[i] is field x of
  // store buffer entry i.
  // ---------------------------------------------------------------------------
  sb_ptr_t    head, cmt, tail;
  logic [1:0] ent_state [N];
  xlen_t      ent_addr  [N];
  xlen_t      ent_data  [N];
  exec_op_t   ent_op    [N];

  // Per-entry views for the search and the write, by genvar (Icarus: no
  // variable index followed by a second select).
  logic [7:0]      ent_mask [N];
  xlen_t           ent_lane [N];
  logic [XLEN-4:0] ent_dw   [N];   // doubleword address
  logic            ent_vis  [N];   // finished or completed: visible to loads
  int unsigned     ent_dist [N];   // entries after the head

  for (genvar i = 0; i < N; i++) begin : g_view
    assign ent_mask[i] = byte_mask(ent_addr[i], ent_op[i]);
    assign ent_lane[i] = lane(ent_addr[i], ent_data[i]);
    assign ent_dw[i]   = ent_addr[i] >> 3;
    assign ent_vis[i]  = (ent_state[i] == S_FIN) || (ent_state[i] == S_COMP);
    assign ent_dist[i] = (i + N - idx_of(head)) % N;
  end

  int unsigned occ;   // entries in use
  assign occ      = ptr_dist(tail, head);
  assign sb_free  = SB_CNT_W'(N - occ);
  assign sb_tail  = tail;
  assign sb_empty = (occ == 0);
  assign lsu_ready = 1'b1;

  // ---------------------------------------------------------------------------
  // Write to memory: the completed entry at the head
  // ---------------------------------------------------------------------------
  int unsigned hd;
  assign hd        = idx_of(head);
  assign wr_valid  = (cmt != head);
  assign wr_addr   = {ent_dw[hd], 3'b000};
  assign wr_data   = ent_lane[hd];
  assign wr_strb   = ent_mask[hd];
  assign ret_valid = wr_valid && wr_ready;
  assign ret_idx   = head;

  // ---------------------------------------------------------------------------
  // Forwarding search
  // ---------------------------------------------------------------------------
  logic [7:0]      ld_mask;
  logic [XLEN-4:0] ld_dw;
  int unsigned     color_d;
  logic            color_ok;   // the color points to an entry still in the buffer

  assign ld_mask  = byte_mask(fw_addr, fw_op);
  assign ld_dw    = fw_addr >> 3;
  assign color_d  = ptr_dist(fw_color, head);
  assign color_ok = color_d < occ;

  logic        found;
  int unsigned best, best_d;

  always_comb begin
    found  = 1'b0;
    best   = 0;
    best_d = 0;
    for (int i = 0; i < N; i++)
      if (color_ok && ent_vis[i] && ent_dist[i] <= color_d && ent_dw[i] == ld_dw &&
          (ent_mask[i] & ld_mask) != '0 && (!found || ent_dist[i] > best_d)) begin
        found  = 1'b1;
        best   = i;
        best_d = ent_dist[i];
      end
  end

  assign fw_match = found;
  assign fw_full  = found && ((ld_mask & ~ent_mask[best]) == '0);
  assign fw_data  = ent_lane[best];
  assign fw_idx   = sb_ptr_add(head, best_d);

  // ---------------------------------------------------------------------------
  // Update
  // ---------------------------------------------------------------------------
  int unsigned n_alloc, n_commit;
  always_comb begin
    n_alloc  = 0;
    n_commit = 0;
    for (int k = 0; k < W; k++) begin
      n_alloc  = n_alloc  + sb_alloc[k];
      n_commit = n_commit + st_commit[k];
    end
  end

  // Entries committed in this cycle: they survive a flush of the same cycle.
  logic committing [N];
  for (genvar i = 0; i < N; i++) begin : g_cm
    assign committing[i] = ((i + N - idx_of(cmt)) % N) < n_commit;
  end

  xlen_t st_addr;
  logic  st_exc;
  assign st_addr = st_resp.result;
  assign st_exc  = st_resp.exception;

  sb_ptr_t cmt_next;
  assign cmt_next = sb_ptr_add(cmt, n_commit);

  always_ff @(posedge clk) begin
    if (reset) begin
      head <= '0;
      cmt  <= '0;
      tail <= '0;
      for (int i = 0; i < N; i++) ent_state[i] <= S_FREE;
    end else begin
      // Retire: the head entry was written.
      if (ret_valid) begin
        ent_state[hd] <= S_FREE;
        head   <= sb_ptr_add(head, 1);
      end

      // Commit: finished -> completed.
      for (int i = 0; i < N; i++)
        if (committing[i]) ent_state[i] <= S_COMP;
      cmt <= cmt_next;

      if (flush) begin
        // Everything not completed goes back to free; the tail returns to
        // the completed boundary, after this cycle's commit.
        for (int i = 0; i < N; i++)
          if (!committing[i] && (ent_state[i] == S_RES || ent_state[i] == S_FIN))
            ent_state[i] <= S_FREE;
        tail <= cmt_next;
      end else begin
        // Execution: the store AGU fills its reserved entry.
        if (st_valid && !st_exc) begin
          ent_state[idx_of(sb_ptr_t'(st_idx))]     <= S_FIN;
          ent_addr[idx_of(sb_ptr_t'(st_idx))] <= st_addr;
          ent_data[idx_of(sb_ptr_t'(st_idx))] <= st_data;
          ent_op[idx_of(sb_ptr_t'(st_idx))]   <= st_op;
        end
        // Reservation: entries from the tail.
        for (int j = 0; j < W; j++)
          if (j < n_alloc) ent_state[idx_of(sb_ptr_add(tail, j))] <= S_RES;
        tail <= sb_ptr_add(tail, n_alloc);
      end
    end
  end

endmodule
