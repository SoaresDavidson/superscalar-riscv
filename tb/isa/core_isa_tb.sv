// ISA suite: the whole core (rtl/core/core.sv) running one small program per
// RV64I feature, each checked against a reference ISA model in this file.
//
// Unlike the other testbenches, a failing program does NOT stop the run. Each
// program runs from reset on its own; the suite reports every program as `ok`
// or `FAIL` with the reason, and ends with $fatal if any failed. The failures
// are the point: they list what the core cannot run yet (Branch Unit, store
// data path, ...). This is why the suite is `make test-isa` and stays out of
// `make test` and CI.
//
// The testbench plays only what the core leaves as ports, and only as much as
// those ports allow:
//   - instruction memory: synchronous, one read port per slot. Program at
//     RESET_PC, every other word a NOP (ADDI x0, x0, 0). mtvec (0) also holds
//     NOPs: after a trap nothing visible may commit.
//   - Memory: loads answer LSU_LAT cycles after the AGU, read from a byte
//     array. The port carries neither the access size nor the store data, so
//     the size comes from a table of ops by age (filled at ROB allocation, as
//     in core_tb) and stores never reach the array.
//   - Branch Unit: absent (br_req_ready = 0), as the core expects without one.
//
// Per program, the checks are: the register commit stream (rd and value, in
// program order) against the reference; no commit after the reference stops
// (end of program or trap); the number of loads and stores committed; the
// final data memory. A program that stops making progress for IDLE_MAX
// cycles is reported as stuck, with the first instruction after the last
// commit -- usually the one the core cannot execute.
//
// Trap behaviour checked here is only what RV64I fixes and decision 10 leaves
// open: the trapping instruction and everything after it never commit. Where
// the core goes after the trap (handler or halt) is not checked.
module core_isa_tb #(
    parameter bit DEEP2   = 1'b0,
    parameter int LSU_LAT = 4
);
  import execute_pkg::*;
  import dispatch_pkg::*;

  localparam int    W         = 3;
  localparam xlen_t RESET_PC  = 64'h0000_4000;
  localparam int    IMEM_N    = 8192;          // words: 0x0000 to 0x7FFF
  localparam xlen_t DBASE     = 64'h0000_8000; // data memory base
  localparam int    DMEM_N    = 1024;          // bytes
  localparam int    PROG_MAX  = 256;
  localparam int    TRACE_MAX = 2048;
  localparam int    IDLE_MAX  = 400;           // cycles without a commit: stuck
  localparam int    DRAIN     = 150;           // cycles watched after the last commit
  localparam int    CYC_MAX   = 8000;          // per program
  localparam logic [31:0] NOP = 32'h0000_0013;

  logic clk = 1'b0, reset = 1'b1;
  initial forever #5 clk = ~clk;

  int cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

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
  // Data memories: ref_mem belongs to the reference model, dut_mem to the
  // core's Memory model. Same initial contents.
  // ---------------------------------------------------------------------------
  logic [7:0] ref_mem [DMEM_N];
  logic [7:0] dut_mem [DMEM_N];

  function automatic logic in_dmem(xlen_t a, int size);
    return a >= DBASE && a + xlen_t'(size) <= DBASE + xlen_t'(DMEM_N);
  endfunction

  // Sign- or zero-extends the low `size` bytes of raw.
  function automatic xlen_t extend(xlen_t raw, int size, logic uns);
    case (size)
      1: return uns ? {56'd0, raw[7:0]}  : {{56{raw[7]}},  raw[7:0]};
      2: return uns ? {48'd0, raw[15:0]} : {{48{raw[15]}}, raw[15:0]};
      4: return uns ? {32'd0, raw[31:0]} : {{32{raw[31]}}, raw[31:0]};
      default: return raw;
    endcase
  endfunction

  function automatic xlen_t ref_rd(xlen_t a, int size, logic uns);
    xlen_t raw;
    int    base;
    raw  = '0;
    base = int'(a - DBASE);
    for (int b = 0; b < size; b++) raw[8*b +: 8] = ref_mem[base + b];
    return extend(raw, size, uns);
  endfunction

  task automatic ref_wr(xlen_t a, int size, xlen_t d);
    int base;
    base = int'(a - DBASE);
    for (int b = 0; b < size; b++) ref_mem[base + b] = d[8*b +: 8];
  endtask

  // Wrong-path loads may compute any address: outside the array they read 0.
  function automatic xlen_t dut_rd(xlen_t a, int size, logic uns);
    xlen_t raw;
    int    base;
    raw = '0;
    if (in_dmem(a, size)) begin
      base = int'(a - DBASE);
      for (int b = 0; b < size; b++) raw[8*b +: 8] = dut_mem[base + b];
    end
    return extend(raw, size, uns);
  endfunction

  function automatic int op_size(exec_op_t op);
    case (op)
      AGU_LB, AGU_LBU, AGU_SB: return 1;
      AGU_LH, AGU_LHU, AGU_SH: return 2;
      AGU_LW, AGU_LWU, AGU_SW: return 4;
      default:                 return 8;
    endcase
  endfunction

  function automatic logic op_uns(exec_op_t op);
    return op == AGU_LBU || op == AGU_LHU || op == AGU_LWU;
  endfunction

  // ---------------------------------------------------------------------------
  // Memory (LSU) model: loads only. Stores reach the AGU and commit, but the
  // port has no store data, so dut_mem never changes.
  // ---------------------------------------------------------------------------
  exec_op_t op_by_age [2**AGE_W];
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
  int       q_head, q_tail;

  always @(posedge clk) begin
    if (reset) begin
      q_head <= 0; q_tail <= 0;
      lsu_valid <= 1'b0; lsu_resp <= '0;
    end else if (flush) begin
      q_head    <= q_tail;               // drop every load in flight
      lsu_valid <= 1'b0;
    end else begin
      if (agu_resp_valid && agu_is_load && !agu_resp.exception) begin
        fu_resp_t r;
        exec_op_t op;
        r  = agu_resp;
        op = op_by_age[agu_resp.age];
        r.result = dut_rd(agu_resp.result, op_size(op), op_uns(op));
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
  function automatic logic [31:0] enc_b(int off, int rs1, int rs2, int f3);
    logic [12:0] i;
    i = 13'(off);
    return {i[12], i[10:5], 5'(rs2), 5'(rs1), 3'(f3), i[4:1], i[11], 7'h63};
  endfunction
  function automatic logic [31:0] enc_j(int off, int rd);
    logic [20:0] i;
    i = 21'(off);
    return {i[20], i[10:1], i[11], i[19:12], 5'(rd), 7'h6F};
  endfunction
  function automatic logic [31:0] enc_sh(logic [5:0] f6, int sh, int rs1, int f3, int rd, logic [6:0] opc);
    return {f6, 6'(sh), 5'(rs1), 3'(f3), 5'(rd), opc};
  endfunction

  // Offsets of branches and jumps are in BYTES.
  function automatic logic [31:0] LUI  (int rd, int imm20);        return {20'(imm20), 5'(rd), 7'h37}; endfunction
  function automatic logic [31:0] AUIPC(int rd, int imm20);        return {20'(imm20), 5'(rd), 7'h17}; endfunction
  function automatic logic [31:0] JAL  (int rd, int off);          return enc_j(off, rd); endfunction
  function automatic logic [31:0] JALR (int rd, int rs1, int imm); return enc_i(imm, rs1, 0, rd, 7'h67); endfunction
  function automatic logic [31:0] BEQ  (int rs1, int rs2, int off); return enc_b(off, rs1, rs2, 0); endfunction
  function automatic logic [31:0] BNE  (int rs1, int rs2, int off); return enc_b(off, rs1, rs2, 1); endfunction
  function automatic logic [31:0] BLT  (int rs1, int rs2, int off); return enc_b(off, rs1, rs2, 4); endfunction
  function automatic logic [31:0] BGE  (int rs1, int rs2, int off); return enc_b(off, rs1, rs2, 5); endfunction
  function automatic logic [31:0] BLTU (int rs1, int rs2, int off); return enc_b(off, rs1, rs2, 6); endfunction
  function automatic logic [31:0] BGEU (int rs1, int rs2, int off); return enc_b(off, rs1, rs2, 7); endfunction
  function automatic logic [31:0] LB   (int rd, int rs1, int imm); return enc_i(imm, rs1, 0, rd, 7'h03); endfunction
  function automatic logic [31:0] LH   (int rd, int rs1, int imm); return enc_i(imm, rs1, 1, rd, 7'h03); endfunction
  function automatic logic [31:0] LW   (int rd, int rs1, int imm); return enc_i(imm, rs1, 2, rd, 7'h03); endfunction
  function automatic logic [31:0] LD   (int rd, int rs1, int imm); return enc_i(imm, rs1, 3, rd, 7'h03); endfunction
  function automatic logic [31:0] LBU  (int rd, int rs1, int imm); return enc_i(imm, rs1, 4, rd, 7'h03); endfunction
  function automatic logic [31:0] LHU  (int rd, int rs1, int imm); return enc_i(imm, rs1, 5, rd, 7'h03); endfunction
  function automatic logic [31:0] LWU  (int rd, int rs1, int imm); return enc_i(imm, rs1, 6, rd, 7'h03); endfunction
  function automatic logic [31:0] SB   (int rs2, int rs1, int imm); return enc_s(imm, rs2, rs1, 0); endfunction
  function automatic logic [31:0] SH   (int rs2, int rs1, int imm); return enc_s(imm, rs2, rs1, 1); endfunction
  function automatic logic [31:0] SW   (int rs2, int rs1, int imm); return enc_s(imm, rs2, rs1, 2); endfunction
  function automatic logic [31:0] SD   (int rs2, int rs1, int imm); return enc_s(imm, rs2, rs1, 3); endfunction
  function automatic logic [31:0] ADDI (int rd, int rs1, int imm); return enc_i(imm, rs1, 0, rd, 7'h13); endfunction
  function automatic logic [31:0] SLTI (int rd, int rs1, int imm); return enc_i(imm, rs1, 2, rd, 7'h13); endfunction
  function automatic logic [31:0] SLTIU(int rd, int rs1, int imm); return enc_i(imm, rs1, 3, rd, 7'h13); endfunction
  function automatic logic [31:0] XORI (int rd, int rs1, int imm); return enc_i(imm, rs1, 4, rd, 7'h13); endfunction
  function automatic logic [31:0] ORI  (int rd, int rs1, int imm); return enc_i(imm, rs1, 6, rd, 7'h13); endfunction
  function automatic logic [31:0] ANDI (int rd, int rs1, int imm); return enc_i(imm, rs1, 7, rd, 7'h13); endfunction
  function automatic logic [31:0] SLLI (int rd, int rs1, int sh);  return enc_sh(6'h00, sh, rs1, 1, rd, 7'h13); endfunction
  function automatic logic [31:0] SRLI (int rd, int rs1, int sh);  return enc_sh(6'h00, sh, rs1, 5, rd, 7'h13); endfunction
  function automatic logic [31:0] SRAI (int rd, int rs1, int sh);  return enc_sh(6'h10, sh, rs1, 5, rd, 7'h13); endfunction
  function automatic logic [31:0] ADDIW(int rd, int rs1, int imm); return enc_i(imm, rs1, 0, rd, 7'h1B); endfunction
  function automatic logic [31:0] SLLIW(int rd, int rs1, int sh);  return enc_r(7'h00, sh, rs1, 1, rd, 7'h1B); endfunction
  function automatic logic [31:0] SRLIW(int rd, int rs1, int sh);  return enc_r(7'h00, sh, rs1, 5, rd, 7'h1B); endfunction
  function automatic logic [31:0] SRAIW(int rd, int rs1, int sh);  return enc_r(7'h20, sh, rs1, 5, rd, 7'h1B); endfunction
  function automatic logic [31:0] ADD  (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 0, rd, 7'h33); endfunction
  function automatic logic [31:0] SUB  (int rd, int rs1, int rs2); return enc_r(7'h20, rs2, rs1, 0, rd, 7'h33); endfunction
  function automatic logic [31:0] SLL  (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 1, rd, 7'h33); endfunction
  function automatic logic [31:0] SLT  (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 2, rd, 7'h33); endfunction
  function automatic logic [31:0] SLTU (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 3, rd, 7'h33); endfunction
  function automatic logic [31:0] XOR  (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 4, rd, 7'h33); endfunction
  function automatic logic [31:0] SRL  (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 5, rd, 7'h33); endfunction
  function automatic logic [31:0] SRA  (int rd, int rs1, int rs2); return enc_r(7'h20, rs2, rs1, 5, rd, 7'h33); endfunction
  function automatic logic [31:0] OR   (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 6, rd, 7'h33); endfunction
  function automatic logic [31:0] AND  (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 7, rd, 7'h33); endfunction
  function automatic logic [31:0] ADDW (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 0, rd, 7'h3B); endfunction
  function automatic logic [31:0] SUBW (int rd, int rs1, int rs2); return enc_r(7'h20, rs2, rs1, 0, rd, 7'h3B); endfunction
  function automatic logic [31:0] SLLW (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 1, rd, 7'h3B); endfunction
  function automatic logic [31:0] SRLW (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 5, rd, 7'h3B); endfunction
  function automatic logic [31:0] SRAW (int rd, int rs1, int rs2); return enc_r(7'h20, rs2, rs1, 5, rd, 7'h3B); endfunction
  function automatic logic [31:0] MUL  (int rd, int rs1, int rs2); return enc_r(7'h01, rs2, rs1, 0, rd, 7'h33); endfunction
  localparam logic [31:0] FENCE   = 32'h0FF0_000F;   // fence iorw, iorw
  localparam logic [31:0] FENCE_I = 32'h0000_100F;
  localparam logic [31:0] ECALL   = 32'h0000_0073;
  localparam logic [31:0] EBREAK  = 32'h0010_0073;

  // Mnemonic only, for messages.
  function automatic string mn(logic [31:0] i);
    logic [2:0] f3;
    logic       alt;
    f3  = i[14:12];
    alt = i[30];
    case (i[6:0])
      7'h37: return "LUI";
      7'h17: return "AUIPC";
      7'h6F: return "JAL";
      7'h67: return "JALR";
      7'h63: case (f3)
               3'd0: return "BEQ";  3'd1: return "BNE";
               3'd4: return "BLT";  3'd5: return "BGE";
               3'd6: return "BLTU"; 3'd7: return "BGEU";
               default: return "BRANCH?";
             endcase
      7'h03: case (f3)
               3'd0: return "LB";  3'd1: return "LH";  3'd2: return "LW";
               3'd3: return "LD";  3'd4: return "LBU"; 3'd5: return "LHU";
               3'd6: return "LWU"; default: return "LOAD?";
             endcase
      7'h23: case (f3)
               3'd0: return "SB"; 3'd1: return "SH";
               3'd2: return "SW"; 3'd3: return "SD";
               default: return "STORE?";
             endcase
      7'h13: case (f3)
               3'd0: return (i == NOP) ? "NOP" : "ADDI";
               3'd1: return "SLLI";  3'd2: return "SLTI";
               3'd3: return "SLTIU"; 3'd4: return "XORI";
               3'd5: return alt ? "SRAI" : "SRLI";
               3'd6: return "ORI";   default: return "ANDI";
             endcase
      7'h1B: case (f3)
               3'd0: return "ADDIW"; 3'd1: return "SLLIW";
               3'd5: return alt ? "SRAIW" : "SRLIW";
               default: return "OP-IMM-32?";
             endcase
      7'h33: begin
               if (i[31:25] == 7'h01) return "MUL/DIV (M extension)";
               case (f3)
                 3'd0: return alt ? "SUB" : "ADD";
                 3'd1: return "SLL";  3'd2: return "SLT";
                 3'd3: return "SLTU"; 3'd4: return "XOR";
                 3'd5: return alt ? "SRA" : "SRL";
                 3'd6: return "OR";   default: return "AND";
               endcase
             end
      7'h3B: case (f3)
               3'd0: return alt ? "SUBW" : "ADDW";
               3'd1: return "SLLW";
               3'd5: return alt ? "SRAW" : "SRLW";
               default: return "OP-32?";
             endcase
      7'h0F: return (f3 == 3'd1) ? "FENCE.I" : "FENCE";
      7'h73: return (i == ECALL) ? "ECALL" : (i == EBREAK) ? "EBREAK" : "SYSTEM";
      default: return "???";
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Program under test
  // ---------------------------------------------------------------------------
  logic [31:0] prog [PROG_MAX];
  int          nprog;
  string       tname, tuses;

  task automatic emit(logic [31:0] i);
    if (nprog >= PROG_MAX) $fatal(1, "programa %s maior que PROG_MAX", tname);
    prog[nprog] = i;
    nprog++;
  endtask

  // ---------------------------------------------------------------------------
  // Reference model (RV64I). Runs from RESET_PC until the pc leaves the
  // program or an instruction traps. Records every instruction it runs, and
  // every (rd, value) the commit stream must show.
  // ---------------------------------------------------------------------------
  xlen_t       x [32];
  xlen_t       rpc;
  xlen_t       tr_pc   [TRACE_MAX];
  logic [31:0] tr_inst [TRACE_MAX];
  int          n_tr;
  int          exp_rd  [TRACE_MAX];
  xlen_t       exp_val [TRACE_MAX];
  int          exp_tr  [TRACE_MAX];     // trace index of each expected commit
  int          n_exp, n_st, n_ld;
  logic        ref_trap;
  string       ref_trap_why;
  string       ref_end_note;            // appended to "extra commit" messages

  task automatic step();
    logic [31:0] i, w;
    logic [6:0]  opc, f7;
    logic [2:0]  f3;
    xlen_t       a, b, imm_i, imm_s, imm_b, imm_u, imm_j, v, npc, addr;
    int          rd, rs1, rs2, size;
    logic        wr, trap, take;

    i   = imem[int'((rpc >> 2) % IMEM_N)];
    opc = i[6:0]; f3 = i[14:12]; f7 = i[31:25];
    rd  = i[11:7]; rs1 = i[19:15]; rs2 = i[24:20];
    a   = x[rs1]; b = x[rs2];
    imm_i = {{52{i[31]}}, i[31:20]};
    imm_s = {{52{i[31]}}, i[31:25], i[11:7]};
    imm_b = {{51{i[31]}}, i[31], i[7], i[30:25], i[11:8], 1'b0};
    imm_u = {{32{i[31]}}, i[31:12], 12'h000};
    imm_j = {{43{i[31]}}, i[31], i[19:12], i[20], i[30:21], 1'b0};

    tr_pc[n_tr]   = rpc;
    tr_inst[n_tr] = i;

    npc  = rpc + 4;
    v    = '0;
    wr   = 1'b0;
    trap = 1'b0;
    take = 1'b0;
    size = 8;

    case (opc)
      7'h37: begin v = imm_u; wr = 1'b1; end
      7'h17: begin v = rpc + imm_u; wr = 1'b1; end
      7'h6F: begin v = rpc + 4; npc = rpc + imm_j; wr = 1'b1; end
      7'h67: if (f3 != 3'd0) trap = 1'b1;
             else begin v = rpc + 4; npc = (a + imm_i) & ~xlen_t'(1); wr = 1'b1; end
      7'h63: begin
               case (f3)
                 3'd0: take = a == b;
                 3'd1: take = a != b;
                 3'd4: take = $signed(a) <  $signed(b);
                 3'd5: take = $signed(a) >= $signed(b);
                 3'd6: take = a <  b;
                 3'd7: take = a >= b;
                 default: trap = 1'b1;
               endcase
               if (take) npc = rpc + imm_b;
             end
      7'h03: begin
               addr = a + imm_i;
               case (f3)
                 3'd0, 3'd4: size = 1;
                 3'd1, 3'd5: size = 2;
                 3'd2, 3'd6: size = 4;
                 3'd3:       size = 8;
                 default:    trap = 1'b1;
               endcase
               if (!trap && (addr % xlen_t'(size)) != 0) trap = 1'b1;
               if (!trap) begin
                 if (!in_dmem(addr, size))
                   $fatal(1, "%s: load da referência em %h fora da memória de dados", tname, addr);
                 v  = ref_rd(addr, size, f3[2]);
                 wr = 1'b1;
                 n_ld++;
               end
             end
      7'h23: begin
               addr = a + imm_s;
               case (f3)
                 3'd0: size = 1; 3'd1: size = 2; 3'd2: size = 4; 3'd3: size = 8;
                 default: trap = 1'b1;
               endcase
               if (!trap && (addr % xlen_t'(size)) != 0) trap = 1'b1;
               if (!trap) begin
                 if (!in_dmem(addr, size))
                   $fatal(1, "%s: store da referência em %h fora da memória de dados", tname, addr);
                 ref_wr(addr, size, b);
                 n_st++;
               end
             end
      7'h13: begin
               wr = 1'b1;
               case (f3)
                 3'd0: v = a + imm_i;
                 3'd1: if (i[31:26] != 6'h00) trap = 1'b1; else v = a << i[25:20];
                 3'd2: v = ($signed(a) < $signed(imm_i)) ? 64'd1 : 64'd0;
                 3'd3: v = (a < imm_i) ? 64'd1 : 64'd0;
                 3'd4: v = a ^ imm_i;
                 3'd5: if (i[31:26] == 6'h00)      v = a >> i[25:20];
                       else if (i[31:26] == 6'h10) v = $signed(a) >>> i[25:20];
                       else trap = 1'b1;
                 3'd6: v = a | imm_i;
                 default: v = a & imm_i;
               endcase
             end
      7'h1B: begin
               wr = 1'b1;
               case (f3)
                 3'd0: w = a[31:0] + imm_i[31:0];
                 3'd1: if (f7 != 7'h00) trap = 1'b1; else w = a[31:0] << i[24:20];
                 3'd5: if (f7 == 7'h00)      w = a[31:0] >> i[24:20];
                       else if (f7 == 7'h20) w = $signed(a[31:0]) >>> i[24:20];
                       else trap = 1'b1;
                 default: trap = 1'b1;
               endcase
               v = {{32{w[31]}}, w};
             end
      7'h33: begin
               wr = 1'b1;
               if (f7 == 7'h00) begin
                 case (f3)
                   3'd0: v = a + b;
                   3'd1: v = a << b[5:0];
                   3'd2: v = ($signed(a) < $signed(b)) ? 64'd1 : 64'd0;
                   3'd3: v = (a < b) ? 64'd1 : 64'd0;
                   3'd4: v = a ^ b;
                   3'd5: v = a >> b[5:0];
                   3'd6: v = a | b;
                   default: v = a & b;
                 endcase
               end else if (f7 == 7'h20 && f3 == 3'd0) v = a - b;
               else if (f7 == 7'h20 && f3 == 3'd5)     v = $signed(a) >>> b[5:0];
               else trap = 1'b1;                       // MUL/DIV included
             end
      7'h3B: begin
               wr = 1'b1;
               if (f7 == 7'h00 && f3 == 3'd0)      w = a[31:0] + b[31:0];
               else if (f7 == 7'h20 && f3 == 3'd0) w = a[31:0] - b[31:0];
               else if (f7 == 7'h00 && f3 == 3'd1) w = a[31:0] << b[4:0];
               else if (f7 == 7'h00 && f3 == 3'd5) w = a[31:0] >> b[4:0];
               else if (f7 == 7'h20 && f3 == 3'd5) w = $signed(a[31:0]) >>> b[4:0];
               else trap = 1'b1;
               v = {{32{w[31]}}, w};
             end
      7'h0F: if (f3 != 3'd0 && f3 != 3'd1) trap = 1'b1;   // FENCE: no effect here
      default: trap = 1'b1;                                // ECALL, EBREAK, CSR, illegal
    endcase

    n_tr++;
    if (trap) begin
      ref_trap     = 1'b1;
      ref_trap_why = $sformatf("%s em %h", mn(i), rpc);
    end else begin
      if (wr && rd != 0) begin
        x[rd] = v;
        exp_rd[n_exp]  = rd;
        exp_val[n_exp] = v;
        exp_tr[n_exp]  = n_tr - 1;
        n_exp++;
      end
      rpc = npc;
    end
  endtask

  task automatic reference();
    for (int r = 0; r < 32; r++) x[r] = '0;
    rpc = RESET_PC;
    n_tr = 0; n_exp = 0; n_st = 0; n_ld = 0;
    ref_trap = 1'b0; ref_trap_why = "";
    while (!ref_trap && rpc >= RESET_PC && rpc < RESET_PC + xlen_t'(4 * nprog)) begin
      if (n_tr >= TRACE_MAX) $fatal(1, "%s: a referência executou %0d instruções, laço infinito?", tname, n_tr);
      step();
    end
    ref_end_note = "";
    if (ref_trap) ref_end_note = {" (devia ter gerado trap em ", ref_trap_why, ")"};
  endtask

  // ---------------------------------------------------------------------------
  // Monitor
  // ---------------------------------------------------------------------------
  xlen_t val_by_tag [PRF_ENTRIES];      // last value written to each tag
  logic  running = 1'b0, failed;
  string fail_msg;
  int    n_commit_rd, n_commit_st, n_commit_ld, last_evt;

  task automatic fail(string s);
    if (!failed) begin
      failed   = 1'b1;
      fail_msg = s;
    end
  endtask

  function automatic string where(int t);
    return $sformatf("%s em %h", mn(tr_inst[t]), tr_pc[t]);
  endfunction

  // Sample on the falling edge, when every registered output is stable.
  always @(negedge clk) begin
    if (running && !reset) begin
      for (int p = 0; p < 3; p++)
        if (u_core.wb_valid[p]) val_by_tag[u_core.wb_tag[p]] = u_core.wb_data[p];

      for (int k = 0; k < W; k++) begin
        if (commit_valid[k] && !failed) begin
          last_evt = cyc;
          if (n_commit_rd >= n_exp)
            fail($sformatf("commit a mais de x%0d = %h depois do fim do programa%s",
                           commit_rd[k], val_by_tag[commit_tag[k]], ref_end_note));
          else if (commit_rd[k] !== 5'(exp_rd[n_commit_rd]))
            fail($sformatf("commit %0d: x%0d, esperado x%0d de %s",
                           n_commit_rd, commit_rd[k], exp_rd[n_commit_rd],
                           where(exp_tr[n_commit_rd])));
          else if (val_by_tag[commit_tag[k]] !== exp_val[n_commit_rd])
            fail($sformatf("commit %0d: x%0d = %h, esperado %h de %s",
                           n_commit_rd, commit_rd[k], val_by_tag[commit_tag[k]],
                           exp_val[n_commit_rd], where(exp_tr[n_commit_rd])));
          else
            n_commit_rd++;
        end
        if (st_commit[k]) begin n_commit_st++; last_evt = cyc; end
        if (ld_commit[k]) begin n_commit_ld++; last_evt = cyc; end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // One program: build, reference, run, check
  // ---------------------------------------------------------------------------
  localparam int NT = 25;
  string res_name [NT];
  string res_uses [NT];
  string res_msg  [NT];
  logic  res_ok   [NT];

  task automatic run_test(int t);
    int done_at, t0, last_tr;
    string s;

    nprog = 0; tname = ""; tuses = "";
    build(t);

    for (int k = 0; k < IMEM_N; k++) imem[k] = NOP;
    for (int k = 0; k < nprog; k++) imem[int'(RESET_PC >> 2) + k] = prog[k];
    for (int k = 0; k < DMEM_N; k++) begin
      ref_mem[k] = 8'(k * 29 + 8'h83);      // mixes bytes with bit 7 set and clear
      dut_mem[k] = ref_mem[k];
    end
    reference();

    running = 1'b0;
    reset   = 1'b1;
    repeat (3) @(posedge clk);
    for (int k = 0; k < PRF_ENTRIES; k++) val_by_tag[k] = 'x;
    n_commit_rd = 0; n_commit_st = 0; n_commit_ld = 0;
    failed = 1'b0; fail_msg = "";
    #1 reset = 1'b0;
    running  = 1'b1;
    t0       = cyc;
    last_evt = cyc;
    done_at  = -1;

    while (1) begin
      @(posedge clk);
      if (failed) break;
      if (n_commit_rd >= n_exp && n_commit_ld >= n_ld && n_commit_st >= n_st) begin
        if (done_at < 0) done_at = cyc;
        else if (cyc - done_at >= DRAIN) break;
      end else if (cyc - last_evt > IDLE_MAX) begin
        last_tr = (n_commit_rd == 0) ? 0 : exp_tr[n_commit_rd - 1] + 1;
        s = $sformatf("travado há %0d ciclos: %0d/%0d commits de registrador, %0d/%0d loads, %0d/%0d stores",
                      IDLE_MAX, n_commit_rd, n_exp, n_commit_ld, n_ld, n_commit_st, n_st);
        if (last_tr < n_tr)
          s = {s, "; primeira instrução depois do último commit: ", where(last_tr)};
        fail(s);
        break;
      end
      if (cyc - t0 > CYC_MAX) begin
        fail($sformatf("timeout: %0d ciclos", CYC_MAX));
        break;
      end
    end
    @(negedge clk);
    running = 1'b0;

    if (!failed && n_commit_ld != n_ld)
      fail($sformatf("%0d loads com commit, esperado %0d", n_commit_ld, n_ld));
    if (!failed && n_commit_st != n_st)
      fail($sformatf("%0d stores com commit, esperado %0d", n_commit_st, n_st));
    if (!failed) begin
      int bad, n_bad;
      bad = -1; n_bad = 0;
      for (int k = DMEM_N - 1; k >= 0; k--)     // no break: the lowest address wins
        if (dut_mem[k] !== ref_mem[k]) begin bad = k; n_bad++; end
      if (bad >= 0)
        fail($sformatf("memória de dados difere em %0d bytes; primeiro: %h = %h, esperado %h",
                       n_bad, DBASE + xlen_t'(bad), dut_mem[bad], ref_mem[bad]));
    end

    res_name[t] = tname;
    res_uses[t] = tuses;
    res_ok[t]   = !failed;
    res_msg[t]  = fail_msg;
    $display("%-5s %-22s %0d instruções, %0d ciclos%s%s",
             failed ? "FALHA" : "ok", tname, n_tr, cyc - t0,
             failed ? ": " : "", fail_msg);
  endtask

  // ---------------------------------------------------------------------------
  // Programs. Offsets of branches and jumps are in bytes: 4 * instructions.
  // x10 holds DBASE in every program that touches memory.
  // ---------------------------------------------------------------------------
  int unsigned seed;
  function automatic int unsigned lcg();
    seed = seed * 32'd1103515245 + 32'd12345;
    return seed >> 8;
  endfunction

  task automatic build(int t);
    case (t)
      0: begin
        tname = "alu_reg"; tuses = "ALU: ADD SUB AND OR XOR SLT SLTU SLL SRL SRA";
        emit(ADDI(1, 0, -7));
        emit(ADDI(2, 0, 3));
        emit(LUI (3, 20'h80000));          // 0xFFFFFFFF_80000000
        emit(ADDI(4, 0, 65));              // shift amount: only bits 5:0 count
        emit(ADD (5, 1, 2));
        emit(SUB (6, 2, 1));
        emit(AND (7, 1, 3));
        emit(OR  (8, 1, 2));
        emit(XOR (9, 1, 3));
        emit(SLT (11, 1, 2));
        emit(SLT (12, 2, 1));
        emit(SLTU(13, 1, 2));
        emit(SLTU(14, 2, 1));
        emit(SLL (15, 3, 4));
        emit(SRL (16, 3, 4));
        emit(SRA (17, 3, 4));
        emit(SLL (18, 2, 2));
        emit(ADDI(19, 0, 63));
        emit(SRA (20, 3, 19));
        emit(SRL (21, 3, 19));
        emit(SLL (22, 2, 19));
        emit(SUB (23, 0, 3));
      end
      1: begin
        tname = "alu_imm"; tuses = "ALU: ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI";
        emit(ADDI (1, 0, -2048));
        emit(ADDI (2, 1, 2047));           // -1
        emit(SLTI (3, 1, -2047));
        emit(SLTI (4, 2, -2));
        emit(SLTIU(5, 0, -1));             // 0 < 0xFFFF_FFFF_FFFF_FFFF
        emit(SLTIU(6, 2, 5));
        emit(XORI (7, 2, 12'h555));
        emit(ORI  (8, 1, 12'h0F0));
        emit(ANDI (9, 2, -16));
        emit(ANDI (11, 1, 12'h7FF));
        emit(SLLI (12, 2, 63));
        emit(SRLI (13, 2, 63));
        emit(SRAI (14, 12, 63));
        emit(SRLI (15, 12, 32));
        emit(SRAI (16, 12, 32));
        emit(SLLI (17, 2, 0));
        emit(XORI (18, 2, -1));
        emit(SLLI (19, 7, 40));
      end
      2: begin
        tname = "lui_auipc"; tuses = "ALU: LUI AUIPC";
        emit(LUI  (1, 20'h12345));
        emit(LUI  (2, 20'hFFFFF));
        emit(LUI  (3, 20'h80000));
        emit(AUIPC(4, 0));
        emit(AUIPC(5, 1));
        emit(AUIPC(6, 20'hFFFFF));
        emit(ADDI (7, 4, 0));
        emit(AUIPC(8, 20'h80000));
        emit(AUIPC(9, 20'h7FFFF));
        emit(ADD  (11, 4, 5));
      end
      3: begin
        tname = "alu_word"; tuses = "ALU, RV64 W: ADDIW SLLIW SRLIW SRAIW ADDW SUBW SLLW SRLW SRAW";
        emit(LUI  (1, 20'h7FFFF));
        emit(ADDI (1, 1, 12'h7FF));        // 0x7FFFF7FF
        emit(ADDIW(2, 1, 2047));           // 0x7FFFFFFE
        emit(ADDIW(3, 2, 2));              // wraps: 0xFFFFFFFF_80000000
        emit(ADDI (4, 0, -1));
        emit(ADDIW(5, 4, 0));              // sext.w
        emit(SLLI (6, 4, 32));             // 0xFFFFFFFF_00000000
        emit(ADDIW(7, 6, 5));              // upper half ignored: 5
        emit(SLLIW(8, 4, 31));
        emit(SRLIW(9, 4, 1));              // 0x7FFFFFFF
        emit(SRAIW(11, 6, 4));             // low half is 0
        emit(SRAIW(12, 8, 4));
        emit(SRLIW(13, 8, 31));
        emit(ADDW (14, 3, 3));             // wraps to 0
        emit(SUBW (15, 0, 3));             // -(-2^31) wraps to -2^31
        emit(ADDI (16, 0, 33));            // W shifts use bits 4:0 only: 1
        emit(SLLW (17, 1, 16));
        emit(SRLW (18, 8, 16));
        emit(SRAW (19, 8, 16));
        emit(SUBW (20, 7, 4));
        emit(ADDW (21, 6, 4));             // upper halves ignored
      end
      4: begin
        tname = "x0"; tuses = "x0 como origem e destino";
        emit(ADDI(0, 0, 5));
        emit(ADD (1, 0, 0));
        emit(ADDI(2, 0, 9));
        emit(ADD (0, 2, 2));
        emit(ADD (3, 0, 2));
        emit(LUI (0, 20'h12345));
        emit(ADDI(4, 0, 1));
        emit(SUB (5, 0, 4));
        emit(AUIPC(0, 1));
        emit(OR  (6, 0, 5));
      end
      5: begin
        tname = "hazards"; tuses = "RAW/WAW/WAR dentro do bundle e entre bundles, reúso de tags";
        emit(ADDI(1, 0, 1));
        emit(ADDI(1, 1, 1));               // same register as source and destination
        emit(ADDI(1, 1, 1));
        emit(ADD (2, 1, 1));
        emit(ADD (2, 2, 2));
        emit(ADD (3, 2, 1));
        emit(ADDI(4, 3, 0));               // WAW with the next one
        emit(ADDI(4, 0, 7));
        emit(ADD (5, 4, 4));               // must see 7
        emit(SUB (4, 5, 4));               // WAR: reads x4, then writes it
        emit(ADD (6, 4, 5));
        // 90 more writes, three times the free tags: tags recycle many times.
        for (int k = 0; k < 90; k++) emit(ADDI(7 + (k % 3), 7 + ((k + 2) % 3), k + 1));
        emit(ADD (8, 7, 9));
      end
      6: begin
        tname = "jal"; tuses = "JAL (resolvido no Decode, link pela ALU)";
        emit(ADDI(1, 0, 1));               // 0
        emit(JAL (5, 8));                  // 1 -> 3, x5 = link
        emit(ADDI(1, 0, 99));              // 2 skipped
        emit(ADDI(2, 0, 2));               // 3
        emit(JAL (0, 12));                 // 4 -> 7
        emit(ADDI(2, 0, 99));              // 5 skipped
        emit(ADDI(2, 0, 98));              // 6 skipped
        emit(JAL (6, 4));                  // 7 -> 8, to the next instruction
        emit(ADD (8, 5, 6));               // 8 uses both links
        emit(JAL (0, 16));                 // 9 -> 13
        emit(ADDI(3, 0, 5));               // 10 <- from 14
        emit(JAL (9, 16));                 // 11 -> 15
        emit(ADDI(3, 0, 99));              // 12 skipped
        emit(ADDI(4, 0, 4));               // 13
        emit(JAL (0, -16));                // 14 -> 10, backward
        emit(ADD (11, 9, 3));              // 15
      end
      7: begin
        tname = "load_sizes"; tuses = "AGU + Memory: LB LBU LH LHU LW LWU LD, offsets +/-";
        emit(LUI (10, 20'h00008));
        emit(LB  (1, 10, 3));
        emit(LBU (2, 10, 3));
        emit(LH  (3, 10, 2));
        emit(LHU (4, 10, 2));
        emit(LW  (5, 10, 4));
        emit(LWU (6, 10, 4));
        emit(LD  (7, 10, 8));
        emit(LB  (8, 10, 7));
        emit(LH  (9, 10, 6));
        emit(ADDI(11, 10, 64));
        emit(LD  (12, 11, -8));
        emit(LW  (13, 11, -4));
        emit(LWU (14, 11, -4));
        emit(LHU (15, 11, -2));
        emit(LBU (16, 11, -1));
        emit(LB  (17, 11, -1));
        emit(LW  (18, 10, 0));
        emit(LH  (19, 10, 0));
      end
      8: begin
        tname = "load_use"; tuses = "AGU + Memory: load alimentando ALU e endereços, RS MEM cheia";
        emit(LUI (10, 20'h00008));
        emit(LD  (1, 10, 0));
        emit(ADD (2, 1, 1));               // load-use
        emit(ANDI(3, 1, 12'h1F8));         // aligned offset taken from a load
        emit(ADD (4, 10, 3));
        emit(LD  (5, 4, 0));               // address from a load
        emit(ADD (6, 5, 2));
        for (int k = 0; k < 12; k++) emit(LD(11 + k, 10, 16 + 8 * k));
        emit(ADD (23, 11, 12));
        emit(ADD (23, 23, 13));
        emit(ADD (23, 23, 22));
        emit(LW  (24, 4, 4));
        emit(ADDW(25, 24, 24));
      end
      9: begin
        tname = "store_then_load"; tuses = "SB SH SW SD e depois loads dos mesmos bytes (dado do store)";
        emit(LUI (10, 20'h00008));
        emit(ADDI(1, 0, -123));
        emit(LUI (2, 20'h12345));
        emit(ADDI(2, 2, 12'h678));
        emit(SD  (2, 10, 128));
        emit(LD  (3, 10, 128));
        emit(SW  (1, 10, 136));
        emit(LW  (4, 10, 136));
        emit(LWU (5, 10, 136));
        emit(SH  (2, 10, 140));
        emit(LH  (6, 10, 140));
        emit(SB  (1, 10, 142));
        emit(LBU (7, 10, 142));
        emit(LD  (8, 10, 136));
      end
      10: begin
        tname = "store_memory"; tuses = "SB SH SW SD, conteúdo final da memória";
        emit(LUI (10, 20'h00008));
        emit(ADDI(1, 0, -1));
        emit(LUI (2, 20'hABCDE));
        emit(SD  (2, 10, 200));
        emit(SW  (1, 10, 208));
        emit(SH  (2, 10, 212));
        emit(SB  (1, 10, 215));
        emit(SD  (0, 10, 216));            // stores x0
        emit(SB  (2, 10, 225));
        emit(SH  (1, 10, 230));
      end
      11: begin
        tname = "branch_not_taken"; tuses = "Branch Unit: BEQ BNE BLT BGE BLTU BGEU, não tomados";
        emit(ADDI(1, 0, -1));
        emit(ADDI(2, 0, 1));
        emit(BEQ (1, 2, 8));
        emit(ADDI(3, 0, 1));
        emit(BNE (1, 1, 8));
        emit(ADDI(4, 0, 2));
        emit(BLT (2, 1, 8));               // 1 < -1 signed: no
        emit(ADDI(5, 0, 3));
        emit(BGE (1, 2, 8));               // -1 >= 1 signed: no
        emit(ADDI(6, 0, 4));
        emit(BLTU(1, 2, 8));               // 0xFF..F < 1 unsigned: no
        emit(ADDI(7, 0, 5));
        emit(BGEU(2, 1, 8));               // 1 >= 0xFF..F unsigned: no
        emit(ADDI(8, 0, 6));
      end
      12: begin
        tname = "branch_taken"; tuses = "Branch Unit: BEQ BNE BLT BGE BLTU BGEU, tomados para frente";
        emit(ADDI(1, 0, -1));
        emit(ADDI(2, 0, 1));
        emit(BEQ (1, 1, 8));
        emit(ADDI(3, 0, 99));              // skipped by every branch below
        emit(BNE (1, 2, 8));
        emit(ADDI(4, 0, 99));
        emit(BLT (1, 2, 8));
        emit(ADDI(5, 0, 99));
        emit(BGE (2, 1, 8));
        emit(ADDI(6, 0, 99));
        emit(BLTU(2, 1, 8));
        emit(ADDI(7, 0, 99));
        emit(BGEU(1, 2, 8));
        emit(ADDI(8, 0, 99));
        emit(ADDI(9, 0, 7));
      end
      13: begin
        tname = "branch_loop"; tuses = "Branch Unit: BNE para trás, laço com contador";
        emit(ADDI(1, 0, 10));
        emit(ADDI(2, 0, 0));
        emit(ADD (2, 2, 1));               // loop
        emit(ADDI(1, 1, -1));
        emit(BNE (1, 0, -8));
        emit(ADDI(3, 2, 0));
      end
      14: begin
        tname = "jalr"; tuses = "Branch Unit: JALR em chamada/retorno e salto calculado";
        emit(ADDI (1, 0, 5));              // 0
        emit(JAL  (5, 16));                // 1 call -> 5
        emit(ADDI (3, 2, 1));              // 2 return lands here
        emit(JAL  (0, 20));                // 3 -> 8
        emit(ADDI (0, 0, 0));              // 4
        emit(ADDI (2, 1, 10));             // 5 function body
        emit(JALR (0, 5, 0));              // 6 return
        emit(ADDI (0, 0, 0));              // 7
        emit(AUIPC(6, 0));                 // 8
        emit(JALR (7, 6, 13));             // 9 -> 8 + 12 = 11 (bit 0 cleared)
        emit(ADDI (8, 0, 99));             // 10 skipped
        emit(ADDI (9, 7, 0));              // 11 the link
      end
      15: begin
        tname = "fence"; tuses = "FENCE e FENCE.I entre trabalho de ALU e loads";
        emit(LUI (10, 20'h00008));
        emit(ADDI(1, 0, 1));
        emit(LD  (2, 10, 0));
        emit(FENCE);
        emit(ADD (3, 2, 1));
        emit(FENCE_I);
        emit(ADDI(4, 3, 1));
        emit(LW  (5, 10, 8));
      end
      16: begin
        tname = "ecall"; tuses = "ECALL gera trap: nada depois dele faz commit";
        emit(ADDI(1, 0, 1));
        emit(ADDI(2, 1, 1));
        emit(ECALL);
        emit(ADDI(3, 0, 99));
        emit(ADDI(4, 0, 99));
      end
      17: begin
        tname = "ebreak"; tuses = "EBREAK gera trap: nada depois dele faz commit";
        emit(ADDI(1, 0, 1));
        emit(EBREAK);
        emit(ADDI(3, 0, 99));
      end
      18: begin
        tname = "illegal"; tuses = "MUL (sem extensão M) gera trap de instrução ilegal";
        emit(ADDI(1, 0, 6));
        emit(ADDI(2, 0, 7));
        emit(MUL (3, 1, 2));
        emit(ADDI(4, 0, 99));
      end
      19: begin
        tname = "misaligned_load"; tuses = "AGU: exceção de desalinhamento num load";
        emit(LUI (10, 20'h00008));
        emit(ADDI(1, 0, 1));
        emit(LW  (2, 10, 2));
        emit(ADDI(3, 0, 99));
        emit(ADDI(1, 0, 98));              // must not overwrite x1
      end
      20: begin
        tname = "misaligned_store"; tuses = "AGU: exceção de desalinhamento num store";
        emit(LUI (10, 20'h00008));
        emit(ADDI(1, 0, 1));
        emit(SH  (1, 10, 1));
        emit(ADDI(3, 0, 99));
      end
      21: begin
        tname = "wrong_path_after_trap"; tuses = "flush com loads e trabalho de ALU em voo";
        emit(LUI (10, 20'h00008));
        emit(ADDI(1, 0, 3));
        for (int k = 0; k < 6; k++) emit(LD(11 + k, 10, 8 * k));
        emit(LD  (2, 10, 4));              // misaligned: traps behind slow loads
        for (int k = 0; k < 6; k++) emit(ADDI(1, 1, 1));
        emit(LD  (3, 10, 0));
      end
      22: begin
        tname = "stress_mix"; tuses = "160 instruções aleatórias de ALU, W e load, sem desvios nem stores";
        seed = 32'hC0FFEE;
        emit(LUI(10, 20'h00008));
        for (int k = 0; k < 160; k++) begin
          int unsigned r;
          int rd, rs1, rs2;
          r   = lcg();
          rd  = 1 + int'(r % 30); if (rd >= 10) rd++;       // never x10
          rs1 = int'((r >> 5) % 32);
          rs2 = int'((r >> 10) % 32);
          case (lcg() % 12)
            0:  emit(ADD (rd, rs1, rs2));
            1:  emit(SUB (rd, rs1, rs2));
            2:  emit(XOR (rd, rs1, rs2));
            3:  emit(ADDI(rd, rs1, int'(lcg() % 4096) - 2048));
            4:  emit(SLLI(rd, rs1, int'(lcg() % 64)));
            5:  emit(SRAI(rd, rs1, int'(lcg() % 64)));
            6:  emit(ADDW(rd, rs1, rs2));
            7:  emit(SLTU(rd, rs1, rs2));
            8:  emit(LD  (rd, 10, 8 * int'(lcg() % 64)));
            9:  emit(LBU (rd, 10, int'(lcg() % 512)));
            10: emit(SRAW(rd, rs1, rs2));
            default: emit(LH(rd, 10, 2 * int'(lcg() % 256)));
          endcase
        end
      end
      23: begin
        tname = "prog_sum_array"; tuses = "programa: laço sobre 16 loads, store da soma";
        emit(LUI (10, 20'h00008));
        emit(ADDI(1, 10, 0));              // pointer
        emit(ADDI(2, 0, 16));              // count
        emit(ADDI(3, 0, 0));               // sum
        emit(LD  (4, 1, 0));               // loop
        emit(ADD (3, 3, 4));
        emit(ADDI(1, 1, 8));
        emit(ADDI(2, 2, -1));
        emit(BNE (2, 0, -16));
        emit(SD  (3, 10, 256));
        emit(LD  (5, 10, 256));
      end
      24: begin
        tname = "prog_memcpy"; tuses = "programa: cópia byte a byte com BLTU, loads e stores";
        emit(LUI (10, 20'h00008));
        emit(ADDI(1, 10, 0));              // src
        emit(ADDI(2, 10, 512));            // dst
        emit(ADDI(3, 10, 24));             // src end
        emit(LBU (4, 1, 0));               // loop
        emit(SB  (4, 2, 0));
        emit(ADDI(1, 1, 1));
        emit(ADDI(2, 2, 1));
        emit(BLTU(1, 3, -16));
        emit(LD  (5, 10, 512));
        emit(LD  (6, 10, 520));
        emit(XOR (7, 5, 6));
      end
      default: $fatal(1, "não existe programa %0d", t);
    endcase
  endtask

  // ---------------------------------------------------------------------------
  // Run every program, then the report
  // ---------------------------------------------------------------------------
  // No `timescale in the project: time is in simulator units, so the report
  // counts cycles, never ns or MHz.
  localparam string BAR  = "=========================================================";
  localparam string LINE = "---------------------------------------------------------";

  initial begin
    int n_ok, n_insn, cyc_start;
    $display("");
    $display("%s", BAR);
    $display(" Testbench core_isa  -  DEEP2 = %0d, LSU_LAT = %0d, W = %0d", DEEP2, LSU_LAT, W);
    $display("%s", BAR);
    $display("    programas: %0d, cada um a partir do reset", NT);
    $display("    travado depois de %0d ciclos sem commit; espera final de %0d ciclos", IDLE_MAX, DRAIN);
    $display("");
    $display("%s", LINE);
    cyc_start = cyc;
    n_insn    = 0;
    for (int t = 0; t < NT; t++) begin
      run_test(t);
      n_insn += n_tr;
    end
    $display("%s", LINE);

    n_ok = 0;
    for (int t = 0; t < NT; t++) if (res_ok[t]) n_ok++;

    if (n_ok != NT) begin
      $display("");
      $display(" Programas que falharam");
      $display("%s", LINE);
      for (int t = 0; t < NT; t++)
        if (!res_ok[t]) begin
          $display("  %-22s %s", res_name[t], res_uses[t]);
          $display("  %-22s -> %s", "", res_msg[t]);
        end
    end

    $display("");
    $display("%s", LINE);
    $display("  OK        : %0d", n_ok);
    $display("  FALHA     : %0d", NT - n_ok);
    $display("  instruções executadas pela referência: %0d", n_insn);
    $display("  ciclos, todos os programas: %0d", cyc - cyc_start);
    if (n_ok == NT) $display("  RESULTADO : TODOS OS PROGRAMAS OK");
    else            $display("  RESULTADO : %0d DE %0d PROGRAMAS FALHANDO", NT - n_ok, NT);
    $display("%s", LINE);
    $display("");

    if (n_ok != NT) $fatal(1, "core_isa_tb: %0d de %0d programas falharam", NT - n_ok, NT);
    $display("PASS core_isa_tb DEEP2=%0d: %0d programas", DEEP2, NT);
    $finish;
  end

endmodule
