// Address Generation Unit. Computes the effective address of loads and stores
// (address = src1 + imm) and flags a misalignment exception from the access
// size. The memory access itself belongs to the Memory stage; the AGU only
// produces the address. Latency 1 cycle, one request per cycle.
// Spec: wiki Execute.md; contract: rtl/execute/README.md.
//
// Same output-register + valid/ready + selective-flush structure as the ALU.
// result carries the effective address. For a load, wr_en/dst_tag are passed
// through (the loaded value is written later, by Memory). For a store, wr_en
// arrives as 0.
// resp_is_load tells a load from a store or an exception-free access apart:
// wr_en cannot (a load to x0 has wr_en = 0, like a store). Completion uses it
// to answer the ROB on the AGU port only for stores and exceptions.
//
// Side ports for the Memory (wiki decision 17; Memory.md, "Alocação no
// dispatch: interface"), registered with resp like resp_is_load, so
// back-pressure holds them and the flush drops them together with resp:
//   resp_store_data  src2, the store data (step 1 of decision 17)
//   resp_op          the op: access size, signedness and direction
//   resp_lsq_idx     store buffer or load buffer entry reserved at dispatch
//   resp_color       for a load, the last store buffer entry older than it
// fu_req_t and fu_resp_t do not change: the index and the color come in on
// req_lsq_idx/req_color, beside req.
module agu
  import execute_pkg::*;
(
  input  logic     clk,
  input  logic     reset,
  input  logic     flush,
  input  age_t     flush_age,

  input  logic     req_valid,
  output logic     req_ready,
  input  fu_req_t  req,
  input  lsq_idx_t req_lsq_idx,      // side fields of req, from the RS MEM
  input  sb_ptr_t  req_color,

  output logic     resp_valid,
  input  logic     resp_ready,
  output fu_resp_t resp,
  output logic     resp_is_load,     // resp is a load (valid with resp_valid)
  output xlen_t    resp_store_data,  // side fields of resp, for the Memory
  output exec_op_t resp_op,
  output lsq_idx_t resp_lsq_idx,
  output sb_ptr_t  resp_color
);

  // operand selection (continuous: no struct member select in always_comb)
  exec_op_t op;
  xlen_t    base;
  xlen_t    imm;
  xlen_t    addr;
  xlen_t    data;

  assign op   = req.op;
  assign base = req.src1;
  assign imm  = req.imm;
  assign data = req.src2;
  assign addr = base + imm;

  // access size and store flag, per op
  logic is_store;
  logic chk_half, chk_word, chk_double;

  always_comb begin
    is_store   = 1'b0;
    chk_half   = 1'b0;
    chk_word   = 1'b0;
    chk_double = 1'b0;
    case (op)
      AGU_LB, AGU_LBU:          ;                 // byte: always aligned
      AGU_LH, AGU_LHU:          chk_half   = 1'b1;
      AGU_LW, AGU_LWU:          chk_word   = 1'b1;
      AGU_LD:                   chk_double = 1'b1;
      AGU_SB:                   is_store = 1'b1;
      AGU_SH:                   begin is_store = 1'b1; chk_half   = 1'b1; end
      AGU_SW:                   begin is_store = 1'b1; chk_word   = 1'b1; end
      AGU_SD:                   begin is_store = 1'b1; chk_double = 1'b1; end
      default:                  ;                 // not an AGU op
    endcase
  end

  // misalignment: low address bits must be zero for the access size
  logic misaligned;
  assign misaligned = (chk_half   &  addr[0]) |
                      (chk_word   & |addr[1:0]) |
                      (chk_double & |addr[2:0]);

  exc_cause_t cause;
  always_comb begin
    if (!misaligned)    cause = CAUSE_NONE;
    else if (is_store)  cause = CAUSE_STORE_MISALIGNED;
    else                cause = CAUSE_LOAD_MISALIGNED;
  end

  // request fields the AGU does not use (Branch Unit only)
  logic unused;
  assign unused = &{1'b0, req.pred_taken, req.pred_target, req.pc,
                    req.use_imm};

  // output register + handshake + selective flush (same pattern as the ALU)
  logic     valid_q;
  fu_resp_t resp_q;
  logic     is_load_q;
  xlen_t    data_q;
  exec_op_t op_q;
  lsq_idx_t lsq_idx_q;
  sb_ptr_t  color_q;
  logic     kill_held;
  logic     accept;

  assign kill_held  = flush && valid_q && age_is_younger(resp_q.age, flush_age);
  assign resp_valid = valid_q && !kill_held;
  assign resp       = resp_q;
  assign resp_is_load    = is_load_q;
  assign resp_store_data = data_q;
  assign resp_op         = op_q;
  assign resp_lsq_idx    = lsq_idx_q;
  assign resp_color      = color_q;
  assign req_ready  = !resp_valid || resp_ready;
  assign accept     = req_valid && req_ready &&
                      !(flush && age_is_younger(req.age, flush_age));

  always_ff @(posedge clk) begin
    if (reset) begin
      valid_q <= 1'b0;
    end else if (accept) begin
      valid_q          <= 1'b1;
      resp_q.result    <= addr;
      resp_q.dst_tag   <= req.dst_tag;
      resp_q.wr_en     <= req.wr_en;
      resp_q.age       <= req.age;
      resp_q.exception <= misaligned;
      resp_q.cause     <= cause;
      is_load_q        <= is_load(op);
      data_q           <= data;
      op_q             <= op;
      lsq_idx_q        <= req_lsq_idx;
      color_q          <= req_color;
    end else if (req_ready) begin
      valid_q <= 1'b0;
    end
  end

endmodule
