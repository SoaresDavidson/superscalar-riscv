// Integer ALU for RV64I. Latency 1 cycle, accepts a new request every cycle.
// Spec: wiki page Execute.md; interface contract: rtl/execute/README.md.
//
// Structure: combinational operation followed by one output register.
//   - req_ready is high when the output register is empty, is being read in
//     this cycle, or holds a result that the flush is killing.
//   - flush kills only instructions younger than flush_age: the one held in
//     the output register and the one arriving in the same cycle. An older
//     held result survives (it must still be written back).
//   - W instructions (ADDW/SUBW/SLLW/SRLW/SRAW) operate on the low 32 bits and
//     sign-extend the result to XLEN; their shift amount is 5 bits.
module alu
  import execute_pkg::*;
(
  input  logic     clk,
  input  logic     reset,      // synchronous, active high
  input  logic     flush,      // a branch with age flush_age mispredicted
  input  age_t     flush_age,

  input  logic     req_valid,
  output logic     req_ready,
  input  fu_req_t  req,

  output logic     resp_valid,
  input  logic     resp_ready,
  output fu_resp_t resp
);

  localparam int unsigned SHAMT_W = $clog2(XLEN);

  // Operands selected with continuous assignments: Icarus does not support
  // struct member selects inside always_comb.
  exec_op_t            op;
  xlen_t               op_a;
  xlen_t               op_b;
  xlen_t               imm;
  xlen_t               pc;
  logic [SHAMT_W-1:0]  shamt;
  xlen_t               result;

  // 32-bit datapath for the RV64 W instructions
  logic [31:0]         a32;
  logic [31:0]         b32;
  logic [4:0]          shamt32;
  logic [31:0]         res32;
  logic                is_word;
  xlen_t               res32_ext;

  assign op      = req.op;
  assign op_a    = req.src1;
  assign op_b    = req.use_imm ? req.imm : req.src2;
  assign imm     = req.imm;
  assign pc      = req.pc;
  assign shamt   = op_b[SHAMT_W-1:0];
  assign a32     = op_a[31:0];
  assign b32     = op_b[31:0];
  assign shamt32 = op_b[4:0];
  assign res32_ext = {{(XLEN-32){res32[31]}}, res32};

  // W result (32-bit), and whether this op is a W op
  always_comb begin
    res32   = '0;
    is_word = 1'b1;
    case (op)
      ALU_ADDW:  res32 = a32 + b32;
      ALU_SUBW:  res32 = a32 - b32;
      ALU_SLLW:  res32 = a32 << shamt32;
      ALU_SRLW:  res32 = a32 >> shamt32;
      ALU_SRAW:  res32 = 32'($signed(a32) >>> shamt32);
      default:   is_word = 1'b0;
    endcase
  end

  // Full 64-bit result
  always_comb begin
    case (op)
      ALU_ADD:   result = op_a + op_b;
      ALU_SUB:   result = op_a - op_b;
      ALU_AND:   result = op_a & op_b;
      ALU_OR:    result = op_a | op_b;
      ALU_XOR:   result = op_a ^ op_b;
      ALU_SLT:   result = xlen_t'($signed(op_a) < $signed(op_b));
      ALU_SLTU:  result = xlen_t'(op_a < op_b);
      ALU_SLL:   result = op_a << shamt;
      ALU_SRL:   result = op_a >> shamt;
      ALU_SRA:   result = xlen_t'($signed(op_a) >>> shamt);
      ALU_LUI:   result = imm;
      ALU_AUIPC: result = pc + imm;
      default:   result = is_word ? res32_ext : '0;  // W ops, else unreachable
    endcase
  end

  // Request fields the ALU does not use (Branch Unit only)
  logic unused;
  assign unused = &{1'b0, req.pred_taken, req.pred_target};

  // Output register and handshake
  logic     valid_q;
  fu_resp_t resp_q;
  logic     kill_held;
  logic     accept;

  assign kill_held  = flush && valid_q && age_is_younger(resp_q.age, flush_age);
  assign resp_valid = valid_q && !kill_held;
  assign resp       = resp_q;
  assign req_ready  = !resp_valid || resp_ready;
  assign accept     = req_valid && req_ready &&
                      !(flush && age_is_younger(req.age, flush_age));

  always_ff @(posedge clk) begin
    if (reset) begin
      valid_q <= 1'b0;
    end else if (accept) begin
      valid_q          <= 1'b1;
      resp_q.result    <= result;
      resp_q.rd        <= req.rd;
      resp_q.wr_en     <= req.wr_en;
      resp_q.age       <= req.age;
      resp_q.exception <= 1'b0;
      resp_q.cause     <= CAUSE_NONE;
    end else if (req_ready) begin
      valid_q <= 1'b0;
    end
  end

endmodule
