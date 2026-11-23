// Integration (T12): fetch -> PipeFifo (u_ibuf) -> decode, with decode's JAL
// redirect fed back to fetch. Same program, memory model and scoreboard as
// T11 (fetch_decode_tb.sv), now with the instruction buffer between the two
// stages. Spec: docs/fetch/Fetch.md, "Ligação com a u_ibuf".
//
// Wiring under test (no core top exists yet, so it lives here):
//   1. the u_ibuf flush rises on ANY redirect, including Decode's JAL: every
//      bundle in the FIFO is younger than the JAL already inside Decode;
//   2. while the FIFO is being flushed its out_valid is masked, because
//      PipeFifo still shows the old head in the flush cycle and Decode would
//      take it. Decode's own flush is NOT used for the JAL: it would also drop
//      the bundle that holds the JAL.
// FLUSH_ON_JAL and GATE_VALID turn each rule off, to show that both are needed.
//
// Two phases, with a reset between them:
//   A. consumer always ready: checks the order and measures the JAL cost
//      (bubbles between the JAL leaving Decode and its target leaving Decode);
//   B. random back-pressure on Decode's output: checks the order only.
module fetch_ibuf_decode_tb #(
  parameter int DEPTH        = 2,
  parameter bit FLUSH_ON_JAL = 1'b1,
  parameter bit GATE_VALID   = 1'b1
);
  import execute_pkg::*;

  localparam int WIDTH      = 3;
  localparam int MEM_WORDS  = 256;
  localparam int N_EXPECT   = 24;
  localparam int JAL_BUBBLES = 3;   // 2 without the FIFO (T11), +1 crossing it
  localparam int BUNDLE_W   = WIDTH + WIDTH * 32 + WIDTH * XLEN;  // 291

  logic clk = 1'b0;
  logic reset = 1'b1;

  // fetch <-> imem
  logic [WIDTH-1:0][XLEN-1:0] imem_addr;
  logic [WIDTH-1:0][31:0]     imem_rdata;
  // fetch -> u_ibuf
  logic                       f_valid, f_ready;
  logic [WIDTH-1:0]           f_slot_valid;
  logic [WIDTH-1:0][31:0]     f_inst;
  logic [WIDTH-1:0][XLEN-1:0] f_pc;
  // u_ibuf -> decode
  logic                       q_valid, q_ready;
  logic [BUNDLE_W-1:0]        q_data;
  logic                       d_in_valid;
  logic [WIDTH-1:0]           d_in_slot_valid;
  logic [WIDTH-1:0][31:0]     d_in_inst;
  logic [WIDTH-1:0][XLEN-1:0] d_in_pc;
  // decode -> consumer
  logic                       d_valid;
  logic                       d_ready = 1'b1;
  uop_t [WIDTH-1:0]           d_uop;
  logic [WIDTH-1:0][WIDTH-1:0] dep_rs1, dep_rs2, dep_rd;
  // decode -> fetch (JAL)
  logic                       jal_valid;
  logic [XLEN-1:0]            jal_pc;
  logic [WIDTH-1:0]           slot_kill;

  logic                       ibuf_flush;

  logic [31:0] imem [MEM_WORDS];

  fetch #(.WIDTH(WIDTH)) u_fetch (
    .clk, .reset,
    .imem_addr, .imem_rdata,
    .out_valid(f_valid), .out_ready(f_ready), .out_slot_valid(f_slot_valid),
    .out_inst(f_inst), .out_pc(f_pc),
    .dec_redirect_valid(jal_valid), .dec_redirect_pc(jal_pc),
    .be_redirect_valid(1'b0), .be_redirect_pc('0)
  );

  // --- the wiring under test -----------------------------------------------
  // The back-end redirect is tied low here; in the core it joins the OR too.
  assign ibuf_flush = FLUSH_ON_JAL ? jal_valid : 1'b0;

  PipeFifo #(.DATA_W(BUNDLE_W), .DEPTH(DEPTH)) u_ibuf (
    .clk, .reset, .flush(ibuf_flush),
    .in_valid(f_valid), .in_ready(f_ready), .in_data({f_slot_valid, f_pc, f_inst}),
    .out_valid(q_valid), .out_ready(q_ready), .out_data(q_data)
  );

  assign d_in_valid = GATE_VALID ? (q_valid && !ibuf_flush) : q_valid;
  assign {d_in_slot_valid, d_in_pc, d_in_inst} = q_data;
  // -------------------------------------------------------------------------

  decode #(.WIDTH(WIDTH)) u_decode (
    .clk, .reset, .flush(1'b0),
    .in_valid(d_in_valid), .in_ready(q_ready), .in_slot_valid(d_in_slot_valid),
    .in_inst(d_in_inst), .in_pc(d_in_pc),
    .out_valid(d_valid), .out_ready(d_ready), .out_uop(d_uop),
    .out_dep_rs1(dep_rs1), .out_dep_rs2(dep_rs2), .out_dep_rd(dep_rd),
    .redirect_valid(jal_valid), .redirect_pc(jal_pc), .out_slot_kill(slot_kill)
  );

  always #5 clk = ~clk;

  // Synchronous instruction memory, as in T11: one cycle from address to
  // instruction (Fetch.md, "Memória de instruções").
  for (genvar g = 0; g < WIDTH; g++) begin : g_imem
    always_ff @(posedge clk) imem_rdata[g] <= imem[imem_addr[g][9:2]];
  end

  // --- tiny assembler (same as T11) ----------------------------------------
  function automatic logic [31:0] addi(input logic [4:0] rd, input logic [11:0] imm);
    return {imm, 5'd0, 3'b000, rd, 7'b0010011};
  endfunction

  function automatic logic [31:0] jal(input logic [4:0] rd, input logic [20:0] off);
    return {off[20], off[10:1], off[11], off[19:12], rd, 7'b1101111};
  endfunction

  logic [XLEN-1:0] expect_pc [N_EXPECT];
  int  seen;
  int  cycles;
  bit  random_bp;
  int  jal_left;      // cycle the last JAL left Decode, -1 if none pending
  int  jal_checks;

  initial begin
    for (int i = 0; i < MEM_WORDS; i++) imem[i] = addi(5'd31, 12'hBAD); // wrong-path marker

    // 0x00..0x0C straight; 0x10: jal to 0x40 (slot 1 of the 2nd bundle)
    imem[0]  = addi(5'd1, 12'd1);
    imem[1]  = addi(5'd2, 12'd2);
    imem[2]  = addi(5'd3, 12'd3);
    imem[3]  = addi(5'd4, 12'd4);
    imem[4]  = jal(5'd0, 21'h30);           // 0x10 -> 0x40
    // 0x40..0x48 straight; 0x4C: jal x1 back to 0x00 (slot 0 of a bundle)
    imem[16] = addi(5'd5, 12'd5);
    imem[17] = addi(5'd6, 12'd6);
    imem[18] = addi(5'd7, 12'd7);
    imem[19] = jal(5'd1, -21'sh4C);         // 0x4C -> 0x00

    for (int i = 0; i < N_EXPECT; i++) begin
      case (i % 9)
        0: expect_pc[i] = 64'h00;  1: expect_pc[i] = 64'h04;  2: expect_pc[i] = 64'h08;
        3: expect_pc[i] = 64'h0C;  4: expect_pc[i] = 64'h10;  5: expect_pc[i] = 64'h40;
        6: expect_pc[i] = 64'h44;  7: expect_pc[i] = 64'h48;  default: expect_pc[i] = 64'h4C;
      endcase
    end
  end

  // Back-pressure on decode's output: always ready in phase A, random in B.
  always @(negedge clk) d_ready <= random_bp ? (($urandom % 4) != 0) : 1'b1;

  // Scoreboard: every surviving uop must be the next expected PC. In phase A
  // it also measures the gap between a JAL and its target leaving Decode.
  always @(posedge clk) begin
    if (!reset && d_valid && d_ready) begin
      for (int k = 0; k < WIDTH; k++) begin
        uop_t u;
        u = d_uop[k];
        if (u.valid && seen < N_EXPECT) begin
          if (u.pc !== expect_pc[seen])
            $fatal(1, "T12 (DEPTH=%0d): uop %0d: pc = %h, expected %h (wrong-path instruction survived?)",
                   DEPTH, seen, u.pc, expect_pc[seen]);
          if (!random_bp && jal_left >= 0 && (u.pc == 64'h40 || u.pc == 64'h00)) begin
            if (cycles - jal_left - 1 != JAL_BUBBLES)
              $fatal(1, "T12 (DEPTH=%0d): JAL cost %0d bubbles, expected %0d",
                     DEPTH, cycles - jal_left - 1, JAL_BUBBLES);
            jal_checks++;
            jal_left = -1;
          end
          if (u.pc == 64'h10 || u.pc == 64'h4C) jal_left = cycles;
          seen++;
        end
      end
    end
  end

  task automatic run_phase(input bit rbp, output int used);
    @(negedge clk);       // away from the edge the scoreboard samples
    reset     = 1'b1;
    random_bp = rbp;
    seen      = 0;
    cycles    = 0;
    jal_left  = -1;
    repeat (2) @(posedge clk);
    #1 reset = 1'b0;
    while (seen < N_EXPECT && cycles < 500) begin
      @(posedge clk);
      cycles++;
    end
    if (seen < N_EXPECT)
      $fatal(1, "T12 (DEPTH=%0d): only %0d of %0d instructions after %0d cycles",
             DEPTH, seen, N_EXPECT, cycles);
    used = cycles;
  endtask

  initial begin
    int cyc_a, cyc_b;
    jal_checks = 0;
    run_phase(1'b0, cyc_a);
    if (jal_checks == 0) $fatal(1, "T12 (DEPTH=%0d): no JAL cost was measured", DEPTH);
    run_phase(1'b1, cyc_b);
    $display("PASS fetch_ibuf_decode_tb (DEPTH = %0d, %0d instructions in order; JAL = %0d bubbles; %0d cycles free-flowing, %0d with back-pressure)",
             DEPTH, N_EXPECT, JAL_BUBBLES, cyc_a, cyc_b);
    $finish;
  end
endmodule
