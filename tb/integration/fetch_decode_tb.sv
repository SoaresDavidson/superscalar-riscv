// Integration: fetch -> decode, with decode's JAL redirect fed back to fetch.
// Checks that the instructions leaving decode (uop.valid = 1) follow the
// program order exactly: no wrong-path instruction after a JAL ever survives,
// with random back-pressure from the consumer of decode.
module fetch_decode_tb;
  import execute_pkg::*;

  localparam int WIDTH     = 3;
  localparam int MEM_WORDS = 256;
  localparam int N_EXPECT  = 24;

  logic clk = 1'b0;
  logic reset = 1'b1;

  // fetch <-> imem
  logic [WIDTH-1:0][XLEN-1:0] imem_addr;
  logic [WIDTH-1:0][31:0]     imem_rdata;
  // fetch -> decode
  logic                       f_valid, f_ready;
  logic [WIDTH-1:0]           f_slot_valid;
  logic [WIDTH-1:0][31:0]     f_inst;
  logic [WIDTH-1:0][XLEN-1:0] f_pc;
  // decode -> consumer
  logic                       d_valid;
  logic                       d_ready = 1'b1;
  uop_t [WIDTH-1:0]           d_uop;
  logic [WIDTH-1:0][WIDTH-1:0] dep_rs1, dep_rs2, dep_rd;
  // decode -> fetch (JAL)
  logic                       jal_valid;
  logic [XLEN-1:0]            jal_pc;
  logic [WIDTH-1:0]           slot_kill;

  logic [31:0] imem [MEM_WORDS];

  fetch #(.WIDTH(WIDTH)) u_fetch (
    .clk, .reset,
    .imem_addr, .imem_rdata,
    .out_valid(f_valid), .out_ready(f_ready), .out_slot_valid(f_slot_valid),
    .out_inst(f_inst), .out_pc(f_pc),
    .dec_redirect_valid(jal_valid), .dec_redirect_pc(jal_pc),
    .be_redirect_valid(1'b0), .be_redirect_pc('0)
  );

  decode #(.WIDTH(WIDTH)) u_decode (
    .clk, .reset, .flush(1'b0),
    .in_valid(f_valid), .in_ready(f_ready), .in_slot_valid(f_slot_valid),
    .in_inst(f_inst), .in_pc(f_pc),
    .out_valid(d_valid), .out_ready(d_ready), .out_uop(d_uop),
    .out_dep_rs1(dep_rs1), .out_dep_rs2(dep_rs2), .out_dep_rd(dep_rd),
    .redirect_valid(jal_valid), .redirect_pc(jal_pc), .out_slot_kill(slot_kill)
  );

  always #5 clk = ~clk;

  for (genvar g = 0; g < WIDTH; g++) begin : g_imem
    assign imem_rdata[g] = imem[imem_addr[g][9:2]];
  end

  // --- tiny assembler ------------------------------------------------------
  function automatic logic [31:0] addi(input logic [4:0] rd, input logic [11:0] imm);
    return {imm, 5'd0, 3'b000, rd, 7'b0010011};
  endfunction

  function automatic logic [31:0] jal(input logic [4:0] rd, input logic [20:0] off);
    return {off[20], off[10:1], off[11], off[19:12], rd, 7'b1101111};
  endfunction

  // Expected program order of the PCs that leave decode.
  logic [XLEN-1:0] expect_pc [N_EXPECT];
  int seen = 0;
  int cycles = 0;

  initial begin
    for (int i = 0; i < MEM_WORDS; i++) imem[i] = addi(5'd31, 12'hBAD); // wrong-path marker

    // 0x00..0x0C: straight line; 0x10: jal to 0x40 (slot 1 of the 2nd bundle)
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

    // Program order: 0,4,8,C,10, 40,44,48,4C, then again from 0.
    for (int i = 0; i < N_EXPECT; i++) begin
      case (i % 9)
        0: expect_pc[i] = 64'h00;  1: expect_pc[i] = 64'h04;  2: expect_pc[i] = 64'h08;
        3: expect_pc[i] = 64'h0C;  4: expect_pc[i] = 64'h10;  5: expect_pc[i] = 64'h40;
        6: expect_pc[i] = 64'h44;  7: expect_pc[i] = 64'h48;  default: expect_pc[i] = 64'h4C;
      endcase
    end
  end

  // Random back-pressure on decode's output.
  always @(negedge clk) d_ready <= ($urandom % 4) != 0;

  // Scoreboard: every surviving uop must be the next expected PC.
  always @(posedge clk) begin
    if (!reset && d_valid && d_ready) begin
      for (int k = 0; k < WIDTH; k++) begin
        uop_t u;
        u = d_uop[k];
        if (u.valid && seen < N_EXPECT) begin
          if (u.pc !== expect_pc[seen])
            $fatal(1, "uop %0d: pc = %h, expected %h (wrong-path instruction survived?)",
                   seen, u.pc, expect_pc[seen]);
          seen++;
        end
      end
    end
  end

  initial begin
    repeat (2) @(posedge clk);
    #1 reset = 1'b0;
    while (seen < N_EXPECT && cycles < 500) begin
      @(posedge clk);
      cycles++;
    end
    if (seen < N_EXPECT) $fatal(1, "only %0d of %0d instructions after %0d cycles", seen, N_EXPECT, cycles);
    $display("PASS fetch_decode_tb (WIDTH = %0d, %0d instructions in order, %0d cycles)",
             WIDTH, seen, cycles);
    $finish;
  end
endmodule
