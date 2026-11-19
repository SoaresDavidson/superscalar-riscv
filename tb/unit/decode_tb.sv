// Self-checking unit testbench for `decode`. Prints PASS at the end and calls
// $fatal on any failed check. Runs at WIDTH = 1, 2, 3 and 4 (PARAMS_decode in
// the Makefile); cases that need more slots than WIDTH provides are skipped
// and reported.
//
// ISA under test: RV64I, 52 instructions, NO multiplier (Decisoes-de-Projeto,
// decisions 1 and 11). Every funct7 = 0000001 encoding -- MUL as much as
// DIV/REM -- must come out illegal.
//
// Icarus 12.0 idiom (see AGENTS.md, "Icarus 12.0 limits"): a packed vector of
// structs may be indexed with a variable ONLY whole-element. `out_uop[i].rs1`
// with `int i` aborts the elaborator, so every access goes through a scalar
// struct temporary: `a = out_uop[i];` and then `a.rs1`. The dependency masks
// are checked either whole (a reduction over the 2-D vector) or at a LITERAL
// slot index, so no variable index is ever applied to them.

module decode_tb;

  import execute_pkg::*;

  // parameter, not localparam: the Makefile overrides it with -Pdecode_tb.WIDTH
  parameter int WIDTH = 3;

  // No `localparam int XLEN` here: the package is imported above, so XLEN is
  // already in scope. Redeclaring it shadowed the package name and tripped
  // VARHIDDEN in the linter -- the same trap that took the XLEN parameter out
  // of decode.sv. (Note: a comment whose first word is the linter's own name
  // is parsed as a pragma, hence the rewording.)

  // --- DUT wiring -----------------------------------------------------------

  logic                            clk, reset, flush;
  logic                            in_valid, in_ready;
  logic [WIDTH-1:0]                in_slot_valid;
  logic [WIDTH-1:0][31:0]          in_inst;
  logic [WIDTH-1:0][XLEN-1:0]      in_pc;

  logic                            out_valid, out_ready;
  uop_t [WIDTH-1:0]                out_uop;
  logic [WIDTH-1:0][WIDTH-1:0]     out_dep_rs1;
  logic [WIDTH-1:0][WIDTH-1:0]     out_dep_rs2;
  logic [WIDTH-1:0][WIDTH-1:0]     out_dep_rd;
  logic                            redirect_valid;
  logic [XLEN-1:0]                 redirect_pc;
  logic [WIDTH-1:0]                out_slot_kill;

  decode #(.WIDTH(WIDTH)) dut (.*);   // XLEN comes from the package

  // --- clock, watchdog, bookkeeping ----------------------------------------

  localparam int TIMEOUT_NS = 40000;

  string cur;        // name of the running case, printed on failure
  int    checks;     // how many checks actually ran

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Without this, a DUT that never raises in_ready would hang instead of
  // failing.
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

  // imm is the byte offset; bit 0 is not encoded (section 7). Dropping imm[0]
  // is the ISA, not an oversight, so the unused-bit warning is silenced here
  // rather than worked around.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [31:0] enc_b(logic [12:0] imm, logic [4:0] rs2,
                                        logic [4:0] rs1, logic [2:0] f3,
                                        logic [6:0] op);
    enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], op};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic [31:0] enc_u(logic [19:0] imm_hi, logic [4:0] rd,
                                        logic [6:0] op);
    enc_u = {imm_hi, rd, op};
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */   // imm[0] is implicit, as in enc_b
  function automatic logic [31:0] enc_j(logic [20:0] imm, logic [4:0] rd,
                                        logic [6:0] op);
    enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, op};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

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
    `CHK(op)
    `CHK(use_imm)
    `CHK(imm)
    `CHK(rs1)
    `CHK(rs1_valid)
    `CHK(rs2)
    `CHK(rs2_valid)
    `CHK(rd)
    `CHK(has_dest)
    `CHK(is_jal)
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

  // One slot's dependency mask. `want` is the producer slot, or -1 for "no
  // producer in this bundle". Built with a shift rather than a variable bit
  // write, to keep every index into a packed vector constant.
  task automatic chk_oh(string what, int slot, logic [WIDTH-1:0] got, int want);
    logic [WIDTH-1:0] w;
    checks++;
    w = (want < 0) ? WIDTH'(0) : (WIDTH'(1) << want);
    if (got !== w)
      fail($sformatf("%s[%0d] = 'b%0b, expected 'b%0b (producer %0d)",
                     what, slot, got, w, want));
  endtask

  // "Nothing depends on anything": one reduction over the whole 2-D mask.
  task automatic chk_no_deps();
    check_bit("any rs1 dependency", |out_dep_rs1, 1'b0);
    check_bit("any rs2 dependency", |out_dep_rs2, 1'b0);
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
    e           = exp_init();
    e.valid     = 1'b1;
    e.illegal   = 1'b1;
    e.op        = OP_NONE;
    e.has_dest  = 1'b0;
    e.rs1_valid = 1'b0;
    e.rs2_valid = 1'b0;
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
                        exec_op_t op, bit w);
    uop_t e;
    e             = exp_init();
    e.valid       = 1'b1;
    e.illegal     = 1'b0;
    e.op          = op;
    e.use_imm     = 1'b0;
    e.rs1         = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2         = 5'd2;  e.rs2_valid = 1'b1;
    e.rd          = 5'd3;  e.has_dest  = 1'b1;
    e.is_jal      = 1'b0;
    e.serializing = 1'b0;
    covered++;
    one(nm, enc_r(f7, 5'd2, 5'd1, f3, 5'd3, w ? OP_OP32 : OP_OP), e);
  endtask

  task automatic alu_ri(string nm, logic [11:0] imm, logic [2:0] f3,
                        exec_op_t op, bit w);
    uop_t e;
    e             = exp_init();
    e.valid       = 1'b1;
    e.illegal     = 1'b0;
    e.op          = op;
    e.use_imm     = 1'b1;
    e.imm         = {{52{imm[11]}}, imm};
    e.rs1         = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2_valid   = 1'b0;
    e.rd          = 5'd3;  e.has_dest  = 1'b1;
    e.is_jal      = 1'b0;
    e.serializing = 1'b0;
    covered++;
    one(nm, enc_i(imm, 5'd1, f3, 5'd3, w ? OP_OPIMM32 : OP_OPIMM), e);
  endtask

  // Immediate shifts: the immediate carries the shift amount, not imm_i
  // (section 7 says imm_i is not used, section 9.3 gives the shamt field).
  task automatic shift_i(string nm, logic [11:0] immfield, logic [2:0] f3,
                         exec_op_t op, bit w, int shamt);
    uop_t e;
    e             = exp_init();
    e.valid       = 1'b1;
    e.illegal     = 1'b0;
    e.op          = op;
    e.use_imm     = 1'b1;
    e.imm         = 64'(shamt);
    e.rs1         = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2_valid   = 1'b0;
    e.rd          = 5'd3;  e.has_dest  = 1'b1;
    e.serializing = 1'b0;
    covered++;
    one(nm, enc_i(immfield, 5'd1, f3, 5'd3, w ? OP_OPIMM32 : OP_OPIMM), e);
  endtask

  task automatic ld(string nm, logic [2:0] f3, exec_op_t op);
    uop_t e;
    e              = exp_init();
    e.valid        = 1'b1;
    e.illegal      = 1'b0;
    e.op           = op;
    e.use_imm      = 1'b1;
    e.imm          = 64'd16;
    e.rs1          = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2_valid    = 1'b0;
    e.rd           = 5'd3;  e.has_dest  = 1'b1;
    e.serializing  = 1'b0;
    covered++;
    one(nm, enc_i(12'd16, 5'd1, f3, 5'd3, OP_LOAD), e);
  endtask

  task automatic st(string nm, logic [2:0] f3, exec_op_t op);
    uop_t e;
    e             = exp_init();
    e.valid       = 1'b1;
    e.illegal     = 1'b0;
    e.op          = op;
    e.imm         = 64'd16;
    e.rs1         = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2         = 5'd2;  e.rs2_valid = 1'b1;
    e.has_dest    = 1'b0;      // S format never writes (section 6)
    e.serializing = 1'b0;
    covered++;
    one(nm, enc_s(12'd16, 5'd2, 5'd1, f3, OP_STORE), e);
  endtask

  task automatic br(string nm, logic [2:0] f3, exec_op_t op);
    uop_t e;
    e             = exp_init();
    e.valid       = 1'b1;
    e.illegal     = 1'b0;
    e.op          = op;
    e.imm         = 64'd32;
    e.rs1         = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2         = 5'd2;  e.rs2_valid = 1'b1;
    e.has_dest    = 1'b0;      // B format never writes (section 6)
    e.serializing = 1'b0;
    covered++;
    one(nm, enc_b(13'd32, 5'd2, 5'd1, f3, OP_BRANCH), e);
  endtask

  // ==========================================================================
  // Cases 1-12: encoding coverage
  // ==========================================================================

  task automatic case01_all_52();
    uop_t e;
    covered = 0;

    // --- U and J formats: no sources, one destination ---------------------
    // LUI: the result IS the immediate, so the op says so -- there is no
    // separate "operand A selects zero" field any more.
    e = exp_init();
    e.valid     = 1'b1;  e.illegal   = 1'b0;
    e.op        = ALU_LUI;
    e.use_imm   = 1'b1;
    e.imm       = 64'h0000_0000_1234_5000;
    e.rs1_valid = 1'b0;  e.rs2_valid = 1'b0;
    e.rd        = 5'd3;  e.has_dest  = 1'b1;
    e.is_jal    = 1'b0;  e.serializing = 1'b0;
    covered++;
    one("LUI", enc_u(20'h12345, 5'd3, OP_LUI), e);

    e.op   = ALU_AUIPC;                  // result = pc + imm
    e.imm  = 64'h0000_0000_0000_1000;
    covered++;
    one("AUIPC", enc_u(20'h00001, 5'd3, OP_AUIPC), e);

    // JAL: Fetch is redirected here (decision 7); the uop only has to write
    // the link value pc + 4, which is what ALU_PC4 means. imm stays imm_j
    // because it is what the redirect was computed from.
    e = exp_init();
    e.valid     = 1'b1;  e.illegal   = 1'b0;
    e.op        = ALU_PC4;
    e.imm       = 64'd2048;
    e.is_jal    = 1'b1;
    e.rs1_valid = 1'b0;  e.rs2_valid = 1'b0;
    e.rd        = 5'd1;  e.has_dest  = 1'b1;
    e.serializing = 1'b0;
    covered++;
    one("JAL", enc_j(21'd2048, 5'd1, OP_JAL), e);

    e = exp_init();
    e.valid     = 1'b1;  e.illegal   = 1'b0;
    e.op        = BR_JALR;
    e.use_imm   = 1'b1;
    e.imm       = 64'd8;
    e.is_jal    = 1'b0;                  // JALR is resolved in Execute
    e.rs1       = 5'd1;  e.rs1_valid = 1'b1;
    e.rs2_valid = 1'b0;
    e.rd        = 5'd1;  e.has_dest  = 1'b1;
    e.serializing = 1'b0;
    covered++;
    one("JALR", enc_i(12'd8, 5'd1, 3'b000, 5'd1, OP_JALR), e);

    // --- branches (6) -----------------------------------------------------
    br("BEQ",  3'b000, BR_BEQ);
    br("BNE",  3'b001, BR_BNE);
    br("BLT",  3'b100, BR_BLT);
    br("BGE",  3'b101, BR_BGE);
    br("BLTU", 3'b110, BR_BLTU);
    br("BGEU", 3'b111, BR_BGEU);

    // --- loads (7): size and signedness live in the op -------------------
    ld("LB",  3'b000, AGU_LB);
    ld("LH",  3'b001, AGU_LH);
    ld("LW",  3'b010, AGU_LW);
    ld("LD",  3'b011, AGU_LD);
    ld("LBU", 3'b100, AGU_LBU);
    ld("LHU", 3'b101, AGU_LHU);
    ld("LWU", 3'b110, AGU_LWU);

    // --- stores (4) -------------------------------------------------------
    st("SB", 3'b000, AGU_SB);
    st("SH", 3'b001, AGU_SH);
    st("SW", 3'b010, AGU_SW);
    st("SD", 3'b011, AGU_SD);

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

    // --- OP-IMM-32 (4): the W op says "32-bit", shamt is 5 bits ----------
    alu_ri("ADDIW",  12'd7, 3'b000, ALU_ADDW, 1'b1);
    shift_i("SLLIW", {7'b0000000, 5'd5}, 3'b001, ALU_SLLW, 1'b1, 5);
    shift_i("SRLIW", {7'b0000000, 5'd5}, 3'b101, ALU_SRLW, 1'b1, 5);
    shift_i("SRAIW", {7'b0100000, 5'd5}, 3'b101, ALU_SRAW, 1'b1, 5);

    // --- OP-32 (5) --------------------------------------------------------
    alu_rr("ADDW", 7'b0000000, 3'b000, ALU_ADDW, 1'b1);
    alu_rr("SUBW", 7'b0100000, 3'b000, ALU_SUBW, 1'b1);
    alu_rr("SLLW", 7'b0000000, 3'b001, ALU_SLLW, 1'b1);
    alu_rr("SRLW", 7'b0000000, 3'b101, ALU_SRLW, 1'b1);
    alu_rr("SRAW", 7'b0100000, 3'b101, ALU_SRAW, 1'b1);

    // --- MISC-MEM and SYSTEM (3) -----------------------------------------
    // No functional unit: fu_of(OP_NONE) is FU_NONE, and the `illegal` bit is
    // what tells a system instruction apart from a bad encoding.
    // FENCE's serializing is 1 as the conservative reading while decision 9
    // (nop or store-queue drain) is open -- draining is never wrong.
    e = exp_init();
    e.valid     = 1'b1;  e.illegal = 1'b0;
    e.op        = OP_NONE;
    e.rs1_valid = 1'b0;  e.rs2_valid = 1'b0;  e.has_dest = 1'b0;
    covered++;
    one("FENCE", 32'h0ff0000f, e);

    e.serializing = 1'b1;                 // decision 10
    covered++;
    one("ECALL", 32'h0000_0073, e);
    covered++;
    one("EBREAK", 32'h0010_0073, e);

    cur = "case 1 instruction count";
    checks++;
    if (covered != 52)
      fail($sformatf("exercised %0d instructions, RV64I without M has 52",
                     covered));
  endtask

  task automatic case02_imm_i();
    uop_t e;
    e = exp_init();
    e.valid = 1'b1;  e.imm = 64'd2047;
    one("imm_i = +2047", enc_i(12'h7FF, 5'd1, 3'b000, 5'd3, OP_OPIMM), e);
    e.imm = 64'hFFFF_FFFF_FFFF_F800;      // -2048, sign-extended to bit 63
    one("imm_i = -2048", enc_i(12'h800, 5'd1, 3'b000, 5'd3, OP_OPIMM), e);
  endtask

  // `a` is a whole uop_t but only a.imm[0] is read here: the slot has to be
  // copied whole (the Icarus rule), and this case is only about that one bit.
  /* verilator lint_off UNUSEDSIGNAL */
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
  /* verilator lint_on UNUSEDSIGNAL */

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
    shift_i("SLLIW shamt=31", {7'b0000000, 5'd31}, 3'b001, ALU_SLLW, 1'b1, 31);
    shift_i("SRLIW shamt=31", {7'b0000000, 5'd31}, 3'b101, ALU_SRLW, 1'b1, 31);
    shift_i("SRAIW shamt=31", {7'b0100000, 5'd31}, 3'b101, ALU_SRAW, 1'b1, 31);
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
    // Same opcode and funct3; funct7 = 0000001 is the only difference, and it
    // is now the difference between a legal ADD and an illegal MUL
    // (decision 11: there is no multiplier).
    alu_rr("ADD vs MUL: ADD", 7'b0000000, 3'b000, ALU_ADD, 1'b0);
    illegal("ADD vs MUL: MUL", enc_r(7'b0000001, 5'd2, 5'd1, 3'b000, 5'd3, OP_OP));
  endtask

  task automatic case09_m_ext_illegal();
    // The whole M extension is out of scope (decisions 1 and 11): funct7 =
    // 0000001 is illegal for EVERY funct3, in OP and in OP-32 alike. That is
    // MUL/MULH/MULHSU/MULHU and DIV/DIVU/REM/REMU, plus the W forms.
    illegal("MUL",    enc_r(7'b0000001, 5'd2, 5'd1, 3'b000, 5'd3, OP_OP));
    illegal("MULH",   enc_r(7'b0000001, 5'd2, 5'd1, 3'b001, 5'd3, OP_OP));
    illegal("MULHSU", enc_r(7'b0000001, 5'd2, 5'd1, 3'b010, 5'd3, OP_OP));
    illegal("MULHU",  enc_r(7'b0000001, 5'd2, 5'd1, 3'b011, 5'd3, OP_OP));
    illegal("DIV",    enc_r(7'b0000001, 5'd2, 5'd1, 3'b100, 5'd3, OP_OP));
    illegal("DIVU",   enc_r(7'b0000001, 5'd2, 5'd1, 3'b101, 5'd3, OP_OP));
    illegal("REM",    enc_r(7'b0000001, 5'd2, 5'd1, 3'b110, 5'd3, OP_OP));
    illegal("REMU",   enc_r(7'b0000001, 5'd2, 5'd1, 3'b111, 5'd3, OP_OP));
    illegal("MULW",   enc_r(7'b0000001, 5'd2, 5'd1, 3'b000, 5'd3, OP_OP32));
    illegal("DIVW",   enc_r(7'b0000001, 5'd2, 5'd1, 3'b100, 5'd3, OP_OP32));
    illegal("DIVUW",  enc_r(7'b0000001, 5'd2, 5'd1, 3'b101, 5'd3, OP_OP32));
    illegal("REMW",   enc_r(7'b0000001, 5'd2, 5'd1, 3'b110, 5'd3, OP_OP32));
    illegal("REMUW",  enc_r(7'b0000001, 5'd2, 5'd1, 3'b111, 5'd3, OP_OP32));
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
    illegal("JALR funct3=001",   enc_i(12'd8, 5'd1, 3'b001, 5'd1, OP_JALR));
    illegal("OP funct7=0001000", enc_r(7'b0001000, 5'd2, 5'd1, 3'b000, 5'd3, OP_OP));
    illegal("OP funct7=0100000 funct3=001",
            enc_r(7'b0100000, 5'd2, 5'd1, 3'b001, 5'd3, OP_OP));
    illegal("OP-32 funct3=010",  enc_r(7'b0000000, 5'd2, 5'd1, 3'b010, 5'd3, OP_OP32));
    illegal("OP-IMM-32 funct3=010",
            enc_i(12'd4, 5'd1, 3'b010, 5'd3, OP_OPIMM32));
  endtask

  task automatic case12_serializing();
    uop_t e;
    e = exp_init();
    e.valid = 1'b1;  e.illegal = 1'b0;
    e.op = OP_NONE;  e.serializing = 1'b1;
    one("ECALL serializing",  32'h0000_0073, e);
    one("EBREAK serializing", 32'h0010_0073, e);
    // CSR accesses, decision 10. Only op and serializing are asserted: which
    // operands the CSR forms really use is still open, so the spec does not
    // define rs1_valid/has_dest for them yet.
    one("CSRRW",  enc_i(12'h305, 5'd1, 3'b001, 5'd5, OP_SYSTEM), e);
    one("CSRRS",  enc_i(12'h305, 5'd1, 3'b010, 5'd5, OP_SYSTEM), e);
    one("CSRRC",  enc_i(12'h305, 5'd1, 3'b011, 5'd5, OP_SYSTEM), e);
    one("CSRRWI", enc_i(12'h305, 5'd1, 3'b101, 5'd5, OP_SYSTEM), e);
    one("CSRRSI", enc_i(12'h305, 5'd1, 3'b110, 5'd5, OP_SYSTEM), e);
    one("CSRRCI", enc_i(12'h305, 5'd1, 3'b111, 5'd5, OP_SYSTEM), e);
    // FENCE.I drains too (decision 9 open; draining is the safe reading)
    one("FENCE.I", enc_i(12'd0, 5'd0, 3'b001, 5'd0, OP_MISCMEM), e);
  endtask

  // ==========================================================================
  // Cases 13-20: intra-bundle dependencies (decision 3, section 8)
  // ==========================================================================
  // The masks are one-hot over the bundle: bit j of slot i's mask marks the
  // closest earlier writer. Most cases need at least 3 slots to say anything
  // about "closest", so with WIDTH < 3 they report SKIP rather than silently
  // passing.

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
      chk_no_deps();
      // distinct destinations, so no WAW either
      check_bit("any rd dependency", |out_dep_rd, 1'b0);
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
      chk_oh("rs1_dep", 0, out_dep_rs1[0], -1);
      chk_oh("rs1_dep", 1, out_dep_rs1[1],  0);
      check_bit("any rs2 dependency", |out_dep_rs2, 1'b0);
      check_bit("any rd dependency",  |out_dep_rd,  1'b0);
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
      chk_oh("rs1_dep", 2, out_dep_rs1[2], 1);   // slot 1, NOT slot 0
      // and the WAW between slots 0 and 1 is reported on rd
      chk_oh("rd_dep",  0, out_dep_rd[0], -1);
      chk_oh("rd_dep",  1, out_dep_rd[1],  0);
      chk_oh("rd_dep",  2, out_dep_rd[2], -1);   // slot 2 writes x7, nobody else does
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
      chk_oh("rs1_dep", 1, out_dep_rs1[1], 0);
      // ...the second source (x1) has no producer here...
      check_bit("any rs2 dependency", |out_dep_rs2, 1'b0);
      // ...and writing the same register is a WAW on rd, not a dependency of
      // slot 1 on itself: the mask points at slot 0.
      chk_oh("rd_dep", 1, out_dep_rd[1], 0);
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
      // No intra-bundle dependency: a writer of x0 produces no value and
      // allocates no tag (section 9.4), so it cannot be anyone's producer --
      // not even for the WAW mask between the two x0 writers.
      chk_no_deps();
      check_bit("any rd dependency", |out_dep_rd, 1'b0);
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
      chk_oh("rs1_dep", 1, out_dep_rs1[1], -1);  // x7: no producer
      chk_oh("rs1_dep", 2, out_dep_rs1[2],  0);  // x5 from slot 0
      chk_oh("rs2_dep", 1, out_dep_rs2[1],  0);  // x5 from slot 0
      chk_oh("rs2_dep", 2, out_dep_rs2[2],  1);  // x6 from slot 1
      check_bit("any rd dependency", |out_dep_rd, 1'b0);  // x5, x6, x8 distinct
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
      chk_no_deps();
      check_bit("any rd dependency", |out_dep_rd, 1'b0);
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
      // the invalid slot does not produce, so the producer is slot 0
      chk_oh("rs1_dep", 2, out_dep_rs1[2], 0);
      // nor does it take part in the WAW mask
      chk_oh("rd_dep",  1, out_dep_rd[1], -1);
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
      e          = exp_init();
      e.valid    = 1'b1;
      e.illegal  = 1'b0;
      e.op       = ALU_ADD;
      e.use_imm  = 1'b1;
      e.imm      = 64'(i) + 64'd1;
      e.rd       = 5'(i + 10);
      e.has_dest = 1'b1;
      e.pc       = 64'h1000 + 64'(4 * i);
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
    uop_t e;
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
      // a killed slot reaches Rename invalid, so it allocates nothing
      e = exp_init();  e.valid = 1'b0;
      check_uop(1, e);
      // and it is nobody's producer: slot 1 writes x3, slot 2 reads x1
      check_bit("killed slot produces nothing", |out_dep_rd, 1'b0);
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
  // Cases 29-31: the WAW mask the rename needs for old_tag
  // ==========================================================================
  // Without rd_dep, two writers of the same register in one bundle would both
  // report the pre-bundle tag as old_tag. The ROB would then hand the same
  // commit_old_tag back twice: that tag enters the free list twice while the
  // intermediate one leaks. These cases pin the mask down.

  task automatic case29_waw_chain();
    if (WIDTH < 3) begin
      skip("case 29", "needs 3 slots");
    end else begin
      cur = "case 29: three writers of x5, each old_tag chains to the previous";
      bundle_of_nops();
      b_inst[0] = enc_i(12'd1, 5'd1, 3'b000, 5'd5, OP_OPIMM);  // addi x5, x1, 1
      b_inst[1] = enc_i(12'd2, 5'd2, 3'b000, 5'd5, OP_OPIMM);  // addi x5, x2, 2
      b_inst[2] = enc_i(12'd3, 5'd3, 3'b000, 5'd5, OP_OPIMM);  // addi x5, x3, 3
      send_bundle(WIDTH'(3'b111));
      chk_oh("rd_dep", 0, out_dep_rd[0], -1);  // first writer: tag from the map
      chk_oh("rd_dep", 1, out_dep_rd[1],  0);
      chk_oh("rd_dep", 2, out_dep_rd[2],  1);  // the CLOSEST, not slot 0
      // no source reads x5, so the source masks stay empty
      chk_no_deps();
    end
  endtask

  task automatic case30_waw_non_allocating();
    if (WIDTH < 3) begin
      skip("case 30", "needs 3 slots");
    end else begin
      cur = "case 30: a slot that allocates nothing has an empty rd mask";
      bundle_of_nops();
      b_inst[0] = enc_i(12'd1, 5'd1, 3'b000, 5'd5, OP_OPIMM);   // addi x5, x1, 1
      b_inst[1] = enc_s(12'd5, 5'd5, 5'd1, 3'b010, OP_STORE);   // sw x5, 5(x1): no rd
      b_inst[2] = enc_i(12'd3, 5'd1, 3'b000, 5'd5, OP_OPIMM);   // addi x5, x1, 3
      send_bundle(WIDTH'(3'b111));
      // the store does not allocate, so it asks for no old_tag...
      chk_oh("rd_dep", 1, out_dep_rd[1], -1);
      // ...and it does not break the chain either: slot 2 still points at
      // slot 0, the closest slot that actually allocated x5.
      chk_oh("rd_dep", 2, out_dep_rd[2], 0);
      // the store reads x5, which slot 0 writes
      chk_oh("rs2_dep", 1, out_dep_rs2[1], 0);
    end
  endtask

  task automatic case31_waw_different_regs();
    if (WIDTH < 2) begin
      skip("case 31", "needs 2 slots");
    end else begin
      cur = "case 31: writers of different registers are not a WAW";
      bundle_of_nops();
      b_inst[0] = enc_i(12'd1, 5'd1, 3'b000, 5'd5, OP_OPIMM);  // addi x5, x1, 1
      b_inst[1] = enc_i(12'd2, 5'd1, 3'b000, 5'd6, OP_OPIMM);  // addi x6, x1, 2
      send_bundle(~WIDTH'(0));
      check_bit("any rd dependency", |out_dep_rd, 1'b0);
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

    case01_all_52();
    case02_imm_i();
    case03_imm_b_j();
    case04_imm_u_sign();
    case05_shamt_63();
    case06_shamt_w();
    case07_srl_vs_sra();
    case08_add_vs_mul();
    case09_m_ext_illegal();
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

    do_reset();
    case29_waw_chain();               tick();
    case30_waw_non_allocating();      tick();
    case31_waw_different_regs();      tick();

    // Case 32 is the Makefile: PARAMS_decode runs this suite at WIDTH 1..4.
    $display("PASS decode_tb (WIDTH = %0d, %0d checks)", WIDTH, checks);
    $finish;
  end

endmodule
