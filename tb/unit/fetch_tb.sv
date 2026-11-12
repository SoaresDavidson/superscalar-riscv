// Unit testbench for fetch. Spec: docs/fetch/Fetch.md, "Casos de teste".
// Self-checking: prints PASS at the end, $fatal on the first failed check.
module fetch_tb;
  import execute_pkg::*;

  parameter int WIDTH = 3;
  localparam int MEM_WORDS = 256;

  logic clk   = 1'b0;
  logic reset = 1'b1;

  logic [WIDTH-1:0][XLEN-1:0] imem_addr;
  logic [WIDTH-1:0][31:0]     imem_rdata;
  logic                       out_valid;
  logic                       out_ready = 1'b1;
  logic [WIDTH-1:0]           out_slot_valid;
  logic [WIDTH-1:0][31:0]     out_inst;
  logic [WIDTH-1:0][XLEN-1:0] out_pc;
  logic                       dec_redirect_valid = 1'b0;
  logic [XLEN-1:0]            dec_redirect_pc    = '0;
  logic                       be_redirect_valid  = 1'b0;
  logic [XLEN-1:0]            be_redirect_pc     = '0;

  logic [31:0] imem [MEM_WORDS];
  int checks = 0;

  fetch #(.WIDTH(WIDTH)) dut (.*);

  always #5 clk = ~clk;

  // Combinational instruction memory, one read port per slot.
  for (genvar g = 0; g < WIDTH; g++) begin : g_imem
    assign imem_rdata[g] = imem[imem_addr[g][9:2]];
  end

  initial begin
    for (int i = 0; i < MEM_WORDS; i++) imem[i] = 32'h1000_0000 + 32'(i);

    // T1: during reset, out_valid = 0 (0 exactly: x also fails).
    #1;
    if (out_valid !== 1'b0) $fatal(1, "T1: out_valid = %b during reset, expected 0", out_valid);
    checks++;
    @(posedge clk); #1;
    if (out_valid !== 1'b0) $fatal(1, "T1: out_valid = %b during reset, expected 0", out_valid);
    checks++;

    $display("PASS fetch_tb (WIDTH = %0d, %0d checks)", WIDTH, checks);
    $finish;
  end
endmodule
