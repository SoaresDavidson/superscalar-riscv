// Decode stage: WIDTH instructions per cycle, plus intra-bundle dependency
// resolution (decision 3). Specified in docsDecode/Decode.md; this file is
// still a STUB -- the ports and their widths are final, the behavior is not
// written yet, so tb/unit/decode_tb.sv fails on purpose.
//
// Interface notes, section 4 and section 8 of the spec:
//  - bundle_dep_t cannot live in core_pkg, because a package is not
//    parameterizable and the producer index is $clog2(WIDTH) wide. The four
//    out_dep_* ports are that struct, flattened (open item 5 of section 12).
//  - PROD_BITS is derived; never override it. The max(...,1) keeps WIDTH = 1
//    legal, where $clog2(1) = 0 would give a zero-width field.

/* verilator lint_off UNUSEDSIGNAL */  // stub: inputs are not consumed yet
module decode #(
  parameter int WIDTH     = 3,
  parameter int XLEN      = core_pkg::XLEN,
  parameter int PROD_BITS = ($clog2(WIDTH) > 0) ? $clog2(WIDTH) : 1
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
  output core_pkg::uop_t [WIDTH-1:0]        out_uop,

  // bundle_dep_t, flattened
  output logic [WIDTH-1:0]                  out_dep_rs1_in_bundle,
  output logic [WIDTH-1:0]                  out_dep_rs2_in_bundle,
  output logic [WIDTH-1:0][PROD_BITS-1:0]   out_dep_rs1_producer,
  output logic [WIDTH-1:0][PROD_BITS-1:0]   out_dep_rs2_producer,

  // --- JAL redirect (decision 7, spec section 10) --------------------------
  output logic                              redirect_valid,
  output logic [XLEN-1:0]                   redirect_pc,
  output logic [WIDTH-1:0]                  out_slot_kill
);

  // TODO: field extraction (section 6), immediates (section 7), intra-bundle
  // dependencies (section 8), classification (section 9), JAL redirect and
  // intra-bundle kill (section 10).
  assign in_ready              = 1'b0;
  assign out_valid             = 1'b0;
  assign out_uop               = '0;
  assign out_dep_rs1_in_bundle = '0;
  assign out_dep_rs2_in_bundle = '0;
  assign out_dep_rs1_producer  = '0;
  assign out_dep_rs2_producer  = '0;
  assign redirect_valid        = 1'b0;
  assign redirect_pc           = '0;
  assign out_slot_kill         = '0;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
