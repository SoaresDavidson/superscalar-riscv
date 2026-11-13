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

  localparam logic [XLEN-1:0] BUNDLE = XLEN'(4 * WIDTH);  // bytes per bundle

  // The bundle on the output must be valid, start at pc0, and carry the
  // instructions stored at pc0, pc0 + 4, ... Each slot is copied to a scalar
  // first: Icarus 12 misreads a variable index followed by a second select.
  task automatic expect_bundle(input string tc, input logic [XLEN-1:0] pc0);
    logic [XLEN-1:0] pc_k;
    logic [XLEN-1:0] want;
    logic [31:0]     inst_k;
    if (out_valid !== 1'b1)
      $fatal(1, "%s: out_valid = %b, expected 1", tc, out_valid);
    if (out_slot_valid !== '1)
      $fatal(1, "%s: out_slot_valid = %b, expected all ones", tc, out_slot_valid);
    for (int k = 0; k < WIDTH; k++) begin
      pc_k   = out_pc[k];
      inst_k = out_inst[k];
      want   = pc0 + XLEN'(4 * k);
      if (pc_k !== want)
        $fatal(1, "%s: slot %0d pc = %h, expected %h", tc, k, pc_k, want);
      if (inst_k !== imem[want[9:2]])
        $fatal(1, "%s: slot %0d inst = %h, expected %h", tc, k, inst_k, imem[want[9:2]]);
      checks++;
    end
  endtask

  // In a cycle with a redirect the bundle on the output is on the wrong path.
  task automatic expect_invalid(input string tc);
    if (out_valid !== 1'b0)
      $fatal(1, "%s: out_valid = %b, expected 0", tc, out_valid);
    checks++;
  endtask

  initial begin
    for (int i = 0; i < MEM_WORDS; i++) imem[i] = 32'h1000_0000 + 32'(i);

    // T1: during reset, out_valid = 0 (0 exactly: x also fails).
    #1;
    if (out_valid !== 1'b0) $fatal(1, "T1: out_valid = %b during reset, expected 0", out_valid);
    checks++;
    @(posedge clk); #1;
    if (out_valid !== 1'b0) $fatal(1, "T1: out_valid = %b during reset, expected 0", out_valid);
    checks++;

    // T2: after reset, the bundle starts at RESET_PC with every slot valid.
    reset = 1'b0; #1;
    expect_bundle("T2", '0);

    // T3: sequential fetch, one bundle further per accepted cycle.
    @(posedge clk); #1; expect_bundle("T3", BUNDLE);
    @(posedge clk); #1; expect_bundle("T3", 2 * BUNDLE);

    // T4: stall. With out_ready = 0 the bundle already on the output
    // (2 * BUNDLE) stays there; fetch resumes when out_ready returns.
    out_ready = 1'b0;
    repeat (3) begin
      @(posedge clk); #1; expect_bundle("T4", 2 * BUNDLE);
    end
    out_ready = 1'b1;
    @(posedge clk); #1; expect_bundle("T4", 3 * BUNDLE);

    // T5: Decode redirect (JAL). The bundle is dropped in the redirect cycle;
    // the next one starts at the target.
    dec_redirect_valid = 1'b1; dec_redirect_pc = 64'h80; #1;
    expect_invalid("T5");
    @(posedge clk); #1; dec_redirect_valid = 1'b0; #1;
    expect_bundle("T5", 64'h80);

    // T6: back-end redirect during a stall. The stalled bundle is on the
    // wrong path, so the redirect wins; with out_ready still 0 the new bundle
    // then holds like any other.
    out_ready = 1'b0;
    be_redirect_valid = 1'b1; be_redirect_pc = 64'h20; #1;
    expect_invalid("T6");
    @(posedge clk); #1; be_redirect_valid = 1'b0; #1;
    expect_bundle("T6", 64'h20);
    @(posedge clk); #1; expect_bundle("T6", 64'h20);
    out_ready = 1'b1;

    // T7: both redirects in the same cycle. The back end corrects an older
    // instruction, so it wins over Decode.
    be_redirect_valid  = 1'b1; be_redirect_pc  = 64'h100;
    dec_redirect_valid = 1'b1; dec_redirect_pc = 64'h40; #1;
    expect_invalid("T7");
    @(posedge clk); #1; be_redirect_valid = 1'b0; dec_redirect_valid = 1'b0; #1;
    expect_bundle("T7", 64'h100);

    $display("PASS fetch_tb (WIDTH = %0d, %0d checks)", WIDTH, checks);
    $finish;
  end
endmodule
