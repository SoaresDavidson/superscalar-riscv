// Integration testbench: the whole core (rtl/core/core.sv) running a program
// fetched from instruction memory.
//
// The testbench plays only what the core leaves as ports:
//   - instruction memory: synchronous, one read port per slot. The main
//     program sits at RESET_PC; the trap handler at mtvec (0, the ROB reset
//     value); every other word is a NOP (ADDI x0, x0, 0), which commits
//     nothing visible.
//   - Memory: loads answer LSU_LAT cycles after the AGU, on lsu_resp; the
//     memory is read-only (store data has no path yet). The access size comes
//     from a table of ops by age, filled at ROB allocation: the Memory port
//     does not carry the size yet. A flush drops the loads in flight.
//   - Branch Unit: absent (br_req_ready = 0). The program has no branches.
//
// Program: the backend_tb program (dependencies inside a bundle, same
// register as source and destination, x0 as destination, loads feeding ALU
// work, out-of-order completion, RS back-pressure), then a misaligned LD.
// The LD raises an exception: the ROB flushes and redirects Fetch to mtvec.
// The instructions behind the LD are in flight when the flush comes and must
// never commit. The handler reads x20, which one of them overwrote
// speculatively, so it checks that rename recovered the committed mapping and
// that tags freed by the flush are reused correctly.
//
// Checks: the commit stream (rd and value, in program order) against a
// reference model; the number of loads and stores committed; exactly one
// flush, to mtvec; nothing commits after the handler; Fetch keeps running.
module core_tb #(
    parameter bit DEEP2   = 1'b0,
    parameter int LSU_LAT = 4
);
  import execute_pkg::*;
  import dispatch_pkg::*;

  localparam int    W        = 3;
  localparam int    MAX_CYC  = 3000;
  localparam xlen_t RESET_PC = 64'h0000_1000;
  localparam xlen_t MTVEC    = 64'h0;
  localparam int    IMEM_N   = 2048;           // words: 0x0000 to 0x1FFF
  localparam logic [31:0] NOP = 32'h0000_0013;

  logic clk = 1'b0, reset;
  initial forever #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // Core
  // ---------------------------------------------------------------------------
  logic [W-1:0][XLEN-1:0] imem_addr;
  logic [W-1:0][31:0]     imem_rdata;

  logic      br_req_valid, br_resp_ready;
  fu_req_t   br_req;

  logic      agu_resp_valid, agu_is_load;
  fu_resp_t  agu_resp;
  logic      lsu_valid, lsu_resp_ready;
  fu_resp_t  lsu_resp;
  logic [W-1:0] st_commit, ld_commit;
  logic      flush;

  logic [W-1:0] commit_valid;
  reg_t [W-1:0] commit_rd;
  tag_t [W-1:0] commit_tag;
  logic         rob_empty;

  core #(.W(W), .RESET_PC(RESET_PC), .DEEP2(DEEP2)) u_core (
      .clk, .reset,
      .imem_addr, .imem_rdata,
      .br_req_valid, .br_req_ready (1'b0), .br_req,
      .br_resp_valid (1'b0), .br_resp_ready, .br_resp ('0),
      .br_redirect   ('0),
      .agu_resp_valid, .agu_resp, .agu_is_load,
      .lsu_resp_valid (lsu_valid), .lsu_resp_ready, .lsu_resp,
      .st_commit, .ld_commit, .lsu_ready (1'b1),
      .flush,
      .commit_valid, .commit_rd, .commit_tag, .rob_empty
  );

  // ---------------------------------------------------------------------------
  // Instruction memory
  // ---------------------------------------------------------------------------
  logic [31:0] imem [IMEM_N];

  for (genvar k = 0; k < W; k++) begin : g_imem
    always @(posedge clk) imem_rdata[k] <= imem[(imem_addr[k] >> 2) % IMEM_N];
  end

  // ---------------------------------------------------------------------------
  // Memory model (read-only) and LSU model
  // ---------------------------------------------------------------------------
  function automatic logic [63:0] mem64(logic [63:0] a);
    logic [31:0] lo;
    lo = a[31:0] & 32'hFFFF_FFF8;
    return {32'h8000_0000 | (lo + 32'd4), 32'h9000_0000 | lo};
  endfunction

  function automatic logic [63:0] load_value(exec_op_t op, logic [63:0] a);
    logic [63:0] d;
    logic [31:0] w;
    d = mem64(a);
    w = a[2] ? d[63:32] : d[31:0];
    if (op == AGU_LW) return {{32{w[31]}}, w};
    return d;   // AGU_LD
  endfunction

  // Op of every instruction the ROB takes, by age: the size of the access.
  exec_op_t op_by_age [256];
  always @(posedge clk) begin
    for (int k = 0; k < W; k++) begin
      uop_t u;
      u = u_core.rob_uop[k];
      if (u_core.rob_alloc[k]) op_by_age[u_core.rob_age[k]] <= u.op;
    end
  end

  localparam int QN = 16;
  fu_resp_t q_resp [QN];
  int       q_due  [QN];
  int       q_head, q_tail, cyc;

  always @(posedge clk) begin
    if (reset) begin
      q_head <= 0; q_tail <= 0; cyc <= 0;
      lsu_valid <= 1'b0; lsu_resp <= '0;
    end else begin
      cyc <= cyc + 1;
      if (flush) begin
        q_head    <= q_tail;           // drop every load in flight
        lsu_valid <= 1'b0;
      end else begin
        if (agu_resp_valid && agu_is_load && !agu_resp.exception) begin
          fu_resp_t r;
          r        = agu_resp;
          r.result = load_value(exec_op_t'(op_by_age[agu_resp.age]), agu_resp.result);
          q_resp[q_tail % QN] <= r;
          q_due[q_tail % QN]  <= cyc + LSU_LAT;
          q_tail <= q_tail + 1;
        end
        if (q_head != q_tail && q_due[q_head % QN] <= cyc) begin
          lsu_valid <= 1'b1;
          lsu_resp  <= q_resp[q_head % QN];
          q_head    <= q_head + 1;
        end else begin
          lsu_valid <= 1'b0;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Encoders (RV64I)
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] enc_i(int imm, int rs1, int f3, int rd, logic [6:0] opc);
    return {12'(imm), 5'(rs1), 3'(f3), 5'(rd), opc};
  endfunction
  function automatic logic [31:0] enc_r(logic [6:0] f7, int rs2, int rs1, int f3, int rd, logic [6:0] opc);
    return {f7, 5'(rs2), 5'(rs1), 3'(f3), 5'(rd), opc};
  endfunction
  function automatic logic [31:0] enc_s(int imm, int rs2, int rs1, int f3);
    logic [11:0] i;
    i = 12'(imm);
    return {i[11:5], 5'(rs2), 5'(rs1), 3'(f3), i[4:0], 7'h23};
  endfunction

  function automatic logic [31:0] ADDI(int rd, int rs1, int imm); return enc_i(imm, rs1, 0, rd, 7'h13); endfunction
  function automatic logic [31:0] SLLI(int rd, int rs1, int sh);  return enc_i(sh & 63, rs1, 1, rd, 7'h13); endfunction
  function automatic logic [31:0] SRLI(int rd, int rs1, int sh);  return enc_i(sh & 63, rs1, 5, rd, 7'h13); endfunction
  function automatic logic [31:0] ADD (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 0, rd, 7'h33); endfunction
  function automatic logic [31:0] SUB (int rd, int rs1, int rs2); return enc_r(7'h20, rs2, rs1, 0, rd, 7'h33); endfunction
  function automatic logic [31:0] XOR (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 4, rd, 7'h33); endfunction
  function automatic logic [31:0] OR  (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 6, rd, 7'h33); endfunction
  function automatic logic [31:0] AND (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 7, rd, 7'h33); endfunction
  function automatic logic [31:0] SLT (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 2, rd, 7'h33); endfunction
  function automatic logic [31:0] ADDW(int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 0, rd, 7'h3B); endfunction
  function automatic logic [31:0] LUI (int rd, int imm20);        return {20'(imm20), 5'(rd), 7'h37}; endfunction
  function automatic logic [31:0] LD  (int rd, int rs1, int imm); return enc_i(imm, rs1, 3, rd, 7'h03); endfunction
  function automatic logic [31:0] LW  (int rd, int rs1, int imm); return enc_i(imm, rs1, 2, rd, 7'h03); endfunction
  function automatic logic [31:0] SD  (int rs2, int rs1, int imm); return enc_s(imm, rs2, rs1, 3); endfunction

  // ---------------------------------------------------------------------------
  // Programs. main: everything up to and including the misaligned LD (index
  // EXC), then the wrong path. handler: at mtvec.
  // ---------------------------------------------------------------------------
  localparam int NMAIN = 47;
  localparam int EXC   = 42;            // index of the misaligned LD
  localparam int NHAND = 3;
  logic [31:0] main_prog [NMAIN];
  logic [31:0] hand_prog [NHAND];

  // ---------------------------------------------------------------------------
  // Reference model: runs main up to EXC (excluded), then the handler, and
  // lists every (rd, value) the commit stream must show.
  // ---------------------------------------------------------------------------
  localparam int NEXP_MAX = NMAIN + NHAND;
  logic [63:0] x [32];
  int          exp_rd  [NEXP_MAX];
  logic [63:0] exp_val [NEXP_MAX];
  int          n_exp, n_st, n_ld;

  function automatic logic [63:0] sext12(logic [31:0] i);
    return {{52{i[31]}}, i[31:20]};
  endfunction

  task automatic step(input logic [31:0] i);
    logic [63:0] v, a, b2, imm;
    int rd, rs1, rs2;
    logic [6:0] opc;
    logic [2:0] f3;
    logic writes;
    opc  = i[6:0];  f3 = i[14:12];
    rd   = i[11:7]; rs1 = i[19:15]; rs2 = i[24:20];
    a    = x[rs1];  b2 = x[rs2];
    imm  = sext12(i);
    writes = 1'b1;
    v      = '0;
    case (opc)
      7'h13: case (f3)
               3'd0: v = a + imm;
               3'd1: v = a << i[25:20];
               3'd5: v = a >> i[25:20];
               default: $fatal(1, "reference: OP-IMM f3 %0d not modelled", f3);
             endcase
      7'h33: case ({i[30], f3})
               4'b0000: v = a + b2;
               4'b1000: v = a - b2;
               4'b0100: v = a ^ b2;
               4'b0110: v = a | b2;
               4'b0111: v = a & b2;
               4'b0010: v = ($signed(a) < $signed(b2)) ? 64'd1 : 64'd0;
               default: $fatal(1, "reference: OP not modelled");
             endcase
      7'h3B: begin logic [31:0] s; s = a[31:0] + b2[31:0]; v = {{32{s[31]}}, s}; end
      7'h37: v = {{32{i[31]}}, i[31:12], 12'h000};
      7'h03: begin
               n_ld++;
               v = load_value(exec_op_t'((f3 == 3'd2) ? AGU_LW : AGU_LD), a + imm);
             end
      7'h23: begin writes = 1'b0; n_st++; end
      default: $fatal(1, "reference: opcode %h not modelled", opc);
    endcase
    if (writes && rd != 0) begin
      x[rd] = v;
      exp_rd[n_exp]  = rd;
      exp_val[n_exp] = v;
      n_exp++;
    end
  endtask

  task automatic reference();
    for (int r = 0; r < 32; r++) x[r] = '0;
    n_exp = 0; n_st = 0; n_ld = 0;
    for (int p = 0; p < EXC; p++) step(main_prog[p]);
    for (int p = 0; p < NHAND; p++) step(hand_prog[p]);
  endtask

  // ---------------------------------------------------------------------------
  // Monitors
  // ---------------------------------------------------------------------------
  logic [63:0] val_by_tag [PRF_ENTRIES];   // last value written to each tag
  int n_commit_rd, n_commit_st, n_commit_ld, n_flush;
  logic seen_rs_stall, seen_int_full;

  // Sample on the falling edge, when every registered output is stable.
  always @(negedge clk) begin
    if (!reset) begin
      for (int p = 0; p < 3; p++)
        if (u_core.wb_valid[p]) val_by_tag[u_core.wb_tag[p]] = u_core.wb_data[p];

      if (flush) begin
        n_flush++;
        if (u_core.be_redirect_pc !== MTVEC)
          $fatal(1, "flush redirects to %h, expected mtvec %h",
                 u_core.be_redirect_pc, MTVEC);
      end

      for (int k = 0; k < W; k++) begin
        if (commit_valid[k]) begin
          if (n_commit_rd >= n_exp)
            $fatal(1, "extra register commit: x%0d (cycle %0d)", commit_rd[k], cyc);
          if (commit_rd[k] !== 5'(exp_rd[n_commit_rd]))
            $fatal(1, "commit %0d: rd = x%0d, expected x%0d",
                   n_commit_rd, commit_rd[k], exp_rd[n_commit_rd]);
          if (val_by_tag[commit_tag[k]] !== exp_val[n_commit_rd])
            $fatal(1, "commit %0d (x%0d): value %h, expected %h",
                   n_commit_rd, commit_rd[k], val_by_tag[commit_tag[k]],
                   exp_val[n_commit_rd]);
          n_commit_rd++;
        end
        if (st_commit[k]) n_commit_st++;
        if (ld_commit[k]) n_commit_ld++;
      end

      if (u_core.dec_valid && !u_core.u_dispatch.rs_ok) seen_rs_stall = 1'b1;
      if (u_core.int_free == 4'd0) seen_int_full = 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Program and run
  // ---------------------------------------------------------------------------
  initial begin
    int p;
    p = 0;
    // Bundle 0: dependencies inside the bundle (x2 needs x1, x3 needs both).
    main_prog[p++] = ADDI(1, 0, 5);
    main_prog[p++] = ADDI(2, 1, 3);
    main_prog[p++] = ADD (3, 1, 2);
    // Same register as source and destination; x0 as destination.
    main_prog[p++] = ADDI(1, 1, 1);
    main_prog[p++] = ADDI(0, 3, 7);          // writes nothing
    main_prog[p++] = SUB (4, 3, 1);
    // Base address of the data area, and a 32-bit overflow.
    main_prog[p++] = LUI (10, 32'h00008);    // x10 = 0x8000 = BASE
    main_prog[p++] = LUI (5, 32'h7FFFF);
    main_prog[p++] = ADDW(6, 5, 5);          // wraps and sign-extends
    // Eight loads, more than the 4 RS MEM entries; slow answers.
    main_prog[p++] = LD  (11, 10, 0);
    main_prog[p++] = LD  (12, 10, 8);
    main_prog[p++] = LW  (13, 10, 4);        // high half, negative: sign-extends
    main_prog[p++] = LD  (14, 10, 16);
    main_prog[p++] = LW  (15, 10, 24);
    main_prog[p++] = LD  (16, 10, 32);
    main_prog[p++] = LD  (17, 10, 40);
    main_prog[p++] = LD  (18, 10, 48);
    main_prog[p++] = ADD (19, 11, 12);       // waits for two loads
    // ALU work independent of the loads finishes first (out of order).
    main_prog[p++] = XOR (20, 3, 4);
    main_prog[p++] = OR  (21, 1, 2);
    main_prog[p++] = AND (22, 3, 2);
    // Stores and a load whose base comes from a load.
    main_prog[p++] = SD  (19, 10, 64);
    main_prog[p++] = SRLI(23, 11, 60);       // small value from a load
    main_prog[p++] = SLLI(24, 23, 3);
    main_prog[p++] = ADD (25, 10, 24);
    main_prog[p++] = LD  (26, 25, 0);        // address depends on a load
    main_prog[p++] = SLT (27, 13, 0);        // negative lw result < 0
    // A long chain, to keep tags and ROB rows in flight.
    main_prog[p++] = ADD (28, 26, 19);
    main_prog[p++] = ADDI(28, 28, 1);
    main_prog[p++] = ADDI(28, 28, 2);
    main_prog[p++] = ADDI(28, 28, 3);
    main_prog[p++] = ADD (29, 28, 27);
    main_prog[p++] = SUB (30, 29, 6);
    main_prog[p++] = SD  (30, 10, 72);
    main_prog[p++] = ADDI(1, 1, 10);
    main_prog[p++] = ADDI(2, 2, 20);
    main_prog[p++] = ADDI(3, 3, 30);
    main_prog[p++] = ADD (31, 1, 2);
    main_prog[p++] = ADD (31, 31, 3);
    main_prog[p++] = XOR (31, 31, 30);
    main_prog[p++] = LD  (7, 10, 56);
    main_prog[p++] = ADD (8, 7, 31);
    // The exception: an 8-byte load from an address that is a multiple of 4.
    if (p != EXC) $fatal(1, "main program: EXC = %0d, but the LD is at %0d", EXC, p);
    main_prog[p++] = LD  (9, 10, 4);
    // Wrong path: in flight when the flush comes, must never commit.
    main_prog[p++] = ADDI(20, 0, 1);         // overwrites x20 speculatively
    main_prog[p++] = ADDI(21, 0, 2);
    main_prog[p++] = LD  (22, 10, 0);
    main_prog[p++] = ADD (9, 20, 21);
    if (p != NMAIN) $fatal(1, "main program has %0d instructions, NMAIN = %0d", p, NMAIN);

    // Trap handler at mtvec: reads the committed x20, not the wrong-path one.
    hand_prog[0] = ADDI(9, 0, 12'h077);
    hand_prog[1] = ADDI(20, 20, 5);
    hand_prog[2] = ADD (21, 20, 9);

    for (int a = 0; a < IMEM_N; a++) imem[a] = NOP;
    for (int k = 0; k < NMAIN; k++) imem[(RESET_PC >> 2) + k] = main_prog[k];
    for (int k = 0; k < NHAND; k++) imem[(MTVEC >> 2) + k] = hand_prog[k];

    reference();

    n_commit_rd = 0; n_commit_st = 0; n_commit_ld = 0; n_flush = 0;
    seen_rs_stall = 1'b0; seen_int_full = 1'b0;

    reset = 1'b1;
    repeat (2) @(posedge clk);
    #1 reset = 1'b0;

    while (n_commit_rd < n_exp && cyc < MAX_CYC) @(posedge clk);
    if (n_commit_rd < n_exp)
      $fatal(1, "timeout: %0d of %0d register commits in %0d cycles",
             n_commit_rd, n_exp, cyc);
    // The handler is followed by NOPs: nothing else may commit.
    repeat (40) @(posedge clk);
    @(negedge clk);

    if (n_commit_rd !== n_exp)
      $fatal(1, "%0d register commits, expected %0d", n_commit_rd, n_exp);
    if (n_flush !== 1)        $fatal(1, "%0d flushes, expected 1", n_flush);
    if (n_commit_st !== n_st)
      $fatal(1, "%0d stores committed, expected %0d", n_commit_st, n_st);
    if (n_commit_ld !== n_ld)
      $fatal(1, "%0d loads committed, expected %0d", n_commit_ld, n_ld);
    // NOPs keep flowing behind the handler, so the RS and the ROB are never
    // empty at a fixed instant; check instead that the core kept running.
    if (imem_addr[0] <= MTVEC + 64'(4 * NHAND))
      $fatal(1, "fetch stuck at %h after the handler", imem_addr[0]);
    if (!seen_rs_stall)      $fatal(1, "the RS never refused a bundle: back-pressure not exercised");
    if (!seen_int_full)      $fatal(1, "the RS INT never filled");

    $display("PASS core_tb DEEP2=%0d LSU_LAT=%0d: %0d register commits (%0d loads, %0d stores), 1 flush, %0d cycles",
             DEEP2, LSU_LAT, n_exp, n_ld, n_st, cyc);
    $finish;
  end

endmodule
