`default_nettype none

module retire_csr #(
    parameter XLEN = 64,
    parameter PC_W = 64,
    parameter [XLEN-1:0] MTVEC_RESET = 0
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 trap_we,
    input  wire [PC_W-1:0]      trap_pc,
    input  wire [3:0]           trap_cause,
    input  wire [XLEN-1:0]      trap_tval,
    input  wire                 mret_we,
    input  wire [1:0]           instret,
    input  wire                 mtvec_wr_valid,
    input  wire [XLEN-1:0]      mtvec_wr_data,
    input  wire [11:0]          rd_addr,
    output wire [PC_W-1:0]      mtvec_pc,
    output wire [PC_W-1:0]      mepc_pc,
    output reg  [XLEN-1:0]      rd_data,
    output reg                  rd_hit
);

  reg                 mie_q;
  reg                 mpie_q;
  reg [XLEN-1:2]      mtvec_q;
  reg [PC_W-1:2]      mepc_q;
  reg [3:0]           mcause_q;
  reg [XLEN-1:0]      mtval_q;
  reg [XLEN-1:0]      mcycle_q;
  reg [XLEN-1:0]      minstret_q;

  assign mtvec_pc = {mtvec_q[PC_W-1:2], 2'b00};
  assign mepc_pc  = {mepc_q, 2'b00};

  wire [XLEN-1:0] mstatus_v = {{(XLEN-13){1'b0}}, 2'b11, 3'b000, mpie_q, 3'b000, mie_q, 3'b000};

  reg [XLEN-1:0] rv;
  reg            rh;

  always @* begin
    rv = {XLEN{1'b0}};
    rh = 1'b1;
    case (rd_addr)
      12'h300: rv = mstatus_v;
      12'h305: rv = {mtvec_q, 2'b00};
      12'h341: rv = {mepc_q, 2'b00};
      12'h342: rv = {{(XLEN-4){1'b0}}, mcause_q};
      12'h343: rv = mtval_q;
      12'hB00: rv = mcycle_q;
      12'hB02: rv = minstret_q;
      default: rh = 1'b0;
    endcase
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      mie_q      <= 1'b0;
      mpie_q     <= 1'b0;
      mtvec_q    <= MTVEC_RESET[XLEN-1:2];
      mepc_q     <= {(PC_W-2){1'b0}};
      mcause_q   <= 4'd0;
      mtval_q    <= {XLEN{1'b0}};
      mcycle_q   <= {XLEN{1'b0}};
      minstret_q <= {XLEN{1'b0}};
      rd_data    <= {XLEN{1'b0}};
      rd_hit     <= 1'b0;
    end else begin
      rd_data    <= rv;
      rd_hit     <= rh;
      mcycle_q   <= mcycle_q + {{(XLEN-1){1'b0}}, 1'b1};
      minstret_q <= minstret_q + {{(XLEN-2){1'b0}}, instret};
      if (mtvec_wr_valid) mtvec_q <= mtvec_wr_data[XLEN-1:2];
      if (trap_we) begin
        mepc_q   <= trap_pc[PC_W-1:2];
        mcause_q <= trap_cause;
        mtval_q  <= trap_tval;
        mpie_q   <= mie_q;
        mie_q    <= 1'b0;
      end else if (mret_we) begin
        mie_q    <= mpie_q;
        mpie_q   <= 1'b1;
      end
    end
  end

  wire unused_ok = &{1'b0, MTVEC_RESET[1:0], mtvec_wr_data[1:0], trap_pc[1:0]};

endmodule
`default_nettype wire
