// Reservation station MEM: holds load and store instructions until both
// sources are ready, then issues at most one per cycle to the AGU.
// Spec: docs/rs/RS.md.
//
// Same organization as rs_int (tags only, operands read at issue), with a
// single selector. Loads use src1 (base); stores use src1 (base) and src2
// (data), and issue only with both ready.
//
// STATUS: skeleton. Ports are final for this version; every output is tied to
// zero, so rs_mem_tb fails until the logic is written.
/* verilator lint_off UNUSEDSIGNAL */
module rs_mem
  import execute_pkg::*;
  import dispatch_pkg::*;
#(
    parameter  int W       = 3,   // writes per cycle (bundle width)
    parameter  int ENTRIES = 4,   // RS_MEM_ENTRIES
    parameter  int WB_N    = 3,   // write-back buses: ALU, Branch Unit, load
    localparam int CNT_W   = $clog2(ENTRIES + 1)
) (
    input  logic clk,
    input  logic reset,
    input  logic flush,                              // empties the RS

    // Dispatch
    input  logic [W-1:0]               wr,           // mem_wr
    input  rs_mem_entry_t [W-1:0]      wr_entry,     // mem_entry
    output logic [CNT_W-1:0]           free,         // mem_free

    // Write-back buses (wakeup)
    input  logic [WB_N-1:0]            wb_valid,
    input  logic [WB_N-1:0][TAG_W-1:0] wb_tag,

    // AGU: request and its two PRF read ports (PRFRename read ports 4 and 5)
    output logic                       agu_req_valid,
    input  logic                       agu_req_ready,
    output fu_req_t                    agu_req,
    output logic [1:0][TAG_W-1:0]      agu_read_tag,
    input  logic [1:0]                 agu_read_valid,  // always 1 at issue, see RS.md
    input  logic [1:0][XLEN-1:0]       agu_read_data
);

  // TODO: logic, adapted from rs_int.sv.
  assign free          = '0;
  assign agu_req_valid = 1'b0;
  assign agu_req       = '0;
  assign agu_read_tag  = '0;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
