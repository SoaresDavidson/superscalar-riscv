// Reservation station INT: holds the instructions for the ALU and the Branch
// Unit until both sources are ready, then issues one per FU per cycle.
// Spec: docs/rs/RS.md.
//
// Tags only: an entry never holds operand values. At issue, the source tags
// of the selected entry go to the PRF read ports and src1/src2 of fu_req_t
// come from the read data, in the same cycle.
//
// STATUS: skeleton. Ports are final for this version; every output is tied to
// zero, so rs_int_tb fails until the logic is written.
/* verilator lint_off UNUSEDSIGNAL */
module rs_int
  import execute_pkg::*;
  import dispatch_pkg::*;
#(
    parameter  int W       = 3,   // bundle width: writes per cycle
    parameter  int ENTRIES = 8,   // RS_INT_ENTRIES
    parameter  int WB_N    = 3,   // write-back buses: ALU, Branch Unit, load
    localparam int CNT_W   = $clog2(ENTRIES + 1)
) (
    input  logic clk,
    input  logic reset,
    input  logic flush,                              // clears every entry

    // Dispatch
    input  logic [W-1:0]               wr,           // int_wr
    input  rs_int_entry_t [W-1:0]      wr_entry,     // int_entry
    output logic [CNT_W-1:0]           free,         // int_free

    // Write-back buses (wakeup)
    input  logic [WB_N-1:0]            wb_valid,
    input  logic [WB_N-1:0][TAG_W-1:0] wb_tag,

    // ALU: request and its two PRF read ports (PRFRename read ports 0 and 1)
    output logic                       alu_req_valid,
    input  logic                       alu_req_ready,
    output fu_req_t                    alu_req,
    output logic [1:0][TAG_W-1:0]      alu_read_tag,
    input  logic [1:0]                 alu_read_valid,
    input  logic [1:0][XLEN-1:0]       alu_read_data,

    // Branch Unit: same shape (PRFRename read ports 2 and 3)
    output logic                       br_req_valid,
    input  logic                       br_req_ready,
    output fu_req_t                    br_req,
    output logic [1:0][TAG_W-1:0]      br_read_tag,
    input  logic [1:0]                 br_read_valid,
    input  logic [1:0][XLEN-1:0]       br_read_data
);

  // TODO: logic. See docs/rs/RS.md, section "Funcionamento".
  assign free          = '0;
  assign alu_req_valid = 1'b0;
  assign alu_req       = '0;
  assign alu_read_tag  = '0;
  assign br_req_valid  = 1'b0;
  assign br_req        = '0;
  assign br_read_tag   = '0;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
