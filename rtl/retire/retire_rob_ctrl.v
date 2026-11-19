`default_nettype none

module retire_rob_ctrl #(
    parameter ROB_ROWS  = 16,
    parameter ROB_ROW_W = 4,
    parameter TAG_W     = 7,
    parameter LANES     = 3,
    parameter PC_W      = 64,
    parameter WB_PORTS  = 4,
    parameter XC_PORTS  = 2
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         clr,
    input  wire                         fl_block,
    input  wire                         kill_valid,
    input  wire [ROB_ROW_W:0]           kill_ptr,

    input  wire                         alloc_valid,
    input  wire                         br_kill_valid,
    input  wire [TAG_W-1:0]             br_kill_tag,
    input  wire                         commit_lsu_ready,
    input  wire [LANES-1:0]             kill_live,
    input  wire [PC_W-1:0]              alloc_pc,

    input  wire                         head_adv,

    input  wire [WB_PORTS-1:0]          wb_valid,
    input  wire [WB_PORTS*TAG_W-1:0]    wb_tag,
    input  wire [XC_PORTS-1:0]          xc_valid,
    input  wire [XC_PORTS*TAG_W-1:0]    xc_tag,

    output wire                         fire,
    output reg  [ROB_ROW_W:0]           head_q,
    output reg  [ROB_ROW_W:0]           tail_q,
    output reg                          ready_q,
    output reg                          full_q,
    output reg                          empty_q,
    output wire [LANES*ROB_ROWS-1:0]    wb_hit,
    output wire [LANES*ROB_ROWS-1:0]    xc_hit,
    output wire [LANES*XC_PORTS*ROB_ROWS-1:0] xc_hit_pp,
    output wire [PC_W-1:0]              h_rowpc,

    output wire [LANES*ROB_ROWS-1:0]    kill_hit,
    output wire                         kill_acc,
    output wire [ROB_ROW_W:0]           kill_ptr_c,
    output wire [LANES*ROB_ROWS-1:0]    kill_m,
    output reg                          squash_q,
    output reg  [TAG_W-1:0]             squash_tag_q,
    output reg                          lsu_q
);

  assign fire = alloc_valid & ready_q & ~br_kill_valid & ~fl_block;

  wire [ROB_ROW_W:0] fire_ext = {{ROB_ROW_W{1'b0}}, fire};
  wire [ROB_ROW_W:0] adv_ext  = {{ROB_ROW_W{1'b0}}, head_adv};
  wire [ROB_ROW_W:0] n_tail   = kill_valid ? kill_ptr : (tail_q + fire_ext);
  wire [ROB_ROW_W:0] n_head   = clr ? n_tail : (head_q + adv_ext);
  wire               n_empty  = (n_head == n_tail);
  wire               n_full   = (n_head[ROB_ROW_W-1:0] == n_tail[ROB_ROW_W-1:0])
                              & (n_head[ROB_ROW_W] != n_tail[ROB_ROW_W]);

  always @(posedge clk) begin
    if (!rst_n) begin
      head_q  <= {(ROB_ROW_W + 1){1'b0}};
      tail_q  <= {(ROB_ROW_W + 1){1'b0}};
      empty_q <= 1'b1;
      full_q  <= 1'b0;
      ready_q <= 1'b0;
    end else begin
      head_q  <= n_head;
      tail_q  <= n_tail;
      empty_q <= n_empty;
      full_q  <= n_full;
      ready_q <= ~n_full;
    end
  end

  wire [ROB_ROW_W-1:0] t_row = tail_q[ROB_ROW_W-1:0];
  wire [ROB_ROW_W-1:0] h_row = head_q[ROB_ROW_W-1:0];
  reg  [ROB_ROWS-1:0]  rowwrap;
  reg  [PC_W-1:0]      rowpc [0:ROB_ROWS-1];

  always @(posedge clk) begin
    if (fire) begin
      rowwrap[t_row] <= tail_q[ROB_ROW_W];
      rowpc[t_row]   <= alloc_pc;
    end
  end

  assign h_rowpc = rowpc[h_row];

  reg [LANES*ROB_ROWS-1:0] wb_hit_c;
  reg [LANES*ROB_ROWS-1:0] xc_hit_c;

  reg [LANES*XC_PORTS*ROB_ROWS-1:0] xc_hit_pp_c;
  reg [TAG_W-1:0]          tg;
  integer                  pi;
  integer                  lk;
  integer                  rw;

  always @* begin
    wb_hit_c = {(LANES * ROB_ROWS){1'b0}};
    xc_hit_c = {(LANES * ROB_ROWS){1'b0}};
    xc_hit_pp_c = {(LANES * XC_PORTS * ROB_ROWS){1'b0}};
    tg       = {TAG_W{1'b0}};
    for (pi = 0; pi < WB_PORTS; pi = pi + 1) begin
      tg = wb_tag[pi*TAG_W +: TAG_W];
      for (lk = 0; lk < LANES; lk = lk + 1) begin
        for (rw = 0; rw < ROB_ROWS; rw = rw + 1) begin
          wb_hit_c[lk*ROB_ROWS + rw] = wb_hit_c[lk*ROB_ROWS + rw]
              | (wb_valid[pi] & (tg[1:0] == lk[1:0])
                 & (tg[TAG_W-2:2] == rw[ROB_ROW_W-1:0])
                 & (rowwrap[rw] == tg[TAG_W-1]));
        end
      end
    end
    for (pi = 0; pi < XC_PORTS; pi = pi + 1) begin
      tg = xc_tag[pi*TAG_W +: TAG_W];
      for (lk = 0; lk < LANES; lk = lk + 1) begin
        for (rw = 0; rw < ROB_ROWS; rw = rw + 1) begin
          xc_hit_pp_c[(lk*XC_PORTS + pi)*ROB_ROWS + rw]
              = (xc_valid[pi] & (tg[1:0] == lk[1:0])
                 & (tg[TAG_W-2:2] == rw[ROB_ROW_W-1:0])
                 & (rowwrap[rw] == tg[TAG_W-1]));
          xc_hit_c[lk*ROB_ROWS + rw] = xc_hit_c[lk*ROB_ROWS + rw]
              | xc_hit_pp_c[(lk*XC_PORTS + pi)*ROB_ROWS + rw];
        end
      end
    end
  end

  assign wb_hit = wb_hit_c;
  assign xc_hit = xc_hit_c;
  assign xc_hit_pp = xc_hit_pp_c;

  reg [LANES*ROB_ROWS-1:0] kill_hit_c;
  integer                  kl;
  integer                  kr;

  always @* begin
    kill_hit_c = {(LANES * ROB_ROWS){1'b0}};
    for (kl = 0; kl < LANES; kl = kl + 1) begin
      for (kr = 0; kr < ROB_ROWS; kr = kr + 1) begin
        kill_hit_c[kl*ROB_ROWS + kr]
            = (br_kill_valid & (br_kill_tag[1:0] == kl[1:0])
               & (br_kill_tag[TAG_W-2:2] == kr[ROB_ROW_W-1:0])
               & (rowwrap[kr] == br_kill_tag[TAG_W-1]));
      end
    end
  end

  assign kill_hit = kill_hit_c;

  assign kill_acc = (|kill_live) & ~clr;

  assign kill_ptr_c = br_kill_tag[TAG_W-1:2] + {{ROB_ROW_W{1'b0}}, 1'b1};
  wire [ROB_ROW_W:0]   kill_n_f = tail_q - kill_ptr_c;
  wire [ROB_ROW_W-1:0] kill_n   = kill_n_f[ROB_ROW_W-1:0];

  reg [LANES*ROB_ROWS-1:0] kill_m_c;
  reg [ROB_ROW_W-1:0]      row_dist;
  reg                      row_sq;
  reg                      t_row_hit;
  integer                  mk;
  integer                  mr;

  always @* begin
    kill_m_c  = {(LANES * ROB_ROWS){1'b0}};
    row_dist  = {ROB_ROW_W{1'b0}};
    row_sq    = 1'b0;
    t_row_hit = 1'b0;
    for (mr = 0; mr < ROB_ROWS; mr = mr + 1) begin
      row_dist  = mr[ROB_ROW_W-1:0] - kill_ptr_c[ROB_ROW_W-1:0];
      row_sq    = (row_dist < kill_n);
      t_row_hit = (br_kill_tag[TAG_W-2:2] == mr[ROB_ROW_W-1:0]);
      for (mk = 0; mk < LANES; mk = mk + 1) begin
        kill_m_c[mk*ROB_ROWS + mr]
            = kill_acc & (row_sq | (t_row_hit & (mk[1:0] > br_kill_tag[1:0])));
      end
    end
  end

  assign kill_m = kill_m_c;

  always @(posedge clk) begin
    if (!rst_n) begin
      squash_q <= 1'b0;
      lsu_q    <= 1'b0;
    end else begin
      squash_q <= kill_acc;
      lsu_q    <= commit_lsu_ready;
    end
  end

  always @(posedge clk) begin
    squash_tag_q <= br_kill_tag;
  end

  wire unused_ok = &{1'b0, kill_n_f[ROB_ROW_W]};

endmodule
`default_nettype wire
