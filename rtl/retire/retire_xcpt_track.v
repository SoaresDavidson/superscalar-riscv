`default_nettype none

module retire_xcpt_track #(
    parameter TAG_W    = 7,
    parameter CAUSE_W  = 5,
    parameter XLEN     = 64,
    parameter XC_PORTS = 2,
    parameter LANES    = 3
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         clr,
    input  wire                         cancel_valid,
    input  wire [TAG_W-1:0]             cancel_tag,
    input  wire                         ab_fire,
    input  wire [LANES-1:0]             ab_exc,
    input  wire [TAG_W-3:0]             ab_base,
    input  wire [LANES*CAUSE_W-1:0]     ab_cause,
    input  wire [XC_PORTS-1:0]          xc_acc,
    input  wire [XC_PORTS*TAG_W-1:0]    xc_tag,
    input  wire [XC_PORTS*CAUSE_W-1:0]  xc_cause,
    input  wire [XC_PORTS*XLEN-1:0]     xc_tval,
    output wire [CAUSE_W-1:0]           xcause,
    output wire [XLEN-1:0]              xtval
);

  function t_older;
    input [TAG_W-1:0] a;
    input [TAG_W-1:0] b;
    begin
      t_older = (a[TAG_W-1] ^ b[TAG_W-1]) ^ (a[TAG_W-2:0] < b[TAG_W-2:0]);
    end
  endfunction

  reg                xv_q;
  reg [TAG_W-1:0]    tag_q;
  reg [CAUSE_W-1:0]  cause_q;
  reg [XLEN-1:0]     tval_q;

  reg                cv;
  reg [TAG_W-1:0]    ct;
  reg [CAUSE_W-1:0]  cc;
  reg [XLEN-1:0]     cx;
  reg [TAG_W-1:0]    pt;
  reg [CAUSE_W-1:0]  pcz;
  integer            p;

  always @* begin
    cv  = 1'b0;
    ct  = {TAG_W{1'b0}};
    cc  = {CAUSE_W{1'b0}};
    cx  = {XLEN{1'b0}};
    pt  = {TAG_W{1'b0}};
    pcz = {CAUSE_W{1'b0}};
    for (p = 0; p < XC_PORTS; p = p + 1) begin
      pt  = xc_tag[p*TAG_W +: TAG_W];
      pcz = xc_cause[p*CAUSE_W +: CAUSE_W];
      if (xc_acc[p]) begin
        if (!cv
            || ((pt == ct) && cc[CAUSE_W-1] && !pcz[CAUSE_W-1])
            || ((pt != ct) && t_older(pt, ct))) begin
          cv = 1'b1;
          ct = pt;
          cc = pcz;
          cx = xc_tval[p*XLEN +: XLEN];
        end
      end
    end
  end

  reg                abv;
  reg [TAG_W-1:0]    abt;
  reg [CAUSE_W-1:0]  abc;
  integer            k;

  always @* begin
    abv = 1'b0;
    abt = {TAG_W{1'b0}};
    abc = {CAUSE_W{1'b0}};
    for (k = LANES - 1; k >= 0; k = k - 1) begin
      if (ab_exc[k]) begin
        abv = 1'b1;
        abt = {ab_base, k[1:0]};
        abc = ab_cause[k*CAUSE_W +: CAUSE_W];
      end
    end
  end

  wire take_xc = cv & (~xv_q | t_older(ct, tag_q));
  wire take_ab = ab_fire & abv & ~cv & ~xv_q;
  wire drop    = cancel_valid & xv_q & t_older(cancel_tag, tag_q);

  always @(posedge clk) begin
    if (!rst_n) begin
      xv_q <= 1'b0;
    end else if (clr) begin
      xv_q <= 1'b0;
    end else if (take_xc | take_ab) begin
      xv_q <= 1'b1;
    end else if (drop) begin
      xv_q <= 1'b0;
    end
  end

  always @(posedge clk) begin
    if (take_xc) begin
      tag_q   <= ct;
      cause_q <= cc;
      tval_q  <= cx;
    end else if (take_ab) begin
      tag_q   <= abt;
      cause_q <= abc;
      tval_q  <= {XLEN{1'b0}};
    end
  end

  assign xcause = cause_q;
  assign xtval  = tval_q;

endmodule
`default_nettype wire
