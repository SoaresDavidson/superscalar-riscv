module retire_team_tb
  import execute_pkg::*;
  import dispatch_pkg::*;
#(
    parameter bit DEEP2 = 1'b0
);

  localparam int W         = 3;
  localparam int WB_N      = 4;
  localparam int ROB_ROWS  = 16;
  localparam int ROB_CNT_W = $clog2(3 * ROB_ROWS + 1);
  localparam int NI        = 512;

  localparam integer K_ALU    = 0;
  localparam integer K_BR     = 1;
  localparam integer K_LD     = 2;
  localparam integer K_ST     = 3;
  localparam integer K_ECALL  = 5;
  localparam integer K_EBREAK = 6;
  localparam integer K_MRET   = 7;
  localparam integer K_FENCE  = 8;
  localparam integer K_FENCEI = 9;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic reset;

  logic [W-1:0]               rob_alloc;
  rob_entry_t [W-1:0]         rob_entry;
  uop_t [W-1:0]               rob_uop;
  logic [W-1:0][2:0]          rob_sys_kind;
  logic [ROB_CNT_W-1:0]       rob_free;
  age_t [W-1:0]               rob_age;
  logic [WB_N-1:0]            resp_valid;
  fu_resp_t [WB_N-1:0]        resp;
  redirect_t                  redirect;
  logic [W-1:0]               commit_valid;
  reg_t [W-1:0]               commit_rd;
  tag_t [W-1:0]               commit_tag;
  tag_t [W-1:0]               commit_old_tag;
  logic                       flush;
  logic                       be_redirect_valid;
  xlen_t                      be_redirect_pc;
  logic [W-1:0]               st_commit;
  logic [W-1:0]               ld_commit;
  logic                       lsu_ready;
  logic                       mtvec_wr_valid;
  xlen_t                      mtvec_wr_data;
  logic [11:0]                csr_rd_addr;
  xlen_t                      csr_rd_data;
  logic                       csr_rd_hit;
  logic                       rob_empty;
  logic                       rob_full;
  logic                       flush_busy;

  logic                       ren_dispatch_valid;
  logic [W-1:0]               ren_slot_valid;
  logic [W-1:0][4:0]          ren_rs1;
  logic [W-1:0][4:0]          ren_rs2;
  logic [W-1:0][4:0]          ren_rd;
  logic [W-1:0]               ren_writes_rd;
  logic [W-1:0][W-1:0]        ren_rs1_dep;
  logic [W-1:0][W-1:0]        ren_rs2_dep;
  logic [W-1:0][W-1:0]        ren_rd_dep;
  logic                       ren_rob_ready;
  logic                       ren_dispatch_ready;
  logic [W-1:0][1:0]          ren_src_ready;
  logic [W-1:0][TAG_W-1:0]    ren_src1_tag;
  logic [W-1:0][TAG_W-1:0]    ren_src2_tag;
  logic [W-1:0][TAG_W-1:0]    ren_dst_tag;
  logic [W-1:0][TAG_W-1:0]    ren_old_tag;
  logic [0:0]                 ren_wb_valid;
  logic [0:0][TAG_W-1:0]      ren_wb_tag;
  logic [0:0][XLEN-1:0]       ren_wb_data;
  logic [5:0][TAG_W-1:0]      ren_read_tag;
  logic [5:0]                 ren_read_valid;
  logic [5:0][XLEN-1:0]       ren_read_data;

  retire_team #(
      .W       (W),
      .WB_N    (WB_N),
      .ROB_ROWS(ROB_ROWS),
      .DEEP2   (DEEP2),
      .DBG_EN  (1'b0)
  ) dut (
      .clk              (clk),
      .reset            (reset),
      .rob_alloc        (rob_alloc),
      .rob_entry        (rob_entry),
      .rob_uop          (rob_uop),
      .rob_sys_kind     (rob_sys_kind),
      .rob_free         (rob_free),
      .rob_age          (rob_age),
      .resp_valid       (resp_valid),
      .resp             (resp),
      .redirect         (redirect),
      .commit_valid     (commit_valid),
      .commit_rd        (commit_rd),
      .commit_tag       (commit_tag),
      .commit_old_tag   (commit_old_tag),
      .flush            (flush),
      .be_redirect_valid(be_redirect_valid),
      .be_redirect_pc   (be_redirect_pc),
      .st_commit        (st_commit),
      .ld_commit        (ld_commit),
      .lsu_ready        (lsu_ready),
      .mtvec_wr_valid   (mtvec_wr_valid),
      .mtvec_wr_data    (mtvec_wr_data),
      .csr_rd_addr      (csr_rd_addr),
      .csr_rd_data      (csr_rd_data),
      .csr_rd_hit       (csr_rd_hit),
      .rob_empty        (rob_empty),
      .rob_full         (rob_full),
      .flush_busy       (flush_busy)
  );

  PRFRename #(
      .ENTRIES(64),
      .W      (W),
      .WB_N   (1),
      .READ_N (6)
  ) ren (
      .clk           (clk),
      .reset         (reset),
      .flush         (flush),
      .dispatch_valid(ren_dispatch_valid),
      .slot_valid    (ren_slot_valid),
      .rs1           (ren_rs1),
      .rs2           (ren_rs2),
      .rd            (ren_rd),
      .writes_rd     (ren_writes_rd),
      .rs1_dep       (ren_rs1_dep),
      .rs2_dep       (ren_rs2_dep),
      .rd_dep        (ren_rd_dep),
      .rob_ready     (ren_rob_ready),
      .rs_ready      (1'b1),
      .dispatch_ready(ren_dispatch_ready),
      .src_ready     (ren_src_ready),
      .src1_tag      (ren_src1_tag),
      .src2_tag      (ren_src2_tag),
      .dst_tag       (ren_dst_tag),
      .old_tag       (ren_old_tag),
      .wb_valid      (ren_wb_valid),
      .wb_tag        (ren_wb_tag),
      .wb_data       (ren_wb_data),
      .read_tag      (ren_read_tag),
      .read_valid    (ren_read_valid),
      .read_data     (ren_read_data),
      .commit_valid  (commit_valid),
      .commit_rd     (commit_rd),
      .commit_tag    (commit_tag),
      .commit_old_tag(commit_old_tag)
  );

  integer      errors;
  integer      cyc;
  logic        chk_on;
  integer      n_disp;
  integer      n_comm;
  integer      rowseq;
  logic [63:0] next_pc;
  logic [63:0] exp_mtvec;

  integer      i_kind  [0:NI-1];
  integer      i_rd    [0:NI-1];
  integer      i_has   [0:NI-1];
  integer      i_lane  [0:NI-1];
  integer      i_row   [0:NI-1];
  integer      i_cpl   [0:NI-1];
  integer      i_exc   [0:NI-1];
  logic [63:0] i_pc    [0:NI-1];
  logic [TAG_W-1:0] i_pdst  [0:NI-1];
  logic [TAG_W-1:0] i_stale [0:NI-1];
  age_t        i_age   [0:NI-1];

  logic [TAG_W-1:0] refmap [0:31];

  integer      b_kind [0:2];
  integer      b_rd   [0:2];
  integer      b_rs1  [0:2];
  integer      b_rs2  [0:2];
  integer      b_chk_src1;

  logic        exp_flush_en;
  logic [63:0] exp_flush_pc;
  integer      flush_cnt;
  integer      cov_same_cycle;
  integer      cov_redir;
  integer      cov_commit_cycles;

  task fail(input string msg);
    begin
      errors = errors + 1;
      $display("FAIL cyc=%0d: %s", cyc, msg);
    end
  endtask

  task check_cycle;
    integer      k, j, n, row;
    logic [W-1:0] cv, exp_free, exp_st, exp_ld;
    logic        stop;
    begin
      if (chk_on) begin
        if ((^{commit_valid, flush, be_redirect_valid, st_commit, ld_commit, rob_free, dut.retire_commit_valid}) === 1'bx) begin
          fail("X or Z on an adapter output");
        end
        cv       = dut.retire_commit_valid;
        exp_free = '0;
        exp_st   = '0;
        exp_ld   = '0;
        stop     = 1'b0;
        if (rob_free !== 6'd0 && rob_free !== 6'd3) fail("rob_free is neither 0 nor W");
        if (cv !== 3'b000) begin
          cov_commit_cycles = cov_commit_cycles + 1;
          if (n_comm >= n_disp) begin
            fail("commit with nothing in flight");
            stop = 1'b1;
          end else begin
            k   = i_lane[n_comm];
            row = i_row[n_comm];
            for (j = 0; j < k; j = j + 1) begin
              if (cv[j]) begin
                fail("commit lane below the oldest uncommitted lane");
                stop = 1'b1;
              end
            end
            j = k;
            while (!stop && j < W && cv[j]) begin
              n = n_comm;
              if (n >= n_disp || i_row[n] != row || i_lane[n] != j) begin
                fail("commit run leaves the row or the program order");
                stop = 1'b1;
              end else begin
                if (!(i_cpl[n] >= 0 && i_cpl[n] < cyc)) fail("instruction committed before its completion was visible");
                if (i_exc[n] != 0) fail("faulting instruction committed");
                if (i_kind[n] == K_ECALL || i_kind[n] == K_EBREAK) fail("ECALL / EBREAK committed instead of trapping");
                exp_free[j] = (i_has[n] != 0);
                if (i_kind[n] == K_ST) exp_st[j] = 1'b1;
                if (i_kind[n] == K_LD) exp_ld[j] = 1'b1;
                if (i_has[n] != 0) begin
                  if (commit_rd[j] !== i_rd[n][4:0]) fail("commit_rd differs from the reference");
                  if (commit_tag[j] !== i_pdst[n]) fail("commit_tag differs from the rename dst_tag");
                  if (commit_old_tag[j] !== i_stale[n]) fail("commit_old_tag differs from the rename old_tag");
                  refmap[i_rd[n][4:0]] = i_pdst[n];
                end
                n_comm = n_comm + 1;
                j = j + 1;
              end
            end
            while (!stop && j < W) begin
              if (cv[j]) begin
                fail("commit set is not a contiguous run of lanes");
                stop = 1'b1;
              end
              j = j + 1;
            end
          end
        end
        if (!stop) begin
          if (commit_valid !== exp_free) fail("PRFRename commit_valid differs from the destination commits");
          if (st_commit !== exp_st) fail("st_commit differs from the committed stores");
          if (ld_commit !== exp_ld) fail("ld_commit differs from the committed loads");
        end
        if (flush === 1'b1) begin
          flush_cnt = flush_cnt + 1;
          if (!exp_flush_en) begin
            fail("unexpected flush");
          end else begin
            if (be_redirect_pc !== exp_flush_pc) begin
              fail("be_redirect_pc differs from the expected flush target");
              $display("  got %h expected %h", be_redirect_pc, exp_flush_pc);
            end
          end
          if (be_redirect_valid !== 1'b1) fail("be_redirect_valid differs from flush");
          if (commit_valid !== 3'b000) cov_same_cycle = cov_same_cycle + 1;
          exp_flush_en = 1'b0;
          n_disp  = n_comm;
          next_pc = be_redirect_pc;
        end else begin
          if (be_redirect_valid !== 1'b0) fail("be_redirect_valid without flush");
        end
      end
    end
  endtask

  task tick;
    begin
      check_cycle;
      @(posedge clk);
      #1;
      cyc = cyc + 1;
      rob_alloc          = '0;
      rob_entry          = '0;
      rob_uop            = '0;
      rob_sys_kind       = '0;
      resp_valid         = '0;
      resp               = '0;
      redirect           = '0;
      mtvec_wr_valid     = 1'b0;
      ren_dispatch_valid = 1'b0;
      ren_slot_valid     = '0;
      ren_rs1            = '0;
      ren_rs2            = '0;
      ren_rd             = '0;
      ren_writes_rd      = '0;
      ren_rs1_dep        = '0;
      ren_rs2_dep        = '0;
      ren_rd_dep         = '0;
    end
  endtask

  logic [63:0] mon_pc0, mon_pc1, mon_pc2;
  rob_entry_t  mon_e0, mon_e1, mon_e2;
  always @(posedge clk) begin
    if (chk_on) begin
      mon_e0  = rob_entry[0];
      mon_e1  = rob_entry[1];
      mon_e2  = rob_entry[2];
      mon_pc0 = mon_e0.pc;
      mon_pc1 = mon_e1.pc;
      mon_pc2 = mon_e2.pc;
      if (rob_alloc[1] && mon_pc1 !== mon_pc0 + 64'd4) fail("O1: pc of slot 1 is not pc0 + 4");
      if (rob_alloc[2] && mon_pc2 !== mon_pc0 + 64'd8) fail("O1: pc of slot 2 is not pc0 + 8");
    end
  end

  function exec_op_t op_of(input integer kind, input integer has);
    begin
      case (kind)
        K_ALU:   op_of = ALU_ADD;
        K_BR: begin
          if (has != 0) op_of = BR_JALR;
          else op_of = BR_BEQ;
        end
        K_LD:    op_of = AGU_LD;
        K_ST:    op_of = AGU_SD;
        default: op_of = OP_NONE;
      endcase
    end
  endfunction

  function logic [2:0] sys_of(input integer kind);
    begin
      case (kind)
        K_ECALL:  sys_of = 3'd1;
        K_EBREAK: sys_of = 3'd2;
        K_MRET:   sys_of = 3'd3;
        K_FENCE:  sys_of = 3'd4;
        K_FENCEI: sys_of = 3'd5;
        default:  sys_of = 3'd0;
      endcase
    end
  endfunction

  function integer is_sys(input integer kind);
    begin
      is_sys = (kind == K_ECALL || kind == K_EBREAK || kind == K_MRET || kind == K_FENCE || kind == K_FENCEI) ? 1 : 0;
    end
  endfunction

  task slot(input integer k, input integer kind, input integer rd, input integer rs1, input integer rs2);
    begin
      b_kind[k] = kind;
      b_rd[k]   = (kind == K_ST || is_sys(kind) != 0) ? 0 : rd;
      b_rs1[k]  = rs1;
      b_rs2[k]  = rs2;
    end
  endtask

  task dispatch(input integer n);
    integer       k, j, tmo, idx;
    logic [W-1:0] sv, wr, dep;
    logic [63:0]  pc0;
    rob_entry_t   e;
    uop_t         u;
    logic [W-1:0][TAG_W-1:0] dst, old;
    begin
      tmo = 0;
      while (rob_free !== 6'd3 || flush !== 1'b0) begin
        tick;
        tmo = tmo + 1;
        if (tmo > 300) begin
          fail("dispatch timeout: the ROB never became ready");
          tmo = 0;
        end
      end
      pc0 = next_pc;
      sv  = '0;
      wr  = '0;
      for (k = 0; k < W; k = k + 1) begin
        sv[k] = (k < n);
        wr[k] = (k < n) && (b_rd[k] != 0);
      end
      for (k = 0; k < W; k = k + 1) begin
        ren_rs1[k] = (k < n) ? b_rs1[k] : 0;
        ren_rs2[k] = (k < n) ? b_rs2[k] : 0;
        ren_rd[k]  = (k < n) ? b_rd[k] : 0;
        dep = '0;
        if (wr[k]) for (j = 0; j < k; j = j + 1) if (wr[j] && b_rd[j] == b_rd[k]) begin dep = '0; dep[j] = 1'b1; end
        ren_rd_dep[k] = dep;
        dep = '0;
        if (k < n && b_rs1[k] != 0) for (j = 0; j < k; j = j + 1) if (wr[j] && b_rd[j] == b_rs1[k]) begin dep = '0; dep[j] = 1'b1; end
        ren_rs1_dep[k] = dep;
        dep = '0;
        if (k < n && b_rs2[k] != 0) for (j = 0; j < k; j = j + 1) if (wr[j] && b_rd[j] == b_rs2[k]) begin dep = '0; dep[j] = 1'b1; end
        ren_rs2_dep[k] = dep;
      end
      ren_slot_valid     = sv;
      ren_writes_rd      = wr;
      ren_dispatch_valid = 1'b1;
      ren_rob_ready      = 1'b1;
      #1;
      if (ren_dispatch_ready !== 1'b1) fail("PRFRename refused a bundle");
      dst = ren_dst_tag;
      old = ren_old_tag;
      if (b_chk_src1 >= 0) begin
        if (ren_src1_tag[0] !== b_chk_src1[TAG_W-1:0]) begin
          fail("post-flush rename: src1_tag of the consumer is not the committed link tag");
          $display("  got %0d expected %0d", ren_src1_tag[0], b_chk_src1);
        end
        b_chk_src1 = -1;
      end
      for (k = 0; k < W; k = k + 1) begin
        e = '0;
        u = '0;
        if (k < n) begin
          e.pc          = pc0 + 64'(4 * k);
          e.rd          = b_rd[k][4:0];
          e.has_dest    = wr[k];
          e.dst_tag     = dst[k];
          e.old_tag     = old[k];
          e.done        = (is_sys(b_kind[k]) != 0);
          e.illegal     = 1'b0;
          e.serializing = (is_sys(b_kind[k]) != 0);
          u.valid       = 1'b1;
          u.pc          = e.pc;
          u.op          = op_of(b_kind[k], b_rd[k]);
          u.rd          = e.rd;
          u.has_dest    = wr[k];
          u.serializing = e.serializing;
        end
        rob_entry[k]    = e;
        rob_uop[k]      = u;
        rob_sys_kind[k] = (k < n) ? sys_of(b_kind[k]) : 3'd0;
      end
      rob_alloc = sv;
      #1;

      for (k = 0; k < n; k = k + 1) begin
        idx = n_disp + k;
        i_kind[idx]  = b_kind[k];
        i_rd[idx]    = b_rd[k];
        i_has[idx]   = wr[k] ? 1 : 0;
        i_lane[idx]  = k;
        i_row[idx]   = rowseq;
        i_exc[idx]   = 0;
        i_pc[idx]    = pc0 + 64'(4 * k);
        i_pdst[idx]  = dst[k];
        i_stale[idx] = old[k];
        i_age[idx]   = rob_age[k];
        i_cpl[idx]   = (is_sys(b_kind[k]) != 0) ? cyc : -1;
        if (idx > 0) begin
          if (!age_is_younger(i_age[idx], i_age[idx-1])) begin
            fail("rob_age is not monotonic in program order");
            $display("  age[%0d] = %0d, age[%0d] = %0d", idx, i_age[idx], idx - 1, i_age[idx-1]);
          end
        end
      end
      n_disp  = n_disp + n;
      rowseq  = rowseq + 1;
      next_pc = pc0 + 64'(4 * n);
      tick;
    end
  endtask

  task answer(input integer idx, input integer port, input logic exc, input exc_cause_t cause, input logic [63:0] result);
    fu_resp_t r;
    begin
      if (idx >= n_disp || idx < n_comm) fail("script: answer for an instruction that is not in flight");
      if (resp_valid[port]) tick;
      r           = '0;
      r.result    = result;
      r.dst_tag   = i_pdst[idx];
      r.wr_en     = (i_has[idx] != 0);
      r.age       = i_age[idx];
      r.exception = exc;
      r.cause     = cause;
      resp_valid[port] = 1'b1;
      resp[port]       = r;
      i_cpl[idx]       = cyc;
      if (exc) i_exc[idx] = 1;
    end
  endtask

  task complete(input integer idx);
    integer port;
    begin
      case (i_kind[idx])
        K_ALU:   port = 0;
        K_BR:    port = 1;
        K_LD:    port = 3;
        K_ST:    port = 2;
        default: port = 0;
      endcase
      answer(idx, port, 1'b0, CAUSE_NONE, 64'h0000_0000_0000_5a5a);
    end
  endtask

  task expect_flush(input logic [63:0] pc);
    begin
      exp_flush_en = 1'b1;
      exp_flush_pc = pc;
    end
  endtask

  task wait_flush;
    integer c0, t;
    begin
      c0 = flush_cnt;
      t  = 0;
      while (flush_cnt == c0 && t <= 120) begin
        tick;
        t = t + 1;
      end
      if (flush_cnt == c0) fail("no flush within 120 cycles");
      exp_flush_en = 1'b0;
    end
  endtask

  task drain;
    integer t;
    begin
      t = 0;
      while (n_comm < n_disp && t <= 200) begin
        tick;
        t = t + 1;
      end
      if (n_comm < n_disp) fail("drain timeout: instructions never committed");
      tick;
      tick;
      tick;
      if (rob_empty !== 1'b1) fail("rob_empty is not 1 after the drain");
    end
  endtask

  task csr_rd(input [11:0] a, input logic [63:0] expect_val, input string what);
    begin
      csr_rd_addr = a;
      tick;
      if (csr_rd_hit !== 1'b1) fail({what, ": csr_rd_hit is not 1"});
      if (csr_rd_data !== expect_val) begin
        fail({what, ": CSR value differs"});
        $display("  got %h expected %h", csr_rd_data, expect_val);
      end
    end
  endtask

  task mtvec_wr(input logic [63:0] v);
    begin
      mtvec_wr_valid = 1'b1;
      mtvec_wr_data  = v;
      exp_mtvec      = {v[63:2], 2'b00};
      tick;
    end
  endtask

  task check_map(input string what);
    integer r, k, bad;
    begin
      bad = 0;
      r   = 0;
      while (r < 32) begin
        for (k = 0; k < W; k = k + 1) begin
          ren_rs1[k] = (r + 2 * k < 32) ? r + 2 * k : 0;
          ren_rs2[k] = (r + 2 * k + 1 < 32) ? r + 2 * k + 1 : 0;
        end
        #1;
        for (k = 0; k < W; k = k + 1) begin
          if (r + 2 * k < 32) begin
            if (ren_src1_tag[k] !== refmap[r + 2 * k]) bad = bad + 1;
          end
          if (r + 2 * k + 1 < 32) begin
            if (ren_src2_tag[k] !== refmap[r + 2 * k + 1]) bad = bad + 1;
          end
        end
        r = r + 6;
      end
      ren_rs1 = '0;
      ren_rs2 = '0;
      if (bad != 0) begin
        fail({what, ": PRFRename mapping differs from the committed map"});
        $display("  %0d registers differ", bad);
      end
    end
  endtask

  integer      e0;
  integer      s_a, s_b, s_c, s_d, s_i;
  logic [63:0] s_pc;

  initial begin
    errors = 0; cyc = 0; chk_on = 1'b0; n_disp = 0; n_comm = 0; rowseq = 0; next_pc = 64'h0000_0000_0000_1000;
    exp_mtvec = 64'h0; b_chk_src1 = -1; exp_flush_en = 1'b0; exp_flush_pc = 64'h0; flush_cnt = 0;
    cov_same_cycle = 0; cov_redir = 0; cov_commit_cycles = 0;
    for (s_i = 0; s_i < 32; s_i = s_i + 1) refmap[s_i] = s_i[TAG_W-1:0];
    for (s_i = 0; s_i < NI; s_i = s_i + 1) begin
      i_kind[s_i] = 0; i_rd[s_i] = 0; i_has[s_i] = 0; i_lane[s_i] = 0; i_row[s_i] = 0; i_cpl[s_i] = -1; i_exc[s_i] = 0;
      i_pc[s_i] = '0; i_pdst[s_i] = '0; i_stale[s_i] = '0; i_age[s_i] = '0;
    end
    for (s_i = 0; s_i < 3; s_i = s_i + 1) begin b_kind[s_i] = 0; b_rd[s_i] = 0; b_rs1[s_i] = 0; b_rs2[s_i] = 0; end
    rob_alloc = '0; rob_entry = '0; rob_uop = '0; rob_sys_kind = '0; resp_valid = '0; resp = '0; redirect = '0;
    lsu_ready = 1'b1; mtvec_wr_valid = 1'b0; mtvec_wr_data = '0; csr_rd_addr = '0;
    ren_dispatch_valid = 1'b0; ren_slot_valid = '0; ren_rs1 = '0; ren_rs2 = '0; ren_rd = '0; ren_writes_rd = '0;
    ren_rs1_dep = '0; ren_rs2_dep = '0; ren_rd_dep = '0; ren_rob_ready = 1'b1;
    ren_wb_valid = '0; ren_wb_tag = '0; ren_wb_data = '0; ren_read_tag = '0;
    reset = 1'b1;
    repeat (5) @(posedge clk);
    #1;
    reset = 1'b0;
    repeat (3) @(posedge clk);
    #1;
    chk_on = 1'b1;

    $display("retire_team_tb start: DEEP2=%0d", DEEP2);

    e0 = errors;
    slot(0, K_ALU, 1, 0, 0); slot(1, K_ALU, 2, 1, 0); slot(2, K_LD, 3, 2, 0); dispatch(3);
    slot(0, K_ALU, 4, 3, 1); slot(1, K_ST, 0, 4, 2);                          dispatch(2);
    slot(0, K_BR, 0, 4, 1);                                                   dispatch(1);
    slot(0, K_ALU, 1, 2, 3); slot(1, K_ALU, 1, 1, 0); slot(2, K_ALU, 2, 1, 2); dispatch(3);
    for (s_i = n_disp - 1; s_i >= n_comm; s_i = s_i - 1) complete(s_i);
    drain;
    check_map("S1");
    csr_rd(12'hB02, n_comm, "S1 minstret");
    if (errors == e0) $display("PASS S1 bundles of 3 / 2 / 1 slots completed by age in reverse order (%0d instructions)", n_comm);

    e0 = errors;
    mtvec_wr(64'h0000_0000_8000_0100);
    s_pc = next_pc;
    slot(0, K_ALU, 5, 0, 0); slot(1, K_LD, 6, 5, 0); slot(2, K_ALU, 7, 0, 0); dispatch(3);
    s_a = n_disp - 3; s_b = n_disp - 2; s_c = n_disp - 1;
    expect_flush(exp_mtvec);
    complete(s_a);
    complete(s_c);
    answer(s_b, 2, 1'b1, CAUSE_LOAD_MISALIGNED, 64'h0000_0000_0001_2343);
    wait_flush;
    tick;
    csr_rd(12'h341, s_pc + 64'd4, "S2 mepc");
    csr_rd(12'h342, 64'd4, "S2 mcause");
    csr_rd(12'h343, 64'h0000_0000_0001_2343, "S2 mtval");
    check_map("S2 after the trap");

    if (next_pc !== exp_mtvec) fail("S2: the refetch pc after the trap is not mtvec");
    slot(0, K_ALU, 7, 0, 0); slot(1, K_MRET, 0, 0, 0); dispatch(2);
    s_a = n_disp - 2;
    expect_flush(s_pc + 64'd4);
    complete(s_a);
    wait_flush;
    drain;
    check_map("S2 after MRET");
    if (errors == e0) $display("PASS S2 misaligned load trap (mepc, mcause, mtval) and MRET from lane 1");

    e0 = errors;
    slot(0, K_ALU, 8, 0, 0); slot(1, K_BR, 0, 8, 0); slot(2, K_ST, 0, 8, 9); dispatch(3);
    s_a = n_disp - 3; s_b = n_disp - 2; s_c = n_disp - 1;
    complete(s_a);
    complete(s_c);
    tick;

    answer(s_b, 1, 1'b0, CAUSE_NONE, 64'h0);
    redirect.valid = 1'b1; redirect.pc = 64'h0000_0000_0000_4000; redirect.age = i_age[s_b];
    expect_flush(64'h0000_0000_0000_4000);
    wait_flush;
    drain;
    check_map("S3");
    csr_rd(12'hB02, n_comm, "S3 minstret");
    if (errors == e0) $display("PASS S3 lane 1 mispredict, younger store never commits, minstret counts the branch");

    e0 = errors;
    slot(0, K_ALU, 5, 0, 0); slot(1, K_BR, 5, 5, 0); slot(2, K_ALU, 6, 0, 0); dispatch(3);
    s_a = n_disp - 3; s_b = n_disp - 2; s_c = n_disp - 1;
    complete(s_a);
    complete(s_c);
    tick;
    answer(s_b, 1, 1'b0, CAUSE_NONE, 64'h0000_0000_0000_8888);
    redirect.valid = 1'b1; redirect.pc = 64'h0000_0000_0000_6000; redirect.age = i_age[s_b];
    expect_flush(64'h0000_0000_0000_6000);
    wait_flush;

    b_chk_src1 = i_pdst[s_b];
    slot(0, K_ALU, 9, 5, 0); slot(1, K_ALU, 5, 5, 9); dispatch(2);
    s_a = n_disp - 2; s_b = n_disp - 1;
    complete(s_a);
    complete(s_b);
    drain;
    check_map("S4");
    if (errors == e0) $display("PASS S4 linking mispredict, same-cycle commit applied over the restore");

    e0 = errors;
    s_pc = next_pc;
    slot(0, K_ALU, 8, 0, 0); slot(1, K_ECALL, 0, 0, 0); slot(2, K_ALU, 9, 0, 0); dispatch(3);
    s_a = n_disp - 3; s_c = n_disp - 1;
    expect_flush(exp_mtvec);
    complete(s_a);
    complete(s_c);
    wait_flush;
    tick;
    csr_rd(12'h341, s_pc + 64'd4, "S5 mepc");
    csr_rd(12'h342, 64'd11, "S5 mcause");
    check_map("S5");

    slot(0, K_ALU, 8, 0, 0); slot(1, K_ALU, 9, 8, 0); dispatch(2);
    complete(n_disp - 1);
    complete(n_disp - 2);
    drain;
    if (errors == e0) $display("PASS S5 ECALL in lane 1 traps with mepc = pc0 + 4, mcause 11");

    e0 = errors;
    slot(0, K_BR, 0, 8, 9); slot(1, K_ALU, 10, 0, 0); slot(2, K_ALU, 11, 0, 0); dispatch(3);
    s_a = n_disp - 3; s_b = n_disp - 2; s_c = n_disp - 1;
    complete(s_b);
    complete(s_c);
    tick;
    answer(s_a, 1, 1'b0, CAUSE_NONE, 64'h0);
    redirect.valid = 1'b1; redirect.pc = 64'h0000_0000_0000_7000; redirect.age = i_age[s_a];
    expect_flush(64'h0000_0000_0000_7000);
    wait_flush;
    drain;
    check_map("S6");
    if (errors == e0) $display("PASS S6 BRU answer and redirect of one age: the redirect wins");

    e0 = errors;
    slot(0, K_ALU, 12, 0, 0); slot(1, K_FENCE, 0, 0, 0); slot(2, K_FENCEI, 0, 0, 0); dispatch(3);
    complete(n_disp - 3);
    drain;
    slot(0, K_ALU, 13, 0, 0); slot(1, K_ALU, 14, 0, 0); dispatch(2);
    complete(n_disp - 2);
    complete(n_disp - 1);
    drain;
    check_map("S7");
    csr_rd(12'hB02, n_comm, "S7 minstret");
    if (errors == e0) $display("PASS S7 FENCE and FENCE.I in lanes 1 and 2 commit alone");

    e0 = errors;
    if (cov_same_cycle < 1) fail("S4 never produced a flush cycle that also commits a destination");
    if (flush_cnt != 6) begin
      fail("unexpected number of flush cycles");
      $display("  flushes %0d, expected 6 (S2 trap, S2 MRET, S3, S4, S5, S6)", flush_cnt);
    end

    s_d = 0;
    for (s_i = 0; s_i < 11; s_i = s_i + 1) begin
      s_a = (s_i < 10) ? 3 : 2;
      for (s_b = 0; s_b < 3; s_b = s_b + 1) begin
        ren_rd[s_b] = (s_b < s_a) ? 1 + ((s_i * 3 + s_b) % 31) : 0;
      end
      ren_slot_valid     = (s_a == 3) ? 3'b111 : 3'b011;
      ren_writes_rd      = ren_slot_valid;
      ren_dispatch_valid = 1'b1;
      ren_rob_ready      = 1'b1;
      #1;
      if (ren_dispatch_ready !== 1'b1) begin
        fail("PRFRename stalls before 32 new destinations were renamed");
        s_d = s_d + 1;
      end
      @(posedge clk);
      #1;
      cyc = cyc + 1;
    end
    ren_rd = '0;
    ren_slot_valid = 3'b001;
    ren_writes_rd  = 3'b001;
    ren_rd[0]      = 5'd1;
    #1;
    if (ren_dispatch_ready !== 1'b0) fail("PRFRename still accepts a 33rd destination: more than 32 free tags");
    if (errors == e0) $display("PASS drain: 32 free tags after %0d commits and %0d flushes", n_comm, flush_cnt);

    if (errors == 0) begin
      $display("PASS retire_team_tb DEEP2=%0d", DEEP2);
      $display("TEST PASSED");
    end else begin
      $display("TEST FAILED: %0d", errors);
      $fatal(1, "retire_team_tb: %0d errors", errors);
    end
    $finish;
  end

  initial begin
    #3000000;
    $display("TEST FAILED: watchdog");
    $fatal(1, "retire_team_tb: watchdog");
  end

endmodule
