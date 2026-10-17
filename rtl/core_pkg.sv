// Shared types of the core. Transcribed from superscalar-riscv.wiki/Decode.md
// section 5 (uop_t and its enums). The micro-operation names only architectural
// registers: it carries no tag, no PRF index, no ROB index and no reservation
// station pointer, so any of the three rename variants in rtl/rename/ consumes
// it unchanged (Decode.md section 5, "Independencia da variante de rename").
package core_pkg;

  // Register and address width. Fixed at 64 by decision 1, so it lives here as
  // a constant; modules take it as `parameter int XLEN = core_pkg::XLEN` so the
  // value has a single definition. WIDTH is NOT here on purpose: it stays a
  // per-module parameter, never a package constant and never a literal.
  parameter int XLEN = 64;

  // Architectural register specifier: x0-x31.
  parameter int REG_BITS = 5;

  parameter WIDTH = 3;
  // --- classification enums (Decode.md section 5) ---------------------------

  typedef enum logic [2:0] {
    UC_ALU, UC_MUL, UC_LOAD, UC_STORE, UC_BRANCH, UC_JUMP, UC_SYSTEM, UC_ILLEGAL
  } uop_class_e;

  typedef enum logic [3:0] {
    ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
    ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR,  ALU_AND
  } alu_op_e;

  typedef enum logic [1:0] { MUL_LO, MUL_HI, MUL_HISU, MUL_HIU } mul_op_e;
  typedef enum logic [2:0] { BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU } br_op_e;
  typedef enum logic [1:0] { MEM_B, MEM_H, MEM_W, MEM_D } mem_size_e;
  typedef enum logic [1:0] { OPA_RS1, OPA_PC, OPA_ZERO } op_a_sel_e;
  typedef enum logic [0:0] { OPB_RS2, OPB_IMM } op_b_sel_e;

  // --- micro-operation -------------------------------------------------------
  // One uop_t per slot of a bundle. Field order follows the table in
  // Decode.md section 5.

  typedef struct packed {
    logic                 valid;         // slot carries an instruction
    logic [XLEN-1:0]      pc;            // AUIPC, JAL, branches, exceptions

    uop_class_e           uop_class;     // functional unit class
    alu_op_e              alu_op;
    mul_op_e              mul_op;
    br_op_e               br_op;

    mem_size_e            mem_size;      // B / H / W / D
    logic                 mem_unsigned;  // LBU, LHU, LWU: zero-extend
    logic                 word_op;       // W variant: 32-bit op, sign-extended

    op_a_sel_e            op_a_sel;      // RS1 / PC / ZERO
    op_b_sel_e            op_b_sel;      // RS2 / IMM
    logic [XLEN-1:0]      imm;           // already assembled and extended

    logic [REG_BITS-1:0]  rs1;
    logic                 rs1_valid;
    logic [REG_BITS-1:0]  rs2;
    logic                 rs2_valid;
    logic [REG_BITS-1:0]  rd;
    logic                 has_dest;      // lowered when rd == x0 (section 9.4)

    logic                 serializing;   // runs alone, drained pipeline (dec. 10)
    logic                 illegal;       // unrecognized encoding (section 9.5)
  } uop_t;

typedef struct packed {
  // para cada slot e cada fonte: existe produtor no mesmo bundle?
  logic [WIDTH-1:0]                    rs1_in_bundle;
  logic [WIDTH-1:0]                    rs2_in_bundle;
  // se existe, qual slot é o escritor mais próximo (índice)
  logic [WIDTH-1:0][$clog2(WIDTH)-1:0] rs1_producer;
  logic [WIDTH-1:0][$clog2(WIDTH)-1:0] rs2_producer;
} bundle_dep_t;

endpackage
