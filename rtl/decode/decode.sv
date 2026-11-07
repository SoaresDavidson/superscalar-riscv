// Decode stage: WIDTH instructions per cycle, plus intra-bundle dependency
// resolution (decision 3). Specified in docsDecode/Decode.md; interface
// contract in rtl/decode/README.md.
//
// Per-slot decoders are identical and independent: every RISC-V format puts
// opcode and the register specifiers in the same bits (decision 3), so each
// slot slices its fields with no reference to the others. Only three things
// are bundle-wide: the intra-bundle dependency masks, the JAL redirect, and
// the kill mask it implies.
//
// Icarus 12.0 idioms this file obeys (AGENTS.md, "Icarus 12.0 limits"):
//   - per-slot vectors are indexed with a genvar inside a generate loop, and
//     the indexed target is always a continuous `assign`, never an always_comb
//     target (which elaborates with "has no sensitivities");
//   - a struct element is never read as arr[i].field: it is copied to a
//     scalar temporary first;
//   - "closest previous writer" loops upward with no `break` and lets the
//     last write win, because `break` is silently ignored;
//   - internal per-slot wide values are UNPACKED arrays, so a variable index
//     into them can never become the "variable index + second select" form
//     that aborts the elaborator;
//   - no CONSTANT select of any kind is read inside an always_* block --
//     neither a genvar index like uses_rs1[i] nor a plain part-select like
//     inst[31:20]. Icarus answers "sorry: constant selects in always_*
//     processes are not currently supported (all bits will be included)" and
//     widens the sensitivity list to the whole vector. The behavior stays
//     correct, but a `sorry:` left in the build is noise that hides the next
//     one, so every such read is hoisted into a continuous assign first.
//     A VARIABLE select inside always_* is fine and needs no hoisting.
module decode
  import execute_pkg::*;
#(
  // WIDTH is the only parameter: it must never be a literal 3 anywhere in the
  // RTL (decision 2). XLEN is NOT a parameter here, and deliberately so --
  // it comes from the package, exactly as alu.sv and agu.sv take it. An
  // overridable XLEN would silently disagree with uop_t, whose `pc` and `imm`
  // are xlen_t and therefore fixed at the PACKAGE width: ports would be one
  // width and the struct another, with no error anywhere.
  parameter int WIDTH = 3
) (
  input  logic                              clk,
  input  logic                              reset,  // synchronous, active high
  input  logic                              flush,  // cancels speculative state

  // --- input: Fetch -> Decode ---------------------------------------------
  input  logic                              in_valid,
  output logic                              in_ready,
  input  logic [WIDTH-1:0]                  in_slot_valid,
  input  logic [WIDTH-1:0][31:0]            in_inst,
  input  logic [WIDTH-1:0][XLEN-1:0]        in_pc,

  // --- output: Decode -> Register Rename / Dispatch ------------------------
  output logic                              out_valid,
  input  logic                              out_ready,
  output uop_t [WIDTH-1:0]                  out_uop,

  // Intra-bundle dependencies (decision 3), one one-hot mask of WIDTH bits
  // per slot. Bit j of slot i's mask (always j < i) marks the CLOSEST earlier
  // writer of that register inside this same bundle; all-zero means none.
  // This is the format Register-Rename consumes directly: rs1/rs2 chain the
  // producer's dst_tag into the source, and rd chains it into old_tag.
  output logic [WIDTH-1:0][WIDTH-1:0]       out_dep_rs1,
  output logic [WIDTH-1:0][WIDTH-1:0]       out_dep_rs2,
  output logic [WIDTH-1:0][WIDTH-1:0]       out_dep_rd,

  // --- JAL redirect (decision 7, spec section 10) --------------------------
  output logic                              redirect_valid,
  output logic [XLEN-1:0]                   redirect_pc,
  output logic [WIDTH-1:0]                  out_slot_kill
);

  // ======================================================================
  // Opcodes (RV64I, 32-bit encodings)
  // ======================================================================
  localparam logic [6:0] OP_LUI     = 7'b0110111;
  localparam logic [6:0] OP_AUIPC   = 7'b0010111;
  localparam logic [6:0] OP_JAL     = 7'b1101111;
  localparam logic [6:0] OP_JALR    = 7'b1100111;
  localparam logic [6:0] OP_BRANCH  = 7'b1100011;
  localparam logic [6:0] OP_LOAD    = 7'b0000011;
  localparam logic [6:0] OP_STORE   = 7'b0100011;
  localparam logic [6:0] OP_OPIMM   = 7'b0010011;
  localparam logic [6:0] OP_OP      = 7'b0110011;
  localparam logic [6:0] OP_OPIMM32 = 7'b0011011;
  localparam logic [6:0] OP_OP32    = 7'b0111011;
  localparam logic [6:0] OP_MISCMEM = 7'b0001111;
  localparam logic [6:0] OP_SYSTEM  = 7'b1110011;

  // ======================================================================
  // Per-slot decode (unpacked: see the Icarus note above)
  // ======================================================================
  uop_t            dec       [WIDTH];   // slot decoded on its own
  logic [XLEN-1:0] jal_tgt   [WIDTH];   // pc + imm_j, meaningful when is_jal
  logic [ REG_W-1:0] rd_of   [WIDTH];
  logic [ REG_W-1:0] rs1_of  [WIDTH];
  logic [ REG_W-1:0] rs2_of  [WIDTH];
  logic            uses_rs1  [WIDTH];
  logic            uses_rs2  [WIDTH];

  logic [WIDTH-1:0] is_jal;     // a JAL on the right path, by slot
  logic [WIDTH-1:0] kill;       // slot is to the right of a JAL
  logic [WIDTH-1:0] slot_live;  // slot carries an instruction we keep
  logic [WIDTH-1:0] produces;   // slot allocates a destination

  for (genvar k = 0; k < WIDTH; k++) begin : g_slot
    logic [31:0]     inst;
    logic [XLEN-1:0] pc_k;

    assign inst = in_inst[k];
    assign pc_k = in_pc[k];

    // --- speculative field extraction (decision 3): fixed positions, sliced
    // before the format is known; the opcode then decides which are real.
    logic [6:0] opcode, funct7;
    logic [2:0] funct3;
    logic [4:0] i_rd, i_rs1, i_rs2;
    logic       alt;        // funct7[5] / funct6[4]: SUB vs ADD, SRA vs SRL
    logic       m_ext;      // funct7 = 0000001: the M extension, out of scope

    assign opcode = inst[6:0];
    assign funct3 = inst[14:12];
    assign funct7 = inst[31:25];
    assign i_rd   = inst[11:7];
    assign i_rs1  = inst[19:15];
    assign i_rs2  = inst[24:20];
    assign alt    = inst[30];
    assign m_ext  = (inst[31:25] == 7'b0000001);

    // --- immediates (spec section 7), each already sign-extended to XLEN
    logic [XLEN-1:0] imm_i, imm_s, imm_b, imm_u, imm_j, shamt6, shamt5;

    assign imm_i  = {{(XLEN-12){inst[31]}}, inst[31:20]};
    assign imm_s  = {{(XLEN-12){inst[31]}}, inst[31:25], inst[11:7]};
    assign imm_b  = {{(XLEN-12){inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
    assign imm_u  = {{(XLEN-32){inst[31]}}, inst[31:12], 12'b0};
    assign imm_j  = {{(XLEN-20){inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};
    // Shifts carry the shift amount in the immediate, not imm_i: 6 bits in
    // the 64-bit forms, 5 in the W forms (spec section 9.3).
    assign shamt6 = {{(XLEN-6){1'b0}}, inst[25:20]};
    assign shamt5 = {{(XLEN-5){1'b0}}, inst[24:20]};

    // funct6 / funct7 legality for the immediate shifts
    logic sh6_ok, sh7_ok;
    assign sh6_ok = (inst[31] == 1'b0) && (inst[29:26] == 4'b0000);  // 0b0?0000
    assign sh7_ok = (inst[31] == 1'b0) && (inst[29:25] == 5'b00000); // 0b0?00000

    // Hoisted out of the always_comb below: ANY constant select read there
    // makes Icarus give up on the sensitivity list (see the file header).
    logic        slot_valid_k;
    logic [1:0]  quadrant;   // inst[1:0]: 11 for every 32-bit encoding
    logic [5:0]  funct6;     // the 64-bit immediate shifts discriminate on 6 bits
    logic [11:0] imm12;      // inst[31:20] whole, to tell ECALL from EBREAK
    assign slot_valid_k = in_slot_valid[k];
    assign quadrant     = inst[1:0];
    assign funct6       = inst[31:26];
    assign imm12        = inst[31:20];

    uop_t u;
    logic want_rs1, want_rs2, want_rd;
    // A local flag instead of reading the struct field back mid-block: a
    // field select is a constant select too (see the file header).
    logic bad;

    always_comb begin
      // Defaults: no operands, no destination, no FU. Everything below only
      // ever turns things ON, so an unrecognized encoding falls through as a
      // clean illegal uop.
      u.valid       = slot_valid_k;        // overridden by slot_live further down
      u.pc          = pc_k;
      u.op          = OP_NONE;
      u.use_imm     = 1'b0;
      u.imm         = '0;
      u.rs1         = i_rs1;
      u.rs1_valid   = 1'b0;
      u.rs2         = i_rs2;
      u.rs2_valid   = 1'b0;
      u.rd          = i_rd;
      u.has_dest    = 1'b0;
      u.is_jal      = 1'b0;
      u.serializing = 1'b0;
      bad           = 1'b0;
      want_rs1      = 1'b0;
      want_rs2      = 1'b0;
      want_rd       = 1'b0;

      if (quadrant != 2'b11) begin
        // 16-bit compressed encoding: the C extension is out of scope (dec. 1)
        bad = 1'b1;
      end else begin
        case (opcode)
          // --- U format: no sources, one destination --------------------
          OP_LUI: begin
            u.op      = ALU_LUI;
            u.use_imm = 1'b1;
            u.imm     = imm_u;
            want_rd   = 1'b1;
          end
          OP_AUIPC: begin
            u.op      = ALU_AUIPC;
            u.use_imm = 1'b1;
            u.imm     = imm_u;
            want_rd   = 1'b1;
          end

          // --- J format: target resolved here, link value from the ALU ---
          OP_JAL: begin
            u.op     = ALU_PC4;     // rd = pc + 4
            u.imm    = imm_j;       // kept for the redirect below
            u.is_jal = 1'b1;
            want_rd  = 1'b1;
          end

          // --- JALR: the Branch Unit resolves it and links pc + 4 --------
          OP_JALR: begin
            if (funct3 != 3'b000) begin
              bad = 1'b1;
            end else begin
              u.op      = BR_JALR;
              u.use_imm = 1'b1;
              u.imm     = imm_i;
              want_rs1  = 1'b1;
              want_rd   = 1'b1;
            end
          end

          // --- B format: two sources, never a destination ----------------
          OP_BRANCH: begin
            u.imm    = imm_b;
            want_rs1 = 1'b1;
            want_rs2 = 1'b1;
            case (funct3)
              3'b000:  u.op = BR_BEQ;
              3'b001:  u.op = BR_BNE;
              3'b100:  u.op = BR_BLT;
              3'b101:  u.op = BR_BGE;
              3'b110:  u.op = BR_BLTU;
              3'b111:  u.op = BR_BGEU;
              default: begin                 // funct3 010 and 011 are reserved
                bad = 1'b1;
                want_rs1  = 1'b0;
                want_rs2  = 1'b0;
              end
            endcase
          end

          // --- loads: address is rs1 + imm, size and signedness in the op -
          OP_LOAD: begin
            u.use_imm = 1'b1;
            u.imm     = imm_i;
            want_rs1  = 1'b1;
            want_rd   = 1'b1;
            case (funct3)
              3'b000:  u.op = AGU_LB;
              3'b001:  u.op = AGU_LH;
              3'b010:  u.op = AGU_LW;
              3'b011:  u.op = AGU_LD;
              3'b100:  u.op = AGU_LBU;
              3'b101:  u.op = AGU_LHU;
              3'b110:  u.op = AGU_LWU;
              default: begin                 // funct3 111 is reserved
                bad = 1'b1;
                want_rs1  = 1'b0;
                want_rd   = 1'b0;
              end
            endcase
          end

          // --- stores: rs2 is the data, never a destination --------------
          OP_STORE: begin
            u.use_imm = 1'b1;
            u.imm     = imm_s;
            want_rs1  = 1'b1;
            want_rs2  = 1'b1;
            case (funct3)
              3'b000:  u.op = AGU_SB;
              3'b001:  u.op = AGU_SH;
              3'b010:  u.op = AGU_SW;
              3'b011:  u.op = AGU_SD;
              default: begin                 // funct3 100..111 are reserved
                bad = 1'b1;
                want_rs1  = 1'b0;
                want_rs2  = 1'b0;
              end
            endcase
          end

          // --- OP-IMM ----------------------------------------------------
          OP_OPIMM: begin
            u.use_imm = 1'b1;
            u.imm     = imm_i;
            want_rs1  = 1'b1;
            want_rd   = 1'b1;
            case (funct3)
              3'b000:  u.op = ALU_ADD;
              3'b010:  u.op = ALU_SLT;
              3'b011:  u.op = ALU_SLTU;
              3'b100:  u.op = ALU_XOR;
              3'b110:  u.op = ALU_OR;
              3'b111:  u.op = ALU_AND;
              3'b001: begin                  // SLLI
                u.imm = shamt6;
                if (funct6 == 6'b000000) begin
                  u.op = ALU_SLL;
                end else begin
                  bad = 1'b1;
                  want_rs1  = 1'b0;
                  want_rd   = 1'b0;
                end
              end
              default: begin                 // funct3 101: SRLI / SRAI
                u.imm = shamt6;
                if (sh6_ok) begin
                  u.op = alt ? ALU_SRA : ALU_SRL;
                end else begin
                  bad = 1'b1;
                  want_rs1  = 1'b0;
                  want_rd   = 1'b0;
                end
              end
            endcase
          end

          // --- OP-IMM-32: W forms, 32-bit op, 5-bit shamt ----------------
          OP_OPIMM32: begin
            u.use_imm = 1'b1;
            u.imm     = imm_i;
            want_rs1  = 1'b1;
            want_rd   = 1'b1;
            case (funct3)
              3'b000:  u.op = ALU_ADDW;
              3'b001: begin                  // SLLIW
                u.imm = shamt5;
                if (funct7 == 7'b0000000) begin
                  u.op = ALU_SLLW;
                end else begin
                  // inst[25] set would mean shamt >= 32, meaningless on a
                  // 32-bit operand (spec section 9.3)
                  bad = 1'b1;
                  want_rs1  = 1'b0;
                  want_rd   = 1'b0;
                end
              end
              3'b101: begin                  // SRLIW / SRAIW
                u.imm = shamt5;
                if (sh7_ok) begin
                  u.op = alt ? ALU_SRAW : ALU_SRLW;
                end else begin
                  bad = 1'b1;
                  want_rs1  = 1'b0;
                  want_rd   = 1'b0;
                end
              end
              default: begin
                bad = 1'b1;
                want_rs1  = 1'b0;
                want_rd   = 1'b0;
              end
            endcase
          end

          // --- OP: register-register, 64-bit -----------------------------
          OP_OP: begin
            want_rs1 = 1'b1;
            want_rs2 = 1'b1;
            want_rd  = 1'b1;
            if (m_ext) begin
              // funct7 = 0000001 is the M extension: MUL and DIV/REM alike
              // are out of scope (decisions 1 and 11 -- there is no
              // multiplier in Execute).
              bad = 1'b1;
              want_rs1  = 1'b0;
              want_rs2  = 1'b0;
              want_rd   = 1'b0;
            end else if (funct7 == 7'b0000000) begin
              case (funct3)
                3'b000:  u.op = ALU_ADD;
                3'b001:  u.op = ALU_SLL;
                3'b010:  u.op = ALU_SLT;
                3'b011:  u.op = ALU_SLTU;
                3'b100:  u.op = ALU_XOR;
                3'b101:  u.op = ALU_SRL;
                3'b110:  u.op = ALU_OR;
                default: u.op = ALU_AND;     // funct3 111
              endcase
            end else if (funct7 == 7'b0100000) begin
              case (funct3)
                3'b000:  u.op = ALU_SUB;
                3'b101:  u.op = ALU_SRA;
                default: begin
                  bad = 1'b1;
                  want_rs1  = 1'b0;
                  want_rs2  = 1'b0;
                  want_rd   = 1'b0;
                end
              endcase
            end else begin
              bad = 1'b1;
              want_rs1  = 1'b0;
              want_rs2  = 1'b0;
              want_rd   = 1'b0;
            end
          end

          // --- OP-32: register-register, W forms -------------------------
          OP_OP32: begin
            want_rs1 = 1'b1;
            want_rs2 = 1'b1;
            want_rd  = 1'b1;
            if (m_ext) begin                 // MULW, DIVW, DIVUW, REMW, REMUW
              bad = 1'b1;
              want_rs1  = 1'b0;
              want_rs2  = 1'b0;
              want_rd   = 1'b0;
            end else if (funct7 == 7'b0000000) begin
              case (funct3)
                3'b000:  u.op = ALU_ADDW;
                3'b001:  u.op = ALU_SLLW;
                3'b101:  u.op = ALU_SRLW;
                default: begin
                  bad = 1'b1;
                  want_rs1  = 1'b0;
                  want_rs2  = 1'b0;
                  want_rd   = 1'b0;
                end
              endcase
            end else if (funct7 == 7'b0100000) begin
              case (funct3)
                3'b000:  u.op = ALU_SUBW;
                3'b101:  u.op = ALU_SRAW;
                default: begin
                  bad = 1'b1;
                  want_rs1  = 1'b0;
                  want_rs2  = 1'b0;
                  want_rd   = 1'b0;
                end
              endcase
            end else begin
              bad = 1'b1;
              want_rs1  = 1'b0;
              want_rs2  = 1'b0;
              want_rd   = 1'b0;
            end
          end

          // --- MISC-MEM: FENCE / FENCE.I ---------------------------------
          // No FU and no operands. serializing = 1 is the CONSERVATIVE
          // choice while decision 9 is open: draining is always correct,
          // treating a fence as a nop is only correct if the group settles
          // on that. Lowering this flag later is an optimization; raising it
          // later would be a bug fix.
          OP_MISCMEM: begin
            if (funct3 == 3'b000 || funct3 == 3'b001) begin
              u.serializing = 1'b1;
            end else begin
              bad = 1'b1;
            end
          end

          // --- SYSTEM: ECALL / EBREAK / CSR access -----------------------
          // All serializing (decision 10) and all without a FU. The CSR
          // forms do not declare operands yet: which of rs1/rd/uimm they
          // really use depends on decision 10, still open.
          OP_SYSTEM: begin
            if (funct3 == 3'b000) begin
              if (imm12 == 12'h000 || imm12 == 12'h001) begin
                u.serializing = 1'b1;        // ECALL, EBREAK
              end else begin
                bad = 1'b1;            // MRET and friends: out of scope
              end
            end else if (funct3 == 3'b100) begin
              bad = 1'b1;              // reserved
            end else begin
              u.serializing = 1'b1;          // CSRRW/S/C and the immediate forms
            end
          end

          default: bad = 1'b1;
        endcase
      end

      // x0 never allocates and always reads zero (decision 5). An illegal
      // encoding allocates nothing either (spec section 9.5).
      u.illegal   = bad;
      u.rs1_valid = want_rs1 && (i_rs1 != 5'd0) && !bad;
      u.rs2_valid = want_rs2 && (i_rs2 != 5'd0) && !bad;
      u.has_dest  = want_rd  && (i_rd  != 5'd0) && !bad;
    end

    assign dec[k]     = u;
    assign jal_tgt[k] = pc_k + imm_j;

    // Bundle-wide views of this slot. `u` is already a scalar struct, so its
    // fields are read directly; what must never happen is dec[k].field.
    assign rd_of[k]    = u.rd;
    assign rs1_of[k]   = u.rs1;
    assign rs2_of[k]   = u.rs2;
    assign is_jal[k]   = in_slot_valid[k] && u.is_jal;

    // A slot to the right of a JAL is on the wrong path: it neither produces
    // nor consumes a dependency. Prefix OR over the earlier slots; the k = 0
    // arm is a generate-if because is_jal[-1:0] is not a legal part-select.
    if (k == 0) begin : g_kill0
      assign kill[0] = 1'b0;
    end else begin : g_killn
      assign kill[k] = |is_jal[k-1:0];
    end

    assign slot_live[k] = in_slot_valid[k] && !kill[k];
    assign produces[k]  = slot_live[k] && u.has_dest;
    assign uses_rs1[k]  = slot_live[k] && u.rs1_valid;
    assign uses_rs2[k]  = slot_live[k] && u.rs2_valid;
  end

  // ======================================================================
  // Intra-bundle dependencies (decision 3, spec section 8)
  //
  // For each source of slot i, the producer is the CLOSEST earlier writer:
  // the largest j < i that is live, has a destination, and whose rd matches.
  // The loop runs upward with no `break` and rewrites the mask on every
  // match, so the last match -- the largest j -- is the one that survives.
  // rd gets the same treatment, for the WAW case the rename needs to chain
  // old_tag through (without it, two writers of the same register in one
  // bundle would both report the pre-bundle tag as old_tag, and the free
  // list would get one tag back twice while another leaked).
  // ======================================================================
  logic [WIDTH-1:0] dep_rs1_c [WIDTH];
  logic [WIDTH-1:0] dep_rs2_c [WIDTH];
  logic [WIDTH-1:0] dep_rd_c  [WIDTH];

  for (genvar i = 0; i < WIDTH; i++) begin : g_dep
    logic [WIDTH-1:0] m1, m2, md;

    // This slot's own fields, hoisted for the same reason as above: i is a
    // genvar, so reading uses_rs1[i] directly inside always_comb costs the
    // sensitivity list. j below is a plain variable and needs no hoisting.
    logic            i_uses_rs1, i_uses_rs2, i_produces;
    logic [REG_W-1:0] i_rs1, i_rs2, i_rd;
    assign i_uses_rs1 = uses_rs1[i];
    assign i_uses_rs2 = uses_rs2[i];
    assign i_produces = produces[i];
    assign i_rs1      = rs1_of[i];
    assign i_rs2      = rs2_of[i];
    assign i_rd       = rd_of[i];

    always_comb begin
      m1 = '0;
      m2 = '0;
      md = '0;
      for (int j = 0; j < WIDTH; j++) begin
        if (j < i && produces[j]) begin
          if (i_uses_rs1 && i_rs1 == rd_of[j]) begin
            m1    = '0;
            m1[j] = 1'b1;
          end
          if (i_uses_rs2 && i_rs2 == rd_of[j]) begin
            m2    = '0;
            m2[j] = 1'b1;
          end
          if (i_produces && i_rd == rd_of[j]) begin
            md    = '0;
            md[j] = 1'b1;
          end
        end
      end
    end

    assign dep_rs1_c[i] = m1;
    assign dep_rs2_c[i] = m2;
    assign dep_rd_c[i]  = md;
  end

  // ======================================================================
  // JAL redirect (decision 7, spec section 10)
  // Exactly one redirect per bundle: the FIRST JAL wins, since every slot
  // after it is already on the wrong path. The loop runs DOWNWARD and lets
  // the last write win, so the lowest index survives -- the same no-`break`
  // idiom as above.
  // ======================================================================
  logic            any_jal;
  logic [XLEN-1:0] redirect_pc_c;

  assign any_jal = |is_jal;

  always_comb begin
    redirect_pc_c = '0;
    for (int k = WIDTH - 1; k >= 0; k--) begin
      if (is_jal[k]) redirect_pc_c = jal_tgt[k];
    end
  end

  // ======================================================================
  // Final per-slot uop: the decode of the slot, with `valid` lowered when the
  // slot sits to the right of a JAL. Unpacked arrays indexed whole-element,
  // with the struct copied into a scalar temporary first -- the two rules
  // AGENTS.md gives for reading a slot under Icarus.
  // ======================================================================
  uop_t uop_c [WIDTH];

  always_comb begin
    uop_t t;
    for (int k = 0; k < WIDTH; k++) begin
      t          = dec[k];
      t.valid    = slot_live[k];
      uop_c[k]   = t;
    end
  end

  // ======================================================================
  // Output register and handshake
  //
  // One bundle deep. in_ready falls while a bundle is parked at the output
  // and nobody is taking it, so a stalled consumer back-pressures Fetch
  // without the bundle being split (decision 15: all or nothing).
  // flush takes precedence over the handshake: a bundle accepted on the same
  // edge as a flush is dropped, not propagated.
  // ======================================================================
  logic             accept;
  logic             out_valid_q;
  uop_t             uop_q      [WIDTH];
  logic [WIDTH-1:0] dep_rs1_q  [WIDTH];
  logic [WIDTH-1:0] dep_rs2_q  [WIDTH];
  logic [WIDTH-1:0] dep_rd_q   [WIDTH];
  logic [WIDTH-1:0] kill_q;
  logic [XLEN-1:0]  redirect_pc_q;
  logic             redirect_valid_q;

  assign in_ready = !out_valid_q || out_ready;
  assign accept   = in_valid && in_ready && !flush;

  always_ff @(posedge clk) begin
    if (reset) begin
      out_valid_q      <= 1'b0;
      redirect_valid_q <= 1'b0;
    end else if (flush) begin
      out_valid_q      <= 1'b0;
      redirect_valid_q <= 1'b0;
    end else begin
      // A redirect is a single-cycle pulse, one per accepted bundle: Fetch
      // must be steered once, however long the bundle then waits downstream.
      redirect_valid_q <= accept && any_jal;
      if (accept) begin
        out_valid_q <= 1'b1;
      end else if (out_ready) begin
        out_valid_q <= 1'b0;
      end
    end

    if (reset) begin
      for (int k = 0; k < WIDTH; k++) begin
        uop_q[k]     <= '0;
        dep_rs1_q[k] <= '0;
        dep_rs2_q[k] <= '0;
        dep_rd_q[k]  <= '0;
      end
      kill_q        <= '0;
      redirect_pc_q <= '0;
    end else if (accept) begin
      for (int k = 0; k < WIDTH; k++) begin
        uop_q[k]     <= uop_c[k];
        dep_rs1_q[k] <= dep_rs1_c[k];
        dep_rs2_q[k] <= dep_rs2_c[k];
        dep_rd_q[k]  <= dep_rd_c[k];
      end
      kill_q        <= kill;
      redirect_pc_q <= redirect_pc_c;
    end
  end

  assign out_valid      = out_valid_q;
  assign out_slot_kill  = kill_q;
  assign redirect_valid = redirect_valid_q;
  assign redirect_pc    = redirect_pc_q;

  for (genvar k = 0; k < WIDTH; k++) begin : g_out
    assign out_uop[k]     = uop_q[k];
    assign out_dep_rs1[k] = dep_rs1_q[k];
    assign out_dep_rs2[k] = dep_rs2_q[k];
    assign out_dep_rd[k]  = dep_rd_q[k];
  end

endmodule
