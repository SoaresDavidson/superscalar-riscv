// Self-checking unit testbench for `decode`. Covers the 29 mandatory cases of
// docsDecode/Decode.md section 11. Prints PASS at the end, $fatal on any failed
// check. Runs at WIDTH = 1, 2, 3 and 4 (PARAMS_decode in the Makefile); cases
// that need more slots than WIDTH provides are skipped and reported.
//
// Icarus 12.0 idiom (see AGENTS.md, "Icarus 12.0 limits"): a packed vector of
// structs may be indexed with a variable ONLY whole-element. `out_uop[i].rs1`
// with `int i` aborts the elaborator, so every access goes through a scalar
// struct temporary: `a = out_uop[i];` and then `a.rs1`.

module decode_tb;

  import core_pkg::*;

  // parameter, not localparam: the Makefile overrides it with -Pdecode_tb.WIDTH
  parameter int WIDTH = 3;

  localparam int XLEN      = core_pkg::XLEN;
  localparam int PROD_BITS = ($clog2(WIDTH) > 0) ? $clog2(WIDTH) : 1;

  // --- DUT wiring -----------------------------------------------------------

  logic                            clk, reset, flush;
  logic                            in_valid, in_ready;
  logic [WIDTH-1:0]                in_slot_valid;
  logic [WIDTH-1:0][31:0]          in_inst;
  logic [WIDTH-1:0][XLEN-1:0]      in_pc;

  logic                            out_valid, out_ready;
  uop_t [WIDTH-1:0]                out_uop;
  logic [WIDTH-1:0]                out_dep_rs1_in_bundle;
  logic [WIDTH-1:0]                out_dep_rs2_in_bundle;
  logic [WIDTH-1:0][PROD_BITS-1:0] out_dep_rs1_producer;
  logic [WIDTH-1:0][PROD_BITS-1:0] out_dep_rs2_producer;
  logic                            redirect_valid;
  logic [XLEN-1:0]                 redirect_pc;
  logic [WIDTH-1:0]                out_slot_kill;

  decode #(.WIDTH(WIDTH), .XLEN(XLEN)) dut (.*);

  // --- clock, watchdog, bookkeeping ----------------------------------------

  localparam int TIMEOUT_NS = 20000;

  string cur;        // name of the running case, printed on failure
  int    checks;     // how many checks actually ran

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Without this, a DUT that never raises in_ready (the current stub) would
  // hang instead of failing.
  initial begin
    #TIMEOUT_NS;
    $fatal(1, "TIMEOUT after %0d ns during case: %s", TIMEOUT_NS, cur);
  end

  task automatic fail(string msg);
    $display("FAIL [%s] %s", cur, msg);
    $fatal(1, "case failed: %s", cur);
  endtask

  // --- instruction builders (section 6 field map) ---------------------------

  function automatic logic [31:0] enc_r(logic [6:0] f7, logic [4:0] rs2,
                                        logic [4:0] rs1, logic [2:0] f3,
                                        logic [4:0] rd, logic [6:0] op);
    enc_r = {f7, rs2, rs1, f3, rd, op};
  endfunction

  function automatic logic [31:0] enc_i(logic [11:0] imm, logic [4:0] rs1,
                                        logic [2:0] f3, logic [4:0] rd,
                                        logic [6:0] op);
    enc_i = {imm, rs1, f3, rd, op};
  endfunction

  function automatic logic [31:0] enc_s(logic [11:0] imm, logic [4:0] rs2,
                                        logic [4:0] rs1, logic [2:0] f3,
                                        logic [6:0] op);
    enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op};
  endfunction

  // imm is the byte offset; bit 0 is not encoded (section 7)
  function automatic logic [31:0] enc_b(logic [12:0] imm, logic [4:0] rs2,
                                        logic [4:0] rs1, logic [2:0] f3,
                                        logic [6:0] op);
    enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], op};
  endfunction

  function automatic logic [31:0] enc_u(logic [19:0] imm_hi, logic [4:0] rd,
                                        logic [6:0] op);
    enc_u = {imm_hi, rd, op};
  endfunction

  function automatic logic [31:0] enc_j(logic [20:0] imm, logic [4:0] rd,
                                        logic [6:0] op);
    enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, op};
  endfunction

  // --- expected uop: all fields x (don't care) until set --------------------

  function automatic uop_t exp_init();
    exp_init = {$bits(uop_t){1'bx}};
  endfunction

  // A field is checked only when the expected value carries no x bit, so each
  // case states just the fields it is about.
  `define CARE(f)  ((^{e.f}) !== 1'bx)
  `define CHK(f)                                                              \
    if (`CARE(f)) begin                                                        \
      checks++;                                                                \
      if (a.f !== e.f)                                                         \
        fail($sformatf("slot %0d: %s = 'h%0h, expected 'h%0h",                 \
                       slot, `"f`", a.f, e.f));                                \
    end

  task automatic check_uop(int slot, uop_t e);
    uop_t a;
    a = out_uop[slot];        // whole-element read: the only legal form here
    `CHK(valid)
    `CHK(pc)
    `CHK(uop_class)
    `CHK(alu_op)
    `CHK(mul_op)
    `CHK(br_op)
    `CHK(mem_size)
    `CHK(mem_unsigned)
    `CHK(word_op)
    `CHK(op_a_sel)
    `CHK(op_b_sel)
    `CHK(imm)
    `CHK(rs1)
    `CHK(rs1_valid)
    `CHK(rs2)
    `CHK(rs2_valid)
    `CHK(rd)
    `CHK(has_dest)
    `CHK(serializing)
    `CHK(illegal)
  endtask

  task automatic check_bit(string what, logic got, logic want);
    checks++;
    if (got !== want)
      fail($sformatf("%s = %0b, expected %0b", what, got, want));
  endtask

  task automatic check_vec(string what, logic [WIDTH-1:0] got,
                           logic [WIDTH-1:0] want);
    checks++;
    if (got !== want)
      fail($sformatf("%s = 'b%0b, expected 'b%0b", what, got, want));
  endtask

  task automatic check_producer(string what, int slot, logic [PROD_BITS-1:0] got,
                                int want);
    checks++;
    if (got !== PROD_BITS'(want))
      fail($sformatf("%s[%0d] = %0d, expected %0d", what, slot, got, want));
  endtask

  // --- driving --------------------------------------------------------------

  // Timing discipline, and the reason for it: inputs change on the NEGEDGE and
  // everything is sampled between edges. Driving on the posedge races with the
  // DUT's own always_ff -- in_valid rising and falling on the very edges that
  // should capture it, so the handshake is silently lost.
  task automatic do_reset();
    @(negedge clk);
    reset         = 1'b1;
    flush         = 1'b0;
    in_valid      = 1'b0;
    out_ready     = 1'b1;
    in_slot_valid = '0;
    in_inst       = '0;
    in_pc         = '0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
  endtask

  // Presents a bundle and returns once it has been accepted (in_valid &&
  // in_ready on the same edge).
  task automatic send(logic [WIDTH-1:0] slot_valid);
    bit accepted;
    @(negedge clk);
    in_slot_valid = slot_valid;
    in_valid      = 1'b1;
    accepted      = 1'b0;
    do begin
      @(posedge clk);          // the edge that captures
      accepted = in_ready;     // in_ready as it stood at that edge
      @(negedge clk);          // only now may the inputs change
    end while (!accepted);
    in_valid      = 1'b0;
    in_slot_valid = '0;
  endtask

  // Waits for the bundle to appear on the output side.
  task automatic await_out();
    while (!out_valid) begin
      @(posedge clk);
      @(negedge clk);
    end
  endtask

  // Single instruction in slot 0, the remaining slots invalid.
  task automatic send_one(logic [31:0] inst, logic [XLEN-1:0] pc);
    in_inst    = '0;
    in_pc      = '0;
    in_inst[0] = inst;
    in_pc[0]   = pc;
    send(WIDTH'(1));
    await_out();
  endtask

  // The common shape of the encoding cases: decode one instruction, compare
  // slot 0 against `e`, then drain.
  task automatic one(string nm, logic [31:0] inst, uop_t e);
    cur = nm;
    send_one(inst, 64'h0000_0000_0000_1000);
    check_uop(0, e);
    // Deliberately does NOT advance the clock: the caller may still want to
    // look at out_uop (case 3 checks imm[0] separately).
  endtask

  // An encoding that must be rejected (section 9.5): the instruction keeps
  // flowing, with illegal = 1 and nothing allocated.
  task automatic illegal(string nm, logic [31:0] inst);
    uop_t e;
    e             = exp_init();
    e.valid       = 1'b1;
    e.illegal     = 1'b1;
    e.uop_class   = UC_ILLEGAL;
    e.has_dest    = 1'b0;
    e.rs1_valid   = 1'b0;
    e.rs2_valid   = 1'b0;
    one(nm, inst, e);
  endtask

  // --- bundle driving (slot count depends on WIDTH) -------------------------

  localparam logic [31:0] NOP = 32'h0000_0013;  // addi x0, x0, 0

  logic [31:0] b_inst [0:3];    // program order, slot 0 first
  int          covered;         // instructions exercised by case 1

  task automatic send_bundle(logic [WIDTH-1:0] slot_valid);
    in_inst = '0;
    in_pc   = '0;
    for (int i = 0; i < WIDTH; i++) begin
      in_inst[i] = b_inst[i];
      in_pc[i]   = 64'h1000 + 64'(4 * i);
    end
    send(slot_valid);
    await_out();
  endtask

  task automatic bundle_of_nops();
    for (int i = 0; i < 4; i++) b_inst[i] = NOP;
  endtask

  task automatic tick();
    @(posedge clk);
    @(negedge clk);
  endtask

  task automatic skip(string nm, string why);
    $display("SKIP [%s] %s (WIDTH = %0d)", nm, why, WIDTH);
  endtask

  task automatic chk_prod1(int slot, int want);
    logic [PROD_BITS-1:0] p;
    p = out_dep_rs1_producer[slot];
    check_producer("rs1_producer", slot, p, want);
  endtask

  task automatic chk_prod2(int slot, int want);
    logic [PROD_BITS-1:0] p;
    p = out_dep_rs2_producer[slot];
    check_producer("rs2_producer", slot, p, want);
  endtask

  // --- per-class expectation shorthands ------------------------------------
  // Every one uses rs1 = x1, rs2 = x2, rd = x3: non-zero and distinct, so the
  // x0 lowering of section 9.4 never interferes here (it has its own cases).

  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_AUIPC  = 7'b0010111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_OPIMM  = 7'b0010011;
  localparam logic [6:0] OP_OP     = 7'b0110011;
  localparam logic [6:0] OP_OPIMM32= 7'b0011011;
  localparam logic [6:0] OP_OP32   = 7'b0111011;
  localparam logic [6:0] OP_MISCMEM= 7'b0001111;
  localparam logic [6:0] OP_SYSTEM = 7'b1110011;

  task automatic alu_rr(string nm, logic [6:0] f7, logic [2:0] f3,
                        alu_op_e op, bit w);
    uop_t e;
    e             = exp_init();
    e.valid       = 1'b1;
    e.illegal     = 1'b0;
    e.uop_class   = UC_ALU;
    e.alu_op      = op;
    e.word_op     = w;
    e.op_a_sel    = OPA_RS1;
    e.op_b_sel    = OPB_RS2;
    e.rs1         = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2         = 5'd2;  e.rs2_valid = 1'b1;
    e.rd          = 5'd3;  e.has_dest  = 1'b1;
    e.serializing = 1'b0;
    covered++;
    one(nm, enc_r(f7, 5'd2, 5'd1, f3, 5'd3, w ? OP_OP32 : OP_OP), e);
  endtask

  task automatic alu_ri(string nm, logic [11:0] imm, logic [2:0] f3,
                        alu_op_e op, bit w);
    uop_t e;
    e             = exp_init();
    e.valid       = 1'b1;
    e.illegal     = 1'b0;
    e.uop_class   = UC_ALU;
    e.alu_op      = op;
    e.word_op     = w;
    e.op_a_sel    = OPA_RS1;
    e.op_b_sel    = OPB_IMM;
    e.imm         = {{52{imm[11]}}, imm};
    e.rs1         = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2_valid   = 1'b0;
    e.rd          = 5'd3;  e.has_dest  = 1'b1;
    e.serializing = 1'b0;
    covered++;
    one(nm, enc_i(imm, 5'd1, f3, 5'd3, w ? OP_OPIMM32 : OP_OPIMM), e);
  endtask

  // Immediate shifts: the immediate carries the shift amount, not imm_i
  // (section 7 says imm_i is not used, section 9.3 gives the shamt field).
  task automatic shift_i(string nm, logic [11:0] immfield, logic [2:0] f3,
                         alu_op_e op, bit w, int shamt);
    uop_t e;
    e             = exp_init();
    e.valid       = 1'b1;
    e.illegal     = 1'b0;
    e.uop_class   = UC_ALU;
    e.alu_op      = op;
    e.word_op     = w;
    e.op_a_sel    = OPA_RS1;
    e.op_b_sel    = OPB_IMM;
    e.imm         = 64'(shamt);
    e.rs1         = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2_valid   = 1'b0;
    e.rd          = 5'd3;  e.has_dest  = 1'b1;
    e.serializing = 1'b0;
    covered++;
    one(nm, enc_i(immfield, 5'd1, f3, 5'd3, w ? OP_OPIMM32 : OP_OPIMM), e);
  endtask

  task automatic ld(string nm, logic [2:0] f3, mem_size_e sz, bit uns);
    uop_t e;
    e              = exp_init();
    e.valid        = 1'b1;
    e.illegal      = 1'b0;
    e.uop_class    = UC_LOAD;
    e.mem_size     = sz;
    e.mem_unsigned = uns;
    e.op_a_sel     = OPA_RS1;
    e.op_b_sel     = OPB_IMM;
    e.imm          = 64'd16;
    e.rs1          = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2_valid    = 1'b0;
    e.rd           = 5'd3;  e.has_dest  = 1'b1;
    e.serializing  = 1'b0;
    covered++;
    one(nm, enc_i(12'd16, 5'd1, f3, 5'd3, OP_LOAD), e);
  endtask

  task automatic st(string nm, logic [2:0] f3, mem_size_e sz);
    uop_t e;
    e             = exp_init();
    e.valid       = 1'b1;
    e.illegal     = 1'b0;
    e.uop_class   = UC_STORE;
    e.mem_size    = sz;
    e.imm         = 64'd16;
    e.rs1         = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2         = 5'd2;  e.rs2_valid = 1'b1;
    e.has_dest    = 1'b0;      // S format never writes (section 6)
    e.serializing = 1'b0;
    covered++;
    one(nm, enc_s(12'd16, 5'd2, 5'd1, f3, OP_STORE), e);
  endtask

  task automatic br(string nm, logic [2:0] f3, br_op_e op);
    uop_t e;
    e             = exp_init();
    e.valid       = 1'b1;
    e.illegal     = 1'b0;
    e.uop_class   = UC_BRANCH;
    e.br_op       = op;
    e.imm         = 64'd32;
    e.rs1         = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2         = 5'd2;  e.rs2_valid = 1'b1;
    e.has_dest    = 1'b0;      // B format never writes (section 6)
    e.serializing = 1'b0;
    covered++;
    one(nm, enc_b(13'd32, 5'd2, 5'd1, f3, OP_BRANCH), e);
  endtask

  task automatic mul_rr(string nm, logic [2:0] f3, mul_op_e op, bit w);
    uop_t e;
    e             = exp_init();
    e.valid       = 1'b1;
    e.illegal     = 1'b0;
    e.uop_class   = UC_MUL;   // shares opcode with ALU, funct7 = 0000001
    e.mul_op      = op;
    e.word_op     = w;
    e.op_a_sel    = OPA_RS1;
    e.op_b_sel    = OPB_RS2;
    e.rs1         = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2         = 5'd2;  e.rs2_valid = 1'b1;
    e.rd          = 5'd3;  e.has_dest  = 1'b1;
    e.serializing = 1'b0;
    covered++;
    one(nm, enc_r(7'b0000001, 5'd2, 5'd1, f3, 5'd3, w ? OP_OP32 : OP_OP), e);
  endtask

  // ==========================================================================
  // Cases 1-12: encoding coverage
  // ==========================================================================

  task automatic case01_all_57();
    uop_t e;
    covered = 0;

    // --- U and J formats: no sources, one destination ---------------------
    e = exp_init();
    e.valid     = 1'b1;  e.illegal   = 1'b0;
    e.uop_class = UC_ALU;  e.alu_op  = ALU_ADD;
    e.op_a_sel  = OPA_ZERO;  e.op_b_sel = OPB_IMM;
    e.imm       = 64'h0000_0000_1234_5000;
    e.rs1_valid = 1'b0;  e.rs2_valid = 1'b0;
    e.rd        = 5'd3;  e.has_dest  = 1'b1;
    e.word_op   = 1'b0;  e.serializing = 1'b0;
    covered++;
    one("LUI", enc_u(20'h12345, 5'd3, OP_LUI), e);

    e.op_a_sel = OPA_PC;                 // AUIPC: PC + imm_u
    e.imm      = 64'h0000_0000_0000_1000;
    covered++;
    one("AUIPC", enc_u(20'h00001, 5'd3, OP_AUIPC), e);

    e = exp_init();
    e.valid     = 1'b1;  e.illegal   = 1'b0;
    e.uop_class = UC_JUMP;
    e.imm       = 64'd2048;
    e.rs1_valid = 1'b0;  e.rs2_valid = 1'b0;
    e.rd        = 5'd1;  e.has_dest  = 1'b1;
    e.serializing = 1'b0;
    covered++;
    one("JAL", enc_j(21'd2048, 5'd1, OP_JAL), e);

    e = exp_init();
    e.valid     = 1'b1;  e.illegal   = 1'b0;
    e.uop_class = UC_JUMP;
    e.imm       = 64'd8;
    e.rs1       = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2_valid = 1'b0;
    e.rd        = 5'd1;  e.has_dest  = 1'b1;
    e.serializing = 1'b0;
    covered++;
    one("JALR", enc_i(12'd8, 5'd1, 3'b000, 5'd1, OP_JALR), e);

    // --- branches (6) -----------------------------------------------------
    br("BEQ",  3'b000, BR_EQ);
    br("BNE",  3'b001, BR_NE);
    br("BLT",  3'b100, BR_LT);
    br("BGE",  3'b101, BR_GE);
    br("BLTU", 3'b110, BR_LTU);
    br("BGEU", 3'b111, BR_GEU);

    // --- loads (7) --------------------------------------------------------
    ld("LB",  3'b000, MEM_B, 1'b0);
    ld("LH",  3'b001, MEM_H, 1'b0);
    ld("LW",  3'b010, MEM_W, 1'b0);
    ld("LD",  3'b011, MEM_D, 1'b0);
    ld("LBU", 3'b100, MEM_B, 1'b1);
    ld("LHU", 3'b101, MEM_H, 1'b1);
    ld("LWU", 3'b110, MEM_W, 1'b1);

    // --- stores (4) -------------------------------------------------------
    st("SB", 3'b000, MEM_B);
    st("SH", 3'b001, MEM_H);
    st("SW", 3'b010, MEM_W);
    st("SD", 3'b011, MEM_D);

    // --- OP-IMM (6 + 3 shifts) -------------------------------------------
    alu_ri("ADDI",  12'd7,   3'b000, ALU_ADD,  1'b0);
    alu_ri("SLTI",  12'd7,   3'b010, ALU_SLT,  1'b0);
    alu_ri("SLTIU", 12'd7,   3'b011, ALU_SLTU, 1'b0);
    alu_ri("XORI",  12'd7,   3'b100, ALU_XOR,  1'b0);
    alu_ri("ORI",   12'd7,   3'b110, ALU_OR,   1'b0);
    alu_ri("ANDI",  12'd7,   3'b111, ALU_AND,  1'b0);
    shift_i("SLLI", {6'b000000, 6'd5}, 3'b001, ALU_SLL, 1'b0, 5);
    shift_i("SRLI", {6'b000000, 6'd5}, 3'b101, ALU_SRL, 1'b0, 5);
    shift_i("SRAI", {6'b010000, 6'd5}, 3'b101, ALU_SRA, 1'b0, 5);

    // --- OP (10) ----------------------------------------------------------
    alu_rr("ADD",  7'b0000000, 3'b000, ALU_ADD,  1'b0);
    alu_rr("SUB",  7'b0100000, 3'b000, ALU_SUB,  1'b0);
    alu_rr("SLL",  7'b0000000, 3'b001, ALU_SLL,  1'b0);
    alu_rr("SLT",  7'b0000000, 3'b010, ALU_SLT,  1'b0);
    alu_rr("SLTU", 7'b0000000, 3'b011, ALU_SLTU, 1'b0);
    alu_rr("XOR",  7'b0000000, 3'b100, ALU_XOR,  1'b0);
    alu_rr("SRL",  7'b0000000, 3'b101, ALU_SRL,  1'b0);
    alu_rr("SRA",  7'b0100000, 3'b101, ALU_SRA,  1'b0);
    alu_rr("OR",   7'b0000000, 3'b110, ALU_OR,   1'b0);
    alu_rr("AND",  7'b0000000, 3'b111, ALU_AND,  1'b0);

    // --- OP-IMM-32 (4): word_op = 1, shamt is 5 bits ---------------------
    alu_ri("ADDIW",  12'd7, 3'b000, ALU_ADD, 1'b1);
    shift_i("SLLIW", {7'b0000000, 5'd5}, 3'b001, ALU_SLL, 1'b1, 5);
    shift_i("SRLIW", {7'b0000000, 5'd5}, 3'b101, ALU_SRL, 1'b1, 5);
    shift_i("SRAIW", {7'b0100000, 5'd5}, 3'b101, ALU_SRA, 1'b1, 5);

    // --- OP-32 (5) --------------------------------------------------------
    alu_rr("ADDW", 7'b0000000, 3'b000, ALU_ADD, 1'b1);
    alu_rr("SUBW", 7'b0100000, 3'b000, ALU_SUB, 1'b1);
    alu_rr("SLLW", 7'b0000000, 3'b001, ALU_SLL, 1'b1);
    alu_rr("SRLW", 7'b0000000, 3'b101, ALU_SRL, 1'b1);
    alu_rr("SRAW", 7'b0100000, 3'b101, ALU_SRA, 1'b1);

    // --- MISC-MEM and SYSTEM (3) -----------------------------------------
    // FENCE: serializing is left unchecked -- decision 9 (nop or store-queue
    // drain) is still open, and it is the consumer of that flag.
    e = exp_init();
    e.valid     = 1'b1;  e.illegal = 1'b0;
    e.uop_class = UC_SYSTEM;
    e.rs1_valid = 1'b0;  e.rs2_valid = 1'b0;  e.has_dest = 1'b0;
    covered++;
    one("FENCE", 32'h0ff0000f, e);

    e = exp_init();
    e.valid       = 1'b1;  e.illegal = 1'b0;
    e.uop_class   = UC_SYSTEM;
    e.serializing = 1'b1;                 // decision 10
    e.rs1_valid   = 1'b0;  e.rs2_valid = 1'b0;  e.has_dest = 1'b0;
    covered++;
    one("ECALL", 32'h0000_0073, e);
    covered++;
    one("EBREAK", 32'h0010_0073, e);

    // --- M extension (5) --------------------------------------------------
    mul_rr("MUL",    3'b000, MUL_LO,   1'b0);
    mul_rr("MULH",   3'b001, MUL_HI,   1'b0);
    mul_rr("MULHSU", 3'b010, MUL_HISU, 1'b0);
    mul_rr("MULHU",  3'b011, MUL_HIU,  1'b0);
    mul_rr("MULW",   3'b000, MUL_LO,   1'b1);

    cur = "case 1 instruction count";
    if (covered != 57)
      fail($sformatf("exercised %0d instructions, the ISA has 57", covered));
  endtask

  task automatic case02_imm_i();
    uop_t e;
    e = exp_init();
    e.valid = 1'b1;  e.imm = 64'd2047;
    one("imm_i = +2047", enc_i(12'h7FF, 5'd1, 3'b000, 5'd3, OP_OPIMM), e);
    e.imm = 64'hFFFF_FFFF_FFFF_F800;      // -2048, sign-extended to bit 63
    one("imm_i = -2048", enc_i(12'h800, 5'd1, 3'b000, 5'd3, OP_OPIMM), e);
  endtask

  task automatic case03_imm_b_j();
    uop_t e, a;
    // B: 13-bit signed, even. Range -4096 .. +4094.
    e = exp_init();
    e.valid = 1'b1;  e.imm = 64'd4094;
    one("imm_b = +4094", enc_b(13'd4094, 5'd2, 5'd1, 3'b000, OP_BRANCH), e);
    a = out_uop[0];
    check_bit("imm_b[0] (bit 0 is implicit, never encoded)", a.imm[0], 1'b0);

    e.imm = 64'hFFFF_FFFF_FFFF_F000;      // -4096
    one("imm_b = -4096", enc_b(13'h1000, 5'd2, 5'd1, 3'b000, OP_BRANCH), e);
    a = out_uop[0];
    check_bit("imm_b[0]", a.imm[0], 1'b0);

    // J: 21-bit signed, even. Range -1048576 .. +1048574.
    e = exp_init();
    e.valid = 1'b1;  e.imm = 64'd1048574;
    one("imm_j = +1048574", enc_j(21'd1048574, 5'd1, OP_JAL), e);
    a = out_uop[0];
    check_bit("imm_j[0]", a.imm[0], 1'b0);

    e.imm = 64'hFFFF_FFFF_FFF0_0000;      // -1048576
    one("imm_j = -1048576", enc_j(21'h100000, 5'd1, OP_JAL), e);
    a = out_uop[0];
    check_bit("imm_j[0]", a.imm[0], 1'b0);
  endtask

  task automatic case04_imm_u_sign();
    uop_t e;
    // In RV64 LUI/AUIPC sign-extend the 32-bit immediate: NOT zero-extension.
    e = exp_init();
    e.valid = 1'b1;  e.imm = 64'hFFFF_FFFF_8000_0000;
    one("imm_u sign-extended (inst[31] = 1)", enc_u(20'h80000, 5'd3, OP_LUI), e);
  endtask

  task automatic case05_shamt_63();
    shift_i("SLLI shamt=63", {6'b000000, 6'd63}, 3'b001, ALU_SLL, 1'b0, 63);
    shift_i("SRLI shamt=63", {6'b000000, 6'd63}, 3'b101, ALU_SRL, 1'b0, 63);
    shift_i("SRAI shamt=63", {6'b010000, 6'd63}, 3'b101, ALU_SRA, 1'b0, 63);
  endtask

  task automatic case06_shamt_w();
    // shamt = 31 is the largest legal W shift; inst[25] = 1 means shamt >= 32,
    // which has no meaning on a 32-bit operand (section 9.3) -> illegal.
    shift_i("SLLIW shamt=31", {7'b0000000, 5'd31}, 3'b001, ALU_SLL, 1'b1, 31);
    shift_i("SRLIW shamt=31", {7'b0000000, 5'd31}, 3'b101, ALU_SRL, 1'b1, 31);
    shift_i("SRAIW shamt=31", {7'b0100000, 5'd31}, 3'b101, ALU_SRA, 1'b1, 31);
    illegal("SLLIW inst[25]=1",
            enc_i({6'b000000, 1'b1, 5'd31}, 5'd1, 3'b001, 5'd3, OP_OPIMM32));
    illegal("SRLIW inst[25]=1",
            enc_i({6'b000000, 1'b1, 5'd31}, 5'd1, 3'b101, 5'd3, OP_OPIMM32));
    illegal("SRAIW inst[25]=1",
            enc_i({6'b010000, 1'b1, 5'd31}, 5'd1, 3'b101, 5'd3, OP_OPIMM32));
  endtask

  task automatic case07_srl_vs_sra();
    // Same funct3 = 101; only the discriminator (funct6/funct7) changes.
    shift_i("SRLI vs SRAI: SRLI", {6'b000000, 6'd1}, 3'b101, ALU_SRL, 1'b0, 1);
    shift_i("SRLI vs SRAI: SRAI", {6'b010000, 6'd1}, 3'b101, ALU_SRA, 1'b0, 1);
    alu_rr("SRL vs SRA: SRL", 7'b0000000, 3'b101, ALU_SRL, 1'b0);
    alu_rr("SRL vs SRA: SRA", 7'b0100000, 3'b101, ALU_SRA, 1'b0);
  endtask

  task automatic case08_add_vs_mul();
    // Same opcode and funct3; funct7 = 0000001 is the only difference.
    alu_rr("ADD vs MUL: ADD", 7'b0000000, 3'b000, ALU_ADD, 1'b0);
    mul_rr("ADD vs MUL: MUL", 3'b000, MUL_LO, 1'b0);
  endtask

  task automatic case09_div_rem_illegal();
    // funct7 = 0000001 with funct3 >= 100 is DIV/DIVU/REM/REMU in OP, and the
    // W variants in OP-32: out of scope by decision 1.
    illegal("DIV",   enc_r(7'b0000001, 5'd2, 5'd1, 3'b100, 5'd3, OP_OP));
    illegal("DIVU",  enc_r(7'b0000001, 5'd2, 5'd1, 3'b101, 5'd3, OP_OP));
    illegal("REM",   enc_r(7'b0000001, 5'd2, 5'd1, 3'b110, 5'd3, OP_OP));
    illegal("REMU",  enc_r(7'b0000001, 5'd2, 5'd1, 3'b111, 5'd3, OP_OP));
    illegal("DIVW",  enc_r(7'b0000001, 5'd2, 5'd1, 3'b100, 5'd3, OP_OP32));
    illegal("DIVUW", enc_r(7'b0000001, 5'd2, 5'd1, 3'b101, 5'd3, OP_OP32));
    illegal("REMW",  enc_r(7'b0000001, 5'd2, 5'd1, 3'b110, 5'd3, OP_OP32));
    illegal("REMUW", enc_r(7'b0000001, 5'd2, 5'd1, 3'b111, 5'd3, OP_OP32));
  endtask

  task automatic case10_compressed_illegal();
    // inst[1:0] != 11 is a compressed instruction: out of scope (decision 1).
    illegal("inst[1:0] = 00", 32'h0000_0010);
    illegal("inst[1:0] = 01", 32'h0000_0011);
    illegal("inst[1:0] = 10", 32'h0000_0012);
  endtask

  task automatic case11_reserved_funct3();
    illegal("BRANCH funct3=010", enc_b(13'd8, 5'd2, 5'd1, 3'b010, OP_BRANCH));
    illegal("BRANCH funct3=011", enc_b(13'd8, 5'd2, 5'd1, 3'b011, OP_BRANCH));
    illegal("LOAD funct3=111",   enc_i(12'd4, 5'd1, 3'b111, 5'd3, OP_LOAD));
    illegal("STORE funct3=100",  enc_s(12'd4, 5'd2, 5'd1, 3'b100, OP_STORE));
    illegal("STORE funct3=101",  enc_s(12'd4, 5'd2, 5'd1, 3'b101, OP_STORE));
    illegal("STORE funct3=110",  enc_s(12'd4, 5'd2, 5'd1, 3'b110, OP_STORE));
    illegal("STORE funct3=111",  enc_s(12'd4, 5'd2, 5'd1, 3'b111, OP_STORE));
  endtask

  task automatic case12_serializing();
    uop_t e;
    e = exp_init();
    e.valid = 1'b1;  e.illegal = 1'b0;
    e.uop_class = UC_SYSTEM;  e.serializing = 1'b1;
    one("ECALL serializing",  32'h0000_0073, e);
    one("EBREAK serializing", 32'h0010_0073, e);
    // CSR accesses, decision 10. Only class and serializing are asserted: the
    // spec does not define rs1_valid for the uimm forms (CSRRWI and friends).
    one("CSRRW",  enc_i(12'h305, 5'd1, 3'b001, 5'd5, OP_SYSTEM), e);
    one("CSRRS",  enc_i(12'h305, 5'd1, 3'b010, 5'd5, OP_SYSTEM), e);
    one("CSRRC",  enc_i(12'h305, 5'd1, 3'b011, 5'd5, OP_SYSTEM), e);
    one("CSRRWI", enc_i(12'h305, 5'd1, 3'b101, 5'd5, OP_SYSTEM), e);
    one("CSRRSI", enc_i(12'h305, 5'd1, 3'b110, 5'd5, OP_SYSTEM), e);
    one("CSRRCI", enc_i(12'h305, 5'd1, 3'b111, 5'd5, OP_SYSTEM), e);
  endtask

  // ==========================================================================
  // Cases 13-20: intra-bundle dependencies (decision 3, section 8)
  // ==========================================================================
  // Every case needs at least 3 slots to say anything about "closest writer",
  // so with WIDTH < 3 they report SKIP instead of silently passing.

  task automatic case13_no_deps();
    if (WIDTH < 3) begin
      skip("case 13", "needs 3 slots");
    end else begin
      cur = "case 13: bundle with no dependencies";
      bundle_of_nops();
      b_inst[0] = enc_i(12'd1, 5'd1, 3'b000, 5'd3, OP_OPIMM);  // addi x3, x1, 1
      b_inst[1] = enc_i(12'd2, 5'd2, 3'b000, 5'd4, OP_OPIMM);  // addi x4, x2, 2
      b_inst[2] = enc_i(12'd3, 5'd5, 3'b000, 5'd6, OP_OPIMM);  // addi x6, x5, 3
      send_bundle(WIDTH'(3'b111));
      check_vec("rs1_in_bundle", out_dep_rs1_in_bundle, '0);
      check_vec("rs2_in_bundle", out_dep_rs2_in_bundle, '0);
    end
  endtask

  task automatic case14_slot1_reads_slot0();
    if (WIDTH < 2) begin
      skip("case 14", "needs 2 slots");
    end else begin
      cur = "case 14: slot 1 reads rd of slot 0";
      bundle_of_nops();
      b_inst[0] = enc_i(12'd1, 5'd1, 3'b000, 5'd5, OP_OPIMM);  // addi x5, x1, 1
      b_inst[1] = enc_i(12'd2, 5'd5, 3'b000, 5'd6, OP_OPIMM);  // addi x6, x5, 2
      send_bundle(~WIDTH'(0));
      check_vec("rs1_in_bundle", out_dep_rs1_in_bundle, WIDTH'(2));
      check_vec("rs2_in_bundle", out_dep_rs2_in_bundle, '0);
      chk_prod1(1, 0);
    end
  endtask

  task automatic case15_closest_writer();
    if (WIDTH < 3) begin
      skip("case 15", "needs 3 slots");
    end else begin
      cur = "case 15: closest writer wins (slots 0 and 1 both write x5)";
      bundle_of_nops();
      b_inst[0] = enc_i(12'd1, 5'd1, 3'b000, 5'd5, OP_OPIMM);  // addi x5, x1, 1
      b_inst[1] = enc_i(12'd2, 5'd2, 3'b000, 5'd5, OP_OPIMM);  // addi x5, x2, 2
      b_inst[2] = enc_i(12'd3, 5'd5, 3'b000, 5'd7, OP_OPIMM);  // addi x7, x5, 3
      send_bundle(WIDTH'(3'b111));
      check_vec("rs1_in_bundle", out_dep_rs1_in_bundle, WIDTH'(3'b100));
      chk_prod1(2, 1);                 // slot 1, the last writer -- not slot 0
    end
  endtask

  task automatic case16_same_reg_src_and_dst();
    if (WIDTH < 2) begin
      skip("case 16", "needs 2 slots");
    end else begin
      cur = "case 16: add x5, x5, x1 after a writer of x5 (no self-dependency)";
      bundle_of_nops();
      b_inst[0] = enc_i(12'd0, 5'd1, 3'b000, 5'd5, OP_OPIMM);           // addi x5, x1, 0
      b_inst[1] = enc_r(7'b0000000, 5'd1, 5'd5, 3'b000, 5'd5, OP_OP);   // add x5, x5, x1
      send_bundle(~WIDTH'(0));
      // the source dependency is detected...
      check_vec("rs1_in_bundle", out_dep_rs1_in_bundle, WIDTH'(2));
      chk_prod1(1, 0);
      // ...and writing the same register does not make slot 1 depend on itself
      check_vec("rs2_in_bundle", out_dep_rs2_in_bundle, '0);
    end
  endtask

  task automatic case17_x0_writers();
    uop_t e;
    if (WIDTH < 3) begin
      skip("case 17", "needs 3 slots");
    end else begin
      cur = "case 17: two writers of x0 and a reader of x0";
      bundle_of_nops();
      b_inst[0] = enc_i(12'd1, 5'd1, 3'b000, 5'd0, OP_OPIMM);  // addi x0, x1, 1
      b_inst[1] = enc_i(12'd2, 5'd2, 3'b000, 5'd0, OP_OPIMM);  // addi x0, x2, 2
      b_inst[2] = enc_i(12'd3, 5'd0, 3'b000, 5'd7, OP_OPIMM);  // addi x7, x0, 3
      send_bundle(WIDTH'(3'b111));
      // No intra-bundle dependency: a writer of x0 produces no value (section 9.4)
      check_vec("rs1_in_bundle", out_dep_rs1_in_bundle, '0);
      check_vec("rs2_in_bundle", out_dep_rs2_in_bundle, '0);
      // has_dest lowered on both writers
      e = exp_init();  e.has_dest = 1'b0;  e.rd = 5'd0;
      check_uop(0, e);
      check_uop(1, e);
      // and the source is lowered too, since x0 is already a known zero
      e = exp_init();  e.rs1_valid = 1'b0;
      check_uop(2, e);
    end
  endtask

  task automatic case18_rs2_and_both();
    if (WIDTH < 3) begin
      skip("case 18", "needs 3 slots");
    end else begin
      cur = "case 18: dependency through rs2, and through both sources at once";
      bundle_of_nops();
      b_inst[0] = enc_i(12'd1, 5'd1, 3'b000, 5'd5, OP_OPIMM);          // addi x5, x1, 1
      b_inst[1] = enc_r(7'b0000000, 5'd5, 5'd7, 3'b000, 5'd6, OP_OP);  // add x6, x7, x5
      b_inst[2] = enc_r(7'b0000000, 5'd6, 5'd5, 3'b000, 5'd8, OP_OP);  // add x8, x5, x6
      send_bundle(WIDTH'(3'b111));
      check_vec("rs1_in_bundle", out_dep_rs1_in_bundle, WIDTH'(3'b100));
      check_vec("rs2_in_bundle", out_dep_rs2_in_bundle, WIDTH'(3'b110));
      chk_prod1(2, 0);                 // x5 from slot 0
      chk_prod2(1, 0);                 // x5 from slot 0
      chk_prod2(2, 1);                 // x6 from slot 1
    end
  endtask

  task automatic case19_store_branch_never_produce();
    if (WIDTH < 3) begin
      skip("case 19", "needs 3 slots");
    end else begin
      cur = "case 19: store and branch are never producers (has_dest = 0)";
      bundle_of_nops();
      // In S and B formats inst[11:7] holds immediate bits, not rd. Both are
      // chosen so that a decoder wrongly reading rd there would invent a
      // dependency: the store's inst[11:7] = 5 and the branch's = 18.
      b_inst[0] = enc_s(12'd5,  5'd5, 5'd1, 3'b010, OP_STORE);          // sw x5, 5(x1)
      b_inst[1] = enc_b(13'd18, 5'd2, 5'd1, 3'b000, OP_BRANCH);         // beq x1, x2, 18
      b_inst[2] = enc_r(7'b0000000, 5'd18, 5'd5, 3'b000, 5'd9, OP_OP);  // add x9, x5, x18
      send_bundle(WIDTH'(3'b111));
      check_vec("rs1_in_bundle", out_dep_rs1_in_bundle, '0);
      check_vec("rs2_in_bundle", out_dep_rs2_in_bundle, '0);
    end
  endtask

  task automatic case20_dep_across_invalid_slot();
    if (WIDTH < 3) begin
      skip("case 20", "needs 3 slots");
    end else begin
      cur = "case 20: dependency crossing an invalid slot";
      bundle_of_nops();
      b_inst[0] = enc_i(12'd1, 5'd1, 3'b000, 5'd5, OP_OPIMM);  // addi x5, x1, 1  (valid)
      b_inst[1] = enc_i(12'd2, 5'd2, 3'b000, 5'd5, OP_OPIMM);  // addi x5, x2, 2  (INVALID slot)
      b_inst[2] = enc_i(12'd3, 5'd5, 3'b000, 5'd7, OP_OPIMM);  // addi x7, x5, 3
      send_bundle(WIDTH'(3'b101));
      check_vec("rs1_in_bundle", out_dep_rs1_in_bundle, WIDTH'(3'b100));
      // the invalid slot does not produce, so the producer is slot 0
      chk_prod1(2, 0);
    end
  endtask

  // ==========================================================================
  // Cases 21-28: stage behavior
  // ==========================================================================

  task automatic case21_full_bundle();
    uop_t e;
    cur = "case 21: full bundle decoded in one cycle";
    bundle_of_nops();
    for (int i = 0; i < 4; i++)
      b_inst[i] = enc_i(12'(i + 1), 5'd1, 3'b000, 5'(i + 10), OP_OPIMM);
    send_bundle(~WIDTH'(0));
    for (int i = 0; i < WIDTH; i++) begin
      e           = exp_init();
      e.valid     = 1'b1;
      e.illegal   = 1'b0;
      e.uop_class = UC_ALU;
      e.alu_op    = ALU_ADD;
      e.imm       = 64'(i + 1);
      e.rd        = 5'(i + 10);
      e.has_dest  = 1'b1;
      e.pc        = 64'h1000 + 64'(4 * i);
      check_uop(i, e);
    end
  endtask

  task automatic case22_partial_bundle();
    uop_t e;
    cur = "case 22: partial bundle, only slot 0 valid";
    bundle_of_nops();
    b_inst[0] = enc_i(12'd7, 5'd1, 3'b000, 5'd3, OP_OPIMM);
    send_bundle(WIDTH'(1));
    e = exp_init();  e.valid = 1'b1;
    check_uop(0, e);
    for (int i = 1; i < WIDTH; i++) begin
      e = exp_init();  e.valid = 1'b0;   // invalid slots carry uop.valid = 0
      check_uop(i, e);
    end

    if (WIDTH < 2) begin
      skip("case 22b", "needs 2 slots");
    end else begin
      cur = "case 22: partial bundle, slots 0 and 1 valid";
      b_inst[1] = enc_i(12'd8, 5'd1, 3'b000, 5'd4, OP_OPIMM);
      send_bundle(WIDTH'(3));
      e = exp_init();  e.valid = 1'b1;
      check_uop(0, e);
      check_uop(1, e);
      for (int i = 2; i < WIDTH; i++) begin
        e = exp_init();  e.valid = 1'b0;
        check_uop(i, e);
      end
    end
  endtask

  task automatic case23_backpressure();
    uop_t [WIDTH-1:0] snap;
    cur = "case 23: back-pressure, bundle leaves whole (decision 15)";
    bundle_of_nops();
    for (int i = 0; i < 4; i++)
      b_inst[i] = enc_i(12'(i + 1), 5'd1, 3'b000, 5'(i + 10), OP_OPIMM);
    @(negedge clk);
    out_ready = 1'b0;
    send_bundle(~WIDTH'(0));
    snap = out_uop;
    repeat (4) begin
      tick();
      check_bit("out_valid held while out_ready = 0", out_valid, 1'b1);
      check_bit("in_ready falls under back-pressure", in_ready, 1'b0);
      checks++;
      if (out_uop !== snap) fail("bundle changed while stalled");
    end
    out_ready = 1'b1;
    tick();
    check_bit("out_valid drops once drained", out_valid, 1'b0);
  endtask

  task automatic case24_flush_at_handshake();
    cur = "case 24: flush in the same cycle as the input handshake";
    bundle_of_nops();
    b_inst[0] = enc_i(12'd1, 5'd1, 3'b000, 5'd3, OP_OPIMM);
    @(negedge clk);
    in_inst   = '0;
    in_pc     = '0;
    for (int i = 0; i < WIDTH; i++) in_inst[i] = b_inst[i];
    in_slot_valid = ~WIDTH'(0);
    in_valid      = 1'b1;
    // wait until the stage would accept on the coming edge, then raise flush
    // while still between edges, so handshake and flush land on the same edge:
    // flush takes precedence (section 4)
    while (!in_ready) tick();
    flush = 1'b1;
    @(posedge clk);                 // handshake and flush together
    @(negedge clk);
    in_valid = 1'b0;
    flush    = 1'b0;
    check_bit("out_valid after flushed handshake", out_valid, 1'b0);
    tick();
    check_bit("out_valid stays low", out_valid, 1'b0);
  endtask

  task automatic case25_sync_reset();
    cur = "case 25: synchronous reset clears out_valid";
    bundle_of_nops();
    b_inst[0] = enc_i(12'd1, 5'd1, 3'b000, 5'd3, OP_OPIMM);
    @(negedge clk);
    out_ready = 1'b0;                  // keep the bundle parked at the output
    send_bundle(~WIDTH'(0));
    check_bit("out_valid before reset", out_valid, 1'b1);
    reset = 1'b1;
    @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    check_bit("out_valid one cycle after reset", out_valid, 1'b0);
    out_ready = 1'b1;
    tick();
  endtask

  task automatic case26_jal_slot0();
    cur = "case 26: JAL in slot 0 kills the slots to its right";
    if (WIDTH < 2) begin
      skip("case 26", "needs 2 slots");
    end else begin
      bundle_of_nops();
      b_inst[0] = enc_j(21'd16, 5'd1, OP_JAL);                 // jal x1, +16
      for (int i = 1; i < 4; i++)
        b_inst[i] = enc_i(12'd1, 5'd1, 3'b000, 5'd3, OP_OPIMM);
      send_bundle(~WIDTH'(0));
      check_bit("redirect_valid", redirect_valid, 1'b1);
      checks++;
      if (redirect_pc !== 64'h1000 + 64'd16)
        fail($sformatf("redirect_pc = 'h%0h, expected 'h%0h (pc0 + imm_j)",
                       redirect_pc, 64'h1000 + 64'd16));
      check_vec("out_slot_kill", out_slot_kill, ~WIDTH'(1));
      tick();
      check_bit("redirect_valid is a single pulse", redirect_valid, 1'b0);
    end
  endtask

  task automatic case27_jal_last_slot();
    cur = "case 27: JAL in the last slot kills nothing";
    bundle_of_nops();
    for (int i = 0; i < 4; i++)
      b_inst[i] = enc_i(12'd1, 5'd1, 3'b000, 5'd3, OP_OPIMM);
    b_inst[WIDTH-1] = enc_j(21'd16, 5'd1, OP_JAL);
    send_bundle(~WIDTH'(0));
    check_bit("redirect_valid", redirect_valid, 1'b1);
    check_vec("out_slot_kill", out_slot_kill, '0);
  endtask

  task automatic case28_two_jals();
    cur = "case 28: two JALs, only the first redirects";
    if (WIDTH < 2) begin
      skip("case 28", "needs 2 slots");
    end else begin
      bundle_of_nops();
      b_inst[0] = enc_j(21'd16, 5'd1, OP_JAL);    // taken: target 0x1010
      b_inst[1] = enc_j(21'd64, 5'd1, OP_JAL);    // already on the wrong path
      for (int i = 2; i < 4; i++)
        b_inst[i] = enc_i(12'd1, 5'd1, 3'b000, 5'd3, OP_OPIMM);
      send_bundle(~WIDTH'(0));
      check_bit("redirect_valid", redirect_valid, 1'b1);
      checks++;
      if (redirect_pc !== 64'h1000 + 64'd16)
        fail($sformatf("redirect_pc = 'h%0h, expected the FIRST jal target 'h%0h",
                       redirect_pc, 64'h1000 + 64'd16));
      check_vec("out_slot_kill", out_slot_kill, ~WIDTH'(1));
    end
  endtask

  // ==========================================================================
  // Sequence
  // ==========================================================================

  initial begin
    cur     = "init";
    checks  = 0;
    covered = 0;
    bundle_of_nops();
    do_reset();

    case01_all_57();
    case02_imm_i();
    case03_imm_b_j();
    case04_imm_u_sign();
    case05_shamt_63();
    case06_shamt_w();
    case07_srl_vs_sra();
    case08_add_vs_mul();
    case09_div_rem_illegal();
    case10_compressed_illegal();
    case11_reserved_funct3();
    case12_serializing();

    do_reset();
    case13_no_deps();                 tick();
    case14_slot1_reads_slot0();       tick();
    case15_closest_writer();          tick();
    case16_same_reg_src_and_dst();    tick();
    case17_x0_writers();              tick();
    case18_rs2_and_both();            tick();
    case19_store_branch_never_produce(); tick();
    case20_dep_across_invalid_slot(); tick();

    do_reset();
    case21_full_bundle();             tick();
    case22_partial_bundle();          tick();
    do_reset();
    case23_backpressure();
    do_reset();
    case24_flush_at_handshake();
    do_reset();
    case25_sync_reset();
    do_reset();
    case26_jal_slot0();               tick();
    do_reset();
    case27_jal_last_slot();           tick();
    do_reset();
    case28_two_jals();

    // Case 29 is the Makefile: PARAMS_decode runs this suite at WIDTH 1..4.
    $display("PASS decode_tb (WIDTH = %0d, %0d checks)", WIDTH, checks);
    $finish;
  end

endmodule
