// Shared types for the Execute stage (functional units).
// Spec: wiki page Execute.md. Interface changes must update that page.
//
// Open items that affect this file (see "Questoes em aberto" in Execute.md):
//   - XLEN / REG_W: Decisoes-de-Projeto says RV32IM; Decode.md says XLEN = 64
//     and 7-bit register specifiers. Defaults below follow Decisoes-de-Projeto
//     (the first source of truth). Change them in ONE place when reconciled.
//   - AGU store data and the Memory interface are not specified yet.
package execute_pkg;

  // ---------------------------------------------------------------------
  // Global widths
  // ---------------------------------------------------------------------
  parameter int unsigned XLEN  = 32;  // datapath width
  parameter int unsigned REG_W = 5;   // architectural register specifier width
  parameter int unsigned AGE_W = 8;   // instruction age (program-order id)

  typedef logic [XLEN-1:0]  xlen_t;
  typedef logic [REG_W-1:0] reg_t;
  typedef logic [AGE_W-1:0] age_t;

  // ---------------------------------------------------------------------
  // Operations. One enum for all FUs; the FU is derived from the op.
  // The Decode stage must translate the raw opcode into one of these.
  // ---------------------------------------------------------------------
  typedef enum logic [5:0] {
    // ALU
    ALU_ADD    = 6'd0,
    ALU_SUB    = 6'd1,
    ALU_AND    = 6'd2,
    ALU_OR     = 6'd3,
    ALU_XOR    = 6'd4,
    ALU_SLT    = 6'd5,
    ALU_SLTU   = 6'd6,
    ALU_SLL    = 6'd7,
    ALU_SRL    = 6'd8,
    ALU_SRA    = 6'd9,
    ALU_LUI    = 6'd10,  // result = imm
    ALU_AUIPC  = 6'd11,  // result = pc + imm

    // Branch unit
    BR_BEQ     = 6'd16,
    BR_BNE     = 6'd17,
    BR_BLT     = 6'd18,
    BR_BGE     = 6'd19,
    BR_BLTU    = 6'd20,
    BR_BGEU    = 6'd21,
    BR_JALR    = 6'd22,

    // AGU: the op carries the access size, so misalignment is derivable
    AGU_LB     = 6'd32,
    AGU_LBU    = 6'd33,
    AGU_LH     = 6'd34,
    AGU_LHU    = 6'd35,
    AGU_LW     = 6'd36,
    AGU_SB     = 6'd37,
    AGU_SH     = 6'd38,
    AGU_SW     = 6'd39,

    // Multiplier
    MUL_MUL    = 6'd48,
    MUL_MULH   = 6'd49,
    MUL_MULHSU = 6'd50,
    MUL_MULHU  = 6'd51
  } exec_op_t;

  // ---------------------------------------------------------------------
  // Which functional unit executes an op
  // ---------------------------------------------------------------------
  typedef enum logic [2:0] {
    FU_NONE   = 3'd0,  // not an Execute op (illegal / unknown encoding)
    FU_ALU    = 3'd1,
    FU_BRANCH = 3'd2,
    FU_AGU    = 3'd3,
    FU_MUL    = 3'd4
  } fu_kind_t;

  function automatic fu_kind_t fu_of(input exec_op_t op);
    case (op)
      ALU_ADD, ALU_SUB, ALU_AND, ALU_OR, ALU_XOR, ALU_SLT, ALU_SLTU,
      ALU_SLL, ALU_SRL, ALU_SRA, ALU_LUI, ALU_AUIPC:
        return FU_ALU;
      BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU, BR_JALR:
        return FU_BRANCH;
      AGU_LB, AGU_LBU, AGU_LH, AGU_LHU, AGU_LW, AGU_SB, AGU_SH, AGU_SW:
        return FU_AGU;
      MUL_MUL, MUL_MULH, MUL_MULHSU, MUL_MULHU:
        return FU_MUL;
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
