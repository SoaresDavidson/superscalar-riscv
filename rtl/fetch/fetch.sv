// Fetch stage. Spec: docs/fetch/Fetch.md.
//
// Implemented so far: reset (T1, T2), sequential fetch (T3) and stall (T4).
// Redirects come in the next commit, with their test cases.
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

  // Next PC: reset, then one bundle further each time Decode accepts.
  // Without out_ready the register does not load: PC and bundle hold (T4).
  always_ff @(posedge clk) begin
    if (reset)          pc_q <= RESET_PC;
    else if (out_ready) pc_q <= pc_q + XLEN'(4 * WIDTH);   // T3
  end

  for (genvar k = 0; k < WIDTH; k++) begin : g_slot
    assign imem_addr[k] = pc_q + XLEN'(4 * k);
    assign out_pc[k]    = pc_q + XLEN'(4 * k);
    assign out_inst[k]  = imem_rdata[k];
  end

  assign out_slot_valid = '1;
  assign out_valid      = !reset;   // T1

  // Not used yet: redirects (T5 to T7).
  logic unused;
  assign unused = &{1'b0, dec_redirect_valid, dec_redirect_pc,
                    be_redirect_valid, be_redirect_pc};

endmodule
