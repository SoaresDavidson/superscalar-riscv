// Shared types for the Execute stage (functional units).
// Spec: wiki page Execute.md. Interface changes must update that page.
//
// ISA: RV64I, no multiplier, no divider, no C (Decisoes-de-Projeto, dec. 1 and 11).
// Instruction 32 bits, data XLEN = 64, 32 registers (5-bit specifiers).
//
// This package is the single source of the Decode<->Execute operation types
// (AGENTS.md): Decode fills exec_op_t and the request below; the FUs consume
// them. Do not create a second package for the same information.
//
// Open items (see Execute.md): load/store sizes beyond the ones listed; the
// AGU store-data path to Memory; TAG/age widths once rename and Issue fix them.
package execute_pkg;

  // ---------------------------------------------------------------------
  // Global widths
  // ---------------------------------------------------------------------
  parameter int unsigned XLEN  = 64;  // datapath width
  parameter int unsigned REG_W = 5;   // register specifier width (32 regs, RV64I)
  parameter int unsigned AGE_W = 8;   // instruction age (program-order id)

  typedef logic [XLEN-1:0]  xlen_t;
  typedef logic [REG_W-1:0] reg_t;
  typedef logic [AGE_W-1:0] age_t;

  // ---------------------------------------------------------------------
  // Operations. One enum for all FUs; the FU is derived from the op.
  // The Decode stage must translate the raw opcode into one of these.
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

    // Branch unit
    BR_BEQ     = 7'd32,
    BR_BNE     = 7'd33,
    BR_BLT     = 7'd34,
    BR_BGE     = 7'd35,
    BR_BLTU    = 7'd36,
    BR_BGEU    = 7'd37,
    BR_JALR    = 7'd38,

    // AGU: the op carries the access size, so misalignment is derivable
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
    AGU_SD     = 7'd74
  } exec_op_t;

  // ---------------------------------------------------------------------
  // Which functional unit executes an op
  // ---------------------------------------------------------------------
  typedef enum logic [2:0] {
    FU_NONE   = 3'd0,  // not an Execute op (illegal / unknown encoding)
    FU_ALU    = 3'd1,
    FU_BRANCH = 3'd2,
    FU_AGU    = 3'd3
  } fu_kind_t;

  function automatic fu_kind_t fu_of(input exec_op_t op);
    case (op)
      ALU_ADD, ALU_SUB, ALU_AND, ALU_OR, ALU_XOR, ALU_SLT, ALU_SLTU,
      ALU_SLL, ALU_SRL, ALU_SRA, ALU_LUI, ALU_AUIPC,
      ALU_ADDW, ALU_SUBW, ALU_SLLW, ALU_SRLW, ALU_SRAW:
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

  // ---------------------------------------------------------------------
  // Instruction age: a program-order id that wraps around.
  // `a` is younger than `b` when a was issued after b. Correct only while
  // the span of in-flight instructions is smaller than 2**(AGE_W-1).
  // Used by the selective flush: a mispredicted branch kills only the
  // instructions younger than itself; older in-flight ones must finish.
  // ---------------------------------------------------------------------
  function automatic logic age_is_younger(input age_t a, input age_t b);
    logic signed [AGE_W-1:0] diff;
    diff = a - b;
    return (diff > 0);
  endfunction

  // ---------------------------------------------------------------------
  // Exception causes (RISC-V mcause values for the cases AGU can raise)
  // ---------------------------------------------------------------------
  typedef enum logic [3:0] {
    CAUSE_NONE             = 4'd0,
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
    reg_t     rd;
    logic     wr_en;        // 0 for rd = x0, stores and branches
    age_t     age;
    logic     pred_taken;   // prediction made by Fetch (Branch Unit only)
    xlen_t    pred_target;
  } fu_req_t;

  // ---------------------------------------------------------------------
  // Response: FU -> write-back (payload; resp_valid/resp_ready are ports)
  // ---------------------------------------------------------------------
  typedef struct packed {
    xlen_t      result;     // value, or effective address for the AGU
    reg_t       rd;
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
