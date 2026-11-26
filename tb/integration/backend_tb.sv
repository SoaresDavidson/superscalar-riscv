// Integration testbench: the back end wired together and running a program.
//
//   decode -> dispatch -> PRFRename -> rs_int -> alu
//                                   -> rs_mem -> agu -> (LSU model)
//                      -> retire_team (ROB) -> commit -> PRFRename
//
// The program is RV64I machine code fed to the Decode in bundles of 3. The
// testbench plays only the blocks that do not exist yet:
//   - Memory/LSU: loads take LSU_LAT cycles after the AGU and answer on the
//     load write-back bus and on ROB response port 3. Memory is read-only
//     (store data has no path to Memory yet, rtl/execute/README.md); stores
//     complete through the AGU on ROB port 2.
//   - Branch Unit: absent. The program has no branches or jumps.
//
// Checks:
//   - the commit stream: every register-writing instruction commits once, in
//     program order, with the value a reference model computes;
//   - every instruction commits (ALU, loads and stores), no flush happens;
//   - at the end the ROB is empty and both RS are empty.
//
// Hazards covered: dependencies inside one bundle, same register as source
// and destination, x0 as destination, a load result feeding ALU work,
// out-of-order completion (slow loads, fast ALU), and back-pressure: the
// RS INT fills and the RS MEM runs short, and Dispatch holds the bundle.
// Not covered (no Branch Unit): flush with results in flight, tag reuse
// after flush.

// Outputs nobody reads yet (redirects, CSR reads) stay unconnected on purpose.
/* verilator lint_off PINCONNECTEMPTY */
module backend_tb #(
    parameter bit DEEP2   = 1'b0,
    parameter int LSU_LAT = 4
);
  import execute_pkg::*;
  import dispatch_pkg::*;

  localparam int W        = 3;
  localparam int WB_N     = 3;   // register write-back buses: ALU, Branch Unit, load
  localparam int READ_N   = 7;
  localparam int ROB_N    = 4;   // ROB response ports: ALU, Branch Unit, AGU, LSU
  localparam int MAX_CYC  = 3000;

  logic clk = 1'b0, reset;
  initial forever #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // Program (filled in the initial block below)
  // ---------------------------------------------------------------------------
  localparam int NPROG = 42;
  logic [31:0] prog [NPROG];
  localparam logic [63:0] PC0  = 64'h0000_1000;

  // ---------------------------------------------------------------------------
  // Wires between the blocks
  // ---------------------------------------------------------------------------
  logic                        flush;

  // Front: testbench -> decode
  logic                        in_valid, in_ready;
  logic [W-1:0]                in_slot_valid;
  logic [W-1:0][31:0]          in_inst;
  logic [W-1:0][XLEN-1:0]      in_pc;

  // decode -> dispatch / rename
  logic                        dec_valid, dec_ready;
  uop_t [W-1:0]                dec_uop;
  logic [W-1:0][W-1:0]         dep_rs1, dep_rs2, dep_rd;

  // dispatch <-> rename
  logic                        ren_dispatch_valid, ren_dispatch_ready;
  logic [W-1:0]                ren_slot_valid, ren_writes_rd;
  logic [W-1:0][REG_W-1:0]     ren_rs1, ren_rs2, ren_rd;
  logic                        ren_rob_ready, ren_rs_ready;
  logic [W-1:0][1:0]           ren_src_ready;
  logic [W-1:0][TAG_W-1:0]     ren_src1_tag, ren_src2_tag, ren_dst_tag, ren_old_tag;

  // dispatch <-> ROB
  logic [5:0]                  rob_free;
  age_t [W-1:0]                rob_age;
  logic [W-1:0]                rob_alloc;
  rob_entry_t [W-1:0]          rob_entry;
  uop_t [W-1:0]                rob_uop;

  // dispatch -> RS
  logic [3:0]                  int_free;
  logic [W-1:0]                int_wr;
  rs_int_entry_t [W-1:0]       int_entry;
  logic [2:0]                  mem_free;
  logic [W-1:0]                mem_wr;
  rs_mem_entry_t [W-1:0]       mem_entry;

  // Register write-back buses (RS wakeup and PRF write)
  logic [WB_N-1:0]             wb_valid;
  logic [WB_N-1:0][TAG_W-1:0]  wb_tag;
  logic [WB_N-1:0][XLEN-1:0]   wb_data;

  // PRF read ports: 0-1 ALU, 2-3 Branch Unit, 4-5 AGU
  logic [READ_N-1:0][TAG_W-1:0] rd_tag;
  logic [READ_N-1:0]            rd_valid;
  logic [READ_N-1:0][XLEN-1:0]  rd_data;

  // RS -> FUs
  logic                        alu_req_valid, alu_req_ready;
  fu_req_t                     alu_req;
  logic                        br_req_valid;
  fu_req_t                     br_req;
  logic                        agu_ld_req_valid, agu_ld_req_ready;
  fu_req_t                     agu_ld_req;
  lsq_idx_t                    agu_ld_req_lsq_idx;
  sb_ptr_t                     agu_ld_req_color;
  exec_op_t                    agu_ld_op;
  logic                        agu_st_req_valid, agu_st_req_ready;
  fu_req_t                     agu_st_req;
  lsq_idx_t                    agu_st_req_lsq_idx;

  // FUs -> write-back / ROB
  logic                        alu_resp_valid, agu_ld_resp_valid, agu_st_resp_valid;
  fu_resp_t                    alu_resp, agu_ld_resp, agu_st_resp;
  logic                        lsu_valid;        // LSU model answer
  fu_resp_t                    lsu_resp;

  // ROB -> rename (commit)
  logic [W-1:0]                commit_valid;
  reg_t [W-1:0]                commit_rd;
  tag_t [W-1:0]                commit_tag, commit_old_tag;
  logic [W-1:0]                st_commit, ld_commit;
  logic                        rob_empty;

  // ---------------------------------------------------------------------------
  // Blocks
  // ---------------------------------------------------------------------------
  decode #(.WIDTH(W)) u_decode (
      .clk, .reset, .flush,
      .in_valid, .in_ready, .in_slot_valid, .in_inst, .in_pc,
      .out_valid      (dec_valid),
      .out_ready      (dec_ready),
      .out_uop        (dec_uop),
      .out_dep_rs1    (dep_rs1),
      .out_dep_rs2    (dep_rs2),
      .out_dep_rd     (dep_rd),
      .redirect_valid (),
      .redirect_pc    (),
      .out_slot_kill  ()
  );

  dispatch #(.W(W)) u_dispatch (
      .clk, .reset, .flush,
      .dec_valid, .dec_uop, .dec_ready,
      .ren_dispatch_valid, .ren_slot_valid, .ren_rs1, .ren_rs2, .ren_rd,
      .ren_writes_rd, .ren_rob_ready, .ren_rs_ready,
      .ren_dispatch_ready, .ren_src_ready, .ren_src1_tag, .ren_src2_tag,
      .ren_dst_tag, .ren_old_tag,
      .rob_free, .rob_age, .rob_alloc, .rob_entry, .rob_uop,
      .int_free, .int_wr, .int_entry,
      .mem_free, .mem_wr, .mem_entry
  );

  PRFRename #(.XLEN(XLEN), .ENTRIES(PRF_ENTRIES), .W(W), .WB_N(WB_N), .READ_N(READ_N)) u_rename (
      .clk, .reset, .flush,
      .dispatch_valid (ren_dispatch_valid),
      .slot_valid     (ren_slot_valid),
      .rs1            (ren_rs1),
      .rs2            (ren_rs2),
      .rd             (ren_rd),
      .writes_rd      (ren_writes_rd),
      .rs1_dep        (dep_rs1),
      .rs2_dep        (dep_rs2),
      .rd_dep         (dep_rd),
      .rob_ready      (ren_rob_ready),
      .rs_ready       (ren_rs_ready),
      .dispatch_ready (ren_dispatch_ready),
      .src_ready      (ren_src_ready),
      .src1_tag       (ren_src1_tag),
      .src2_tag       (ren_src2_tag),
      .dst_tag        (ren_dst_tag),
      .old_tag        (ren_old_tag),
      .wb_valid, .wb_tag, .wb_data,
      .read_tag       (rd_tag),
      .read_valid     (rd_valid),
      .read_data      (rd_data),
      .commit_valid, .commit_rd, .commit_tag, .commit_old_tag
  );

  rs_int #(.W(W), .WB_N(WB_N)) u_rs_int (
      .clk, .reset, .flush,
      .wr (int_wr), .wr_entry (int_entry), .free (int_free),
      .wb_valid, .wb_tag,
      .alu_req_valid, .alu_req_ready, .alu_req,
      .alu_read_tag   (rd_tag[1:0]),
      .alu_read_valid (rd_valid[1:0]),
      .alu_read_data  (rd_data[1:0]),
      .br_req_valid, .br_req_ready (1'b0), .br_req,     // no Branch Unit yet
      .br_read_tag    (rd_tag[3:2]),
      .br_read_valid  (rd_valid[3:2]),
      .br_read_data   (rd_data[3:2])
  );

  rs_mem #(.W(W), .WB_N(WB_N)) u_rs_mem (
      .clk, .reset, .flush,
      .wr (mem_wr), .wr_entry (mem_entry), .free (mem_free),
      .wb_valid, .wb_tag,
      .agu_ld_req_valid, .agu_ld_req_ready, .agu_ld_req,
      .agu_ld_req_lsq_idx, .agu_ld_req_color,
      .agu_ld_read_tag   (rd_tag[4]),
      .agu_ld_read_valid (rd_valid[4]),
      .agu_ld_read_data  (rd_data[4]),
      .agu_st_req_valid, .agu_st_req_ready, .agu_st_req,
      .agu_st_req_lsq_idx,
      .agu_st_read_tag   (rd_tag[6:5]),
      .agu_st_read_valid (rd_valid[6:5]),
      .agu_st_read_data  (rd_data[6:5])
  );

  // The FUs flush selectively by age; the ROB flushes everything at commit.
  // This program never flushes (checked below), so flush_age is not used.
  alu u_alu (
      .clk, .reset, .flush, .flush_age ('0),
      .req_valid (alu_req_valid), .req_ready (alu_req_ready), .req (alu_req),
      .resp_valid (alu_resp_valid), .resp_ready (1'b1), .resp (alu_resp)
  );

  // Two AGUs (wiki decision 17): loads and stores.
  agu u_agu_ld (
      .clk, .reset, .flush, .flush_age ('0),
      .req_valid (agu_ld_req_valid), .req_ready (agu_ld_req_ready), .req (agu_ld_req),
      .req_lsq_idx (agu_ld_req_lsq_idx), .req_color (agu_ld_req_color),
      .resp_valid (agu_ld_resp_valid), .resp_ready (1'b1), .resp (agu_ld_resp),
      .resp_is_load (), .resp_store_data (), .resp_op (agu_ld_op),
      .resp_lsq_idx (), .resp_color ()
  );

  agu u_agu_st (
      .clk, .reset, .flush, .flush_age ('0),
      .req_valid (agu_st_req_valid), .req_ready (agu_st_req_ready), .req (agu_st_req),
      .req_lsq_idx (agu_st_req_lsq_idx), .req_color ('0),
      .resp_valid (agu_st_resp_valid), .resp_ready (1'b1), .resp (agu_st_resp),
      .resp_is_load (), .resp_store_data (), .resp_op (),
      .resp_lsq_idx (), .resp_color ()
  );

  // ---------------------------------------------------------------------------
  // Write-back and ROB responses (the wiring in rtl/issue/README.md)
  // ---------------------------------------------------------------------------
  // Register write-back: ALU on bus 0, Branch Unit on bus 1 (absent), load
  // data on bus 2. Only instructions that write a register announce a tag.
  assign wb_valid[0] = alu_resp_valid && alu_resp.wr_en;
  assign wb_tag[0]   = alu_resp.dst_tag;
  assign wb_data[0]  = alu_resp.result;
  assign wb_valid[1] = 1'b0;
  assign wb_tag[1]   = '0;
  assign wb_data[1]  = '0;
  assign wb_valid[2] = lsu_valid && lsu_resp.wr_en;
  assign wb_tag[2]   = lsu_resp.dst_tag;
  assign wb_data[2]  = lsu_resp.result;

  // ROB responses. A load is done when its DATA arrives (port 3), not when
  // the AGU computes the address: port 2 takes the store AGU, or the load AGU
  // only with an exception. This program raises no exception, so the two
  // never contest port 2 (checked below) and no arbiter is needed here.
  logic ld_exc;
  assign ld_exc = agu_ld_resp_valid && agu_ld_resp.exception;
  always @(posedge clk)
    if (!reset && ld_exc && agu_st_resp_valid)
      $fatal(1, "backend_tb: load exception and store on ROB port 2 in one cycle");

  logic [ROB_N-1:0]     resp_valid;
  fu_resp_t [ROB_N-1:0] resp;
  assign resp_valid[0] = alu_resp_valid;
  assign resp[0]       = alu_resp;
  assign resp_valid[1] = 1'b0;
  assign resp[1]       = '0;
  assign resp_valid[2] = agu_st_resp_valid || ld_exc;
  assign resp[2]       = ld_exc ? agu_ld_resp : agu_st_resp;
  assign resp_valid[3] = lsu_valid;
  assign resp[3]       = lsu_resp;

  retire_team #(.DEEP2(DEEP2)) u_rob (
      .clk, .reset,
      .rob_alloc, .rob_entry, .rob_uop,
      .rob_sys_kind     ('0),            // no sys_kind in uop_t yet
      .rob_free, .rob_age,
      .resp_valid, .resp,
      .redirect         ('0),
      .commit_valid, .commit_rd, .commit_tag, .commit_old_tag,
      .flush,
      .be_redirect_valid(),
      .be_redirect_pc   (),
      .st_commit, .ld_commit,
      .lsu_ready        (1'b1),
      .mtvec_wr_valid   (1'b0),
      .mtvec_wr_data    ('0),
      .csr_rd_addr      ('0),
      .csr_rd_data      (),
      .csr_rd_hit       (),
      .rob_empty,
      .rob_full         (),
      .flush_busy       ()
  );

  // ---------------------------------------------------------------------------
  // Memory model (read-only) and LSU model
  // ---------------------------------------------------------------------------
  function automatic logic [63:0] mem64(logic [63:0] a);
    logic [31:0] lo;
    lo = a[31:0] & 32'hFFFF_FFF8;
    return {32'h8000_0000 | (lo + 32'd4), 32'h9000_0000 | lo};
  endfunction

  function automatic logic [63:0] load_value(exec_op_t op, logic [63:0] a);
    logic [63:0] d;
    logic [31:0] w;
    d = mem64(a);
    w = a[2] ? d[63:32] : d[31:0];
    if (op == AGU_LW) return {{32{w[31]}}, w};
    return d;   // AGU_LD
  endfunction

  // Loads leave the AGU, wait LSU_LAT cycles and answer one per cycle.
  localparam int QN = 16;
  fu_resp_t q_resp [QN];
  int       q_due  [QN];
  int       q_head, q_tail, cyc;

  always @(posedge clk) begin
    if (reset) begin
      q_head <= 0; q_tail <= 0; cyc <= 0;
      lsu_valid <= 1'b0; lsu_resp <= '0;
    end else begin
      cyc <= cyc + 1;
      if (agu_ld_resp_valid && !agu_ld_resp.exception) begin
        fu_resp_t r;
        r        = agu_ld_resp;
        r.result = load_value(agu_ld_op, agu_ld_resp.result);
        q_resp[q_tail % QN] <= r;
        q_due[q_tail % QN]  <= cyc + LSU_LAT;
        q_tail <= q_tail + 1;
      end
      if (q_head != q_tail && q_due[q_head % QN] <= cyc) begin
        lsu_valid <= 1'b1;
        lsu_resp  <= q_resp[q_head % QN];
        q_head    <= q_head + 1;
      end else begin
        lsu_valid <= 1'b0;
      end
    end
  end


  // ---------------------------------------------------------------------------
  // Front end: bundles of 3 consecutive instructions from the program
  // ---------------------------------------------------------------------------
  int b;   // next bundle
  for (genvar k = 0; k < W; k++) begin : g_front
    assign in_slot_valid[k] = (3 * b + k) < NPROG;
    assign in_inst[k]       = ((3 * b + k) < NPROG) ? prog[3 * b + k] : 32'h0000_0013;
    assign in_pc[k]         = PC0 + 64'(4 * (3 * b + k));
  end
  assign in_valid = !reset && (3 * b < NPROG);

  always @(posedge clk) begin
    if (reset) b <= 0;
    else if (in_valid && in_ready) b <= b + 1;
  end

  // ---------------------------------------------------------------------------
  // Encoders (RV64I)
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] enc_i(int imm, int rs1, int f3, int rd, logic [6:0] opc);
    return {12'(imm), 5'(rs1), 3'(f3), 5'(rd), opc};
  endfunction
  function automatic logic [31:0] enc_r(logic [6:0] f7, int rs2, int rs1, int f3, int rd, logic [6:0] opc);
    return {f7, 5'(rs2), 5'(rs1), 3'(f3), 5'(rd), opc};
  endfunction
  function automatic logic [31:0] enc_s(int imm, int rs2, int rs1, int f3);
    logic [11:0] i;
    i = 12'(imm);
    return {i[11:5], 5'(rs2), 5'(rs1), 3'(f3), i[4:0], 7'h23};
  endfunction

  function automatic logic [31:0] ADDI(int rd, int rs1, int imm); return enc_i(imm, rs1, 0, rd, 7'h13); endfunction
  function automatic logic [31:0] SLLI(int rd, int rs1, int sh);  return enc_i(sh & 63, rs1, 1, rd, 7'h13); endfunction
  function automatic logic [31:0] SRLI(int rd, int rs1, int sh);  return enc_i(sh & 63, rs1, 5, rd, 7'h13); endfunction
  function automatic logic [31:0] ADD (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 0, rd, 7'h33); endfunction
  function automatic logic [31:0] SUB (int rd, int rs1, int rs2); return enc_r(7'h20, rs2, rs1, 0, rd, 7'h33); endfunction
  function automatic logic [31:0] XOR (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 4, rd, 7'h33); endfunction
  function automatic logic [31:0] OR  (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 6, rd, 7'h33); endfunction
  function automatic logic [31:0] AND (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 7, rd, 7'h33); endfunction
  function automatic logic [31:0] SLT (int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 2, rd, 7'h33); endfunction
  function automatic logic [31:0] ADDW(int rd, int rs1, int rs2); return enc_r(7'h00, rs2, rs1, 0, rd, 7'h3B); endfunction
  function automatic logic [31:0] LUI (int rd, int imm20);        return {20'(imm20), 5'(rd), 7'h37}; endfunction
  function automatic logic [31:0] LD  (int rd, int rs1, int imm); return enc_i(imm, rs1, 3, rd, 7'h03); endfunction
  function automatic logic [31:0] LW  (int rd, int rs1, int imm); return enc_i(imm, rs1, 2, rd, 7'h03); endfunction
  function automatic logic [31:0] SD  (int rs2, int rs1, int imm); return enc_s(imm, rs2, rs1, 3); endfunction

  // ---------------------------------------------------------------------------
  // Reference model: runs the program in order and lists, for every
  // instruction that writes a register (rd != x0), the (rd, value) the
  // commit stream must show.
  // ---------------------------------------------------------------------------
  logic [63:0] x [32];
  int          exp_rd  [NPROG];
  logic [63:0] exp_val [NPROG];
  int          n_exp, n_st, n_ld;

  function automatic logic [63:0] sext12(logic [31:0] i);
    return {{52{i[31]}}, i[31:20]};
  endfunction

  task automatic reference();
    for (int r = 0; r < 32; r++) x[r] = '0;
    n_exp = 0; n_st = 0; n_ld = 0;
    for (int p = 0; p < NPROG; p++) begin
      logic [31:0] i;
      logic [63:0] v, a, b2, imm;
      int rd, rs1, rs2;
      logic [6:0] opc;
      logic [2:0] f3;
      logic writes;
      i    = prog[p];
      opc  = i[6:0];  f3 = i[14:12];
      rd   = i[11:7]; rs1 = i[19:15]; rs2 = i[24:20];
      a    = x[rs1];  b2 = x[rs2];
      imm  = sext12(i);
      writes = 1'b1;
      v      = '0;
      case (opc)
        7'h13: case (f3)
                 3'd0: v = a + imm;
                 3'd1: v = a << i[25:20];
                 3'd5: v = a >> i[25:20];
                 default: $fatal(1, "reference: OP-IMM f3 %0d not modelled", f3);
               endcase
        7'h33: case ({i[30], f3})
                 4'b0000: v = a + b2;
                 4'b1000: v = a - b2;
                 4'b0100: v = a ^ b2;
                 4'b0110: v = a | b2;
                 4'b0111: v = a & b2;
                 4'b0010: v = ($signed(a) < $signed(b2)) ? 64'd1 : 64'd0;
                 default: $fatal(1, "reference: OP not modelled");
               endcase
        7'h3B: begin logic [31:0] s; s = a[31:0] + b2[31:0]; v = {{32{s[31]}}, s}; end
        7'h37: v = {{32{i[31]}}, i[31:12], 12'h000};
        7'h03: begin
                 n_ld++;
                 v = load_value(exec_op_t'((f3 == 3'd2) ? AGU_LW : AGU_LD), a + imm);
               end
        7'h23: begin writes = 1'b0; n_st++; end
        default: $fatal(1, "reference: opcode %h not modelled", opc);
      endcase
      if (writes && rd != 0) begin
        x[rd] = v;
        exp_rd[n_exp]  = rd;
        exp_val[n_exp] = v;
        n_exp++;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Monitors
  // ---------------------------------------------------------------------------
  logic [63:0] val_by_tag [PRF_ENTRIES];   // last value written to each tag
  int n_commit_rd, n_commit_all, n_commit_st, n_commit_ld;
  int max_int_used, max_mem_used;
  logic seen_rs_stall, seen_int_full, seen_rename_stall;

  // Sample on the falling edge, when every registered output is stable.
  always @(negedge clk) begin
    if (!reset) begin
      for (int p = 0; p < WB_N; p++)
        if (wb_valid[p]) val_by_tag[wb_tag[p]] = wb_data[p];

      if (flush) $fatal(1, "unexpected flush (cycle %0d)", cyc);

      for (int k = 0; k < W; k++) begin
        if (commit_valid[k]) begin
          if (n_commit_rd >= n_exp)
            $fatal(1, "more register commits than the program has");
          if (commit_rd[k] !== 5'(exp_rd[n_commit_rd]))
            $fatal(1, "commit %0d: rd = x%0d, expected x%0d",
                   n_commit_rd, commit_rd[k], exp_rd[n_commit_rd]);
          if (val_by_tag[commit_tag[k]] !== exp_val[n_commit_rd])
            $fatal(1, "commit %0d (x%0d): value %h, expected %h",
                   n_commit_rd, commit_rd[k], val_by_tag[commit_tag[k]],
                   exp_val[n_commit_rd]);
          n_commit_rd++;
        end
        if (u_rob.retire_commit_valid[k]) n_commit_all++;
        if (st_commit[k]) n_commit_st++;
        if (ld_commit[k]) n_commit_ld++;
      end

      if (dec_valid && !u_dispatch.rs_ok) seen_rs_stall = 1'b1;
      if (int_free == 4'd0) seen_int_full = 1'b1;
      if (dec_valid && !ren_dispatch_ready) seen_rename_stall = 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Program and run
  // ---------------------------------------------------------------------------
  initial begin
    int p;
    p = 0;
    // Bundle 0: dependencies inside the bundle (x2 needs x1, x3 needs both).
    prog[p++] = ADDI(1, 0, 5);
    prog[p++] = ADDI(2, 1, 3);
    prog[p++] = ADD (3, 1, 2);
    // Bundle 1: same register as source and destination; x0 as destination.
    prog[p++] = ADDI(1, 1, 1);
    prog[p++] = ADDI(0, 3, 7);          // writes nothing
    prog[p++] = SUB (4, 3, 1);
    // Bundle 2: base address of the data area, and a 32-bit overflow.
    prog[p++] = LUI (10, 32'h00008);    // x10 = 0x8000 = BASE
    prog[p++] = LUI (5, 32'h7FFFF);
    prog[p++] = ADDW(6, 5, 5);          // wraps and sign-extends
    // Bundles 3-6: eight loads, more than the 4 RS MEM entries; slow answers.
    prog[p++] = LD  (11, 10, 0);
    prog[p++] = LD  (12, 10, 8);
    prog[p++] = LW  (13, 10, 4);        // high half, negative: sign-extends
    prog[p++] = LD  (14, 10, 16);
    prog[p++] = LW  (15, 10, 24);
    prog[p++] = LD  (16, 10, 32);
    prog[p++] = LD  (17, 10, 40);
    prog[p++] = LD  (18, 10, 48);
    prog[p++] = ADD (19, 11, 12);       // waits for two loads
    // Bundle 6: ALU work independent of the loads finishes first (out of order).
    prog[p++] = XOR (20, 3, 4);
    prog[p++] = OR  (21, 1, 2);
    prog[p++] = AND (22, 3, 2);
    // Bundle 7: stores and a load whose base comes from a load.
    prog[p++] = SD  (19, 10, 64);
    prog[p++] = SRLI(23, 11, 60);       // small value from a load
    prog[p++] = SLLI(24, 23, 3);
    // Bundle 8
    prog[p++] = ADD (25, 10, 24);
    prog[p++] = LD  (26, 25, 0);        // address depends on a load
    prog[p++] = SLT (27, 13, 0);        // negative lw result < 0
    // Bundles 9-14: a long chain, to keep tags and ROB rows in flight.
    prog[p++] = ADD (28, 26, 19);
    prog[p++] = ADDI(28, 28, 1);
    prog[p++] = ADDI(28, 28, 2);
    prog[p++] = ADDI(28, 28, 3);
    prog[p++] = ADD (29, 28, 27);
    prog[p++] = SUB (30, 29, 6);
    prog[p++] = SD  (30, 10, 72);
    prog[p++] = ADDI(1, 1, 10);
    prog[p++] = ADDI(2, 2, 20);
    prog[p++] = ADDI(3, 3, 30);
    prog[p++] = ADD (31, 1, 2);
    prog[p++] = ADD (31, 31, 3);
    prog[p++] = XOR (31, 31, 30);
    prog[p++] = LD  (7, 10, 56);
    prog[p++] = ADD (8, 7, 31);
    if (p != NPROG) $fatal(1, "program has %0d instructions, NPROG = %0d", p, NPROG);

    reference();

    n_commit_rd = 0; n_commit_all = 0; n_commit_st = 0; n_commit_ld = 0;
    seen_rs_stall = 1'b0; seen_int_full = 1'b0; seen_rename_stall = 1'b0;

    reset = 1'b1;
    repeat (2) @(posedge clk);
    #1 reset = 1'b0;

    while (n_commit_all < NPROG && cyc < MAX_CYC) @(posedge clk);
    if (n_commit_all < NPROG)
      $fatal(1, "timeout: %0d of %0d instructions committed in %0d cycles",
             n_commit_all, NPROG, cyc);
    repeat (3) @(posedge clk);
    @(negedge clk);

    if (n_commit_rd !== n_exp)
      $fatal(1, "%0d register commits, expected %0d", n_commit_rd, n_exp);
    if (n_commit_all !== NPROG)
      $fatal(1, "%0d instructions committed, expected %0d", n_commit_all, NPROG);
    if (n_commit_st !== n_st)
      $fatal(1, "%0d stores committed, expected %0d", n_commit_st, n_st);
    if (n_commit_ld !== n_ld)
      $fatal(1, "%0d loads committed, expected %0d", n_commit_ld, n_ld);
    if (!rob_empty)          $fatal(1, "ROB not empty at the end");
    if (int_free !== 4'd8)   $fatal(1, "RS INT not empty at the end (free = %0d)", int_free);
    if (mem_free !== 3'd4)   $fatal(1, "RS MEM not empty at the end (free = %0d)", mem_free);
    if (!seen_rs_stall)      $fatal(1, "the RS never refused a bundle: back-pressure not exercised");
    if (!seen_int_full)      $fatal(1, "the RS INT never filled");

    $display("PASS backend_tb DEEP2=%0d LSU_LAT=%0d: %0d instructions (%0d writes, %0d loads, %0d stores) in %0d cycles%s",
             DEEP2, LSU_LAT, NPROG, n_exp, n_ld, n_st, cyc,
             seen_rename_stall ? ", rename stalled for tags" : "");
    $finish;
  end

endmodule
/* verilator lint_on PINCONNECTEMPTY */
