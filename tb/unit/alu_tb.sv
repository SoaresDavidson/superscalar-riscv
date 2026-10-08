// Self-checking unit test for the ALU (rtl/execute/alu.sv).
//
// Timing convention: the testbench drives inputs on the falling edge and the
// DUT samples on the rising edge. A monitor checks every output handshake
// (resp_valid && resp_ready) against a FIFO of expected results, so a result
// that is lost, duplicated, reordered or wrong fails the test.
module alu_tb;
  import execute_pkg::*;

  // ---------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------
  logic     clk = 1'b0;
  logic     reset;
  logic     flush;
  age_t     flush_age;
  logic     req_valid;
  logic     req_ready;
  fu_req_t  req;
  logic     resp_valid;
  logic     resp_ready;
  fu_resp_t resp;

  alu dut (
    .clk        (clk),
    .reset      (reset),
    .flush      (flush),
    .flush_age  (flush_age),
    .req_valid  (req_valid),
    .req_ready  (req_ready),
    .req        (req),
    .resp_valid (resp_valid),
    .resp_ready (resp_ready),
    .resp       (resp)
  );

  always #5 clk = ~clk;

  integer errors = 0;

  task automatic check(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL [t=%0t]: %s", $time, msg);
      errors++;
    end
  endtask

  // ---------------------------------------------------------------------
  // Expected-result FIFO and output monitor
  // ---------------------------------------------------------------------
  localparam int FIFO_D = 1024;
  age_t  exp_age [FIFO_D];
  xlen_t exp_res [FIFO_D];
  reg_t  exp_rd  [FIFO_D];
  logic  exp_wr  [FIFO_D];
  integer head = 0, tail = 0;

  function automatic void push_expected(input age_t a, input xlen_t r,
                                        input reg_t rd, input logic wr);
    exp_age[tail] = a;
    exp_res[tail] = r;
    exp_rd[tail]  = rd;
    exp_wr[tail]  = wr;
    tail++;
  endfunction

  // A flush removes the expected results of instructions younger than
  // flush_age. In program order they are always at the tail of the FIFO.
  function automatic void kill_expected_younger(input age_t fa);
    while (tail > head && age_is_younger(exp_age[tail-1], fa)) tail--;
  endfunction

  always @(posedge clk) begin
    if (!reset && resp_valid && resp_ready) begin
      if (head == tail) begin
        $display("FAIL [t=%0t]: unexpected output, age %0d", $time, resp.age);
        errors++;
      end else begin
        check(resp.age    == exp_age[head], $sformatf("age: got %0d, expected %0d", resp.age, exp_age[head]));
        check(resp.result == exp_res[head], $sformatf("age %0d result: got %h, expected %h", resp.age, resp.result, exp_res[head]));
        check(resp.rd     == exp_rd[head],  $sformatf("age %0d rd: got %0d, expected %0d", resp.age, resp.rd, exp_rd[head]));
        check(resp.wr_en  == exp_wr[head],  $sformatf("age %0d wr_en: got %b, expected %b", resp.age, resp.wr_en, exp_wr[head]));
        check(resp.exception == 1'b0,       $sformatf("age %0d raised an exception", resp.age));
        head++;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Driver
  // ---------------------------------------------------------------------
  age_t next_age = '0;

  // Presents one request and waits until it is accepted. Returns right
  // before the rising edge that performs the handshake.
  task automatic send(input exec_op_t op, input xlen_t a, input xlen_t b,
                      input xlen_t imm, input xlen_t pc, input logic use_imm,
                      input reg_t rd, input logic wr_en, input xlen_t expected);
    @(negedge clk);
    req             = '0;
    req.op          = op;
    req.src1        = a;
    req.src2        = b;
    req.imm         = imm;
    req.use_imm     = use_imm;
    req.pc          = pc;
    req.rd          = rd;
    req.wr_en       = wr_en;
    req.age         = next_age;
    req_valid       = 1'b1;
    #1;
    while (!req_ready) begin
      @(negedge clk);
      #1;
    end
    push_expected(next_age, expected, rd, wr_en);
    next_age++;
  endtask

  // Register-register operation writing x5
  task automatic rr(input exec_op_t op, input xlen_t a, input xlen_t b, input xlen_t expected);
    send(op, a, b, '0, '0, 1'b0, 7'd5, 1'b1, expected);
  endtask

  task automatic idle();
    @(negedge clk);
    req_valid = 1'b0;
  endtask

  // ---------------------------------------------------------------------
  // Reference model for the random test (written independently of the RTL:
  // the arithmetic shift is built from a logical shift plus sign fill)
  // ---------------------------------------------------------------------
  function automatic xlen_t model(input exec_op_t op, input xlen_t a,
                                  input xlen_t b, input xlen_t imm, input xlen_t pc);
    int unsigned sh;
    sh = b % XLEN;
    case (op)
      ALU_ADD:   return a + b;
      ALU_SUB:   return a - b;
      ALU_AND:   return a & b;
      ALU_OR:    return a | b;
      ALU_XOR:   return a ^ b;
      ALU_SLT:   return (a[XLEN-1] != b[XLEN-1]) ? xlen_t'(a[XLEN-1]) : xlen_t'(a < b);
      ALU_SLTU:  return xlen_t'(a < b);
      ALU_SLL:   return a << sh;
      ALU_SRL:   return a >> sh;
      ALU_SRA:   return (a >> sh) | (a[XLEN-1] ? ~({XLEN{1'b1}} >> sh) : '0);
      ALU_LUI:   return imm;
      ALU_AUIPC: return pc + imm;
      default:   return 'x;
    endcase
  endfunction

  // ---------------------------------------------------------------------
  // Random back-pressure (enabled only during the random test)
  // ---------------------------------------------------------------------
  logic   random_bp = 1'b0;
  integer seed = 32'd2026;

  always @(negedge clk) begin
    if (random_bp) resp_ready = ($random(seed) % 4) != 0;  // ready 75% of the time
  end

  localparam xlen_t MIN_S = {1'b1, {(XLEN-1){1'b0}}};  // most negative
  localparam xlen_t MAX_S = {1'b0, {(XLEN-1){1'b1}}};  // most positive
  localparam xlen_t ONES  = {XLEN{1'b1}};              // -1

  function automatic xlen_t random_operand();
    case ($random(seed) & 7)
      0:       return '0;
      1:       return ONES;
      2:       return MIN_S;
      3:       return MAX_S;
      4:       return xlen_t'(1);
      default: return {$random(seed), $random(seed)};
    endcase
  endfunction

  function automatic exec_op_t random_alu_op();
    case (($random(seed) & 32'h7FFF_FFFF) % 12)
      0:       return ALU_ADD;
      1:       return ALU_SUB;
      2:       return ALU_AND;
      3:       return ALU_OR;
      4:       return ALU_XOR;
      5:       return ALU_SLT;
      6:       return ALU_SLTU;
      7:       return ALU_SLL;
      8:       return ALU_SRL;
      9:       return ALU_SRA;
      10:      return ALU_LUI;
      default: return ALU_AUIPC;
    endcase
  endfunction

  // ---------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------
  initial begin
    reset      = 1'b1;
    flush      = 1'b0;
    flush_age  = '0;
    req_valid  = 1'b0;
    req        = '0;
    resp_ready = 1'b1;
    repeat (2) @(negedge clk);
    reset = 1'b0;
    #1;
    check(resp_valid == 1'b0, "after reset: resp_valid must be 0");
    check(req_ready  == 1'b1, "after reset: req_ready must be 1");

    // ----- 1. Directed tests, back-to-back, no back-pressure -----
    rr(ALU_ADD,  64'd5, 64'd7, 64'd12);
    rr(ALU_ADD,  MAX_S, 64'd1, MIN_S);                       // signed overflow wraps
    rr(ALU_ADD,  ONES,  64'd1, 64'd0);                       // unsigned wrap
    rr(ALU_SUB,  64'd3, 64'd5, 64'hFFFF_FFFF_FFFF_FFFE);     // 3 - 5 = -2
    rr(ALU_SUB,  MIN_S, 64'd1, MAX_S);                       // underflow wraps
    rr(ALU_AND,  64'hF0F0_F0F0_F0F0_F0F0, 64'hFF00_FF00_FF00_FF00, 64'hF000_F000_F000_F000);
    rr(ALU_OR,   64'hF0F0_F0F0_F0F0_F0F0, 64'h0F0F_0000_0F0F_0000, 64'hFFFF_F0F0_FFFF_F0F0);
    rr(ALU_XOR,  64'hFFFF_0000_FFFF_0000, 64'hFF00_FF00_FF00_FF00, 64'h00FF_FF00_00FF_FF00);

    // slt vs sltu: the same bits compare differently
    rr(ALU_SLT,  ONES,  64'd1, 64'd1);   // -1 < 1 (signed)
    rr(ALU_SLTU, ONES,  64'd1, 64'd0);   // 2^64-1 < 1 is false (unsigned)
    rr(ALU_SLT,  64'd1, ONES,  64'd0);
    rr(ALU_SLTU, 64'd1, ONES,  64'd1);
    rr(ALU_SLT,  MIN_S, MAX_S, 64'd1);
    rr(ALU_SLT,  64'd7, 64'd7, 64'd0);   // equal is not less

    // shifts: amount is the low 6 bits of the operand
    rr(ALU_SLL,  64'd1, 64'd0,  64'd1);                      // by 0
    rr(ALU_SLL,  64'd1, 64'd40, 64'h0000_0100_0000_0000);    // beyond 32: 6-bit amount
    rr(ALU_SLL,  64'd1, 64'd63, MIN_S);                      // by XLEN-1
    rr(ALU_SLL,  64'd1, 64'd64, 64'd1);                      // 64 -> amount 0
    rr(ALU_SRL,  MIN_S, 64'd63, 64'd1);
    rr(ALU_SRL,  ONES,  64'd36, 64'h0000_0000_0FFF_FFFF);
    rr(ALU_SRA,  MIN_S, 64'd63, ONES);                       // sign fills
    rr(ALU_SRA,  MIN_S, 64'd4,  64'hF800_0000_0000_0000);
    rr(ALU_SRA,  64'h4000_0000_0000_0000, 64'd1, 64'h2000_0000_0000_0000);  // positive: zero fill

    // immediate operand: src2 must be ignored
    send(ALU_ADD,   64'd10, 64'd999, ONES - 64'd2, '0, 1'b1, 7'd5, 1'b1, 64'd7);   // 10 + (-3)
    send(ALU_SLL,   64'd1,  64'd0,   64'd33,       '0, 1'b1, 7'd5, 1'b1, 64'h0000_0002_0000_0000);
    send(ALU_LUI,   64'd123, 64'd456, 64'h0000_0000_1234_5000, '0, 1'b1, 7'd5, 1'b1, 64'h0000_0000_1234_5000);
    send(ALU_AUIPC, 64'd123, 64'd456, 64'h20, 64'h1000, 1'b1, 7'd5, 1'b1, 64'h1020);

    // same register as source and destination: add x5, x5, x5
    send(ALU_ADD, 64'd21, 64'd21, '0, '0, 1'b0, 7'd5, 1'b1, 64'd42);
    // x0 destination: wr_en arrives as 0 and must leave as 0
    send(ALU_ADD, 64'd1, 64'd2, '0, '0, 1'b0, 7'd0, 1'b0, 64'd3);
    // highest register specifier (7 bits)
    send(ALU_ADD, 64'd1, 64'd2, '0, '0, 1'b0, 7'd127, 1'b1, 64'd3);
    idle();
    repeat (2) @(negedge clk);

    // ----- 2. Back-pressure: hold, no loss, no duplication -----
    resp_ready = 1'b0;
    send(ALU_ADD, 64'd100, 64'd1, '0, '0, 1'b0, 7'd5, 1'b1, 64'd101);   // A: accepted (output empty)
    @(negedge clk);                                                     // A now held
    req.op = ALU_ADD; req.src1 = 64'd200; req.src2 = 64'd2; req.age = next_age;  // present B
    repeat (3) begin
      #1;
      check(req_ready  == 1'b0, "back-pressure: req_ready must be 0 while output is held");
      check(resp_valid == 1'b1, "back-pressure: held result must stay valid");
      check(resp.result == 64'd101, "back-pressure: held result must not change");
      @(negedge clk);
    end
    resp_ready = 1'b1;                                                  // A leaves, B enters
    #1;
    check(req_ready == 1'b1, "back-pressure: req_ready must rise with resp_ready");
    push_expected(next_age, 64'd202, 7'd5, 1'b1);
    next_age++;
    idle();
    #1;
    check(resp_valid == 1'b1 && resp.result == 64'd202, "back-pressure: B must follow A");
    repeat (2) @(negedge clk);

    // ----- 3. Flush: an OLDER held result survives -----
    resp_ready = 1'b0;
    next_age = 8'd10;
    send(ALU_ADD, 64'd1, 64'd1, '0, '0, 1'b0, 7'd5, 1'b1, 64'd2);       // age 10
    idle();
    flush = 1'b1; flush_age = 8'd11;                                    // branch age 11
    #1;
    check(resp_valid == 1'b1, "flush: older result (age 10) must survive a flush from age 11");
    @(negedge clk);
    flush = 1'b0;
    resp_ready = 1'b1;
    repeat (2) @(negedge clk);

    // ----- 4. Flush: a YOUNGER held result and a younger incoming one die -----
    resp_ready = 1'b0;
    next_age = 8'd12;
    send(ALU_ADD, 64'd5, 64'd5, '0, '0, 1'b0, 7'd5, 1'b1, 64'd10);      // age 12
    @(negedge clk);
    flush = 1'b1; flush_age = 8'd11;
    kill_expected_younger(8'd11);
    resp_ready = 1'b1;                       // even with ready high, nothing may leave
    req.age = 8'd13; req_valid = 1'b1;       // younger instruction arriving during flush
    #1;
    check(resp_valid == 1'b0, "flush: younger held result (age 12) must be masked");
    @(negedge clk);
    flush = 1'b0;
    req_valid = 1'b0;
    #1;
    check(resp_valid == 1'b0, "flush: younger incoming request (age 13) must be dropped");
    repeat (2) @(negedge clk);

    // ----- 5. Flush across the age wraparound -----
    resp_ready = 1'b0;
    next_age = 8'd2;
    send(ALU_ADD, 64'd1, 64'd1, '0, '0, 1'b0, 7'd5, 1'b1, 64'd2);       // age 2
    @(negedge clk);
    req_valid = 1'b0;
    flush = 1'b1; flush_age = 8'd250;                                   // 2 is younger than 250
    kill_expected_younger(8'd250);
    #1;
    check(resp_valid == 1'b0, "flush: age 2 is younger than 250 after wraparound");
    @(negedge clk);
    flush = 1'b0;
    resp_ready = 1'b1;
    repeat (2) @(negedge clk);

    // ----- 6. Random test against the model, with random back-pressure -----
    next_age = '0;
    random_bp = 1'b1;
    repeat (500) begin
      exec_op_t op;
      xlen_t a, b, imm, pc;
      logic  ui;
      op  = random_alu_op();
      a   = random_operand();
      b   = random_operand();
      imm = random_operand();
      pc  = {$random(seed), $random(seed)} & ~xlen_t'(3);
      ui  = $random(seed);
      send(op, a, b, imm, pc, ui, reg_t'($random(seed)), 1'b1,
           model(op, a, ui ? imm : b, imm, pc));
    end
    idle();
    random_bp = 1'b0;
    @(negedge clk);
    resp_ready = 1'b1;
    repeat (3) @(negedge clk);

    // ----- End -----
    check(head == tail, $sformatf("%0d expected result(s) never came out", tail - head));
    if (errors == 0) $display("PASS");
    else $fatal(1, "%0d check(s) failed", errors);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "timeout: the ALU stopped accepting or producing results");
  end
endmodule
