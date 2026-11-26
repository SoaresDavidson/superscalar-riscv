// The DUT is combinational: every check is made in the same cycle in which the
// inputs are applied (drive on the falling edge, check 1 time unit later,
// before the next rising edge). A DUT that registers its outputs fails here.

// Two AGUs (wiki decision 17): agu_ld_* (load AGU) and agu_st_* (store AGU).
// ROB port 2 carries a store, or a load with an exception; when both arrive in
// the same cycle the older wins and the other gets resp_ready = 0.
//
// Directed tests compare against hand-written expected vectors (which buses and
// which ROB ports fire). The random test compares against expect_model(), a
// transcription of the rules. Valid bits are compared with !== so that an X is
// a failure; payloads are compared only where the valid bit is expected high.
module completion_tb;
  import execute_pkg::*;

  localparam int WB_N = 3;   // write-back buses: ALU, Branch Unit, load
  localparam int ROB_N = 4;   // ROB ports: ALU, Branch Unit, AGU, load
  localparam int N_RANDOM = 3000;

  // Clock and DUT
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic reset = 1'b1;
  logic flush = 1'b0;

  logic     alu_resp_valid = 1'b0, br_resp_valid = 1'b0;
  logic     agu_ld_resp_valid = 1'b0, agu_st_resp_valid = 1'b0;
  logic     lsu_resp_valid = 1'b0;
  logic     alu_resp_ready, br_resp_ready, lsu_resp_ready;
  logic     agu_ld_resp_ready, agu_st_resp_ready;
  fu_resp_t alu_resp = '0, br_resp = '0, lsu_resp = '0;
  fu_resp_t agu_ld_resp = '0, agu_st_resp = '0;

  logic     [WB_N-1:0]  wb_valid;
  tag_t     [WB_N-1:0]  wb_tag;
  xlen_t    [WB_N-1:0]  wb_data;
  logic     [ROB_N-1:0] rob_resp_valid;
  fu_resp_t [ROB_N-1:0] rob_resp;

  completion dut (.*);

  // Helpers
  int unsigned n_checks = 0;

  function automatic fu_resp_t mk(input xlen_t result, input tag_t dst_tag, input logic wr_en, input age_t age, input logic exception, input exc_cause_t cause);
    fu_resp_t r;
    r.result = result;
    r.dst_tag = dst_tag;
    r.wr_en = wr_en;
    r.age = age;
    r.exception = exception;
    r.cause = cause;
    return r;
  endfunction

  task automatic idle();
    flush = 1'b0;
    alu_resp_valid = 1'b0;  alu_resp = '0;
    br_resp_valid = 1'b0;  br_resp = '0;
    agu_ld_resp_valid = 1'b0;  agu_ld_resp = '0;
    agu_st_resp_valid = 1'b0;  agu_st_resp = '0;
    lsu_resp_valid = 1'b0;  lsu_resp = '0;
  endtask

  // Source of write-back bus p and of ROB port p.
  function automatic fu_resp_t wb_src(input int p);
    case (p)
      0: return alu_resp;
      1: return br_resp;
      default: return lsu_resp;
    endcase
  endfunction

  // ROB port 2: who should win it this cycle (0 none, 1 load AGU, 2 store AGU).
  function automatic int port2_winner();
    fu_resp_t l, s;
    logic     ld_c, st_c;
    l    = agu_ld_resp;
    s    = agu_st_resp;
    ld_c = agu_ld_resp_valid && l.exception;
    st_c = agu_st_resp_valid;
    if (ld_c && st_c) return age_is_younger(s.age, l.age) ? 1 : 2;
    if (ld_c)         return 1;
    if (st_c)         return 2;
    return 0;
  endfunction

  function automatic fu_resp_t rob_src(input int p);
    case (p)
      0: return alu_resp;
      1: return br_resp;
      2: return (port2_winner() == 1) ? agu_ld_resp : agu_st_resp;
      default: return lsu_resp;
    endcase
  endfunction

  // Expected readies of the two AGUs: the loser of a port-2 contest waits.
  // During a flush everything is consumed (and dropped).
  task automatic expect_ready(output logic e_ld, output logic e_st);
    fu_resp_t l;
    logic     both;
    l    = agu_ld_resp;
    both = agu_ld_resp_valid && l.exception && agu_st_resp_valid;
    e_ld = flush || !(both && port2_winner() == 2);
    e_st = flush || !(both && port2_winner() == 1);
  endtask

  // The rules, used only by the random test.
  function automatic logic writes(input logic v, input fu_resp_t r);
    return v && !flush && r.wr_en && (r.dst_tag != '0) && !r.exception;
  endfunction

  task automatic expect_model(output logic [WB_N-1:0] e_wb, output logic [ROB_N-1:0] e_rob);
    e_wb[0] = writes(alu_resp_valid, alu_resp);
    e_wb[1] = writes(br_resp_valid,  br_resp);
    e_wb[2] = writes(lsu_resp_valid, lsu_resp);
    e_rob[0] = !flush && alu_resp_valid;
    e_rob[1] = !flush && br_resp_valid;
    e_rob[2] = !flush && (port2_winner() != 0);
    e_rob[3] = !flush && lsu_resp_valid;
  endtask

  task automatic fail(input string name, input string what);
    $display("FAIL %s: %s", name, what);
    $display("     flush=%b valid alu/br/agu_ld/agu_st/lsu=%b%b%b%b%b",
             flush, alu_resp_valid, br_resp_valid, agu_ld_resp_valid, agu_st_resp_valid, lsu_resp_valid);
    $display("     wb_valid=%b rob_resp_valid=%b ready ld/st=%b%b", wb_valid, rob_resp_valid,
             agu_ld_resp_ready, agu_st_resp_ready);
    $fatal(1, "completion_tb failed");
  endtask

  // Compares every output against the expected valid vectors.
  task automatic check(input string name, input logic [WB_N-1:0] e_wb, input logic [ROB_N-1:0] e_rob);
    fu_resp_t s, o;
    logic     e_ld, e_st;
    if ({alu_resp_ready, br_resp_ready, lsu_resp_ready} !== 3'b111)
      fail(name, "an ALU, Branch Unit or load resp_ready is not 1");
    expect_ready(e_ld, e_st);
    if (agu_ld_resp_ready !== e_ld || agu_st_resp_ready !== e_st)
      fail(name, $sformatf("AGU ready ld/st = %b%b, expected %b%b",
                           agu_ld_resp_ready, agu_st_resp_ready, e_ld, e_st));

    if (wb_valid !== e_wb)
      fail(name, $sformatf("wb_valid = %b, expected %b", wb_valid, e_wb));
    for (int p = 0; p < WB_N; p++) begin
      s = wb_src(p);
      if (e_wb[p] && wb_tag[p] !== s.dst_tag)
        fail(name, $sformatf("wb_tag[%0d] = %0d, expected %0d", p, wb_tag[p], s.dst_tag));
      if (e_wb[p] && wb_data[p] !== s.result)
        fail(name, $sformatf("wb_data[%0d] = %h, expected %h", p, wb_data[p], s.result));
    end

    if (rob_resp_valid !== e_rob)
      fail(name, $sformatf("rob_resp_valid = %b, expected %b", rob_resp_valid, e_rob));
    for (int p = 0; p < ROB_N; p++) begin
      s = rob_src(p);
      o = rob_resp[p]; // whole struct, never rob_resp[p].field (Icarus)
      if (e_rob[p] && o !== s)
        fail(name, $sformatf("rob_resp[%0d] = %h, expected %h (fields not passed through)", p, o, s));
    end
    n_checks++;
  endtask

  // Apply on the falling edge, check before the rising edge, move on.
  task automatic step(input string name, input logic [WB_N-1:0] e_wb, input logic [ROB_N-1:0] e_rob);
    #1;
    check(name, e_wb, e_rob);
    @(negedge clk);
  endtask

  // Random stimulus
  function automatic exc_cause_t rand_cause();
    case ($urandom_range(3))
      0: return CAUSE_NONE;
      1: return CAUSE_ILLEGAL_INST;
      2: return CAUSE_LOAD_MISALIGNED;
      default: return CAUSE_STORE_MISALIGNED;
    endcase
  endfunction

  function automatic fu_resp_t rand_resp();
    fu_resp_t r;
    r.result = {$urandom, $urandom};
    r.dst_tag = ($urandom_range(7) == 0) ? tag_t'(0) : tag_t'($urandom);
    r.wr_en = ($urandom_range(3) != 0);
    r.age = age_t'($urandom);
    r.exception = ($urandom_range(9) == 0);
    r.cause = exc_cause_t'(r.exception ? rand_cause() : CAUSE_NONE); // Icarus 13: enum from ?: needs a cast
    return r;
  endfunction

  // Test sequence
  logic [WB_N-1:0]  e_wb;
  logic [ROB_N-1:0] e_rob;

  initial begin
    @(negedge clk);

    // T1: nothing arrives, during and after reset
    idle();
    step("T1 idle during reset", 3'b000, 4'b0000);
    reset = 1'b0;
    step("T1 idle", 3'b000, 4'b0000);

    // T2: ALU result with destination -> bus 0 and ROB port 0
    idle();
    alu_resp_valid = 1'b1;
    alu_resp = mk(64'hA5A5_0000_0000_0001, tag_t'(5), 1'b1, age_t'(7), 1'b0, CAUSE_NONE);
    step("T2 ALU with destination", 3'b001, 4'b0001);

    // T3: Branch Unit. jalr writes the link (bus 1); beq only tells the ROB.
    idle();
    br_resp_valid = 1'b1;
    br_resp = mk(64'h0000_0000_0000_1004, tag_t'(9), 1'b1, age_t'(8), 1'b0, CAUSE_NONE);
    step("T3 jalr link", 3'b010, 4'b0010);
    idle();
    br_resp_valid = 1'b1;
    br_resp = mk(64'hDEAD_BEEF_DEAD_BEEF, tag_t'(9), 1'b0, age_t'(9), 1'b0, CAUSE_NONE);
    step("T3 conditional branch", 3'b000, 4'b0010);

    // T4: AGU store -> ROB port 2 only, never a write-back
    idle();
    agu_st_resp_valid = 1'b1;
    agu_st_resp = mk(64'h0000_0000_0000_2000, tag_t'(0), 1'b0, age_t'(10), 1'b0, CAUSE_NONE);
    step("T4 AGU store", 3'b000, 4'b0100);

    // T5: AGU load without exception -> nothing at all: the load finishes on
    // port 3 when the data arrives. Also a load to x0 (wr_en = 0), which is
    // why the Completion cannot tell a load from a store by wr_en.
    idle();
    agu_ld_resp_valid = 1'b1;
    agu_ld_resp = mk(64'h0000_0000_0000_3000, tag_t'(12), 1'b1, age_t'(11), 1'b0, CAUSE_NONE);
    step("T5 AGU load", 3'b000, 4'b0000);
    idle();
    agu_ld_resp_valid = 1'b1;
    agu_ld_resp = mk(64'h0000_0000_0000_3008, tag_t'(0), 1'b0, age_t'(12), 1'b0, CAUSE_NONE);
    step("T5 AGU load to x0", 3'b000, 4'b0000);

    // T6: AGU load with a misalignment exception -> ROB port 2, with the cause
    idle();
    agu_ld_resp_valid = 1'b1;
    agu_ld_resp = mk(64'h0000_0000_0000_3003, tag_t'(12), 1'b1, age_t'(13), 1'b1,
                     CAUSE_LOAD_MISALIGNED);
    step("T6 AGU load exception", 3'b000, 4'b0100);

    // T7: AGU store with a misalignment exception -> ROB port 2
    idle();
    agu_st_resp_valid = 1'b1;
    agu_st_resp = mk(64'h0000_0000_0000_2002, tag_t'(0), 1'b0, age_t'(14), 1'b1,
                     CAUSE_STORE_MISALIGNED);
    step("T7 AGU store exception", 3'b000, 4'b0100);

    // T8: load data from Memory -> bus 2 and ROB port 3
    idle();
    lsu_resp_valid = 1'b1;
    lsu_resp = mk(64'hFFFF_FFFF_FFFF_FF80, tag_t'(20), 1'b1, age_t'(11), 1'b0, CAUSE_NONE);
    step("T8 load data", 3'b100, 4'b1000);

    // T9: exception with wr_en = 1 (load side) -> ROB port 3, no write-back
    idle();
    lsu_resp_valid = 1'b1;
    lsu_resp = mk(64'h0, tag_t'(21), 1'b1, age_t'(15), 1'b1, CAUSE_LOAD_MISALIGNED);
    step("T9 exception does not write", 3'b000, 4'b1000);

    // T10: wr_en = 1 with tag 0 on each writer: no write-back, ROB told
    idle();
    alu_resp_valid = 1'b1;
    alu_resp = mk(64'hFFFF_FFFF_FFFF_FFFF, tag_t'(0), 1'b1, age_t'(1), 1'b0, CAUSE_NONE);
    br_resp_valid  = 1'b1;
    br_resp  = mk(64'hFFFF_FFFF_FFFF_FFFF, tag_t'(0), 1'b1, age_t'(2), 1'b0, CAUSE_NONE);
    lsu_resp_valid = 1'b1;
    lsu_resp = mk(64'hFFFF_FFFF_FFFF_FFFF, tag_t'(0), 1'b1, age_t'(3), 1'b0, CAUSE_NONE);
    step("T10 tag 0", 3'b000, 4'b1011);

    // T11: all four sources in the same cycle, distinct payloads (detects a
    // swap between buses or ports); then with the AGU carrying a load
    idle();
    alu_resp_valid = 1'b1;
    alu_resp = mk(64'h1111_1111_1111_1111, tag_t'(31), 1'b1, age_t'(40), 1'b0, CAUSE_NONE);
    br_resp_valid  = 1'b1;
    br_resp  = mk(64'h2222_2222_2222_2222, tag_t'(32), 1'b1, age_t'(41), 1'b0, CAUSE_NONE);
    agu_st_resp_valid = 1'b1;
    agu_st_resp = mk(64'h3333_3333_3333_3333, tag_t'(0),  1'b0, age_t'(42), 1'b0, CAUSE_NONE);
    agu_ld_resp_valid = 1'b1;
    agu_ld_resp = mk(64'h5555_5555_5555_5555, tag_t'(33), 1'b1, age_t'(39), 1'b0, CAUSE_NONE);
    lsu_resp_valid = 1'b1;
    lsu_resp = mk(64'h4444_4444_4444_4444, tag_t'(34), 1'b1, age_t'(43), 1'b0, CAUSE_NONE);
    step("T11 all sources, load without exception", 3'b111, 4'b1111);
    agu_st_resp_valid = 1'b0;
    step("T11 all sources but the store AGU", 3'b111, 4'b1011);

    // T12: no valid, with payloads that would write; then X payloads
    idle();
    alu_resp = mk(64'h1, tag_t'(1), 1'b1, age_t'(1), 1'b0, CAUSE_NONE);
    br_resp  = alu_resp;
    agu_ld_resp = mk(64'h1, tag_t'(1), 1'b1, age_t'(1), 1'b1, CAUSE_LOAD_MISALIGNED);
    agu_st_resp = alu_resp;
    lsu_resp = alu_resp;
    step("T12 invalid with real payload", 3'b000, 4'b0000);
    alu_resp = 'x;  br_resp = 'x;  agu_ld_resp = 'x;  agu_st_resp = 'x;  lsu_resp = 'x;
    step("T12 invalid with X payload", 3'b000, 4'b0000);

    // T13: flush with every source valid: nothing goes out, all ready
    idle();
    alu_resp_valid = 1'b1;
    alu_resp = mk(64'h5, tag_t'(50), 1'b1, age_t'(60), 1'b0, CAUSE_NONE);
    br_resp_valid  = 1'b1;
    br_resp  = mk(64'h6, tag_t'(51), 1'b1, age_t'(61), 1'b0, CAUSE_NONE);
    agu_st_resp_valid = 1'b1;
    agu_st_resp = mk(64'h7, tag_t'(0),  1'b0, age_t'(62), 1'b0, CAUSE_NONE);
    agu_ld_resp_valid = 1'b1;
    agu_ld_resp = mk(64'h9, tag_t'(52), 1'b1, age_t'(58), 1'b1, CAUSE_LOAD_MISALIGNED);
    lsu_resp_valid = 1'b1;
    lsu_resp = mk(64'h8, tag_t'(53), 1'b1, age_t'(63), 1'b0, CAUSE_NONE);
    flush = 1'b1;
    step("T13 flush, also during a port-2 contest", 3'b000, 4'b0000);

    // T14: next cycle, the same tags come back with new data (tag reuse after
    // the flush) and are written normally
    flush = 1'b0;
    agu_ld_resp_valid = 1'b0;
    alu_resp = mk(64'h50, tag_t'(50), 1'b1, age_t'(0), 1'b0, CAUSE_NONE);
    br_resp  = mk(64'h51, tag_t'(51), 1'b1, age_t'(1), 1'b0, CAUSE_NONE);
    lsu_resp = mk(64'h53, tag_t'(53), 1'b1, age_t'(3), 1'b0, CAUSE_NONE);
    step("T14 tag reuse after flush", 3'b111, 4'b1111);

    // T15: limits: bit 63, upper half only, largest tag, age 0 and max, causes
    idle();
    alu_resp_valid = 1'b1;
    alu_resp = mk(64'h8000_0000_0000_0001, '1, 1'b1, age_t'(0), 1'b0, CAUSE_NONE);
    lsu_resp_valid = 1'b1;
    lsu_resp = mk(64'hFFFF_FFFF_0000_0000, tag_t'(1), 1'b1, '1, 1'b0, CAUSE_NONE);
    step("T15 largest tag, wide data, age limits", 3'b101, 4'b1001);
    for (int c = 0; c < 4; c++) begin
      fu_resp_t r;
      idle();
      r = mk('1, '1, 1'b0, '1, 1'b1, exc_cause_t'((c == 0) ? CAUSE_NONE : (c == 1) ? CAUSE_ILLEGAL_INST : (c == 2) ? CAUSE_LOAD_MISALIGNED : CAUSE_STORE_MISALIGNED));
      if (c[0]) begin agu_ld_resp_valid = 1'b1; agu_ld_resp = r; end
      else      begin agu_st_resp_valid = 1'b1; agu_st_resp = r; end
      step($sformatf("T15 AGU exception, cause %0d", c), 3'b000, 4'b0100);
    end

    // T16: port-2 contest, the load (with exception) is older. The load goes
    // out and the store waits (ready 0); next cycle the store goes out alone.
    idle();
    agu_ld_resp_valid = 1'b1;
    agu_ld_resp = mk(64'hA001, tag_t'(7), 1'b1, age_t'(20), 1'b1, CAUSE_LOAD_MISALIGNED);
    agu_st_resp_valid = 1'b1;
    agu_st_resp = mk(64'hB001, tag_t'(0), 1'b0, age_t'(21), 1'b0, CAUSE_NONE);
    step("T16 contest, older load wins", 3'b000, 4'b0100);
    agu_ld_resp_valid = 1'b0;
    step("T16 the store goes out next cycle", 3'b000, 4'b0100);

    // T17: port-2 contest, the store is older. Also across the age wrap:
    // age 250 is older than age 3.
    idle();
    agu_ld_resp_valid = 1'b1;
    agu_ld_resp = mk(64'hA002, tag_t'(8), 1'b1, age_t'(3), 1'b1, CAUSE_LOAD_MISALIGNED);
    agu_st_resp_valid = 1'b1;
    agu_st_resp = mk(64'hB002, tag_t'(0), 1'b0, age_t'(250), 1'b1, CAUSE_STORE_MISALIGNED);
    step("T17 contest, older store wins (age wrap)", 3'b000, 4'b0100);
    agu_st_resp_valid = 1'b0;
    step("T17 the load goes out next cycle", 3'b000, 4'b0100);

    // T18: a load without exception never contests port 2: both readies stay 1
    // and the store goes out in the same cycle.
    idle();
    agu_ld_resp_valid = 1'b1;
    agu_ld_resp = mk(64'hA003, tag_t'(9), 1'b1, age_t'(30), 1'b0, CAUSE_NONE);
    agu_st_resp_valid = 1'b1;
    agu_st_resp = mk(64'hB003, tag_t'(0), 1'b0, age_t'(31), 1'b0, CAUSE_NONE);
    step("T18 load without exception, no contest", 3'b000, 4'b0100);

    // R: random responses and random flush, against the rules
    for (int i = 0; i < N_RANDOM; i++) begin
      flush = ($urandom_range(19) == 0);
      alu_resp_valid = $urandom_range(1);
      br_resp_valid  = $urandom_range(1);
      agu_ld_resp_valid = $urandom_range(1);
      agu_st_resp_valid = $urandom_range(1);
      lsu_resp_valid = $urandom_range(1);
      alu_resp = rand_resp();
      br_resp = rand_resp();
      agu_ld_resp = rand_resp();
      agu_st_resp = rand_resp();
      if ($urandom_range(2) == 0) begin   // more port-2 contests
        fu_resp_t l;
        l = agu_ld_resp;
        l.exception = 1'b1;
        l.cause = CAUSE_LOAD_MISALIGNED;
        agu_ld_resp = l;
      end
      lsu_resp = rand_resp();
      #1;
      expect_model(e_wb, e_rob);
      check($sformatf("R cycle %0d", i), e_wb, e_rob);
      @(negedge clk);
    end

    $display("completion_tb: %0d checks PASS", n_checks);
    $finish;
  end

  // A hung simulation is a failure, not a silent stop
  initial begin
    #(10 * (N_RANDOM + 200));
    $fatal(1, "completion_tb: timeout");
  end

endmodule
