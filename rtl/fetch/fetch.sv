// Fetch stage. Spec: docs/fetch/Fetch.md.
//
// Next-PC priority, highest first (spec, "Próximo PC"):
//   reset > back-end redirect > Decode redirect (JAL) > stall > sequential.
// In a cycle with any redirect, the bundle on the output was fetched from the
// old PC and is on the wrong path, so out_valid is held low.
module fetch
  import execute_pkg::*;
#(
  parameter int    WIDTH    = 3,
  parameter xlen_t RESET_PC = '0
) (
  input  logic                        clk,
  input  logic                        reset,   // synchronous, active high

  // instruction memory: one combinational read port per slot
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

  logic any_redirect;

  assign any_redirect = be_redirect_valid || dec_redirect_valid;

  // One PC register per slot (spec, "PC de cada slot"), always holding
  // pc_q[k] = pc_q[0] + 4k. The +4k is added before the flip-flop, so
  // imem_addr and out_pc come straight from registers: no adder between the
  // flip-flop and the outputs (v1's critical path in the slow corner).
  //
  // Without out_ready (and no redirect) the registers do not load: PC and
  // bundle hold (T4). A redirect wins over the stall (T6), and the back end
  // wins over Decode (T7).
  for (genvar k = 0; k < WIDTH; k++) begin : g_slot
    xlen_t pc_q;

    always_ff @(posedge clk) begin
      if (reset)                   pc_q <= RESET_PC + XLEN'(4 * k);
      else if (be_redirect_valid)  pc_q <= be_redirect_pc  + XLEN'(4 * k); // T6, T7
      else if (dec_redirect_valid) pc_q <= dec_redirect_pc + XLEN'(4 * k); // T5
      else if (out_ready)          pc_q <= pc_q + XLEN'(4 * WIDTH);        // T3
    end

    assign imem_addr[k] = pc_q;
    assign out_pc[k]    = pc_q;
    assign out_inst[k]  = imem_rdata[k];
  end

  assign out_slot_valid = '1;
  assign out_valid      = !reset && !any_redirect;   // T1, T5

endmodule
