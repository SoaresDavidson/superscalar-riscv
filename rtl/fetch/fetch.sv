// Fetch stage. Spec: docs/fetch/Fetch.md.
//
// This commit: module skeleton with every port of the spec and the reset
// behavior only (test case T1). Sequential fetch, stall and redirects come
// in the next commits, each with its test cases.
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

  always_ff @(posedge clk) begin
    if (reset) pc_q <= RESET_PC;
  end

  for (genvar k = 0; k < WIDTH; k++) begin : g_slot
    assign imem_addr[k] = pc_q + XLEN'(4 * k);
    assign out_pc[k]    = pc_q + XLEN'(4 * k);
    assign out_inst[k]  = imem_rdata[k];
  end

  assign out_slot_valid = '1;
  assign out_valid      = !reset;   // T1

  // Not used yet: stall (T4) and redirects (T5 to T7).
  logic unused;
  assign unused = &{1'b0, out_ready, dec_redirect_valid, dec_redirect_pc,
                    be_redirect_valid, be_redirect_pc};

endmodule
