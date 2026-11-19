`default_nettype none

module retire_rrat #(
    parameter NUM_AREGS = 32,
    parameter AREG_W    = 5,
    parameter PREG_W    = 7,
    parameter LANES     = 3
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire [LANES-1:0]                  we,
    input  wire [LANES*AREG_W-1:0]           w_ldst,
    input  wire [LANES*PREG_W-1:0]           w_pdst,
    output wire [(NUM_AREGS-1)*PREG_W-1:0]   rrat_flat
);

  genvar gi;
  generate
    for (gi = 1; gi < NUM_AREGS; gi = gi + 1) begin : g_reg
      localparam [AREG_W-1:0] IDX = gi[AREG_W-1:0];
      localparam [PREG_W-1:0] RST = gi[PREG_W-1:0];

      reg [PREG_W-1:0] q;
      reg [LANES-1:0]  hit;
      integer          k;
      integer          kw;

      always @* begin
        hit = {LANES{1'b0}};
        for (k = 0; k < LANES; k = k + 1) begin
          hit[k] = we[k] & (w_ldst[k*AREG_W +: AREG_W] == IDX);
        end
      end

      always @(posedge clk) begin
        if (!rst_n) begin
          q <= RST;
        end else begin
          for (kw = 0; kw < LANES; kw = kw + 1) begin
            if (hit[kw]) q <= w_pdst[kw*PREG_W +: PREG_W];
          end
        end
      end

      assign rrat_flat[(gi-1)*PREG_W +: PREG_W] = q;
    end
  endgenerate

endmodule
`default_nettype wire
