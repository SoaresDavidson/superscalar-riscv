// Fetch stage. Spec: docs/fetch/Fetch.md.
//
// The instruction memory is synchronous: imem_rdata carries the instructions
// of the address sent the cycle before. Fetch therefore has two stages:
//   F1 -- pc_q: the address being sent to the memory this cycle;
//   F2 -- f2_*: the bundle whose instructions arrive this cycle, offered to
//         Decode.
//
// Next-state priority, highest first (spec, "Próximo estado"):
//   reset > back-end redirect > Decode redirect (JAL) > stall > advance.
// A reset or redirect empties F2: the new address has only just been sent.
// In a cycle with any redirect, the bundle in F2 is on the wrong path, so
// out_valid is held low; the bundle in F1 is dropped at the same edge.
module fetch
  import execute_pkg::*;
#(
  parameter int    WIDTH    = 3,
  parameter xlen_t RESET_PC = '0
) (
  input  logic                        clk,
  input  logic                        reset,   // synchronous, active high

  // instruction memory: one synchronous read port per slot (1-cycle latency)
  output logic [WIDTH-1:0][XLEN-1:0]  imem_addr,
  input  logic [WIDTH-1:0][31:0]      imem_rdata,

  // Fetch -> Decode (same names as decode's in_* ports)
  output logic                        out_valid,
  input  logic                        out_ready,
  output logic [WIDTH-1:0]            out_slot_valid,
  output logic [WIDTH-1:0][31:0]      out_inst,
  output logic [WIDTH-1:0][XLEN-1:0]  out_pc,

  // redirect from Decode (JAL)
  input  logic                        dec_redirect_valid,
  input  logic [XLEN-1:0]             dec_redirect_pc,

  // redirect from the back end (Pipeline-Control)
  input  logic                        be_redirect_valid,
  input  logic [XLEN-1:0]             be_redirect_pc
);

  xlen_t                  pc_q;      // F1
  logic                   f2_valid_q;
  xlen_t                  f2_pc_q;
  logic                   held_q;    // F2's instructions live in inst_q
  logic [WIDTH-1:0][31:0] inst_q;

  logic any_redirect;
  logic stall;

  assign any_redirect = be_redirect_valid || dec_redirect_valid;
  // F2 holds a bundle that Decode does not take this cycle.
  assign stall        = f2_valid_q && !out_ready;

  always_ff @(posedge clk) begin
    if (reset) begin
      pc_q       <= RESET_PC;                          // T1, T2, T10
      f2_valid_q <= 1'b0;
      held_q     <= 1'b0;
    end else if (be_redirect_valid) begin
      pc_q       <= be_redirect_pc;                    // T6, T7
      f2_valid_q <= 1'b0;
      held_q     <= 1'b0;
    end else if (dec_redirect_valid) begin
      pc_q       <= dec_redirect_pc;                   // T5
      f2_valid_q <= 1'b0;
      held_q     <= 1'b0;
    end else if (stall) begin
      // The memory moves on to the next bundle, so the stalled instructions
      // are copied once, in the first stall cycle (T4). pc_q holds: its
      // address is resent and arrives when the stall ends.
      if (!held_q) inst_q <= imem_rdata;
      held_q     <= 1'b1;
    end else begin
      // F2 empty or its bundle accepted: F1 moves to F2 (T3).
      f2_valid_q <= 1'b1;
      f2_pc_q    <= pc_q;
      held_q     <= 1'b0;
      pc_q       <= pc_q + XLEN'(4 * WIDTH);
    end
  end

  for (genvar k = 0; k < WIDTH; k++) begin : g_slot
    assign imem_addr[k] = pc_q + XLEN'(4 * k);
    assign out_pc[k]    = f2_pc_q + XLEN'(4 * k);
  end

  assign out_inst       = held_q ? inst_q : imem_rdata;
  assign out_slot_valid = '1;
  assign out_valid      = !reset && f2_valid_q && !any_redirect;   // T1, T5

endmodule
