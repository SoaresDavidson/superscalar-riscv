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

  xlen_t pc_q;
  logic  any_redirect;

  assign any_redirect = be_redirect_valid || dec_redirect_valid;

  // Without out_ready (and no redirect) the register does not load: PC and
  // bundle hold (T4). A redirect wins over the stall (T6), and the back end
  // wins over Decode (T7).
  always_ff @(posedge clk) begin
    if (reset)                   pc_q <= RESET_PC;
    else if (be_redirect_valid)  pc_q <= be_redirect_pc;          // T6, T7
    else if (dec_redirect_valid) pc_q <= dec_redirect_pc;         // T5
    else if (out_ready)          pc_q <= pc_q + XLEN'(4 * WIDTH); // T3
  end

  for (genvar k = 0; k < WIDTH; k++) begin : g_slot
    assign imem_addr[k] = pc_q + XLEN'(4 * k);
    assign out_pc[k]    = pc_q + XLEN'(4 * k);
    assign out_inst[k]  = imem_rdata[k];
  end

  assign out_slot_valid = '1;
  assign out_valid      = !reset && !any_redirect;   // T1, T5

endmodule
