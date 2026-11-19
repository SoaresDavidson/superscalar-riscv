// Single shared package of the core (AGENTS.md, "Decode <-> Execute interface").
// It holds BOTH sides of that contract:
//   - uop_t: what Decode produces, in ARCHITECTURAL registers (no tag).
//   - exec_op_t / fu_req_t / fu_resp_t / redirect_t: what the FUs consume and
//     produce, in PHYSICAL tags.
// Spec: wiki pages Decode.md and Execute.md. Changing any type here is a
// contract change between the two stages: agree it with both owners and update
// both wiki pages and the block READMEs in the same commit.
//
// ISA: RV64I, no multiplier, no divider, no C (Decisoes-de-Projeto, dec. 1
// and 11). Instruction 32 bits, data XLEN = 64, 32 registers (5-bit
// specifiers). 52 instructions -- there is no MUL/DIV functional unit and no
// MUL/DIV operation in exec_op_t.
//
// WIDTH is deliberately NOT here: it stays a per-module parameter, never a
// package constant and never a literal. Anything whose width depends on WIDTH
// (the intra-bundle dependency masks) therefore cannot live in a package
// either -- a SystemVerilog package is not parameterizable -- and travels as
// module ports instead.
package execute_pkg;

  // ---------------------------------------------------------------------
  // Global widths
  // ---------------------------------------------------------------------
  parameter int unsigned XLEN  = 64;  // datapath width (dec. 1)
  parameter int unsigned REG_W = 5;   // ARCHITECTURAL register specifier, x0-x31
  parameter int unsigned AGE_W = 8;   // instruction age (program-order id)

  // Physical register file size, and the tag that indexes it. This is the
  // name the FUs and the write-back travel in, NOT the architectural
  // specifier above: after rename, a destination is a physical tag.
  //
  // PENDING (open question 1): PRF_ENTRIES is not decided yet. 64 matches the
  // current default of PRFRename (rtl/rename/). When the group fixes it, this
  // is the single place to change -- TAG_W follows.
  parameter int unsigned PRF_ENTRIES = 64;

  typedef logic [XLEN-1:0]  xlen_t;
  typedef logic [REG_W-1:0] reg_t;   // architectural register number
  typedef logic [AGE_W-1:0] age_t;

  localparam int unsigned TAG_W = $clog2(PRF_ENTRIES);
  typedef logic [TAG_W-1:0] tag_t;   // physical register (rename tag)

  // ---------------------------------------------------------------------
  // Operations. One enum for all FUs; the FU is derived from the op.
  // Decode translates the raw opcode straight into one of these, so the op
  // alone carries what used to need separate class / alu_op / br_op /
  // mem_size / mem_unsigned / word_op fields:
  //   - the FU comes from fu_of(op);
  //   - the access size and signedness are in the AGU_* op;
  //   - the 32-bit W semantics are in the ALU_*W op.
  // ---------------------------------------------------------------------
  typedef enum logic [6:0] {
    // ALU, 64-bit
    ALU_ADD    = 7'd0,
    ALU_SUB    = 7'd1,
    ALU_AND    = 7'd2,
    ALU_OR     = 7'd3,
    ALU_XOR    = 7'd4,
    ALU_SLT    = 7'd5,
    ALU_SLTU   = 7'd6,
    ALU_SLL    = 7'd7,
    ALU_SRL    = 7'd8,
    ALU_SRA    = 7'd9,
    ALU_LUI    = 7'd10,  // result = imm
    ALU_AUIPC  = 7'd11,  // result = pc + imm
    // ALU, RV64 W variants: 32-bit op, result sign-extended to 64
    ALU_ADDW   = 7'd12,
    ALU_SUBW   = 7'd13,
    ALU_SLLW   = 7'd14,
    ALU_SRLW   = 7'd15,
    ALU_SRAW   = 7'd16,
    // JAL link value. JAL itself never reaches a FU -- its target is resolved
    // in Decode and Fetch is redirected there (dec. 7) -- but the instruction
    // still has to write pc + 4 into rd, and the ALU is where that happens.
    // JALR's link value comes from the Branch Unit instead, which is already
    // computing its target.
    ALU_PC4    = 7'd17,  // result = pc + 4

    // Branch unit
    BR_BEQ     = 7'd32,
    BR_BNE     = 7'd33,
    BR_BLT     = 7'd34,
    BR_BGE     = 7'd35,
    BR_BLTU    = 7'd36,
    BR_BGEU    = 7'd37,
    BR_JALR    = 7'd38,

    // AGU: the op carries the access size and signedness, so both the
    // misalignment check and the load extension are derivable from it
    AGU_LB     = 7'd64,
    AGU_LBU    = 7'd65,
    AGU_LH     = 7'd66,
    AGU_LHU    = 7'd67,
    AGU_LW     = 7'd68,
    AGU_LWU    = 7'd69,
    AGU_LD     = 7'd70,
    AGU_SB     = 7'd71,
    AGU_SH     = 7'd72,
    AGU_SW     = 7'd73,
    AGU_SD     = 7'd74,

    // No functional unit. Two kinds of uop land here, told apart by the
    // `illegal` bit of uop_t: an unrecognized encoding (illegal = 1), and a
    // system instruction that Retirement handles rather than a FU
    // (FENCE, ECALL, EBREAK, CSR*; illegal = 0, serializing = 1).
    // PENDING (open question 5): when decision 10 settles what the core does
    // with traps and CSRs, the system instructions get their own encodings
    // here and stop sharing OP_NONE.
    OP_NONE    = 7'd127
  } exec_op_t;

  // ---------------------------------------------------------------------
  // Which functional unit executes an op
  // ---------------------------------------------------------------------
  typedef enum logic [2:0] {
    FU_NONE   = 3'd0,  // not an Execute op (illegal, or a system instruction)
    FU_ALU    = 3'd1,
    FU_BRANCH = 3'd2,
    FU_AGU    = 3'd3
  } fu_kind_t;

  function automatic fu_kind_t fu_of(input exec_op_t op);
    case (op)
      ALU_ADD, ALU_SUB, ALU_AND, ALU_OR, ALU_XOR, ALU_SLT, ALU_SLTU,
      ALU_SLL, ALU_SRL, ALU_SRA, ALU_LUI, ALU_AUIPC,
      ALU_ADDW, ALU_SUBW, ALU_SLLW, ALU_SRLW, ALU_SRAW, ALU_PC4:
        return FU_ALU;
      BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU, BR_JALR:
        return FU_BRANCH;
      AGU_LB, AGU_LBU, AGU_LH, AGU_LHU, AGU_LW, AGU_LWU, AGU_LD,
      AGU_SB, AGU_SH, AGU_SW, AGU_SD:
        return FU_AGU;
      default:
        return FU_NONE;
    endcase
  endfunction

  // True for the loads: they occupy the AGU but write a register later, with
  // the value returned by Memory. Stores do not write anything.
  function automatic logic is_load(input exec_op_t op);
    case (op)
      AGU_LB, AGU_LBU, AGU_LH, AGU_LHU, AGU_LW, AGU_LWU, AGU_LD:
        return 1'b1;
      default:
        return 1'b0;
    endcase
  endfunction

  // ---------------------------------------------------------------------
  // Micro-operation: Decode -> Rename / Dispatch, one per bundle slot.
  //
  // It names only ARCHITECTURAL registers: no tag, no PRF index, no ROB
  // index, no reservation-station pointer. The tag does not exist yet at this
  // point -- Rename produces it -- which is what keeps Decode independent of
  // the rename variant. Dispatch builds fu_req_t below by copying these
  // fields and substituting rd/has_dest with the dst_tag that Rename returned.
  // ---------------------------------------------------------------------
  typedef struct packed {
    logic      valid;         // slot carries an instruction on the right path
    xlen_t     pc;            // AUIPC, JAL/JALR, branches, exceptions

    exec_op_t  op;            // operation; the FU follows from fu_of(op)
    logic      use_imm;       // 1: second operand is imm, 0: rs2
    xlen_t     imm;           // assembled and sign-extended; shamt for shifts

    reg_t      rs1;
    logic      rs1_valid;     // 0 also means "the operand is a known zero"
    reg_t      rs2;
    logic      rs2_valid;
    reg_t      rd;
    logic      has_dest;      // lowered when rd == x0 (dec. 5)

    logic      is_jal;        // Decode already redirected Fetch for this slot
    logic      serializing;   // runs alone, drained pipeline (dec. 10)
    logic      illegal;       // unrecognized encoding; Retirement raises it
  } uop_t;

  // ---------------------------------------------------------------------
  // Instruction age: a program-order id that wraps around.
  // `a` is younger than `b` when a was issued after b. Correct only while
  // the span of in-flight instructions is smaller than 2**(AGE_W-1).
  // Used by the selective flush: a mispredicted branch kills only the
  // instructions younger than itself; older in-flight ones must finish.
  //
  // CONSEQUENCE, if age is the ROB index (open question 2): the ROB must hold
  // at most 2**(AGE_W-1) entries -- 128 with AGE_W = 8. A fuller ROB would
  // make this comparison wrap the wrong way and the selective flush would
  // kill the wrong instructions.
  // ---------------------------------------------------------------------
  function automatic logic age_is_younger(input age_t a, input age_t b);
    logic signed [AGE_W-1:0] diff;
    diff = a - b;
    return (diff > 0);
  endfunction

  // ---------------------------------------------------------------------
  // Exception causes (RISC-V mcause values for the cases the core can raise)
  // ---------------------------------------------------------------------
  typedef enum logic [3:0] {
    CAUSE_NONE             = 4'd0,
    CAUSE_ILLEGAL_INST     = 4'd2,
    CAUSE_LOAD_MISALIGNED  = 4'd4,
    CAUSE_STORE_MISALIGNED = 4'd6
  } exc_cause_t;

  // ---------------------------------------------------------------------
  // Request: Issue -> FU (payload; req_valid/req_ready travel as ports)
  // ---------------------------------------------------------------------
  typedef struct packed {
    exec_op_t op;
    xlen_t    src1;
    xlen_t    src2;
    xlen_t    imm;          // already sign-extended by Decode
    logic     use_imm;      // 1: second ALU operand is imm, 0: src2
    xlen_t    pc;           // branches, jalr link, auipc
    tag_t     dst_tag;      // PHYSICAL destination: Rename's dst_tag, not rd
    logic     wr_en;        // 0 for rd = x0, stores and branches
    age_t     age;
    logic     pred_taken;   // prediction made by Fetch (Branch Unit only)
    xlen_t    pred_target;
  } fu_req_t;

  // ---------------------------------------------------------------------
  // Response: FU -> write-back (payload; resp_valid/resp_ready are ports)
  // dst_tag is what the CDB broadcasts: it goes straight to the wb_tag port
  // of the rename and to the reservation stations, so it must be a tag.
  // ---------------------------------------------------------------------
  typedef struct packed {
    xlen_t      result;     // value, or effective address for the AGU
    tag_t       dst_tag;
    logic       wr_en;
    age_t       age;
    logic       exception;
    exc_cause_t cause;
  } fu_resp_t;

  // ---------------------------------------------------------------------
  // Branch Unit -> Pipeline-Control. valid == "the prediction was wrong".
  // ---------------------------------------------------------------------
  typedef struct packed {
    logic  valid;           // misprediction: redirect fetch and flush
    xlen_t pc;              // correct next PC
    age_t  age;             // age of the branch; flush instructions younger
  } redirect_t;

endpackage
